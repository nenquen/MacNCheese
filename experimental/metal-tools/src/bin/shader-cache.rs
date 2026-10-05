//! Build validated shader-cache packets. Port of shader_cache.py.
use anyhow::{bail, Result};
use metal_tools::shader;
use std::collections::HashMap;
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

fn main() -> Result<()> {
    let mut positional: Vec<String> = vec![];
    let mut index: Vec<usize> = vec![];
    let mut out: Option<PathBuf> = None;
    let mut translator = "metal2vulkan".to_string();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--out" => out = args.next().map(PathBuf::from),
            "--translator" => {
                if let Some(v) = args.next() {
                    translator = v;
                }
            }
            "--index" => {
                if let Some(v) = args.next() {
                    index.push(v.parse().unwrap_or(usize::MAX));
                }
            }
            _ if a.starts_with("--index=") => {
                index.push(a["--index=".len()..].parse().unwrap_or(usize::MAX));
            }
            _ if !a.starts_with('-') => positional.push(a),
            _ => {}
        }
    }
    let _ = arg("--unused");
    let pack_path = positional.first().map(PathBuf::from).unwrap_or_default();
    if pack_path.as_os_str().is_empty() {
        eprintln!("Usage: shader-cache PACK [--out DIR] [--translator BIN] [--index N]");
        std::process::exit(2);
    }
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let out = out.unwrap_or_else(|| repo.join("work/metal-backend-repro/shader-cache"));
    let pack = std::fs::read(&pack_path)?;
    let entries = shader::libraries(&pack)?;
    if index.is_empty() {
        let mut counts: HashMap<u8, usize> = HashMap::new();
        for (_, _, funcs) in &entries {
            for f in funcs {
                *counts.entry(f.stage).or_default() += 1;
            }
        }
        println!("Libraries: {} function stages: {counts:?}", entries.len());
        for (i, (offset, library, funcs)) in entries.iter().enumerate() {
            if i < 12 || (funcs.first().is_some_and(|f| f.stage == 0) && i < 100) {
                let names: Vec<(&str, u8)> =
                    funcs.iter().map(|f| (f.name.as_str(), f.stage)).collect();
                println!("{i} {offset} {} {names:?}", library.len());
            }
        }
        return Ok(());
    }
    for i in index {
        let library = match entries.get(i) {
            Some((_, library, _)) => library.clone(),
            None => bail!("no such library index: {i}"),
        };
        let report = shader::convert(&library, &out, &translator)?;
        println!("{report}");
    }
    Ok(())
}
