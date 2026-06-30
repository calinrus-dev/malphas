// C-ABI structures and the background simulation tick for Malphas v2.9.0.
//
// The hot path is driven by a single VSync pulse from Flutter.  On each tick
// the core obtains the fresh Silver Platter from the mapped MSP and hands the
// back buffer directly to the loaded `.mxc` systems.  Systems write render
// commands into the buffer; the core only flips the double-buffer index.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use crate::bridge::get_front_buffer_snapshot;
use crate::input::drain_input_events;
use crate::msp_loader::MSP_MAP;
use crate::system_host::tick_systems;

/// ABI version embedded in the bridge.  Dart must verify this value before
/// trusting the layout.  Format: 0xMMmmpp00 (major, minor, patch).
pub const BRIDGE_ABI_VERSION: u32 = 0x02090000;

// ---------------------------------------------------------------------------
// Global shared-memory handles and engine lifecycle state.
// ---------------------------------------------------------------------------
pub(crate) static ENGINE_RUNNING: AtomicBool = AtomicBool::new(false);
pub(crate) static ENGINE_PAUSED: AtomicBool = AtomicBool::new(false);

pub(crate) static TELEMETRY_ORIGIN: OnceLock<Instant> = OnceLock::new();
pub(crate) static LAST_PULSE_MICROS: AtomicU64 = AtomicU64::new(0);
static VM_TICK_MICROS: AtomicU64 = AtomicU64::new(0);
static PULSE_LATENCY_MICROS: AtomicU64 = AtomicU64::new(0);
static COMMANDS_GENERATED_COUNT: AtomicU64 = AtomicU64::new(0);

pub(crate) fn telemetry_now_micros() -> u64 {
    TELEMETRY_ORIGIN
        .get_or_init(Instant::now)
        .elapsed()
        .as_micros() as u64
}

pub(crate) fn get_vm_tick_micros_internal() -> u64 {
    VM_TICK_MICROS.load(Ordering::Relaxed)
}

pub(crate) fn get_pulse_latency_micros_internal() -> u64 {
    PULSE_LATENCY_MICROS.load(Ordering::Relaxed)
}

pub(crate) fn get_commands_generated_count_internal() -> u64 {
    COMMANDS_GENERATED_COUNT.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// C-ABI structures.
// ---------------------------------------------------------------------------
#[repr(C)]
#[derive(Clone, Copy)]
pub struct DartRenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub pad: u16,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

/// In-Arena text object pointed to by text render commands.
///
/// Kept for ABI compatibility; text rendering in v2.9.0 is handled by systems.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextPayload {
    pub x: f32,
    pub y: f32,
    pub font_size: f32,
    // Null-terminated UTF-8 string bytes follow immediately in memory.
}

/// 64-byte FFI-visible double-buffer bridge.  Fields are laid out so that Dart
/// can read the atomic counts and back index without copying the struct.
#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32,
    pub abi_version: u32,
    pub buffer_a_commands: *mut DartRenderCommand,
    pub buffer_b_command_count: AtomicU32,
    pub _padding1: u32,
    pub buffer_b_commands: *mut DartRenderCommand,
    pub atomic_back_index: AtomicU8,
    pub _padding2: u8,
    pub _padding3: u8,
    pub _padding4: u8,
    pub commands_written: AtomicU32,
    pub _padding5: u32,
    pub _padding6: u32,
    pub _padding7: u64,
    pub _padding8: u64,
    // Total: 64 bytes, 1 cache line.
}

/// Owned Rust-side view of the bridge and its buffers.  The pointers are valid
/// for the lifetime of this object.
pub(crate) struct BridgeState {
    pub bridge: *mut MalphasDoubleBufferBridge,
    pub buffer_a: *mut DartRenderCommand,
    pub buffer_b: *mut DartRenderCommand,
    pub capacity: u32,
}

// The pointers point to allocations owned by this struct and never change after
// construction, so sharing an immutable Arc<BridgeState> across threads is safe.
unsafe impl Send for BridgeState {}
unsafe impl Sync for BridgeState {}

static BRIDGE_STATE: Mutex<Option<Arc<BridgeState>>> = Mutex::new(None);
static LAST_TICK_MICROS: AtomicU64 = AtomicU64::new(0);

