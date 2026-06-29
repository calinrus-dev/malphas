//! Malphas package compiler and signer CLI.
//!
//! Subcommands:
//!   compile <manifest.json>  -- Build <pack_id>.mhp and <pack_id>.msp
//!   sign    <file> <privkey> -- Write <file>.sig

use clap::{Parser, Subcommand};
use ed25519_dalek::{Signer, SigningKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};

const MHP_HEADER_SIZE: usize = 112;
const MSP_HEADER_SIZE: usize = 64;
const FONT_ATLAS_WIDTH: usize = 512;
const FONT_ATLAS_HEIGHT: usize = 512;
const FONT_ATLAS_SIZE: usize = FONT_ATLAS_WIDTH * FONT_ATLAS_HEIGHT; // 262144
const FONT_METRICS_SIZE: usize = 4096;
const CELL_SIZE: usize = 32;
const GLYPH_SIZE_PX: f32 = 24.0;

#[repr(C, align(16))]
#[derive(Clone, Copy, Debug)]
struct MhpHeader {
    magic: [u8; 4],
    version: u32,
    total_size: u64,
    checksum: [u8; 32],
    pack_id: [u8; 16],
    canvas_width: u16,
    canvas_height: u16,
    font_metrics_offset: u32,
    font_atlas_offset: u32,
    objects_table_offset: u32,
    objects_table_count: u32,
    skins_offset: u32,
    skins_size: u32,
    has_embedded_msp: u32,
    embedded_msp_offset: u32,
    embedded_msp_size: u32,
    padding: [u8; 4],
}

#[repr(C, align(16))]
#[derive(Clone, Copy, Debug)]
struct MhpObjectDescriptor {
    object_id: u32,
    properties_offset: u32,
    properties_size: u32,
    skins_offset: u32,
    skins_size: u32,
    padding: [u8; 12],
}

#[repr(C, align(16))]
#[derive(Clone, Copy, Debug)]
struct MspHeader {
    magic: [u8; 4],
    version: u32,
    checksum: [u8; 32],
    bytecode_size: u32,
    entry_point: u32,
    padding: [u8; 16],
}

/// Typed manifest.json schema for the compiler.
///
/// `deny_unknown_fields` rejects any key that the compiler does not understand,
/// which catches typos early instead of silently ignoring them.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    pack_id: String,
    canvas_width: u16,
    canvas_height: u16,
    objects: Vec<ManifestObject>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestObject {
    object_id: u32,
    properties: serde_json::Value,
}

#[derive(Parser)]
#[command(
    name = "malphas-cli",
    version,
    about = "Malphas package compiler and signer"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Compile a manifest into .mhp and .msp packages.
    Compile {
        /// Path to manifest.json
        manifest: PathBuf,
    },
    /// Sign a file with an Ed25519 private key.
    Sign {
        /// File to sign
        file: PathBuf,
        /// 32-byte Ed25519 private key as hex
        private_key_hex: String,
    },
}

