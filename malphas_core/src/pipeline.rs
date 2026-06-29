// C-ABI structures, shared-memory globals, resource loading, arena helpers,
// and the background simulation tick for the Malphas engine.
use arc_swap::ArcSwap;
use std::collections::VecDeque;
use std::fs::File;
use std::io::Read;
use std::os::raw::c_char;
use std::sync::atomic::{
    AtomicBool, AtomicPtr, AtomicU32, AtomicU64, AtomicU8, AtomicUsize, Ordering,
};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Instant;

use sha2::{Digest, Sha256};

use crate::arena_layout::{
    DEFAULT_STATIC_RESOURCES_OFFSET, ENTITIES_COUNT, ENTITIES_OFFSET, ENTITY_SLOT_SIZE,
    ENTITY_STR_OFFSET, FONT_ATLAS_OFFSET, FONT_METRICS_OFFSET, OBJECTS_TABLE_OFFSET,
    STATIC_RESOURCES_SIZE, TEXT_PAYLOAD_SIZE,
};
use crate::bridge::{
    get_buffer_a_ptr, get_buffer_b_ptr, malphas_alloc, malphas_free, pause_engine_internal,
};
use crate::crypto::c_str_to_str;
use crate::input::INPUT_QUEUE;

// ---------------------------------------------------------------------------
// Global shared-memory handles and engine lifecycle state.
// All addresses are stored as usize to keep them Send/Sync and trivially atomic.
// ---------------------------------------------------------------------------
pub(crate) static ARENA_ADDRESS: AtomicUsize = AtomicUsize::new(0);
pub(crate) static ARENA_SIZE: AtomicUsize = AtomicUsize::new(0);
pub(crate) static BRIDGE_ADDRESS: AtomicUsize = AtomicUsize::new(0);
pub(crate) static MAX_COMMANDS_CAPACITY: AtomicU32 = AtomicU32::new(2048);
pub(crate) static ENGINE_RUNNING: AtomicBool = AtomicBool::new(false);
pub(crate) static ENGINE_PAUSED: AtomicBool = AtomicBool::new(false);

// ---------------------------------------------------------------------------
// Lock-free telemetry counters for MALPHAS REINFORCED v2.2 Phase 5.
// All values are written Relaxed and read from FFI without synchronising
// engine state, so they add no contention on the hot path.
// ---------------------------------------------------------------------------
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
// Protects dynamic entity data in the Arena.  Static resources (font atlas,
// metrics, jump tables, loaded package bytes) are written once during package
// loading and are read lock-free afterwards.  The engine tick holds this
// lock only while accessing dynamic entity state; Dart-side helpers acquire
// it for entity setup.
// ---------------------------------------------------------------------------
pub(crate) static ARENA_LOCK: RwLock<()> = RwLock::new(());

// ---------------------------------------------------------------------------
// C-ABI structures.  All are 16-byte aligned so they are safe on strict
// architectures such as ARM64.  Sizes are verified by unit tests.
// ---------------------------------------------------------------------------
#[repr(C)]
#[derive(Clone, Copy)]
pub struct DartRenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub pad: u16,
    /// Logical union payload.  For `command_type == 1` this is the rectangle
    /// geometry (`x`, `y`, `width`, `height`).  For `command_type == 2` the
    /// same bytes are reinterpreted: `x` holds the text length, `y` holds the
    /// text style/font size, and `width`/`height` hold the low/high 32 bits of
    /// a pointer to a `TextPayload` in the Arena.  The struct stays 24 bytes
    /// with 4-byte alignment so the command array remains homogeneous.
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

/// In-Arena text object pointed to by text render commands.  The command only
/// stores the pointer; geometry lives here so the double-buffered command
/// array stays a homogeneous 24-byte stride.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TextPayload {
    pub x: f32,
    pub y: f32,
    pub font_size: f32,
    // Null-terminated UTF-8 string bytes follow immediately in Arena memory.
}

#[repr(C, align(16))]
pub struct CoreCommandBuffer {
    /// Atomic so both sides can read the count of the buffer they are
    /// observing without invoking formal data races.
    pub command_count: AtomicU32,
    pub commands: *mut DartRenderCommand,
}

