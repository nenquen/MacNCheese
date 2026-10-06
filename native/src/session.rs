//! One run of the macOS client under Darling. Port of RobloxSession.
//!
//! v1 scope: default OpenGL/X11 path, system DNS, no mods/web/MangoHud.
//! Vulkan dependency install, custom DNS proxy and the kqueue runtime
//! repair stay in the Python launcher until ported.

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::audio::Audio;
use crate::paths;

const STUB_FRAMEWORKS: &[&str] = &["CoreML", "CoreHaptics", "DeviceCheck"];

const TRACE_ENV: &[(&str, &str)] = &[
    ("diagnostic_signals", "MACNCHEESE_DIAGNOSTIC_SIGNALS"),
    ("trace_udp", "MACNCHEESE_TRACE_UDP"),
    ("trace_lock", "MACNCHEESE_TRACE_LOCK"),
    ("trace_events", "MACNCHEESE_TRACE_EVENTS"),
    ("trace_gl", "MACNCHEESE_TRACE_GL"),
    ("fps_log", "MACNCHEESE_FPS_LOG"),
    ("trace_keys", "MACNCHEESE_TRACE_KEYS"),
];

const LAUNCH_SCRIPT: &str = r#"project=$1 shim_dir=$2 launch_uri=$3; shift 3
for kv in "$@"; do export "$kv"; done
case ${MACNCHEESE_FRAMERATE_CAP:-} in
  '' | *[!0-9]*) ;;
  *)
    cap_file="$HOME/Library/Roblox/GlobalBasicSettings_13.xml"
    if [ -f "$cap_file" ]; then
      content=$(<"$cap_file")
      wanted="<int name=\"FramerateCap\">$MACNCHEESE_FRAMERATE_CAP</int>"
      pattern='<int name="FramerateCap">-?[0-9]+</int>'
      if [[ $content =~ $pattern ]]; then
        old=${BASH_REMATCH[0]}
        content=${content/$old/$wanted}
      else
        close='</Properties>'
        insert=$'\t'"$wanted"$'\n\t\t</Properties>'
        content=${content/$close/$insert}
      fi
      printf '%s\n' "$content" > "$cap_file"
    fi ;;
esac
app="$project/RobloxPlayer.app/Contents/MacOS"
cd "$app" || exit 1
export DYLD_FORCE_FLAT_NAMESPACE=1
export DYLD_INSERT_LIBRARIES="$shim_dir/libMacNCheeseShims.dylib"
export DYLD_LIBRARY_PATH="$shim_dir:$app"
if [ -n "$launch_uri" ]; then
  export MACNCHEESE_PENDING_URI="$launch_uri"
  exec ./RobloxPlayer -protocolString "$launch_uri"
fi
exec ./RobloxPlayer
"#;

fn have(cmd: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {cmd}")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Programs the launch needs that are missing.
pub fn missing_tools() -> Vec<String> {
    let mut missing = ["darling", "unzip", "pw-cat"]
        .into_iter()
        .filter(|t| !have(t))
        .filter(|t| *t != "pw-cat" || !have("pacat"))
        .map(str::to_string)
        .collect::<Vec<_>>();
    // clang/lld are only needed to compile the shim; Flatpak ships a
    // prebuilt one (MACNCHEESE_PREBUILT_SHIM), so don't demand a
    // toolchain when there is nothing to build.
    if !shim_built() {
        for tool in ["clang", "ld.lld"] {
            if !have(tool) {
                missing.push(tool.into());
            }
        }
    }
    missing
}

/// Append a diagnostics line to logs/session.log — launch mysteries
/// otherwise end up as screenshot archaeology.
pub(crate) fn log_line(msg: &str) {
    let dir = paths::data_dir().join("logs");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("session.log"))
    {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "[{t}] {msg}");
    }
}

