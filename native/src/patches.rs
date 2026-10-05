//! Verified binary patches for known client builds. Ports of
//! transport_patches.py, shader_patches.py and patch_startup_throttle.py.
//!
//! Same rule as the Python originals: only complete known files are
//! touched; unknown builds are left unchanged, never half-patched.

use sha2::{Digest, Sha256};
use std::path::Path;

fn sha256(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap_or(0))
        .collect()
}

// ---------------------------------------------------------------- transport

struct Site {
    offset: usize,
    original: Vec<u8>,
    patched: Vec<u8>,
}

const TRANSPORT_SIZE: usize = 123_526_704;
const TRANSPORT_SHA: &str = "be95441279431786043ca06a918b1c3ef172f54848b716df8ecf2e440921ebff";

fn transport_sites() -> Vec<Site> {
    vec![
        Site { offset: 0x4A38D78, original: unhex("554889e5"), patched: unhex("31c0c390") },
        Site { offset: 0x536EC65, original: vec![0x01], patched: vec![0xff] },
        Site { offset: 0x5370858, original: vec![0x75], patched: vec![0xeb] },
        Site { offset: 0x5370A1E, original: vec![0x75], patched: vec![0xeb] },
        Site { offset: 0x1153F70, original: vec![0x89, 0xf3], patched: vec![0x31, 0xdb] },
    ]
}

/// "patched" | "already patched" | "unsupported …". Writes atomically.
pub fn apply_transport(binary: &Path) -> String {
    let data = match std::fs::read(binary) {
        Ok(d) => d,
        Err(e) => return format!("unreadable client: {e}"),
    };
    if data.len() != TRANSPORT_SIZE {
        return "unsupported client; transport binary left unchanged".into();
    }
    let sites = transport_sites();
    let patches = &sites[..4];
    let compat = &sites[4..];
    for site in sites.iter() {
        let end = site.offset + site.original.len();
        if end > data.len()
            || site.original.len() != site.patched.len()
            || (&data[site.offset..end] != site.original.as_slice()
                && &data[site.offset..end] != site.patched.as_slice())
        {
            return "unsupported client; transport binary left unchanged".into();
        }
    }
    let mut normalized = data.clone();
    for site in sites.iter() {
        let end = site.offset + site.original.len();
        normalized[site.offset..end].copy_from_slice(&site.original);
    }
    if sha256(&normalized) != TRANSPORT_SHA {
        return "unsupported client; transport binary left unchanged".into();
    }
    let mut replacement = data.clone();
    for site in patches {
        let end = site.offset + site.patched.len();
        replacement[site.offset..end].copy_from_slice(&site.patched);
    }
    // Include the compatible throttle change (same bytes the patcher uses).
    for site in compat {
        let end = site.offset + site.patched.len();
        replacement[site.offset..end].copy_from_slice(&site.patched);
    }
    if replacement == data {
        return "already patched".into();
    }
    match atomic_replace(binary, &data, &replacement) {
        Ok(()) => "patched".into(),
        Err(e) => format!("patch failed: {e}"),
    }
}

fn atomic_replace(path: &Path, expected: &[u8], replacement: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    let tmp = parent.join(format!(".patch-{}-", std::process::id()));
    std::fs::write(&tmp, replacement)?;
    #[cfg(unix)]
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(&tmp, meta.permissions());
    }
    if std::fs::read(path).map(|d| d != expected).unwrap_or(true) {
        let _ = std::fs::remove_file(&tmp);
        return Err(std::io::Error::other("changed during patch"));
    }
    std::fs::rename(&tmp, path)
}

// ------------------------------------------------------------------- shader

const SHADER_SIZE: usize = 4_368_535;
const SHADER_SHA: &str = "736943d1dd2881451292eab34c892dec0cd146b5e4cb0b6770abc2f282afc5c6";

struct ShaderSource {
    offset: usize,
    size: usize,
    sha: &'static str,
    descriptors: Vec<usize>,
    sites: Vec<usize>,
}

fn shader_sources() -> Vec<ShaderSource> {
    vec![
        ShaderSource {
            offset: 0x37D917,
            size: 21402,
            sha: "9f113af818c8b2df6a584edc16f323326878cf9d20ef5e034790c9a69d2573df",
            descriptors: vec![2538, 2539, 2540],
            sites: vec![0x52C, 0x54B],
        },
        ShaderSource {
            offset: 0x382CB1,
            size: 21572,
            sha: "9d13523b7b5076b2949bad827db313204a074e27720e978332227721e261b4bd",
            descriptors: vec![2541],
            sites: vec![0x52C, 0x54B],
        },
    ]
}

