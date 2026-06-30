// Hot-swappable Malphas eXecutable Core (.mxc) system host.
//
// The core loads dynamic libraries that export two symbols:
//
//   #[no_mangle]
//   pub extern "C" fn malphas_init_system(
//       lookup_table: *const *const u8,
//       entity_count: u32,
//   ) -> i32;
//
//   #[no_mangle]
//   pub extern "C" fn malphas_tick(
//       lookup_table: *const *const u8,
//       entity_count: u32,
//       dt_micros: u64,
//       render_buffer: *mut DartRenderCommand,
//       render_capacity: u32,
//       render_count: *mut u32,
//   );
//
// `malphas_init_system` is called once when the system is loaded so it can
// allocate its own flat SoA dynamic state from the read-only static payloads.
// `malphas_tick` receives the fresh Silver Platter every frame, mutates only
// its internal state, and writes render commands into the provided back buffer.

use std::ffi::{c_char, CStr};
use std::path::Path;
use std::sync::RwLock;

use libloading::{Library, Symbol};

use crate::pipeline::DartRenderCommand;

/// C-ABI signature exposed by every `.mxc` system for one-shot initialisation.
pub type MalphasInitFn =
    unsafe extern "C" fn(lookup_table: *const *const u8, entity_count: u32) -> i32;

/// C-ABI signature exposed by every `.mxc` system for the 120 FPS tick.
pub type MalphasTickFn = unsafe extern "C" fn(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
);

/// A loaded `.mxc` dynamic library and its resolved symbols.
#[allow(dead_code)]
pub struct LoadedSystem {
    _lib: Library,
    init: MalphasInitFn,
    tick: MalphasTickFn,
}

static LOADED_SYSTEMS: RwLock<Vec<LoadedSystem>> = RwLock::new(Vec::new());

/// Load a `.mxc` dynamic library and register its `malphas_init_system` and
/// `malphas_tick` symbols.  If an MSP is already mapped, `init` is called
/// immediately so the system can build its internal SoA state.
pub fn load_system(path: &Path) -> Result<(), i32> {
    let lib = unsafe { Library::new(path).map_err(|_| -200)? };
    let init: Symbol<MalphasInitFn> =
        unsafe { lib.get(b"malphas_init_system\0").map_err(|_| -201)? };
    let tick: Symbol<MalphasTickFn> = unsafe { lib.get(b"malphas_tick\0").map_err(|_| -202)? };
    let init = *init;
    let tick = *tick;

    let mut guard = LOADED_SYSTEMS.write().map_err(|_| -203)?;
    guard.push(LoadedSystem {
        _lib: lib,
        init,
        tick,
    });
    drop(guard);

    // Initialise the freshly loaded system against the current MSP, if any.
    crate::msp_loader::with_msp_map(|m| {
        let table = m.lookup_table_ptr();
        let count = m.entity_count();
        if !table.is_null() && count > 0 {
            unsafe {
                init(table, count);
            }
        }
    });

    Ok(())
}

/// Remove all loaded systems.  This unmaps the dynamic libraries.
pub fn clear_systems() {
    if let Ok(mut guard) = LOADED_SYSTEMS.write() {
        guard.clear();
    }
}

/// Invoke every loaded system with the current Silver Platter and render
/// buffer.  Each system writes into a consecutive slice of the buffer; the core
/// receives the final command count.
///
/// This is the only cross-library call in the hot path.  Systems must perform
/// no further FFI calls during their own execution loop.
pub fn tick_systems(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
) {
    if lookup_table.is_null()
        || render_buffer.is_null()
        || render_count.is_null()
        || entity_count == 0
    {
        unsafe {
            *render_count = 0;
        }
        return;
    }

    if let Ok(guard) = LOADED_SYSTEMS.read() {
        let mut base_offset = 0usize;
        for system in guard.iter() {
            let mut written: u32 = 0;
            unsafe {
                (system.tick)(
                    lookup_table,
                    entity_count,
                    dt_micros,
                    render_buffer.add(base_offset),
                    render_capacity.saturating_sub(base_offset as u32),
                    &mut written,
                );
            }
            base_offset += written as usize;
        }
        unsafe {
            *render_count = base_offset.min(render_capacity as usize) as u32;
        }
    } else {
        unsafe {
            *render_count = 0;
        }
    }
}

/// Number of systems currently loaded (useful for telemetry).
pub(crate) fn get_loaded_system_count_internal() -> u32 {
    LOADED_SYSTEMS
        .read()
        .ok()
        .map(|guard| guard.len() as u32)
        .unwrap_or(0)
}

fn c_str_to_path<'a>(ptr: *const c_char) -> Option<&'a Path> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok().map(Path::new) }
}

#[no_mangle]
pub extern "C" fn load_system_file(filepath: *const c_char) -> i32 {
    match c_str_to_path(filepath) {
        Some(path) => match load_system(path) {
            Ok(()) => 0,
            Err(code) => code,
        },
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn tick_loaded_systems(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
) {
    tick_systems(
        lookup_table,
        entity_count,
        dt_micros,
        render_buffer,
        render_capacity,
        render_count,
    );
}
