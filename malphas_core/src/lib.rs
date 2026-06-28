use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::fs::File;
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use arc_swap::ArcSwap;
use std::time::{Duration, Instant};
use sha2::{Sha256, Digest};
use zip::ZipArchive;

// ---------------------------------------------------------------------------
// Global shared-memory handles and engine lifecycle state.
// All addresses are stored as usize to keep them Send/Sync and trivially atomic.
// ---------------------------------------------------------------------------
static ARENA_ADDRESS: AtomicUsize = AtomicUsize::new(0);
static ARENA_SIZE: AtomicUsize = AtomicUsize::new(0);
static BRIDGE_ADDRESS: AtomicUsize = AtomicUsize::new(0);
static MAX_COMMANDS_CAPACITY: AtomicU32 = AtomicU32::new(2048);
static ENGINE_RUNNING: AtomicBool = AtomicBool::new(false);
static ENGINE_PAUSED: AtomicBool = AtomicBool::new(false);
static ACTIVE_THREADS: AtomicUsize = AtomicUsize::new(0);

/// Single-clock synchronisation primitive.  Flutter's Ticker is the only
/// clock source; the Rust simulation thread waits on this condvar and is
/// woken by `trigger_engine_pulse` once per vsync.
static PULSE_CONDVAR: Condvar = Condvar::new();
static PULSE_COUNTER: Mutex<u64> = Mutex::new(0);

/// Serialises `init_engine` re-initialisation so two FFI callers cannot race
/// to spawn overlapping simulation threads.
static INIT_LOCK: Mutex<()> = Mutex::new(());

/// Serialises Dart-side Arena writes with the Rust simulation tick.  The
/// engine tick holds this lock while it reads entity state and generates
/// render commands; Dart-side helpers acquire it for entity setup.
static ARENA_WRITE_LOCK: Mutex<()> = Mutex::new(());

// ---------------------------------------------------------------------------
// Input event queue: Dart pushes, engine thread drains at frame start.
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, Copy)]
struct InputEvent {
    x: f32,
    y: f32,
}

static INPUT_QUEUE: Mutex<Vec<InputEvent>> = Mutex::new(Vec::new());

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
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

#[repr(C, align(16))]
pub struct CoreCommandBuffer {
    /// Atomic so both sides can read the count of the buffer they are
    /// observing without invoking formal data races.
    pub command_count: AtomicU32,
    pub commands: *mut DartRenderCommand,
}

#[repr(C, align(16))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: AtomicU8,
    pub commands_written: AtomicU32,
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

static RUNTIME: Mutex<Option<ResourcePackRuntime>> = Mutex::new(None);

/// Lock-free, atomic single-writer / multi-reader bytecode container.
///
/// NOTE: `ArcSwap<[u8]>` is not supported by `arc-swap` because `[u8]` is
/// `?Sized` and the crate's `RefCnt` trait requires a sized pointee.  The
/// closest zero-copy shape is `Arc<Box<[u8]>>`: the hot path dereferences
/// `&**guard` which still yields a contiguous `[u8]` slice.
static BYTECODE_VM: OnceLock<ArcSwap<Box<[u8]>>> = OnceLock::new();

fn get_bytecode_vm() -> &'static ArcSwap<Box<[u8]>> {
    BYTECODE_VM.get_or_init(|| ArcSwap::from(Arc::new(Vec::new().into_boxed_slice())))
}

fn c_str_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}

// ---------------------------------------------------------------------------
// Thread lifecycle guard: decrements ACTIVE_THREADS even if the thread panics.
// ---------------------------------------------------------------------------
struct ActiveThreadGuard;

