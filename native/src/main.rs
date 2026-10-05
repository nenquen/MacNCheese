//! Mac'n Cheese TUI (ratatui, no GTK, no Python).
//! Tabs: Play | Settings | Logs. The game backend (Darling + shim) is
//! shared with the frozen Python launcher through the same files.

mod audio;
mod display;
mod flags;
mod i18n;
mod mods;
mod patches;
mod paths;
mod session;
mod settings;
mod update;

use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Tabs},
    Terminal,
};
use serde_json::{Map, Value};
use std::io;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

const TABS: &[&str] = &["Play", "Settings", "Flags", "Logs", "Setup"];

fn app_uri() -> Option<String> {
    std::env::args()
        .skip(1)
        .find(|a| !a.starts_with('-'))
        .filter(|u| u.contains(':'))
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("macncheese {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Mac'n Cheese {} — Roblox on Linux through Darling", env!("CARGO_PKG_VERSION"));
        println!("Usage: macncheese [--version|--help] [roblox-url]");
        return Ok(());
    }
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new();
    let result = run(&mut terminal, &mut app);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    result
}

enum StartMsg {
    Started(session::Session),
    Failed(String),
}

struct App {
    tab: usize,
    settings: Map<String, Value>,
    session: Option<session::Session>,
    starting: bool,
    status: String,
    settings_cursor: usize,
    logs: Vec<std::path::PathBuf>,
    logs_state: ListState,
    log_tail: Vec<String>,
    tx: Sender<StartMsg>,
    rx: Receiver<StartMsg>,
    setup: SetupState,
    setup_tx: Sender<SetupMsg>,
    setup_rx: Receiver<SetupMsg>,
}

#[derive(Clone)]
enum SetupState {
    Idle,
    Running(String),
    Done(String),
    Failed(String),
}

enum SetupMsg {
    Progress(String),
    Finished(Result<String, String>),
}

impl App {
    fn new() -> App {
        let (tx, rx) = mpsc::channel();
        let (setup_tx, setup_rx) = mpsc::channel();
        App {
            tab: 0,
            settings: settings::load(),
            session: None,
            starting: false,
            status: String::new(),
            settings_cursor: 0,
            logs: Vec::new(),
            logs_state: ListState::default(),
            log_tail: Vec::new(),
            tx,
            rx,
            setup: SetupState::Idle,
            setup_tx,
            setup_rx,
        }
    }

    fn save_settings(&self) {
        let _ = settings::save(&self.settings);
    }

    fn set(&mut self, key: &str, value: Value) {
        self.settings.insert(key.to_string(), value);
        self.save_settings();
    }

    fn get_bool(&self, key: &str, default: bool) -> bool {
        self.settings.get(key).and_then(|v| v.as_bool()).unwrap_or(default)
    }

    fn start_or_stop(&mut self) {
        if self.session.is_some() {
            if let Some(mut s) = self.session.take() {
                s.finish();
            }
            self.status = "Stopped.".into();
            return;
        }
        if self.starting {
            return;
        }
        if !paths::app_bundle().is_dir() {
            self.status = "Roblox is not installed yet.".into();
            return;
        }
        self.starting = true;
        self.status = "Starting Roblox…".into();
        let tx = self.tx.clone();
        let snapshot = self.settings.clone();
        std::thread::spawn(move || {
            let _ = tx.send(match session::Session::start(&snapshot, app_uri()) {
                Ok(s) => StartMsg::Started(s),
                Err(e) => StartMsg::Failed(e),
            });
        });
    }

    fn tick(&mut self) {
        while let Ok(msg) = self.rx.try_recv() {
            self.starting = false;
            match msg {
                StartMsg::Started(s) => {
                    self.session = Some(s);
                    self.status = "Roblox running.".into();
                }
                StartMsg::Failed(e) => {
                    self.status = format!("Could not start: {e}");
                }
            }
        }
        while let Ok(msg) = self.setup_rx.try_recv() {
            match msg {
                SetupMsg::Progress(text) => self.setup = SetupState::Running(text),
                SetupMsg::Finished(Ok(text)) => {
                    self.setup = SetupState::Done(text);
                    self.status = "Setup complete.".into();
                }
                SetupMsg::Finished(Err(e)) => {
                    self.setup = SetupState::Failed(e.clone());
                    self.status = format!("Setup failed: {e}");
                }
            }
        }
        if let Some(s) = self.session.as_mut() {
            match s.poll() {
                None => self.refresh_tail(),
                Some(code) => {
                    self.session = None;
                    self.status = format!("Roblox exited ({code}).");
                }
            }
        }
    }

