//! Host audio: playback/record FIFOs paired with the shim's CoreAudio HAL.
//! Port of HostAudio in core.py (playback side + voice-chat recorder).

use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

use crate::paths;

fn which(name: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {name}")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn runtime_dir() -> PathBuf {
    if let Ok(v) = std::env::var("XDG_RUNTIME_DIR") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }))
}

fn player_command(fifo: &str) -> Option<Vec<String>> {
    let pipewire = std::env::var("PIPEWIRE_REMOTE").is_ok()
        || runtime_dir().join("pipewire-0").exists();
    if pipewire && which("pw-cat") {
        return Some(vec![
            "pw-cat".into(),
            "--playback".into(),
            "--raw".into(),
            "--format".into(),
            "f32".into(),
            "--rate".into(),
            "44100".into(),
            "--channels".into(),
            "2".into(),
            "--latency".into(),
            "40ms".into(),
            "--media-role".into(),
            "Game".into(),
            "-P".into(),
            "{ application.name = \"Roblox\" application.icon-name = \"macncheese\" media.name = \"Roblox viewing\" }}".into(),
            fifo.into(),
        ]);
    }
    if which("pacat") {
        return Some(vec![
            "pacat".into(),
            "--playback".into(),
            "--raw".into(),
            "--format=float32le".into(),
            "--rate=44100".into(),
            "--channels=2".into(),
            "--latency-msec=40".into(),
            "--client-name=Roblox".into(),
            "--stream-name=Roblox viewing".into(),
            "--property=media.role=game".into(),
            fifo.into(),
        ]);
    }
    None
}

fn recorder_command(fifo: &str, rate: u32, channels: u32) -> Option<Vec<String>> {
    let pipewire = std::env::var("PIPEWIRE_REMOTE").is_ok()
        || runtime_dir().join("pipewire-0").exists();
    if pipewire && which("pw-cat") {
        return Some(vec![
            "pw-cat".into(),
            "--record".into(),
            "--raw".into(),
            "--format".into(),
            "f32".into(),
            "--rate".into(),
            rate.to_string(),
            "--channels".into(),
            channels.to_string(),
            "--latency".into(),
            "20ms".into(),
            "--media-role".into(),
            "Communication".into(),
            fifo.into(),
        ]);
    }
    if which("pacat") {
        return Some(vec![
            "pacat".into(),
            "--record".into(),
            "--raw".into(),
            "--format=float32le".into(),
            format!("--rate={rate}"),
            format!("--channels={channels}"),
            "--latency-msec=20".into(),
            "--client-name=Roblox".into(),
            "--stream-name=Roblox microphone (Mac'n Cheese)".into(),
            "--property=media.role=phone".into(),
            fifo.into(),
        ]);
    }
    None
}

fn spawn(cmd: &[String]) -> io::Result<Child> {
    Command::new(&cmd[0])
        .args(&cmd[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

fn make_fifo(path: &std::path::Path) -> io::Result<()> {
    let _ = std::fs::remove_file(path);
    let cpath = std::ffi::CString::new(path.as_os_str().as_encoded_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "fifo path"))?;
    let rc = unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn open_keep(path: &std::path::Path) -> io::Result<std::fs::File> {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC)
        .open(path)
}

pub struct Audio {
    fifo: PathBuf,
    input_fifo: PathBuf,
    request: PathBuf,
    _keep: std::fs::File,
    _input_keep: Option<std::fs::File>,
    player: Child,
    recorder: Option<Child>,
    restarted_at: std::time::Instant,
}

impl Audio {
    pub fn fifo_guest(&self) -> String {
        format!("/Volumes/SystemRoot{}", self.fifo.display())
    }

    pub fn input_fifo_guest(&self) -> String {
        format!("/Volumes/SystemRoot{}", self.input_fifo.display())
    }

    pub fn start() -> Option<Audio> {
        let cache = paths::cache_dir();
        let _ = std::fs::create_dir_all(&cache);
        let pid = std::process::id();
        let fifo = cache.join(format!("audio-{pid}.fifo"));
        let input_fifo = cache.join(format!("audio-in-{pid}.fifo"));
        let request = PathBuf::from(format!("{}.request", input_fifo.display()));
        let cmd = player_command(&fifo.to_string_lossy())?;
        make_fifo(&fifo).ok()?;
        make_fifo(&input_fifo).ok()?;
        let keep = open_keep(&fifo).ok()?;
        let input_keep = open_keep(&input_fifo).ok();
        let player = spawn(&cmd).ok()?;
        Some(Audio {
            fifo,
            input_fifo,
            request,
            _keep: keep,
            _input_keep: input_keep,
            player,
            recorder: None,
            restarted_at: std::time::Instant::now(),
        })
    }

    fn keep_recording(&mut self) {
        let want = std::fs::read_to_string(&self.request)
            .ok()
            .and_then(|s| {
                let mut it = s.trim().split(',');
                let rate = it.next()?.parse().ok()?;
                let channels = it.next()?.parse().ok()?;
                Some((rate, channels))
            });
        match want {
            Some((rate, channels)) => {
                let alive = self.recorder.as_mut().is_some_and(|c| c.try_wait().ok().flatten().is_none());
                if !alive {
                    let _ = self.recorder.take().map(|mut c| c.kill());
                    if let Some(cmd) = recorder_command(&self.input_fifo.to_string_lossy(), rate, channels) {
                        self.recorder = spawn(&cmd).ok();
                    }
                }
            }
            None => {
                if let Some(mut rec) = self.recorder.take() {
                    let _ = rec.kill();
                }
            }
        }
    }

    /// Restart dead players; poll the voice-chat request. Called each second.
    pub fn keep_playing(&mut self) {
        self.keep_recording();
        let dead = self.player.try_wait().ok().flatten().is_some();
        if !dead || self.restarted_at.elapsed() < std::time::Duration::from_secs(5) {
            return;
        }
        self.restarted_at = std::time::Instant::now();
        let cmd = match player_command(&self.fifo.to_string_lossy()) {
            Some(c) => c,
            None => return,
        };
        if let Ok(child) = spawn(&cmd) {
            self.player = child;
        }
    }

    pub fn stop(mut self) {
        let _ = self.recorder.take().map(|mut c| {
            let _ = c.kill();
        });
        let _ = std::fs::remove_file(&self.input_fifo);
        let _ = std::fs::remove_file(&self.request);
        drop(self._keep);
        drop(self._input_keep);
        let _ = self.player.kill();
        let _ = self.player.wait();
        let _ = std::fs::remove_file(&self.fifo);
    }
}