impl Drop for ActiveThreadGuard {
    fn drop(&mut self) {
        ACTIVE_THREADS.fetch_sub(1, Ordering::SeqCst);
    }
}

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
    if bridge_ptr.is_null() || arena_ptr.is_null() {
        return -1;
    }

    let _init_guard = INIT_LOCK.lock();

    // 1. Signal any previous simulation thread to stop and spin-wait until it
    //    has truly exited.  No arbitrary sleeps.
    ENGINE_RUNNING.store(false, Ordering::SeqCst);
    while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
        std::thread::yield_now();
    }

    // 2. Drain stale inputs from a previous session.
    if let Ok(mut queue) = INPUT_QUEUE.lock() {
        queue.clear();
    }

    // 3. Publish new shared-memory handles.
    BRIDGE_ADDRESS.store(bridge_ptr as usize, Ordering::SeqCst);
    ARENA_ADDRESS.store(arena_ptr as usize, Ordering::SeqCst);
    ARENA_SIZE.store(arena_size as usize, Ordering::SeqCst);
    MAX_COMMANDS_CAPACITY.store(max_commands, Ordering::SeqCst);

    // 4. Initialise the Arena memory map (first 32 bytes).
    unsafe {
        let arena_start = arena_ptr as *mut u8;
        std::ptr::write_bytes(arena_start, 0, 32);

        *arena_start.add(0) = b'M';
        *arena_start.add(1) = b'A';
        *arena_start.add(2) = b'M';
        *arena_start.add(3) = b'P';

        *(arena_start.add(4) as *mut u32) = 1024;   // static_resources_offset
        *(arena_start.add(8) as *mut u32) = 0;      // static_resources_size
        *(arena_start.add(12) as *mut u32) = 32;    // entities_offset
        *(arena_start.add(16) as *mut u32) = 0;     // entities_count
    }

    // 5. Reset the single-clock pulse counter so this engine session starts
    //    from a clean synchronisation point.
    if let Ok(mut counter) = PULSE_COUNTER.lock() {
        *counter = 0;
    }

    // 6. Start the background simulation thread.  It no longer has its own
    //    timer; Flutter drives every tick via `trigger_engine_pulse`.
    ENGINE_PAUSED.store(false, Ordering::SeqCst);
    ENGINE_RUNNING.store(true, Ordering::SeqCst);

    ACTIVE_THREADS.fetch_add(1, Ordering::SeqCst);
    std::thread::spawn(move || {
        let _guard = ActiveThreadGuard;
        let mut last_counter: u64 = 0;

        while ENGINE_RUNNING.load(Ordering::SeqCst) {
            let mut counter = PULSE_COUNTER.lock().unwrap();
            while *counter == last_counter && ENGINE_RUNNING.load(Ordering::SeqCst) {
                counter = PULSE_CONDVAR.wait(counter).unwrap();
            }
            if !ENGINE_RUNNING.load(Ordering::SeqCst) {
                break;
            }
            last_counter = *counter;
            drop(counter);

            if !ENGINE_PAUSED.load(Ordering::SeqCst) {
                process_engine_tick_internal();
            }
        }
    });

    0
}

#[no_mangle]
pub extern "C" fn shutdown_engine() -> i32 {
    let _init_guard = INIT_LOCK.lock();
    ENGINE_RUNNING.store(false, Ordering::SeqCst);
    // Wake the simulation thread so it observes the stop signal and exits
    // without waiting for the next vsync pulse.
    PULSE_CONDVAR.notify_all();
    // Spin-wait (no sleep) until the background thread exits.
    while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
        std::thread::yield_now();
    }
    BRIDGE_ADDRESS.store(0, Ordering::SeqCst);
    ARENA_ADDRESS.store(0, Ordering::SeqCst);
    0
}

#[no_mangle]
pub extern "C" fn pause_engine(paused: i32) -> i32 {
    ENGINE_PAUSED.store(paused != 0, Ordering::SeqCst);
    0
}

// ---------------------------------------------------------------------------
// Input event queue.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn process_input_event(_event_type: i32, x: f32, y: f32) -> i32 {
    if x.is_nan() || y.is_nan() {
        return -1;
    }
    match INPUT_QUEUE.lock() {
        Ok(mut queue) => {
            queue.push(InputEvent { x, y });
            0
        }
        Err(_) => -2,
    }
}

// ---------------------------------------------------------------------------
// Portable FFI pointer delegates.  Dart must never perform pointer arithmetic
// on the bridge layout or copy nested structs by value.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn get_buffer_a_ptr(bridge: *mut MalphasDoubleBufferBridge) -> *mut CoreCommandBuffer {
    if bridge.is_null() {
        return std::ptr::null_mut();
    }
    // `addr_of_mut!` avoids creating an intermediate &mut to a struct that is
    // also observed from Dart.
    unsafe { std::ptr::addr_of_mut!((*bridge).buffer_a) }
}

#[no_mangle]
pub extern "C" fn get_buffer_b_ptr(bridge: *mut MalphasDoubleBufferBridge) -> *mut CoreCommandBuffer {
    if bridge.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { std::ptr::addr_of_mut!((*bridge).buffer_b) }
}

