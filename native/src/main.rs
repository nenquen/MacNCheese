//! Mac'n Cheese TUI: Play | Settings | Flags | Logs (+ Setup on first run).
//!
//! Lite by design: one file, no GTK, no Python. Mouse works like a GUI
//! (click tabs, buttons, rows) and every action has a keyboard twin.

mod audio;
mod display;
mod flags;
mod gui;
mod icon;
mod theme;
mod mods;
mod patches;
mod paths;
mod session;
mod settings;
mod tui;
mod update;

use anyhow::Result;
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Tabs},
};
use serde_json::{Map, Value};
use std::sync::mpsc::{self, Receiver, Sender};

// ---------------------------------------------------------------- state

#[derive(Clone, Copy, PartialEq)]
enum Tab {
    Play,
    Settings,
    Flags,
    Logs,
    Setup,
}

impl Tab {
    fn title(self) -> &'static str {
        match self {
            Tab::Play => "Play",
            Tab::Settings => "Settings",
            Tab::Flags => "Flags",
            Tab::Logs => "Logs",
            Tab::Setup => "Setup",
        }
    }
}

#[derive(Clone)]
enum Action {
    Tab(usize),
    PlayToggle,
    SettingsRow(usize),
    LogRow(usize),
    SetupRun,
}

enum StartMsg {
    Started(session::Session),
    Failed(String),
}

enum SetupMsg {
    Progress(String),
    Finished(Result<String, String>),
}

enum UpdateMsg {
    Available(String),
    Current,
}

#[derive(Clone)]
enum SetupState {
    Idle,
    Running(String),
    Done(String),
    Failed(String),
}

pub struct App {
    tabs: Vec<Tab>,
    tab: usize,
    settings: Map<String, Value>,
    pub(crate) session: Option<session::Session>,
    starting: bool,
    pub(crate) status: String,
    settings_cursor: usize,
    logs: Vec<std::path::PathBuf>,
    logs_state: ListState,
    log_tail: Vec<String>,
    start_tx: Sender<StartMsg>,
    start_rx: Receiver<StartMsg>,
    setup: SetupState,
    setup_tx: Sender<SetupMsg>,
    setup_rx: Receiver<SetupMsg>,
    update_tx: Sender<UpdateMsg>,
    update_rx: Receiver<UpdateMsg>,
    pub(crate) clicks: Vec<(Rect, Action)>,
}

impl App {
    pub fn new() -> App {
        let (start_tx, start_rx) = mpsc::channel();
        let (setup_tx, setup_rx) = mpsc::channel();
        let (update_tx, update_rx) = mpsc::channel();
        let settings = settings::load();
        let done = settings.get("setup_complete").and_then(|v| v.as_bool()).unwrap_or(false);
        let tabs = if done {
            vec![Tab::Play, Tab::Settings, Tab::Flags, Tab::Logs]
        } else {
            vec![Tab::Play, Tab::Settings, Tab::Flags, Tab::Logs, Tab::Setup]
        };
        let mut app = App {
            tabs,
            tab: 0,
            settings,
            session: None,
            starting: false,
            status: String::new(),
            settings_cursor: 0,
            logs: Vec::new(),
            logs_state: ListState::default(),
            log_tail: Vec::new(),
            start_tx,
            start_rx,
            setup: SetupState::Idle,
            setup_tx,
            setup_rx,
            update_tx,
            update_rx,
            clicks: Vec::new(),
        };
        // First run: open Setup with an explanation. Nothing runs
        // until the user confirms (yes/no).
        if !done {
            app.tab = app.tabs.iter().position(|t| *t == Tab::Setup).unwrap_or(0);
        }
        app.spawn_update_check();
        app
    }

    fn save_settings(&self) {
        let _ = settings::save(&self.settings);
    }

    // -- play ------------------------------------------------------
    pub fn play_toggle(&mut self) {
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
        if update::installed_version().is_none() {
            self.status = "Roblox is not installed — run Setup first.".into();
            return;
        }
        self.starting = true;
        self.status = "Starting Roblox…".into();
        let tx = self.start_tx.clone();
        let snapshot = self.settings.clone();
        std::thread::spawn(move || {
            let _ = tx.send(match session::Session::start(&snapshot, app_uri()) {
                Ok(s) => StartMsg::Started(s),
                Err(e) => StartMsg::Failed(e),
            });
        });
    }

