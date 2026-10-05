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
pub fn ensure_raknet() -> bool {
    let needed: &[(&str, &str)] = &[
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raknet_enforced() {
        let dir = std::env::temp_dir().join(format!("mcflags-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        std::env::set_var("MACNCHEESE_FLAGS_FILE", dir.join("flags.json"));
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
}
