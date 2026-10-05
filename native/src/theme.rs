//! Color themes, OpenCode-style: named slots, built-ins embedded in the
//! binary, user overrides in ~/.config/macncheese/themes/*.json.
//!
//! Slots: background, text, muted, accent, ok, warn, err, border.

use ratatui::style::Color;
use std::collections::HashMap;

#[derive(Clone)]
pub struct Palette {
    pub bg: Color,
    pub fg: Color,
    pub accent: Color,
    pub dim: Color,
    pub ok: Color,
    pub warn: Color,
    pub err: Color,
    pub border: Color,
}

fn rgb(hex: &str) -> Color {
    let h = hex.trim_start_matches('#');
    let n = u32::from_str_radix(h, 16).unwrap_or(0);
    Color::Rgb(((n >> 16) & 0xff) as u8, ((n >> 8) & 0xff) as u8, (n & 0xff) as u8)
}

pub static DARK: Palette = Palette {
    bg: Color::Black,
    fg: Color::White,
    accent: Color::Yellow,
    dim: Color::DarkGray,
    ok: Color::Green,
    warn: Color::Yellow,
    err: Color::Red,
    border: Color::DarkGray,
};

pub static LIGHT: Palette = Palette {
    bg: Color::White,
    fg: Color::Black,
    accent: Color::Blue,
    dim: Color::Gray,
    ok: Color::Green,
    warn: Color::Yellow,
    err: Color::Red,
    border: Color::Gray,
};

pub static CATPPUCCIN: Palette = Palette {
    bg: Color::Rgb(30, 30, 46),
    fg: Color::Rgb(205, 214, 244),
    accent: Color::Rgb(203, 166, 247),
    dim: Color::Rgb(108, 112, 134),
    ok: Color::Rgb(166, 227, 161),
    warn: Color::Rgb(249, 226, 175),
    err: Color::Rgb(243, 139, 168),
    border: Color::Rgb(88, 91, 112),
};

pub static CATPPUCCIN_LATTE: Palette = Palette {
    bg: Color::Rgb(239, 241, 245),
    fg: Color::Rgb(76, 79, 105),
    accent: Color::Rgb(136, 57, 239),
    dim: Color::Rgb(156, 160, 176),
    ok: Color::Rgb(64, 160, 43),
    warn: Color::Rgb(223, 142, 29),
    err: Color::Rgb(210, 15, 57),
    border: Color::Rgb(204, 208, 218),
};

pub static ROSE_PINE: Palette = Palette {
    bg: Color::Rgb(25, 23, 36),
    fg: Color::Rgb(224, 222, 244),
    accent: Color::Rgb(196, 167, 231),
    dim: Color::Rgb(110, 106, 134),
    ok: Color::Rgb(156, 207, 216),
    warn: Color::Rgb(246, 193, 119),
    err: Color::Rgb(235, 111, 146),
    border: Color::Rgb(64, 61, 82),
};

pub static ROSE_PINE_DAWN: Palette = Palette {
    bg: Color::Rgb(250, 244, 237),
    fg: Color::Rgb(87, 82, 121),
    accent: Color::Rgb(144, 122, 169),
    dim: Color::Rgb(152, 147, 165),
    ok: Color::Rgb(86, 148, 159),
    warn: Color::Rgb(234, 157, 52),
    err: Color::Rgb(180, 99, 122),
    border: Color::Rgb(220, 211, 197),
};

pub static TOKYONIGHT: Palette = Palette {
    bg: Color::Rgb(26, 27, 38),
    fg: Color::Rgb(192, 202, 245),
    accent: Color::Rgb(122, 162, 247),
    dim: Color::Rgb(86, 95, 137),
    ok: Color::Rgb(158, 206, 106),
    warn: Color::Rgb(224, 175, 104),
    err: Color::Rgb(247, 118, 142),
    border: Color::Rgb(59, 66, 97),
};

pub static NORD: Palette = Palette {
    bg: Color::Rgb(46, 52, 64),
    fg: Color::Rgb(216, 222, 233),
    accent: Color::Rgb(136, 192, 208),
    dim: Color::Rgb(76, 86, 106),
    ok: Color::Rgb(163, 190, 140),
    warn: Color::Rgb(235, 203, 139),
    err: Color::Rgb(191, 97, 106),
    border: Color::Rgb(67, 76, 94),
};

