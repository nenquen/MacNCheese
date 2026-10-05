//! Validated shader-cache packets for the experimental Indium adapter.
//! Port of experimental/metal/shader_cache.py (pure logic; CLI in bins).
//!
//! Reads locally installed shader libraries; never changes the client.

use anyhow::{bail, Context, Result};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

fn u32le(data: &[u8], at: usize) -> Result<u32> {
    data.get(at..at + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .context("truncated u32")
}

fn u64le(data: &[u8], at: usize) -> Result<u64> {
    data.get(at..at + 8)
        .map(|b| u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
        .context("truncated u64")
}

fn sha256_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

pub struct Function {
    pub name: String,
    pub stage: u8,
    pub bitcode: Vec<u8>,
}

/// Parse one metallib image into (name, stage, bitcode) functions.
pub fn functions(library: &[u8]) -> Result<Vec<Function>> {
    if library.len() < 88 || &library[..4] != b"MTLB" {
        bail!("invalid metallib header");
    }
    let mut header = [0u64; 9];
    for (i, slot) in header.iter_mut().enumerate() {
        *slot = u64le(library, 16 + i * 8)?;
    }
    let [size, offset, length, _, _, _, _, bc_offset, bc_length] = header;
    let (size, offset, length) = (size as usize, offset as usize, length as usize);
    let (bc_offset, bc_length) = (bc_offset as usize, bc_length as usize);
    let table_end = offset + 4 + length;
    if size != library.len() || table_end > size || bc_offset + bc_length > size {
        bail!("metallib range outside file");
    }
    let count = u32le(library, offset)? as usize;
    if count > 1024 {
        bail!("too many metallib functions");
    }
    let mut pos = offset + 4;
    let mut result = vec![];
    for _ in 0..count {
        if pos + 4 > table_end {
            bail!("metallib function outside table");
        }
        let group_size = u32le(library, pos)? as usize;
        let end = pos + group_size;
        if group_size < 8 || end > table_end {
            bail!("metallib group outside table");
        }
        pos += 4;
        let mut tags: HashMap<&[u8], &[u8]> = HashMap::new();
        while pos + 4 <= end {
            let tag = &library[pos..pos + 4];
            pos += 4;
            if tag == b"ENDT" {
                break;
            }
            if pos + 2 > end {
                bail!("truncated metallib tag");
            }
            let tag_length = u16::from_le_bytes([library[pos], library[pos + 1]]) as usize;
            pos += 2;
            if pos + tag_length > end {
                bail!("metallib tag outside group");
            }
            tags.insert(tag, &library[pos..pos + tag_length]);
            pos += tag_length;
        }
        pos = end;
        let get = |t: &[u8]| tags.get(t).copied();
        let (Some(name_raw), Some(type_raw), Some(mdsz), Some(offt)) =
            (get(b"NAME"), get(b"TYPE"), get(b"MDSZ"), get(b"OFFT"))
        else {
            bail!("missing metallib function metadata");
        };
        let end = name_raw.iter().rposition(|&b| b != 0).map(|i| i + 1).unwrap_or(0);
        let name = std::str::from_utf8(&name_raw[..end])
            .map_err(|_| anyhow::anyhow!("invalid metallib function stage/name"))?
            .to_string();
        if name.is_empty() || type_raw.len() != 1 || type_raw[0] > 2 {
            bail!("invalid metallib function stage/name");
        }
        if mdsz.len() != 8 || offt.len() != 24 {
            bail!("invalid metallib bitcode metadata");
        }
        let stage = type_raw[0];
        let bitcode_size = u64::from_le_bytes(mdsz.try_into().unwrap()) as usize;
        let o0 = u64::from_le_bytes(offt[0..8].try_into().unwrap()) as usize;
        let o1 = u64::from_le_bytes(offt[8..16].try_into().unwrap()) as usize;
        let o2 = u64::from_le_bytes(offt[16..24].try_into().unwrap()) as usize;
        let _ = (o0, o1);
        let bitcode_offset = o2 + bc_offset;
        if bitcode_offset + bitcode_size > size {
            bail!("function bitcode outside metallib");
        }
        result.push(Function {
            name,
            stage,
            bitcode: library[bitcode_offset..bitcode_offset + bitcode_size].to_vec(),
        });
    }
    Ok(result)
}

/// Split a blob into metallib images: (file offset, image, functions).
pub fn libraries(pack: &[u8]) -> Result<Vec<(usize, Vec<u8>, Vec<Function>)>> {
    let mut out = vec![];
    let mut pos = 0;
    loop {
        let start = match pack[pos..].windows(4).position(|w| w == b"MTLB") {
            Some(i) => pos + i,
            None => break,
        };
        if start + 88 > pack.len() {
            break;
        }
        let size = u64le(pack, start + 16)? as usize;
        if size < 88 || size > pack.len() - start {
            pos = start + 4;
            continue;
        }
        let library = pack[start..start + size].to_vec();
        let funcs = functions(&library)?;
        out.push((start, library, funcs));
        pos = start + size;
    }
    Ok(out)
}

fn words_of(data: &[u8]) -> Result<Vec<u32>> {
    if data.len() < 20 || data.len() % 4 != 0 {
        bail!("invalid SPIR-V size");
    }
    Ok(data.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
}

fn words_to(data: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() * 4);
    for w in data {
        out.extend_from_slice(&w.to_le_bytes());
    }
    out
}

fn user_location(semantic: &str) -> Option<u32> {
    let rest = semantic.strip_prefix("user(locn")?.strip_suffix(')')?;
    rest.parse().ok()
}

/// Rewrite entry name, descriptor sets and varying locations. Exactly one
/// entry point must exist; push constants are rejected.
pub fn adapt_spirv(data: &[u8], stage: u8, name: &str, reflection: &Value) -> Result<Vec<u8>> {
    if data.len() < 20 || data.len() % 4 != 0 || ![0, 1].contains(&stage) {
        bail!("invalid SPIR-V size or unsupported stage");
    }
    let words = words_of(data)?;
    if words[0] != 0x0723_0203 {
        bail!("invalid SPIR-V header");
    }
    let mut result = words[..5].to_vec();
    let set_index = if stage == 1 { 1 } else { 0 };
    let mut varying_locations: HashMap<u32, u32> = HashMap::new();
    for varying in reflection.get("varyings").and_then(|v| v.as_array()).into_iter().flatten() {
        let semantic = varying.get("user_semantic").and_then(|s| s.as_str()).unwrap_or("");
        let Some(loc) = user_location(semantic) else {
            bail!("named varyings need a shared vertex/fragment interface allocator");
        };
        let at = varying.get("location").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        varying_locations.insert(at, loc);
    }
    let mut variable_storage: HashMap<u32, u32> = HashMap::new();
    {
        let mut scan = 5;
        while scan < words.len() {
            let (count, opcode) = (words[scan] >> 16, words[scan] & 0xFFFF);
            if count == 0 || scan + count as usize > words.len() {
                bail!("malformed SPIR-V instruction");
            }
            if opcode == 59 && count >= 4 {
                variable_storage.insert(words[scan + 2], words[scan + 3]);
                if words[scan + 3] == 9 {
                    bail!("shader needs an unimplemented push-constant ABI");
                }
            }
            scan += count as usize;
        }
    }
    let mut name_bytes = format!("{name}\0").into_bytes();
    while name_bytes.len() % 4 != 0 {
        name_bytes.push(0);
    }
    let name_words: Vec<u32> = name_bytes.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
    let mut pos = 5;
    let mut entry_count = 0;
    while pos < words.len() {
        let (count, opcode) = (words[pos] >> 16, words[pos] & 0xFFFF);
        let count = count as usize;
        if count == 0 || pos + count > words.len() {
            bail!("malformed SPIR-V instruction");
        }
        let mut instruction = words[pos..pos + count].to_vec();
        if opcode == 15 {
            if count < 4 || instruction[1] != (if stage == 0 { 0 } else { 4 }) {
                bail!("SPIR-V entry point disagrees with shader stage");
            }
            entry_count += 1;
            let mut old_name_end = 3;
            while old_name_end < count
                && !instruction[old_name_end].to_le_bytes().contains(&0)
            {
                old_name_end += 1;
            }
            if old_name_end == count {
                bail!("unterminated SPIR-V entry-point name");
            }
            let mut rebuilt = instruction[..3].to_vec();
            rebuilt.extend_from_slice(&name_words);
            rebuilt.extend_from_slice(&instruction[old_name_end + 1..]);
            rebuilt[0] = ((rebuilt.len() as u32) << 16) | opcode as u32;
            instruction = rebuilt;
        } else if opcode == 71 && count == 4 && instruction[2] == 34 {
            if instruction[3] != 0 {
                bail!("translator uses an unexpected descriptor set");
            }
            instruction[3] = set_index;
        } else if opcode == 71 && count == 4 && instruction[2] == 30 {
            let expected_storage = if stage == 0 { 3 } else { 1 };
            if variable_storage.get(&instruction[1]) == Some(&expected_storage) {
                let loc = instruction[3];
                match varying_locations.get(&loc) {
                    Some(v) => instruction[3] = *v,
                    None => bail!("SPIR-V varying is missing from reflection"),
                }
            }
        }
        result.extend_from_slice(&instruction);
        pos += count;
    }
    if entry_count != 1 {
        bail!("adapter supports exactly one entry per library");
    }
    Ok(words_to(&result))
}

/// (type, metal_index, internal_binding, access) rows for the MVK1 packet.
pub fn binding_packet(reflection: &Value, stage: u8) -> Result<Vec<(u32, u32, u32, u32)>> {
    let mut result = vec![];
    let mut unsupported = vec![];
    let mut occupied = HashSet::new();
    for binding in reflection.get("bindings").and_then(|b| b.as_array()).into_iter().flatten() {
        let kind = binding.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        let descriptor = binding.get("descriptor");
        let Some(descriptor) = descriptor else {
            unsupported.push(format!("{kind}: resource has no descriptor contract"));
            continue;
        };
        let set = descriptor.get("set").and_then(|v| v.as_u64()).unwrap_or(99);
        let count = descriptor.get("count").and_then(|v| v.as_u64()).unwrap_or(0);
        if set != 0 || count != 1 {
            unsupported.push(format!("{kind}: descriptor arrays/other sets need backend support"));
            continue;
        }
        let index = binding.get("metal_index").and_then(|v| v.as_u64());
        let internal = descriptor.get("binding").and_then(|v| v.as_u64());
        let (Some(index), Some(internal)) = (index, internal) else {
            unsupported.push(format!("{kind}: invalid descriptor binding"));
            continue;
        };
        if index > 127 || internal > 4095 || occupied.contains(&internal) {
            bail!("invalid or duplicate descriptor binding");
        }
        occupied.insert(internal);
        let (binding_type, access) = match kind {
            "Buffer" => (4, 0),
            "Texture" => (1, 0),
            "StorageImage" => (1, 3),
            "Sampler" => (2, 0),
            _ => {
                unsupported.push(format!("{kind}: explicit adapter implementation required"));
                continue;
            }
        };
        result.push((binding_type, index as u32, internal as u32, access));
    }
    if stage == 2 {
        unsupported.push("compute dispatch/push-constant ABI is not implemented".into());
    }
    for field in [
        "runtime_sampler_specializations",
        "runtime_storage_image_specializations",
        "function_constants",
        "argument_buffer_fields",
        "tessellation",
        "imageblock_layouts",
        "implicit_imageblock_attachments",
        "fragment_imageblock",
    ] {
        if reflection.get(field).is_some_and(|v| !v.is_null() && v != &Value::from(false) && v.as_array().is_some_and(|a| !a.is_empty())) {
            unsupported.push(format!("{field}: adapter implementation required"));
        }
    }
    if !unsupported.is_empty() {
        bail!("{}", unsupported.join("; "));
    }
    Ok(result)
}

/// Reject reflection that disagrees with the actual SPIR-V resource ABI.
pub fn audit_descriptors(data: &[u8], reflection: &Value) -> Result<()> {
    let words = words_of(data)?;
    let mut types: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut variables: HashMap<u32, (u32, u32)> = HashMap::new();
    let mut decorations: HashMap<(u32, u32), u32> = HashMap::new();
    let mut pos = 5;
    while pos < words.len() {
        let (count, opcode) = (words[pos] >> 16, words[pos] & 0xFFFF);
        let count = count as usize;
        if count == 0 || pos + count > words.len() {
            bail!("malformed SPIR-V instruction");
        }
        let ins = &words[pos..pos + count];
        if (19..=33).contains(&opcode) && count >= 2 {
            types.insert(ins[1], ins.to_vec());
        } else if opcode == 59 && count >= 4 {
            variables.insert(ins[2], (ins[1], ins[3]));
        } else if opcode == 71 && count == 4 && (ins[2] == 33 || ins[2] == 34) {
            let key = (ins[1], ins[2]);
            if decorations.contains_key(&key) {
                bail!("duplicate descriptor decoration");
            }
            decorations.insert(key, ins[3]);
        }
        pos += count;
    }
    let mut actual: HashMap<(u32, u32), &str> = HashMap::new();
    for (variable, (pointer_id, storage)) in &variables {
        if ![0, 2, 12].contains(storage) {
            continue;
        }
        let pointer = types.get(pointer_id).map(|v| v.as_slice()).unwrap_or(&[]);
        if pointer.len() != 4 || pointer[0] & 0xFFFF != 32 || pointer[2] != *storage {
            bail!("invalid descriptor pointer type");
        }
        let value = types.get(&pointer[3]).map(|v| v.as_slice()).unwrap_or(&[]);
        let opcode = if value.is_empty() { 0 } else { value[0] & 0xFFFF };
        let kind = if opcode == 30 && *storage == 12 {
            "Buffer"
        } else if opcode == 26 && *storage == 0 {
            "Sampler"
        } else if opcode == 25 && *storage == 0 && value.len() >= 9 && (value[7] == 1 || value[7] == 2) {
            if value[7] == 1 { "Texture" } else { "StorageImage" }
        } else {
            bail!("unsupported descriptor type/array ABI");
        };
        if !decorations.contains_key(&(*variable, 33)) || !decorations.contains_key(&(*variable, 34)) {
            bail!("descriptor lacks set/binding decorations");
        }
        let key = (decorations[&(*variable, 34)], decorations[&(*variable, 33)]);
        if actual.contains_key(&key) {
            bail!("duplicate SPIR-V descriptor binding");
        }
        actual.insert(key, kind);
    }
    let mut expected: HashMap<(u32, u32), &str> = HashMap::new();
    for binding in reflection.get("bindings").and_then(|b| b.as_array()).into_iter().flatten() {
        let d = &binding["descriptor"];
        let key = (
            d.get("set").and_then(|v| v.as_u64()).unwrap_or(99) as u32,
            d.get("binding").and_then(|v| v.as_u64()).unwrap_or(9999) as u32,
        );
        let kind = binding.get("kind").and_then(|k| k.as_str()).unwrap_or("");
        expected.insert(key, kind);
    }
    if actual != expected {
        bail!("SPIR-V descriptors disagree with shader reflection");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn op(code: u32, words: &[u32]) -> Vec<u32> {
        let mut v = vec![((words.len() as u32 + 1) << 16) | code];
        v.extend_from_slice(words);
        v
    }

    fn spirv(instructions: &[Vec<u32>]) -> Vec<u8> {
        let mut words = vec![0x0723_0203, 0x0001_0500, 0, 100, 0];
        for ins in instructions {
            words.extend_from_slice(ins);
        }
        words_to(&words)
    }

    fn descriptor(binding: u32, kind: &str, index: u32) -> Value {
        json!({"kind": kind, "metal_index": index,
               "descriptor": {"set": 0, "binding": binding, "count": 1}})
    }

    #[test]
    fn buffers_use_ssbo_contract() {
        let reflection = json!({"bindings": [descriptor(0, "Buffer", 0)]});
        assert_eq!(binding_packet(&reflection, 0).unwrap(), vec![(4, 0, 0, 0)]);
        let module = spirv(&[op(30, &[1]), op(32, &[2, 12, 1]), op(59, &[2, 3, 12]),
                             op(71, &[3, 34, 0]), op(71, &[3, 33, 0])]);
        audit_descriptors(&module, &reflection).unwrap();
        let mut wrong = reflection.clone();
        wrong["bindings"][0]["kind"] = json!("Sampler");
        assert!(audit_descriptors(&module, &wrong).unwrap_err().to_string().contains("disagree"));
    }

    #[test]
    fn sampler_and_texture_audit() {
        let module = spirv(&[op(26, &[1]), op(32, &[2, 0, 1]), op(59, &[2, 3, 0]),
                             op(71, &[3, 34, 0]), op(71, &[3, 33, 160]),
                             op(25, &[4, 10, 1, 0, 0, 0, 1, 0]), op(32, &[5, 0, 4]),
                             op(59, &[5, 6, 0]), op(71, &[6, 34, 0]), op(71, &[6, 33, 32])]);
        audit_descriptors(&module, &json!({"bindings": [descriptor(160, "Sampler", 0),
                                                       descriptor(32, "Texture", 0)]}))
            .unwrap();
    }

    #[test]
    fn unknown_abi_rejected() {
        for (stage, update) in [(2u8, json!({})), (0, json!({"function_constants": [1]})),
                               (0, json!({"runtime_sampler_specializations": [1]})),
                               (0, json!({"argument_buffer_fields": [1]}))] {
            let mut r = json!({"bindings": []});
            for (k, v) in update.as_object().unwrap() {
                r[k] = v.clone();
            }
            assert!(binding_packet(&r, stage).is_err(), "stage {stage}");
        }
        for count in [0, 2] {
            let mut d = descriptor(0, "Buffer", 0);
            d["descriptor"]["count"] = json!(count);
            assert!(binding_packet(&json!({"bindings": [d]}), 0).is_err());
        }
        let dup = json!({"bindings": [descriptor(0, "Buffer", 0), descriptor(0, "Buffer", 0)]});
        assert!(binding_packet(&dup, 0).unwrap_err().to_string().contains("duplicate"));
    }

    #[test]
    fn entry_remap() {
        let module = spirv(&[op(15, &[4, 1, 0x6e69616d, 0, 9]), op(59, &[2, 9, 1]),
                             op(71, &[9, 30, 0]), op(71, &[8, 34, 0])]);
        let out = adapt_spirv(&module, 1, "main0",
                              &json!({"varyings": [{"location": 0, "user_semantic": "user(locn7)"}]}))
            .unwrap();
        let words = words_of(&out).unwrap();
        let has = |ins: &[u32]| words.windows(ins.len()).any(|w| w == ins);
        assert!(has(&op(71, &[9, 30, 7])));
        assert!(has(&op(71, &[8, 34, 1])));
        assert!(out.windows(6).any(|w| w == b"main0\0"));
    }

    #[test]
    fn push_and_named_rejected() {
        assert!(adapt_spirv(&spirv(&[op(59, &[1, 2, 9])]), 0, "main0", &json!({"varyings": []}))
            .unwrap_err().to_string().contains("push-constant"));
        assert!(adapt_spirv(&spirv(&[]), 0, "main0",
                            &json!({"varyings": [{"location": 0, "user_semantic": "CUSTOM"}]}))
            .unwrap_err().to_string().contains("shared"));
    }

    #[test]
    fn malformed_rejected() {
        for module in [b"".to_vec(), b"12345".to_vec(), spirv(&[vec![0]]),
                       spirv(&[op(15, &[0, 1, 0x41414141])])] {
            assert!(adapt_spirv(&module, 0, "main0", &json!({"varyings": []})).is_err());
        }
        for library in [b"".to_vec(), [b"MTLB".to_vec(), vec![0u8; 84]].concat()] {
            assert!(functions(&library).is_err());
        }
    }

    #[test]
    fn table_length_excludes_count() {
        fn tag(name: &[u8], value: &[u8]) -> Vec<u8> {
            [name, &(value.len() as u16).to_le_bytes(), value].concat()
        }
        let mut tags = tag(b"NAME", b"main0\0");
        tags.extend(tag(b"TYPE", b"\0"));
        tags.extend(tag(b"MDSZ", &4u64.to_le_bytes()));
        tags.extend(tag(b"OFFT", &[0u8; 24]));
        tags.extend(b"ENDT");
        let mut group = (tags.len() as u32 + 4).to_le_bytes().to_vec();
        group.extend(tags);
        let mut header = vec![0u8; 88];
        header[..4].copy_from_slice(b"MTLB");
        let bitcode_offset = 88 + 4 + group.len();
        for (i, v) in [bitcode_offset as u64 + 4, 88, group.len() as u64, 0, 0, 0, 0, bitcode_offset as u64, 4].iter().enumerate() {
            header[16 + i * 8..16 + i * 8 + 8].copy_from_slice(&v.to_le_bytes());
        }
        let mut library = header;
        library.extend_from_slice(&1u32.to_le_bytes());
        library.extend_from_slice(&group);
        library.extend_from_slice(b"AIR!");
        let funcs = functions(&library).unwrap();
        assert_eq!(funcs.len(), 1);
        assert_eq!(funcs[0].name, "main0");
        assert_eq!(funcs[0].bitcode, b"AIR!");
    }
}
pub fn convert(library: &[u8], out_dir: &Path, translator: &str) -> Result<serde_json::Value> {
    let funcs = functions(library)?;
    if funcs.len() != 1 {
        bail!("adapter supports exactly one function per metallib");
    }
    let func = &funcs[0];
    let digest = sha256_hex(library);
    std::fs::create_dir_all(out_dir)?;
    std::fs::write(out_dir.join(format!("{digest}.metallib")), library)?;
    let air = out_dir.join(format!("{digest}.air"));
    std::fs::write(&air, &func.bitcode)?;
    let spv_path = out_dir.join(format!("{digest}.spv"));
    let meta_path = out_dir.join(format!("{digest}.json"));
    let stage_name = ["vertex", "fragment", "kernel"][func.stage.min(2) as usize];
    let status = std::process::Command::new(translator)
        .args([air.to_str().unwrap_or(""), spv_path.to_str().unwrap_or(")"), "--stage", stage_name, "--raster-samples", "1", "--emit-meta", meta_path.to_str().unwrap_or("")])
        .status()?;
    if !status.success() {
        bail!("translator failed");
    }
    let reflection: Value = serde_json::from_str(&std::fs::read_to_string(&meta_path)?)?;
    let entry = reflection.get("entry_point").and_then(|v| v.as_str()).unwrap_or("");
    if entry != func.name {
        bail!("AIR and metallib disagree about entry-point identity");
    }
    let bindings = binding_packet(&reflection, func.stage)?;
    let data = std::fs::read(&spv_path)?;
    audit_descriptors(&data, &reflection)?;
    let data = adapt_spirv(&data, func.stage, &func.name, &reflection)?;
    std::fs::write(&spv_path, &data)?;
    let status = std::process::Command::new("spirv-val")
        .args(["--target-env", "vulkan1.2", spv_path.to_str().unwrap_or("")])
        .status()?;
    if !status.success() {
        bail!("spirv-val rejected the adapted module");
    }
    let name_bytes = func.name.as_bytes();
    let mut packet = b"MVK1".to_vec();
    for v in [1u32, func.stage as u32 + 1, name_bytes.len() as u32, bindings.len() as u32, data.len() as u32] {
        packet.extend_from_slice(&v.to_le_bytes());
    }
    packet.extend_from_slice(name_bytes);
    for (t, i, b, a) in &bindings {
        for v in [*t, *i, *b, *a] {
            packet.extend_from_slice(&v.to_le_bytes());
        }
    }
    packet.extend_from_slice(&data);
    std::fs::write(out_dir.join(format!("{digest}.mvk")), &packet)?;
    Ok(serde_json::json!({
        "sha256": digest, "name": func.name, "stage": func.stage,
        "bindings": bindings.iter().map(|b| vec![b.0, b.1, b.2, b.3]).collect::<Vec<_>>(),
        "validated_bytes": data.len(),
    }))
}
