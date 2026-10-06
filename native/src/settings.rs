//! Settings: ~/.config/macncheese/settings.json with validated defaults.
//! Port of launcher/macncheese/core.py DEFAULT_SETTINGS/load_settings.

use anyhow::{Context, Result};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

fn defaults() -> HashMap<&'static str, Value> {
    let mut m = HashMap::new();
    m.insert("setup_complete", Value::Bool(false));
    m.insert("language", Value::from("en"));
    m.insert("mouse_sensitivity", Value::from(1.0));
    m.insert("scroll_sensitivity", Value::from(1.5));
    m.insert("auto_patch_throttle", Value::Bool(true));
    m.insert("raw_mouse", Value::Bool(true));
    m.insert("display_backend", Value::from("x11"));
    m.insert("tui_font_scale", Value::from(1.0));
    m.insert("theme", Value::from("cheese"));
    m.insert("debug", Value::Bool(false));
    m.insert("use_system_font", Value::Bool(true));
    m.insert("dpi_scale", Value::from(1.0));
    m.insert("dpi_scale_auto", Value::Bool(true));
    m.insert("hide_menu_bar", Value::Bool(true));
    m.insert("renderer", Value::from("opengl"));
    m.insert("mangohud", Value::Bool(false));
    m.insert("dns", Value::from("system"));
    m.insert("dns_custom", Value::from(""));
    m.insert("show_launcher_after_exit", Value::Bool(true));
    m.insert("diagnostic_signals", Value::Bool(false));
    m.insert("keep_logs", Value::from(30));
    m.insert("framerate_cap", Value::from("0"));
    m
}

/// Roblox UI scale; invalid values fall back to 1.0.
pub fn validated_dpi_scale(value: &Value) -> f64 {
    match value.as_f64() {
        Some(v) if v.is_finite() && (1.0..=4.0).contains(&v) => v,
        _ => 1.0,
    }
}

fn settings_file() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| dirs::home_dir().unwrap_or_default().join(".config"));
    base.join("macncheese").join("settings.json")
}

/// Is debug logging on? Read fresh from disk: log_line and the wrapper
/// shell both gate on it, and neither has the in-memory map.
pub fn debug_enabled() -> bool {
    load()
        .get("debug")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// Merge stored settings over defaults; wrong types fall back silently.
pub fn load() -> Map<String, Value> {
    let text = fs::read_to_string(settings_file()).unwrap_or_default();
    merge_stored(&text)
}

/// The merge itself, split out so tests can feed it JSON directly.
pub fn merge_stored(text: &str) -> Map<String, Value> {
    let mut merged: Map<String, Value> = defaults()
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    let stored: Map<String, Value> = serde_json::from_str(text).unwrap_or_default();
    for (key, value) in stored {
        if key == "dpi_scale" {
            merged.insert(key.clone(), Value::from(validated_dpi_scale(&value)));
            continue;
        }
        let valid = match merged.get(&key) {
            Some(Value::Bool(_)) => value.is_boolean(),
            Some(Value::Number(_)) => value.is_number() && !value.is_boolean(),
            Some(Value::String(_)) => value.is_string(),
            _ => false,
        };
        if valid {
            merged.insert(key, value);
        }
    }
    // The "system" theme was removed; stored configs land on Cheese.
    if merged.get("theme").and_then(|v| v.as_str()) == Some("system") {
        merged.insert("theme".into(), Value::from("cheese"));
    }
    merged
}

/// The shipped default for one key (Backspace reset in the Settings tab).
pub fn default_for(key: &str) -> Option<Value> {
    defaults().get(key).cloned()
}

/// Atomic write (temp + rename), like the Python launcher.
pub fn save(settings: &Map<String, Value>) -> Result<()> {
    let path = settings_file();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).context("creating config dir")?;
    }
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, serde_json::to_string_pretty(settings)?).context("writing settings")?;
    fs::rename(&tmp, &path).context("replacing settings")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpi_validation() {
        assert_eq!(validated_dpi_scale(&Value::from(1.25)), 1.25);
        assert_eq!(validated_dpi_scale(&Value::from(9.0)), 1.0);
        assert_eq!(validated_dpi_scale(&Value::Bool(true)), 1.0);
        assert_eq!(validated_dpi_scale(&Value::Null), 1.0);
    }

    #[test]
    fn defaults_sane() {
        let d = defaults();
        assert_eq!(d["hide_menu_bar"], Value::Bool(true));
        assert_eq!(d["renderer"], Value::from("opengl"));
        assert_eq!(d["theme"], Value::from("cheese"), "Cheese is the main theme");
        assert_eq!(d["debug"], Value::Bool(false), "Logs tab starts hidden");
        assert_eq!(default_for("renderer"), Some(Value::from("opengl")));
        assert_eq!(default_for("no_such_key"), None);
    }

    #[test]
    fn stored_system_theme_migrates_to_cheese() {
        let merged = merge_stored(r#"{"theme": "system", "debug": true}"#);
        assert_eq!(merged["theme"], Value::from("cheese"), "system -> cheese");
        assert_eq!(merged["debug"], Value::Bool(true), "debug passes through");
        let bad = merge_stored(r#"{"theme": 42, "debug": "yes"}"#);
        assert_eq!(bad["theme"], Value::from("cheese"), "wrong types fall back");
        assert_eq!(bad["debug"], Value::Bool(false));
    }
}
