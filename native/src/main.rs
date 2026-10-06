//! Mac'n Cheese TUI: Play | Settings | Flags | Logs (+ Setup while the
//! Roblox client is missing, Sober-style onboarding).
//!
//! Lite by design: one file, no GTK, no Python. Mouse works like a GUI
//! (click tabs, buttons, rows) and every action has a keyboard twin.

mod audio;
mod desktop_entry;
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
    /// Label half of a settings row: select it.
    SettingsRow(usize),
    /// Value half of a settings row: select and cycle forward.
    SettingsValue(usize),
    FlagRow(usize),
    LogRow(usize),
    SetupRun,
    AddFlag,
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
    tail_follow: bool,
    flags_cursor: usize,
    flags_state: ListState,
    flag_edit: Option<FlagEdit>,
    tail_scroll: u16,
    tail_max: usize,
    start_tx: Sender<StartMsg>,
    start_rx: Receiver<StartMsg>,
    setup: SetupState,
    setup_tx: Sender<SetupMsg>,
    setup_rx: Receiver<SetupMsg>,
    update_tx: Sender<UpdateMsg>,
    update_rx: Receiver<UpdateMsg>,
    pub(crate) clicks: Vec<(Rect, Action)>,
}

#[derive(Clone)]
enum FlagRow {
    Custom { key: String, value: String },
}

#[derive(Clone, Copy, PartialEq)]
enum EditStage {
    Name,
    Value,
}

struct FlagEdit {
    stage: EditStage,
    name: String,
    buf: String,
}

impl FlagEdit {
    fn name() -> FlagEdit {
        FlagEdit { stage: EditStage::Name, name: String::new(), buf: String::new() }
    }

    fn value(name: String, current: String) -> FlagEdit {
        FlagEdit { stage: EditStage::Value, name, buf: current }
    }
}

enum EditDone {
    Cancel,
    Pending,
    Name(String),
    Save(String, String),
}

impl FlagEdit {
    fn key(&mut self, key: Key) -> EditDone {
        match key {
            Key::Esc => EditDone::Cancel,
            Key::Enter => match self.stage {
                EditStage::Name => EditDone::Name(std::mem::take(&mut self.buf)),
                EditStage::Value => {
                    EditDone::Save(std::mem::take(&mut self.name), std::mem::take(&mut self.buf))
                }
            },
            Key::Backspace => {
                self.buf.pop();
                EditDone::Pending
            }
            Key::Char(c) => {
                if !c.is_control() {
                    self.buf.push(c);
                }
                EditDone::Pending
            }
            _ => EditDone::Pending,
        }
    }
}

impl App {
    pub fn new() -> App {
        let (start_tx, start_rx) = mpsc::channel();
        let (setup_tx, setup_rx) = mpsc::channel();
        let (update_tx, update_rx) = mpsc::channel();
        let settings = settings::load();
        let needed = Self::setup_needed(&settings);
        let mut app = App {
            tabs: vec![Tab::Play, Tab::Settings, Tab::Flags],
            tab: 0,
            settings,
            session: None,
            starting: false,
            status: String::new(),
            settings_cursor: 0,
            logs: Vec::new(),
            logs_state: ListState::default(),
            log_tail: Vec::new(),
            tail_follow: true,
            flags_cursor: 0,
            flags_state: ListState::default(),
            flag_edit: None,
            tail_scroll: 0,
            tail_max: 0,
            start_tx,
            start_rx,
            setup: SetupState::Idle,
            setup_tx,
            setup_rx,
            update_tx,
            update_rx,
            clicks: Vec::new(),
        };
        // Adds Logs (debug) and Setup (missing client), in that order.
        app.sync_tabs();
        // Open Setup when consent is missing or the client isn't on
        // disk — Sober-style, prompt until Roblox is present.
        if needed {
            app.tab = app.tabs.iter().position(|t| *t == Tab::Setup).unwrap_or(0);
        }
        app.spawn_update_check();
        app
    }

    /// Setup shows until the user consented AND the client is on disk;
    /// a missing Roblox always brings the tab back.
    fn setup_needed(settings: &Map<String, Value>) -> bool {
        let consent = settings
            .get("setup_complete")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        !consent || update::installed_version().is_none()
    }

    /// Keep the tab list in sync with the client state (setup finished)
    /// and the debug flag (Logs visibility).
    fn sync_tabs(&mut self) {
        let needed = Self::setup_needed(&self.settings);
        let want_logs = self
            .settings
            .get("debug")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if needed && !self.tabs.contains(&Tab::Setup) {
            self.tabs.push(Tab::Setup);
        }
        if want_logs && !self.tabs.contains(&Tab::Logs) {
            let at = self
                .tabs
                .iter()
                .position(|t| *t == Tab::Setup)
                .unwrap_or(self.tabs.len());
            self.tabs.insert(at, Tab::Logs);
        }
        // Drop what is no longer wanted, keeping the selection sane.
        for gone in [Tab::Logs, Tab::Setup] {
            let wanted = match gone {
                Tab::Logs => want_logs,
                Tab::Setup => needed,
                _ => true,
            };
            if wanted {
                continue;
            }
            if let Some(idx) = self.tabs.iter().position(|t| *t == gone) {
                self.tabs.remove(idx);
                if self.tab == idx {
                    self.tab = 0; // was viewing it: back to Play
                } else if self.tab > idx {
                    self.tab -= 1;
                }
                if self.tab >= self.tabs.len() {
                    self.tab = 0;
                }
            }
        }
    }

