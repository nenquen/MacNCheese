//! System display-scale detection. Port of display.detect_system_scale.
//! Sources: toolkit env overrides, KDE, GNOME, Xft.dpi. Never fails.

use std::collections::HashMap;
use std::path::PathBuf;

pub fn validated_dpi_scale(v: f64) -> f64 {
    if v.is_finite() && (1.0..=4.0).contains(&v) {
        v
    } else {
        1.0
    }
}

fn valid(v: f64) -> Option<f64> {
    if v.is_finite() && (1.0..=4.0).contains(&v) {
        Some((v * 100.0).round() / 100.0)
    } else {
        None
    }
}

fn higher(best: &mut Option<f64>, v: f64) {
    if valid(v).is_some_and(|f| best.is_none_or(|b| f > b)) {
        *best = valid(v);
    }
}

fn parse_num(s: &str) -> Option<f64> {
    s.trim().parse().ok()
}

pub struct Ctx {
    pub env: HashMap<String, String>,
    pub files: HashMap<PathBuf, String>,
    pub commands: HashMap<String, String>,
    /// False in tests: unmocked reads return empty instead of touching live system.
    pub live: bool,
}

impl Ctx {
    pub fn live() -> Ctx {
        Ctx { env: std::env::vars().collect(), files: HashMap::new(), commands: HashMap::new(), live: true }
    }

    fn run(&self, argv: &[&str]) -> String {
        let key = argv.join(" ");
        if let Some(out) = self.commands.get(&key) {
            return out.clone();
        }
        if !self.live {
            return String::new();
        }
        std::process::Command::new(argv[0])
            .args(&argv[1..])
            .output()
            .map(|o| {
                if o.status.success() {
                    String::from_utf8_lossy(&o.stdout).into_owned()
                } else {
                    String::new()
                }
            })
            .unwrap_or_default()
    }

    fn read(&self, path: &PathBuf) -> Option<String> {
        if let Some(text) = self.files.get(path) {
            return Some(text.clone());
        }
        if !self.live {
            return None;
        }
        std::fs::read_to_string(path).ok()
    }
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

fn env_override(ctx: &Ctx) -> Option<f64> {
    let mut best: Option<f64> = None;
    for key in ["GDK_SCALE", "QT_SCALE_FACTOR"] {
        if let Some(v) = ctx.env.get(key).and_then(|s| parse_num(s.split([';', ',']).next().unwrap_or(""))) {
            higher(&mut best, v);
        }
    }
    if let Some(list) = ctx.env.get("QT_SCREEN_SCALE_FACTORS") {
        for part in list.replace(',', ";").split(';') {
            let v = part.split('=').next_back().unwrap_or("");
            if let Some(f) = parse_num(v).and_then(valid) {
                higher(&mut best, f);
            }
        }
    }
    best
}

fn kde(ctx: &Ctx) -> Option<f64> {
    let out = ctx.run(&["kscreen-doctor", "-o"]);
    let mut best: Option<f64> = None;
    for line in out.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Scale:") {
            if let Some(f) = parse_num(rest).and_then(valid) {
                higher(&mut best, f);
            }
        }
    }
    if best.is_some() {
        return best;
    }
    let text = ctx.read(&home().join(".config/kwinoutputconfig.json"))?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    let outputs = json.get("outputs")?.as_array()?;
    let mut found: Option<f64> = None;
    for o in outputs {
        if let Some(f) = o.get("scale").and_then(|v| v.as_f64()).and_then(valid) {
            higher(&mut found, f);
        }
    }
    found
}

fn gnome(ctx: &Ctx) -> Option<f64> {
    if let Some(xml) = ctx.read(&home().join(".config/monitors.xml")) {
        let mut best: Option<f64> = None;
        let mut search = xml.as_str();
        while let Some(i) = search.find("<scale>") {
            search = &search[i + 7..];
            if let Some(end) = search.find("</scale>") {
                if let Some(f) = parse_num(&search[..end]).and_then(valid) {
                    higher(&mut best, f);
                }
            }
        }
        if best.is_some() {
            return best;
        }
    }
    let out = ctx.run(&["gsettings", "get", "org.gnome.desktop.interface", "scaling-factor"]);
    out.split_whitespace()
        .next_back()
        .and_then(parse_num)
        .and_then(valid)
}

fn xft(ctx: &Ctx) -> Option<f64> {
    let out = ctx.run(&["xrdb", "-query"]);
    for line in out.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Xft.dpi:") {
            if let Some(dpi) = parse_num(rest) {
                let scale = valid(dpi / 96.0)?;
                if scale > 1.0 {
                    return Some(scale);
                }
            }
        }
    }
    None
}

/// Best-effort desktop scale for pre-filling Roblox UI scale. Never fails.
pub fn detect(ctx: &Ctx) -> f64 {
    if let Some(v) = env_override(ctx) {
        return v;
    }
    let desktop = ctx.env.get("XDG_CURRENT_DESKTOP").map(|s| s.to_lowercase()).unwrap_or_default();
    if desktop.contains("kde") {
        if let Some(v) = kde(ctx) {
            return v;
        }
    } else if desktop.contains("gnome") {
        if let Some(v) = gnome(ctx) {
            return v;
        }
    } else {
        for probe in [kde, gnome] {
            if let Some(v) = probe(ctx) {
                return v;
            }
        }
    }
    xft(ctx).unwrap_or(1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx(env: &[(&str, &str)], commands: &[(&str, &str)], files: &[(&str, &str)]) -> Ctx {
        Ctx {
            env: env.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            files: files.iter().map(|(k, v)| (PathBuf::from(k), v.to_string())).collect(),
            commands: commands.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            live: false,
        }
    }

    #[test]
    fn unknown_is_default() {
        assert_eq!(detect(&ctx(&[], &[], &[])), 1.0);
    }

    #[test]
    fn env_wins() {
        let c = ctx(&[("GDK_SCALE", "2")], &[], &[]);
        assert_eq!(detect(&c), 2.0);
    }

    #[test]
    fn kde_kscreen() {
        let c = ctx(
            &[("XDG_CURRENT_DESKTOP", "KDE")],
            &[("kscreen-doctor -o", "Output: 1\n Scale: 1.25\n")],
            &[],
        );
        assert_eq!(detect(&c), 1.25);
    }

    #[test]
    fn gnome_xml() {
        let home = dirs::home_dir().unwrap();
        let path = home.join(".config/monitors.xml");
        let c = ctx(
            &[("XDG_CURRENT_DESKTOP", "GNOME")],
            &[("gsettings get org.gnome.desktop.interface scaling-factor", "uint32 1")],
            &[(
                path.to_str().unwrap(),
                "<monitors><configuration><logicalmonitor><scale>1.5</scale></logicalmonitor></configuration></monitors>",
            )],
        );
        assert_eq!(detect(&c), 1.5);
    }

    #[test]
    fn xft_fallback() {
        let c = ctx(&[], &[("xrdb -query", "Xft.dpi:\t120\n")], &[]);
        assert_eq!(detect(&c), 1.25);
    }
}
