//! Malphas Source Pack (MSP) compiler v2.7.0.
//!
//! Builds a rigid, 64-byte aligned binary from a human-readable workspace:
//!
//!   MspHeader (64 bytes) -> MspEntityDescriptor[] (64 bytes each) -> Payloads
//!
//! Every payload starts at an absolute file offset that is a strict multiple of
//! 64 bytes.  Raw zero padding is injected between payloads; the compiler never
//! relies on struct padding.  The last 64 KB of the payload section are reserved
//! for hardcoded Error Payloads used by the runtime fallback path.

use std::collections::HashSet;
use std::error::Error;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::manifest::Manifest;

pub const MSP_MAGIC: [u8; 4] = *b"MLPS";
pub const MSP_VERSION: u32 = 2;
/// Space reserved at the end of the payload section for Error Payloads.
pub const ERROR_PAYLOAD_RESERVE: usize = 64 * 1024;

/// 64-byte aligned MSP header (one cache line).
#[repr(C, align(64))]
#[derive(Clone, Copy, Debug)]
pub struct MspHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub entity_table_offset: u32,
    pub entity_count: u32,
    pub payload_section_offset: u32,
    pub payload_section_size: u32,
    pub checksum: u64,
    pub _padding: [u8; 32],
}

/// 64-byte aligned entity descriptor (one cache line).
///
/// Because `tag_mask` is a u64 placed after a u32, `#[repr(C)]` inserts 4 bytes
/// of implicit padding.  The manual padding is therefore 40 bytes so the total
/// struct size remains exactly 64 bytes.
#[repr(C, align(64))]
#[derive(Clone, Copy, Debug)]
pub struct MspEntityDescriptor {
    pub entity_id: u32,
    pub tag_mask: u64,
    pub payload_offset: u32,
    pub payload_size: u32,
    pub _padding: [u8; 40],
}

/// Compute the deterministic u64 checksum used by the runtime loader.
///
/// The checksum covers the entity table concatenated with the payload section.
pub fn compute_msp_checksum(data: &[u8]) -> u64 {
    let mut checksum: u64 = 0;
    let chunks = data.chunks_exact(8);
    let remainder = chunks.remainder();
    for chunk in chunks {
        let mut word = [0u8; 8];
        word.copy_from_slice(chunk);
        checksum ^= u64::from_le_bytes(word);
    }
    if !remainder.is_empty() {
        let mut word = [0u8; 8];
        word[..remainder.len()].copy_from_slice(remainder);
        checksum ^= u64::from_le_bytes(word);
    }
    checksum
}

/// Append zero bytes until `data.len()` is a multiple of 64.
pub fn pad64(data: &mut Vec<u8>) {
    let rem = data.len() % 64;
    if rem != 0 {
        data.resize(data.len() + (64 - rem), 0);
    }
}

/// Validate a pack identifier.
pub fn validate_pack_id(pack_id: &str) -> Result<(), Box<dyn Error>> {
    if pack_id.is_empty() {
        return Err("pack_id must not be empty".into());
    }
    if pack_id.len() > 16 {
        return Err(format!("pack_id too long (max 16 characters): {pack_id}").into());
    }
    if !pack_id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return Err(format!("pack_id contains invalid characters: {pack_id}").into());
    }
    Ok(())
}

