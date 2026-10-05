//! Terminal frontend: crossterm + alternate screen.

use anyhow::Result;
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, MouseButton, MouseEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{backend::CrosstermBackend, Terminal};
use std::io;
use std::time::Duration;

use crate::{ui, App, Input, Key, KeyAction};

fn to_input(event: Event) -> Option<Input> {
    match event {
        Event::Key(key) => {
            use crossterm::event::KeyCode as K;
            let k = match key.code {
                K::Up => Key::Up,
                K::Down => Key::Down,
                K::Left => Key::Left,
                K::Right => Key::Right,
                K::Enter => Key::Enter,
                K::Esc => Key::Esc,
                K::Tab => Key::Tab,
                K::Backspace => Key::Backspace,
                K::PageUp => Key::PageUp,
                K::PageDown => Key::PageDown,
                K::Char(c) => Key::Char(c),
                _ => return None,
            };
            Some(Input::Key(k))
        }
        Event::Mouse(mouse) if mouse.kind == MouseEventKind::Down(MouseButton::Left) => {
            Some(Input::Click(mouse.column, mouse.row))
        }
        _ => None,
    }
}

pub fn run() -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    // Own window title instead of the shell's.
    print!("\x1b]0;Mac'n Cheese\x07");
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new();
    let result = event_loop(&mut terminal, &mut app);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
    terminal.show_cursor()?;
    result
}

fn event_loop(
    terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>,
    app: &mut App,
) -> Result<()> {
    app.refresh_logs();
    loop {
        app.tick();
        app.clicks.clear();
        terminal.draw(|f| ui(f, app))?;
        if event::poll(Duration::from_millis(250))? {
            let Some(input) = to_input(event::read()?) else {
                continue;
            };
            match app.on_input(input) {
                KeyAction::Quit => {
                    if let Some(mut s) = app.session.take() {
                        s.finish();
                    }
                    return Ok(());
                }
                KeyAction::None => {}
            }
        }
    }
}