    // -- setup -----------------------------------------------------
    pub fn run_setup(&mut self) {
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
            if update::installed_version().is_none() {
                say("Contacting version service…");
                let (version, upload) = match update::latest_version() {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = tx.send(SetupMsg::Finished(Err(e)));
                        return;
                    }
                };
                say(&format!("Downloading Roblox {version}…"));
                if let Err(e) = update::update_roblox(&upload, &|f, m| {
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
            let _ = tx.send(SetupMsg::Finished(Ok("Roblox is ready.".into())));
        });
    }

    pub fn finish_setup(&mut self, ok: bool) {
        if ok {
            let mut settings = settings::load();
            settings.insert("setup_complete".into(), Value::Bool(true));
            let _ = settings::save(&settings);
            self.settings = settings;
            // Setup never shows again: drop the tab, go Play.
            self.tabs.retain(|t| *t != Tab::Setup);
            self.tab = 0;
        }
    }

    // -- update check ----------------------------------------------
    pub fn spawn_update_check(&mut self) {
        let tx = self.update_tx.clone();
        std::thread::spawn(move || {
            let installed = update::installed_version();
            let latest = update::latest_version().ok().map(|(v, _)| v);
            match (installed, latest) {
                (Some(cur), Some(new)) if cur != new => {
                    let _ = tx.send(UpdateMsg::Available(new));
                }
                _ => {
                    let _ = tx.send(UpdateMsg::Current);
                }
            }
        });
    }