fn source_files() -> Vec<PathBuf> {
    let shim = paths::project().join("shim");
    let mut out = vec![paths::build_script()];
    for ext in ["c", "m", "h", "cpp"] {
        if let Ok(entries) = std::fs::read_dir(&shim) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().is_some_and(|e| e == ext) {
                    out.push(p);
                }
            }
        }
    }
    out.sort();
    out
}

/// Built dylib newer than every source (mtime heuristic; the Python
/// launcher uses a content hash, equivalent outcome).
pub fn shim_built() -> bool {
    let dylib = paths::shim();
    if !dylib.is_file() {
        return false;
    }
    for name in STUB_FRAMEWORKS {
        if !paths::frameworks_build()
            .join(format!("{name}.framework"))
            .join(name)
            .is_file()
        {
            return false;
        }
    }
    // A prebuilt payload (Flatpak, MACNCHEESE_PREBUILT_SHIM) is
    // immutable: updates arrive with the app image, so source mtimes
    // carry no signal — existence above is all we can check.
    if std::env::var("MACNCHEESE_PREBUILT_SHIM").is_ok_and(|v| !v.is_empty()) {
        return true;
    }
    let built = match std::fs::metadata(&dylib).and_then(|m| m.modified()) {
        Ok(t) => t,
        Err(_) => return false,
    };
    source_files().into_iter().all(|src| {
        std::fs::metadata(&src)
            .and_then(|m| m.modified())
            .map(|t| t <= built)
            .unwrap_or(false)
    })
}

pub fn build_shim() -> Result<String, String> {
    let out = Command::new(paths::build_script())
        .env("MACNCHEESE_BUILD_DIR", paths::build_dir())
        .env("DARLING_SYSROOT", paths::darling_sysroot())
        .output()
        .map_err(|e| format!("could not run build script: {e}"))?;
    let mut log = String::from_utf8_lossy(&out.stdout).into_owned();
    log.push_str(&String::from_utf8_lossy(&out.stderr));
    if out.status.success() {
        Ok(log)
    } else {
        Err(log)
    }
}

fn install_framework(name: &str) -> std::io::Result<()> {
    let frameworks = paths::darling_prefix()
        .join("System")
        .join("Library")
        .join("Frameworks");
    std::fs::create_dir_all(&frameworks)?;
    let target = frameworks.join(format!("{name}.framework"));
    let staged = frameworks.join(format!(".{name}.framework.new"));
    let old = frameworks.join(format!(".{name}.framework.old"));
    for leftover in [&staged, &old] {
        if leftover.is_dir() && !leftover.is_symlink() {
            let _ = std::fs::remove_dir_all(leftover);
        }
    }
    copy_dir(
        &paths::frameworks_build().join(format!("{name}.framework")),
        &staged,
    )?;
    if target.exists() || target.is_symlink() {
        let _ = std::fs::rename(&target, &old);
    }
    std::fs::rename(&staged, &target)?;
    let _ = std::fs::remove_dir_all(&old);
    Ok(())
}

fn copy_dir(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let (s, d) = (entry.path(), dst.join(entry.file_name()));
        let meta = std::fs::symlink_metadata(&s)?;
        if meta.file_type().is_symlink() {
            let link = std::fs::read_link(&s)?;
            std::os::unix::fs::symlink(link, d)?;
        } else if meta.is_dir() {
            copy_dir(&s, &d)?;
        } else {
            std::fs::copy(&s, &d)?;
        }
    }
    Ok(())
}