pub static GRUVBOX: Palette = Palette {
    bg: Color::Rgb(40, 40, 40),
    fg: Color::Rgb(235, 219, 178),
    accent: Color::Rgb(250, 189, 47),
    dim: Color::Rgb(146, 131, 116),
    ok: Color::Rgb(184, 187, 38),
    warn: Color::Rgb(254, 128, 25),
    err: Color::Rgb(251, 73, 52),
    border: Color::Rgb(80, 73, 69),
};

pub fn builtin(name: &str) -> Option<&'static Palette> {
    Some(match name {
        "dark" => &DARK,
        "light" => &LIGHT,
        "catppuccin" | "catppuccin-mocha" => &CATPPUCCIN,
        "catppuccin-latte" => &CATPPUCCIN_LATTE,
        "rose-pine" | "rosepine" | "rose" => &ROSE_PINE,
        "rose-pine-dawn" => &ROSE_PINE_DAWN,
        "tokyonight" | "tokyo-night" => &TOKYONIGHT,
        "nord" => &NORD,
        "gruvbox" => &GRUVBOX,
        _ => return None,
    })
}

pub fn names() -> Vec<(&'static str, &'static str)> {
    vec![
        ("system", "System"),
        ("dark", "Dark"),
        ("light", "Light"),
        ("catppuccin", "Catppuccin"),
        ("catppuccin-latte", "Catppuccin Latte"),
        ("rose-pine", "Rosé Pine"),
        ("rose-pine-dawn", "Rosé Pine Dawn"),
        ("tokyonight", "TokyoNight"),
        ("nord", "Nord"),
        ("gruvbox", "Gruvbox"),
    ]
}

/// User overrides from ~/.config/macncheese/themes/*.json.
/// Any subset of bg/fg/accent/dim/ok/warn/err/border as "#rrggbb".
pub fn custom(name: &str) -> Option<Palette> {
    let base = dirs::home_dir()?.join(".config/macncheese/themes");
    let mut found = None;
    for entry in std::fs::read_dir(&base).ok()?.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "json")
            && path.file_stem().is_some_and(|s| s == name)
        {
            found = Some(path);
            break;
        }
    }
    // Fall back to the closest built-in for missing slots.
    let base = builtin(name).unwrap_or(&DARK).clone();
    let path = found?;
    let json: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()?;
    let pick = |key: &str, current: Color| {
        json.get(key)
            .and_then(|v| v.as_str())
            .map(rgb)
            .unwrap_or(current)
    };
    Some(Palette {
        bg: pick("bg", base.bg),
        fg: pick("fg", base.fg),
        accent: pick("accent", base.accent),
        dim: pick("dim", base.dim),
        ok: pick("ok", base.ok),
        warn: pick("warn", base.warn),
        err: pick("err", base.err),
        border: pick("border", base.border),
    })
}

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
    if let Ok(text) = std::fs::read_to_string(dirs::home_dir().unwrap_or_default().join(".config/kdeglobals")) {
        for line in text.lines() {
            let line = line.trim().to_lowercase();
            if line.starts_with("colorscheme") {
                return line.contains("dark");
            }
        }
    }
    true
}

pub fn resolve(mode: &str) -> Palette {
    if mode == "system" {
        return if system_dark() { DARK.clone() } else { LIGHT.clone() };
    }
    if let Some(custom) = custom(mode) {
        return custom;
    }
    builtin(mode).cloned().unwrap_or_else(|| {
        if system_dark() { DARK.clone() } else { LIGHT.clone() }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_themes() {
        for name in ["dark", "light", "catppuccin", "rose-pine", "tokyonight", "nord", "gruvbox"] {
            assert!(builtin(name).is_some(), "{name}");
        }
    }

    #[test]
    fn unknown_falls_back() {
        let pal = resolve("nope");
        assert!(matches!(pal.bg, Color::Black | Color::White));
    }

    #[test]
    fn hex_parsing() {
        assert!(matches!(rgb("#cba6f7"), Color::Rgb(203, 166, 247)));
    }
}
