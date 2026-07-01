//! Malphas Source Pack (MSP) compiler v3.0.0.
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

use sha2::{Digest, Sha256};

use crate::manifest::Manifest;
use crate::payload_schema::payload_type_id_from_name;

pub const MSP_MAGIC: [u8; 4] = *b"MLPS";
pub const MSP_VERSION: u32 = 4;
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
    pub checksum: [u8; 32],
    pub _padding: [u8; 8],
}

/// 64-byte aligned entity descriptor (one cache line).
///
/// The 4-byte gap between `entity_id` and `tag_mask` carries `payload_type_id`,
/// leaving 40 bytes of explicit padding so the total struct size remains exactly
/// 64 bytes.
#[repr(C, align(64))]
#[derive(Clone, Copy, Debug)]
pub struct MspEntityDescriptor {
    pub entity_id: u32,
    pub payload_type_id: u32,
    pub tag_mask: u64,
    pub payload_offset: u32,
    pub payload_size: u32,
    pub _padding: [u8; 40],
}

/// Compute the deterministic SHA-256 digest used by the runtime loader.
///
/// The digest covers the entity table concatenated with the payload section.
pub fn compute_msp_sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
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

/// Resolve and validate a payload file path.
///
/// The path must be relative, must not contain parent-directory components,
/// and must resolve to a location inside the manifest directory.  Symlinks are
/// followed by `canonicalize` and rejected if they escape the workspace.
fn resolve_payload_path(
    payload_file: &Path,
    manifest_dir: &Path,
) -> Result<PathBuf, Box<dyn Error>> {
    if payload_file.is_absolute() {
        return Err(format!(
            "absolute payload paths are not allowed: {}",
            payload_file.display()
        )
        .into());
    }

    if payload_file
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(format!(
            "payload paths must not contain '..' components: {}",
            payload_file.display()
        )
        .into());
    }

    let canonical_manifest = manifest_dir.canonicalize().map_err(|e| {
        format!(
            "failed to canonicalize manifest directory '{}': {e}",
            manifest_dir.display()
        )
    })?;

    let resolved = manifest_dir.join(payload_file);
    let canonical_payload = resolved.canonicalize().map_err(|e| {
        format!(
            "failed to canonicalize payload file '{}': {e}",
            resolved.display()
        )
    })?;

    if !canonical_payload.starts_with(&canonical_manifest) {
        return Err(format!(
            "payload file '{}' resolves outside the manifest directory",
            payload_file.display()
        )
        .into());
    }

    Ok(canonical_payload)
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
        let payload_path = resolve_payload_path(&entity.payload_file, manifest_dir)?;
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
            payload_type_id: payload_type_id_from_name(&entity.payload_type),
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
    let checksum = compute_msp_sha256(&body);

    let header = MspHeader {
        magic: MSP_MAGIC,
        version: MSP_VERSION,
        entity_table_offset: entity_table_offset as u32,
        entity_count: entity_count as u32,
        payload_section_offset: payload_section_offset as u32,
        payload_section_size: payload_section.len() as u32,
        checksum,
        _padding: [0; 8],
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
    buf[24..56].copy_from_slice(&header.checksum);
    buf[56..64].copy_from_slice(&header._padding);
    buf
}

/// Serialize an `MspEntityDescriptor` into its exact 64-byte representation.
pub fn descriptor_as_bytes(descriptor: &MspEntityDescriptor) -> [u8; 64] {
    let mut buf = [0u8; 64];
    buf[0..4].copy_from_slice(&descriptor.entity_id.to_le_bytes());
    buf[4..8].copy_from_slice(&descriptor.payload_type_id.to_le_bytes());
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
                    payload_type: "unknown".to_string(),
                    payload_file: PathBuf::from("a.bin"),
                },
                ManifestEntity {
                    entity_id: 1,
                    tag_mask: 2,
                    payload_type: "unknown".to_string(),
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

        // Verify SHA-256 digest over entity table + payload section.
        let entity_table_offset = u32::from_le_bytes(msp[8..12].try_into().unwrap()) as usize;
        let payload_section_offset = u32::from_le_bytes(msp[16..20].try_into().unwrap()) as usize;
        let payload_section_size = u32::from_le_bytes(msp[20..24].try_into().unwrap()) as usize;
        let stored_checksum = &msp[24..56];
        let calculated = compute_msp_sha256(
            &msp[entity_table_offset..payload_section_offset + payload_section_size],
        );
        assert_eq!(&calculated[..], stored_checksum);

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
                    payload_type: "unknown".to_string(),
                    payload_file: PathBuf::from("a.bin"),
                },
                ManifestEntity {
                    entity_id: 0,
                    tag_mask: 2,
                    payload_type: "unknown".to_string(),
                    payload_file: PathBuf::from("b.bin"),
                },
            ],
        };
        let result = build_msp(&manifest, Path::new("."));
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("duplicate entity_id"));
    }

    #[test]
    fn build_msp_rejects_traversal_payload_file() {
        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_test_traversal_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let manifest_dir = tmp_dir.join("workspace");
        fs::create_dir_all(&manifest_dir).unwrap();

        // Regression: the exact traversal payload from the v3.0.0 hardening spec
        // must be rejected before any filesystem read is attempted.
        let manifest = Manifest {
            pack_id: "traversal_test".to_string(),
            entities: vec![ManifestEntity {
                entity_id: 0,
                tag_mask: 1,
                payload_type: "unknown".to_string(),
                payload_file: PathBuf::from("../etc/passwd"),
            }],
        };

        let result = build_msp(&manifest, &manifest_dir);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("'..' components") || msg.contains("outside the manifest directory"),
            "unexpected error message: {msg}"
        );

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn build_msp_rejects_absolute_payload_path() {
        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_test_absolute_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let payload_file = tmp_dir.join("entity.bin");
        write_file(&payload_file, b"payload");

        let manifest_dir = tmp_dir.join("workspace");
        fs::create_dir_all(&manifest_dir).unwrap();

        let manifest = Manifest {
            pack_id: "absolute_test".to_string(),
            entities: vec![ManifestEntity {
                entity_id: 0,
                tag_mask: 1,
                payload_type: "unknown".to_string(),
                payload_file: payload_file.clone(),
            }],
        };

        let result = build_msp(&manifest, &manifest_dir);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(
            msg.contains("absolute payload paths are not allowed"),
            "unexpected error message: {msg}"
        );

        let _ = fs::remove_file(&payload_file);
        let _ = fs::remove_dir_all(&tmp_dir);
    }
}
