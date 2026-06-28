// Engine lifecycle internals, pulse synchronisation, FFI pointer helpers,
// and the 16-byte aligned allocator exposed to Dart.
use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use crate::input::INPUT_QUEUE;
use crate::pipeline::{
    process_engine_tick_internal, telemetry_now_micros, CoreCommandBuffer, DartRenderCommand,
    MalphasDoubleBufferBridge, ARENA_ADDRESS, ARENA_SIZE, BRIDGE_ADDRESS, ENGINE_PAUSED,
    ENGINE_RUNNING, LAST_PULSE_MICROS, MAX_COMMANDS_CAPACITY, RUNTIME,
};

/// Serialises `init_engine` re-initialisation so two FFI callers cannot race
/// to spawn overlapping simulation threads.
pub(crate) static INIT_LOCK: Mutex<()> = Mutex::new(());

/// Sender end of the single-clock pulse channel.  Flutter's Ticker pushes one
/// `()` message per vsync; the simulation thread blocks on `recv` between
/// ticks.  Dropping the sender (during shutdown) wakes the receiver so the
/// thread can exit cleanly.
static PULSE_SENDER: Mutex<Option<std::sync::mpsc::Sender<()>>> = Mutex::new(None);

/// Number of background simulation threads currently alive.
pub(crate) static ACTIVE_THREADS: AtomicUsize = AtomicUsize::new(0);

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
pub(crate) fn init_engine_internal(
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
        *arena_start.add(2) = b'L';
        *arena_start.add(3) = b'P';

        *(arena_start.add(4) as *mut u32) = 1024; // static_resources_offset
        *(arena_start.add(8) as *mut u32) = 0; // static_resources_size
        *(arena_start.add(12) as *mut u32) = 32; // entities_offset
        *(arena_start.add(16) as *mut u32) = 0; // entities_count
    }

    // 5. Create a fresh single-clock pulse channel for this session.
    let (pulse_tx, pulse_rx) = std::sync::mpsc::channel::<()>();
    if let Ok(mut guard) = PULSE_SENDER.lock() {
        *guard = Some(pulse_tx);
    }

    // 6. Start the background simulation thread.  It no longer has its own
    //    timer; Flutter drives every tick via `trigger_engine_pulse`.
    ENGINE_PAUSED.store(false, Ordering::SeqCst);
    ENGINE_RUNNING.store(true, Ordering::SeqCst);

    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<()>();
    ACTIVE_THREADS.fetch_add(1, Ordering::SeqCst);
    std::thread::spawn(move || {
        let _guard = ActiveThreadGuard;
        // Signal that we are alive and about to enter the event loop.  This
        // prevents `trigger_engine_pulse` from racing the worker startup.
        let _ = ready_tx.send(());

        while ENGINE_RUNNING.load(Ordering::SeqCst) {
            match pulse_rx.recv() {
                Ok(()) => {
                    if !ENGINE_RUNNING.load(Ordering::SeqCst) {
                        break;
                    }
                    if !ENGINE_PAUSED.load(Ordering::SeqCst) {
                        process_engine_tick_internal();
                    }
                }
                Err(_) => break,
            }
        }
    });

    // Block until the worker has entered its event loop.  Real callers never
    // pulse before `init_engine` returns, so this only costs one context
    // switch during app startup.
    let _ = ready_rx.recv();

    0
}

pub(crate) fn shutdown_engine_internal() -> i32 {
    let _init_guard = INIT_LOCK.lock();
    ENGINE_RUNNING.store(false, Ordering::SeqCst);
    // Drop the pulse sender so the simulation thread's `recv` returns an Err
    // and the thread exits without waiting for the next vsync pulse.
    if let Ok(mut guard) = PULSE_SENDER.lock() {
        *guard = None;
    }
    // Spin-wait (no sleep) until the background thread exits.
    while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
        std::thread::yield_now();
    }
    BRIDGE_ADDRESS.store(0, Ordering::SeqCst);
    ARENA_ADDRESS.store(0, Ordering::SeqCst);

    // By now the simulation thread has exited (ACTIVE_THREADS == 0), so no
    // reader can observe the old runtime. Swap it out and drop it.
    let old_ptr = RUNTIME.swap(std::ptr::null_mut(), Ordering::Acquire);
    if !old_ptr.is_null() {
        unsafe {
            drop(Box::from_raw(old_ptr));
        }
    }
    0
}

pub(crate) fn pause_engine_internal(paused: i32) -> i32 {
    ENGINE_PAUSED.store(paused != 0, Ordering::SeqCst);
    0
}