    fn refresh_tail(&mut self) {
        let path = match self.session.as_ref().and_then(|s| s.log_path.clone()) {
            Some(p) => p,
            None => return,
        };
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let lines: Vec<String> = text.lines().map(str::to_string).collect();
        let n = lines.len();
        self.log_tail = if n > 12 { lines[n - 12..].to_vec() } else { lines };
    }

    fn run_setup(&mut self) {
        if matches!(self.setup, SetupState::Running(_)) {
            return;
        }
        self.setup = SetupState::Running("Checking…".into());
        let tx = self.setup_tx.clone();
        std::thread::spawn(move || {
            let say = |t: &str| {
                let _ = tx.send(SetupMsg::Progress(t.into()));
            };
            let missing = session::missing_tools();
            if !missing.is_empty() {
                let _ = tx.send(SetupMsg::Finished(Err(format!(
                    "Install these first: {}",
                    missing.join(", ")
                ))));
                return;
            }
            if crate::update::installed_version().is_none() {
                say("Contacting version service…");
                let (version, upload) = match crate::update::latest_version() {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = tx.send(SetupMsg::Finished(Err(e)));
                        return;
                    }
                };
                say(&format!("Downloading Roblox {version}…"));
                if let Err(e) = crate::update::update_roblox(&upload, &|f, m| {
                    say(&format!("{m} ({:.0}%)", f * 100.0));
                }) {
                    let _ = tx.send(SetupMsg::Finished(Err(e)));
                    return;
                }
            }
            say("Building compatibility libraries…");
            if !session::shim_built() {
                if let Err(e) = session::build_shim() {
                    let _ = tx.send(SetupMsg::Finished(Err(format!("Shim build failed:\n{e}"))));
                    return;
                }
            }
            say("Preparing prefix…");
            if let Err(e) = session::prepare_prefix() {
                let _ = tx.send(SetupMsg::Finished(Err(e)));
                return;
            }
            apply_detected_scale();
            let _ = tx.send(SetupMsg::Finished(Ok("Roblox is ready. Press Enter on Play.".into())));
        });
    }

    fn refresh_logs(&mut self) {
        let dir = paths::logs_dir();
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name().is_some_and(|n| {
                            n.to_string_lossy().starts_with("launch-")
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        files.sort();
        files.reverse();
        self.logs = files.into_iter().take(30).collect();
        if self.logs_state.selected().is_none() && !self.logs.is_empty() {
            self.logs_state.select(Some(0));
        }
    }
}

fn rows() -> Vec<Row> {
    vec![
        Row::Cycle {
            key: "renderer",
            title: "Renderer",
            options: vec![("opengl", "OpenGL"), ("vulkan", "Vulkan (Zink, experimental)")],
        },
        Row::Number {
            key: "dpi_scale",
            title: "Roblox UI scale",
            min: 1.0,
            max: 4.0,
            step: 0.05,
            fmt: "%",
        },
        Row::Number {
            key: "mouse_sensitivity",
            title: "Camera sensitivity",
            min: 0.1,
            max: 5.0,
            step: 0.05,
            fmt: "x",
        },
        Row::Bool { key: "raw_mouse", title: "Raw mouse input", default: true },
        Row::Bool { key: "hide_menu_bar", title: "Hide the macOS menu bar", default: true },
        Row::Bool { key: "mangohud", title: "MangoHud overlay", default: false },
    ]
}

enum Row {
    Cycle { key: &'static str, title: &'static str, options: Vec<(&'static str, &'static str)> },
    Number { key: &'static str, title: &'static str, min: f64, max: f64, step: f64, fmt: &'static str },
    Bool { key: &'static str, title: &'static str, default: bool },
}

impl Row {
    fn describe(&self, settings: &Map<String, Value>) -> String {
        match self {
            Row::Cycle { title, options, key } => {
                let cur = settings.get(*key).and_then(|v| v.as_str()).unwrap_or("");
                let label = options.iter().find(|(v, _)| *v == cur).map(|(_, l)| *l).unwrap_or(cur);
                format!("{title}: {label}")
            }
            Row::Number { title, key, fmt, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_f64()).unwrap_or(0.0);
                if *fmt == "%" {
                    format!("{title}: {:.0}%", v * 100.0)
                } else {
                    format!("{title}: {v:.2}")
                }
            }
            Row::Bool { title, key, default } => {
                let v = settings.get(*key).and_then(|v| v.as_bool()).unwrap_or(*default);
                format!("{title}: {}", if v { "on" } else { "off" })
            }
        }
    }

    fn left(&self, settings: &mut Map<String, Value>) {
        match self {
            Row::Cycle { key, options, .. } => {
                let cur = settings.get(*key).and_then(|v| v.as_str()).unwrap_or("");
                let i = options.iter().position(|(v, _)| *v == cur).unwrap_or(0);
                let next = options[(i + 1) % options.len()].0;
                settings.insert(key.to_string(), Value::from(next));
            }
            Row::Number { key, min, step, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_f64()).unwrap_or(*min);
                settings.insert(key.to_string(), Value::from(((v - step).max(*min) * 100.0).round() / 100.0));
            }
            Row::Bool { key, default, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_bool()).unwrap_or(*default);
                settings.insert(key.to_string(), Value::Bool(!v));
            }
        }
    }

    fn right(&self, settings: &mut Map<String, Value>) {
        match self {
            Row::Cycle { .. } => self.left(settings),
            Row::Number { key, max, step, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_f64()).unwrap_or(*max);
                settings.insert(key.to_string(), Value::from(((v + step).min(*max) * 100.0).round() / 100.0));
            }
            Row::Bool { .. } => self.left(settings),
        }
    }
}