/// Validate a pack identifier.
///
/// Allowed characters are ASCII letters, digits, underscore and hyphen; the
/// length must be between 1 and 16 inclusive. This set intentionally excludes
/// path separators and `.`, so it also rejects path-traversal attempts such as
/// `..` or `../evil`.
fn validate_pack_id(pack_id: &str) -> Result<(), Box<dyn Error>> {
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

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Compile { manifest } => {
            if let Err(e) = compile_manifest(&manifest) {
                eprintln!("Compile failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Sign {
            file,
            private_key_hex,
        } => {
            if let Err(e) = sign_file(&file, &private_key_hex) {
                eprintln!("Sign failed: {e}");
                std::process::exit(1);
            }
        }
    }
}

/// Append zero padding so `data.len()` becomes a multiple of 16.
fn pad16(data: &mut Vec<u8>) {
    let rem = data.len() % 16;
    if rem != 0 {
        data.resize(data.len() + (16 - rem), 0);
    }
}

/// Locate the workspace root by walking up from `start` looking for a
/// Cargo.toml that contains `[workspace]`.
fn find_workspace_root(start: &Path) -> Option<PathBuf> {
    let mut current = Some(start);
    while let Some(dir) = current {
        let candidate = dir.join("Cargo.toml");
        if let Ok(contents) = fs::read_to_string(&candidate) {
            if contents.contains("[workspace]") {
                return Some(dir.to_path_buf());
            }
        }
        current = dir.parent();
    }
    None
}

/// Resolve the JetBrains Mono font path. Prefer a copy next to the manifest,
/// otherwise fall back to the workspace asset directory.
fn resolve_font_path(manifest_dir: &Path) -> Option<PathBuf> {
    let local = manifest_dir.join("JetBrainsMono-Regular.ttf");
    if local.is_file() {
        return Some(local);
    }
    find_workspace_root(manifest_dir).map(|root| {
        root.join("flutter_app")
            .join("assets")
            .join("fonts")
            .join("JetBrainsMono-Regular.ttf")
    })
}

/// Build a 512x512 A8 font atlas plus a 4096-byte metrics table.
fn compile_font_atlas(font_path: &Path) -> Result<(Vec<u8>, Vec<u8>), Box<dyn Error>> {
    let font_bytes = fs::read(font_path)?;
    let font = fontdue::Font::from_bytes(font_bytes, fontdue::FontSettings::default())
        .map_err(|e| format!("fontdue error: {e:?}"))?;

    let mut atlas = vec![0u8; FONT_ATLAS_SIZE];
    let mut metrics_table = vec![0u8; FONT_METRICS_SIZE];

    for char_code in 0..256u16 {
        let cell_x = (char_code as usize) % 16;
        let cell_y = (char_code as usize) / 16;
        let px = cell_x * CELL_SIZE;
        let py = cell_y * CELL_SIZE;

        let ch = char::from_u32(u32::from(char_code)).unwrap_or('\0');
        let (metrics, bitmap) = font.rasterize(ch, GLYPH_SIZE_PX);

        let mw = metrics.width;
        let mh = metrics.height;

        let start_x = px + (CELL_SIZE.saturating_sub(mw)) / 2;
        let start_y = py + (CELL_SIZE.saturating_sub(mh)) / 2;

        // Blit the glyph bitmap into the 32x32 cell, centered.
        for gy in 0..mh {
            let dst_y = start_y + gy;
            if dst_y >= FONT_ATLAS_HEIGHT {
                continue;
            }
            for gx in 0..mw {
                let dst_x = start_x + gx;
                if dst_x >= FONT_ATLAS_WIDTH {
                    continue;
                }
                let alpha = bitmap[gy * mw + gx];
                atlas[dst_y * FONT_ATLAS_WIDTH + dst_x] = alpha;
            }
        }

        let offset = (char_code as usize) * 16;
        let x_offset = ((CELL_SIZE.saturating_sub(mw)) / 2) as i16;
        let advance = if mw > 0 { mw as u16 } else { 16 };

        write_u16_le(&mut metrics_table, offset, char_code);
        write_u16_le(&mut metrics_table, offset + 2, u16::try_from(start_x)?);
        write_u16_le(&mut metrics_table, offset + 4, u16::try_from(start_y)?);
        write_u16_le(&mut metrics_table, offset + 6, u16::try_from(mw)?);
        write_u16_le(&mut metrics_table, offset + 8, u16::try_from(mh)?);
        write_i16_le(&mut metrics_table, offset + 10, x_offset);
        write_u16_le(&mut metrics_table, offset + 12, advance);
        // bytes 14-15 already zero (padding)
    }

    Ok((metrics_table, atlas))
}

fn write_u16_le(buf: &mut [u8], offset: usize, value: u16) {
    buf[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn write_i16_le(buf: &mut [u8], offset: usize, value: i16) {
    buf[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

/// Patch record for the two-pass bytecode assembler.
struct BytecodePatch {
    instruction_index: usize,
    target_label: &'static str,
    reg2: u8,
}

/// Two-pass assembler producing the default bouncing-physics bytecode.
fn assemble_bouncing_script() -> Vec<u8> {
    struct Assembler<'a> {
        insts: &'a mut Vec<u8>,
        labels: &'a mut std::collections::HashMap<&'static str, usize>,
        patches: &'a mut Vec<BytecodePatch>,
    }

    impl Assembler<'_> {
        fn mark(&mut self, name: &'static str) {
            self.labels.insert(name, self.insts.len() / 4);
        }

        fn emit(&mut self, op: u8, arg1: u8, val: u16) {
            self.insts.push(op);
            self.insts.push(arg1);
            self.insts.push(((val >> 8) & 0xFF) as u8);
            self.insts.push((val & 0xFF) as u8);
        }

        fn emit_jmp_lt(&mut self, label: &'static str, reg1: u8, reg2: u8) {
            self.patches.push(BytecodePatch {
                instruction_index: self.insts.len() / 4,
                target_label: label,
                reg2,
            });
            self.emit(0x08, reg1, 0);
        }
    }

    let mut insts: Vec<u8> = Vec::new();
    let mut labels: std::collections::HashMap<&'static str, usize> =
        std::collections::HashMap::new();
    let mut patches: Vec<BytecodePatch> = Vec::new();

    {
        let mut asm = Assembler {
            insts: &mut insts,
            labels: &mut labels,
            patches: &mut patches,
        };

        asm.mark("start");
        asm.emit(0x05, 0, 4); // READ_ARENA_F32(reg0, offset=4) -> X
        asm.emit(0x05, 1, 8); // READ_ARENA_F32(reg1, offset=8) -> Y
        asm.emit(0x05, 2, 24); // READ_ARENA_F32(reg2, offset=24) -> speed_x
        asm.emit(0x05, 3, 28); // READ_ARENA_F32(reg3, offset=28) -> speed_y
        asm.emit(0x02, 0, 2); // ADD_REG(reg0, reg2) -> X += speed_x
        asm.emit(0x02, 1, 3); // ADD_REG(reg1, reg3) -> Y += speed_y

        asm.emit(0x05, 4, 32); // READ_ARENA_F32(reg4, offset=32) -> min_x
        asm.emit_jmp_lt("skip_reverse_x_a", 4, 0); // if min_x < X, skip reverse
        asm.emit(0x01, 5, 0); // LOAD_REG_CONST(reg5, 0)
        asm.emit(0x01, 6, 1); // LOAD_REG_CONST(reg6, 1)
        asm.emit(0x03, 5, 6); // SUB_REG(reg5, reg6) -> reg5 = -1
        asm.emit(0x0B, 2, 5); // MUL_REG(reg2, reg5) -> speed_x = -speed_x

        asm.mark("skip_reverse_x_a");
        asm.emit(0x05, 4, 36); // READ_ARENA_F32(reg4, offset=36) -> max_x
        asm.emit_jmp_lt("skip_reverse_x_b", 0, 4); // if X < max_x, skip reverse
        asm.emit(0x01, 5, 0);
        asm.emit(0x01, 6, 1);
        asm.emit(0x03, 5, 6);
        asm.emit(0x0B, 2, 5);

        asm.mark("skip_reverse_x_b");
        asm.emit(0x05, 4, 40); // READ_ARENA_F32(reg4, offset=40) -> min_y
        asm.emit_jmp_lt("skip_reverse_y_a", 4, 1); // if min_y < Y, skip reverse
        asm.emit(0x01, 5, 0);
        asm.emit(0x01, 6, 1);
        asm.emit(0x03, 5, 6);
        asm.emit(0x0B, 3, 5); // MUL_REG(reg3, reg5) -> speed_y = -speed_y

        asm.mark("skip_reverse_y_a");
        asm.emit(0x05, 4, 44); // READ_ARENA_F32(reg4, offset=44) -> max_y
        asm.emit_jmp_lt("skip_reverse_y_b", 1, 4); // if Y < max_y, skip reverse
        asm.emit(0x01, 5, 0);
        asm.emit(0x01, 6, 1);
        asm.emit(0x03, 5, 6);
        asm.emit(0x0B, 3, 5);

        asm.mark("skip_reverse_y_b");
        asm.emit(0x04, 0, 4); // WRITE_ARENA_F32(offset=4, reg0) -> X
        asm.emit(0x04, 1, 8); // WRITE_ARENA_F32(offset=8, reg1) -> Y
        asm.emit(0x04, 2, 24); // WRITE_ARENA_F32(offset=24, reg2) -> speed_x
        asm.emit(0x04, 3, 28); // WRITE_ARENA_F32(offset=28, reg3) -> speed_y
        asm.emit(0x00, 0, 0); // HALT
    }

    // Resolve labels.
    for patch in &patches {
        let target = labels
            .get(patch.target_label)
            .copied()
            .unwrap_or_else(|| panic!("Unresolved bytecode label: {}", patch.target_label));
        let base = patch.instruction_index * 4;
        assert_eq!(insts[base], 0x08, "Unexpected opcode at patch location");
        let val = (u16::from(patch.reg2) << 8) | (u16::try_from(target & 0xFF).unwrap());
        insts[base + 2] = ((val >> 8) & 0xFF) as u8;
        insts[base + 3] = (val & 0xFF) as u8;
    }

    insts
}

fn build_msp(bytecode: &[u8]) -> Vec<u8> {
    let checksum = Sha256::digest(bytecode);
    let header = MspHeader {
        magic: *b"MLPS",
        version: 1,
        checksum: checksum.into(),
        bytecode_size: u32::try_from(bytecode.len()).unwrap(),
        entry_point: 0,
        padding: [0; 16],
    };

    let mut out = Vec::with_capacity(MSP_HEADER_SIZE + bytecode.len());
    out.extend_from_slice(msp_header_as_bytes(&header));
    out.extend_from_slice(bytecode);
    out
}

fn build_mhp(
    pack_id: &str,
    canvas_width: u16,
    canvas_height: u16,
    metrics: &[u8],
    atlas: &[u8],
    objects: &[ObjectEntry],
    msp: &[u8],
) -> Vec<u8> {
    let mut metrics_section = metrics.to_vec();
    pad16(&mut metrics_section);
    let mut atlas_section = atlas.to_vec();
    pad16(&mut atlas_section);

    // Objects table + property data pool.
    // Skins are reserved for a future skin format; in v2.5.x no skin payload is
    // emitted, so every descriptor reports skins_size == 0 and skins_offset == 0.
    let mut objects_table: Vec<u8> = Vec::new();
    let mut data_pool: Vec<u8> = Vec::new();

    for obj in objects {
        let prop_json = serde_json::to_string(&obj.properties).unwrap_or_else(|_| "{}".to_string());
        let mut prop_bytes = prop_json.into_bytes();
        pad16(&mut prop_bytes);
        let prop_offset = data_pool.len();
        data_pool.extend_from_slice(&prop_bytes);

        let descriptor = MhpObjectDescriptor {
            object_id: obj.object_id,
            properties_offset: u32::try_from(prop_offset).unwrap(),
            properties_size: u32::try_from(prop_bytes.len()).unwrap(),
            skins_offset: 0,
            skins_size: 0,
            padding: [0; 12],
        };
        objects_table.extend_from_slice(descriptor_as_bytes(&descriptor));
    }
    pad16(&mut objects_table);
    pad16(&mut data_pool);

    let font_metrics_offset = MHP_HEADER_SIZE;
    let font_atlas_offset = font_metrics_offset + metrics_section.len();
    let objects_table_offset = font_atlas_offset + atlas_section.len();
    let skins_offset = objects_table_offset + objects_table.len();
    let embedded_msp_offset = skins_offset + data_pool.len();
    let embedded_msp_size = msp.len();

    // In v2.5.x the data pool contains only object properties; the skin format
    // is reserved for a future release.  The header's skins_offset/skins_size
    // therefore describe the property data pool so existing loaders remain valid.
    let mut payload = Vec::new();
    payload.extend_from_slice(&metrics_section);
    payload.extend_from_slice(&atlas_section);
    payload.extend_from_slice(&objects_table);
    payload.extend_from_slice(&data_pool);
    payload.extend_from_slice(msp);

    let checksum = Sha256::digest(&payload);

    let mut pack_id_bytes = [0u8; 16];
    for (i, b) in pack_id.bytes().take(16).enumerate() {
        pack_id_bytes[i] = b;
    }

    let header = MhpHeader {
        magic: *b"MLPH",
        version: 1,
        total_size: u64::try_from(MHP_HEADER_SIZE + payload.len()).unwrap(),
        checksum: checksum.into(),
        pack_id: pack_id_bytes,
        canvas_width,
        canvas_height,
        font_metrics_offset: u32::try_from(font_metrics_offset).unwrap(),
        font_atlas_offset: u32::try_from(font_atlas_offset).unwrap(),
        objects_table_offset: u32::try_from(objects_table_offset).unwrap(),
        objects_table_count: u32::try_from(objects.len()).unwrap(),
        skins_offset: u32::try_from(skins_offset).unwrap(),
        skins_size: u32::try_from(data_pool.len()).unwrap(),
        has_embedded_msp: 1,
        embedded_msp_offset: u32::try_from(embedded_msp_offset).unwrap(),
        embedded_msp_size: u32::try_from(embedded_msp_size).unwrap(),
        padding: [0; 4],
    };

    let mut out = Vec::with_capacity(MHP_HEADER_SIZE + payload.len());
    out.extend_from_slice(&header_as_bytes(&header));
    out.extend_from_slice(&payload);
    out
}

/// Serialize an `MhpHeader` into its exact 112-byte on-disk representation.
///
/// Fields are written explicitly so the function never reads compiler-inserted
/// trailing padding bytes, which may be uninitialized when the struct is
/// created on the stack.
fn header_as_bytes(header: &MhpHeader) -> [u8; MHP_HEADER_SIZE] {
    let mut buf = [0u8; MHP_HEADER_SIZE];
    buf[0..4].copy_from_slice(&header.magic);
    buf[4..8].copy_from_slice(&header.version.to_le_bytes());
    buf[8..16].copy_from_slice(&header.total_size.to_le_bytes());
    buf[16..48].copy_from_slice(&header.checksum);
    buf[48..64].copy_from_slice(&header.pack_id);
    buf[64..66].copy_from_slice(&header.canvas_width.to_le_bytes());
    buf[66..68].copy_from_slice(&header.canvas_height.to_le_bytes());
    buf[68..72].copy_from_slice(&header.font_metrics_offset.to_le_bytes());
    buf[72..76].copy_from_slice(&header.font_atlas_offset.to_le_bytes());
    buf[76..80].copy_from_slice(&header.objects_table_offset.to_le_bytes());
    buf[80..84].copy_from_slice(&header.objects_table_count.to_le_bytes());
    buf[84..88].copy_from_slice(&header.skins_offset.to_le_bytes());
    buf[88..92].copy_from_slice(&header.skins_size.to_le_bytes());
    buf[92..96].copy_from_slice(&header.has_embedded_msp.to_le_bytes());
    buf[96..100].copy_from_slice(&header.embedded_msp_offset.to_le_bytes());
    buf[100..104].copy_from_slice(&header.embedded_msp_size.to_le_bytes());
    buf[104..108].copy_from_slice(&header.padding);
    // Bytes 108..112 are the struct's trailing alignment padding and are left
    // zero-initialized, matching the C-ABI layout on disk.
    buf
}

fn descriptor_as_bytes(descriptor: &MhpObjectDescriptor) -> &[u8] {
    unsafe {
        std::slice::from_raw_parts(
            std::ptr::from_ref::<MhpObjectDescriptor>(descriptor) as *const u8,
            std::mem::size_of::<MhpObjectDescriptor>(),
        )
    }
}

fn msp_header_as_bytes(header: &MspHeader) -> &[u8] {
    unsafe {
        std::slice::from_raw_parts(
            std::ptr::from_ref::<MspHeader>(header) as *const u8,
            std::mem::size_of::<MspHeader>(),
        )
    }
}

#[derive(Debug)]
struct ObjectEntry {
    object_id: u32,
    properties: serde_json::Value,
}

/// Compile a manifest.json into .mhp and .msp files next to it.
fn compile_manifest(manifest_path: &Path) -> Result<(PathBuf, PathBuf), Box<dyn Error>> {
    let manifest_dir = manifest_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));

    let manifest_text = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest '{}': {e}", manifest_path.display()))?;
    let manifest: Manifest = serde_json::from_str(&manifest_text)
        .map_err(|e| format!("invalid manifest '{}': {e}", manifest_path.display()))?;

    validate_pack_id(&manifest.pack_id)?;

    let pack_id = manifest.pack_id;
    let canvas_width = manifest.canvas_width;
    let canvas_height = manifest.canvas_height;

    let objects: Vec<ObjectEntry> = manifest
        .objects
        .into_iter()
        .map(|obj| ObjectEntry {
            object_id: obj.object_id,
            properties: obj.properties,
        })
        .collect();

    let font_path = resolve_font_path(manifest_dir)
        .ok_or_else(|| "Could not locate JetBrainsMono-Regular.ttf".to_string())?;
    let (metrics, atlas) = compile_font_atlas(&font_path)?;

    let bytecode = assemble_bouncing_script();
    let msp = build_msp(&bytecode);
    let mhp = build_mhp(
        &pack_id,
        canvas_width,
        canvas_height,
        &metrics,
        &atlas,
        &objects,
        &msp,
    );

    let mhp_path = manifest_dir.join(format!("{pack_id}.mhp"));
    let msp_path = manifest_dir.join(format!("{pack_id}.msp"));

    fs::write(&mhp_path, &mhp)?;
    fs::write(&msp_path, &msp)?;

    println!("Compiled: {}", mhp_path.display());
    println!("Compiled: {}", msp_path.display());

    Ok((mhp_path, msp_path))
}

fn decode_hex_32(s: &str) -> Result<[u8; 32], Box<dyn Error>> {
    let cleaned = s.trim().trim_start_matches("0x").trim_start_matches("0X");
    let bytes = hex::decode(cleaned)?;
    if bytes.len() != 32 {
        return Err("Invalid private key: expected 64 hex characters".into());
    }
    let mut array = [0u8; 32];
    array.copy_from_slice(&bytes);
    Ok(array)
}

fn sign_file(file_path: &Path, private_key_hex: &str) -> Result<(), Box<dyn Error>> {
    if private_key_hex.trim().is_empty() {
        return Err(format!(
            "empty signing key for '{}'; use a valid 32-byte Ed25519 seed or pass --allow-empty-key",
            file_path.display()
        )
        .into());
    }

    let seed = decode_hex_32(private_key_hex)?;
    let signing_key = SigningKey::from_bytes(&seed);

    let data = fs::read(file_path)?;
    let signature = signing_key.sign(&data);

    let sig_path = file_path.with_extension(
        file_path
            .extension()
            .and_then(|ext| ext.to_str())
            .map_or_else(|| "sig".to_string(), |ext| format!("{ext}.sig")),
    );
    fs::write(&sig_path, hex::encode(signature.to_bytes()))?;
    println!("Signature written to {}", sig_path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn header_sizes_and_alignments() {
        assert_eq!(std::mem::size_of::<MhpHeader>(), 112);
        assert_eq!(std::mem::align_of::<MhpHeader>(), 16);
        assert_eq!(std::mem::size_of::<MspHeader>(), 64);
        assert_eq!(std::mem::align_of::<MspHeader>(), 16);
        assert_eq!(std::mem::size_of::<MhpObjectDescriptor>(), 32);
        assert_eq!(std::mem::align_of::<MhpObjectDescriptor>(), 16);
    }

    #[test]
    fn assemble_bouncing_script_length_is_multiple_of_four() {
        let bytecode = assemble_bouncing_script();
        assert_eq!(bytecode.len() % 4, 0);
        assert!(!bytecode.is_empty());
    }

    #[test]
    fn compile_round_trip_produces_valid_mhp_and_msp() {
        let ws_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("malphas_cli should live inside a workspace");
        let tmp_dir = ws_root.join("target").join("malphas_cli_test_tmp");
        fs::create_dir_all(&tmp_dir).unwrap();

        let manifest_path = tmp_dir.join("manifest.json");
        let mut file = fs::File::create(&manifest_path).unwrap();
        file.write_all(
            br#"{"pack_id":"round_trip_pack","canvas_width":1000,"canvas_height":1000,"objects":[{"object_id":1,"properties":{"x":10}}]}"#,
        )
        .unwrap();
        file.flush().unwrap();
        drop(file);

        let (mhp_path, msp_path) = compile_manifest(&manifest_path).unwrap();

        assert!(mhp_path.exists());
        assert!(msp_path.exists());

        let mhp = fs::read(&mhp_path).unwrap();
        let msp = fs::read(&msp_path).unwrap();

        assert_eq!(&mhp[0..4], b"MLPH");
        assert_eq!(&msp[0..4], b"MLPS");

        // Verify MHP checksum over payload.
        let payload = &mhp[MHP_HEADER_SIZE..];
        let expected = Sha256::digest(payload);
        assert_eq!(&mhp[16..48], expected.as_slice());

        // Verify MSP checksum over bytecode.
        let bytecode = &msp[MSP_HEADER_SIZE..];
        let expected_msp = Sha256::digest(bytecode);
        assert_eq!(&msp[8..40], expected_msp.as_slice());

        // Tidy up.
        let _ = fs::remove_file(&mhp_path);
        let _ = fs::remove_file(&msp_path);
        let _ = fs::remove_file(&manifest_path);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn sign_command_writes_verifiable_signature() {
        use ed25519_dalek::{Verifier, VerifyingKey};
        use rand_core::OsRng;

        let ws_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("malphas_cli should live inside a workspace");
        let tmp_dir = ws_root.join("target").join("malphas_cli_test_tmp");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN TEST").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);
        let private_key_hex = hex::encode(signing_key.to_bytes());

        sign_file(&data_path, &private_key_hex).unwrap();

        let sig_path = data_path.with_extension("bin.sig");
        assert!(sig_path.exists());

        let sig_hex = fs::read_to_string(&sig_path).unwrap();
        let sig_bytes = hex::decode(sig_hex.trim()).unwrap();
        let signature = ed25519_dalek::Signature::from_slice(&sig_bytes).unwrap();

        let verifying_key =
            VerifyingKey::from_bytes(&signing_key.verifying_key().to_bytes()).unwrap();
        let data = fs::read(&data_path).unwrap();
        assert!(verifying_key.verify(&data, &signature).is_ok());

        // 0x prefix must also be accepted.
        let data_path_0x = tmp_dir.join("payload_0x.bin");
        fs::write(&data_path_0x, b"MALPHAS CLI SIGN TEST 0X").unwrap();
        sign_file(&data_path_0x, &format!("0x{private_key_hex}")).unwrap();
        let sig_path_0x = data_path_0x.with_extension("bin.sig");
        assert!(sig_path_0x.exists());

        // Empty key must be rejected.
        let empty_result = sign_file(&data_path, "");
        assert!(empty_result.is_err());

        // Tidy up.
        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_file(&sig_path);
        let _ = fs::remove_file(&data_path_0x);
        let _ = fs::remove_file(&sig_path_0x);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn compile_font_atlas_produces_a8_atlas_and_metrics() {
        let ws_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("malphas_cli should live inside a workspace");
        let font_path = ws_root
            .join("flutter_app")
            .join("assets")
            .join("fonts")
            .join("JetBrainsMono-Regular.ttf");

        let (metrics, atlas) = compile_font_atlas(&font_path).unwrap();

        assert_eq!(atlas.len(), FONT_ATLAS_SIZE);
        assert_eq!(metrics.len(), FONT_METRICS_SIZE);

        // The atlas is mostly zero (empty cells) but common glyphs should be
        // non-zero somewhere inside their 32x32 cell.
        let max_in_cell = |code: u16| {
            let cx = (code as usize % 16) * CELL_SIZE;
            let cy = (code as usize / 16) * CELL_SIZE;
            let mut max = 0u8;
            for y in cy..cy + CELL_SIZE {
                for x in cx..cx + CELL_SIZE {
                    max = max.max(atlas[y * FONT_ATLAS_WIDTH + x]);
                }
            }
            max
        };
        assert!(
            max_in_cell(0x41) > 0,
            "glyph 'A' should render non-zero alpha"
        );
        assert!(
            max_in_cell(0x30) > 0,
            "glyph '0' should render non-zero alpha"
        );
    }

    #[test]
    fn compile_manifest_rejects_invalid_manifests() {
        let ws_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("malphas_cli should live inside a workspace");
        let tmp_dir = ws_root.join("target").join("malphas_cli_test_invalid");
        fs::create_dir_all(&tmp_dir).unwrap();

        let unknown_field = tmp_dir.join("unknown.json");
        fs::write(
            &unknown_field,
            br#"{"pack_id":"x","canvas_width":1,"canvas_height":1,"objects":[],"extra":true}"#,
        )
        .unwrap();
        let err = compile_manifest(&unknown_field).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("unknown field") || msg.contains("invalid manifest"),
            "unexpected error: {msg}"
        );

        let missing_field = tmp_dir.join("missing.json");
        fs::write(&missing_field, br#"{"pack_id":"x","canvas_width":1}"#).unwrap();
        let err = compile_manifest(&missing_field).unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("missing field") || msg.contains("invalid manifest"),
            "unexpected error: {msg}"
        );

        // Tidy up.
        let _ = fs::remove_file(&unknown_field);
        let _ = fs::remove_file(&missing_field);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn validate_pack_id_accepts_valid_ids() {
        assert!(validate_pack_id("bouncing_demo").is_ok());
        assert!(validate_pack_id("A1_-").is_ok());
        assert!(validate_pack_id("1234567890123456").is_ok());
    }

    #[test]
    fn validate_pack_id_rejects_invalid_ids() {
        assert!(validate_pack_id("").is_err());
        assert!(validate_pack_id("12345678901234567").is_err());
        assert!(validate_pack_id("../evil").is_err());
        assert!(validate_pack_id("foo/bar").is_err());
        assert!(validate_pack_id("foo\\bar").is_err());
        assert!(validate_pack_id("foo.bar").is_err());
        assert!(validate_pack_id("foo bar").is_err());
    }

    #[test]
    fn mhp_header_serialization_is_exactly_112_bytes_and_zero_padded() {
        let header = MhpHeader {
            magic: *b"MLPH",
            version: 0,
            total_size: 0,
            checksum: [0; 32],
            pack_id: [0; 16],
            canvas_width: 0,
            canvas_height: 0,
            font_metrics_offset: 0,
            font_atlas_offset: 0,
            objects_table_offset: 0,
            objects_table_count: 0,
            skins_offset: 0,
            skins_size: 0,
            has_embedded_msp: 0,
            embedded_msp_offset: 0,
            embedded_msp_size: 0,
            padding: [0; 4],
        };
        let bytes = header_as_bytes(&header);
        assert_eq!(bytes.len(), MHP_HEADER_SIZE);
        assert_eq!(MHP_HEADER_SIZE, 112);
        assert_eq!(&bytes[0..4], b"MLPH");
        assert!(bytes[4..].iter().all(|&b| b == 0));
    }
}