/// Trigger one engine tick from Flutter's Ticker (single-clock sync).
/// Sends one `()` message through the pulse channel.  If the simulation
/// thread is blocked on `recv` it wakes immediately; if it is busy the
/// message sits in the channel buffer until the next loop iteration.
pub(crate) fn trigger_engine_pulse_internal() -> i32 {
    if !ENGINE_RUNNING.load(Ordering::SeqCst) {
        return -1;
    }
    // Timestamp the pulse as early as possible so latency reflects the time
    // from Flutter's Ticker through the channel to the worker thread wake-up.
    LAST_PULSE_MICROS.store(telemetry_now_micros(), Ordering::Relaxed);
    match PULSE_SENDER.lock() {
        Ok(guard) => {
            if let Some(sender) = guard.as_ref() {
                if sender.send(()).is_ok() {
                    0
                } else {
                    -4
                }
            } else {
                -3 // channel not yet initialised
            }
        }
        Err(_) => -2,
    }
}

// ---------------------------------------------------------------------------
// Portable FFI pointer delegates.  Dart must never perform pointer arithmetic
// on the bridge layout or copy nested structs by value.
// ---------------------------------------------------------------------------
pub(crate) fn get_buffer_a_ptr(bridge: *mut MalphasDoubleBufferBridge) -> *mut CoreCommandBuffer {
    if bridge.is_null() {
        return std::ptr::null_mut();
    }
    // `addr_of_mut!` avoids creating an intermediate &mut to a struct that is
    // also observed from Dart.
    unsafe { std::ptr::addr_of_mut!((*bridge).buffer_a) }
}

pub(crate) fn get_buffer_b_ptr(bridge: *mut MalphasDoubleBufferBridge) -> *mut CoreCommandBuffer {
    if bridge.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { std::ptr::addr_of_mut!((*bridge).buffer_b) }
}

pub(crate) fn get_back_index(bridge: *mut MalphasDoubleBufferBridge) -> u8 {
    if bridge.is_null() {
        return 0;
    }
    unsafe { (*bridge).atomic_back_index.load(Ordering::Acquire) }
}

pub(crate) fn get_command_count(buffer: *const CoreCommandBuffer) -> u32 {
    if buffer.is_null() {
        return 0;
    }
    unsafe { (*buffer).command_count.load(Ordering::Acquire) }
}

pub(crate) fn get_commands_pointer(buffer: *const CoreCommandBuffer) -> *mut DartRenderCommand {
    if buffer.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { (*buffer).commands }
}

pub(crate) fn get_commands_written(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    if bridge.is_null() {
        return 0;
    }
    unsafe { (*bridge).commands_written.load(Ordering::Acquire) }
}

// ---------------------------------------------------------------------------
// Aligned native allocator exposed to Dart.  All shared buffers must go
// through this allocator to satisfy 16-byte alignment on ARM64.
// ---------------------------------------------------------------------------
pub(crate) fn malphas_alloc(size: usize) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    let layout = match std::alloc::Layout::from_size_align(size, 16) {
        Ok(l) => l,
        Err(_) => return std::ptr::null_mut(),
    };
    unsafe { std::alloc::alloc(layout) }
}

pub(crate) fn malphas_free(ptr: *mut u8, size: usize) {
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
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn test_aligned_allocator_round_trip() {
        let size = 1024usize;
        let ptr = malphas_alloc(size);
        assert!(!ptr.is_null());
        assert_eq!(
            ptr as usize % 16,
            0,
            "Allocator must return 16-byte aligned memory"
        );
        unsafe { std::ptr::write_bytes(ptr, 0xAB, size) };
        malphas_free(ptr, size);
    }

    #[test]
    fn test_active_thread_lifecycle() {
        let bridge = Arc::new(std::sync::Mutex::new(unsafe {
            std::mem::zeroed::<crate::pipeline::MalphasDoubleBufferBridge>()
        }));
        let mut arena = vec![0u8; 1024 * 1024];
        let bridge_ptr =
            &mut *bridge.lock().unwrap() as *mut crate::pipeline::MalphasDoubleBufferBridge;
        let arena_ptr = arena.as_mut_ptr() as *mut c_void;

        assert_eq!(
            crate::init_engine(bridge_ptr, arena_ptr, arena.len() as u32, 2048),
            0
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(ACTIVE_THREADS.load(Ordering::SeqCst) > 0);

        assert_eq!(crate::shutdown_engine(), 0);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
            assert!(
                std::time::Instant::now() < deadline,
                "Thread did not shut down"
            );
            std::thread::yield_now();
        }
    }
}