    fn save_settings(&mut self) {
        let _ = settings::save(&self.settings);
        // Toggling debug must show/hide the Logs tab right away.
        self.sync_tabs();
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
            // Jump to Setup (it is always listed while the client is
            // missing), the same prompt-when-absent flow Sober uses.
            if let Some(i) = self.tabs.iter().position(|t| *t == Tab::Setup) {
                self.tab = i;
            }
            return;
        }
        self.starting = true;
        self.status = "Starting Roblox…".into();
        let tx = self.start_tx.clone();
        let snapshot = self.settings.clone();
        std::thread::spawn(move || {
            let _ = tx.send(match session::Session::start(&snapshot, app_uri()) {
                Ok(s) => StartMsg::Started(s),
                Err(e) => {
                    session::log_line(&format!("start failed: {e}"));
                    StartMsg::Failed(e)
                }
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
            self.tab = 0;
        }
        // Setup disappears once consented + installed, and reappears
        // any time the client goes missing.
        self.sync_tabs();
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
            Input::WheelUp => {
                self.wheel(-1);
                KeyAction::None
            }
            Input::WheelDown => {
                self.wheel(1);
                KeyAction::None
            }
        }
    }

    /// Mouse wheel: lists move, log tail scrolls (down = newer).
    fn wheel(&mut self, delta: i32) {
        match self.current() {
            Tab::Settings => self.move_cursor(delta),
            Tab::Flags => self.move_cursor(delta * 3),
            Tab::Logs => self.scroll_tail(delta * 10),
            _ => {}
        }
    }

    fn scroll_tail(&mut self, delta: i32) {
        let max = self.tail_max as i32;
        let next = (self.tail_scroll as i32 + delta).clamp(0, max);
        self.tail_scroll = next as u16;
        self.tail_follow = next >= max;
    }

    fn on_key(&mut self, key: Key) -> KeyAction {
        if self.flag_edit.is_some() {
            return self.edit_key(key);
        }
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
            Key::Char('a') => {
                if self.current() == Tab::Flags {
                    self.flag_edit = Some(FlagEdit::name());
                }
                KeyAction::None
            }
            Key::Char('d') => {
                if self.current() == Tab::Flags {
                    self.delete_flag();
                }
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
            Key::PageUp => {
                match self.current() {
                    Tab::Settings => self.jump_section(-1),
                    Tab::Logs => self.scroll_tail(-10),
                    _ => {}
                }
                KeyAction::None
            }
            Key::PageDown => {
                match self.current() {
                    Tab::Settings => self.jump_section(1),
                    Tab::Logs => self.scroll_tail(10),
                    _ => {}
                }
                KeyAction::None
            }
            Key::Backspace => {
                if self.current() == Tab::Settings {
                    self.reset_setting();
                }
                KeyAction::None
            }
            Key::Char('e') => {
                if self.current() == Tab::Flags {
                    self.begin_edit_value();
                }
                KeyAction::None
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
                    row.right(&mut self.settings);
                    self.save_settings();
                }
            }
            Tab::Setup => self.run_setup(),
            Tab::Flags => self.activate_flag(),
            _ => {}
        }
    }

