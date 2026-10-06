//! Filesystem layout. Port of the path block in core.py.
//!
//! The project root is the checkout for git runs, or the directory holding
//! the binary's payload for packages. Everything writable goes to the
//! project when it is writable, else to the XDG user dirs.

use std::path::PathBuf;

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

fn xdg(dir_var: &str, fallback: &[&str]) -> PathBuf {
    if let Ok(v) = std::env::var(dir_var) {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    let mut p = home();
    for part in fallback {
        p.push(part);
    }
    p
}

fn writable(dir: &std::path::Path) -> bool {
    // Mode bits lie on read-only mounts (squashfs shows 0755): probe it.
    let probe = dir.join(".macncheese-write-test");
    match std::fs::create_dir_all(dir) {
        Ok(()) => {}
        Err(_) => return false,
    }
    match std::fs::write(&probe, b"1") {
        Ok(()) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// Repository / payload root: ancestor holding build_debug_shim.sh.
pub fn project() -> PathBuf {
    if let Ok(custom) = std::env::var("MACNCHEESE_PROJECT") {
        let p = PathBuf::from(custom);
        if p.is_dir() {
            return p;
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        // Installed payloads keep launcher/ beside the binary tree.
        let mut dir = exe.parent().map(|p| p.to_path_buf());
        for _ in 0..4 {
            if let Some(d) = dir.clone() {
                if d.join("build_debug_shim.sh").is_file() {
                    return d;
                }
                dir = d.parent().map(|p| p.to_path_buf());
            }
        }
        // AppImage-style payload: usr/share/macncheese under the mount.
        if let Some(d) = exe.parent() {
            let payload = d.join("../share/macncheese");
            if payload.join("build_debug_shim.sh").is_file() {
                if let Ok(c) = payload.canonicalize() {
                    return c;
                }
            }
        }
    }
    // Development fallback: native/../ (repo root).
    let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    if dev.join("build_debug_shim.sh").is_file() {
        return dev;
    }
    xdg("XDG_DATA_HOME", &[".local", "share"]).join("macncheese")
}

pub fn data_dir() -> PathBuf {
    let p = project();
    if writable(&p) {
        return p;
    }
    xdg("XDG_DATA_HOME", &[".local", "share"]).join("macncheese")
}

pub fn cache_dir() -> PathBuf {
    xdg("XDG_CACHE_HOME", &[".cache"]).join("macncheese")
}

pub fn app_bundle() -> PathBuf {
    data_dir().join("RobloxPlayer.app")
}

pub fn build_dir() -> PathBuf {
    data_dir().join("build")
}

pub fn shim() -> PathBuf {
    if let Ok(pre) = std::env::var("MACNCHEESE_PREBUILT_SHIM") {
        if !pre.is_empty() {
            return PathBuf::from(pre).join("libMacNCheeseShims.dylib");
        }
    }
    build_dir().join("libMacNCheeseShims.dylib")
}

pub fn build_script() -> PathBuf {
    project().join("build_debug_shim.sh")
}

pub fn frameworks_build() -> PathBuf {
    // Flatpak builds the stub frameworks once at image build time next
    // to the prebuilt shim; the per-user build dir is not involved.
    if let Ok(pre) = std::env::var("MACNCHEESE_PREBUILT_SHIM") {
        if !pre.is_empty() {
            return PathBuf::from(pre).join("frameworks");
        }
    }
    build_dir().join("frameworks")
}

pub fn logs_dir() -> PathBuf {
    data_dir().join("logs")
}

pub fn quit_sentinel() -> PathBuf {
    cache_dir().join("game-closing")
}

/// Darling prefix (DPREFIX or ~/.darling).
pub fn darling_prefix() -> PathBuf {
    if let Ok(v) = std::env::var("DPREFIX") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    home().join(".darling")
}

/// Darling's macOS sysroot: /usr/libexec, then /usr/local, then /app.
pub fn darling_sysroot() -> PathBuf {
    for cand in [
        "/usr/libexec/darling",
        "/usr/local/libexec/darling",
        "/app/libexec/darling",
    ] {
        if PathBuf::from(cand).is_dir() {
            return PathBuf::from(cand);
        }
    }
    PathBuf::from("/usr/libexec/darling")
}
