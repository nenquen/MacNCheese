//! Color themes: System (from the desktop), Dark, Light.
//! OpenCode-style: "system" follows the OS, the rest are fixed palettes.

use ratatui::style::Color;

pub struct Palette {
    pub bg: Color,
    pub fg: Color,
    pub accent: Color,
    pub dim: Color,
    pub ok: Color,
    pub err: Color,
}

pub static DARK: Palette = Palette {
    bg: Color::Black,
    fg: Color::White,
    accent: Color::Yellow,
    dim: Color::DarkGray,
    ok: Color::Green,
    err: Color::Red,
};

pub static LIGHT: Palette = Palette {
    bg: Color::White,
    fg: Color::Black,
    accent: Color::Blue,
    dim: Color::Gray,
    ok: Color::Green,
    err: Color::Red,
};

/// True when the desktop is in dark mode (portal first, desktops second).
pub fn system_dark() -> bool {
    if let Ok(out) = std::process::Command::new("gsettings")
        .args(["get", "org.freedesktop.appearance", "color-scheme"])
        .output()
    {
        let text = String::from_utf8_lossy(&out.stdout);
        if text.contains('1') {
            return true;
        }
        if text.contains('2') {
            return false;
        }
    }
    if let Ok(out) = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.interface", "color-scheme"])
        .output()
    {
        let text = String::from_utf8_lossy(&out.stdout);
        if text.contains("prefer-dark") {
            return true;
        }
    }
    if let Ok(text) = std::fs::read_to_string(dirs_home().join(".config/kdeglobals")) {
        for line in text.lines() {
            let line = line.trim().to_lowercase();
            if line.starts_with("colorscheme") {
                return line.contains("dark");
            }
        }
    }
    true
}

fn dirs_home() -> std::path::PathBuf {
    dirs::home_dir().unwrap_or_default()
}

pub fn resolve(mode: &str) -> &'static Palette {
    match mode {
        "dark" => &DARK,
        "light" => &LIGHT,
        _ => {
            if system_dark() {
                &DARK
            } else {
                &LIGHT
            }
        }
    }
}

/// Installed monospace families for the font picker.
pub fn mono_fonts() -> Vec<String> {
    let out = std::process::Command::new("fc-list")
        .args([":spacing=mono", "family"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut seen = std::collections::HashSet::new();
    let mut fonts: Vec<String> = out
        .split([',', '\n'])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && seen.insert(s.clone()))
        .collect();
    fonts.sort();
    fonts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn palettes_resolve() {
        assert!(std::ptr::eq(resolve("dark"), &DARK));
        assert!(std::ptr::eq(resolve("light"), &LIGHT));
        let sys = resolve("system");
        assert!(std::ptr::eq(sys, &DARK) || std::ptr::eq(sys, &LIGHT));
    }

    #[test]
    fn fonts_list_sane() {
        let fonts = mono_fonts();
        assert!(fonts.windows(2).all(|w| w[0] <= w[1]), "not sorted/deduped");
    }
}
