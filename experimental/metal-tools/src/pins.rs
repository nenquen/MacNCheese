//! SHA-256 source-tree pins. Port of source_pins.py tree_digest.

use anyhow::{bail, Result};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

fn collect(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        let meta = std::fs::symlink_metadata(&path)?;
        if meta.is_dir() && !meta.file_type().is_symlink() {
            collect(&path, out)?;
        } else if meta.is_file() || meta.file_type().is_symlink() {
            out.push(path);
        }
    }
    Ok(())
}

/// SHA-256 of relative path + NUL + kind + file SHA-256 + newline, sorted.
pub fn tree_digest(root: &Path, selections: Option<&serde_json::Value>) -> Result<String> {
    let mut files = vec![];
    match selections {
        Some(serde_json::Value::Array(items)) if !items.is_empty() => {
            for item in items {
                let entry = root.join(item.as_str().unwrap_or(""));
                let meta = std::fs::symlink_metadata(&entry)
                    .map_err(|_| anyhow::anyhow!("Missing source: {}", entry.display()))?;
                if meta.is_dir() && !meta.file_type().is_symlink() {
                    collect(&entry, &mut files)?;
                } else if meta.is_file() || meta.file_type().is_symlink() {
                    files.push(entry);
                } else {
                    bail!("Missing source: {}", entry.display());
                }
            }
        }
        _ => {
            if !root.is_dir() {
                bail!("Missing source: {}", root.display());
            }
            collect(root, &mut files)?;
        }
    }
    files.sort_by_key(|p| {
        p.strip_prefix(root)
            .map(|r| r.as_posix())
            .unwrap_or_default()
    });
    let mut digest = Sha256::new();
    let mut seen = std::collections::HashSet::new();
    for path in files {
        if !seen.insert(path.clone()) {
            continue;
        }
        let rel = path
            .strip_prefix(root)
            .map(|r| r.as_posix())
            .unwrap_or_default();
        let meta = std::fs::symlink_metadata(&path)?;
        let (kind, content) = if meta.file_type().is_symlink() {
            (b'L', std::fs::read_link(&path).unwrap_or_default().as_posix().into_bytes())
        } else {
            (b'F', std::fs::read(&path)?)
        };
        digest.update(rel.as_bytes());
        digest.update([0u8]);
        digest.update([kind]);
        digest.update(sha2_hex(&content).as_bytes());
        digest.update(b"\n");
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn sha2_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

trait AsPosix {
    fn as_posix(&self) -> String;
}

impl AsPosix for std::path::Path {
    fn as_posix(&self) -> String {
        self.to_string_lossy().replace('\\', "/")
    }
}