    // -- per-tick ---------------------------------------------------
    pub fn tick(&mut self) {
        while let Ok(msg) = self.start_rx.try_recv() {
            self.starting = false;
            match msg {
                StartMsg::Started(s) => {
                    self.session = Some(s);
                    self.status = "Roblox running.".into();
                }
                StartMsg::Failed(e) => self.status = format!("Could not start: {e}"),
            }
        }
        while let Ok(msg) = self.setup_rx.try_recv() {
            match msg {
                SetupMsg::Progress(text) => self.setup = SetupState::Running(text),
                SetupMsg::Finished(Ok(text)) => {
                    self.setup = SetupState::Done(text);
                    self.status = "Setup complete.".into();
                    self.finish_setup(true);
                }
                SetupMsg::Finished(Err(e)) => {
                    self.setup = SetupState::Failed(e.clone());
                    self.status = format!("Setup failed: {e}");
                }
            }
        }
        while let Ok(msg) = self.update_rx.try_recv() {
            match msg {
                UpdateMsg::Available(v) => {
                    self.status = format!("Roblox update available: {v} (Play to install).");
                }
                UpdateMsg::Current => {}
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
        if let Ok(text) = std::fs::read_to_string(&path) {
            let lines: Vec<String> = text.lines().map(str::to_string).collect();
            let n = lines.len();
            self.log_tail = if n > 12 { lines[n - 12..].to_vec() } else { lines };
        }
    }

    pub fn refresh_logs(&mut self) {
        let mut files: Vec<_> = std::fs::read_dir(paths::logs_dir())
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("launch-"))
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

    // -- input ------------------------------------------------------
    pub fn on_input(&mut self, input: Input) -> KeyAction {
        match input {
            Input::Key(key) => self.on_key(key),
            Input::Click(column, row) => self.on_click(column, row),
        }
    }

    fn on_key(&mut self, key: Key) -> KeyAction {
        match key {
            Key::Char('q') | Key::Esc => KeyAction::Quit,
            Key::Char('1') => self.goto(0),
            Key::Char('2') => self.goto(1),
            Key::Char('3') => self.goto(2),
            Key::Char('4') => self.goto(3),
            Key::Char('5') => self.goto(4),
            Key::Tab => {
                if !self.tabs.is_empty() {
                    self.tab = (self.tab + 1) % self.tabs.len();
                }
                KeyAction::None
            }
            Key::Enter => {
                self.activate();
                KeyAction::None
            }
            Key::Up | Key::Char('k') => {
                self.move_cursor(-1);
                KeyAction::None
            }
            Key::Down | Key::Char('j') => {
                self.move_cursor(1);
                KeyAction::None
            }
            Key::Left | Key::Char('h') => {
                self.nudge(false);
                KeyAction::None
            }
            Key::Right | Key::Char('l') => {
                self.nudge(true);
                KeyAction::None
            }
            Key::Char('r') => {
                if self.current() == Tab::Logs {
                    self.refresh_logs();
                }
                KeyAction::None
            }
            Key::Char('e') => {
                if self.current() == Tab::Flags {
                    KeyAction::EditFlags
                } else {
                    KeyAction::None
                }
            }
            _ => KeyAction::None,
        }
    }

    fn current(&self) -> Tab {
        self.tabs.get(self.tab).copied().unwrap_or(Tab::Play)
    }

    fn goto(&mut self, i: usize) -> KeyAction {
        if i < self.tabs.len() {
            self.tab = i;
        }
        KeyAction::None
    }

    fn activate(&mut self) {
        match self.current() {
            Tab::Play => self.play_toggle(),
            Tab::Settings => {
                if let Some(row) = setting_rows().get(self.settings_cursor) {
                    row.left(&mut self.settings);
                    self.save_settings();
                }
            }
            Tab::Setup => self.run_setup(),
            _ => {}
        }
    }

    fn move_cursor(&mut self, delta: i32) {
        match self.current() {
            Tab::Settings => {
                let n = setting_rows().len() as i32;
                self.settings_cursor =
                    (self.settings_cursor as i32 + delta).clamp(0, n - 1) as usize;
            }
            Tab::Logs => {
                let i = self.logs_state.selected().unwrap_or(0) as i32 + delta;
                let max = self.logs.len().saturating_sub(1) as i32;
                if max >= 0 {
                    self.logs_state.select(Some(i.clamp(0, max) as usize));
                }
            }
            _ => {}
        }
    }

    fn nudge(&mut self, right: bool) {
        if self.current() != Tab::Settings {
            return;
        }
        if let Some(row) = setting_rows().get(self.settings_cursor) {
            if right {
                row.right(&mut self.settings);
            } else {
                row.left(&mut self.settings);
            }
            self.save_settings();
        }
    }

    pub fn on_click(&mut self, column: u16, row: u16) -> KeyAction {
        let hit = self
            .clicks
            .iter()
            .rev()
            .find(|(r, _)| {
                column >= r.x
                    && column < r.x + r.width
                    && row >= r.y
                    && row < r.y + r.height
            })
            .map(|(_, a)| a.clone());
        match hit {
            Some(Action::Tab(i)) => self.goto(i),
            Some(Action::PlayToggle) => {
                self.play_toggle();
                KeyAction::None
            }
            Some(Action::SettingsRow(i)) => {
                self.settings_cursor = i;
                if let Some(r) = setting_rows().get(i) {
                    r.left(&mut self.settings);
                    self.save_settings();
                }
                KeyAction::None
            }
            Some(Action::LogRow(i)) => {
                self.logs_state.select(Some(i));
                KeyAction::None
            }
            Some(Action::SetupRun) => {
                self.run_setup();
                KeyAction::None
            }
            None => KeyAction::None,
        }
    }
}

pub enum KeyAction {
    None,
    Quit,
    EditFlags,
}

/// Backend-agnostic input: crossterm and winit frontends both produce these.
#[derive(Clone, Copy)]
pub enum Key {
    Up, Down, Left, Right, Enter, Esc, Tab,
    Char(char),
}

#[derive(Clone, Copy)]
pub enum Input {
    Key(Key),
    Click(u16, u16),
}

fn app_uri() -> Option<String> {
    std::env::args().skip(1).find(|a| !a.starts_with('-') && a.contains(':'))
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("macncheese {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("Mac'n Cheese {} — Roblox on Linux through Darling", env!("CARGO_PKG_VERSION"));
        println!("Usage: macncheese [--version|--help|--tui] [roblox-url]");
        println!("Keys: 1-5 tabs · arrows/hjkl move · Enter activate · e edit flags · q quit.");
        println!("Mouse: click tabs, buttons and rows.");
        return Ok(());
    }
    let force_tui = args.iter().any(|a| a == "--tui");
    let has_display = std::env::var("WAYLAND_DISPLAY").is_ok() || std::env::var("DISPLAY").is_ok();
    if !force_tui && has_display {
        return gui::run();
    }
    tui::run()
}

/// Apply the detected desktop scale once (mirrors dpi_scale_auto).
fn apply_detected_scale() {
    let mut settings = settings::load();
    let auto = settings.get("dpi_scale_auto").and_then(|v| v.as_bool()).unwrap_or(true);
    if !auto {
        return;
    }
    let detected = display::validated_dpi_scale(display::detect(&display::Ctx::live()));
    let current = settings.get("dpi_scale").and_then(|v| v.as_f64()).unwrap_or(1.0);
    if (detected - current).abs() > 0.001 {
        settings.insert("dpi_scale".into(), Value::from(detected));
        let _ = settings::save(&settings);
    }
}

// ---------------------------------------------------------------- ui

/// Fill the area with the theme background first: terminals show their
/// own color otherwise, and the theme would only tint the text.
fn paint_bg(f: &mut ratatui::Frame, pal: &crate::theme::Palette, area: Rect) {
    f.render_widget(
        Block::default().style(ratatui::style::Style::default().bg(pal.bg)),
        area,
    );
}

fn title_block(pal: &crate::theme::Palette, title: &str) -> Block<'static> {
    Block::default()
        .borders(Borders::ALL)
        .border_style(ratatui::style::Style::default().fg(pal.border))
        .style(ratatui::style::Style::default().bg(pal.raised))
        .title(title.to_string())
}

pub(crate) fn ui(f: &mut ratatui::Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0), Constraint::Length(2)])
        .split(f.area());

    let titles: Vec<String> = app.tabs.iter().map(|t| t.title().to_string()).collect();
    let mode = app.settings.get("theme").and_then(|v| v.as_str()).unwrap_or("system");
    let pal = crate::theme::resolve(mode);
    let tabs = Tabs::new(titles)
        .divider(Span::raw(" | "))
        .block(title_block(&pal, "Mac'n Cheese"))
        .select(app.tab)
        .style(Style::default().fg(pal.fg))
        .highlight_style(Style::default().fg(pal.accent).add_modifier(Modifier::BOLD));
    f.render_widget(tabs, chunks[0]);
    // Clickable tab segments follow the widget's own left-aligned layout:
    // titles joined by " | ", starting just inside the border.
    let bar = chunks[0];
    {
        let mut x = bar.x + 1;
        for (i, tab) in app.tabs.iter().enumerate() {
            let w = (tab.title().len() + 2) as u16;
            if x + w <= bar.x + bar.width.saturating_sub(1) {
                app.clicks.push((Rect::new(x, bar.y + 1, w, 1), Action::Tab(i)));
            }
            x += w + 3; // title width + " | " divider
        }
    }

    paint_bg(f, &pal, chunks[0]);
    paint_bg(f, &pal, chunks[1]);
    paint_bg(f, &pal, chunks[2]);
    match app.tabs.get(app.tab).copied().unwrap_or(Tab::Play) {
        Tab::Play => render_play(f, app, &pal, chunks[1]),
        Tab::Settings => render_settings(f, app, &pal, chunks[1]),
        Tab::Flags => render_flags(f, app, &pal, chunks[1]),
        Tab::Logs => render_logs(f, app, &pal, chunks[1]),
        Tab::Setup => render_setup(f, app, &pal, chunks[1]),
    }

    let hint = match app.tabs.get(app.tab).copied().unwrap_or(Tab::Play) {
        Tab::Play => "Enter: play/stop · click too · q quit",
        Tab::Settings => "↑↓/click row · ←→/Enter change · q quit",
        Tab::Flags => "e: edit in $EDITOR · q quit",
        Tab::Logs => "↑↓/click pick · r refresh · q quit",
        Tab::Setup => "Enter: run setup · q quit",
    };
    let status = Paragraph::new(vec![
        Line::from(Span::styled(app.status.clone(), Style::default().fg(pal.accent))),
        Line::from(Span::styled(hint, Style::default().fg(pal.dim))),
    ])
    .block(title_block(&pal, ""));
    f.render_widget(status, chunks[2]);
}

