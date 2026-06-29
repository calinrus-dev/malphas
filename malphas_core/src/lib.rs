// This crate is a C-ABI boundary; pointer arguments are validated inside each
// function before they are dereferenced, so the not_unsafe_ptr_arg_deref lint
// is not useful here.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod arena_layout;
pub mod bridge;
pub mod crypto;
pub mod input;
pub mod pipeline;
pub mod vm;

use std::ffi::c_void;
use std::os::raw::c_char;

use crate::bridge::{
    get_back_index as get_back_index_internal, get_buffer_a_ptr as get_buffer_a_ptr_internal,
    get_buffer_b_ptr as get_buffer_b_ptr_internal, get_command_count as get_command_count_internal,
    get_commands_pointer as get_commands_pointer_internal,
    get_commands_written as get_commands_written_internal,
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
use crate::pipeline::{
    get_commands_generated_count_internal, get_hit_tests_count_internal,
    get_pulse_latency_micros_internal, get_vm_tick_micros_internal,
    load_resource_pack as load_resource_pack_internal,
    load_resource_pack_raw as load_resource_pack_raw_internal, process_engine_tick_sync,
    set_entities_count as set_entities_count_internal, set_entity as set_entity_internal,
    write_arena_bytes as write_arena_bytes_internal, CoreCommandBuffer, DartRenderCommand,
    MalphasDoubleBufferBridge, TextPayload,
};

// ---------------------------------------------------------------------------
// Engine lifecycle.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn init_engine(
    bridge_ptr: *mut MalphasDoubleBufferBridge,
    arena_ptr: *mut c_void,
    arena_size: u32,
    max_commands: u32,
) -> i32 {
    init_engine_internal(bridge_ptr, arena_ptr, arena_size, max_commands)
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
pub extern "C" fn get_buffer_a_ptr(
    bridge: *mut MalphasDoubleBufferBridge,
) -> *mut CoreCommandBuffer {
    get_buffer_a_ptr_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_buffer_b_ptr(
    bridge: *mut MalphasDoubleBufferBridge,
) -> *mut CoreCommandBuffer {
    get_buffer_b_ptr_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_back_index(bridge: *mut MalphasDoubleBufferBridge) -> u8 {
    get_back_index_internal(bridge)
}

#[no_mangle]
pub extern "C" fn get_command_count(buffer: *const CoreCommandBuffer) -> u32 {
    get_command_count_internal(buffer)
}

#[no_mangle]
pub extern "C" fn get_commands_pointer(buffer: *const CoreCommandBuffer) -> *mut DartRenderCommand {
    get_commands_pointer_internal(buffer)
}

#[no_mangle]
pub extern "C" fn get_commands_written(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    get_commands_written_internal(bridge)
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
pub extern "C" fn get_hit_tests_count() -> u64 {
    get_hit_tests_count_internal()
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
// Resource pack loading.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn load_resource_pack_raw(ptr: *const u8, size: u32) -> i32 {
    load_resource_pack_raw_internal(ptr, size)
}

#[no_mangle]
pub extern "C" fn load_resource_pack(filepath: *const c_char) -> i32 {
    load_resource_pack_internal(filepath)
}

// ---------------------------------------------------------------------------
// Safe Arena helpers for Dart-side entity setup.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn set_entities_count(count: u32) -> i32 {
    set_entities_count_internal(count)
}

#[no_mangle]
pub extern "C" fn write_arena_bytes(offset: u32, ptr: *const u8, len: u32) -> i32 {
    write_arena_bytes_internal(offset, ptr, len)
}

#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub extern "C" fn set_entity(
    entity_id: u32,
    command_type: u8,
    layer: u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color_rgba: u32,
    speed_x: f32,
    speed_y: f32,
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    str_offset: u32,
) -> i32 {
    set_entity_internal(
        entity_id,
        command_type,
        layer,
        x,
        y,
        width,
        height,
        color_rgba,
        speed_x,
        speed_y,
        min_x,
        max_x,
        min_y,
        max_y,
        str_offset,
    )
}

// ---------------------------------------------------------------------------
// Synchronous tick fallback.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn process_engine_tick(dt_micros: u64) -> i32 {
    process_engine_tick_sync(dt_micros)
}
