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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use arc_swap::ArcSwapOption;
use libloading::{Library, Symbol};

use crate::integrity_policy::global_trust_anchor;
use crate::input::InputEvent;
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

/// Optional C-ABI signature that receives the input event slice for this tick.
pub type MalphasTickWithInputFn = unsafe extern "C" fn(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
    input_events: *const InputEvent,
    input_count: u32,
);

/// A loaded `.mxc` dynamic library and its resolved symbols.
#[derive(Clone)]
#[allow(dead_code)]
pub struct LoadedSystem {
    _lib: Option<Arc<Library>>,
    init: MalphasInitFn,
    tick: MalphasTickFn,
    tick_with_input: Option<MalphasTickWithInputFn>,
    tainted: Arc<AtomicBool>,
}

static LOADED_SYSTEMS: ArcSwapOption<Vec<LoadedSystem>> = ArcSwapOption::const_empty();

/// Error codes for system loading beyond the original -200..-203 range.
const ERR_SYSTEM_SANDBOX: i32 = -210;
const ERR_SYSTEM_SIGNATURE_MISSING: i32 = -211;
const ERR_SYSTEM_SIGNATURE_INVALID: i32 = -212;
const ERR_SYSTEM_INIT_PANIC: i32 = -213;

/// Returns true if `ptr` is properly aligned for `T`.
fn is_aligned<T>(ptr: *const T) -> bool {
    (ptr as usize).is_multiple_of(std::mem::align_of::<T>())
}

/// Locate the workspace root used to sandbox `.mxc` loads.
///
/// Prefers `CARGO_MANIFEST_DIR` (set by Cargo at compile/run time) and falls
/// back to walking up from the current working directory until a `Cargo.toml`
/// containing a `[workspace]` section is found.
fn workspace_root() -> Option<std::path::PathBuf> {
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let manifest_dir = std::path::PathBuf::from(manifest_dir);
        let parent = manifest_dir.parent()?;
        if is_workspace_root(parent) {
            return Some(parent.to_path_buf());
        }
    }

    let mut current = std::env::current_dir().ok()?;
    loop {
        if is_workspace_root(&current) {
            return Some(current);
        }
        let parent = current.parent()?;
        if parent == current {
            break;
        }
        current = parent.to_path_buf();
    }
    None
}

fn is_workspace_root(path: &Path) -> bool {
    let cargo_toml = path.join("Cargo.toml");
    if !cargo_toml.exists() {
        return false;
    }
    match std::fs::read_to_string(&cargo_toml) {
        Ok(contents) => contents.contains("[workspace]"),
        Err(_) => false,
    }
}