fn u32le(data: &[u8], at: usize) -> Option<u32> {
    data.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

fn validate_layout(data: &[u8], sources: &[ShaderSource]) -> bool {
    if data.len() < 20 || &data[..4] != b"RBXS" {
        return false;
    }
    let version = u16::from_le_bytes([data[4], data[5]]);
    let variants = u16::from_le_bytes([data[6], data[7]]) as usize;
    let defines = u16::from_le_bytes([data[8], data[9]]) as usize;
    let options = u16::from_le_bytes([data[10], data[11]]) as usize;
    let names = u16::from_le_bytes([data[12], data[13]]) as usize;
    let shaders = u16::from_le_bytes([data[14], data[15]]) as usize;
    if version != 11 || variants == 0 || names == 0 || shaders == 0 {
        return false;
    }
    let names_start = 20 + variants * 64;
    let table_start = names_start + names * 68 + defines * 64 + options * 65;
    let source_start = table_start + shaders * 64;
    if source_start >= data.len() {
        return false;
    }
    use std::collections::BTreeMap;
    let mut ranges: BTreeMap<(usize, usize), Vec<(usize, Vec<u8>)>> = BTreeMap::new();
    for index in 0..shaders {
        let entry = table_start + index * 64;
        let (offset, size) = match (u32le(data, entry + 16), u32le(data, entry + 20)) {
            (Some(o), Some(s)) => (o as usize, s as usize),
            _ => return false,
        };
        let kind = data.get(entry + 28).copied().unwrap_or(0);
        let variant = data.get(entry + 29).copied().unwrap_or(255) as usize;
        let name_index = u16::from_le_bytes([*data.get(entry + 30).unwrap_or(&0), *data.get(entry + 31).unwrap_or(&0)]) as usize;
        if !b"vpc".contains(&kind)
            || variant >= variants
            || name_index >= names
            || size == 0
            || offset < source_start
            || offset + size > data.len()
        {
            return false;
        }
        let name_start = names_start + name_index * 68;
        let end = data[name_start..].iter().position(|&b| b == 0).unwrap_or(64).min(64);
        let name = data[name_start..name_start + end.min(data.len().saturating_sub(name_start))].to_vec();
        ranges.entry((offset, size)).or_default().push((index, name));
    }
    let mut position = source_start;
    for key in ranges.keys() {
        if key.0 != position {
            return false;
        }
        position += key.1;
    }
    if position != data.len() {
        return false;
    }
    for source in sources {
        let refs = match ranges.get(&(source.offset, source.size)) {
            Some(r) => r,
            None => return false,
        };
        let ids: Vec<usize> = refs.iter().map(|(i, _)| *i).collect();
        if ids != source.descriptors
            || refs.iter().any(|(_, n)| n != b"HeightmapDebugPS")
        {
            return false;
        }
        let blob = &data[source.offset..source.offset + source.size];
        if sha256(blob) != source.sha {
            return false;
        }
        for (site, decl) in source.sites.iter().zip(
            [b"uniform vec4 MaterialLUT[256];".as_slice(), b"uniform vec4 ColorLUT[256];".as_slice()],
        ) {
            if *site < 7 || blob.get(site - 7..site - 7 + decl.len()) != Some(decl) {
                return false;
            }
        }
        if source.sites.len() != 2 {
            return false;
        }
    }
    true
}

pub fn apply_shader(pack: &Path) -> String {
    let data = match std::fs::read(pack) {
        Ok(d) => d,
        Err(_) => return "unsupported shader pack; shader sources left unchanged".into(),
    };
    if data.len() != SHADER_SIZE {
        return "unsupported shader pack; shader sources left unchanged".into();
    }
    let sources = shader_sources();
    let mut positions = vec![];
    for source in &sources {
        for site in &source.sites {
            positions.push(source.offset + site);
        }
    }
    {
        let mut uniq = positions.clone();
        uniq.sort();
        uniq.dedup();
        if uniq.len() != positions.len() {
            return "unsupported shader pack; shader sources left unchanged".into();
        }
    }
    for &p in &positions {
        if p >= data.len() || (data[p] != b' ' && data[p] != b'\t') {
            return "unsupported shader pack; shader sources left unchanged".into();
        }
    }
    let mut normalized = data.clone();
    for &p in &positions {
        normalized[p] = b' ';
    }
    if sha256(&normalized) != SHADER_SHA || !validate_layout(&normalized, &sources) {
        return "unsupported shader pack; shader sources left unchanged".into();
    }
    let mut replacement = data.clone();
    for &p in &positions {
        replacement[p] = b'\t';
    }
    if replacement == data {
        return "already patched".into();
    }
    match atomic_replace(pack, &data, &replacement) {
        Ok(()) => "patched".into(),
        Err(e) => format!("patch failed: {e}"),
    }
}

// ----------------------------------------------------------------- throttle

const ARG_MOVES: &[u8] = &[0x89, 0xf3, 0x49, 0x89, 0xfe];
const PATCHED_MOVES: &[u8] = &[0x31, 0xdb, 0x49, 0x89, 0xfe];
const PROLOGUE: &[u8] = &[0x55, 0x48, 0x89, 0xe5];
const VALUE_LOG: &[u8] = &[0x41, 0xb8, 0x4e, 0, 0, 0, 0xba, 3, 0, 0, 0, 0x41, 0xb9, 1, 0, 0, 0];
const NULL_LOG: &[u8] = &[0x41, 0xb8, 0x55, 0, 0, 0, 0xba, 2, 0, 0, 0, 0x41, 0xb9, 1, 0, 0, 0];

fn find_all(data: &[u8], needle: &[u8]) -> Vec<usize> {
    if needle.is_empty() || data.len() < needle.len() {
        return vec![];
    }
    let mut out = vec![];
    let mut i = 0;
    while i + needle.len() <= data.len() {
        if &data[i..i + needle.len()] == needle {
            out.push(i);
            i += needle.len();
        } else {
            i += 1;
        }
    }
    out
}

fn contains(data: &[u8], needle: &[u8]) -> bool {
    !find_all(data, needle).is_empty()
}

fn find_throttle_site(data: &[u8], moves: &[u8]) -> Option<usize> {
    for null_at in find_all(data, NULL_LOG) {
        let window_start = null_at.saturating_sub(0x600);
        let window = &data[window_start..null_at];
        let mut found = vec![];
        for m in find_all(window, moves) {
            let back = m.saturating_sub(0x20);
            if contains(&window[back..m], PROLOGUE) {
                found.push(m);
            }
        }
        for mv in found.into_iter().rev() {
            let body_end = (null_at + 64).min(data.len());
            let body = &data[window_start + mv..body_end];
            if contains(body, VALUE_LOG) && contains(body, NULL_LOG) {
                return Some(window_start + mv);
            }
        }
    }
    None
}

/// "patched" | "already patched" | "original" | "unsupported …".
pub fn apply_throttle(binary: &Path) -> String {
    let data = match std::fs::read(binary) {
        Ok(d) => d,
        Err(e) => return format!("unreadable client: {e}"),
    };
    if find_throttle_site(&data, PATCHED_MOVES).is_none()
        && find_throttle_site(&data, ARG_MOVES).is_none()
    {
        return "unsupported client; throttle patch skipped".into();
    }
    if find_throttle_site(&data, ARG_MOVES).is_none() {
        return "already patched".into();
    }
    let offset = match find_throttle_site(&data, ARG_MOVES) {
        Some(o) => o,
        None => return "already patched".into(),
    };
    let mut replacement = data.clone();
    replacement[offset] = 0x31;
    replacement[offset + 1] = 0xdb;
    match atomic_replace(binary, &data, &replacement) {
        Ok(()) => "patched".into(),
        Err(e) => format!("patch failed: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_files_unsupported() {
        let dir = std::env::temp_dir();
        let f = dir.join("mc-patch-probe.bin");
        std::fs::write(&f, b"tiny").unwrap();
        assert!(apply_transport(&f).starts_with("unsupported"));
        assert!(apply_shader(&f).starts_with("unsupported"));
        assert!(apply_throttle(&f).starts_with("unsupported"));
        let _ = std::fs::remove_file(&f);
    }

    #[test]
    fn throttle_roundtrip() {
        // Synthetic setStartupThrottle shape: prologue, moves, both logs.
        let mut data = vec![0u8; 0x700];
        data[0x100..0x104].copy_from_slice(PROLOGUE);
        data[0x110..0x115].copy_from_slice(ARG_MOVES);
        data[0x200..0x200 + VALUE_LOG.len()].copy_from_slice(VALUE_LOG);
        data[0x300..0x300 + NULL_LOG.len()].copy_from_slice(NULL_LOG);
        assert_eq!(find_throttle_site(&data, ARG_MOVES), Some(0x110));
        assert_eq!(find_throttle_site(&data, PATCHED_MOVES), None);
        data[0x110] = 0x31;
        data[0x111] = 0xdb;
        assert_eq!(find_throttle_site(&data, PATCHED_MOVES), Some(0x110));
    }
}