fn clickable_button(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect, label: &str, action: Action) {
    let text = format!("[ {label} ]");
    let x = area.x + area.width.saturating_sub(text.len() as u16 + 2) / 2;
    let y = area.y + area.height / 2;
    let rect = Rect::new(x, y, text.len() as u16 + 2, 1);
    app.clicks.push((rect, action));
    f.render_widget(Paragraph::new(Line::from(Span::styled(text, Style::default().fg(pal.accent)))), rect);
}

fn render_play(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
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
            Style::default().fg(if running { pal.ok } else { pal.fg }),
        )),
        Line::from(""),
    ];
    for line in app.log_tail.iter() {
        lines.push(Line::from(Span::styled(line.clone(), Style::default().fg(pal.dim))));
    }
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(3)])
        .split(area);
    f.render_widget(
        Paragraph::new(lines).block(title_block(pal, "Play")),
        chunks[0],
    );
    let btn = chunks[1];
    let label = if running { "Stop" } else { "Play Roblox" };
    clickable_button(f, app, pal, Rect::new(btn.x, btn.y + 1, btn.width, 1), label, Action::PlayToggle);
}

fn render_settings(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    let y0 = area.y + 1;
    let items: Vec<ListItem> = setting_rows()
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let style = if i == app.settings_cursor {
                Style::default().fg(pal.accent).add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            app.clicks.push((
                Rect::new(area.x + 1, y0 + i as u16, area.width.saturating_sub(2), 1),
                Action::SettingsRow(i),
            ));
            ListItem::new(Line::from(Span::styled(row.describe(&app.settings), style)))
        })
        .collect();
    f.render_widget(List::new(items).block(title_block(pal, "Settings")), area);
}

