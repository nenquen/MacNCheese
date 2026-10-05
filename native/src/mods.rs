//! Content mods: sounds, cursors, fonts, overlay folder. Port of mods.py.

use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

use crate::paths;

fn str_of(settings: &Map<String, Value>, key: &str) -> String {
    settings.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

fn bool_of(settings: &Map<String, Value>, key: &str) -> bool {
    settings.get(key).and_then(|v| v.as_bool()).unwrap_or(false)
}

fn content_dir() -> PathBuf {
    paths::app_bundle().join("Contents/Resources/content")
}

fn backup_dir() -> PathBuf {
    paths::data_dir().join("mods_backup")
}

fn mods_dir() -> PathBuf {
    paths::data_dir().join("modifications")
}

fn builtin_mods() -> PathBuf {
    // Payload layout keeps launcher assets beside the binary tree.
    paths::project().join("launcher/macncheese/assets/mods")
}

pub fn ensure_mods_dir() -> PathBuf {
    let dir = mods_dir();
    let _ = std::fs::create_dir_all(&dir);
    let readme = dir.join("README.txt");
    if !readme.exists() {
        let _ = std::fs::write(
            &readme,
            "Place custom files here to override Roblox content.\nFor example: textures/Cursors/KeyboardMouse/ArrowCursor.png\nor sounds/ouch.ogg\n",
        );
    }
    dir
}

fn backup_if_needed(target: &Path, rel: &str) {
    if !target.exists() {
        return;
    }
    let backup = backup_dir().join(rel);
    if backup.exists() {
        return;
    }
    if let Some(parent) = backup.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::copy(target, &backup);
}

fn copy_over(src: &Path, dst: &Path, rel: &str) {
    backup_if_needed(dst, rel);
    if let Some(parent) = dst.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::copy(src, dst);
}

pub fn restore_all(content: &Path) {
    let backup = backup_dir();
    if !content.is_dir() || !backup.is_dir() {
        return;
    }
    let mut stack = vec![backup.clone()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            let Ok(rel) = path.strip_prefix(&backup) else { continue };
            let target = content.join(rel);
            if let Some(parent) = target.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::copy(&path, &target);
        }
    }
    for ext in ["ttf", "otf"] {
        let _ = std::fs::remove_file(content.join("fonts").join(format!("CustomFont.{ext}")));
    }
    let _ = std::fs::remove_dir_all(&backup);
}