#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: AtomicU8,
    pub commands_written: AtomicU32,
    pub _padding0: u32,
    pub _padding1: u32,
    pub _padding2: u32,
    pub _padding3: u32,
    pub _padding4: u32,
    pub _padding5: u32,
}

#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct MhpHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub total_size: u64,
    pub checksum: [u8; 32],
    pub pack_id: [u8; 16],
    pub canvas_width: u16,
    pub canvas_height: u16,
    pub font_metrics_offset: u32,
    pub font_atlas_offset: u32,
    pub objects_table_offset: u32,
    pub objects_table_count: u32,
    pub skins_offset: u32,
    pub skins_size: u32,
    pub has_embedded_msp: u32,
    pub embedded_msp_offset: u32,
    pub embedded_msp_size: u32,
    pub padding: [u8; 4],
}

#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct MhpObjectDescriptor {
    pub object_id: u32,
    pub properties_offset: u32,
    pub properties_size: u32,
    pub skins_offset: u32,
    pub skins_size: u32,
    pub padding: [u8; 12],
}

#[repr(C, align(16))]
#[derive(Clone, Copy)]
pub struct MspHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub checksum: [u8; 32],
    pub bytecode_size: u32,
    pub entry_point: u32,
    pub padding: [u8; 16],
}

// ---------------------------------------------------------------------------
// Runtime state.
// ---------------------------------------------------------------------------
pub struct ResourcePackRuntime {
    pub arena_start_ptr: *mut u8,
    pub arena_size: usize,
}

unsafe impl Send for ResourcePackRuntime {}
unsafe impl Sync for ResourcePackRuntime {}

/// Live runtime pointer.  Stored as an atomic raw pointer so it can be
/// hot-swapped during package loading without taking a lock on the simulation
/// hot path. The tick `load`s it with `Acquire`; package loading `swap`s it
/// with `AcqRel` while the engine is paused and the Arena lock is held.
pub(crate) static RUNTIME: AtomicPtr<ResourcePackRuntime> = AtomicPtr::new(std::ptr::null_mut());

/// Lock-free, atomic single-writer / multi-reader bytecode container.
///
/// NOTE: `ArcSwap<[u8]>` is not supported by `arc-swap` because `[u8]` is
/// `?Sized` and the crate's `RefCnt` trait requires a sized pointee.  The
/// closest zero-copy shape is `Arc<Box<[u8]>>`: the hot path dereferences
/// `&**guard` which still yields a contiguous `[u8]` slice.
static BYTECODE_VM: OnceLock<ArcSwap<Box<[u8]>>> = OnceLock::new();

pub(crate) fn get_bytecode_vm() -> &'static ArcSwap<Box<[u8]>> {
    BYTECODE_VM.get_or_init(|| ArcSwap::from(Arc::new(Vec::new().into_boxed_slice())))
}

// ---------------------------------------------------------------------------
// Synchronous tick fallback (kept for API compatibility; real work is done
// by the background thread started in init_engine).
// ---------------------------------------------------------------------------
pub(crate) fn process_engine_tick_sync(_dt_micros: u64) -> i32 {
    0
}

