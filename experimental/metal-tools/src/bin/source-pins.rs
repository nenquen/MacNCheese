//! Verify pinned source trees. Port of source_pins.py.
use anyhow::{bail, Result};
use metal_tools::pins;
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
    let darling = arg("--darling").map(PathBuf::from).unwrap_or_default();
    let vulkan = arg("--vulkan").map(PathBuf::from).unwrap_or_default();
    let translator = arg("--translator").map(PathBuf::from);
    if darling.as_os_str().is_empty() || vulkan.as_os_str().is_empty() {
        eprintln!("Usage: source-pins --darling DIR --vulkan DIR [--translator DIR]");
        std::process::exit(2);
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../metal/source_pins.json");
    let pins: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&manifest)?)?;
    let roots = [
        ("metal", darling.join("src/external/metal")),
        ("libcxx", darling.join("src/external/libcxx/include")),
        ("vulkan", vulkan),
    ];
    for (component, root) in roots {
        let selections = pins[component].get("selections");
        let actual = pins::tree_digest(&root, selections)?;
        let expected = pins[component]["sha256"].as_str().unwrap_or("");
        if actual != expected {
            bail!("{component} source differs from tested content: {actual}");
        }
        println!("{component}: source pin verified");
    }
    if let Some(t) = translator {
        let selections = pins["translator"].get("selections");
        let actual = pins::tree_digest(&t, selections)?;
        if actual != pins["translator"]["sha256"].as_str().unwrap_or("") {
            bail!("translator source differs from tested content: {actual}");
        }
        println!("translator: source pin verified");
    }
    Ok(())
}