fn darlingserver_running() -> bool {
    let uid = unsafe { libc::getuid() }.to_string();
    Command::new("pgrep")
        .args(["-u", &uid, "-x", "darlingserver"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn darling_shutdown() {
    let _ = Command::new("darling")
        .arg("shutdown")
        .envs(base_env(false))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Copy stub frameworks into the stopped prefix's upper layer.
pub fn prepare_prefix() -> Result<(), String> {
    if !paths::darling_prefix().is_dir() {
        let env = base_env(false);
        let _ = Command::new("darling")
            .args(["shell", "true"])
            .envs(&env)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        if !paths::darling_prefix().is_dir() {
            return Err("Darling could not create its prefix".into());
        }
    }
    if darlingserver_running() {
        darling_shutdown();
    }
    for name in STUB_FRAMEWORKS {
        install_framework(name).map_err(|e| format!("framework {name}: {e}"))?;
    }
    Ok(())
}

fn base_env(wayland: bool) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = std::env::vars().collect();
    // The Flatpak cannot carry the setuid bit, so `darling` refuses to
    // start unless the fake-root library stands in for root (only
    // darling/darlingserver act on it; other roles pass through, see
    // flatpak/darling-noroot.c). On the host the setuid bit exists and
    // the loader ignores LD_PRELOAD for it anyway.
    if let Ok(pre) = std::env::var("MACNCHEESE_NOROOT_LIB") {
        if !pre.is_empty() && std::path::Path::new(&pre).is_file() {
            env.insert("LD_PRELOAD".into(), pre);
        }
    }
    if wayland {
        env.insert("EGL_PLATFORM".into(), "wayland".into());
        env.remove("DISPLAY");
    } else {
        env.insert("EGL_PLATFORM".into(), "x11".into());
    }
    env
}

fn host_vram_bytes() -> Option<u64> {
    let mut best: Option<u64> = None;
    let entries = std::fs::read_dir("/sys/class/drm").ok()?;
    for card in entries.flatten() {
        let total_path = card.path().join("device/mem_info_vram_total");
        let total: u64 = std::fs::read_to_string(&total_path).ok()?.trim().parse().ok()?;
        let used: u64 = std::fs::read_to_string(card.path().join("device/mem_info_vram_used"))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(total / 4);
        if total < 64 * 1024 * 1024 || used > total {
            continue;
        }
        let free = total - used;
        let reserve = (256 * 1024 * 1024).min(total / 4);
        let budget = (64 * 1024 * 1024).max((total * 3 / 4).min(free.saturating_sub(reserve)));
        best = Some(best.map_or(budget, |b: u64| b.min(budget)));
    }
    // Unknown adapter: conservative 512 MiB, never an invented 8 GiB.
    Some(best.unwrap_or(512 * 1024 * 1024))
}

fn shim_variables(settings: &serde_json::Map<String, serde_json::Value>) -> Result<(Vec<String>, bool), String> {
    let get = |k: &str| settings.get(k);
    let f64_of = |k: &str, d: f64| get(k).and_then(|v| v.as_f64()).unwrap_or(d);
    let bool_of = |k: &str, d: bool| get(k).and_then(|v| v.as_bool()).unwrap_or(d);
    let cache = paths::cache_dir();
    let mut vars = vec![
        format!("MACNCHEESE_MOUSE_SENSITIVITY={:.2}", f64_of("mouse_sensitivity", 1.0)),
        format!("MACNCHEESE_SCROLL_SENSITIVITY={:.2}", f64_of("scroll_sensitivity", 1.5)),
        format!("MESA_SHADER_CACHE_DIR={}", cache.join("mesa-shader-cache").display()),
        format!("MESA_GLSL_CACHE_DIR={}", cache.join("mesa-shader-cache").display()),
        format!("__GL_SHADER_DISK_CACHE_PATH={}", cache.join("nvidia-shader-cache").display()),
        format!("TMPDIR=/Volumes/SystemRoot{}", cache.join("roblox-tmp").display()),
    ];
    let dpi = settings
        .get("dpi_scale")
        .map(crate::settings::validated_dpi_scale)
        .unwrap_or(1.0);
    vars.push(format!("MACNCHEESE_DPI_SCALE={dpi:.3}"));
    let backend = settings
        .get("display_backend")
        .and_then(|v| v.as_str())
        .unwrap_or("x11");
    let helper = crate::paths::shim().parent()
        .map(|p| p.join("libmacncheese-wayland.so"))
        .unwrap_or_default();
    let wayland = match crate::display::window_environment(backend, &helper) {
        Ok(pairs) => {
            let mut is_wayland = false;
            for (k, v) in pairs {
                if k == "MACNCHEESE_WAYLAND" && v == "1" {
                    is_wayland = true;
                }
                vars.push(format!("{k}={v}"));
            }
            is_wayland
        }
        Err(e) => return Err(e),
    };
    if let Some(vram) = host_vram_bytes() {
        vars.push(format!("MACNCHEESE_VRAM_BYTES={vram}"));
    }
    if let Some(icon) = crate::icon::icon_argb_file() {
        vars.push(format!("MACNCHEESE_ICON_ARGB={}", icon.display()));
    }
    if bool_of("hide_menu_bar", true) {
        vars.push("MACNCHEESE_HIDE_MENU_BAR=1".into());
    }
    if !bool_of("raw_mouse", true) {
        vars.push("MACNCHEESE_RAW_MOUSE=0".into());
    }
    let cap = get("framerate_cap").and_then(|v| v.as_u64()).unwrap_or(0);
    if cap > 0 {
        vars.push(format!("MACNCHEESE_FRAMERATE_CAP={cap}"));
    }
    // Trace toggles straight through.
    for (key, name) in TRACE_ENV {
        if bool_of(key, false) {
            vars.push(format!("{name}=1"));
        }
    }
    Ok((vars, wayland))
}

pub struct Session {
    pub log_path: Option<PathBuf>,
    process: Option<Child>,
    audio: Option<Audio>,
    seen_roblox: bool,
}

impl Session {
    pub fn start(
        settings: &serde_json::Map<String, serde_json::Value>,
        launch_uri: Option<String>,
    ) -> Result<Session, String> {
        let missing = missing_tools();
        if !missing.is_empty() {
            let msg = format!(
                "missing programs: {} | shim_built={} prebuilt={:?} pid={}",
                missing.join(", "),
                shim_built(),
                std::env::var("MACNCHEESE_PREBUILT_SHIM"),
                std::process::id()
            );
            log_line(&format!("start refused: {msg}"));
            return Err(msg);
        }
        log_line(&format!(
            "start ok: shim_built={} prebuilt={:?} pid={} client={:?}",
            shim_built(),
            std::env::var("MACNCHEESE_PREBUILT_SHIM"),
            std::process::id(),
            crate::update::installed_version()
        ));
        if !shim_built() {
            build_shim()?;
        }
        let t0 = Instant::now();
        prepare_prefix()?;
        let prefix_took = t0.elapsed().as_secs_f32();
        crate::flags::ensure_raknet();
        crate::update::ensure_launch_patches();
        crate::mods::apply(settings);

        let (mut vars, wayland) = shim_variables(settings)?;
        let audio = Audio::start();
        match &audio {
            Some(a) => {
                vars.push(format!("MACNCHEESE_AUDIO_FIFO={}", a.fifo_guest()));
                vars.push(format!("MACNCHEESE_AUDIO_INPUT_FIFO={}", a.input_fifo_guest()));
            }
            None => vars.push("MACNCHEESE_AUDIO=0".into()),
        }

        // Warm the server: the first process after start can fail check-in.
        let t1 = Instant::now();
        if !darlingserver_running() {
            let env = base_env(wayland);
            let _ = Command::new("darling")
                .args(["shell", "true"])
                .envs(&env)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        let warmup_took = t1.elapsed().as_secs_f32();

        // A sentinel left over from a quit that outlived the launcher must
        // not end this session before it starts.
        let _ = std::fs::remove_file(paths::quit_sentinel());
        let logs = paths::logs_dir();
        let _ = std::fs::create_dir_all(&logs);
        let _ = std::fs::create_dir_all(paths::cache_dir().join("mesa-shader-cache"));
        let _ = std::fs::create_dir_all(paths::cache_dir().join("nvidia-shader-cache"));
        let _ = std::fs::create_dir_all(paths::cache_dir().join("roblox-tmp"));
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let log_path = logs.join(format!("launch-n{stamp}.log"));
        let mut log = std::fs::File::create(&log_path)
            .map_err(|e| format!("cannot open log: {e}"))?;
        writeln!(log, "Mac'n Cheese {}", env!("CARGO_PKG_VERSION")).ok();
        writeln!(
            log,
            "Prefix preparation took {prefix_took:.1} s; Darling warmup took {warmup_took:.1} s"
        )
        .ok();
        log.flush().ok();

        let data = paths::data_dir();
        let shim_parent = paths::shim()
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(paths::build_dir);
        let mut command = vec![
            "darling".to_string(),
            "shell".to_string(),
            "/bin/bash".to_string(),
            "-c".to_string(),
            LAUNCH_SCRIPT.to_string(),
            "macncheese".to_string(),
            format!("/Volumes/SystemRoot{}", data.display()),
            format!("/Volumes/SystemRoot{}", shim_parent.display()),
            launch_uri.unwrap_or_default(),
        ];
        command.extend(vars);
        let log_file = std::fs::File::create(&log_path).map_err(|e| format!("log: {e}"))?;
        let stderr = log_file.try_clone().map_err(|e| format!("log: {e}"))?;
        let child = Command::new("darling")
            .args(&command[1..])
            .envs(base_env(wayland))
            .stdin(Stdio::null())
            .stdout(log_file)
            .stderr(stderr)
            .spawn()
            .map_err(|e| format!("could not start darling: {e}"))?;

        // Crash-handler suppression thread (slow dumps block exit).
        std::thread::spawn(|| {
            for _ in 0..10 {
                std::thread::sleep(std::time::Duration::from_secs(2));
                let out = Command::new("pgrep")
                    .args(["-f", "RobloxCrashHandler"])
                    .output();
                let hit = out.map(|o| !o.stdout.is_empty()).unwrap_or(false);
                if hit {
                    let _ = Command::new("pkill")
                        .args(["-f", "RobloxCrashHandler"])
                        .status();
                    break;
                }
            }
        });

        Ok(Session {
            log_path: Some(log_path),
            process: Some(child),
            audio,
            seen_roblox: false,
        })
    }

    /// True once the game process itself has been observed.
    fn game_seen() -> bool {
        Command::new("pgrep")
            .args(["-f", "RobloxPlayer"])
            .output()
            .map(|o| !o.stdout.is_empty())
            .unwrap_or(false)
    }

    /// None while running, else the exit status.
    pub fn poll(&mut self) -> Option<i32> {
        let status = match self.process.as_mut() {
            Some(child) => match child.try_wait() {
                Ok(Some(s)) => s.code(),
                Ok(None) => {
                    if let Some(audio) = self.audio.as_mut() {
                        audio.keep_playing();
                    }
                    // The shim touches the sentinel when Roblox starts
                    // terminating; teardown takes seconds, the session can
                    // end for the user as soon as quitting began.
                    if !self.seen_roblox {
                        self.seen_roblox = Self::game_seen();
                    } else if crate::paths::quit_sentinel().exists() {
                        self.finish();
                        return Some(0);
                    }
                    return None;
                }
                Err(_) => Some(-1),
            },
            None => Some(-1),
        };
        self.finish();
        status
    }

    /// Never blocks: kill, reap what exits at once, reaper thread takes
    /// the rest. Called from the UI tick; a blocking wait here froze the
    /// whole window ("not responding") after Roblox quit.
    pub fn finish(&mut self) {
        if let Some(mut child) = self.process.take() {
            let _ = child.kill();
            match child.try_wait() {
                Ok(Some(_)) => {}
                _ => {
                    std::thread::spawn(move || {
                        let _ = child.wait();
                    });
                }
            }
        }
        if let Some(audio) = self.audio.take() {
            audio.stop();
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.finish();
    }
}