// ---------------------------------------------------------------------------
// Background simulation tick.
// ---------------------------------------------------------------------------
pub(crate) fn process_engine_tick_internal() {
    let tick_start_micros = telemetry_now_micros();
    let last_pulse_micros = LAST_PULSE_MICROS.load(Ordering::Relaxed);
    PULSE_LATENCY_MICROS.store(
        tick_start_micros.saturating_sub(last_pulse_micros),
        Ordering::Relaxed,
    );

    // Telemetry counters for this frame.  These are locals because the atomic
    // stores happen once at the end of the tick.
    let mut hit_tests_this_frame: u64 = 0;

    let bridge_addr = BRIDGE_ADDRESS.load(Ordering::SeqCst);
    if bridge_addr == 0 {
        return;
    }

    let bridge = bridge_addr as *mut MalphasDoubleBufferBridge;
    let back_index = unsafe { (*bridge).atomic_back_index.load(Ordering::Acquire) };

    let back_buffer_ptr = if back_index == 0 {
        get_buffer_a_ptr(bridge)
    } else {
        get_buffer_b_ptr(bridge)
    };
    if back_buffer_ptr.is_null() {
        return;
    }

    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);
    let max_capacity = MAX_COMMANDS_CAPACITY.load(Ordering::SeqCst) as usize;

    if arena_addr == 0 {
        return;
    }

    let arena_start = arena_addr as *mut u8;

    // 1. Drain input events at the start of the frame.  This only touches the
    //    input queue, not the Arena, so no Arena lock is required.
    let mut events = VecDeque::new();
    if let Ok(mut queue) = INPUT_QUEUE.lock() {
        std::mem::swap(&mut *queue, &mut events);
    }

    // 2. Process input events under a write lock because they mutate entity
    //    state (speed and colour).  The lock is held only for this short phase.
    if !events.is_empty() {
        let _write_guard = ARENA_LOCK.write();
        let entities_offset = unsafe { *(arena_start.add(ENTITIES_OFFSET) as *const u32) } as usize;
        let entities_count = unsafe { *(arena_start.add(ENTITIES_COUNT) as *const u32) } as usize;

        for event in events {
            let x = event.x;
            let y = event.y;
            for entity_id in 0..entities_count {
                let entity_ptr =
                    unsafe { arena_start.add(entities_offset + entity_id * ENTITY_SLOT_SIZE) };
                let cmd = unsafe { &mut *(entity_ptr as *mut DartRenderCommand) };

                if cmd.command_type == 0 {
                    continue;
                }

                // Text commands (type 2) carry a pointer in their width/height
                // fields, not geometry, so skip them for hit testing.
                if cmd.command_type == 2 {
                    continue;
                }

                hit_tests_this_frame += 1;
                if x >= cmd.x && x <= cmd.x + cmd.width && y >= cmd.y && y <= cmd.y + cmd.height {
                    unsafe {
                        let speed_x_ptr = entity_ptr.add(24) as *mut f32;
                        let speed_y_ptr = entity_ptr.add(28) as *mut f32;
                        *speed_x_ptr = -(*speed_x_ptr);
                        *speed_y_ptr = -(*speed_y_ptr);

                        if cmd.color_rgba == 0xFF00FFCC {
                            cmd.color_rgba = 0xFFFF00CC;
                        } else if cmd.color_rgba == 0xFFFF00CC {
                            cmd.color_rgba = 0xFF00FFCC;
                        } else if cmd.color_rgba == 0xFFE0DCD3 {
                            cmd.color_rgba = 0xFFFFFF00;
                        } else if cmd.color_rgba == 0xFFFFFF00 {
                            cmd.color_rgba = 0xFFE0DCD3;
                        }
                    }
                }
            }
        }
    }

    // 3. Load bytecode atomically and lock-free.  Bytecode is a static resource
    //    and is read lock-free after package load.
    let bytecode_guard = get_bytecode_vm().load();
    let bytecode: &[u8] = &bytecode_guard;

    // 4. Execute bytecode and generate render commands.  Entity data is dynamic,
    //    so it is accessed under a read lock.  This allows concurrent Dart
    //    readers while still excluding Dart writers.  The engine thread is the
    //    only writer during this phase.
    {
        let _read_guard = ARENA_LOCK.read();
        let entities_offset = unsafe { *(arena_start.add(ENTITIES_OFFSET) as *const u32) } as usize;
        let entities_count = unsafe { *(arena_start.add(ENTITIES_COUNT) as *const u32) } as usize;

        // Run bytecode script inside the sandbox runtime.
        let vm_start_micros = telemetry_now_micros();
        {
            // Acquire load matches the AcqRel swap in load_mhp_package, ensuring we
            // see a fully initialised runtime and that the package loader sees our
            // subsequent Arena reads complete before the pointer is reused.
            let runtime_ptr = RUNTIME.load(Ordering::Acquire);
            if !runtime_ptr.is_null() {
                unsafe {
                    let runtime = &mut *runtime_ptr;
                    runtime.arena_start_ptr = arena_start;
                    runtime.arena_size = arena_size;

                    for entity_id in 0..entities_count {
                        runtime.execute_logic_tick(entity_id as u16, bytecode);
                    }
                }
            }
        }
        let vm_end_micros = telemetry_now_micros();
        VM_TICK_MICROS.store(
            vm_end_micros.saturating_sub(vm_start_micros),
            Ordering::Relaxed,
        );

        // Generate render commands into the back buffer.
        let commands_ptr = unsafe { (*back_buffer_ptr).commands };
        if commands_ptr.is_null() {
            return;
        }

        let commands_slice = unsafe { std::slice::from_raw_parts_mut(commands_ptr, max_capacity) };

        let mut write_idx = 0usize;
        for entity_id in 0..entities_count {
            let entity_ptr =
                unsafe { arena_start.add(entities_offset + entity_id * ENTITY_SLOT_SIZE) };
            let cmd = unsafe { &*(entity_ptr as *const DartRenderCommand) };

            if cmd.command_type == 0 {
                continue;
            }

            if write_idx < max_capacity {
                commands_slice[write_idx] = *cmd;

                // Union text command: command_type == 2 stores text metadata in
                // x/y and a pointer to the Arena-resident TextPayload in width/height.
                // This keeps the command array a homogeneous 24-byte stride.
                if cmd.command_type == 2 {
                    let str_offset =
                        unsafe { *(entity_ptr.add(ENTITY_STR_OFFSET) as *const u32) } as usize;
                    let payload_size = TEXT_PAYLOAD_SIZE;

                    if str_offset + payload_size <= arena_size {
                        let text_payload_ptr =
                            unsafe { arena_start.add(str_offset) as *mut TextPayload };

                        // Synchronise the payload geometry with the entity so the
                        // text moves with the simulation while the command buffer
                        // remains a simple fixed-size array.
                        unsafe {
                            (*text_payload_ptr).x = cmd.x;
                            (*text_payload_ptr).y = cmd.y;
                            (*text_payload_ptr).font_size = cmd.width;
                        }

                        let text_bytes_ptr =
                            unsafe { (text_payload_ptr as *mut u8).add(payload_size) };
                        let mut text_len = 0usize;
                        unsafe {
                            let max_len = arena_size - str_offset - payload_size;
                            while text_len < max_len && *text_bytes_ptr.add(text_len) != 0 {
                                text_len += 1;
                            }
                        }

                        let payload_addr = text_payload_ptr as usize;
                        commands_slice[write_idx].x = text_len as f32;
                        commands_slice[write_idx].y = cmd.width; // style = font size
                        commands_slice[write_idx].width = f32::from_bits(payload_addr as u32);
                        commands_slice[write_idx].height =
                            f32::from_bits((payload_addr >> 32) as u32);
                    }

                    write_idx += 1;
                } else {
                    write_idx += 1;
                }
            }
        }

        unsafe {
            (*back_buffer_ptr)
                .command_count
                .store(write_idx as u32, Ordering::Release);
            (*bridge)
                .commands_written
                .store(write_idx as u32, Ordering::Release);
        }

        HIT_TESTS_COUNT.store(hit_tests_this_frame, Ordering::Relaxed);
        COMMANDS_GENERATED_COUNT.store(write_idx as u64, Ordering::Relaxed);

        let next_back = 1 - back_index;
        unsafe {
            (*bridge)
                .atomic_back_index
                .store(next_back, Ordering::Release);
        }
    }
}

