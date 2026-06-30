// Malphas Core v2.9.0 - Data-Oriented Design memory router.
//
// This crate is a C-ABI boundary; pointer arguments are validated inside each
// function before they are dereferenced, so the not_unsafe_ptr_arg_deref lint
// is not useful here.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod bridge;
pub mod crypto;
pub mod input;
pub mod msp_loader;
pub mod pipeline;
pub mod system_host;

mod integrity_policy;

pub use integrity_policy::set_global_trust_anchor;
use integrity_policy::IntegrityError;

use std::os::raw::c_char;

use crate::bridge::{
    get_back_index as get_back_index_internal,
    get_buffer_a_command_count as get_buffer_a_command_count_internal,
    get_buffer_a_commands as get_buffer_a_commands_internal,
    get_buffer_b_command_count as get_buffer_b_command_count_internal,
    get_buffer_b_commands as get_buffer_b_commands_internal,
    get_commands_written as get_commands_written_internal,
    get_front_buffer_snapshot as get_front_buffer_snapshot_internal,
    get_text_payload_pointer as get_text_payload_pointer_internal, init_engine_internal,
    malphas_alloc as malphas_alloc_internal, malphas_free as malphas_free_internal,
    pause_engine_internal, shutdown_engine_internal, trigger_engine_pulse_internal,
};
use crate::crypto::{
    extract_zip_package as extract_zip_package_internal,
    verify_binary_integrity as verify_binary_integrity_internal,
    verify_engine_signature as verify_engine_signature_internal,
};
use crate::input::process_input_event as process_input_event_internal;
use crate::msp_loader::{
    get_msp_entity_count_internal, get_msp_lookup_table_internal,
    load_msp_file as load_msp_file_internal, refresh_msp_file as refresh_msp_file_internal,
};
use crate::pipeline::{
    get_commands_generated_count_internal, get_pulse_latency_micros_internal,
    get_vm_tick_micros_internal, DartRenderCommand, MalphasDoubleBufferBridge, TextPayload,
};
use crate::system_host::{
    get_loaded_system_count_internal, load_system_file as load_system_file_internal,
    tick_loaded_systems as tick_loaded_systems_internal,
};

// ---------------------------------------------------------------------------
// Engine lifecycle.
// ---------------------------------------------------------------------------
/// Initialise the engine and return a pointer to the Rust-owned bridge.
///
/// The returned pointer must be treated as read-only by Dart and must remain
/// valid until `shutdown_engine` returns.  Rust allocates and frees the bridge
/// and command buffers.
#[no_mangle]
pub extern "C" fn init_engine(max_commands: u32) -> *mut MalphasDoubleBufferBridge {
    init_engine_internal(max_commands)
}

#[no_mangle]
pub extern "C" fn set_trust_anchor(public_key_hex: *const c_char) -> i32 {
    let hex = match crypto::c_str_to_str(public_key_hex) {
        Some(s) => s,
        None => return -1,
    };
    match set_global_trust_anchor(hex) {
        Ok(()) => 0,
        Err(IntegrityError::HexDecode(_)) => -2,
        Err(IntegrityError::InvalidPublicKeyLength { .. }) => -3,
        Err(IntegrityError::SignatureInvalid) => -4,
        Err(_) => -5,
    }
}

#[no_mangle]
pub extern "C" fn shutdown_engine() -> i32 {
    shutdown_engine_internal()
}

#[no_mangle]
pub extern "C" fn pause_engine(paused: i32) -> i32 {
    pause_engine_internal(paused)
}

#[no_mangle]
pub extern "C" fn trigger_engine_pulse() -> i32 {
    trigger_engine_pulse_internal()
}

// ---------------------------------------------------------------------------
// MSP (Malphas Source Pack) loading.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn load_msp(filepath: *const c_char) -> i32 {
    load_msp_file_internal(filepath)
}

#[no_mangle]
pub extern "C" fn refresh_msp(filepath: *const c_char) -> i32 {
    refresh_msp_file_internal(filepath)
}

#[no_mangle]
pub extern "C" fn get_msp_lookup_table() -> *const *const u8 {
    get_msp_lookup_table_internal()
}

#[no_mangle]
pub extern "C" fn get_msp_entity_count() -> u32 {
    get_msp_entity_count_internal()
}

