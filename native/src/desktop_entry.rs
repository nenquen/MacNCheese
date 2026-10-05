//! Desktop integration: menu entry + icons so Wayland/X11 show the
//! cheese logo instead of a generic icon. Matches app_id
//! com.nenquen.Macncheese set on the winit window.

use std::path::PathBuf;

use crate::paths;

const APP_ID: &str = "com.nenquen.Macncheese";

fn data_home() -> PathBuf {
    match std::env::var("XDG_DATA_HOME") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => dirs::home_dir().unwrap_or_default().join(".local/share"),
    }
}

fn desktop_file(exe: &str) -> String {
    format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Mac'n Cheese\n\
         Comment=Run the macOS Roblox client on Linux through Darling\n\
         Exec={exe} %u\n\
         Icon=macncheese\n\
         Terminal=false\n\
         Categories=Game;\n\
         Keywords=roblox;darling;\n\
         StartupNotify=true\n\
         StartupWMClass={APP_ID}\n\
         MimeType=x-scheme-handler/roblox;x-scheme-handler/roblox-player;\n"
    )
}

/// Install/refresh ~/.local/share/applications/<APP_ID>.desktop and the
/// hicolor icons. Only writes missing or outdated files.
pub fn ensure_menu_entry() {
    // Inside an AppImage the binary lives under a volatile FUSE mount:
    // point Exec at the stable AppImage path instead, or KWin treats the
    // entry as broken and shows a generic icon.
    let exe = match std::env::var("APPIMAGE") {
        Ok(p) if !p.is_empty() => p,
        _ => std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "macncheese".into()),
    };
    let desktop = desktop_file(&exe);
    let apps = data_home().join("applications");
    let target = apps.join(format!("{APP_ID}.desktop"));
    let stale = std::fs::read_to_string(&target).ok().as_deref() != Some(desktop.as_str());
    if stale {
        if std::fs::create_dir_all(&apps).is_ok() {
            let _ = std::fs::write(&target, &desktop);
        }
    }
    // The game window itself (X11 class RobloxPlayer) gets the same icon
    // in docks, or it falls back to a generic one.
    let game_entry = "[Desktop Entry]\n\
        Type=Application\n\
        Name=Roblox (Mac'n Cheese)\n\
        Exec=macncheese\n\
        Icon=macncheese\n\
        NoDisplay=true\n\
        StartupWMClass=RobloxPlayer\n";
    let game_target = apps.join("macncheese-roblox-window.desktop");
    if std::fs::read_to_string(&game_target).ok().as_deref() != Some(game_entry) {
        let _ = std::fs::create_dir_all(&apps);
        let _ = std::fs::write(&game_target, game_entry);
    }
    // Icons from the payload (AppImage) or the checkout.
    let sources = paths::project().join("branding/icons");
    let mut touched = false;
    for size in [16, 22, 24, 32, 48, 64, 128, 256, 512] {
        let src = sources.join(format!("macncheese-{size}.png"));
        let dst = data_home()
            .join(format!("icons/hicolor/{size}x{size}/apps/macncheese.png"));
        let fresh = match (std::fs::metadata(&dst), std::fs::metadata(&src)) {
            (Ok(d), Ok(s)) => {
                match (d.modified(), s.modified()) {
                    (Ok(dt), Ok(st)) => dt >= st && d.len() == s.len(),
                    _ => false,
                }
            }
            _ => false,
        };
        if fresh {
            continue;
        }
        if dst.parent().map(std::fs::create_dir_all).is_some_and(|r| r.is_ok()) {
            if std::fs::copy(&src, &dst).is_ok() {
                touched = true;
            }
        }
    }
    if stale || touched {
        let _ = std::process::Command::new("update-desktop-database")
            .arg(&apps)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_entry_matches_wayland_app_id() {
        let text = desktop_file("/usr/bin/macncheese");
        assert!(text.contains("StartupWMClass=com.nenquen.Macncheese"));
        assert!(text.contains("Terminal=false"));
        assert!(text.contains("Exec=/usr/bin/macncheese %u"));
        assert!(text.contains("Icon=macncheese"));
    }
}