fn run(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    app: &mut App,
) -> Result<()> {
    app.refresh_logs();
    loop {
        app.tick();
        terminal.draw(|f| ui(f, app))?;
        if event::poll(Duration::from_millis(250))? {
            if let Event::Key(key) = event::read()? {
                match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => {
                        if let Some(mut s) = app.session.take() {
                            s.finish();
                        }
                        return Ok(());
                    }
                    KeyCode::Char('1') => app.tab = 0,
                    KeyCode::Char('2') => app.tab = 1,
                    KeyCode::Char('3') => app.tab = 2,
                    KeyCode::Char('4') => app.tab = 3,
                    KeyCode::Char('5') => app.tab = 4,
                    KeyCode::Tab => app.tab = (app.tab + 1) % TABS.len(),
                    KeyCode::Enter => {
                        if app.tab == 0 {
                            app.start_or_stop();
                        } else if app.tab == 1 {
                            rows()[app.settings_cursor].left(&mut app.settings);
                            app.save_settings();
                        } else if app.tab == 4 {
                            app.run_setup();
                        }
                    }
                    KeyCode::Char('e') => {
                        if app.tab == 2 {
                            return edit_flags(terminal, app);
                        }
                    }
                    KeyCode::Up | KeyCode::Char('k') => match app.tab {
                        1 => app.settings_cursor = app.settings_cursor.saturating_sub(1),
                        3 => {
                            let i = app.logs_state.selected().unwrap_or(0);
                            app.logs_state.select(Some(i.saturating_sub(1)));
                        }
                        _ => {}
                    },
                    KeyCode::Down | KeyCode::Char('j') => match app.tab {
                        1 => app.settings_cursor = (app.settings_cursor + 1).min(rows().len() - 1),
                        3 => {
                            let i = app.logs_state.selected().unwrap_or(0);
                            if !app.logs.is_empty() {
                                app.logs_state.select(Some((i + 1).min(app.logs.len() - 1)));
                            }
                        }
                        _ => {}
                    },
                    KeyCode::Left | KeyCode::Char('h') => {
                        if app.tab == 1 {
                            rows()[app.settings_cursor].left(&mut app.settings);
                            app.save_settings();
                        }
                    }
                    KeyCode::Right | KeyCode::Char('l') => {
                        if app.tab == 1 {
                            rows()[app.settings_cursor].right(&mut app.settings);
                            app.save_settings();
                        }
                    }
                    KeyCode::Char('r') => {
                        if app.tab == 3 {
                            app.refresh_logs();
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

fn ui(f: &mut ratatui::Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0), Constraint::Length(3)])
        .split(f.area());

    let tabs = Tabs::new(TABS.to_vec())
        .block(Block::default().borders(Borders::ALL).title("Mac'n Cheese"))
        .select(app.tab)
        .style(Style::default().fg(Color::White))
        .highlight_style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD));
    f.render_widget(tabs, chunks[0]);

    match app.tab {
        0 => render_play(f, app, chunks[1]),
        1 => render_settings(f, app, chunks[1]),
        2 => render_flags(f, app, chunks[1]),
        3 => render_logs(f, app, chunks[1]),
        _ => render_setup(f, app, chunks[1]),
    }

    let hint = match app.tab {
        0 => "Enter: play/stop · 1-5 tabs · q quit",
        1 => "↑↓ move · ←→/Enter change · q quit",
        2 => "e: edit in $EDITOR · q quit",
        3 => "↑↓ pick log · r refresh · q quit",
        _ => "Enter: run setup · q quit",
    };
    let status = Paragraph::new(vec![
        Line::from(Span::styled(app.status.clone(), Style::default().fg(Color::Cyan))),
        Line::from(Span::styled(hint, Style::default().fg(Color::DarkGray))),
    ])
    .block(Block::default().borders(Borders::ALL));
    f.render_widget(status, chunks[2]);
}

fn render_play(f: &mut ratatui::Frame, app: &mut App, area: ratatui::layout::Rect) {
    let running = app.session.is_some();
    let mut lines = vec![
        Line::from(Span::styled(
            if running {
                "● Roblox running"
            } else if app.starting {
                "… starting"
            } else {
                "○ Roblox stopped"
            },
            Style::default().fg(if running { Color::Green } else { Color::White }),
        )),
        Line::from(""),
    ];
    for line in app.log_tail.iter() {
        lines.push(Line::from(Span::styled(line.clone(), Style::default().fg(Color::DarkGray))));
    }
    f.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title("Play")),
        area,
    );
}

