//! Security-focused integration tests for Malphas v2.7.5.
//!
//! Covers signature enforcement and sandbox path validation for `.msp` and `.mxc`.

use std::io::Write;

use ed25519_dalek::{Signer, SigningKey};
use malphas_core::msp_loader::{
    compute_msp_checksum, MspEntityDescriptor, MspHeader, ERROR_PAYLOAD_RESERVE, MSP_MAGIC,
    MSP_VERSION,
};
use rand_core::OsRng;
use sha2::{Digest, Sha256};

const ERR_MSP_SIGNATURE_MISSING: i32 = -120;
const ERR_MSP_SIGNATURE_INVALID: i32 = -121;
const ERR_SYSTEM_SANDBOX: i32 = -210;
const ERR_SYSTEM_SIGNATURE_MISSING: i32 = -211;
const ERR_SYSTEM_SIGNATURE_INVALID: i32 = -212;

#[repr(C, align(64))]
#[derive(Clone, Copy)]
struct EntityPayload {
    tag_mask: u64,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    speed_x: f32,
    speed_y: f32,
    color_rgba: u32,
    flags: u32,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
}

fn system_library_path() -> std::path::PathBuf {
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let workspace_root = manifest_dir
        .parent()
        .expect("malphas_core inside workspace");
    let profile = if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    };
    let target_dir = workspace_root.join("target").join(profile);

    #[cfg(target_os = "windows")]
    {
        target_dir.join("bouncing_demo.dll")
    }
    #[cfg(target_os = "linux")]
    {
        target_dir.join("libbouncing_demo.so")
    }
    #[cfg(target_os = "macos")]
    {
        target_dir.join("libbouncing_demo.dylib")
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        panic!("unsupported target OS for security tests");
    }
}

fn ensure_system_built() -> std::path::PathBuf {
    let path = system_library_path();
    if !path.exists() {
        let status = std::process::Command::new("cargo")
            .args(["build", "-p", "bouncing_demo", "--release"])
            .status()
            .expect("failed to build bouncing_demo");
        assert!(status.success(), "failed to build bouncing_demo");
    }
    assert!(
        path.exists(),
        "bouncing_demo library not found at {}",
        path.display()
    );
    path
}

fn build_test_msp(path: &std::path::Path) {
    let header_size = std::mem::size_of::<MspHeader>();
    let descriptor_size = std::mem::size_of::<MspEntityDescriptor>();

    let entity_table_offset = header_size;
    let payload_section_offset = entity_table_offset + descriptor_size;

    let payload = EntityPayload {
        tag_mask: 1,
        x: 50.0,
        y: 50.0,
        width: 100.0,
        height: 100.0,
        speed_x: 2.0,
        speed_y: 1.5,
        color_rgba: 0xFF112233,
        flags: 0,
        min_x: 0.0,
        max_x: 500.0,
        min_y: 0.0,
        max_y: 500.0,
    };

    let payload_bytes = unsafe {
        std::slice::from_raw_parts(
            &payload as *const EntityPayload as *const u8,
            std::mem::size_of::<EntityPayload>(),
        )
    };

    let mut payload_section = payload_bytes.to_vec();
    payload_section.resize(payload_section.len() + ERROR_PAYLOAD_RESERVE, 0);
    let rem = payload_section.len() % 64;
    if rem != 0 {
        payload_section.resize(payload_section.len() + (64 - rem), 0);
    }

    let descriptor = MspEntityDescriptor {
        entity_id: 0,
        tag_mask: 1,
        payload_offset: 0,
        payload_size: payload_bytes.len() as u32,
        _padding: [0; 40],
    };

    let mut file = std::fs::File::create(path).unwrap();

    let checksum = compute_msp_checksum(
        &[
            descriptor_as_bytes(&descriptor).as_slice(),
            payload_section.as_slice(),
        ]
        .concat(),
    );
    let header = MspHeader {
        magic: MSP_MAGIC,
        version: MSP_VERSION,
        entity_table_offset: entity_table_offset as u32,
        entity_count: 1,
        payload_section_offset: payload_section_offset as u32,
        payload_section_size: payload_section.len() as u32,
        checksum,
        _padding: [0; 32],
    };
    file.write_all(&header_as_bytes(&header)).unwrap();

    let mut body = vec![0u8; payload_section_offset - header_size];
    body[..descriptor_size].copy_from_slice(&descriptor_as_bytes(&descriptor));
    body.extend_from_slice(&payload_section);
    file.write_all(&body).unwrap();
    file.flush().unwrap();
}

