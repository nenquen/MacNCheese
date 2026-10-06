//! Fast flags: ClientAppSettings.json read/write + RakNet enforcement.
//! Port of load_fast_flags/save_fast_flags/ensure_raknet_transport (flags part).

use serde_json::{Map, Value};
use std::path::PathBuf;

use crate::paths;

pub fn flags_file() -> PathBuf {
    if let Ok(v) = std::env::var("MACNCHEESE_FLAGS_FILE") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    paths::data_dir()
        .join("ClientSettings")
        .join("ClientAppSettings.json")
}

pub fn load() -> Map<String, Value> {
    std::fs::read_to_string(flags_file())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

pub fn save(flags: &Map<String, Value>) -> Result<(), String> {
    let path = flags_file();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(flags).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

/// Force the RakNet transport flags (cheap JSON part, runs every launch).
/// Returns true when anything changed.
pub fn ensure_raknet() -> bool {    let needed: &[(&str, &str)] = &[
        ("FFlagUseRbxTransportClient", "False"),
        ("FFlagUseRbxTransportClient3", "False"),
        ("FFlagUseRbxTransportServer", "False"),
        ("FFlagShareRbxTransport", "False"),
        ("FFlagRbxTransportRuntime", "False"),
        ("DFFlagDebugDisableRbxTransportDummyClient", "True"),
        ("FFlagDebugDisableRbxTransportDummyClient", "True"),
        ("FStringRbxTransportDummyClientEnabledMinorVersions", ""),
        ("FStringRbxTransportDummyClientEnabledMinorVersions_PlaceFilter", "none"),
        ("DFIntRbxTransportDummyClientConnectionTimeoutMs", "0"),
        ("DFIntRbxTransportQuicHandshakeTimeoutMs", "0"),
        ("DFFlagEnablePopLatencyProbe3", "False"),
        ("DFFlagAttachPopUdpProbeToGameJoin2", "False"),
        ("DFFlagRakNetFallbackToRbxTransportEvent", "False"),
        ("DFFlagRakNetFallbackToRbxTransportStatus", "False"),
        ("DFFlagConnectDummyServiceClientEarly", "False"),
        ("DFIntRbxTransportClientConnectionWaitIntervalMs", "0"),
        ("DFFlagHttpLocalThrottle", "False"),
        ("FFlagHttpLocalThrottle", "False"),
        ("DFIntHttpMaxRetries", "0"),
        ("DFIntHttpMaxRetryAfterSec", "0"),
        ("DFIntHttpRbxApiMaxThrottledQueueSize", "0"),
        ("DFIntHttpRetryAndLocalThrottleJitterMaxPercent", "0"),
        ("DFFlagDebugSlimLoaderDisableHTTPRetry", "True"),
        ("FFlagDebugSlimLoaderDisableHTTPRetry", "True"),
        ("DFIntBatchThumbnailMaxWaitMs", "0"),
        ("DFIntBatchThumbnailMinWaitMs", "0"),
        ("DFIntBatchThumbnailExponentialInitialWaitMs", "0"),
        ("DFIntBatchThumbnailMaxExponentialRetries", "0"),
        ("DFIntBatchThumbnailAllowedExternalTimedOutRetries", "0"),
        ("DFIntLuaAppThumbnailsApiRetryTimeMultiplier", "0"),
    ];
    let mut flags = load();
    let mut changed = false;
    for (k, v) in needed {
        if flags.get(*k).and_then(|x| x.as_str()) != Some(v) {
            flags.insert(k.to_string(), Value::from(*v));
            changed = true;
        }
    }
    if changed {
        let _ = save(&flags);
    }
    changed
}

/// Roblox caps its own frame rate (DFIntTaskSchedulerTargetFps, 60) even
/// with vsync off, so "no limit" must set the flag, not just skip it.
/// cap 0 (Unlimited) targets far past any display; anything else is exact.
/// Returns true when anything changed.
pub fn ensure_fps_cap(cap: u64) -> bool {
    let target = if cap == 0 { 10000 } else { cap };
    let mut flags = load();
    let want = Value::from(target.to_string());
    if flags.get("DFIntTaskSchedulerTargetFps") != Some(&want) {
        flags.insert("DFIntTaskSchedulerTargetFps".into(), want);
        let _ = save(&flags);
        return true;
    }
    false
}

/// The game reads ClientSettings from its own bundle directory (its
/// working directory at launch), not from our data dir: merge the flags
/// there every launch, or new flags never arrive. Additive only — the
/// client itself persists server-sent flags into its copy, which must
/// survive.
pub fn sync_to_client() -> bool {
    let mut ours = load();
    if ours.is_empty() {
        return false;
    }
    let dst = crate::paths::app_bundle()
        .join("Contents/MacOS/ClientSettings/ClientAppSettings.json");
    let mut theirs: Map<String, Value> = std::fs::read_to_string(&dst)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    let mut changed = false;
    for (k, v) in std::mem::take(&mut ours) {
        if theirs.get(&k) != Some(&v) {
            theirs.insert(k, v);
            changed = true;
        }
    }
    if !changed {
        return false;
    }
    if let Some(parent) = dst.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return false;
        }
    }
    let tmp = dst.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(&theirs).unwrap_or_default())
        .and_then(|_| std::fs::rename(&tmp, &dst))
        .is_ok()
}

/// Human-readable flag value for lists.
pub fn display_value(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => "?".into(),
    }
}

/// Parse editor input: true/false, numbers, else string.
pub fn parse_value(raw: &str) -> Value {
    let s = raw.trim();
    match s {
        "true" | "True" => return Value::Bool(true),
        "false" | "False" => return Value::Bool(false),
        _ => {}
    }
    if let Ok(n) = s.parse::<i64>() {
        return Value::from(n);
    }
    if let Ok(n) = s.parse::<f64>() {
        return Value::from(n);
    }
    Value::from(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    static FLAGS_FILE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn temp_flags_file(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        std::env::set_var("MACNCHEESE_FLAGS_FILE", dir.join("flags.json"));
        dir
    }
    #[test]
    fn raknet_enforced() {
        let _guard = FLAGS_FILE_LOCK.lock().unwrap();
        let dir = temp_flags_file("mcflags");
        ensure_raknet();
        let flags = load();
        assert_eq!(
            flags.get("FFlagUseRbxTransportClient").and_then(|v| v.as_str()),
            Some("False")
        );
        assert_eq!(
            flags.get("DFIntHttpMaxRetries").and_then(|v| v.as_str()),
            Some("0")
        );
        std::env::remove_var("MACNCHEESE_FLAGS_FILE");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fps_cap_flag() {
        let _guard = FLAGS_FILE_LOCK.lock().unwrap();
        let dir = temp_flags_file("mcfps");
        assert!(ensure_fps_cap(0));
        assert_eq!(
            load().get("DFIntTaskSchedulerTargetFps").and_then(|v| v.as_str()),
            Some("10000")
        );
        assert!(!ensure_fps_cap(0));
        assert!(ensure_fps_cap(144));
        assert_eq!(
            load().get("DFIntTaskSchedulerTargetFps").and_then(|v| v.as_str()),
            Some("144")
        );
        std::env::remove_var("MACNCHEESE_FLAGS_FILE");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn value_parsing() {        use super::{display_value, parse_value};
        assert_eq!(parse_value("True"), Value::Bool(true));
        assert_eq!(parse_value(" 120 "), Value::from(120));
        assert_eq!(parse_value("hello"), Value::from("hello"));
        assert_eq!(display_value(&Value::from("False")), "False");
    }
}
