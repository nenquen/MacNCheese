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

pub static CATPPUCCIN: Palette = Palette {
    bg: Color::Rgb(30, 30, 46),
    fg: Color::Rgb(205, 214, 244),
    accent: Color::Rgb(203, 166, 247),
    dim: Color::Rgb(108, 112, 134),
    ok: Color::Rgb(166, 227, 161),
    err: Color::Rgb(243, 139, 168),
};

pub static ROSE_PINE: Palette = Palette {
    bg: Color::Rgb(25, 23, 36),
    fg: Color::Rgb(224, 222, 244),
    accent: Color::Rgb(196, 167, 231),
    dim: Color::Rgb(110, 106, 134),
    ok: Color::Rgb(156, 207, 216),
    err: Color::Rgb(235, 111, 146),
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
        "catppuccin" => &CATPPUCCIN,
        "rose-pine" | "rosepine" | "rose" => &ROSE_PINE,
        _ => {
            if system_dark() {
                &DARK
            } else {
                &LIGHT
            }
        }
    }
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
    fn theme_names_resolve() {
        assert!(std::ptr::eq(resolve("catppuccin"), &CATPPUCCIN));
        assert!(std::ptr::eq(resolve("rose-pine"), &ROSE_PINE));
        assert!(std::ptr::eq(resolve("rose"), &ROSE_PINE));
        assert!(std::ptr::eq(resolve("nope"), resolve("system")));
    }
}
