//! End-to-end integration test for the Malphas FFI core v3.0.0.
//!
//! Exercises the full lifecycle: init → load MSP → load signed bouncing_demo.mxc →
//! trigger pulse → shutdown, verifying that the system produces render
//! commands and cleans up its background thread.

use std::io::Write;
use std::sync::atomic::Ordering;

use ed25519_dalek::{Signer, SigningKey};
use malphas_core::msp_loader::{
    compute_msp_sha256, MspEntityDescriptor, MspHeader, ERROR_PAYLOAD_RESERVE, MSP_MAGIC,
    MSP_VERSION,
};
use rand_core::OsRng;
use sha2::{Digest, Sha256};

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

#[repr(C, align(64))]
#[allow(dead_code)]
struct MalphasDoubleBufferBridge {
    buffer_a_command_count: std::sync::atomic::AtomicU32,
    abi_version: u32,
    buffer_a_commands: *mut malphas_core::pipeline::DartRenderCommand,
    buffer_b_command_count: std::sync::atomic::AtomicU32,
    _padding1: u32,
    buffer_b_commands: *mut malphas_core::pipeline::DartRenderCommand,
    atomic_back_index: std::sync::atomic::AtomicU8,
    _padding2: u8,
    _padding3: u8,
    _padding4: u8,
    commands_written: std::sync::atomic::AtomicU32,
    _padding5: u32,
    _padding6: u32,
    _padding7: u64,
    _padding8: u64,
}

fn workspace_root() -> std::path::PathBuf {
    let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .expect("malphas_core inside workspace")
        .to_path_buf()
}

fn system_library_path() -> std::path::PathBuf {
    let workspace_root = workspace_root();
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
        panic!("unsupported target OS for integration test");
    }
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
        payload_type_id: malphas_core::payload_schema::PAYLOAD_TYPE_PHYSICS_BODY,
        tag_mask: 1,
        payload_offset: 0,
        payload_size: payload_bytes.len() as u32,
        _padding: [0; 40],
    };

    let mut file = std::fs::File::create(path).unwrap();

    let checksum = compute_msp_sha256(
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
        _padding: [0; 8],
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
    buf[24..56].copy_from_slice(&header.checksum);
    buf[56..64].copy_from_slice(&header._padding);
    buf
}

fn descriptor_as_bytes(descriptor: &MspEntityDescriptor) -> [u8; 64] {
    let mut buf = [0u8; 64];
    buf[0..4].copy_from_slice(&descriptor.entity_id.to_le_bytes());
    buf[4..8].copy_from_slice(&descriptor.payload_type_id.to_le_bytes());
    buf[8..16].copy_from_slice(&descriptor.tag_mask.to_le_bytes());
    buf[16..20].copy_from_slice(&descriptor.payload_offset.to_le_bytes());
    buf[20..24].copy_from_slice(&descriptor.payload_size.to_le_bytes());
    buf[24..64].copy_from_slice(&descriptor._padding);
    buf
}

