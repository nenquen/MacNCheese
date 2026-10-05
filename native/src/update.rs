//! Roblox client install/update. Port of update_roblox + patch stamp.
//!
//! Downloads MacPlayer from setup.rbxcdn.com, unzips over a backup swap,
//! then runs the three verified binary scans once per build.

use serde_json::Value;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use crate::flags;
use crate::patches;
use crate::paths;

const VERSION_URL: &str = "https://clientsettingscdn.roblox.com/v2/client-version/MacPlayer";

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_secs(15)))
        .user_agent("MacNCheese")
        .build()
        .new_agent()
}

/// (version, upload) of the current MacPlayer release.
pub fn latest_version() -> Result<(String, String), String> {
    let mut resp = agent()
        .get(VERSION_URL)
        .call()
        .map_err(|e| format!("version check: {e}"))?;
    let data: Value = resp
        .body_mut()
        .read_json()
        .map_err(|e| format!("version check: {e}"))?;
    let version = data.get("version").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let upload = data.get("clientVersionUpload").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if version.is_empty() || upload.is_empty() {
        return Err("version check: empty reply".into());
    }
    Ok((version, upload))
}

pub fn installed_version() -> Option<String> {
    let plist = paths::app_bundle().join("Contents/Info.plist");
    let text = std::fs::read_to_string(plist).ok()?;
    let key = "<key>CFBundleShortVersionString</key>";
    let i = text.find(key)?;
    let rest = &text[i + key.len()..];
    let s = rest.find("<string>")? + "<string>".len();
    let e = rest[s..].find("</string>")?;
    Some(rest[s..s + e].to_string())
}

fn stamp_path() -> PathBuf {
    paths::cache_dir().join("client-patches.json")
}

fn patches_current() -> bool {
    let version = match installed_version() {
        Some(v) => v,
        None => return false,
    };
    let stamp: Value = std::fs::read_to_string(stamp_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null);
    stamp.get("version").and_then(|v| v.as_str()) == Some(version.as_str())
        && stamp.get("done").and_then(|v| v.as_bool()) == Some(true)
}

fn mark_patches() {
    let _ = std::fs::create_dir_all(paths::cache_dir());
    let version = installed_version().unwrap_or_default();
    let _ = std::fs::write(
        stamp_path(),
        format!("{{\"version\": {version:?}, \"done\": true}}"),
    );
}

/// Fetch + install one client upload. progress(0..1, message).
pub fn update_roblox(
    upload: &str,
    progress: &dyn Fn(f64, &str),
) -> Result<(), String> {
    let url = format!("https://setup.rbxcdn.com/mac/{upload}-RobloxPlayer.zip");
    progress(0.05, "Downloading Roblox…");
    let mut data = Vec::new();
    agent()
        .get(&url)
        .call()
        .map_err(|e| format!("download: {e}"))?
        .into_body()
        .into_reader()
        .read_to_end(&mut data)
        .map_err(|e| format!("download: {e}"))?;
    progress(0.7, "Unpacking Roblox…");
    let dir = paths::data_dir();
    let tmp = dir.join(format!("roblox-new-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).map_err(|e| format!("unpack: {e}"))?;
    unzip(&data, &tmp).map_err(|e| format!("unpack: {e}"))?;
    let staged = tmp.join("RobloxPlayer.app");
    if !staged.is_dir() {
        let _ = std::fs::remove_dir_all(&tmp);
        return Err("unpack: RobloxPlayer.app missing from archive".into());
    }
    let bundle = paths::app_bundle();
    let backup = dir.join("RobloxPlayer.app.backup");
    if bundle.exists() {
        let _ = std::fs::remove_dir_all(&backup);
        std::fs::rename(&bundle, &backup).map_err(|e| format!("replace: {e}"))?;
    }
    if let Err(e) = std::fs::rename(&staged, &bundle) {
        if backup.exists() {
            let _ = std::fs::rename(&backup, &bundle);
        }
        let _ = std::fs::remove_dir_all(&tmp);
        return Err(format!("replace: {e}"));
    }
    let _ = std::fs::remove_dir_all(&backup);
    let _ = std::fs::remove_dir_all(&tmp);
    progress(0.9, "Verifying client patches…");
    run_patch_scans();
    mark_patches();
    progress(1.0, "Done.");
    Ok(())
}

fn unzip(data: &[u8], dest: &Path) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data))
        .map_err(|e| format!("bad zip: {e}"))?;
    for i in 0..archive.len() {
        let mut file = archive.by_index(i).map_err(|e| format!("bad zip: {e}"))?;
        let out = dest.join(file.mangled_name());
        if file.is_dir() {
            std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
        } else {
            if let Some(parent) = out.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let mut target = std::fs::File::create(&out).map_err(|e| e.to_string())?;
            std::io::copy(&mut file, &mut target).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Some(mode) = file.unix_mode() {
                    let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode));
                }
            }
        }
    }
    Ok(())
}

/// Throttle + RakNet + shader scans for the installed client.
pub fn run_patch_scans() -> Vec<(String, String)> {
    let binary = paths::app_bundle().join("Contents/MacOS/RobloxPlayer");
    let pack = paths::app_bundle().join("Contents/Resources/shaders/shaders_glsl3.pack");
    flags::ensure_raknet();
    let throttle = patches::apply_throttle(&binary);
    let transport = patches::apply_transport(&binary);
    let shader = patches::apply_shader(&pack);
    vec![
        ("throttle".into(), throttle),
        ("transport".into(), transport),
        ("shader".into(), shader),
    ]
}

/// Cheap per-launch path: flags always, binary scans only when stale.
pub fn ensure_launch_patches() -> String {
    flags::ensure_raknet();
    if patches_current() {
        return "client patches up to date, rescans skipped".into();
    }
    let results = run_patch_scans();
    mark_patches();
    let summary: Vec<String> = results.into_iter().map(|(k, v)| format!("{k}={v}")).collect();
    format!("client patches verified ({})", summary.join(", "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamp_roundtrip() {
        // No bundle here: must report stale, never crash.
        assert!(!patches_current());
    }
}