// ---------------------------------------------------------------------------
// Resource pack loading.
// ---------------------------------------------------------------------------
pub fn load_resource_pack_raw(ptr: *const u8, size: u32) -> i32 {
    if ptr.is_null() || size < 4 {
        return -1;
    }

    let buffer = unsafe { std::slice::from_raw_parts(ptr, size as usize) };
    let magic = &buffer[0..4];

    if magic == b"MLPH" {
        load_mhp_package(buffer)
    } else if magic == b"MLPS" {
        load_msp_package(buffer)
    } else {
        -30
    }
}

pub(crate) fn load_mhp_package(buffer: &[u8]) -> i32 {
    let header_size = std::mem::size_of::<MhpHeader>();
    if buffer.len() < header_size {
        return -5;
    }

    let header = unsafe { std::ptr::read_unaligned(buffer.as_ptr() as *const MhpHeader) };

    if header.total_size as usize != buffer.len() {
        return -6;
    }

    let mut hasher = Sha256::new();
    hasher.update(&buffer[header_size..]);
    let calculated = hasher.finalize();
    if calculated.as_slice() != header.checksum {
        return -7;
    }

    if header.font_metrics_offset as usize + 4096 > buffer.len() {
        return -8;
    }
    if header.font_atlas_offset as usize + (512 * 512) > buffer.len() {
        return -9;
    }
    let objects_table_end =
        header.objects_table_offset as usize + (header.objects_table_count as usize * 32);
    if objects_table_end > buffer.len() {
        return -10;
    }
    if header.skins_offset as usize + header.skins_size as usize > buffer.len() {
        return -11;
    }

    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);

    if arena_addr != 0 {
        let arena_start = arena_addr as *mut u8;
        // Static resources are written once under a write lock; after this
        // completes they are read lock-free by both the engine tick and Dart.
        let _guard = ARENA_LOCK.write();
        unsafe {
            *(arena_start.add(STATIC_RESOURCES_SIZE) as *mut u32) = buffer.len() as u32;
            *(arena_start.add(FONT_METRICS_OFFSET) as *mut u32) =
                DEFAULT_STATIC_RESOURCES_OFFSET + header.font_metrics_offset;
            *(arena_start.add(FONT_ATLAS_OFFSET) as *mut u32) =
                DEFAULT_STATIC_RESOURCES_OFFSET + header.font_atlas_offset;
            *(arena_start.add(OBJECTS_TABLE_OFFSET) as *mut u32) =
                DEFAULT_STATIC_RESOURCES_OFFSET + header.objects_table_offset;

            if arena_size >= buffer.len() + DEFAULT_STATIC_RESOURCES_OFFSET as usize {
                std::ptr::copy_nonoverlapping(
                    buffer.as_ptr(),
                    arena_start.add(DEFAULT_STATIC_RESOURCES_OFFSET as usize),
                    buffer.len(),
                );
            } else {
                return -12;
            }
        }
    }

    let mut bytecode = Vec::new();
    if header.has_embedded_msp == 1 {
        let start = header.embedded_msp_offset as usize;
        let end = start + header.embedded_msp_size as usize;
        if end <= buffer.len() {
            bytecode = buffer[start..end].to_vec();
        } else {
            return -13;
        }
    }

    let nuevo_bytecode = Arc::new(bytecode.into_boxed_slice());
    get_bytecode_vm().store(nuevo_bytecode);

    // Build the new runtime on the heap; the old one will be dropped after the
    // engine has been paused and the atomic pointer swapped with AcqRel.
    let new_runtime = Box::new(ResourcePackRuntime {
        arena_start_ptr: arena_addr as *mut u8,
        arena_size,
    });
    let new_ptr = Box::into_raw(new_runtime);

    pause_engine_internal(1);
    {
        // Wait (block) until any in-flight tick has released the Arena lock,
        // which guarantees the old runtime is no longer in use.
        let _guard = ARENA_LOCK.write();
        let old_ptr = RUNTIME.swap(new_ptr, Ordering::AcqRel);
        if !old_ptr.is_null() {
            unsafe {
                drop(Box::from_raw(old_ptr));
            }
        }
    }
    pause_engine_internal(0);

    0
}