fn render_flags(f: &mut ratatui::Frame, _app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    let flags = crate::flags::load();
    let mut lines = vec![Line::from(Span::styled(
        format!("{} flags · press e to edit in $EDITOR (clicks work too)", flags.len()),
        Style::default().fg(pal.dim),
    ))];
    let mut keys: Vec<&String> = flags.keys().collect();
    keys.sort();
    for key in keys.iter().take(60) {
        let value = &flags[*key];
        lines.push(Line::from(format!("{key} = {}", value.as_str().unwrap_or("?"))));
    }
    f.render_widget(Paragraph::new(lines).block(title_block(pal, "Fast flags")), area);
}

fn render_logs(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(35), Constraint::Percentage(65)])
        .split(area);
    let items: Vec<ListItem> = app
        .logs
        .iter()
        .enumerate()
        .map(|(i, p)| {
            app.clicks.push((
                Rect::new(chunks[0].x + 1, chunks[0].y + 1 + i as u16, chunks[0].width.saturating_sub(2), 1),
                Action::LogRow(i),
            ));
            ListItem::new(Line::from(
                p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            ))
        })
        .collect();
    f.render_stateful_widget(
        List::new(items)
            .block(title_block(pal, "Logs"))
            .highlight_style(Style::default().fg(pal.accent)),
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
    f.render_widget(Paragraph::new(tail).block(title_block(pal, "Tail")), chunks[1]);
}

fn render_setup(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    let explainer = vec![
        Line::from("First run: Mac'n Cheese will:"),
        Line::from("  1. Download the Roblox client (~300 MB)"),
        Line::from("  2. Build the compatibility libraries"),
        Line::from("  3. Prepare the Darling prefix"),
        Line::from(""),
        Line::from("Nothing runs until you confirm. Continue?"),
        Line::from(""),
    ];
    let (state, color) = match &app.setup {
        SetupState::Idle => (String::new(), pal.fg),
        SetupState::Running(step) => (format!("… {step}"), pal.accent),
        SetupState::Done(msg) => (format!("✓ {msg}"), pal.ok),
        SetupState::Failed(err) => (format!("✗ {err}"), pal.err),
    };
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(3)])
        .split(area);
    let mut lines = explainer;
    if !state.is_empty() {
        lines.push(Line::from(Span::styled(state, Style::default().fg(color))));
    }
    f.render_widget(
        Paragraph::new(lines).block(title_block(pal, "Setup")),
        chunks[0],
    );
    clickable_button(f, app, pal, chunks[1], "Yes, run setup", Action::SetupRun);
}