fn header_as_bytes(header: &MspHeader) -> [u8; 64] {
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

fn descriptor_as_bytes(descriptor: &MspEntityDescriptor) -> [u8; 64] {
    let mut buf = [0u8; 64];
    buf[0..4].copy_from_slice(&descriptor.entity_id.to_le_bytes());
    buf[8..16].copy_from_slice(&descriptor.tag_mask.to_le_bytes());
    buf[16..20].copy_from_slice(&descriptor.payload_offset.to_le_bytes());
    buf[20..24].copy_from_slice(&descriptor.payload_size.to_le_bytes());
    buf[24..64].copy_from_slice(&descriptor._padding);
    buf
}

fn sign_file(path: &std::path::Path, signing_key: &SigningKey) {
    let data = std::fs::read(path).unwrap();
    let hash = Sha256::digest(&data);
    let signature = signing_key.sign(&hash);
    let sig_path = path.with_extension(
        path.extension()
            .and_then(|e| e.to_str())
            .map_or_else(|| "sig".to_string(), |e| format!("{e}.sig")),
    );
    let _ = std::fs::remove_file(&sig_path);
    std::fs::write(sig_path, hex::encode(signature.to_bytes())).unwrap();
}

fn c_string(s: &str) -> std::ffi::CString {
    std::ffi::CString::new(s).unwrap()
}

/// A unique temp working directory with an approved `systems/` root.
fn make_sandbox_workdir(label: &str) -> (std::path::PathBuf, std::path::PathBuf) {
    let work_dir = std::env::temp_dir().join(format!(
        "malphas_security_{}_{}_{}",
        label,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let systems_dir = work_dir.join("systems");
    std::fs::create_dir_all(&systems_dir).unwrap();
    (work_dir, systems_dir)
}

fn load_system_in_sandbox(rel_path: &std::path::Path, work_dir: &std::path::Path) -> i32 {
    // Use an absolute path so tests stay thread-safe and do not race on the
    // process current working directory.
    let absolute = work_dir.join(rel_path);
    malphas_core::load_system(c_string(absolute.to_str().unwrap()).as_ptr())
}

#[test]
fn reject_unsigned_msp() {
    let msp_path =
        std::env::temp_dir().join(format!("malphas_sec_unsigned_{}.msp", std::process::id()));
    build_test_msp(&msp_path);

    let result = malphas_core::load_msp(c_string(msp_path.to_str().unwrap()).as_ptr());
    assert_eq!(result, ERR_MSP_SIGNATURE_MISSING);
}

#[test]
fn reject_msp_with_malformed_signature() {
    let msp_path =
        std::env::temp_dir().join(format!("malphas_sec_bad_sig_{}.msp", std::process::id()));
    build_test_msp(&msp_path);
    std::fs::write(msp_path.with_extension("msp.sig"), "0".repeat(128)).unwrap();

    let result = malphas_core::load_msp(c_string(msp_path.to_str().unwrap()).as_ptr());
    assert_eq!(result, ERR_MSP_SIGNATURE_INVALID);
}

#[test]
fn reject_msp_signed_with_wrong_key() {
    let msp_path =
        std::env::temp_dir().join(format!("malphas_sec_wrong_key_{}.msp", std::process::id()));
    build_test_msp(&msp_path);

    let wrong_key = SigningKey::generate(&mut OsRng);
    sign_file(&msp_path, &wrong_key);

    let result = malphas_core::load_msp(c_string(msp_path.to_str().unwrap()).as_ptr());
    assert_eq!(result, ERR_MSP_SIGNATURE_INVALID);
}

#[test]
fn reject_system_outside_sandbox() {
    let lib_path = ensure_system_built();

    let result = malphas_core::load_system(c_string(lib_path.to_str().unwrap()).as_ptr());
    assert_eq!(result, ERR_SYSTEM_SANDBOX);

    let traversal = std::env::temp_dir()
        .join("systems")
        .join("..")
        .join("evil.dll");
    let result = malphas_core::load_system(c_string(traversal.to_str().unwrap()).as_ptr());
    assert_eq!(result, ERR_SYSTEM_SANDBOX);
}

#[test]
fn reject_unsigned_system() {
    let lib_path = ensure_system_built();
    let (work_dir, systems_dir) = make_sandbox_workdir("unsigned");
    let sandboxed = systems_dir.join(lib_path.file_name().unwrap());
    let _ = std::fs::remove_file(&sandboxed);
    let _ = std::fs::remove_file(
        sandboxed.with_extension(
            sandboxed
                .extension()
                .and_then(|e| e.to_str())
                .map_or_else(|| "sig".to_string(), |e| format!("{e}.sig")),
        ),
    );
    std::fs::copy(&lib_path, &sandboxed).unwrap();

    let rel_path = sandboxed.strip_prefix(&work_dir).unwrap();
    let result = load_system_in_sandbox(rel_path, &work_dir);
    assert_eq!(result, ERR_SYSTEM_SIGNATURE_MISSING);
}

#[test]
fn reject_system_signed_with_wrong_key() {
    let lib_path = ensure_system_built();
    let (work_dir, systems_dir) = make_sandbox_workdir("wrong_key");
    let sandboxed = systems_dir.join(lib_path.file_name().unwrap());
    std::fs::copy(&lib_path, &sandboxed).unwrap();

    let wrong_key = SigningKey::generate(&mut OsRng);
    sign_file(&sandboxed, &wrong_key);

    let rel_path = sandboxed.strip_prefix(&work_dir).unwrap();
    let result = load_system_in_sandbox(rel_path, &work_dir);
    assert_eq!(result, ERR_SYSTEM_SIGNATURE_INVALID);
}
