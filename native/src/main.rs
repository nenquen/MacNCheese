//! Mac'n Cheese native launcher (Rust + GTK4/libadwaita).
//! Rebuild of the Python launcher without an interpreter: one binary,
//! same settings file, same Darling/Roblox backend protocol.

mod settings;

use adw::prelude::*;
use gtk::glib;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id("org.macncheese.MacNCheese")
        .build();

    app.connect_activate(|app| {
        let store = settings::load();

        let play = adw::StatusPage::builder()
            .icon_name("macncheese")
            .title("Mac'n Cheese")
            .build();
        let center = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(12)
            .halign(gtk::Align::Center)
            .build();
        let version = crate::roblox_version();
        let desc = format!(
            "Roblox {} · {}",
            version.as_deref().unwrap_or("not found"),
            if darling_running() {
                "Darling running"
            } else {
                "Darling starts with the game"
            }
        );
        play.set_description(Some(&desc));
        let play_button = gtk::Button::builder()
            .label("Play")
            .css_classes(["suggested-action", "pill"])
            .build();
        play_button.set_size_request(140, -1);
        center.append(&play_button);
        play.set_child(Some(&center));

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
        let _ = store;
        window.present();
    });

    app.run()
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
