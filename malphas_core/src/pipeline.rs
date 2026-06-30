// C-ABI structures and the background simulation tick for Malphas v2.7.0.
//
// The hot path is driven by a single VSync pulse from Flutter.  On each tick
// the core obtains the fresh Silver Platter from the mapped MSP and hands the
// back buffer directly to the loaded `.mxc` systems.  Systems write render
// commands into the buffer; the core only flips the double-buffer index.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

use crate::msp_loader::with_msp_map;
use crate::system_host::tick_systems;

// ---------------------------------------------------------------------------
// Global shared-memory handles and engine lifecycle state.
// ---------------------------------------------------------------------------
pub(crate) static BRIDGE_ADDRESS: AtomicUsize = AtomicUsize::new(0);
pub(crate) static MAX_COMMANDS_CAPACITY: AtomicU32 = AtomicU32::new(2048);
pub(crate) static ENGINE_RUNNING: AtomicBool = AtomicBool::new(false);
pub(crate) static ENGINE_PAUSED: AtomicBool = AtomicBool::new(false);

pub(crate) static TELEMETRY_ORIGIN: OnceLock<Instant> = OnceLock::new();
pub(crate) static LAST_PULSE_MICROS: AtomicU64 = AtomicU64::new(0);
static VM_TICK_MICROS: AtomicU64 = AtomicU64::new(0);
static PULSE_LATENCY_MICROS: AtomicU64 = AtomicU64::new(0);
static HIT_TESTS_COUNT: AtomicU64 = AtomicU64::new(0);
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

pub(crate) fn get_hit_tests_count_internal() -> u64 {
    HIT_TESTS_COUNT.load(Ordering::Relaxed)
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
/// Kept for ABI compatibility; text rendering in v2.7.0 is handled by systems.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextPayload {
    pub x: f32,
    pub y: f32,
    pub font_size: f32,
    // Null-terminated UTF-8 string bytes follow immediately in memory.
}

#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32,
    pub _padding0: u32,
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

// ---------------------------------------------------------------------------
// Tick entry points.
// ---------------------------------------------------------------------------
pub(crate) fn process_engine_tick_sync(_dt_micros: u64) -> i32 {
    0
}

pub(crate) fn process_engine_tick_internal() {
    let tick_start_micros = telemetry_now_micros();
    let last_pulse_micros = LAST_PULSE_MICROS.load(Ordering::Relaxed);
    PULSE_LATENCY_MICROS.store(
        tick_start_micros.saturating_sub(last_pulse_micros),
        Ordering::Relaxed,
    );

    let bridge_addr = BRIDGE_ADDRESS.load(Ordering::SeqCst);
    if bridge_addr == 0 {
        return;
    }

    let bridge = bridge_addr as *mut MalphasDoubleBufferBridge;
    let back_index = unsafe { (*bridge).atomic_back_index.load(Ordering::Acquire) };

    let (commands_ptr, command_count_atomic_ptr) = unsafe {
        if back_index == 0 {
            (
                (*bridge).buffer_a_commands,
                &(*bridge).buffer_a_command_count,
            )
        } else {
            (
                (*bridge).buffer_b_commands,
                &(*bridge).buffer_b_command_count,
            )
        }
    };
    if commands_ptr.is_null() {
        return;
    }

    let max_capacity = MAX_COMMANDS_CAPACITY.load(Ordering::SeqCst);

    // Invoke all loaded .mxc systems with the current Silver Platter and the
    // back buffer.  Systems mutate only their own internal SoA state and write
    // render commands directly into the buffer.
    let msp_tick_start = telemetry_now_micros();
    let mut written: u32 = 0;
    if let Some((lookup_table, entity_count)) =
        with_msp_map(|m| (m.lookup_table_ptr(), m.entity_count()))
    {
        if !lookup_table.is_null() {
            tick_systems(
                lookup_table,
                entity_count,
                0,
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

    unsafe {
        command_count_atomic_ptr.store(written, Ordering::Release);
        (*bridge).commands_written.store(written, Ordering::Release);
    }

    HIT_TESTS_COUNT.store(0, Ordering::Relaxed);
    COMMANDS_GENERATED_COUNT.store(written as u64, Ordering::Relaxed);

    let next_back = 1 - back_index;
    unsafe {
        (*bridge)
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
