//! Window icon in _NET_WM_ICON layout for the shim (MACNCHEESE_ICON_ARGB).

use std::path::PathBuf;

use crate::paths;

fn sources() -> Vec<PathBuf> {
    let icons = paths::project().join("branding/icons");
    [32, 64, 128]
        .into_iter()
        .map(|s| icons.join(format!("macncheese-{s}.png")))
        .collect()
}

/// (Re)build CACHE_DIR/icon.argb when a source is newer. Returns the path.
pub fn icon_argb_file() -> Option<PathBuf> {
    let target = paths::cache_dir().join("icon.argb");
    let fresh = target.exists()
        && sources().into_iter().all(|s| {
            match (std::fs::metadata(&target), std::fs::metadata(&s)) {
                (Ok(t), Ok(o)) => t.modified().ok() >= o.modified().ok(),
                _ => false,
            }
        });
    if fresh {
        return Some(target);
    }
    let mut words: Vec<u8> = Vec::new();
    for source in sources() {
        let data = std::fs::read(&source).ok()?;
        let decoder = png::Decoder::new(&data[..]);
        let mut reader = decoder.read_info().ok()?;
        let mut buf = vec![0u8; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).ok()?;
        let (w, h) = (info.width, info.height);
        if w == 0 || h == 0 || w > 512 || h > 512 {
            continue;
        }
        let pixels: Vec<u8> = match info.color_type {
            png::ColorType::Rgba => buf[..(w * h * 4) as usize].to_vec(),
            png::ColorType::Rgb => {
                let rgb = &buf[..(w * h * 3) as usize];
                let mut out = Vec::with_capacity((w * h * 4) as usize);
                for px in rgb.chunks_exact(3) {
                    out.extend_from_slice(&[px[0], px[1], px[2], 255]);
                }
                out
            }
            _ => continue,
        };
        words.extend_from_slice(&w.to_le_bytes());
        words.extend_from_slice(&h.to_le_bytes());
        for px in pixels.chunks_exact(4) {
            let argb = ((px[3] as u32) << 24) | ((px[0] as u32) << 16) | ((px[1] as u32) << 8) | px[2] as u32;
            words.extend_from_slice(&argb.to_le_bytes());
        }
    }
    if words.is_empty() {
        return None;
    }
    let _ = std::fs::create_dir_all(paths::cache_dir());
    std::fs::write(&target, &words).ok()?;
    Some(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_matches_net_wm_icon() {
        let Some(path) = icon_argb_file() else { return };
        let data = std::fs::read(path).unwrap();
        let mut pos = 0;
        let mut seen = vec![];
        while pos + 8 <= data.len() {
            let w = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
            let h = u32::from_le_bytes(data[pos + 4..pos + 8].try_into().unwrap());
            assert!([32, 64, 128].contains(&w) && w == h, "bad icon {w}x{h}");
            seen.push(w);
            pos += 8 + (w * h * 4) as usize;
        }
        assert_eq!(pos, data.len(), "trailing bytes");
        assert!(!seen.is_empty(), "no icons written");
    }
}