// ---------------------------------------------------------------------------
// Bridge allocation / freeing.
// ---------------------------------------------------------------------------
pub(crate) fn allocate_bridge(max_commands: u32) -> Option<*mut MalphasDoubleBufferBridge> {
    if max_commands == 0 {
        return None;
    }

    let bridge_size = std::mem::size_of::<MalphasDoubleBufferBridge>();
    let bridge_ptr = crate::bridge::malphas_alloc(bridge_size) as *mut MalphasDoubleBufferBridge;
    if bridge_ptr.is_null() {
        return None;
    }

    let command_bytes = (max_commands as usize) * std::mem::size_of::<DartRenderCommand>();
    let buffer_a = crate::bridge::malphas_alloc(command_bytes) as *mut DartRenderCommand;
    let buffer_b = crate::bridge::malphas_alloc(command_bytes) as *mut DartRenderCommand;
    if buffer_a.is_null() || buffer_b.is_null() {
        crate::bridge::malphas_free(bridge_ptr as *mut u8, bridge_size);
        if !buffer_a.is_null() {
            crate::bridge::malphas_free(buffer_a as *mut u8, command_bytes);
        }
        if !buffer_b.is_null() {
            crate::bridge::malphas_free(buffer_b as *mut u8, command_bytes);
        }
        return None;
    }

    // SAFETY: `bridge_ptr` is non-null, 64-byte aligned, and points to
    // `bridge_size` freshly allocated bytes, so zero-initialising the struct is
    // valid.  The subsequent field writes only touch that owned allocation.
    unsafe {
        std::ptr::write_bytes(bridge_ptr as *mut u8, 0, bridge_size);
        (*bridge_ptr).abi_version = BRIDGE_ABI_VERSION;
        (*bridge_ptr).buffer_a_commands = buffer_a;
        (*bridge_ptr).buffer_b_commands = buffer_b;
        (*bridge_ptr).atomic_back_index.store(0, Ordering::Relaxed);
        (*bridge_ptr)
            .buffer_a_command_count
            .store(0, Ordering::Relaxed);
        (*bridge_ptr)
            .buffer_b_command_count
            .store(0, Ordering::Relaxed);
        (*bridge_ptr).commands_written.store(0, Ordering::Relaxed);
    }

    let state = Arc::new(BridgeState {
        bridge: bridge_ptr,
        buffer_a,
        buffer_b,
        capacity: max_commands,
    });

    match BRIDGE_STATE.lock() {
        Ok(mut guard) => {
            *guard = Some(state);
        }
        Err(_) => {
            // Poisoned lock: clean up rather than leak.
            crate::bridge::malphas_free(bridge_ptr as *mut u8, bridge_size);
            crate::bridge::malphas_free(buffer_a as *mut u8, command_bytes);
            crate::bridge::malphas_free(buffer_b as *mut u8, command_bytes);
            return None;
        }
    }

    Some(bridge_ptr)
}

pub(crate) fn free_bridge() {
    let state = BRIDGE_STATE.lock().ok().and_then(|mut g| g.take());
    if let Some(state) = state {
        let bridge_size = std::mem::size_of::<MalphasDoubleBufferBridge>();
        let command_bytes = (state.capacity as usize) * std::mem::size_of::<DartRenderCommand>();
        crate::bridge::malphas_free(state.buffer_a as *mut u8, command_bytes);
        crate::bridge::malphas_free(state.buffer_b as *mut u8, command_bytes);
        crate::bridge::malphas_free(state.bridge as *mut u8, bridge_size);
        // The Arc drops here, releasing the last reference.
    }
}

pub(crate) fn bridge_state() -> Option<Arc<BridgeState>> {
    BRIDGE_STATE.lock().ok().and_then(|g| g.as_ref().cloned())
}

// ---------------------------------------------------------------------------
// Tick entry points.
// ---------------------------------------------------------------------------
pub(crate) fn process_engine_tick_sync(_dt_micros: u64) -> i32 {
    // Synchronous ticks are not preceded by a `trigger_engine_pulse`, so record
    // the current time as the pulse timestamp so latency telemetry reflects the
    // moment the sync tick was requested.
    LAST_PULSE_MICROS.store(telemetry_now_micros(), Ordering::Relaxed);
    process_engine_tick_internal();
    0
}