pub(crate) fn load_msp_package(buffer: &[u8]) -> i32 {
    let header_size = std::mem::size_of::<MspHeader>();
    if buffer.len() < header_size {
        return -20;
    }

    let header = unsafe { std::ptr::read_unaligned(buffer.as_ptr() as *const MspHeader) };

    let payload_start = header_size;
    let payload_end = payload_start + header.bytecode_size as usize;
    if payload_end > buffer.len() {
        return -21;
    }

    let mut hasher = Sha256::new();
    hasher.update(&buffer[payload_start..payload_end]);
    let calculated = hasher.finalize();
    if calculated.as_slice() != header.checksum {
        return -22;
    }

    let bytecode = buffer[payload_start..payload_end].to_vec();
    let nuevo_bytecode = Arc::new(bytecode.into_boxed_slice());
    get_bytecode_vm().store(nuevo_bytecode);

    0
}

pub fn load_resource_pack(filepath: *const c_char) -> i32 {
    let path = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };

    let mut file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return -2,
    };

    let mut buffer = Vec::new();
    if file.read_to_end(&mut buffer).is_err() {
        return -3;
    }

    let size = buffer.len();
    // Copy the file into a Rust-allocated buffer so `load_resource_pack_raw`
    // receives memory with the same 16-byte alignment guarantees as Dart shared
    // buffers. The allocation is freed immediately after parsing.
    let ptr = malphas_alloc(size);
    if ptr.is_null() {
        return -4;
    }

    unsafe {
        std::ptr::copy_nonoverlapping(buffer.as_ptr(), ptr, size);
    }

    let res = load_resource_pack_raw(ptr, size as u32);
    malphas_free(ptr, size);
    res
}