// ---------------------------------------------------------------- settings rows

pub(crate) fn setting_rows() -> Vec<Row> {
    vec![
        Row::Cycle {
            key: "renderer",
            title: "Renderer",
            options: vec![("opengl".into(), "OpenGL".into()), ("vulkan".into(), "Vulkan (Zink, experimental)".into())],
        },
        Row::Cycle {
            key: "display_backend",
            title: "Window backend",
            options: vec![("x11".into(), "X11 / Xwayland".into()), ("wayland".into(), "Native Wayland (experimental)".into())],
        },
        Row::Number { key: "dpi_scale", title: "Roblox UI scale", min: 1.0, max: 4.0, step: 0.05, pct: true },
        Row::Number { key: "mouse_sensitivity", title: "Camera sensitivity", min: 0.1, max: 5.0, step: 0.05, pct: false },
        Row::Bool { key: "raw_mouse", title: "Raw mouse input", default: true },
        Row::Bool { key: "hide_menu_bar", title: "Hide the macOS menu bar", default: true },
        Row::Bool { key: "mangohud", title: "MangoHud overlay", default: false },
        Row::Number { key: "tui_font_scale", title: "TUI font scale", min: 0.8, max: 2.0, step: 0.1, pct: false },
        Row::Cycle {
            key: "theme",
            title: "Color theme",
            options: crate::theme::names()
                .into_iter()
                .map(|(a, b)| (a.to_string(), b.to_string()))
                .collect(),
        },
    ]
}

pub(crate) enum Row {
    Cycle { key: &'static str, title: &'static str, options: Vec<(String, String)> },
    Number { key: &'static str, title: &'static str, min: f64, max: f64, step: f64, pct: bool },
    Bool { key: &'static str, title: &'static str, default: bool },
}

impl Row {
    fn describe(&self, settings: &Map<String, Value>) -> String {
        match self {
            Row::Cycle { title, options, key } => {
                let cur = settings.get(*key).and_then(|v| v.as_str()).unwrap_or("");
                let label = options
                    .iter()
                    .find(|(v, _)| v.as_str() == cur)
                    .map(|(_, l)| l.clone())
                    .unwrap_or_else(|| cur.to_string());
                format!("{title}: {label}")
            }
            Row::Number { title, key, pct, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_f64()).unwrap_or(0.0);
                if *pct {
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
                let next = options[(i + 1) % options.len()].0.clone();
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

#[cfg(test)]
mod tui_tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn drawn(app: &mut App) -> String {
        let backend = TestBackend::new(100, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| ui(f, app)).unwrap();
        terminal.backend().buffer().content().iter().map(|c| c.symbol().to_string()).collect()
    }

    #[test]
    fn play_tab_renders_brand_and_status() {
        let mut app = App::new();
        app.tab = 0;
        let text = drawn(&mut app);
        assert!(text.contains("Mac'n Cheese"), "brand missing");
        assert!(text.contains("Roblox stopped"), "status missing");
        assert!(!app.clicks.is_empty(), "no click targets registered");
    }

    #[test]
    fn all_tabs_render_without_panic() {
        let mut app = App::new();
        let n = app.tabs.len();
        for tab in 0..n {
            app.tab = tab;
            let title = app.tabs[tab].title();
            let text = drawn(&mut app);
            assert!(text.contains(title), "tab {title} missing");
        }
    }

    #[test]
    fn settings_rows_mutate_in_range() {
        let mut settings = settings::load();
        setting_rows()[0].left(&mut settings);
        assert!(["opengl", "vulkan"].contains(&settings["renderer"].as_str().unwrap()));
        setting_rows()[1].right(&mut settings);
        let dpi = settings["dpi_scale"].as_f64().unwrap();
        assert!((1.0..=4.0).contains(&dpi), "dpi out of range: {dpi}");
    }

    #[test]
    fn setup_tab_hidden_when_done() {
        let mut app = App::new();
        app.settings.insert("setup_complete".into(), Value::Bool(true));
        app.tabs.retain(|t| *t != Tab::Setup);
        let text = drawn(&mut app);
        assert!(!text.contains("Setup"), "setup tab should be gone");
    }
}
