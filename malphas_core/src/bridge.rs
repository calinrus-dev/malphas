// Engine lifecycle internals, pulse synchronisation, FFI pointer delegates,
// and the 64-byte aligned allocator exposed to Dart.
use std::alloc::Layout;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};

use crate::msp_loader::unload_msp;
use crate::pipeline::{
    allocate_bridge, free_bridge, process_engine_tick_internal, telemetry_now_micros,
    DartRenderCommand, MalphasDoubleBufferBridge, TextPayload, ENGINE_PAUSED, ENGINE_RUNNING,
    LAST_PULSE_MICROS,
};
use crate::system_host::clear_systems;

/// Serialises `init_engine` re-initialisation so two FFI callers cannot race
/// to spawn overlapping simulation threads.
pub(crate) static INIT_LOCK: Mutex<()> = Mutex::new(());

/// Sender end of the single-clock pulse channel.  Flutter's Ticker pushes one
/// `()` message per vsync; the simulation thread blocks on `recv` between
/// ticks.  Dropping the sender (during shutdown) wakes the receiver so the
/// thread can exit cleanly.  The channel is bounded to one pending pulse.
static PULSE_SENDER: Mutex<Option<std::sync::mpsc::SyncSender<()>>> = Mutex::new(None);

/// Registry of layouts allocated through `malphas_alloc`.  The key is the
/// pointer address returned to the caller.  This lets `malphas_free` deallocate
/// with the exact layout used at allocation time, regardless of what size the
/// caller claims.
static LAYOUT_REGISTRY: OnceLock<Mutex<HashMap<usize, Layout>>> = OnceLock::new();

fn layout_registry() -> &'static Mutex<HashMap<usize, Layout>> {
    LAYOUT_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Number of background simulation threads currently alive.
pub(crate) static ACTIVE_THREADS: AtomicUsize = AtomicUsize::new(0);

/// Condvar used to wake `shutdown_engine_internal` when the simulation thread
/// exits, replacing the previous spin-wait.
static SHUTDOWN_CONDVAR: Condvar = Condvar::new();
static SHUTDOWN_MUTEX: Mutex<()> = Mutex::new(());

// ---------------------------------------------------------------------------
// Thread lifecycle guard: decrements ACTIVE_THREADS even if the thread panics.
// ---------------------------------------------------------------------------
struct ActiveThreadGuard;

impl Drop for ActiveThreadGuard {
    fn drop(&mut self) {
        ACTIVE_THREADS.fetch_sub(1, Ordering::SeqCst);
        // Wake the shutdown waiter if it is parked on the condvar.  A lost
        // notification is harmless: the waiter rechecks ACTIVE_THREADS after a
        // short timeout.
        SHUTDOWN_CONDVAR.notify_one();
    }
}

// ---------------------------------------------------------------------------
// Engine lifecycle.
// ---------------------------------------------------------------------------
/// Returns true if `ptr` is properly aligned for `T`.
fn is_aligned<T>(ptr: *const T) -> bool {
    (ptr as usize).is_multiple_of(std::mem::align_of::<T>())
}

