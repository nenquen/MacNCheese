//! Color themes, OpenCode-style: named slots, built-ins embedded in the
//! binary, user overrides in ~/.config/macncheese/themes/*.json.
//!
//! Slots: background, text, muted, accent, ok, warn, err, border.

use ratatui::style::Color;

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
    border: Color::Gray,
};

pub static CATPPUCCIN: Palette = Palette {
    bg: Color::Rgb(24, 24, 37),
    fg: Color::Rgb(205, 214, 244),
    accent: Color::Rgb(203, 166, 247),
    dim: Color::Rgb(108, 112, 134),
    ok: Color::Rgb(166, 227, 161),
    warn: Color::Rgb(249, 226, 175),
    err: Color::Rgb(243, 139, 168),
    border: Color::Rgb(108, 112, 134),
};

pub static ROSE_PINE: Palette = Palette {
    bg: Color::Rgb(25, 23, 36),
    fg: Color::Rgb(224, 222, 244),
    accent: Color::Rgb(196, 167, 231),
    dim: Color::Rgb(110, 106, 134),
    ok: Color::Rgb(156, 207, 216),
    warn: Color::Rgb(246, 193, 119),
    err: Color::Rgb(235, 111, 146),
    border: Color::Rgb(82, 79, 103),
};

pub static TOKYONIGHT: Palette = Palette {
    bg: Color::Rgb(26, 27, 38),
    fg: Color::Rgb(192, 202, 245),
    accent: Color::Rgb(122, 162, 247),
    dim: Color::Rgb(86, 95, 137),
    ok: Color::Rgb(158, 206, 106),
    warn: Color::Rgb(224, 175, 104),
    err: Color::Rgb(247, 118, 142),
    border: Color::Rgb(86, 95, 137),
};

pub static NORD: Palette = Palette {
    bg: Color::Rgb(46, 52, 64),
    fg: Color::Rgb(216, 222, 233),
    accent: Color::Rgb(136, 192, 208),
    dim: Color::Rgb(76, 86, 106),
    ok: Color::Rgb(163, 190, 140),
    warn: Color::Rgb(235, 203, 139),
    err: Color::Rgb(191, 97, 106),
    border: Color::Rgb(76, 86, 106),
};

pub static GRUVBOX: Palette = Palette {
    bg: Color::Rgb(40, 40, 40),
    fg: Color::Rgb(235, 219, 178),
    accent: Color::Rgb(250, 189, 47),
    dim: Color::Rgb(146, 131, 116),
    ok: Color::Rgb(184, 187, 38),
    warn: Color::Rgb(254, 128, 25),
    err: Color::Rgb(251, 73, 52),
    border: Color::Rgb(102, 92, 84),
};

/// The house theme: sampled from the cheese logo (#fbc558 light cheese,
/// #ead9b2 cream, #c36914 baked edge) on a dark toast ground, with the
/// gruvbox-ish supporting colors so everything stays in the same family.
pub static CHEESE: Palette = Palette {
    bg: Color::Rgb(30, 26, 19),      // #1e1a13 dark toast
    fg: Color::Rgb(234, 217, 178),   // #ead9b2 cream (logo highlight)
    accent: Color::Rgb(251, 197, 88), // #fbc558 light cheese (logo)
    dim: Color::Rgb(143, 127, 90),   // #8f7f5a muted gold-brown
    ok: Color::Rgb(169, 182, 101),   // #a9b665 olive green (gruvbox-ish)
    warn: Color::Rgb(231, 138, 78),  // #e78a4e warm orange (baked edge)
    err: Color::Rgb(234, 105, 98),   // #ea6962 gruvbox red
    border: Color::Rgb(90, 77, 56),  // #5a4d38 baked crust
};

pub fn builtin(name: &str) -> Option<&'static Palette> {
    Some(match name {
        "cheese" | "macncheese" => &CHEESE,
        "dark" => &DARK,
        "catppuccin" | "catppuccin-mocha" => &CATPPUCCIN,
        "rose-pine" | "rosepine" | "rose" => &ROSE_PINE,
        "tokyonight" | "tokyo-night" => &TOKYONIGHT,
        "nord" => &NORD,
        "gruvbox" => &GRUVBOX,
        _ => return None,
    })
}

pub fn names() -> Vec<(&'static str, &'static str)> {
    vec![
        ("cheese", "Cheese"),
        ("catppuccin", "Catppuccin"),
        ("rose-pine", "Rosé Pine"),
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

pub fn resolve(mode: &str) -> Palette {
    // No system/light following: the default is the house Cheese theme,
    // and "system" (removed) migrates to it in settings::load().
    if mode == "system" || mode.is_empty() {
        return CHEESE.clone();
    }
    if let Some(custom) = custom(mode) {
        return custom;
    }
    builtin(mode).cloned().unwrap_or_else(|| CHEESE.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_themes() {
        for name in ["cheese", "catppuccin", "rose-pine", "tokyonight", "nord", "gruvbox"] {
            assert!(builtin(name).is_some(), "{name}");
        }
        assert!(builtin("light").is_none(), "no light themes");
        assert!(builtin("system").is_none(), "system theme removed");
        assert!(names().iter().all(|(v, _)| *v != "system"), "no system option");
        assert_eq!(names()[0].0, "cheese", "Cheese is the main theme");
    }

    #[test]
    fn unknown_falls_back() {
        let pal = resolve("nope");
        assert_eq!(pal.bg, CHEESE.bg, "unknown themes fall back to Cheese");
        assert_eq!(resolve("").bg, CHEESE.bg, "empty mode is Cheese too");
        assert_eq!(resolve("system").bg, CHEESE.bg, "stored system -> Cheese");
    }

    #[test]
    fn hex_parsing() {
        assert!(matches!(rgb("#cba6f7"), Color::Rgb(203, 166, 247)));
    }
}