fn render_settings(f: &mut ratatui::Frame, app: &mut App, area: ratatui::layout::Rect) {
    let items: Vec<ListItem> = rows()
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let style = if i == app.settings_cursor {
                Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            ListItem::new(Line::from(Span::styled(row.describe(&app.settings), style)))
        })
        .collect();
    f.render_widget(
        List::new(items).block(Block::default().borders(Borders::ALL).title("Settings")),
        area,
    );
}

fn render_flags(f: &mut ratatui::Frame, app: &mut App, area: ratatui::layout::Rect) {
    let flags = crate::flags::load();
    let mut lines = vec![Line::from(Span::styled(
        format!("{} flags · press e to edit in $EDITOR", flags.len()),
        Style::default().fg(Color::DarkGray),
    ))];
    let mut keys: Vec<&String> = flags.keys().collect();
    keys.sort();
    for key in keys.iter().take(60) {
        let value = &flags[*key];
        lines.push(Line::from(format!(
            "{key} = {}",
            value.as_str().unwrap_or("?")
        )));
    }
    f.render_widget(
        Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title("Fast flags")),
        area,
    );
}

fn render_setup(f: &mut ratatui::Frame, app: &mut App, area: ratatui::layout::Rect) {
    let (state, color) = match &app.setup {
        SetupState::Idle => ("Press Enter to check and install Roblox.".to_string(), Color::White),
        SetupState::Running(step) => (format!("… {step}"), Color::Yellow),
        SetupState::Done(msg) => (format!("✓ {msg}"), Color::Green),
        SetupState::Failed(err) => (format!("✗ {err}"), Color::Red),
    };
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(state, Style::default().fg(color))))
            .block(Block::default().borders(Borders::ALL).title("Setup")),
        area,
    );
}