/// Build the MSP byte vector from a parsed manifest and its directory.
pub fn build_msp(manifest: &Manifest, manifest_dir: &Path) -> Result<Vec<u8>, Box<dyn Error>> {
    validate_pack_id(&manifest.pack_id)?;

    if manifest.entities.len() > u32::MAX as usize {
        return Err("too many entities".into());
    }

    // Detect duplicate entity IDs early.
    let mut seen_ids = HashSet::with_capacity(manifest.entities.len());
    for entity in &manifest.entities {
        if !seen_ids.insert(entity.entity_id) {
            return Err(format!("duplicate entity_id: {}", entity.entity_id).into());
        }
    }

    let header_size = std::mem::size_of::<MspHeader>();
    let descriptor_size = std::mem::size_of::<MspEntityDescriptor>();
    let entity_count = manifest.entities.len();

    let entity_table_offset = header_size; // 64
    let payload_section_offset = entity_table_offset + entity_count * descriptor_size; // multiple of 64

    // Read payload files and record offsets.  Each payload starts on a 64-byte
    // boundary; padding is injected after the previous payload when necessary.
    let mut payload_section: Vec<u8> = Vec::new();
    let mut descriptors: Vec<MspEntityDescriptor> = Vec::with_capacity(entity_count);

    for entity in &manifest.entities {
        let payload_path = manifest_dir.join(&entity.payload_file);
        let payload_bytes = fs::read(&payload_path).map_err(|e| {
            format!(
                "failed to read payload file '{}': {e}",
                payload_path.display()
            )
        })?;

        if payload_bytes.len() > u32::MAX as usize {
            return Err(format!("payload too large for entity {}", entity.entity_id).into());
        }

        // Current end of payload_section is the absolute start offset of this
        // payload because payload_section_offset is already 64-byte aligned and
        // every previous payload was padded to 64 bytes.
        let payload_offset = payload_section.len();
        let payload_size = payload_bytes.len();

        descriptors.push(MspEntityDescriptor {
            entity_id: entity.entity_id,
            tag_mask: entity.tag_mask,
            payload_offset: payload_offset as u32,
            payload_size: payload_size as u32,
            _padding: [0; 40],
        });

        payload_section.extend_from_slice(&payload_bytes);
        pad64(&mut payload_section);
    }

    // Reserve the 64 KB Error Payload region at the end of the section.
    payload_section.resize(payload_section.len() + ERROR_PAYLOAD_RESERVE, 0);
    pad64(&mut payload_section);

    // Build entity table bytes.
    let mut entity_table_bytes = Vec::with_capacity(entity_count * descriptor_size);
    for descriptor in &descriptors {
        entity_table_bytes.extend_from_slice(&descriptor_as_bytes(descriptor));
    }

    // Assemble body: entity table followed by payload section.
    let mut body = vec![0u8; payload_section_offset - header_size];
    body[..entity_table_bytes.len()].copy_from_slice(&entity_table_bytes);
    body.extend_from_slice(&payload_section);

    // Checksum covers entity table + payload section.
    let checksum = compute_msp_checksum(&body);

    let header = MspHeader {
        magic: MSP_MAGIC,
        version: MSP_VERSION,
        entity_table_offset: entity_table_offset as u32,
        entity_count: entity_count as u32,
        payload_section_offset: payload_section_offset as u32,
        payload_section_size: payload_section.len() as u32,
        checksum,
        _padding: [0; 32],
    };

    let mut output = Vec::with_capacity(header_size + body.len());
    output.extend_from_slice(&header_as_bytes(&header));
    output.extend_from_slice(&body);
    Ok(output)
}

/// Compile a workspace manifest into a `.msp` file next to it.
pub fn compile_manifest(manifest_path: &Path) -> Result<PathBuf, Box<dyn Error>> {
    let manifest_dir = manifest_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));

    let manifest_text = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest '{}': {e}", manifest_path.display()))?;
    let manifest: Manifest = serde_json::from_str(&manifest_text)
        .map_err(|e| format!("invalid manifest '{}': {e}", manifest_path.display()))?;

    let msp = build_msp(&manifest, manifest_dir)?;

    let msp_path = manifest_dir.join(format!("{}.msp", manifest.pack_id));
    let mut file = fs::File::create(&msp_path)?;
    file.write_all(&msp)?;
    file.flush()?;

    println!("Compiled: {}", msp_path.display());
    Ok(msp_path)
}

/// Serialize an `MspHeader` into its exact 64-byte on-disk representation.
pub fn header_as_bytes(header: &MspHeader) -> [u8; 64] {
    let mut buf = [0u8; 64];
    buf[0..4].copy_from_slice(&header.magic);
    buf[4..8].copy_from_slice(&header.version.to_le_bytes());
    buf[8..12].copy_from_slice(&header.entity_table_offset.to_le_bytes());
    buf[12..16].copy_from_slice(&header.entity_count.to_le_bytes());
    buf[16..20].copy_from_slice(&header.payload_section_offset.to_le_bytes());
    buf[20..24].copy_from_slice(&header.payload_section_size.to_le_bytes());
    buf[24..32].copy_from_slice(&header.checksum.to_le_bytes());
    buf[32..64].copy_from_slice(&header._padding);
    buf
}

