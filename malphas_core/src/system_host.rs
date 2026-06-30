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
use std::panic::catch_unwind;
use std::path::{Component, Path};
use std::sync::RwLock;

use libloading::{Library, Symbol};

use crate::integrity_policy::global_trust_anchor;
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
    tainted: bool,
}

static LOADED_SYSTEMS: RwLock<Vec<LoadedSystem>> = RwLock::new(Vec::new());

/// Error codes for system loading beyond the original -200..-203 range.
const ERR_SYSTEM_SANDBOX: i32 = -210;
const ERR_SYSTEM_SIGNATURE_MISSING: i32 = -211;
const ERR_SYSTEM_SIGNATURE_INVALID: i32 = -212;
const ERR_SYSTEM_INIT_PANIC: i32 = -213;

/// Returns true if `path` resolves under one of the approved roots and does
/// not escape via `..`.
fn is_path_allowed(path: &Path) -> bool {
    // Reject paths that explicitly walk upward before we canonicalise.
    for component in path.components() {
        if matches!(component, Component::ParentDir) {
            return false;
        }
    }

    let cwd = std::env::current_dir().unwrap_or_else(|_| Path::new(".").into());
    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    };

    let canonical = match std::fs::canonicalize(&candidate) {
        Ok(p) => p,
        // If the file does not exist yet, fall back to the non-canonical joined
        // path and still validate its logical structure.
        Err(_)
            if candidate
                .components()
                .all(|c| !matches!(c, Component::ParentDir)) =>
        {
            candidate
        }
        Err(_) => return false,
    };

    let allowed_roots = ["systems", "packages", "motors"];
    allowed_roots.iter().any(|root| {
        let root_path = canonical
            .ancestors()
            .find(|p| p.file_name().map(|n| n == *root).unwrap_or(false));
        root_path.map(|p| canonical.starts_with(p)).unwrap_or(false)
    })
}

/// Locate a sidecar Ed25519 signature file for `path`.
///
/// Tries `<path>.sig` first, then strips the extension and tries `<base>.sig`.
fn signature_path_for(path: &Path) -> Option<std::path::PathBuf> {
    let sidecar = path.with_extension(
        path.extension()
            .and_then(|e| e.to_str())
            .map_or_else(|| "sig".to_string(), |e| format!("{e}.sig")),
    );
    if sidecar.exists() {
        return Some(sidecar);
    }
    let base_sig = path.with_extension("sig");
    if base_sig.exists() {
        return Some(base_sig);
    }
    None
}

/// Load a `.mxc` dynamic library and register its `malphas_init_system` and
/// `malphas_tick` symbols.  If an MSP is already mapped, `init` is called
/// immediately so the system can build its internal SoA state.
pub fn load_system(path: &Path) -> Result<(), i32> {
    if !is_path_allowed(path) {
        return Err(ERR_SYSTEM_SANDBOX);
    }

    // Verify Ed25519 sidecar signature before loading any native code, unless
    // the debug-only `MALPHAS_INSECURE_SKIP_VERIFY` environment variable is set.
    let skip_verify = std::env::var_os("MALPHAS_INSECURE_SKIP_VERIFY").is_some();
    if !skip_verify {
        let sig_path = signature_path_for(path).ok_or(ERR_SYSTEM_SIGNATURE_MISSING)?;
        let signature_hex =
            std::fs::read_to_string(&sig_path).map_err(|_| ERR_SYSTEM_SIGNATURE_INVALID)?;
        if global_trust_anchor()
            .verify_ed25519_signature(path, &signature_hex)
            .is_err()
        {
            return Err(ERR_SYSTEM_SIGNATURE_INVALID);
        }
    }

    let lib = unsafe { Library::new(path).map_err(|_| -200)? };
    let init: Symbol<MalphasInitFn> =
        unsafe { lib.get(b"malphas_init_system\0").map_err(|_| -201)? };
    let tick: Symbol<MalphasTickFn> = unsafe { lib.get(b"malphas_tick\0").map_err(|_| -202)? };
    let init = *init;
    let tick = *tick;

    let system = LoadedSystem {
        _lib: lib,
        init,
        tick,
        tainted: false,
    };

    // Initialise the freshly loaded system against the current MSP, if any.
    let init_ok = crate::msp_loader::with_msp_map(|m| {
        let table = m.lookup_table_ptr();
        let count = m.entity_count();
        if !table.is_null() && count > 0 {
            let result = catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
                init(table, count)
            }));
            matches!(result, Ok(0))
        } else {
            true
        }
    })
    .unwrap_or(true);

    if !init_ok {
        return Err(ERR_SYSTEM_INIT_PANIC);
    }

    let mut guard = LOADED_SYSTEMS.write().map_err(|_| -203)?;
    guard.push(system);

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

    if let Ok(mut guard) = LOADED_SYSTEMS.write() {
        let mut base_offset = 0usize;
        for system in guard.iter_mut() {
            if system.tainted {
                continue;
            }
            if base_offset >= render_capacity as usize {
                break;
            }
            let remaining = render_capacity as usize - base_offset;
            let tick = system.tick;
            let tick_result = catch_unwind(std::panic::AssertUnwindSafe(move || unsafe {
                let mut written: u32 = 0;
                tick(
                    lookup_table,
                    entity_count,
                    dt_micros,
                    render_buffer.add(base_offset),
                    remaining as u32,
                    &mut written,
                );
                written
            }));
            let written = match tick_result {
                Ok(w) => w.min(remaining as u32),
                Err(_) => {
                    system.tainted = true;
                    0
                }
            };
            base_offset = base_offset.saturating_add(written as usize);
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