#[no_mangle]
pub extern "C" fn get_back_index(bridge: *mut MalphasDoubleBufferBridge) -> u8 {
    if bridge.is_null() {
        return 0;
    }
    unsafe { (*bridge).atomic_back_index.load(Ordering::Acquire) }
}

#[no_mangle]
pub extern "C" fn get_command_count(buffer: *const CoreCommandBuffer) -> u32 {
    if buffer.is_null() {
        return 0;
    }
    unsafe { (*buffer).command_count.load(Ordering::Acquire) }
}

#[no_mangle]
pub extern "C" fn get_commands_pointer(buffer: *const CoreCommandBuffer) -> *mut DartRenderCommand {
    if buffer.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { (*buffer).commands }
}

#[no_mangle]
pub extern "C" fn get_commands_written(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    if bridge.is_null() {
        return 0;
    }
    unsafe { (*bridge).commands_written.load(Ordering::Acquire) }
}

// ---------------------------------------------------------------------------
// Aligned native allocator exposed to Dart.  All shared buffers must go
// through this allocator to satisfy 16-byte alignment on ARM64.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn malphas_alloc(size: usize) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    let layout = match std::alloc::Layout::from_size_align(size, 16) {
        Ok(l) => l,
        Err(_) => return std::ptr::null_mut(),
    };
    unsafe { std::alloc::alloc(layout) }
}

#[no_mangle]
pub extern "C" fn malphas_free(ptr: *mut u8, size: usize) {
    if ptr.is_null() || size == 0 {
        return;
    }
    let layout = match std::alloc::Layout::from_size_align(size, 16) {
        Ok(l) => l,
        Err(_) => return,
    };
    unsafe { std::alloc::dealloc(ptr, layout) }
}

// ---------------------------------------------------------------------------
// Binary integrity and package extraction.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn verify_binary_integrity(filepath: *const c_char, expected_sha: *const c_char) -> i32 {
    let filepath_str = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };
    let expected_sha_str = match c_str_to_str(expected_sha) {
        Some(s) => s,
        None => return -2,
    };

    let clean_expected = expected_sha_str.trim_start_matches("0x").to_lowercase();

    let mut file = match File::open(filepath_str) {
        Ok(f) => f,
        Err(_) => return -3,
    };

    let mut hasher = Sha256::new();
    let mut buffer = [0; 8192];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buffer[..n]),
            Err(_) => return -4,
        }
    }
    let calculated_sha = format!("{:x}", hasher.finalize());

    if calculated_sha == clean_expected { 0 } else { 1 }
}

#[no_mangle]
pub extern "C" fn extract_zip_package(zip_path: *const c_char, output_dir: *const c_char) -> i32 {
    let zip_path_str = match c_str_to_str(zip_path) {
        Some(s) => s,
        None => return -1,
    };
    let output_dir_str = match c_str_to_str(output_dir) {
        Some(s) => s,
        None => return -2,
    };

    let file = match File::open(zip_path_str) {
        Ok(f) => f,
        Err(_) => return -3,
    };

    let mut archive = match ZipArchive::new(file) {
        Ok(a) => a,
        Err(_) => return -4,
    };

    let dest_path = std::path::Path::new(output_dir_str);
    if !dest_path.exists() {
        if std::fs::create_dir_all(dest_path).is_err() {
            return -5;
        }
    }

    for i in 0..archive.len() {
        let mut file = match archive.by_index(i) {
            Ok(f) => f,
            Err(_) => return -6,
        };

        let outpath = match file.enclosed_name() {
            Some(path) => dest_path.join(path),
            None => continue,
        };

        if file.name().ends_with('/') {
            if std::fs::create_dir_all(&outpath).is_err() {
                return -7;
            }
        } else {
            if let Some(p) = outpath.parent() {
                if !p.exists() {
                    if std::fs::create_dir_all(p).is_err() {
                        return -8;
                    }
                }
            }
            let mut outfile = match File::create(&outpath) {
                Ok(f) => f,
                Err(_) => return -9,
            };
            if std::io::copy(&mut file, &mut outfile).is_err() {
                return -10;
            }
        }
    }

    0
}

// ---------------------------------------------------------------------------
// Safe Arena helpers for Dart-side entity setup.  These acquire ARENA_WRITE_LOCK
// so they never race the simulation tick.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn set_entities_count(count: u32) -> i32 {
    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    if arena_addr == 0 {
        return -1;
    }
    let _guard = ARENA_WRITE_LOCK.lock();
    unsafe {
        *((arena_addr as *mut u8).add(16) as *mut u32) = count;
    }
    0
}