pub(crate) fn process_engine_tick_internal() {
    let tick_start_micros = telemetry_now_micros();
    let last_pulse_micros = LAST_PULSE_MICROS.load(Ordering::Relaxed);
    PULSE_LATENCY_MICROS.store(
        tick_start_micros.saturating_sub(last_pulse_micros),
        Ordering::Relaxed,
    );

    let bridge = match bridge_state() {
        Some(b) => b,
        None => return,
    };

    // Use the same consistent snapshot pattern as `get_front_buffer_snapshot`:
    // read the back index once with Acquire ordering and derive the back buffer
    // (the one the simulation thread writes into) as the opposite side.
    let front_snapshot = get_front_buffer_snapshot(bridge.bridge);
    let back_index = if front_snapshot.0 == 0 { 1 } else { 0 };
    let commands_ptr = if back_index == 0 {
        bridge.buffer_a
    } else {
        bridge.buffer_b
    };
    let command_count_atomic_ptr = if back_index == 0 {
        // SAFETY: `bridge.bridge` is a valid, aligned bridge owned by this
        // `BridgeState`; the field address is derived from a live allocation.
        unsafe { &(*bridge.bridge).buffer_a_command_count }
    } else {
        // SAFETY: Same as above.
        unsafe { &(*bridge.bridge).buffer_b_command_count }
    };
    if commands_ptr.is_null() {
        return;
    }
    let max_capacity = bridge.capacity;

    // Compute real delta time, capped to avoid explosion after a pause.
    let last_tick = LAST_TICK_MICROS.load(Ordering::Relaxed);
    let dt_micros = if last_tick == 0 {
        0
    } else {
        tick_start_micros.saturating_sub(last_tick).min(1_000_000)
    };
    LAST_TICK_MICROS.store(tick_start_micros, Ordering::Relaxed);

    // Drain any input events that arrived since the last tick.  The current ABI
    // does not pass events to systems; they are consumed here to keep the queue
    // bounded.
    let _input_events = drain_input_events();

    // Pin the MSP snapshot for the entire tick so refresh/unload cannot free it
    // underneath the systems.
    let msp_snapshot = MSP_MAP.load_full();
    let msp_tick_start = telemetry_now_micros();
    let mut written: u32 = 0;
    if let Some(msp) = msp_snapshot.as_ref() {
        let lookup_table = msp.lookup_table_ptr();
        let entity_count = msp.entity_count();
        if !lookup_table.is_null() {
            tick_systems(
                lookup_table,
                entity_count,
                dt_micros,
                commands_ptr,
                max_capacity,
                &mut written,
            );
        }
    }
    let msp_tick_end = telemetry_now_micros();
    VM_TICK_MICROS.store(
        msp_tick_end.saturating_sub(msp_tick_start),
        Ordering::Relaxed,
    );

    // SAFETY: `bridge.bridge` is a valid, aligned bridge owned by this
    // `BridgeState`; the atomic stores publish the command count and flip the
    // back buffer index to the front-buffer reader.
    unsafe {
        command_count_atomic_ptr.store(written, Ordering::Release);
        (*bridge.bridge)
            .commands_written
            .store(written, Ordering::Release);
    }

    COMMANDS_GENERATED_COUNT.store(written as u64, Ordering::Relaxed);

    let next_back = if back_index == 0 { 1 } else { 0 };
    // SAFETY: Same as above: the bridge is live and exclusively owned by Rust.
    unsafe {
        (*bridge.bridge)
            .atomic_back_index
            .store(next_back, Ordering::Release);
    }
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_struct_alignments() {
        assert_eq!(std::mem::size_of::<DartRenderCommand>(), 24);
        assert_eq!(std::mem::align_of::<DartRenderCommand>(), 4);

        assert_eq!(std::mem::size_of::<MalphasDoubleBufferBridge>(), 64);
        assert_eq!(std::mem::align_of::<MalphasDoubleBufferBridge>(), 64);

        assert_eq!(std::mem::size_of::<crate::msp_loader::MspHeader>(), 64);
        assert_eq!(std::mem::align_of::<crate::msp_loader::MspHeader>(), 64);
        assert_eq!(
            std::mem::size_of::<crate::msp_loader::MspEntityDescriptor>(),
            64
        );
        assert_eq!(
            std::mem::align_of::<crate::msp_loader::MspEntityDescriptor>(),
            64
        );
    }

    #[test]
    fn test_lockless_lookup_table_latency() {
        let iterations = 100_000;
        let start = std::time::Instant::now();
        for _ in 0..iterations {
            let _ = crate::msp_loader::with_msp_map(|m| m.lookup_table_ptr());
        }
        let duration = start.elapsed();
        let ns_per_iter = (duration.as_nanos() as f64) / (iterations as f64);
        println!("msp_map read latency: {:.4} ns/iter", ns_per_iter);
        assert!(
            ns_per_iter < 1000.0,
            "Latency too high: {} ns/iter",
            ns_per_iter
        );
    }
}