/// Serialize an `MspEntityDescriptor` into its exact 64-byte representation.
pub fn descriptor_as_bytes(descriptor: &MspEntityDescriptor) -> [u8; 64] {
    let mut buf = [0u8; 64];
    buf[0..4].copy_from_slice(&descriptor.entity_id.to_le_bytes());
    buf[8..16].copy_from_slice(&descriptor.tag_mask.to_le_bytes());
    buf[16..20].copy_from_slice(&descriptor.payload_offset.to_le_bytes());
    buf[20..24].copy_from_slice(&descriptor.payload_size.to_le_bytes());
    buf[24..64].copy_from_slice(&descriptor._padding);
    buf
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::ManifestEntity;
    use std::io::Write;

    fn write_file(path: &Path, bytes: &[u8]) {
        let mut file = fs::File::create(path).unwrap();
        file.write_all(bytes).unwrap();
        file.flush().unwrap();
    }

    #[test]
    fn header_and_descriptor_are_64_bytes() {
        assert_eq!(std::mem::size_of::<MspHeader>(), 64);
        assert_eq!(std::mem::align_of::<MspHeader>(), 64);
        assert_eq!(std::mem::size_of::<MspEntityDescriptor>(), 64);
        assert_eq!(std::mem::align_of::<MspEntityDescriptor>(), 64);
    }

    #[test]
    fn build_msp_aligns_payload_offsets_to_64_bytes() {
        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_test_align_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let payload_a = tmp_dir.join("a.bin");
        let payload_b = tmp_dir.join("b.bin");
        write_file(&payload_a, &[1u8; 37]); // not a multiple of 64
        write_file(&payload_b, &[2u8; 64]);

        let manifest = Manifest {
            pack_id: "align_test".to_string(),
            entities: vec![
                ManifestEntity {
                    entity_id: 0,
                    tag_mask: 1,
                    payload_file: PathBuf::from("a.bin"),
                },
                ManifestEntity {
                    entity_id: 1,
                    tag_mask: 2,
                    payload_file: PathBuf::from("b.bin"),
                },
            ],
        };

        let msp = build_msp(&manifest, &tmp_dir).unwrap();

        let entity_table_offset = u32::from_le_bytes(msp[8..12].try_into().unwrap()) as usize;
        let payload_section_offset = u32::from_le_bytes(msp[16..20].try_into().unwrap()) as usize;
        let entity_count = u32::from_le_bytes(msp[12..16].try_into().unwrap()) as usize;

        assert_eq!(entity_table_offset, 64);
        assert_eq!(entity_count, 2);
        assert!(payload_section_offset.is_multiple_of(64));

        let desc0_offset = entity_table_offset;
        let desc1_offset = entity_table_offset + 64;
        let payload0_offset = u32::from_le_bytes(
            msp[desc0_offset + 16..desc0_offset + 20]
                .try_into()
                .unwrap(),
        ) as usize;
        let payload1_offset = u32::from_le_bytes(
            msp[desc1_offset + 16..desc1_offset + 20]
                .try_into()
                .unwrap(),
        ) as usize;

        // Offsets are relative to the payload section; absolute offsets include
        // payload_section_offset.
        assert!(payload0_offset.is_multiple_of(64));
        assert!(payload1_offset.is_multiple_of(64));
        assert!(payload_section_offset + payload0_offset < msp.len());
        assert!(payload_section_offset + payload1_offset < msp.len());

        // Verify payload bytes are written at the expected absolute offsets.
        assert_eq!(
            &msp[payload_section_offset + payload0_offset
                ..payload_section_offset + payload0_offset + 37],
            &[1u8; 37]
        );
        assert_eq!(
            &msp[payload_section_offset + payload1_offset
                ..payload_section_offset + payload1_offset + 64],
            &[2u8; 64]
        );

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn compile_round_trip_produces_valid_msp() {
        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_test_roundtrip_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let payload_path = tmp_dir.join("entity0.bin");
        write_file(&payload_path, b"MALPHAS ENTITY 0");

        let manifest_path = tmp_dir.join("manifest.json");
        let mut file = fs::File::create(&manifest_path).unwrap();
        file.write_all(
            br#"{"pack_id":"round_trip_pack","entities":[{"entity_id":0,"tag_mask":7,"payload_file":"entity0.bin"}]}"#,
        )
        .unwrap();
        file.flush().unwrap();
        drop(file);

        let msp_path = compile_manifest(&manifest_path).unwrap();
        assert!(msp_path.exists());

        let msp = fs::read(&msp_path).unwrap();
        assert_eq!(&msp[0..4], b"MLPS");
        assert_eq!(msp.len() % 64, 0);

        // Verify checksum over entity table + payload section.
        let entity_table_offset = u32::from_le_bytes(msp[8..12].try_into().unwrap()) as usize;
        let payload_section_size = u32::from_le_bytes(msp[20..24].try_into().unwrap()) as usize;
        let stored_checksum = u64::from_le_bytes(msp[24..32].try_into().unwrap());
        let calculated = compute_msp_checksum(
            &msp[entity_table_offset..entity_table_offset + payload_section_size],
        );
        assert_eq!(calculated, stored_checksum);

        // Verify payload size and content.
        let desc_payload_size =
            u32::from_le_bytes(msp[64 + 20..64 + 24].try_into().unwrap()) as usize;
        assert_eq!(desc_payload_size, b"MALPHAS ENTITY 0".len());

        let _ = fs::remove_file(&msp_path);
        let _ = fs::remove_file(&manifest_path);
        let _ = fs::remove_file(&payload_path);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn build_msp_rejects_duplicate_entity_ids() {
        let manifest = Manifest {
            pack_id: "dup_test".to_string(),
            entities: vec![
                ManifestEntity {
                    entity_id: 0,
                    tag_mask: 1,
                    payload_file: PathBuf::from("a.bin"),
                },
                ManifestEntity {
                    entity_id: 0,
                    tag_mask: 2,
                    payload_file: PathBuf::from("b.bin"),
                },
            ],
        };
        let result = build_msp(&manifest, Path::new("."));
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("duplicate entity_id"));
    }
}