pub fn apply(settings: &Map<String, Value>) {
    let content = content_dir();
    if !content.is_dir() {
        return;
    }
    restore_all(&content);

    // 1. Death sound.
    let target_ouch = content.join("sounds/ouch.ogg");
    match str_of(settings, "mod_death_sound").as_str() {
        "classic_oof" => {
            let stock = content.join("sounds/oof.ogg");
            if stock.exists() && target_ouch.exists() {
                copy_over(&stock, &target_ouch, "sounds/ouch.ogg");
            }
        }
        "custom" => {
            let custom = PathBuf::from(str_of(settings, "mod_custom_death_sound"));
            if custom.is_file() {
                copy_over(&custom, &target_ouch, "sounds/ouch.ogg");
            }
        }
        _ => {}
    }

    // 2. Old movement sounds.
    if bool_of(settings, "mod_old_character_sounds") {
        let map = [
            ("sounds/action_footsteps_plastic.mp3", "sounds/OldWalk.mp3"),
            ("sounds/action_jump.mp3", "sounds/OldJump.mp3"),
            ("sounds/action_get_up.mp3", "sounds/OldGetUp.mp3"),
            ("sounds/action_falling.mp3", "sounds/Empty.mp3"),
            ("sounds/action_jump_land.mp3", "sounds/Empty.mp3"),
            ("sounds/action_swim.mp3", "sounds/Empty.mp3"),
            ("sounds/impact_water.mp3", "sounds/Empty.mp3"),
        ];
        for (rel, src) in map {
            let src_file = builtin_mods().join(src);
            if src_file.exists() {
                copy_over(&src_file, &content.join(rel), rel);
            }
        }
    }

    // 3. Cursor presets.
    let cursor_dir = content.join("textures/Cursors/KeyboardMouse");
    match str_of(settings, "mod_cursor_type").as_str() {
        preset @ ("2006" | "2013" | "purple_cross" | "dot") => {
            let dir = builtin_mods().join("cursors").join(preset);
            if let Ok(entries) = std::fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    let src = entry.path();
                    if src.extension().is_some_and(|e| e == "png") {
                        let name = src.file_name().unwrap().to_string_lossy().into_owned();
                        copy_over(&src, &cursor_dir.join(&name),
                                  &format!("textures/Cursors/KeyboardMouse/{name}"));
                    }
                }
            }
        }
        "custom" => {
            let p = PathBuf::from(str_of(settings, "mod_custom_cursor"));
            if p.is_file() && p.extension().is_some_and(|e| e.eq_ignore_ascii_case("png")) {
                for name in ["ArrowCursor.png", "ArrowFarCursor.png"] {
                    copy_over(&p, &cursor_dir.join(name),
                              &format!("textures/Cursors/KeyboardMouse/{name}"));
                }
            } else if p.is_dir() {
                if let Ok(entries) = std::fs::read_dir(&p) {
                    for entry in entries.flatten() {
                        let src = entry.path();
                        if src.extension().is_some_and(|e| e.eq_ignore_ascii_case("png")) {
                            let name = src.file_name().unwrap().to_string_lossy().into_owned();
                            copy_over(&src, &cursor_dir.join(&name),
                                      &format!("textures/Cursors/KeyboardMouse/{name}"));
                        }
                    }
                }
            }
        }
        _ => {}
    }

    // 4. Custom font.
    let font_path = PathBuf::from(str_of(settings, "mod_custom_font"));
    if font_path.is_file() {
        let ext = font_path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
        if ext == "ttf" || ext == "otf" {
            let dest = content.join("fonts").join(format!("CustomFont.{ext}"));
            if let Some(parent) = dest.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::copy(&font_path, &dest);
            let uri = format!("rbxasset://fonts/CustomFont.{ext}");
            let families = content.join("fonts/families");
            if let Ok(entries) = std::fs::read_dir(&families) {
                for entry in entries.flatten() {
                    let jf = entry.path();
                    if jf.extension().is_some_and(|e| e == "json") {
                        backup_if_needed(&jf, &format!("fonts/families/{}", jf.file_name().unwrap().to_string_lossy()));
                        if let Ok(text) = std::fs::read_to_string(&jf) {
                            if let Ok(mut data) = serde_json::from_str::<Value>(&text) {
                                let mut touched = false;
                                if let Some(faces) = data.get_mut("faces").and_then(|f| f.as_array_mut()) {
                                    for face in faces.iter_mut() {
                                        if face.is_object() {
                                            face["assetId"] = Value::from(uri.clone());
                                            touched = true;
                                        }
                                    }
                                }
                                if touched {
                                    let _ = std::fs::write(&jf, serde_json::to_string_pretty(&data).unwrap_or_default());
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 5. User overlay folder (with _Delete markers).
    let dir = ensure_mods_dir();
    let mut stack = vec![dir.clone()];
    while let Some(d) = stack.pop() {
        let entries = match std::fs::read_dir(&d) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let src = entry.path();
            if src.is_dir() {
                stack.push(src);
                continue;
            }
            let name = src.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if name == "README.txt" || name == ".DS_Store" {
                continue;
            }
            let Ok(rel) = src.strip_prefix(&dir) else { continue };
            let stem = src.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            let suffix = src.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
            if stem.ends_with("_Delete") {
                let target = content.join(rel.parent().unwrap_or(Path::new(""))).join(format!("{}{suffix}", &stem[..stem.len() - 7]));
                if target.exists() {
                    backup_if_needed(&target, &target.strip_prefix(&content).unwrap_or(&target).to_string_lossy().into_owned());
                    let _ = std::fs::remove_file(&target);
                }
                continue;
            }
            let dst = content.join(rel);
            copy_over(&src, &dst, &rel.to_string_lossy());
        }
    }
}