    /// Transport flags the app enforces itself; hidden from the list.
    fn managed_keys() -> Vec<&'static str> {
        vec![
            "FFlagUseRbxTransportClient", "FFlagUseRbxTransportClient3",
            "FFlagUseRbxTransportServer", "FFlagShareRbxTransport",
            "FFlagRbxTransportRuntime", "DFFlagDebugDisableRbxTransportDummyClient",
            "FFlagDebugDisableRbxTransportDummyClient",
            "FStringRbxTransportDummyClientEnabledMinorVersions",
            "FStringRbxTransportDummyClientEnabledMinorVersions_PlaceFilter",
            "DFIntRbxTransportDummyClientConnectionTimeoutMs",
            "DFIntRbxTransportQuicHandshakeTimeoutMs", "DFFlagEnablePopLatencyProbe3",
            "DFFlagAttachPopUdpProbeToGameJoin2", "DFFlagRakNetFallbackToRbxTransportEvent",
            "DFFlagRakNetFallbackToRbxTransportStatus", "DFFlagConnectDummyServiceClientEarly",
            "DFIntRbxTransportClientConnectionWaitIntervalMs", "DFFlagHttpLocalThrottle",
            "FFlagHttpLocalThrottle", "DFIntHttpMaxRetries", "DFIntHttpMaxRetryAfterSec",
            "DFIntHttpRbxApiMaxThrottledQueueSize", "DFIntHttpRetryAndLocalThrottleJitterMaxPercent",
            "DFFlagDebugSlimLoaderDisableHTTPRetry", "FFlagDebugSlimLoaderDisableHTTPRetry",
            "DFIntBatchThumbnailMaxWaitMs", "DFIntBatchThumbnailMinWaitMs",
            "DFIntBatchThumbnailExponentialInitialWaitMs", "DFIntBatchThumbnailMaxExponentialRetries",
            "DFIntBatchThumbnailAllowedExternalTimedOutRetries",
            "DFIntLuaAppThumbnailsApiRetryTimeMultiplier",
        ]
    }

    fn custom_flags(&self) -> Vec<(String, String)> {
        // No built-in presets: users research and add their own flags.
        // Transport flags are enforced automatically and hidden here.
        let flags = crate::flags::load();
        let managed = Self::managed_keys();
        let mut out: Vec<(String, String)> = flags
            .iter()
            .filter(|(k, _)| !managed.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), crate::flags::display_value(v)))
            .collect();
        out.sort();
        out
    }

    /// Selectable rows: user customs only.
    fn flag_rows(&self) -> Vec<FlagRow> {
        self.custom_flags()
            .into_iter()
            .map(|(key, value)| FlagRow::Custom { key, value })
            .collect()
    }

    fn save_flag(&self, key: &str, raw: &str) {
        let mut flags = crate::flags::load();
        // Keep the file's existing convention (this client historically
        // stores strings); new keys get typed values.
        let value = match flags.get(key) {
            Some(Value::String(_)) => Value::from(raw.trim()),
            _ => crate::flags::parse_value(raw),
        };
        flags.insert(key.to_string(), value);
        let _ = crate::flags::save(&flags);
    }

    fn activate_flag(&mut self) {
        let rows = self.flag_rows();
        match rows.get(self.flags_cursor) {
            Some(FlagRow::Custom { key, value }) => {
                self.flag_edit = Some(FlagEdit::value(key.clone(), value.clone()));
            }
            None => {}
        }
    }

    fn begin_edit_value(&mut self) {
        match self.flag_rows().get(self.flags_cursor) {
            Some(FlagRow::Custom { key, value }) => {
                self.flag_edit = Some(FlagEdit::value(key.clone(), value.clone()));
            }
            _ => self.activate_flag(),
        }
    }

    fn delete_flag(&mut self) {
        if let Some(FlagRow::Custom { key, .. }) = self.flag_rows().get(self.flags_cursor) {
            let mut flags = crate::flags::load();
            let key = key.clone();
            flags.remove(&key);
            let _ = crate::flags::save(&flags);
            self.status = format!("Removed {key}.");
        }
    }

    fn edit_key(&mut self, key: Key) -> KeyAction {
        let done = match self.flag_edit.as_mut() {
            Some(ed) => ed.key(key),
            None => EditDone::Cancel,
        };
        match done {
            EditDone::Cancel => self.flag_edit = None,
            EditDone::Pending => {}
            EditDone::Name(name) => {
                if name.is_empty() {
                    self.flag_edit = None;
                } else {
                    self.flag_edit = Some(FlagEdit::value(name, String::new()));
                }
            }
            EditDone::Save(name, value) => {
                self.flag_edit = None;
                if !name.is_empty() {
                    self.save_flag(&name, &value);
                    self.status = format!("Saved {name}.");
                }
            }
        }
        KeyAction::None
    }

    fn move_cursor(&mut self, delta: i32) {
        match self.current() {
            Tab::Settings => {
                let n = setting_rows().len() as i32;
                self.settings_cursor =
                    (self.settings_cursor as i32 + delta).clamp(0, n - 1) as usize;
            }
            Tab::Flags => {
                let n = self.flag_rows().len() as i32;
                if n > 0 {
                    self.flags_cursor = (self.flags_cursor as i32 + delta).clamp(0, n - 1) as usize;
                    self.flags_state.select(Some(self.flags_cursor));
                }
            }
            Tab::Logs => {
                let i = self.logs_state.selected().unwrap_or(0) as i32 + delta;
                let max = self.logs.len().saturating_sub(1) as i32;
                if max >= 0 {
                    self.logs_state.select(Some(i.clamp(0, max) as usize));
                    self.tail_follow = true;
                }
            }
            _ => {}
        }
    }

    fn nudge(&mut self, right: bool) {
        if self.current() == Tab::Logs {
            self.scroll_tail(if right { 10 } else { -10 });
            return;
        }
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

    /// PgUp/PgDn: jump between settings sections.
    fn jump_section(&mut self, dir: i32) {
        let starts = section_starts();
        if starts.is_empty() {
            return;
        }
        let cur = self.settings_cursor as usize;
        let current = starts.iter().rposition(|&s| s <= cur).unwrap_or(0);
        if dir < 0 {
            // PgUp: this section's start first, then the previous one.
            self.settings_cursor = if cur > starts[current] {
                starts[current]
            } else if current > 0 {
                starts[current - 1]
            } else {
                0
            };
        } else {
            // PgDn: the next section's start, else the end of the list.
            let next = current + 1;
            self.settings_cursor = if next < starts.len() {
                starts[next]
            } else {
                setting_rows().len().saturating_sub(1)
            };
        }
    }

    /// Backspace: restore the selected row's default.
    fn reset_setting(&mut self) {
        if let Some(row) = setting_rows().get(self.settings_cursor) {
            row.reset(&mut self.settings);
            self.save_settings();
            self.status = format!("{} reset to default.", row.title());
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
                KeyAction::None
            }
            Some(Action::SettingsValue(i)) => {
                self.settings_cursor = i;
                if let Some(r) = setting_rows().get(i) {
                    r.right(&mut self.settings);
                    self.save_settings();
                }
                KeyAction::None
            }
            Some(Action::LogRow(i)) => {
                self.logs_state.select(Some(i));
                self.tail_follow = true;
                KeyAction::None
            }
            Some(Action::FlagRow(i)) => {
                self.flags_cursor = i;
                self.flags_state.select(Some(i));
                self.activate_flag();
                KeyAction::None
            }
            Some(Action::AddFlag) => {
                self.flag_edit = Some(FlagEdit::name());
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
}

/// Backend-agnostic input: crossterm and winit frontends both produce these.
#[derive(Clone, Copy)]
pub enum Key {
    Up, Down, Left, Right, Enter, Esc, Tab, PageUp, PageDown, Backspace,
    Char(char),
}

#[derive(Clone, Copy)]
pub enum Input {
    Key(Key),
    Click(u16, u16),
    WheelUp,
    WheelDown,
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
        println!("Usage: macncheese [--version|--help|--check|--tui] [roblox-url]");
        println!("Keys: number keys switch tabs · arrows/hjkl move · Enter activate · e edit flags · q quit.");
        println!("Mouse: click tabs, buttons and rows.");
        return Ok(());
    }
    if args.iter().any(|a| a == "--check") {
        // Environment self-diagnosis: what a launch would rely on.
        println!("client        : {}", update::installed_version().unwrap_or_else(|| "NOT INSTALLED".into()));
        println!("prebuilt env  : {:?}", std::env::var("MACNCHEESE_PREBUILT_SHIM"));
        println!("shim dylib    : {}", paths::shim().display());
        println!("  is_file     : {}", paths::shim().is_file());
        println!("frameworks    : {}", paths::frameworks_build().display());
        println!("shim_built    : {}", session::shim_built());
        let missing = session::missing_tools();
        println!(
            "missing tools : {}",
            if missing.is_empty() { "none".into() } else { missing.join(", ") }
        );
        println!("darling prefix: {}", paths::darling_prefix().display());
        println!(
            "  exists      : {}",
            paths::darling_prefix().is_dir()
        );
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
        .style(ratatui::style::Style::default().bg(pal.bg))
        .title(if title.is_empty() {
            String::new()
        } else {
            format!(" {title} ")
        })
}

pub(crate) fn ui(f: &mut ratatui::Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0)])
        .split(f.area());

    let titles: Vec<String> = app
        .tabs
        .iter()
        .enumerate()
        .map(|(i, t)| {
            if i == 0 {
                format!(" {}", t.title())
            } else {
                t.title().to_string()
            }
        })
        .collect();
    let mode = app.settings.get("theme").and_then(|v| v.as_str()).unwrap_or("cheese");
    let pal = crate::theme::resolve(mode);
    let tabs = Tabs::new(titles.clone())
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
        for (i, title) in titles.iter().enumerate() {
            let w = (title.len() + 2) as u16;
            if x + w <= bar.x + bar.width.saturating_sub(1) {
                app.clicks.push((Rect::new(x, bar.y + 1, w, 1), Action::Tab(i)));
            }
            x += w + 3; // title width + " | " divider
        }
    }

    paint_bg(f, &pal, chunks[0]);
    paint_bg(f, &pal, chunks[1]);
    match app.tabs.get(app.tab).copied().unwrap_or(Tab::Play) {
        Tab::Play => render_play(f, app, &pal, chunks[1]),
        Tab::Settings => render_settings(f, app, &pal, chunks[1]),
        Tab::Flags => render_flags(f, app, &pal, chunks[1]),
        Tab::Logs => render_logs(f, app, &pal, chunks[1]),
        Tab::Setup => render_setup(f, app, &pal, chunks[1]),
    }
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
    ];
    if !app.status.is_empty() {
        lines.push(Line::from(Span::styled(app.status.clone(), Style::default().fg(pal.accent))));
    }
    lines.push(Line::from(""));
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