#[test]
fn end_to_end_init_load_msp_system_pulse_shutdown() {
    let system_path = system_library_path();
    if !system_path.exists() {
        // Build the system cdylib on demand for the integration test.
        let profile = if cfg!(debug_assertions) {
            "dev"
        } else {
            "release"
        };
        let status = std::process::Command::new("cargo")
            .args(["build", "-p", "bouncing_demo", "--profile", profile])
            .status()
            .expect("failed to spawn cargo build for bouncing_demo");
        assert!(
            status.success(),
            "failed to build bouncing_demo system library"
        );
    }
    assert!(
        system_path.exists(),
        "bouncing_demo system library not found at {} after build",
        system_path.display()
    );

    // 1. init: Rust allocates and owns the bridge and command buffers.
    let bridge_ptr = malphas_core::init_engine(2048);
    assert!(!bridge_ptr.is_null(), "init_engine must succeed");
    let bridge = unsafe { &*bridge_ptr };

    std::thread::sleep(std::time::Duration::from_millis(20));

    // 2. Build and sign a minimal MSP package with an on-the-fly trust anchor.
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();
    malphas_core::set_global_trust_anchor(&hex::encode(verifying_key.to_bytes()))
        .expect("test trust anchor must be valid");

    let msp_path =
        std::env::temp_dir().join(format!("malphas_integration_{}.msp", std::process::id()));
    build_test_msp(&msp_path);

    let msp_bytes = std::fs::read(&msp_path).unwrap();
    let msp_hash = Sha256::digest(&msp_bytes);
    let msp_signature = signing_key.sign(&msp_hash);
    std::fs::write(
        msp_path.with_extension("msp.sig"),
        hex::encode(msp_signature.to_bytes()),
    )
    .unwrap();

    let load_result = malphas_core::load_msp(
        std::ffi::CString::new(msp_path.to_str().unwrap())
            .unwrap()
            .as_ptr(),
    );
    assert_eq!(load_result, 0, "load_msp must succeed");

    // 3. Install the system binary under an approved sandbox root inside the
    // canonical workspace.
    let workspace = workspace_root();
    let systems_root = workspace.join("systems");
    std::fs::create_dir_all(&systems_root).unwrap();
    let work_dir = systems_root.join(format!("_malphas_integration_{}", std::process::id()));
    std::fs::create_dir_all(&work_dir).unwrap();

    let system_file_name = system_path.file_name().unwrap();
    let sandboxed_system = work_dir.join(system_file_name);
    std::fs::copy(&system_path, &sandboxed_system).unwrap();

    let system_bytes = std::fs::read(&sandboxed_system).unwrap();
    let system_hash = Sha256::digest(&system_bytes);
    let signature = signing_key.sign(&system_hash);
    std::fs::write(
        sandboxed_system.with_extension(
            sandboxed_system
                .extension()
                .and_then(|e| e.to_str())
                .map_or_else(|| "sig".to_string(), |e| format!("{e}.sig")),
        ),
        hex::encode(signature.to_bytes()),
    )
    .unwrap();

    let system_result = malphas_core::load_system(
        std::ffi::CString::new(sandboxed_system.to_str().unwrap())
            .unwrap()
            .as_ptr(),
    );
    assert_eq!(system_result, 0, "load_system must succeed");
    assert_eq!(malphas_core::get_loaded_system_count(), 1);

    // 4. Pulse the engine and wait for commands to be generated.
    assert_eq!(malphas_core::trigger_engine_pulse(), 0);

    let mut command_count = 0u32;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while command_count < 1 {
        assert!(
            std::time::Instant::now() < deadline,
            "engine did not produce a command in time"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
        command_count = bridge.commands_written.load(Ordering::Acquire);
    }

    assert!(
        command_count >= 1,
        "expected at least 1 command, got {}",
        command_count
    );

    // 5. Verify the command looks like the bouncing rectangle.
    let back_index = bridge.atomic_back_index.load(Ordering::Acquire);
    let front_index = 1 - back_index;
    let front_commands = if front_index == 0 {
        bridge.buffer_a_commands
    } else {
        bridge.buffer_b_commands
    };
    let front_count = if front_index == 0 {
        bridge.buffer_a_command_count.load(Ordering::Acquire)
    } else {
        bridge.buffer_b_command_count.load(Ordering::Acquire)
    };
    assert!(front_count >= 1);
    let cmd = unsafe { &*front_commands };
    assert_eq!(cmd.cmd_type, 1);
    assert_eq!(cmd.color, 0xFF112233);

    // 6. Shutdown: Rust frees the bridge and command buffers.
    assert_eq!(malphas_core::shutdown_engine(), 0);

    let _ = std::fs::remove_file(&msp_path);
    let _ = std::fs::remove_file(msp_path.with_extension("msp.sig"));
    let _ = std::fs::remove_dir_all(&work_dir);
}
