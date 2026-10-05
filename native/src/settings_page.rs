//! Settings page: form bound to the shared settings store.

use adw::prelude::*;
use serde_json::{Map, Value};
use std::sync::{Arc, Mutex};

use crate::settings;

pub type Store = Arc<Mutex<Map<String, Value>>>;

fn save(store: &Store) {
    if let Ok(map) = store.lock() {
        let _ = settings::save(&map);
    }
}

fn get_bool(store: &Store, key: &str, default: bool) -> bool {
    store
        .lock()
        .ok()
        .and_then(|m| m.get(key).and_then(|v| v.as_bool()))
        .unwrap_or(default)
}

fn set_bool(store: &Store, key: &str, value: bool) {
    if let Ok(mut m) = store.lock() {
        m.insert(key.to_string(), Value::Bool(value));
    }
    save(store);
}

fn switch_row(store: &Store, title: &str, subtitle: &str, key: &str, default: bool) -> adw::SwitchRow {
    let row = adw::SwitchRow::builder()
        .title(title)
        .subtitle(subtitle)
        .active(get_bool(store, key, default))
        .build();
    let store = store.clone();
    let key = key.to_string();
    row.connect_active_notify(move |r| {
        set_bool(&store, &key, r.is_active());
    });
    row
}

fn slider_row(
    store: &Store,
    title: &str,
    key: &str,
    min: f64,
    max: f64,
    step: f64,
    to_value: impl Fn(f64) -> Value + 'static,
    to_slider: impl Fn(&Value) -> f64 + 'static,
    fmt: impl Fn(f64) -> String + 'static,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(title).build();
    let box_ = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .hexpand(true)
        .build();
    let slider = gtk::Scale::with_range(gtk::Orientation::Horizontal, min, max, step);
    slider.set_hexpand(true);
    slider.set_draw_value(false);
    let label = gtk::Label::new(None);
    {
        let current = store
            .lock()
            .ok()
            .map(|m| m.get(key).map(&to_slider).unwrap_or(min))
            .unwrap_or(min);
        slider.set_value(current);
        label.set_text(&fmt(current));
    }
    let store = store.clone();
    let key = key.to_string();
    let label_ref = label.clone();
    slider.connect_value_changed(move |s| {
        let v = s.value();
        if let Ok(mut m) = store.lock() {
            m.insert(key.clone(), to_value(v));
        }
        save(&store);
        label_ref.set_text(&fmt(v));
    });
    box_.append(&slider);
    box_.append(&label);
    row.add_suffix(&box_);
    row
}

pub fn page(store: &Store) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::new();

    let game = adw::PreferencesGroup::builder().title("Game").build();

    let renderer = adw::ComboRow::builder().title("Renderer").build();
    let models = gtk::StringList::new(&["OpenGL", "Vulkan (Zink, experimental)"]);
    renderer.set_model(Some(&models));
    let current = store
        .lock()
        .ok()
        .and_then(|m| m.get("renderer").and_then(|v| v.as_str()).map(str::to_string))
        .unwrap_or_else(|| "opengl".into());
    renderer.set_selected(if current == "vulkan" { 1 } else { 0 });
    renderer.set_subtitle("Vulkan is experimental. Applies on next launch.");
    {
        let store = store.clone();
        renderer.connect_selected_notify(move |r| {
            let value = if r.selected() == 1 { "vulkan" } else { "opengl" };
            if let Ok(mut m) = store.lock() {
                m.insert("renderer".into(), Value::from(value));
            }
            save(&store);
        });
    }
    game.add(&renderer);

    let dpi = slider_row(
        store,
        "Roblox UI scale",
        "dpi_scale",
        100.0,
        400.0,
        5.0,
        |v| Value::from(settings::validated_dpi_scale(&Value::from(v / 100.0))),
        |v| settings::validated_dpi_scale(v) * 100.0,
        |v| format!("{v:.0}%"),
    );
    dpi.set_subtitle("100–400% in 5% steps. Applies on next launch.");
    game.add(&dpi);

    let sens = slider_row(
        store,
        "Camera sensitivity",
        "mouse_sensitivity",
        10.0,
        500.0,
        5.0,
        |v| Value::from((v / 100.0 * 100.0).round() / 100.0),
        |v| v.as_f64().unwrap_or(1.0) * 100.0,
        |v| format!("{:.2}", v / 100.0),
    );
    game.add(&sens);

    game.add(&switch_row(store, "Raw mouse input", "Device deltas for the camera", "raw_mouse", true));
    game.add(&switch_row(store, "Hide the macOS menu bar", "Applies on next launch", "hide_menu_bar", true));
    game.add(&switch_row(store, "MangoHud overlay", "Needs MangoHud. Applies on next launch.", "mangohud", false));
    page.add(&game);

    let interface = adw::PreferencesGroup::builder().title("Interface").build();
    interface.add(&switch_row(
        store,
        "Follow system light/dark mode",
        "KDE and GNOME switches apply live.",
        "follow_system_theme",
        true,
    ));
    interface.add(&switch_row(
        store,
        "Use system interface font",
        "Applies on next launch.",
        "use_system_font",
        true,
    ));
    page.add(&interface);

    page
}