/// Key + description pairs rendered as ` {key}{sep}{desc}  `.
fn hint_line(pal: &crate::theme::Palette, parts: &[(&str, &str)], sep: &str) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    for (key, desc) in parts {
        spans.push(Span::styled(
            format!(" {key}"),
            Style::default().fg(pal.accent).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(
            format!("{sep}{desc}  "),
            Style::default().fg(pal.dim),
        ));
    }
    Line::from(spans)
}

fn render_settings(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(4), Constraint::Length(5)])
        .split(area);

    // -- grouped rows: section headers, then two-column entries -------
    let inner_w = chunks[0].width.saturating_sub(2) as usize;
    let sel_style = Style::default()
        .fg(pal.bg)
        .bg(pal.accent)
        .add_modifier(Modifier::BOLD);
    let mut items: Vec<ListItem> = Vec::new();
    let mut index = 0usize;
    for section in setting_sections() {
        items.push(ListItem::new(Line::from(Span::styled(
            format!("\u{25b8} {}", section.title),
            Style::default().fg(pal.accent).add_modifier(Modifier::BOLD),
        ))));
        for row in &section.rows {
            let value = row.value_text(&app.settings);
            let label = format!("  {}", row.title());
            let pad = inner_w.saturating_sub(value.chars().count());
            let line = if index == app.settings_cursor {
                // One full-width span so the highlight band reaches the
                // right edge of the row.
                Line::from(Span::styled(
                    format!("{label:<pad$}{value}"),
                    sel_style,
                ))
            } else {
                let mut spans = vec![Span::styled(
                    format!("{label:<pad$}"),
                    Style::default().fg(pal.fg),
                )];
                spans.extend(row.value_spans(&app.settings, pal));
                Line::from(spans)
            };
            // Click zones: the label picks the row, the value column
            // selects it and cycles forward.
            let y = chunks[0].y + 1 + items.len() as u16;
            let x = chunks[0].x + 1;
            let total = inner_w as u16;
            let value_zone = 36u16.min(total.saturating_sub(12));
            app.clicks.push((
                Rect::new(x, y, total - value_zone, 1),
                Action::SettingsRow(index),
            ));
            app.clicks.push((
                Rect::new(x + total - value_zone, y, value_zone, 1),
                Action::SettingsValue(index),
            ));
            items.push(ListItem::new(line));
            index += 1;
        }
    }
    f.render_widget(
        List::new(items).block(title_block(pal, "Settings")),
        chunks[0],
    );

    // -- help for the selected row, with the key hints at the bottom --
    let row = setting_rows().into_iter().nth(app.settings_cursor);
    let title = row.as_ref().map(Row::title).unwrap_or("Settings");
    let help = row.as_ref().map(Row::help).unwrap_or_default().to_string();
    let block = title_block(pal, &format!("Help \u{2014} {title}"));
    let inner = block.inner(chunks[1]);
    f.render_widget(
        Paragraph::new(help)
            .wrap(ratatui::widgets::Wrap { trim: true })
            .style(Style::default().fg(pal.dim))
            .block(block),
        chunks[1],
    );
    f.render_widget(
        Paragraph::new(hint_line(
            pal,
            &[
                ("\u{2191}\u{2193}", "select"),
                ("\u{2190}\u{2192}", "change"),
                ("Enter", "cycle"),
                ("\u{232b}", "default"),
                ("PgUp/PgDn", "section"),
                ("q", "quit"),
            ],
            " ",
        )),
        Rect::new(
            inner.x,
            inner.y + inner.height.saturating_sub(1),
            inner.width,
            1,
        ),
    );
}