/// Wait for all active simulation threads to exit, using the shutdown condvar
/// to avoid busy-waiting.  A timeout prevents an infinite wait if a thread is
/// stuck.
fn wait_for_active_threads_to_exit(timeout: std::time::Duration) {
    let start = std::time::Instant::now();
    match SHUTDOWN_MUTEX.lock() {
        Ok(mut guard) => {
            while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
                let remaining = timeout.saturating_sub(start.elapsed());
                if remaining.is_zero() {
                    break;
                }
                match SHUTDOWN_CONDVAR.wait_timeout(guard, remaining) {
                    Ok((g, _)) => guard = g,
                    Err(_) => break,
                }
            }
        }
        Err(_) => {
            // Lock poisoned: fall back to a short, bounded sleep instead of a
            // busy-wait.  This path is defensive and should never run in tests.
            while ACTIVE_THREADS.load(Ordering::SeqCst) > 0 {
                if start.elapsed() >= timeout {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        }
    }
}

pub(crate) fn init_engine_internal(max_commands: u32) -> *mut MalphasDoubleBufferBridge {
    if max_commands == 0 {
        return std::ptr::null_mut();
    }

    let _init_guard = match INIT_LOCK.lock() {
        Ok(g) => g,
        Err(_) => return std::ptr::null_mut(),
    };

    // Drain stale input events from any previous session so a freshly started
    // engine does not process touches that arrived while it was offline.
    let _ = crate::input::drain_input_events();

    // 1. Signal any previous simulation thread to stop and wait efficiently
    //    (with a timeout safety net) until it has truly exited.
    ENGINE_RUNNING.store(false, Ordering::SeqCst);
    wait_for_active_threads_to_exit(std::time::Duration::from_secs(5));

    // 2. Free any previous bridge owned by Rust.
    free_bridge();

    // 3. Allocate a new bridge and command buffers from Rust.
    let bridge_ptr = match allocate_bridge(max_commands) {
        Some(p) => p,
        None => return std::ptr::null_mut(),
    };

    // 4. Create a fresh single-clock pulse channel for this session.  The
    //    channel is bounded to one pending pulse so a fast Ticker cannot
    //    enqueue unbounded work ahead of a slow simulation thread.
    let (pulse_tx, pulse_rx) = std::sync::mpsc::sync_channel::<()>(1);
    match PULSE_SENDER.lock() {
        Ok(mut guard) => {
            *guard = Some(pulse_tx);
        }
        Err(_) => {
            // Lock poisoned: free the newly allocated bridge and return null so
            // the caller does not receive a dangling, un-owned pointer.
            free_bridge();
            return std::ptr::null_mut();
        }
    }

    // 5. Start the background simulation thread.  It no longer has its own
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

    bridge_ptr
}

pub(crate) fn shutdown_engine_internal() -> i32 {
    let _init_guard = match INIT_LOCK.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    ENGINE_RUNNING.store(false, Ordering::SeqCst);
    // Drop the pulse sender so the simulation thread's `recv` returns an Err
    // and the thread exits without waiting for the next vsync pulse.
    if let Ok(mut guard) = PULSE_SENDER.lock() {
        *guard = None;
    }
    // Wait efficiently for the background thread to exit.
    wait_for_active_threads_to_exit(std::time::Duration::from_secs(5));

    // By now the simulation thread has exited (ACTIVE_THREADS == 0), so no
    // reader can observe the old state.  Free the bridge/buffers owned by Rust,
    // then drop the mapped MSP and loaded systems.
    free_bridge();
    unload_msp();
    clear_systems();
    0
}

pub(crate) fn pause_engine_internal(paused: i32) -> i32 {
    ENGINE_PAUSED.store(paused != 0, Ordering::SeqCst);
    0
}

/// Trigger one engine tick from Flutter's Ticker (single-clock sync).
/// Sends one `()` message through the bounded pulse channel.  If the
/// simulation thread is blocked on `recv` it wakes immediately; if a pulse is
/// already pending, the stale pulse is conceptually replaced by the new one
/// (the latest timestamp has already been recorded in `LAST_PULSE_MICROS`).
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
                match sender.try_send(()) {
                    Ok(()) => 0,
                    Err(std::sync::mpsc::TrySendError::Full(())) => {
                        // A stale pulse is already pending.  The worker will
                        // process it using the most recent timestamp stored
                        // above, which is equivalent to dropping the stale
                        // pulse and sending the new one for a unit pulse.
                        0
                    }
                    Err(std::sync::mpsc::TrySendError::Disconnected(())) => -4,
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
pub(crate) fn get_buffer_a_commands(
    bridge: *mut MalphasDoubleBufferBridge,
) -> *mut DartRenderCommand {
    if bridge.is_null() || !is_aligned(bridge) {
        return std::ptr::null_mut();
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    unsafe { (*bridge).buffer_a_commands }
}

pub(crate) fn get_buffer_b_commands(
    bridge: *mut MalphasDoubleBufferBridge,
) -> *mut DartRenderCommand {
    if bridge.is_null() || !is_aligned(bridge) {
        return std::ptr::null_mut();
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    unsafe { (*bridge).buffer_b_commands }
}

pub(crate) fn get_buffer_a_command_count(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    if bridge.is_null() || !is_aligned(bridge) {
        return 0;
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    unsafe { (*bridge).buffer_a_command_count.load(Ordering::Acquire) }
}

pub(crate) fn get_buffer_b_command_count(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    if bridge.is_null() || !is_aligned(bridge) {
        return 0;
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    unsafe { (*bridge).buffer_b_command_count.load(Ordering::Acquire) }
}

pub(crate) fn get_back_index(bridge: *mut MalphasDoubleBufferBridge) -> u8 {
    if bridge.is_null() || !is_aligned(bridge) {
        return 0;
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    unsafe { (*bridge).atomic_back_index.load(Ordering::Acquire) }
}

pub(crate) fn get_commands_written(bridge: *mut MalphasDoubleBufferBridge) -> u32 {
    if bridge.is_null() || !is_aligned(bridge) {
        return 0;
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    unsafe { (*bridge).commands_written.load(Ordering::Acquire) }
}

/// Returns a consistent snapshot of the front buffer: the buffer opposite to
/// `atomic_back_index`.  The returned tuple is `(front_index, front_count,
/// front_commands_pointer)`.  Both the index and the count are read with
/// Acquire ordering so they synchronise with the Release stores performed by
/// the simulation thread after a tick.
pub(crate) fn get_front_buffer_snapshot(
    bridge: *mut MalphasDoubleBufferBridge,
) -> (u8, u32, *mut DartRenderCommand) {
    if bridge.is_null() || !is_aligned(bridge) {
        return (0, 0, std::ptr::null_mut());
    }
    // SAFETY: `bridge` was validated to be non-null and aligned above.
    let back_index = unsafe { (*bridge).atomic_back_index.load(Ordering::Acquire) };
    let front_index = if back_index == 0 { 1 } else { 0 };
    // SAFETY: `bridge` was validated above; the front buffer pointer and count
    // are read with Acquire ordering to synchronise with the writer thread.
    unsafe {
        if front_index == 0 {
            (
                front_index,
                (*bridge).buffer_a_command_count.load(Ordering::Acquire),
                (*bridge).buffer_a_commands,
            )
        } else {
            (
                front_index,
                (*bridge).buffer_b_command_count.load(Ordering::Acquire),
                (*bridge).buffer_b_commands,
            )
        }
    }
}

/// Decodes the `TextPayload` pointer embedded in the `width`/`height` union
/// fields of a text render command.
pub(crate) fn get_text_payload_pointer(command: *const DartRenderCommand) -> *const TextPayload {
    if command.is_null() || !is_aligned(command) {
        return std::ptr::null();
    }
    // SAFETY: `command` was validated to be non-null and aligned above, so the
    // dereference is sound for the C-ABI struct.
    unsafe {
        if (*command).cmd_type != 2 {
            return std::ptr::null();
        }
        let low = (*command).width.to_bits() as u64;
        let high = (*command).height.to_bits() as u64;
        let address = (high << 32) | low;
        if address == 0 {
            return std::ptr::null();
        }
        let ptr = address as *const TextPayload;
        if ptr.is_null() || !is_aligned(ptr) {
            return std::ptr::null();
        }
        // SAFETY: This is a best-effort validation.  The decoded address is
        // non-null and aligned for `TextPayload`, but the full process address
        // space is not tracked, so the caller must still ensure the pointer is
        // valid before dereferencing it.
        ptr
    }
}

// ---------------------------------------------------------------------------
// Aligned native allocator exposed to Dart.  All shared buffers must go
// through this allocator to satisfy 64-byte alignment.
// ---------------------------------------------------------------------------
pub(crate) fn malphas_alloc(size: usize) -> *mut u8 {
    if size == 0 {
        return std::ptr::null_mut();
    }
    let layout = match Layout::from_size_align(size, 64) {
        Ok(l) => l,
        Err(_) => return std::ptr::null_mut(),
    };
    // SAFETY: `layout` has a non-zero size and a valid power-of-two alignment.
    let ptr = unsafe { std::alloc::alloc(layout) };
    if !ptr.is_null() {
        match layout_registry().lock() {
            Ok(mut guard) => {
                guard.insert(ptr as usize, layout);
            }
            Err(_) => {
                // Lock poisoned: free the freshly allocated pointer with the
                // original layout and return null.  We must not hand back an
                // unregistered pointer that `malphas_free` could not safely
                // deallocate later.
                // SAFETY: `ptr` was allocated with `layout` immediately above,
                // so `dealloc` matches the allocator contract.
                unsafe { std::alloc::dealloc(ptr, layout) };
                return std::ptr::null_mut();
            }
        }
    }
    ptr
}

pub(crate) fn malphas_free(ptr: *mut u8, _size: usize) {
    if ptr.is_null() {
        return;
    }
    let layout = match layout_registry().lock() {
        Ok(mut guard) => guard.remove(&(ptr as usize)),
        Err(_) => {
            // Lock poisoned: we cannot verify the original layout, so we must
            // not deallocate.  The pointer is intentionally leaked, which is
            // safer than invoking undefined behaviour with a mismatched layout.
            return;
        }
    };
    if let Some(layout) = layout {
        // SAFETY: `ptr` came from the registry entry for the exact `layout`
        // returned by `malphas_alloc`, so it matches the allocator contract.
        unsafe { std::alloc::dealloc(ptr, layout) }
    }
    // If the pointer is not in the registry we refuse to deallocate: the caller
    // passed either a foreign pointer or a size/layout mismatch.
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    /// Serialise engine-lifecycle tests because they mutate global state
    /// (`ENGINE_RUNNING`, `ACTIVE_THREADS`, `BRIDGE_STATE`, etc.).
    static LIFECYCLE_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn test_aligned_allocator_round_trip() {
        let size = 1024usize;
        let ptr = malphas_alloc(size);
        assert!(!ptr.is_null());
        assert_eq!(
            ptr as usize % 64,
            0,
            "Allocator must return 64-byte aligned memory"
        );
        // SAFETY: `ptr` was allocated with at least `size` writable bytes.
        unsafe { std::ptr::write_bytes(ptr, 0xAB, size) };
        malphas_free(ptr, size);
    }

    #[test]
    fn test_active_thread_lifecycle() {
        let _guard = LIFECYCLE_TEST_LOCK.lock().unwrap();
        let bridge_ptr = crate::init_engine(2048);
        assert!(!bridge_ptr.is_null());
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

    #[test]
    fn test_init_engine_rejects_zero_commands() {
        // Zero commands is invalid; the engine must refuse to start.
        assert!(crate::init_engine(0).is_null());
    }

    #[test]
    fn test_pointer_delegates_reject_misaligned_and_null() {
        // SAFETY: Zeroing a POD C-ABI struct is valid; we only read its address.
        let mut bridge =
            unsafe { std::mem::zeroed::<crate::pipeline::MalphasDoubleBufferBridge>() };
        let bridge_ptr: *mut crate::pipeline::MalphasDoubleBufferBridge = &mut bridge;
        // SAFETY: The misaligned pointer is only used for validation, never
        // dereferenced.
        let misaligned_bridge = unsafe { bridge_ptr.byte_add(1) };

        assert!(get_buffer_a_commands(std::ptr::null_mut()).is_null());
        assert!(get_buffer_a_commands(misaligned_bridge).is_null());
        assert!(get_buffer_b_commands(misaligned_bridge).is_null());
        assert_eq!(get_buffer_a_command_count(std::ptr::null_mut()), 0);
        assert_eq!(get_buffer_a_command_count(misaligned_bridge), 0);
        assert_eq!(get_buffer_b_command_count(misaligned_bridge), 0);
        assert_eq!(get_back_index(misaligned_bridge), 0);
        assert_eq!(get_commands_written(misaligned_bridge), 0);
    }

    #[test]
    fn test_get_text_payload_pointer_requires_text_command() {
        // SAFETY: Zeroing a POD C-ABI struct is valid; we fill in the fields
        // before use.
        let mut rect_cmd = unsafe { std::mem::zeroed::<crate::pipeline::DartRenderCommand>() };
        rect_cmd.cmd_type = 1;
        rect_cmd.width = f32::from_bits(0x12345678);
        rect_cmd.height = f32::from_bits(0x9ABCDEF0);
        assert!(get_text_payload_pointer(&rect_cmd).is_null());

        // SAFETY: Same as above.
        let mut text_cmd = unsafe { std::mem::zeroed::<crate::pipeline::DartRenderCommand>() };
        text_cmd.cmd_type = 2;
        text_cmd.width = f32::from_bits(0x12345678);
        text_cmd.height = f32::from_bits(0x9ABCDEF0);
        let decoded = get_text_payload_pointer(&text_cmd);
        assert!(!decoded.is_null());
        assert_eq!(
            decoded as usize,
            ((0x9ABCDEF0u64 as usize) << 32) | 0x12345678
        );
    }

    #[test]
    fn test_get_text_payload_pointer_rejects_misaligned_address() {
        // SAFETY: Zeroing a POD C-ABI struct is valid; we fill in the fields
        // before use.
        let mut text_cmd = unsafe { std::mem::zeroed::<crate::pipeline::DartRenderCommand>() };
        text_cmd.cmd_type = 2;
        // Encode address 0x0000_0000_0000_0001, which is non-null but not
        // 4-byte aligned.
        text_cmd.width = f32::from_bits(0x0000_0001);
        text_cmd.height = f32::from_bits(0x0000_0000);
        assert!(get_text_payload_pointer(&text_cmd).is_null());

        // Encode address 0x0000_0000_0000_0002, also misaligned.
        text_cmd.width = f32::from_bits(0x0000_0002);
        assert!(get_text_payload_pointer(&text_cmd).is_null());

        // Encode address 0x0000_0000_0000_0004, which is non-null and aligned.
        text_cmd.width = f32::from_bits(0x0000_0004);
        let decoded = get_text_payload_pointer(&text_cmd);
        assert!(!decoded.is_null());
        assert_eq!(decoded as usize, 4);
    }

    #[test]
    fn test_front_buffer_snapshot_returns_consistent_front() {
        let bridge_ptr = crate::pipeline::allocate_bridge(16).expect("bridge must allocate");
        assert!(!bridge_ptr.is_null());

        // SAFETY: `bridge_ptr` is a valid bridge returned by `allocate_bridge`.
        unsafe {
            (*bridge_ptr).atomic_back_index.store(0, Ordering::Release);
            (*bridge_ptr)
                .buffer_a_command_count
                .store(5, Ordering::Release);
            (*bridge_ptr)
                .buffer_b_command_count
                .store(7, Ordering::Release);
        }

        let (front_index, front_count, front_ptr) = get_front_buffer_snapshot(bridge_ptr);
        assert_eq!(front_index, 1);
        assert_eq!(front_count, 7);
        // SAFETY: `bridge_ptr` is valid.
        unsafe {
            assert_eq!(front_ptr, (*bridge_ptr).buffer_b_commands);
        }

        // SAFETY: `bridge_ptr` is valid.
        unsafe {
            (*bridge_ptr).atomic_back_index.store(1, Ordering::Release);
        }
        let (front_index2, front_count2, front_ptr2) = get_front_buffer_snapshot(bridge_ptr);
        assert_eq!(front_index2, 0);
        assert_eq!(front_count2, 5);
        // SAFETY: `bridge_ptr` is valid.
        unsafe {
            assert_eq!(front_ptr2, (*bridge_ptr).buffer_a_commands);
        }

        crate::pipeline::free_bridge();
    }

    #[test]
    fn test_shutdown_does_not_hang() {
        let _guard = LIFECYCLE_TEST_LOCK.lock().unwrap();
        let bridge_ptr = crate::init_engine(256);
        assert!(!bridge_ptr.is_null());
        // Give the worker time to enter its event loop.
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(ACTIVE_THREADS.load(Ordering::SeqCst) > 0);

        let start = std::time::Instant::now();
        assert_eq!(crate::shutdown_engine(), 0);
        let elapsed = start.elapsed();
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "shutdown hung for {:?}",
            elapsed
        );
        assert_eq!(ACTIVE_THREADS.load(Ordering::SeqCst), 0);
    }
}