// ---------------------------------------------------------------------------
// Safe Arena helpers for Dart-side entity setup.  These acquire ARENA_LOCK
// so they never race the simulation tick.
// ---------------------------------------------------------------------------
pub fn set_entities_count(count: u32) -> i32 {
    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    if arena_addr == 0 {
        return -1;
    }
    let _guard = ARENA_LOCK.write();
    unsafe {
        *((arena_addr as *mut u8).add(ENTITIES_COUNT) as *mut u32) = count;
    }
    0
}

pub fn write_arena_bytes(offset: u32, ptr: *const u8, len: u32) -> i32 {
    if ptr.is_null() {
        return -1;
    }
    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);
    if arena_addr == 0 {
        return -2;
    }
    let start = offset as usize;
    let end = start + len as usize;
    if end > arena_size {
        return -3;
    }
    let _guard = ARENA_LOCK.write();
    unsafe {
        std::ptr::copy_nonoverlapping(ptr, (arena_addr as *mut u8).add(start), len as usize);
    }
    0
}

#[allow(clippy::too_many_arguments)]
pub fn set_entity(
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
    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);
    if arena_addr == 0 {
        return -1;
    }

    let _guard = ARENA_LOCK.write();
    let arena_start = arena_addr as *mut u8;
    let entities_offset = unsafe { *(arena_start.add(ENTITIES_OFFSET) as *const u32) } as usize;
    let entity_offset = entities_offset + (entity_id as usize * ENTITY_SLOT_SIZE);
    if entity_offset + ENTITY_SLOT_SIZE > arena_size {
        return -2;
    }

    unsafe {
        let entity_ptr = arena_start.add(entity_offset);
        *entity_ptr = command_type;
        *entity_ptr.add(1) = layer;
        *((entity_ptr.add(4)) as *mut f32) = x;
        *((entity_ptr.add(8)) as *mut f32) = y;
        *((entity_ptr.add(12)) as *mut f32) = width;
        *((entity_ptr.add(16)) as *mut f32) = height;
        *((entity_ptr.add(20)) as *mut u32) = color_rgba;
        *((entity_ptr.add(24)) as *mut f32) = speed_x;
        *((entity_ptr.add(28)) as *mut f32) = speed_y;
        *((entity_ptr.add(32)) as *mut f32) = min_x;
        *((entity_ptr.add(36)) as *mut f32) = max_x;
        *((entity_ptr.add(40)) as *mut f32) = min_y;
        *((entity_ptr.add(44)) as *mut f32) = max_y;
        *((entity_ptr.add(ENTITY_STR_OFFSET)) as *mut u32) = str_offset;
    }
    0
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    #[test]
    fn test_struct_alignments() {
        assert_eq!(std::mem::size_of::<DartRenderCommand>(), 24);
        assert_eq!(std::mem::align_of::<DartRenderCommand>(), 4);

        assert_eq!(std::mem::size_of::<CoreCommandBuffer>(), 16);
        assert_eq!(std::mem::align_of::<CoreCommandBuffer>(), 16);

        assert_eq!(std::mem::size_of::<MalphasDoubleBufferBridge>(), 64);
        assert_eq!(std::mem::align_of::<MalphasDoubleBufferBridge>(), 64);

        assert_eq!(std::mem::size_of::<MhpHeader>(), 112);
        assert_eq!(std::mem::align_of::<MhpHeader>(), 16);
        assert_eq!(std::mem::size_of::<MhpObjectDescriptor>(), 32);
        assert_eq!(std::mem::align_of::<MhpObjectDescriptor>(), 16);
        assert_eq!(std::mem::size_of::<MspHeader>(), 64);
        assert_eq!(std::mem::align_of::<MspHeader>(), 16);
    }

    #[test]
    fn test_lockless_bytecode_latency() {
        let iterations = 100_000;
        let start = std::time::Instant::now();
        for _ in 0..iterations {
            let guard = get_bytecode_vm().load();
            let _ = &**guard;
        }
        let duration = start.elapsed();
        let ns_per_iter = (duration.as_nanos() as f64) / (iterations as f64);
        println!("ArcSwap<[u8]> read latency: {:.4} ns/iter", ns_per_iter);
        assert!(
            ns_per_iter < 1000.0,
            "Latency too high: {} ns/iter",
            ns_per_iter
        );
    }

    #[test]
    fn test_rwlock_concurrent_readers_block_writer() {
        let lock = Arc::new(RwLock::new(()));
        let writer_acquired = Arc::new(AtomicBool::new(false));

        let lock_w = Arc::clone(&lock);
        let writer_acquired_w = Arc::clone(&writer_acquired);

        // Hold two read guards simultaneously.
        let _read_guard_a = lock.read().unwrap();
        let _read_guard_b = lock.read().unwrap();

        // Spawn a writer while readers are still held.
        let handle = thread::spawn(move || {
            let _write_guard = lock_w.write().unwrap();
            writer_acquired_w.store(true, Ordering::SeqCst);
        });

        // Give the writer time to wake up and contend.
        thread::sleep(Duration::from_millis(50));
        assert!(
            !writer_acquired.load(Ordering::SeqCst),
            "writer acquired the lock while readers were still held"
        );

        // Release the readers.
        drop(_read_guard_a);
        drop(_read_guard_b);

        handle.join().unwrap();
        assert!(
            writer_acquired.load(Ordering::SeqCst),
            "writer should have acquired the lock after readers were released"
        );
    }

    #[test]
    fn test_set_entities_count_and_entity_use_layout_constants() {
        use crate::arena_layout::{
            DEFAULT_ENTITIES_OFFSET, ENTITIES_COUNT, ENTITIES_OFFSET, ENTITY_SLOT_SIZE,
        };

        let mut arena = vec![0u8; 1024 * 1024];
        let arena_start = arena.as_mut_ptr();

        // Initialise the minimal header fields used by the helpers without
        // spawning the background thread, so this test does not contend with the
        // lifecycle test over global engine state.
        ARENA_ADDRESS.store(arena_start as usize, Ordering::SeqCst);
        ARENA_SIZE.store(arena.len(), Ordering::SeqCst);
        unsafe {
            *(arena_start.add(ENTITIES_OFFSET) as *mut u32) = DEFAULT_ENTITIES_OFFSET;
            *(arena_start.add(ENTITIES_COUNT) as *mut u32) = 0;
        }

        // set_entities_count must write at the ENTITIES_COUNT offset.
        assert_eq!(set_entities_count(3), 0);
        unsafe {
            assert_eq!(
                *(arena.as_ptr().add(ENTITIES_COUNT) as *const u32),
                3,
                "ENTITIES_COUNT field mismatch"
            );
        }

        // set_entity must read the entities offset from ENTITIES_OFFSET and use
        // ENTITY_SLOT_SIZE for stride.
        assert_eq!(
            set_entity(
                1, 2, 0, 10.0, 20.0, 30.0, 40.0, 0xFF00FFCC, 1.0, -1.0, 0.0, 100.0, 0.0, 100.0,
                512,
            ),
            0
        );

        unsafe {
            let entities_offset = *(arena.as_ptr().add(ENTITIES_OFFSET) as *const u32) as usize;
            assert_eq!(entities_offset, DEFAULT_ENTITIES_OFFSET as usize);

            let entity_ptr = arena.as_ptr().add(entities_offset + ENTITY_SLOT_SIZE);
            assert_eq!(*entity_ptr, 2); // command_type
            assert_eq!(*(entity_ptr.add(1)), 0); // layer
            assert_eq!(*((entity_ptr.add(4)) as *const f32), 10.0); // x
            assert_eq!(*((entity_ptr.add(8)) as *const f32), 20.0); // y
            assert_eq!(*((entity_ptr.add(12)) as *const f32), 30.0); // width
            assert_eq!(*((entity_ptr.add(16)) as *const f32), 40.0); // height
            assert_eq!(*((entity_ptr.add(20)) as *const u32), 0xFF00FFCC); // color
            assert_eq!(*((entity_ptr.add(24)) as *const f32), 1.0); // speed_x
            assert_eq!(*((entity_ptr.add(28)) as *const f32), -1.0); // speed_y
        }

        ARENA_ADDRESS.store(0, Ordering::SeqCst);
        ARENA_SIZE.store(0, Ordering::SeqCst);
    }
}