fn render_flags(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    let rows = app.flag_rows();
    if app.flags_state.selected().is_none() && !rows.is_empty() {
        app.flags_state.select(Some(app.flags_cursor.min(rows.len() - 1)));
    }
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(0), Constraint::Length(3)])
        .split(area);
    let managed = App::managed_keys().len();
    let items: Vec<ListItem> = rows
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let style = if Some(i) == app.flags_state.selected() {
                Style::default().fg(pal.accent).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(pal.fg)
            };
            let text = match row {
                FlagRow::Custom { key, value } => format!("{key} = {value}"),
            };
            app.clicks.push((
                Rect::new(chunks[0].x + 1, chunks[0].y + 1 + i as u16, chunks[0].width.saturating_sub(2), 1),
                Action::FlagRow(i),
            ));
            ListItem::new(Line::from(Span::styled(text, style)))
        })
        .collect();
    f.render_stateful_widget(
        List::new(items).block(title_block(pal, &format!("Fast flags ({managed} transport flags auto-managed)"))),
        chunks[0],
        &mut app.flags_state,
    );
    let editor: Line = match &app.flag_edit {
        Some(ed) => {
            let prompt = match ed.stage {
                EditStage::Name => "Flag name".to_string(),
                EditStage::Value => format!("Value for {}", ed.name),
            };
            Line::from(vec![
                Span::styled(prompt + ": ", Style::default().fg(pal.accent)),
                Span::styled(format!("{}▌", ed.buf), Style::default().fg(pal.fg)),
            ])
        }
        None => hint_line(
            pal,
            &[("a", "add"), ("Enter", "edit"), ("d", "delete")],
            ": ",
        ),
    };
    let bar = chunks[1];
    // The whole hint bar is clickable: starts the add flow.
    if app.flag_edit.is_none() {
        app.clicks.push((
            Rect::new(bar.x + 1, bar.y + 1, bar.width.saturating_sub(2), 1),
            Action::AddFlag,
        ));
    }
    f.render_widget(Paragraph::new(editor).block(title_block(pal, "")), bar);
}

