//! Mac'n Cheese native launcher (Rust + GTK4/libadwaita).
//! Rebuild of the Python launcher without an interpreter: one binary,
//! same settings file, same Darling/Roblox backend protocol.

mod settings;
mod paths;
mod audio;
mod session;

use adw::prelude::*;
use gtk::glib;
use std::sync::{Arc, Mutex};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id("org.macncheese.MacNCheese")
        .build();

    app.connect_activate(|app| {
        let store = settings::load();
        let session: Arc<Mutex<Option<session::Session>>> = Arc::new(Mutex::new(None));
        let (tx, rx) = std::sync::mpsc::channel::<
            Result<session::Session, String>,
        >();
        let rx = Arc::new(Mutex::new(rx));

        let play = adw::StatusPage::builder()
            .icon_name("macncheese")
            .title("Mac'n Cheese")
            .build();
        let center = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .halign(gtk::Align::Center)
            .build();
        let status_label = gtk::Label::builder().build();
        center.append(&status_label);
        let play_button = gtk::Button::builder()
            .label("Play")
            .css_classes(["suggested-action", "pill"])
            .build();
        play_button.set_size_request(140, -1);
        {
            let session = session.clone();
            let status_label = status_label.clone();
            let button = play_button.clone();
            let store = store.clone();
            play_button.connect_clicked(move |_| {
                let running = session.lock().unwrap().is_some();
                if running {
                    if let Some(mut s) = session.lock().unwrap().take() {
                        s.finish();
                    }
                    button.set_label("Play");
                    return;
                }
                button.set_label("Starting…");
                button.set_sensitive(false);
                let tx = tx.clone();
                let store = store.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(session::Session::start(&store));
                });
            });
        }
        center.append(&play_button);
        play.set_child(Some(&center));

        {
            let session = session.clone();
            let status_label = status_label.clone();
            let play_button = play_button.clone();
            let rx = rx.clone();
            glib::timeout_add_seconds_local(1, move || {
                // Collect finished startups from the worker thread.
                if let Ok(result) = rx.lock().unwrap().try_recv() {
                    match result {
                        Ok(s) => {
                            *session.lock().unwrap() = Some(s);
                            play_button.set_label("Stop Roblox");
                            status_label.set_text("Roblox running");
                        }
                        Err(e) => {
                            play_button.set_label("Play");
                            status_label
                                .set_text(&format!("Could not start: {e}"));
                        }
                    }
                    play_button.set_sensitive(true);
                }
                let mut guard = session.lock().unwrap();
                if let Some(s) = guard.as_mut() {
                    match s.poll() {
                        None => {}
                        Some(code) => {
                            *guard = None;
                            play_button.set_label("Play");
                            status_label.set_text(&format!("Roblox exited ({code})"));
                        }
                    }
                }
                glib::ControlFlow::Continue
            });
        }

        let stack = adw::ViewStack::new();
        stack.add_titled_with_icon(&play, Some("play"), "Play", "macncheese-nav-play");

        let sidebar = adw::ViewSwitcherSidebar::builder().stack(&stack).build();
        let split = adw::OverlaySplitView::builder()
            .min_sidebar_width(200.0)
            .max_sidebar_width(260.0)
            .show_sidebar(true)
            .sidebar(&sidebar)
            .build();

        let content = adw::ToolbarView::new();
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&gtk::Label::new(None)));
        content.add_top_bar(&header);
        content.set_content(Some(&stack));
        split.set_content(Some(&content));

        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("Mac'n Cheese")
            .default_width(980)
            .default_height(640)
            .content(&split)
            .build();
        // Initial status line; the 1 s timer keeps it live afterwards.
        status_label.set_text(&initial_status());
        window.present();
    });

    app.run()
}

fn initial_status() -> String {
    let version = roblox_version();
    format!(
        "Roblox {} · {}",
        version.as_deref().unwrap_or("not found"),
        if darling_running() {
            "Darling running"
        } else {
            "Darling starts with the game"
        }
    )
}

/// Installed client version from RobloxPlayer.app/Info.plist, if present.
fn roblox_version() -> Option<String> {
    let data_dir = std::env::var("XDG_DATA_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| {
            dirs::home_dir()
                .unwrap_or_default()
                .join(".local")
                .join("share")
        })
        .join("macncheese");
    let plist = data_dir.join("RobloxPlayer.app/Contents/Info.plist");
    let text = std::fs::read_to_string(plist).ok()?;
    let start = text.find("<key>CFBundleShortVersionString</key>")?;
    let rest = &text[start..];
    let s = rest.find("<string>")? + "<string>".len();
    let e = rest[s..].find("</string>")?;
    Some(rest[s..s + e].to_string())
}

/// True while darlingserver runs for this user.
fn darling_running() -> bool {
    std::process::Command::new("pgrep")
        .args(["-u", &users_uid(), "-x", "darlingserver"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn users_uid() -> String {
    // SAFETY: getuid has no failure modes.
    unsafe { libc::getuid().to_string() }
}