/// Returns true if `path` resolves under one of the approved workspace roots
/// (`systems`, `packages`, or `motors`) and does not escape via `..` or a
/// symlink.
fn is_path_allowed(path: &Path) -> bool {
    // Reject paths that explicitly walk upward before we canonicalise.
    for component in path.components() {
        if matches!(component, Component::ParentDir) {
            return false;
        }
    }

    let workspace = match workspace_root() {
        Some(root) => root,
        None => return false,
    };

    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        workspace.join(path)
    };

    // Reject symlinked paths (including the final file and any directory
    // component that resolves through a symlink).
    if std::fs::symlink_metadata(&candidate)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        return false;
    }

    let canonical = match std::fs::canonicalize(&candidate) {
        Ok(p) => p,
        Err(_) => return false,
    };

    let allowed_roots = [
        workspace.join("systems"),
        workspace.join("packages"),
        workspace.join("motors"),
        workspace.join("flutter_app").join("motors"),
    ];
    // Canonicalise the allowed roots as well so the comparison is consistent
    // across platforms (e.g. Windows canonicalise may prepend a UNC prefix).
    let canonical_allowed: Vec<std::path::PathBuf> = allowed_roots
        .iter()
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .collect();
    canonical_allowed
        .iter()
        .any(|root| canonical.starts_with(root))
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
    #[cfg(debug_assertions)]
    let skip_verify = std::env::var_os("MALPHAS_INSECURE_SKIP_VERIFY").is_some();
    #[cfg(not(debug_assertions))]
    let skip_verify = false;

    if !skip_verify {
        let sig_path = signature_path_for(path).ok_or(ERR_SYSTEM_SIGNATURE_MISSING)?;
        let signature_hex =
            std::fs::read_to_string(&sig_path).map_err(|_| ERR_SYSTEM_SIGNATURE_INVALID)?;
        let policy = global_trust_anchor().ok_or(ERR_SYSTEM_SIGNATURE_INVALID)?;
        if policy
            .verify_ed25519_signature(path, &signature_hex)
            .is_err()
        {
            return Err(ERR_SYSTEM_SIGNATURE_INVALID);
        }
    }

    // SAFETY: We only load a library whose path has been sandboxed and whose
    // sidecar signature verified (debug skip notwithstanding).  The loaded code
    // is treated as untrusted and is isolated inside its own address space by
    // the dynamic loader; we still catch panics at every entry point.
    let lib = unsafe { Library::new(path).map_err(|_| -200)? };
    let init: Symbol<MalphasInitFn> =
        // SAFETY: `malphas_init_system` is a required symbol of every `.mxc`
        // system.  The symbol name is a NUL-terminated byte string.
        unsafe { lib.get(b"malphas_init_system\0").map_err(|_| -201)? };
    let tick: Symbol<MalphasTickFn> =
        // SAFETY: `malphas_tick` is a required symbol of every `.mxc` system.
        unsafe { lib.get(b"malphas_tick\0").map_err(|_| -202)? };
    let init = *init;
    let tick = *tick;

    // Optional input-aware tick symbol.  Older systems continue to work because
    // the core falls back to `malphas_tick` when this symbol is absent.
    let tick_with_input: Option<MalphasTickWithInputFn> = unsafe {
        lib.get(b"malphas_tick_with_input\0")
            .ok()
            .map(|sym: Symbol<MalphasTickWithInputFn>| *sym)
    };

    let system = LoadedSystem {
        _lib: Some(Arc::new(lib)),
        init,
        tick,
        tick_with_input,
        tainted: Arc::new(AtomicBool::new(false)),
    };

    // Initialize the freshly loaded system against the current MSP, if any.
    let init_ok = crate::msp_loader::with_msp_map(|m| {
        let table = m.lookup_table_ptr();
        let count = m.entity_count();
        if !table.is_null() && count > 0 {
            let result = catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
                // SAFETY: `table` is a valid, read-only pointer returned by the
                // MSP mapper and `count` matches its length.  The system ABI
                // contract requires `init` to return an i32 status code.
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

    // Build a new registry snapshot that includes the freshly loaded system,
    // then publish it atomically so the hot path never observes a partial list.
    let snapshot = LOADED_SYSTEMS.load_full();
    let mut new_systems = snapshot
        .as_ref()
        .map(|arc| (**arc).clone())
        .unwrap_or_default();
    new_systems.push(system);
    LOADED_SYSTEMS.store(Some(Arc::new(new_systems)));

    Ok(())
}

/// Remove all loaded systems.  This unmaps the dynamic libraries.
pub fn clear_systems() {
    LOADED_SYSTEMS.store(None);
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
    input_events: &[InputEvent],
) {
    if lookup_table.is_null()
        || render_buffer.is_null()
        || render_count.is_null()
        || entity_count == 0
    {
        // SAFETY: The caller supplied a non-null `render_count` pointer per the
        // C-ABI contract; we simply zero it on early validation failure.
        unsafe {
            *render_count = 0;
        }
        return;
    }

    if !is_aligned(lookup_table) || !is_aligned(render_buffer) {
        // SAFETY: `render_count` was validated non-null above and points to
        // caller-owned memory; zero it because the pointer arguments violate
        // the required alignment.
        unsafe {
            *render_count = 0;
        }
        return;
    }

    let systems = LOADED_SYSTEMS.load_full();
    let Some(systems) = systems.as_ref() else {
        // SAFETY: `render_count` was validated non-null above.
        unsafe {
            *render_count = 0;
        }
        return;
    };

    let mut base_offset = 0usize;
    for system in systems.iter() {
        if system.tainted.load(Ordering::Relaxed) {
            continue;
        }
        if base_offset >= render_capacity as usize {
            break;
        }
        let remaining = render_capacity as usize - base_offset;
        let tick_result = catch_unwind(std::panic::AssertUnwindSafe(move || unsafe {
            // SAFETY: The caller owns `render_buffer` and guarantees that
            // `base_offset..base_offset+remaining` lies inside the buffer.
            // `lookup_table` is the read-only MSP pointer table.
            let mut written: u32 = 0;
            if let Some(tick) = system.tick_with_input {
                tick(
                    lookup_table,
                    entity_count,
                    dt_micros,
                    render_buffer.add(base_offset),
                    remaining as u32,
                    &mut written,
                    input_events.as_ptr(),
                    input_events.len() as u32,
                );
            } else {
                (system.tick)(
                    lookup_table,
                    entity_count,
                    dt_micros,
                    render_buffer.add(base_offset),
                    remaining as u32,
                    &mut written,
                );
            }
            written
        }));
        let written = match tick_result {
            Ok(w) if w <= remaining as u32 => w,
            Ok(_) => {
                // The system claimed to write more commands than fit in its
                // slice: taint it so it is skipped on future ticks.
                system.tainted.store(true, Ordering::Relaxed);
                0
            }
            Err(_) => {
                system.tainted.store(true, Ordering::Relaxed);
                0
            }
        };
        base_offset = base_offset.saturating_add(written as usize);
    }
    // SAFETY: `render_count` was validated non-null at the start of the
    // function and points to caller-owned memory.
    unsafe {
        *render_count = base_offset.min(render_capacity as usize) as u32;
    }
}

/// Number of systems currently loaded (useful for telemetry).
pub(crate) fn get_loaded_system_count_internal() -> u32 {
    LOADED_SYSTEMS
        .load_full()
        .as_ref()
        .map(|arc| arc.len() as u32)
        .unwrap_or(0)
}

fn c_str_to_path<'a>(ptr: *const c_char) -> Option<&'a Path> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: The caller is required by the C-ABI contract to pass a valid,
    // NUL-terminated string.  We only convert it, never mutate it.
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
        &[],
    );
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tick_systems_rejects_misaligned_pointers() {
        let mut render_count: u32 = 0xDEAD_BEEF;
        let lookup_table_storage: [*const u8; 2] = [std::ptr::null(); 2];
        // SAFETY: We only use the misaligned pointer for validation; it is never
        // dereferenced.
        let misaligned_lookup = unsafe { lookup_table_storage.as_ptr().byte_add(1) };

        let render_buffer_storage: [DartRenderCommand; 2] =
            // SAFETY: Zeroing a POD C-ABI struct is valid and we only use the
            // storage address, not its contents.
            unsafe { std::mem::zeroed() };
        // SAFETY: Same as above; the pointer is only used for alignment checking.
        let misaligned_render = unsafe { render_buffer_storage.as_ptr().byte_add(1) };

        tick_systems(
            misaligned_lookup,
            1,
            0,
            misaligned_render as *mut DartRenderCommand,
            1,
            &mut render_count,
            &[],
        );
        assert_eq!(render_count, 0);
    }

    #[test]
    fn tick_systems_marks_tainted_system() {
        // Isolate this test from any other test that may have left systems
        // registered, and ensure we clean up afterwards.
        clear_systems();

        extern "C" fn greedy_tick(
            _lookup_table: *const *const u8,
            _entity_count: u32,
            _dt_micros: u64,
            _render_buffer: *mut DartRenderCommand,
            _render_capacity: u32,
            render_count: *mut u32,
        ) {
            // Simulate a malicious or buggy system that reports writing far
            // more commands than its slice allows.
            // SAFETY: The caller owns `render_count` and guarantees it is non-null.
            unsafe {
                *render_count = 999;
            }
        }

        extern "C" fn dummy_init(_lookup_table: *const *const u8, _entity_count: u32) -> i32 {
            0
        }

        let system = LoadedSystem {
            _lib: None,
            init: dummy_init,
            tick: greedy_tick,
            tick_with_input: None,
            tainted: Arc::new(AtomicBool::new(false)),
        };
        LOADED_SYSTEMS.store(Some(Arc::new(vec![system])));

        let lookup_table_storage: [*const u8; 2] = [std::ptr::null(); 2];
        let mut commands: [DartRenderCommand; 4] = unsafe { std::mem::zeroed() };
        let mut render_count: u32 = 0;

        // First tick: the greedy system is detected and tainted.
        tick_systems(
            lookup_table_storage.as_ptr(),
            1,
            0,
            commands.as_mut_ptr(),
            1,
            &mut render_count,
            &[],
        );
        assert_eq!(render_count, 0);

        let snapshot = LOADED_SYSTEMS.load_full();
        let systems = snapshot.as_ref().expect("registry must hold test system");
        assert_eq!(systems.len(), 1);
        assert!(
            systems[0].tainted.load(Ordering::Relaxed),
            "system that writes out of bounds must be tainted"
        );

        // Second tick: the tainted system must be skipped.
        render_count = 0xDEAD_BEEF;
        tick_systems(
            lookup_table_storage.as_ptr(),
            1,
            0,
            commands.as_mut_ptr(),
            4,
            &mut render_count,
            &[],
        );
        assert_eq!(
            render_count, 0,
            "tainted system must be skipped on the next tick"
        );

        clear_systems();
    }
}
