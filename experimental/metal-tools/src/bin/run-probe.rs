//! Run the native Vulkan experiment in a disposable Darling prefix.
//! Port of experimental/metal/run_probe.py.
use anyhow::{bail, Result};
use std::os::unix::fs::FileTypeExt;
use std::path::PathBuf;

fn arg(flag: &str) -> Option<String> {
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        if a == flag {
            return it.next();
        }
        if let Some(v) = a.strip_prefix(&format!("{flag}=")) {
            return Some(v.to_string());
        }
    }
    None
}

fn present() -> bool {
    std::env::args().skip(1).any(|a| a == "--device")
}

fn main() -> Result<()> {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let work = arg("--work").map(PathBuf::from).unwrap_or_else(|| repo.join("work/metal-backend-repro"));
    let prefix = arg("--prefix").map(PathBuf::from).unwrap_or_else(|| work.join("prefix"));
    let baseline = arg("--baseline").map(PathBuf::from);
    let vertex = arg("--vertex").map(PathBuf::from);
    let fragment = arg("--fragment").map(PathBuf::from);
    let marker = prefix.join(".macncheese-metal-experiment");

    if prefix.exists() && !marker.is_file() {
        bail!("Refusing an existing prefix without the experiment marker; choose a new path.");
    }
    if !prefix.exists() {
        match baseline {
            Some(base) => copy_disposable(&base, &prefix)?,
            None => std::fs::create_dir_all(&prefix)?,
        }
        std::fs::write(&marker, "Disposable native Metal/Vulkan experiment prefix\n")?;
    }
    let arguments: Vec<PathBuf> = if present() {
        vec![work.join("out/device-probe")]
    } else if let (Some(v), Some(f)) = (vertex, fragment) {
        vec![work.join("out/pipeline-probe"), v, f]
    } else {
        eprintln!("choose --device or provide both --vertex and --fragment");
        std::process::exit(2);
    };
    for argument in &arguments {
        if !argument.is_file() {
            bail!("Probe input is missing: {}", argument.display());
        }
    }
    let host = |p: &PathBuf| format!("/Volumes/SystemRoot{}", p.display());
    let exports = [
        ("DYLD_LIBRARY_PATH", host(&work.join("out"))),
        ("DYLD_FRAMEWORK_PATH", host(&work.join("out"))),
        ("DYLD_FORCE_FLAT_NAMESPACE", "1".into()),
        ("MACNCHEESE_METAL_SHADER_CACHE", host(&work.join("shader-cache"))),
    ];
    let mut command = String::from("export ");
    command.push_str(
        &exports
            .iter()
            .map(|(k, v)| format!("{k}={}", shell_quote(v)))
            .collect::<Vec<_>>()
            .join(" "),
    );
    command.push_str("; exec ");
    command.push_str(
        &arguments.iter().map(|p| shell_quote(&host(p))).collect::<Vec<_>>().join(" "),
    );
    let mut env: std::collections::HashMap<String, String> = std::env::vars().collect();
    env.insert("DPREFIX".into(), prefix.to_string_lossy().into_owned());
    env.remove("DYLD_INSERT_LIBRARIES");
    if let Ok(noroot) = std::env::var("MACNCHEESE_NOROOT_LIB") {
        if !noroot.is_empty() {
            env.insert("LD_PRELOAD".into(), noroot);
        }
    }
    let log_path = work.join("probe.log");
    let log = std::fs::File::create(&log_path)?;
    let mut child = std::process::Command::new("darling")
        .args(["shell", "/bin/bash", "-c", &command])
        .envs(&env)
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()?;
    let result = match child.wait_timeout(std::time::Duration::from_secs(25)) {
        Ok(code) => code.code().unwrap_or(1),
        Err(_) => {
            let _ = child.kill();
            println!("Native Vulkan probe timed out");
            1
        }
    };
    let tail = std::fs::read_to_string(&log_path).unwrap_or_default();
    let start = tail.len().saturating_sub(8000);
    println!("{}", &tail[start..]);
    let _ = std::process::Command::new("darling")
        .arg("shutdown")
        .envs(&env)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    println!("Probe exit: {result}; log: {}", log_path.display());
    std::process::exit(result);
}

fn shell_quote(value: &str) -> String {
    if value.chars().all(|c| c.is_alphanumeric() || "/._-=:".contains(c)) {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn copy_disposable(base: &PathBuf, prefix: &PathBuf) -> Result<()> {
    // Skip Darling runtime state; copy the rest with symlinks intact.
    let mut stack = vec![base.clone()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name == ".init.pid" || name.starts_with(".darlingserver") {
                continue;
            }
            let src = entry.path();
            let rel = src.strip_prefix(base).unwrap_or(&src);
            let dst = prefix.join(rel);
            let meta = std::fs::symlink_metadata(&src)?;
            if meta.file_type().is_symlink() {
                if let Some(parent) = dst.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let _ = std::os::unix::fs::symlink(std::fs::read_link(&src)?, &dst);
            } else if meta.is_dir() {
                let ft = meta.file_type();
                if ft.is_socket() {
                    continue;
                }
                std::fs::create_dir_all(&dst)?;
                stack.push(src);
            } else if meta.file_type().is_socket() {
                continue;
            } else {
                if let Some(parent) = dst.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::copy(&src, &dst)?;
            }
        }
    }
    Ok(())
}

trait WaitTimeout {
    fn wait_timeout(&mut self, dur: std::time::Duration) -> Result<std::process::ExitStatus, ()>;
}

impl WaitTimeout for std::process::Child {
    fn wait_timeout(&mut self, dur: std::time::Duration) -> Result<std::process::ExitStatus, ()> {
        let start = std::time::Instant::now();
        loop {
            if let Ok(Some(status)) = self.try_wait() {
                return Ok(status);
            }
            if start.elapsed() >= dur {
                return Err(());
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }
}