/// Apply the detected desktop scale once (mirrors dpi_scale_auto).
fn apply_detected_scale() {
    let mut settings = settings::load();
    let auto = settings.get("dpi_scale_auto").and_then(|v| v.as_bool()).unwrap_or(true);
    if !auto {
        return;
    }
    let detected = crate::display::validated_dpi_scale(crate::display::detect(&crate::display::Ctx::live()));
    let current = settings.get("dpi_scale").and_then(|v| v.as_f64()).unwrap_or(1.0);
    if (detected - current).abs() > 0.001 {
        settings.insert("dpi_scale".into(), serde_json::Value::from(detected));
        let _ = settings::save(&settings);
    }
}

fn edit_flags<B: ratatui::backend::Backend + std::io::Write>(
    terminal: &mut Terminal<B>,
    app: &mut App,
) -> Result<()> {
    use std::io::Write as _;
    use std::process::Command;
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    let path = crate::flags::flags_file();
    if !path.exists() {
        let _ = crate::flags::save(&crate::flags::load());
    }
    let editor =
        std::env::var("EDITOR").unwrap_or_else(|_| "nano".into());
    let status = Command::new(&editor).arg(&path).status();
    match status {
        Ok(s) if s.success() => match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(v) if v.is_object() => app.status = "Flags saved.".into(),
                _ => app.status = "Invalid JSON: not an object, kept old file.".into(),
            },
            Err(e) => app.status = format!("Could not read flags: {e}"),
        },
        _ => app.status = format!("Editor exited: {editor}"),
    }
    enable_raw_mode()?;
    execute!(terminal.backend_mut(), EnterAlternateScreen)?;
    terminal.clear()?;
    Ok(())
}

fn render_logs(f: &mut ratatui::Frame, app: &mut App, area: ratatui::layout::Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(35), Constraint::Percentage(65)])
        .split(area);
    let items: Vec<ListItem> = app
        .logs
        .iter()
        .map(|p| {
            ListItem::new(Line::from(
                p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            ))
        })
        .collect();
    f.render_stateful_widget(
        List::new(items)
            .block(Block::default().borders(Borders::ALL).title("Logs"))
            .highlight_style(Style::default().fg(Color::Yellow)),
        chunks[0],
        &mut app.logs_state,
    );
    let tail = app
        .logs_state
        .selected()
        .and_then(|i| app.logs.get(i))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|text| {
            let lines: Vec<&str> = text.lines().collect();
            let n = lines.len();
            lines[n.saturating_sub(40)..].join("\n")
        })
        .unwrap_or_default();
    f.render_widget(
        Paragraph::new(tail).block(Block::default().borders(Borders::ALL).title("Tail")),
        chunks[1],
    );
}

#[cfg(test)]
mod tui_tests {
    use super::*;
    use ratatui::backend::TestBackend;

    fn app() -> App {
        App::new()
    }

    #[test]
    fn play_tab_renders_brand_and_status() {
        let mut app = app();
        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| ui(f, &mut app)).unwrap();
        let text: String = terminal.backend().buffer().content().iter().map(|c| c.symbol().to_string()).collect();
        assert!(text.contains("Mac'n Cheese"), "brand missing");
        assert!(text.contains("Roblox stopped"), "status missing");
    }

    #[test]
    fn settings_tab_lists_rows() {
        let mut app = app();
        app.tab = 1;
        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| ui(f, &mut app)).unwrap();
        let text: String = terminal.backend().buffer().content().iter().map(|c| c.symbol().to_string()).collect();
        assert!(text.contains("Renderer"), "renderer row missing");
        assert!(text.contains("Roblox UI scale"), "scale row missing");
    }

    #[test]
    fn rows_mutate_and_validate() {
        let mut settings = settings::load();
        let all = rows();
        all[0].left(&mut settings); // renderer cycles
        assert!(["opengl", "vulkan"].contains(&settings["renderer"].as_str().unwrap()));
        all[1].right(&mut settings); // dpi up
        let dpi = settings["dpi_scale"].as_f64().unwrap();
        assert!((1.0..=4.0).contains(&dpi), "dpi out of range: {dpi}");
    }
}
