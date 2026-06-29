//! End-to-end integration test for the Malphas FFI core.
//!
//! Exercises the full lifecycle: init → load pack → set entities →
//! trigger pulse → shutdown, verifying that the engine produces render
//! commands and cleans up its background thread.

use std::ffi::c_void;
use std::sync::atomic::Ordering;

use sha2::{Digest, Sha256};

#[repr(C, align(16))]
struct CoreCommandBuffer {
    command_count: std::sync::atomic::AtomicU32,
    commands: *mut malphas_core::pipeline::DartRenderCommand,
}

#[repr(C, align(16))]
struct MalphasDoubleBufferBridge {
    buffer_a: CoreCommandBuffer,
    buffer_b: CoreCommandBuffer,
    atomic_back_index: std::sync::atomic::AtomicU8,
    commands_written: std::sync::atomic::AtomicU32,
}

fn build_msp_package(bytecode: &[u8]) -> Vec<u8> {
    let mut package = Vec::new();
    // Magic: MLPS
    package.extend_from_slice(b"MLPS");
    // version
    package.extend_from_slice(&1u32.to_le_bytes());
    // checksum (SHA256 of bytecode)
    let mut hasher = Sha256::new();
    hasher.update(bytecode);
    package.extend_from_slice(&hasher.finalize());
    // bytecode_size
    package.extend_from_slice(&(bytecode.len() as u32).to_le_bytes());
    // entry_point
    package.extend_from_slice(&0u32.to_le_bytes());
    // padding
    package.extend_from_slice(&[0u8; 16]);
    // bytecode payload
    package.extend_from_slice(bytecode);
    package
}

#[test]
fn end_to_end_init_load_entities_pulse_shutdown() {
    let mut bridge = MalphasDoubleBufferBridge {
        buffer_a: CoreCommandBuffer {
            command_count: std::sync::atomic::AtomicU32::new(0),
            commands: std::ptr::null_mut(),
        },
        buffer_b: CoreCommandBuffer {
            command_count: std::sync::atomic::AtomicU32::new(0),
            commands: std::ptr::null_mut(),
        },
        atomic_back_index: std::sync::atomic::AtomicU8::new(0),
        commands_written: std::sync::atomic::AtomicU32::new(0),
    };

    let mut arena = vec![0u8; 8 * 1024 * 1024];
    let command_capacity = 2048usize;
    let command_buffer_size =
        command_capacity * std::mem::size_of::<malphas_core::pipeline::DartRenderCommand>();

    let commands_a = unsafe {
        std::alloc::alloc(std::alloc::Layout::from_size_align(command_buffer_size, 16).unwrap())
            as *mut malphas_core::pipeline::DartRenderCommand
    };
    let commands_b = unsafe {
        std::alloc::alloc(std::alloc::Layout::from_size_align(command_buffer_size, 16).unwrap())
            as *mut malphas_core::pipeline::DartRenderCommand
    };

    assert!(!commands_a.is_null());
    assert!(!commands_b.is_null());

    bridge.buffer_a.commands = commands_a;
    bridge.buffer_b.commands = commands_b;

    let bridge_ptr = &mut bridge as *mut MalphasDoubleBufferBridge as *mut c_void;
    let arena_ptr = arena.as_mut_ptr() as *mut c_void;

    // 1. init
    let init_result =
        malphas_core::init_engine(bridge_ptr as *mut _, arena_ptr, arena.len() as u32, 2048);
    assert_eq!(init_result, 0, "init_engine must succeed");

    // Give the background thread a moment to start before pulsing.
    std::thread::sleep(std::time::Duration::from_millis(20));

    // 2. Load a minimal MSP package.
    let bytecode = [0x00, 0x00, 0x00, 0x00]; // HALT
    let package = build_msp_package(&bytecode);
    let load_result = malphas_core::load_resource_pack_raw(package.as_ptr(), package.len() as u32);
    assert_eq!(load_result, 0, "load_resource_pack_raw must succeed");

    // 3. Set entities: one rectangle, one text.
    assert_eq!(malphas_core::set_entities_count(2), 0);

    assert_eq!(
        malphas_core::set_entity(
            0, 1, 0, 50.0, 50.0, 100.0, 100.0, 0xFF112233, 1.0, 1.0, 0.0, 500.0, 0.0, 500.0, 0
        ),
        0
    );

    // Write a TextPayload at offset 8192 and configure entity 1 as text.
    let text_offset = 8192u32;
    let text_bytes = b"Malphas\0";
    let payload_size = std::mem::size_of::<malphas_core::pipeline::TextPayload>();
    let mut payload_buffer = vec![0u8; payload_size + text_bytes.len()];
    payload_buffer[payload_size..].copy_from_slice(text_bytes);
    assert_eq!(
        malphas_core::write_arena_bytes(
            text_offset,
            payload_buffer.as_ptr(),
            payload_buffer.len() as u32
        ),
        0
    );

    assert_eq!(
        malphas_core::set_entity(
            1,
            2,
            1,
            100.0,
            100.0,
            24.0,
            0.0,
            0xFFFFFFFF,
            0.0,
            0.0,
            0.0,
            1000.0,
            0.0,
            1000.0,
            text_offset
        ),
        0
    );

    // 4. Pulse the engine and wait for commands to be generated.
    assert_eq!(malphas_core::trigger_engine_pulse(), 0);

    let mut command_count = 0u32;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while command_count < 2 {
        assert!(
            std::time::Instant::now() < deadline,
            "engine did not produce both commands in time"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
        command_count = bridge.commands_written.load(Ordering::Acquire);
    }

    assert!(
        command_count >= 2,
        "expected at least 2 commands, got {}",
        command_count
    );

    // 5. Shutdown.
    assert_eq!(malphas_core::shutdown_engine(), 0);

    // Clean up command buffers.
    unsafe {
        std::alloc::dealloc(
            commands_a as *mut u8,
            std::alloc::Layout::from_size_align(command_buffer_size, 16).unwrap(),
        );
        std::alloc::dealloc(
            commands_b as *mut u8,
            std::alloc::Layout::from_size_align(command_buffer_size, 16).unwrap(),
        );
    }
}