fn render_logs(f: &mut ratatui::Frame, app: &mut App, pal: &crate::theme::Palette, area: Rect) {
    // File list sized to its longest name instead of a fixed split.
    let widest = app
        .logs
        .iter()
        .map(|p| p.file_name().map(|n| n.to_string_lossy().len()).unwrap_or(0))
        .max()
        .unwrap_or(20)
        .clamp(18, 40) as u16
        + 4;
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(widest), Constraint::Min(0)])
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
    let text = app
        .logs_state
        .selected()
        .and_then(|i| app.logs.get(i))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default();
    let total = text.lines().count();
    // Visible rows minus borders; follow mode pins to the bottom.
    let visible = chunks[1].height.saturating_sub(2) as usize;
    app.tail_max = total.saturating_sub(visible);
    if app.tail_follow {
        app.tail_scroll = app.tail_max.min(u16::MAX as usize) as u16;
    } else {
        app.tail_scroll = app.tail_scroll.min(app.tail_max.min(u16::MAX as usize) as u16);
    }
    f.render_widget(
        Paragraph::new(text)
            .wrap(ratatui::widgets::Wrap { trim: true })
            .scroll((app.tail_scroll, 0))
            .block(title_block(pal, "Tail (PgUp/PgDn/wheel/arrows)")),
        chunks[1],
    );
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

pub(crate) struct Section {
    pub title: &'static str,
    pub rows: Vec<Row>,
}

/// The Settings tab's rows, grouped under section headers.
pub(crate) fn setting_sections() -> Vec<Section> {
    vec![
        Section {
            title: "Graphics",
            rows: vec![
                Row::Cycle {
                    key: "renderer",
                    title: "Renderer",
                    help: "GPU API for Roblox. OpenGL is the stable default; Vulkan renders through Zink and glitches in places.",
                    options: vec![("opengl".into(), "OpenGL".into()), ("vulkan".into(), "Vulkan (Zink, experimental)".into())],
                },
                Row::Cycle {
                    key: "display_backend",
                    title: "Window backend",
                    help: "How Roblox windows are created. X11 works everywhere; native Wayland is experimental with mouse-lock quirks.",
                    options: vec![("x11".into(), "X11 / Xwayland".into()), ("wayland".into(), "Native Wayland (experimental)".into())],
                },
                Row::Cycle {
                    key: "framerate_cap",
                    title: "Frame rate cap",
                    help: "Roblox caps itself at 60 FPS even with vsync off; Unlimited lifts it via the scheduler flag. Applies on next launch.",
                    options: vec![("0".into(), "Unlimited".into()), ("60".into(), "60 FPS".into()), ("120".into(), "120 FPS".into()), ("144".into(), "144 FPS".into()), ("240".into(), "240 FPS".into())],
                },
                Row::Number {
                    key: "dpi_scale",
                    title: "Roblox UI scale",
                    help: "Size of Roblox's own interface, auto-detected from your desktop. 100% = native. Applies on next launch.",
                    min: 1.0, max: 4.0, step: 0.05, pct: true,
                },
                Row::Bool {
                    key: "mangohud",
                    title: "MangoHud overlay",
                    help: "FPS and frame-time overlay on top of Roblox, shown when MangoHud is available.",
                    default: false,
                },
            ],
        },
        Section {
            title: "Input",
            rows: vec![
                Row::Number {
                    key: "mouse_sensitivity",
                    title: "Camera sensitivity",
                    help: "Multiplier for in-game mouse camera speed: 0.1 slow \u{2026} 5.0 fast.",
                    min: 0.1, max: 5.0, step: 0.05, pct: false,
                },
                Row::Number {
                    key: "scroll_sensitivity",
                    title: "Scroll sensitivity",
                    help: "Multiplier for wheel scrolling in Roblox menus: 0.1 slow \u{2026} 5.0 fast.",
                    min: 0.1, max: 5.0, step: 0.1, pct: false,
                },
                Row::Bool {
                    key: "raw_mouse",
                    title: "Raw mouse input",
                    help: "Pass raw, unaccelerated motion straight to Roblox. Keep this on unless the mouse feels wrong.",
                    default: true,
                },
            ],
        },
        Section {
            title: "Interface",
            rows: vec![
                Row::Bool {
                    key: "hide_menu_bar",
                    title: "Hide the macOS menu bar",
                    help: "Hide the fake macOS menu bar Roblox draws along the top of its window.",
                    default: true,
                },
                Row::Number {
                    key: "tui_font_scale",
                    title: "TUI font scale",
                    help: "Size of this launcher's own text, 80% \u{2026} 200%. Applies instantly.",
                    min: 0.8, max: 2.0, step: 0.1, pct: true,
                },
                Row::Cycle {
                    key: "theme",
                    title: "Color theme",
                    help: "Launcher palette. Cheese (the default) is matched to the logo; drop files in ~/.config/macncheese/themes for your own.",
                    options: crate::theme::names()
                        .into_iter()
                        .map(|(a, b)| (a.to_string(), b.to_string()))
                        .collect(),
                },
                Row::Bool {
                    key: "debug",
                    title: "Debug logging",
                    help: "Show the Logs tab with the Roblox output and launch diagnostics. While off, the tab is hidden entirely.",
                    default: false,
                },
            ],
        },
    ]
}