// ---------------------------------------------------------------------------
// System (.mxc) loading and tick dispatch.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn load_system(filepath: *const c_char) -> i32 {
    load_system_file_internal(filepath)
}

#[no_mangle]
pub extern "C" fn get_loaded_system_count() -> u32 {
    get_loaded_system_count_internal()
}

#[no_mangle]
pub extern "C" fn tick_systems(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
) {
    tick_loaded_systems_internal(
        lookup_table,
        entity_count,
        dt_micros,
        render_buffer,
        render_capacity,
        render_count,
    );
}

// ---------------------------------------------------------------------------
// Input event queue.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn process_input_event(event_type: i32, x: f32, y: f32) -> i32 {
    process_input_event_internal(event_type, x, y)
}

// ---------------------------------------------------------------------------
// Portable FFI pointer delegates.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn get_buffer_a_commands(
    bridge: *mut MalphasDoubleBufferBridge,
) -> *mut DartRenderCommand {
    get_buffer_a_commands_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_buffer_b_commands(
    bridge: *mut MalphasDoubleBufferBridge,
) -> *mut DartRenderCommand {
    get_buffer_b_commands_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_buffer_a_command_count(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    get_buffer_a_command_count_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_buffer_b_command_count(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    get_buffer_b_command_count_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_back_index(bridge: *mut MalphasDoubleBufferBridge) -> u8 {
    get_back_index_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_commands_written(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    get_commands_written_internal(bridge)
}

/// Returns a consistent snapshot of the front render-command buffer.
///
/// `out_front_index` and `out_front_count` are optional out-parameters; pass
/// null if they are not needed.  The returned pointer is the front command
/// buffer and remains valid for the lifetime of the bridge.
#[no_mangle]
pub extern "C" fn get_front_buffer_snapshot(
    bridge: *mut MalphasDoubleBufferBridge,
    out_front_index: *mut u8,
    out_front_count: *mut u32,
) -> *mut DartRenderCommand {
    let (front_index, front_count, ptr) = get_front_buffer_snapshot_internal(bridge);
    if !out_front_index.is_null() {
        // SAFETY: `out_front_index` is non-null and owned by the caller.
        unsafe {
            *out_front_index = front_index;
        }
    }
    if !out_front_count.is_null() {
        // SAFETY: `out_front_count` is non-null and owned by the caller.
        unsafe {
            *out_front_count = front_count;
        }
    }
    ptr
}

#[no_mangle]
pub extern "C" fn get_text_payload_pointer(
    command: *const DartRenderCommand,
) -> *const TextPayload {
    get_text_payload_pointer_internal(command)
}

// ---------------------------------------------------------------------------
// Telemetry getters.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn get_vm_tick_micros() -> u64 {
    get_vm_tick_micros_internal()
}

#[no_mangle]
pub extern "C" fn get_pulse_latency_micros() -> u64 {
    get_pulse_latency_micros_internal()
}

#[no_mangle]
pub extern "C" fn get_commands_generated_count() -> u64 {
    get_commands_generated_count_internal()
}

// ---------------------------------------------------------------------------
// Aligned native allocator exposed to Dart.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn malphas_alloc(size: usize) -> *mut u8 {
    malphas_alloc_internal(size)
}

#[no_mangle]
pub extern "C" fn malphas_free(ptr: *mut u8, size: usize) {
    malphas_free_internal(ptr, size)
}

// ---------------------------------------------------------------------------
// Binary integrity, signature verification, and package extraction.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn verify_binary_integrity(
    filepath: *const c_char,
    expected_sha: *const c_char,
) -> i32 {
    verify_binary_integrity_internal(filepath, expected_sha)
}

#[no_mangle]
pub extern "C" fn verify_engine_signature(
    filepath: *const c_char,
    signature_hex: *const c_char,
    public_key_hex: *const c_char,
) -> i32 {
    verify_engine_signature_internal(filepath, signature_hex, public_key_hex)
}

#[no_mangle]
pub extern "C" fn extract_zip_package(zip_path: *const c_char, output_dir: *const c_char) -> i32 {
    extract_zip_package_internal(zip_path, output_dir)
}

// ---------------------------------------------------------------------------
// Synchronous tick fallback.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn process_engine_tick(dt_micros: u64) -> i32 {
    crate::pipeline::process_engine_tick_sync(dt_micros)
}