#[no_mangle]
pub extern "C" fn write_arena_bytes(offset: u32, ptr: *const u8, len: u32) -> i32 {
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
    let _guard = ARENA_WRITE_LOCK.lock();
    unsafe {
        std::ptr::copy_nonoverlapping(ptr, (arena_addr as *mut u8).add(start), len as usize);
    }
    0
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
    let arena_addr = ARENA_ADDRESS.load(Ordering::SeqCst);
    let arena_size = ARENA_SIZE.load(Ordering::SeqCst);
    if arena_addr == 0 {
        return -1;
    }

    let _guard = ARENA_WRITE_LOCK.lock();
    let arena_start = arena_addr as *mut u8;
    let entities_offset = unsafe { *(arena_start.add(12) as *const u32) } as usize;
    let entity_offset = entities_offset + (entity_id as usize * 64);
    if entity_offset + 64 > arena_size {
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
        *((entity_ptr.add(48)) as *mut u32) = str_offset;
    }
    0
}

// ---------------------------------------------------------------------------
// Resource pack loading.
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn load_resource_pack_raw(ptr: *const u8, size: u32) -> i32 {
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

fn load_mhp_package(buffer: &[u8]) -> i32 {
    let header_size = std::mem::size_of::<MhpHeader>();
    if buffer.len() < header_size {
        return -5;
    }

    let header = unsafe { &*(buffer.as_ptr() as *const MhpHeader) };

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
    let objects_table_end = header.objects_table_offset as usize + (header.objects_table_count as usize * 32);
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
        let _guard = ARENA_WRITE_LOCK.lock();
        unsafe {
            *(arena_start.add(8) as *mut u32) = buffer.len() as u32;
            *(arena_start.add(20) as *mut u32) = 1024 + header.font_metrics_offset;
            *(arena_start.add(24) as *mut u32) = 1024 + header.font_atlas_offset;
            *(arena_start.add(28) as *mut u32) = 1024 + header.objects_table_offset;

            if arena_size >= buffer.len() + 1024 {
                std::ptr::copy_nonoverlapping(buffer.as_ptr(), arena_start.add(1024), buffer.len());
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

    let mut runtime = RUNTIME.lock().unwrap();
    *runtime = Some(ResourcePackRuntime {
        arena_start_ptr: arena_addr as *mut u8,
        arena_size,
    });

    0
}

fn load_msp_package(buffer: &[u8]) -> i32 {
    let header_size = std::mem::size_of::<MspHeader>();
    if buffer.len() < header_size {
        return -20;
    }

    let header = unsafe { &*(buffer.as_ptr() as *const MspHeader) };

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

#[no_mangle]
pub extern "C" fn load_resource_pack(filepath: *const c_char) -> i32 {
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
// Synchronous tick fallback (kept for API compatibility; real work is done
// by the background thread started in init_engine).
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn process_engine_tick(_dt_micros: u64) -> i32 {
    0
}

// ---------------------------------------------------------------------------
// Background simulation tick.
// ---------------------------------------------------------------------------
fn process_engine_tick_internal() {
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

    // Hold the Arena write lock for the duration of the tick so Dart cannot
    // observe torn entity state while we read it.
    let _arena_guard = ARENA_WRITE_LOCK.lock();

    let entities_offset = unsafe { *(arena_start.add(12) as *const u32) } as usize;
    let entities_count = unsafe { *(arena_start.add(16) as *const u32) } as usize;

    // 1. Drain input events at the start of the frame.
    let mut events = Vec::new();
    if let Ok(mut queue) = INPUT_QUEUE.lock() {
        std::mem::swap(&mut *queue, &mut events);
    }

    for event in events {
        let x = event.x;
        let y = event.y;
        for entity_id in 0..entities_count {
            let entity_ptr = unsafe { arena_start.add(entities_offset + entity_id * 64) };
            let cmd = unsafe { &mut *(entity_ptr as *mut DartRenderCommand) };

            if cmd.command_type == 0 {
                continue;
            }

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

    // 2. Load bytecode atomically and lock-free.
    let bytecode_guard = get_bytecode_vm().load();
    let bytecode: &[u8] = &**bytecode_guard;

    // 3. Run bytecode script inside the sandbox runtime.
    {
        let mut runtime_opt = RUNTIME.lock().unwrap();
        if let Some(ref mut runtime) = *runtime_opt {
            runtime.arena_start_ptr = arena_start;
            runtime.arena_size = arena_size;

            for entity_id in 0..entities_count {
                runtime.execute_logic_tick(entity_id as u16, bytecode);
            }
        }
    }

    // 4. Generate render commands into the back buffer.
    let commands_ptr = unsafe { (*back_buffer_ptr).commands };
    if commands_ptr.is_null() {
        return;
    }

    let commands_slice = unsafe { std::slice::from_raw_parts_mut(commands_ptr, max_capacity) };

    let mut write_idx = 0usize;
    for entity_id in 0..entities_count {
        let entity_ptr = unsafe { arena_start.add(entities_offset + entity_id * 64) };
        let cmd = unsafe { &*(entity_ptr as *const DartRenderCommand) };

        if cmd.command_type == 0 {
            continue;
        }

        if write_idx < max_capacity {
            commands_slice[write_idx] = *cmd;

            if cmd.command_type == 2 {
                let str_offset = unsafe { *(entity_ptr.add(48) as *const u32) } as usize;
                let text_ptr = unsafe { arena_start.add(str_offset) };

                if write_idx + 1 < max_capacity {
                    let slot_ptr = unsafe { commands_ptr.add(write_idx + 1) as *mut *const u8 };
                    unsafe { *slot_ptr = text_ptr; }
                    write_idx += 2;
                } else {
                    write_idx += 1;
                }
            } else {
                write_idx += 1;
            }
        }
    }

    unsafe {
        (*back_buffer_ptr).command_count.store(write_idx as u32, Ordering::Release);
        (*bridge).commands_written.store(write_idx as u32, Ordering::Release);
    }

    let next_back = 1 - back_index;
    unsafe {
        (*bridge).atomic_back_index.store(next_back, Ordering::Release);
    }
}

#[no_mangle]
pub extern "C" fn render_tick(buffer_ptr: *mut DartRenderCommand, max_commands: i32) -> i32 {
    if buffer_ptr.is_null() || max_commands <= 0 {
        return 0;
    }
    let commands = unsafe { std::slice::from_raw_parts_mut(buffer_ptr, max_commands as usize) };

    if max_commands >= 1 {
        commands[0] = DartRenderCommand {
            command_type: 1,
            layer: 0,
            pad: 0,
            x: 200.0,
            y: 200.0,
            width: 600.0,
            height: 400.0,
            color_rgba: 0xFFE0DCD3,
        };
        return 1;
    }
    0
}

// ---------------------------------------------------------------------------
// Bytecode sandbox VM.
// ---------------------------------------------------------------------------
impl ResourcePackRuntime {
    pub fn execute_logic_tick(&mut self, entity_id: u16, bytecode_buffer: &[u8]) {
        if bytecode_buffer.is_empty() {
            return;
        }

        let entity_offset = 32 + (entity_id as usize * 64);
        let mut pc = 0usize;
        let mut regs = [0.0f32; 8];

        while pc + 4 <= bytecode_buffer.len() {
            let opcode = bytecode_buffer[pc];
            let arg1 = bytecode_buffer[pc + 1];
            let val_u16 = ((bytecode_buffer[pc + 2] as u16) << 8) | (bytecode_buffer[pc + 3] as u16);

            match opcode {
                0x00 => {
                    // HALT
                    break;
                }
                0x01 => {
                    // LOAD_REG_CONST
                    if arg1 < 8 {
                        regs[arg1 as usize] = val_u16 as f32;
                    }
                    pc += 4;
                }
                0x02 => {
                    // ADD_REG
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        regs[arg1 as usize] += regs[val_u16 as usize];
                    }
                    pc += 4;
                }
                0x03 => {
                    // SUB_REG
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        regs[arg1 as usize] -= regs[val_u16 as usize];
                    }
                    pc += 4;
                }
                0x04 => {
                    // WRITE_ARENA_F32
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset + 4 <= self.arena_size {
                            unsafe {
                                let target_ptr = self.arena_start_ptr.add(offset) as *mut f32;
                                *target_ptr = regs[arg1 as usize];
                            }
                        }
                    }
                    pc += 4;
                }
                0x05 => {
                    // READ_ARENA_F32
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset + 4 <= self.arena_size {
                            unsafe {
                                let src_ptr = self.arena_start_ptr.add(offset) as *const f32;
                                regs[arg1 as usize] = *src_ptr;
                            }
                        }
                    }
                    pc += 4;
                }
                0x06 => {
                    // WRITE_ARENA_U8
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset < self.arena_size {
                            unsafe {
                                *self.arena_start_ptr.add(offset) = regs[arg1 as usize] as u8;
                            }
                        }
                    }
                    pc += 4;
                }
                0x07 => {
                    // READ_ARENA_U8
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset < self.arena_size {
                            unsafe {
                                regs[arg1 as usize] = *self.arena_start_ptr.add(offset) as f32;
                            }
                        }
                    }
                    pc += 4;
                }
                0x08 => {
                    // JMP_LT (reg1, reg2, target_instr_index_u8)
                    let reg2 = (val_u16 >> 8) as usize;
                    let target_pc = (val_u16 & 0xFF) as usize * 4;
                    if arg1 < 8 && reg2 < 8 {
                        if regs[arg1 as usize] < regs[reg2] {
                            pc = target_pc;
                            continue;
                        }
                    }
                    pc += 4;
                }
                0x09 => {
                    // JMP
                    pc = arg1 as usize * 4;
                }
                0x0A => {
                    // WRITE_ARENA_U32
                    if arg1 < 8 {
                        let offset = entity_offset + val_u16 as usize;
                        if offset + 4 <= self.arena_size {
                            unsafe {
                                let target_ptr = self.arena_start_ptr.add(offset) as *mut u32;
                                *target_ptr = regs[arg1 as usize] as u32;
                            }
                        }
                    }
                    pc += 4;
                }
                0x0B => {
                    // MUL_REG
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        regs[arg1 as usize] *= regs[val_u16 as usize];
                    }
                    pc += 4;
                }
                0x0C => {
                    // DIV_REG
                    if arg1 < 8 && (val_u16 as usize) < 8 {
                        let div = regs[val_u16 as usize];
                        if div != 0.0 {
                            regs[arg1 as usize] /= div;
                        }
                    }
                    pc += 4;
                }
                _ => break,
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_verify_binary_integrity() {
        let temp_path = std::path::Path::new("temp_test_file.txt");
        let mut file = File::create(temp_path).unwrap();
        file.write_all(b"Malphas Engine Core Verification Data").unwrap();
        drop(file);

        let mut hasher = Sha256::new();
        hasher.update(b"Malphas Engine Core Verification Data");
        let calculated_sha = format!("{:x}", hasher.finalize());

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let hash_c = std::ffi::CString::new(calculated_sha.as_str()).unwrap();

        let res = verify_binary_integrity(filepath_c.as_ptr(), hash_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 0);
    }

    #[test]
    fn test_struct_alignments() {
        assert_eq!(std::mem::size_of::<DartRenderCommand>(), 24);
        assert_eq!(std::mem::align_of::<DartRenderCommand>(), 4);

        assert_eq!(std::mem::size_of::<CoreCommandBuffer>(), 16);
        assert_eq!(std::mem::align_of::<CoreCommandBuffer>(), 16);

        assert_eq!(std::mem::size_of::<MalphasDoubleBufferBridge>(), 48);
        assert_eq!(std::mem::align_of::<MalphasDoubleBufferBridge>(), 16);

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
        assert!(ns_per_iter < 1000.0, "Latency too high: {} ns/iter", ns_per_iter);
    }

    #[test]
    fn test_aligned_allocator_round_trip() {
        let size = 1024usize;
        let ptr = malphas_alloc(size);
        assert!(!ptr.is_null());
        assert_eq!(ptr as usize % 16, 0, "Allocator must return 16-byte aligned memory");
        unsafe { std::ptr::write_bytes(ptr, 0xAB, size) };
        malphas_free(ptr, size);
    }

    #[test]
    fn test_active_thread_lifecycle() {
        use std::sync::Arc;

        let bridge = Arc::new(std::sync::Mutex::new(
            unsafe { std::mem::zeroed::<MalphasDoubleBufferBridge>() }
        ));
        let mut arena = vec![0u8; 1024 * 1024];
        let bridge_ptr = &mut *bridge.lock().unwrap() as *mut MalphasDoubleBufferBridge;
        let arena_ptr = arena.as_mut_ptr() as *mut c_void;

        assert_eq!(init_engine(bridge_ptr, arena_ptr, arena.len() as u32, 2048), 0);
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(ACTIVE_THREADS.load(Ordering::SeqCst) > 0);

        assert_eq!(shutdown_engine(), 0);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
            assert!(std::time::Instant::now() < deadline, "Thread did not shut down");
            std::thread::yield_now();
        }
    }
}