/// Every selectable row, flattened in render order (cursor index space).
pub(crate) fn setting_rows() -> Vec<Row> {
    setting_sections()
        .into_iter()
        .flat_map(|s| s.rows)
        .collect()
}

/// First flattened index of each section (PgUp/PgDn targets).
fn section_starts() -> Vec<usize> {
    let mut starts = Vec::new();
    let mut n = 0;
    for section in setting_sections() {
        starts.push(n);
        n += section.rows.len();
    }
    starts
}

pub(crate) enum Row {
    Cycle {
        key: &'static str,
        title: &'static str,
        help: &'static str,
        options: Vec<(String, String)>,
    },
    Number {
        key: &'static str,
        title: &'static str,
        help: &'static str,
        min: f64,
        max: f64,
        step: f64,
        pct: bool,
    },
    Bool {
        key: &'static str,
        title: &'static str,
        help: &'static str,
        default: bool,
    },
}

impl Row {
    fn key(&self) -> &'static str {
        match self {
            Row::Cycle { key, .. } | Row::Number { key, .. } | Row::Bool { key, .. } => key,
        }
    }

    fn title(&self) -> &'static str {
        match self {
            Row::Cycle { title, .. } | Row::Number { title, .. } | Row::Bool { title, .. } => title,
        }
    }

    pub(crate) fn help(&self) -> &'static str {
        match self {
            Row::Cycle { help, .. } | Row::Number { help, .. } | Row::Bool { help, .. } => help,
        }
    }

    /// The value column as plain text (the selected row paints it in one
    /// style, so it needs the same width as the styled spans).
    fn value_text(&self, settings: &Map<String, Value>) -> String {
        match self {
            Row::Cycle { key, options, .. } => {
                let cur = settings.get(*key).and_then(|v| v.as_str()).unwrap_or("");
                let label = options
                    .iter()
                    .find(|(v, _)| v.as_str() == cur)
                    .map(|(_, l)| l.clone())
                    .unwrap_or_else(|| cur.to_string());
                format!("\u{2039} {label} \u{203a}")
            }
            Row::Number { key, min, pct, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_f64()).unwrap_or(*min);
                Row::display(v, *pct)
            }
            Row::Bool { key, default, .. } => {
                let on = settings.get(*key).and_then(|v| v.as_bool()).unwrap_or(*default);
                if on {
                    "\u{25cf} on".to_string()
                } else {
                    "\u{25cb} off".to_string()
                }
            }
        }
    }

    fn display(v: f64, pct: bool) -> String {
        if pct {
            format!("{}%", (v * 100.0).round() as i64)
        } else {
            format!("{v:.2}")
        }
    }

    /// The value column in the accent color (or ok/dim for toggles).
    pub(crate) fn value_spans(
        &self,
        settings: &Map<String, Value>,
        pal: &crate::theme::Palette,
    ) -> Vec<Span<'static>> {
        match self {
            Row::Number { key, min, pct, .. } => {
                let v = settings.get(*key).and_then(|v| v.as_f64()).unwrap_or(*min);
                vec![Span::styled(
                    Row::display(v, *pct),
                    Style::default().fg(pal.accent).add_modifier(Modifier::BOLD),
                )]
            }
            Row::Bool { key, default, .. } => {
                let on = settings.get(*key).and_then(|v| v.as_bool()).unwrap_or(*default);
                if on {
                    vec![Span::styled(
                        "\u{25cf} on",
                        Style::default().fg(pal.ok),
                    )]
                } else {
                    vec![Span::styled("\u{25cb} off", Style::default().fg(pal.dim))]
                }
            }
            Row::Cycle { .. } => vec![Span::styled(
                self.value_text(settings),
                Style::default().fg(pal.accent).add_modifier(Modifier::BOLD),
            )],
        }
    }

    /// Backspace: put the key back to its shipped default.
    pub(crate) fn reset(&self, settings: &mut Map<String, Value>) {
        if let Some(default) = crate::settings::default_for(self.key()) {
            settings.insert(self.key().to_string(), default);
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
    fn settings_tab_groups_and_explains() {
        let mut app = App::new();
        app.tab = app.tabs.iter().position(|t| *t == Tab::Settings).unwrap();
        let text = drawn(&mut app);
        for expected in [
            "Graphics", "Input", "Interface", // section headers
            "Help", "Renderer", // selected-row help block
            "select", "default", // key hints
        ] {
            assert!(text.contains(expected), "settings view missing {expected:?}");
        }
        // Two click zones per row: label (select) + value (cycle).
        let settings_clicks = app
            .clicks
            .iter()
            .filter(|(_, a)| matches!(a, Action::SettingsRow(_) | Action::SettingsValue(_)))
            .count();
        assert_eq!(settings_clicks, setting_rows().len() * 2, "click zones");
    }

    #[test]
    fn setting_rows_reset_to_defaults() {
        let mut settings = settings::load();
        settings.insert("renderer".into(), Value::from("vulkan"));
        settings.insert("mangohud".into(), Value::Bool(true));
        let rows = setting_rows();
        let row = rows.iter().find(|r| r.key() == "renderer").expect("renderer row");
        row.reset(&mut settings);
        assert_eq!(settings["renderer"], Value::from("opengl"));
        let mangohud = rows.iter().find(|r| r.key() == "mangohud").expect("mangohud row");
        mangohud.reset(&mut settings);
        assert_eq!(settings["mangohud"], Value::Bool(false));
    }

    #[test]
    fn settings_selection_paints_an_accent_band() {
        let mut app = App::new();
        app.tab = app.tabs.iter().position(|t| *t == Tab::Settings).unwrap();
        let backend = TestBackend::new(100, 30);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|f| ui(f, &mut app)).unwrap();
        let buf = terminal.backend().buffer();
        let mode = app.settings.get("theme").and_then(|v| v.as_str()).unwrap_or("cheese");
        let pal = crate::theme::resolve(mode);
        // Block starts at y=3: header at y=4, selected first row at y=5.
        let selected = &buf[(2, 5)];
        assert_eq!(selected.bg, pal.accent, "selected row must be an accent band");
        assert_eq!(selected.fg, pal.bg, "band text takes the background color");
        let plain = &buf[(2, 6)];
        assert_eq!(plain.bg, pal.bg, "unselected rows stay on the theme bg");
    }

    #[test]
    fn page_keys_jump_between_sections() {
        let mut app = App::new();
        let starts = section_starts();
        assert_eq!(starts.len(), 3, "expected Graphics/Input/Interface");
        app.settings_cursor = starts[1] + 1;
        app.jump_section(-1);
        assert_eq!(app.settings_cursor, starts[1], "PgUp -> own section start");
        app.jump_section(-1);
        assert_eq!(app.settings_cursor, starts[0], "PgUp -> previous section");
        app.jump_section(1);
        assert_eq!(app.settings_cursor, starts[1], "PgDn -> next section");
        app.settings_cursor = setting_rows().len() - 1;
        app.jump_section(1);
        assert_eq!(app.settings_cursor, setting_rows().len() - 1, "PgDn at end stays");
    }

    #[test]
    fn debug_flag_gates_the_logs_tab() {
        let mut app = App::new();
        app.settings.insert("debug".into(), Value::Bool(false));
        app.sync_tabs();
        assert!(!app.tabs.contains(&Tab::Logs), "Logs must stay hidden");
        app.settings.insert("debug".into(), Value::Bool(true));
        app.sync_tabs();
        assert!(app.tabs.contains(&Tab::Logs), "debug must reveal Logs");
        // Viewing Logs and switching debug off lands back on Play.
        app.tab = app.tabs.iter().position(|t| *t == Tab::Logs).unwrap();
        app.settings.insert("debug".into(), Value::Bool(false));
        app.sync_tabs();
        assert!(!app.tabs.contains(&Tab::Logs), "Logs must disappear again");
        assert!(
            app.tabs.get(app.tab).copied() == Some(Tab::Play),
            "selection falls back to Play"
        );
    }

    #[test]
    fn setup_needed_without_consent() {
        let no_consent: Map<String, Value> = Map::new();
        assert!(App::setup_needed(&no_consent), "no consent -> setup");
        let mut consented = Map::new();
        consented.insert("setup_complete".into(), Value::Bool(true));
        assert_eq!(
            App::setup_needed(&consented),
            update::installed_version().is_none(),
            "after consent setup shows only while the client is missing"
        );
    }

    #[test]
    fn consented_but_client_missing_keeps_setup_tab() {
        if update::installed_version().is_some() {
            return; // hide-branch needs a real client; nothing to assert
        }
        let mut app = App::new();
        app.settings.insert("setup_complete".into(), Value::Bool(true));
        app.sync_tabs();
        assert!(
            app.tabs.contains(&Tab::Setup),
            "missing client must keep Setup visible"
        );
        app.tab = app.tabs.iter().position(|t| *t == Tab::Setup).unwrap();
        let text = drawn(&mut app);
        assert!(text.contains("Setup"), "setup tab should render");
    }
}
