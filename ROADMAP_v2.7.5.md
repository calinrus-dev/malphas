# Malphas v2.7.5 — "Fortress" Master Implementation Plan

> Status: **implemented** as of tag `v2.7.5`. This document is kept as a historical record of the hardening effort.
>
> Goal: transform Malphas v2.7.0 into a sovereign, hardened, and deterministically predictable runtime: memory-safe across the FFI boundary, cryptographically verifiable supply chain, race-free engine lifecycle, and a Flutter/Core ecosystem aligned to the byte.

---

## 1. Design Principles for v2.7.5

1. **Ownership is never ambiguous.** If Rust reads memory, Rust controls its lifetime or has a verifiable contractual guarantee.
2. **Zero-copy is preserved, but never at the cost of safety.** The Silver Platter remains a flat array; only the way its snapshot is pinned during a tick changes.
3. **Every native binary is signed code.** Engine, `.msp`, and `.mxc` must pass Ed25519 + SHA-256 verification before being touched.
4. **Fail-safe by default.** Any malformed input, path traversal, overflowing system, or poorly synchronized hot-swap must degrade gracefully, never corrupt memory.
5. **Measurable determinism.** `dt`, counters, alignment, and ABI are explicit, versioned, and auditable contracts.
6. **CI is the guardian.** `cargo clippy --all-targets -- -D warnings`, `cargo test`, `flutter analyze/test` must all pass.

---

## 2. Architectural Changes (Summary)

```text
Before (v2.7.0)                         After (v2.7.5)
─────────────────────────────────       ─────────────────────────────────
MSP_MAP: RwLock<Option<MspMap>>   →     MSP_MAP: ArcSwapOption<MspMap>
                                         + MspSnapshot held for entire tick
MSP: MmapMut (writable)           →     MSP: Mmap (read-only)
Bridge: raw pointer from Dart     →     BridgeHandle: Arc<BridgeState>
                                         Rust allocates/frees bridge+buffers
Buffer ptrs: *mut raw             →     immutable after init / atomic
MXC load: dlopen direct           →     verify sig+hash → Library::new
MSP checksum: partial XOR         →     SHA-256/BLAKE2 over signed file
panic = "abort"                   →     panic = "unwind" + catch_unwind
```

---

## 3. Implementation Phases

### Phase 0 — Foundation: Memory Safety and Engine Lifecycle

This phase is **blocking**. Without it, everything else is lipstick on a crash.

#### 0.1 MSP Snapshot with `arc-swap`

- **Files:** `malphas_core/src/msp_loader.rs`, `malphas_core/src/pipeline.rs`
- **Changes:**
  - Replace `static MSP_MAP: RwLock<Option<MspMap>>` with `static MSP_MAP: arc_swap::ArcSwapOption<MspMap>`.
  - `load_msp`/`refresh_msp` build `Arc::new(mmap)` and call `store(Some(arc))`.
  - `process_engine_tick_internal` calls `let snapshot = MSP_MAP.load_full();` at the start and **keeps the `Arc` alive until the end of the tick**.
  - `unload_msp` calls `store(None)`; the last in-flight tick keeps the old `Arc` alive.
- **Gain:** eliminates Silver Platter UAF during `refresh_msp`/`unload_msp`.

#### 0.2 Read-Only MSP

- **Files:** `malphas_core/src/msp_loader.rs`
- **Changes:**
  - Open file with `OpenOptions::new().read(true)`.
  - Use `memmap2::MmapOptions::map(&file)` instead of `MmapMut::map_mut`.
  - Remove the requirement/comment about systems mutating payloads in place.
- **Gain:** systems cannot persist corruption; loading from read-only assets works.

#### 0.3 Bridge Ownership by Rust

- **Files:** `malphas_core/src/pipeline.rs`, `malphas_core/src/bridge.rs`, `malphas_core/src/lib.rs`, `flutter_app/lib/core/ffi/malphas_bindings.dart`
- **Changes:**
  - Create `pub(crate) struct BridgeState` containing:
    - `buffer_a: *mut DartRenderCommand` + `buffer_b: *mut DartRenderCommand`
    - `capacity: u32`
    - `back_index: AtomicU8`
    - `command_counts: [AtomicU32; 2]`
    - `commands_written: AtomicU32`
    - `abi_version: u32`
  - `init_engine` **allocates bridge + buffers internally** with `Layout::from_size_align(..., 64)` and returns the pointer to Dart.
  - `shutdown_engine` frees everything (buffers, bridge) using the layout cookie registry.
  - Dart stops allocating bridge/buffers with `malphas_alloc`; it only receives the pointer and passes it to `init_engine`.
- **Note:** this breaks the old API. Add `abi_version: 0x02070500` at the start of the bridge to detect incompatibility.
- **Gain:** eliminates bridge UAF and buffer pointer races.

#### 0.4 `malphas_alloc/free` with Layout Cookie

- **Files:** `malphas_core/src/bridge.rs`, `flutter_app/lib/core/ffi/malphas_bindings.dart`
- **Changes:**
  - Keep `static LAYOUT_REGISTRY: Mutex<HashMap<usize, Layout>>`.
  - `malphas_alloc(size)` registers `(ptr, Layout::from_size_align(size, 64))` and returns `ptr`.
  - Change C signature to `malphas_free(ptr: *mut u8)` (no `size`) or `malphas_free(ptr, cookie)`.
  - `malphas_free` looks up the layout in the registry; if missing, return an error/-1 instead of deallocating with a wrong layout.
- **Gain:** eliminates layout-mismatch UB.

#### 0.5 Panic Isolation

- **Files:** `Cargo.toml`, `malphas_core/src/system_host.rs`
- **Changes:**
  - Remove `panic = "abort"` from the workspace `release` profile.
  - Wrap `init(...)` in `load_system` with `catch_unwind`.
  - Wrap each `(system.tick)(...)` call in `tick_systems` with `catch_unwind`.
  - If a system panics, mark it as tainted, never call it again, and continue with the others.
- **Gain:** a buggy/malicious system does not kill the app.

---

### Phase 1 — Supply-Chain Security

#### 1.1 Centralized Integrity Policy

- **Files:** `malphas_core/src/crypto.rs` (new module `integrity_policy.rs`)
- **Changes:**
  - Define `pub struct IntegrityPolicy` with Ed25519 trust anchor + SHA-256.
  - Functions `verify_file(path, expected_sha)`, `verify_signature(path, sig_hex, pk_hex)`.
  - Constant-time comparison with `subtle::ConstantTimeEq`.
  - `verify_engine_signature` reads files with a size limit and streams the hash.

#### 1.2 MSP Signing and Load-Time Verification

- **Files:** `malphas_cli/src/compiler.rs`, `malphas_cli/src/main.rs`, `malphas_core/src/msp_loader.rs`
- **Changes:**
  - `compile` generates `.msp` and, if a key is provided, `.msp.sig`.
  - Key via `--sign-key-file <path>` or `MALPHAS_SIGNING_KEY` env var (never argv).
  - `load_msp_file` looks for `.msp.sig` and verifies against the trust anchor before mmap.
  - Strict mode: reject MSP without a valid signature.

#### 1.3 MXC Signing and Verification Before `dlopen`

- **Files:** `malphas_core/src/system_host.rs`
- **Changes:**
  - `load_system(path)` first verifies `.mxc.sig` (or `.so.sig`/`.dll.sig`) and hash.
  - Reject unexpected extensions.
  - Sandbox: `is_path_allowed` rejects absolute paths, `..`, and requires paths under approved directories (`systems/`, `packages/`, `motors/`).

#### 1.4 ZIP Hardening

- **Files:** `malphas_core/src/crypto.rs`
- **Changes:**
  - Limit total uncompressed size (e.g. 1 GB) and ratio (e.g. 100:1).
  - Limit number of entries (e.g. 10k).
  - Reject symlinks and hardlinks.
  - Verify `enclosed_name()` and that it resolves inside `output_dir`.

---

### Phase 2 — Robust Runtime

#### 2.1 Safe `tick_systems`

- **Files:** `malphas_core/src/system_host.rs`
- **Changes:**
  - `base_offset` with explicit bounds checks.
  - `remaining = render_capacity.saturating_sub(base_offset as u32)`.
  - After each tick, verify `written <= remaining`; if not, mark the system as tainted and stop.
  - `*render_count = base_offset.min(render_capacity as usize) as u32`.

#### 2.2 Real `dt_micros` Calculation

- **Files:** `malphas_core/src/pipeline.rs`, `malphas_core/src/bridge.rs`
- **Changes:**
  - Store `last_tick_micros`.
  - `dt_micros = now.saturating_sub(last_tick).min(MAX_DT_MICROS)` (e.g. 1_000_000).
  - Pass the real `dt_micros` to `tick_systems`.

#### 2.3 Lock-Free Input Queue

- **Files:** `malphas_core/src/input.rs`, `malphas_core/src/pipeline.rs`
- **Changes:**
  - Implement a ring buffer with `AtomicUsize` head/tail (or `crossbeam-array-queue`).
  - Validate `event_type` against a known enum and reject `NaN`/`Inf`.
  - Drain the queue at the start of `process_engine_tick_internal`.

#### 2.4 Safe MSP Alignment and Reading

- **Files:** `malphas_core/src/msp_loader.rs`
- **Changes:**
  - Read header and descriptors with `std::ptr::read_unaligned`.
  - Validate that `payload_offset` is a multiple of 64.
  - Validate strict section ordering: `entity_table_offset >= header_size`, `payload_section_offset >= entity_table_end`.

---

### Phase 3 — Flutter / Dart

#### 3.1 Aligned FFI Lifecycle

- **Files:** `flutter_app/lib/core/ffi/malphas_bindings.dart`, `flutter_app/lib/core/ffi/types.dart`, `flutter_app/lib/features/engine_manager/engine_controller.dart`
- **Changes:**
  - Adapt `initEngine()` to the new model: no bridge/buffer allocation, receives pointer from Rust.
  - Always call `shutdownEngine()` before `reloadNativeLibrary`.
  - `reloadNativeLibrary`: shutdown → close lib → open new → init.
  - Add `abi_version` at the start of `MalphasDoubleBufferBridge` in Dart and verify it.

#### 3.2 Correct MSP Parser

- **Files:** `flutter_app/lib/features/package_manager/package_controller.dart`
- **Changes:**
  - Read `pack_id` from header offset 32-47 (new field) or, if kept outside, read from manifest.
  - `entity_table_offset` at offset 8, `entity_count` at offset 12.
  - Add bounds checks and reject malformed packages.

#### 3.3 Valid `createAndCompilePackage`

- **Files:** `flutter_app/lib/features/package_manager/package_controller.dart`, `flutter_app/lib/core/compiler/package_compiler.dart`
- **Changes:**
  - Generate a `payload_file` per entity (write a `.bin` per payload in the package).
  - `strippedManifest` must contain only `pack_id` + `entities` with `entity_id`, `tag_mask`, `payload_file`.
  - Remove `canvas_width/height` from the manifest sent to the CLI.

#### 3.4 Path Sandbox and Public Key

- **Files:** `flutter_app/lib/features/package_manager/package_config_screen.dart`, `flutter_app/lib/features/engine_manager/engine_controller.dart`
- **Changes:**
  - Validate workspace root: canonicalize and reject if outside an allowed base directory.
  - Load public key from asset or config, not hardcoded.

#### 3.5 Android

- **Files:** `flutter_app/android/app/src/main/AndroidManifest.xml`, `build.sh`, `flutter_app/android/app/src/main/jniLibs/...`
- **Changes:**
  - Include `libmalphas_core.so` for `arm64-v8a`, `armeabi-v7a`, `x86_64`.
  - Remove `MANAGE_EXTERNAL_STORAGE`; use `getApplicationDocumentsDirectory`.

---

### Phase 4 — CLI and MSP Format

#### 4.1 MSP Header v2.5 (Minimal Extension)

- **Files:** `malphas_cli/src/compiler.rs`, `malphas_core/src/msp_loader.rs`
- **Changes:**
  - Add `pack_id: [u8; 16]` to the header at bytes 32-47 (replaces part of the padding).
  - Bump `MSP_VERSION` to `3` to reflect the change.
  - Update serialization/deserialization.

#### 4.2 Header Integrity

- **Files:** `malphas_cli/src/compiler.rs`, `malphas_core/src/msp_loader.rs`
- **Changes:**
  - Checksum/signature covers **the entire file except the signature itself**.
  - Migrate checksum to SHA-256; keep XOR only as an optional fast integrity check.

#### 4.3 Path Traversal in Payloads

- **Files:** `malphas_cli/src/compiler.rs`, `malphas_cli/src/manifest.rs`
- **Changes:**
  - Validate that `payload_file` contains no `..`, is not absolute, and resolves inside the workspace.

#### 4.4 Secure CLI Signing

- **Files:** `malphas_cli/src/main.rs`
- **Changes:**
  - `sign <file> --key-file <path>` or `MALPHAS_SIGNING_KEY` env var.
  - Remove private-key positional argument.

#### 4.5 Dependency Cleanup

- **Files:** `malphas_cli/Cargo.toml`, `malphas_core/Cargo.toml`
- **Changes:**
  - Remove `fontdue` from CLI if unused.
  - Use `arc-swap` in core or remove it.
  - Update `zip` to 2.x.

---

### Phase 5 — CI/CD and Quality

#### 5.1 Strict Clippy

- **Files:** `.github/workflows/rust_ci.yml`
- **Changes:**
  - `cargo clippy --release --all-targets -- -D warnings`.
  - Fix the current 4 errors (`arc_with_non_send_sync`, `manual_div_ceil`, `manual_slice_size_calculation`, `slow_vector_initialization`).

#### 5.2 Version Sync

- **Files:** `.github/workflows/flutter_ci.yml`
- **Changes:**
  - Read version with `cargo metadata --format-version 1 | jq -r '.packages[] | select(.name=="malphas_core") | .version'`.

#### 5.3 Secrets

- **Files:** `.github/workflows/rust_ci.yml`, `.github/workflows/android_build.yml`
- **Changes:**
  - `TEST_SIGNING_KEY` as environment variable, never as argument.
  - Sign `.mxc` in CI too.

#### 5.4 Security Tests

- **Files:** `malphas_core/tests/security_tests.rs` (new), `malphas_cli/tests/...`
- **Tests to add:**
  - MSP with corrupted header → rejected.
  - MSP with overlapping offsets → rejected.
  - `.mxc` without signature → rejected.
  - System writing `written = u32::MAX` → does not write outside the buffer.
  - `refresh_msp` during tick → no UAF (threaded harness).
  - ZIP bomb/symlink → rejected.
  - `malphas_free` with wrong size → does not corrupt heap.

---

### Phase 6 — Documentation

- **Files:** `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `AGENTS.md` (if applicable)
- **Changes:**
  - Document the threat model: what the runtime verifies, what it trusts from Dart, what it does not.
  - FFI contract: who allocates, who frees, when `shutdown` is safe.
  - Migration guide from v2.7.0 to v2.7.5.

---

## 4. Actionable TODO List

### Phase 0 — Memory Safety / Lifecycle
- [x] 0.1 Replace `RwLock<Option<MspMap>>` with `ArcSwapOption<MspMap>` in `msp_loader.rs`.
- [x] 0.2 Hold `Arc<MspMap>` snapshot for the entire `process_engine_tick_internal`.
- [x] 0.3 Switch MSP to read-only `Mmap` in `msp_loader.rs`.
- [x] 0.4 Design `BridgeState` with `Arc` and Rust ownership.
- [x] 0.5 Change `init_engine` to allocate bridge+buffers internally.
- [x] 0.6 Change `shutdown_engine` to free bridge+buffers from Rust.
- [x] 0.7 Make buffer pointers immutable after init (or atomic).
- [x] 0.8 Implement layout registry for `malphas_alloc/free`.
- [x] 0.9 Remove `panic = "abort"` from root `Cargo.toml`.
- [x] 0.10 Add `catch_unwind` in `load_system::init` and `tick_systems`.

### Phase 1 — Integrity
- [x] 1.1 Create `integrity_policy.rs` module with constant-time comparison.
- [x] 1.2 Modify `verify_binary_integrity` to use `subtle`.
- [x] 1.3 Add size limit and streaming hash to `verify_engine_signature`.
- [x] 1.4 Add automatic MSP signing to `malphas-cli compile`.
- [x] 1.5 Verify MSP signature in `load_msp_file`.
- [x] 1.6 Verify MXC signature before `Library::new`.
- [x] 1.7 Implement path sandbox in `load_system`.
- [x] 1.8 Harden `extract_zip_package`.

### Phase 2 — Runtime
- [x] 2.1 Make `tick_systems` clamp-safe against excessive `written`.
- [x] 2.2 Calculate real `dt_micros` with maximum clamp.
- [x] 2.3 Implement lock-free input ring buffer and consume it in tick.
- [x] 2.4 Read header/descriptors with `read_unaligned`.
- [x] 2.5 Validate MSP section alignment and ordering.

### Phase 3 — Flutter
- [x] 3.1 Adapt `malphas_bindings.dart` to the new lifecycle.
- [x] 3.2 Implement safe hot-swap (shutdown → reload → init).
- [x] 3.3 Add `abi_version` to bridge and verify it.
- [x] 3.4 Fix MSP parser in `package_controller.dart`.
- [x] 3.5 Fix `createAndCompilePackage` to generate a valid manifest.
- [x] 3.6 Load public key from asset/config.
- [x] 3.7 Validate workspace root path (sandbox).
- [x] 3.8 Include `.so` in Android jniLibs and clean up permissions.

### Phase 4 — CLI
- [x] 4.1 Add `pack_id` to header and bump `MSP_VERSION`.
- [x] 4.2 Make checksum/signature cover header+body.
- [x] 4.3 Validate `payload_file` against path traversal.
- [x] 4.4 Change CLI sign to `--key-file` / env var.
- [x] 4.5 Escape `pack_id` in `bindings_codegen.rs`.
- [x] 4.6 Remove dead dependencies and update `zip`.

### Phase 5 — CI/CD
- [x] 5.1 Make `cargo clippy --all-targets -- -D warnings` pass.
- [x] 5.2 Fix version-sync in `flutter_ci.yml`.
- [x] 5.3 Use environment variable for `TEST_SIGNING_KEY`.
- [x] 5.4 Sign `.mxc` in CI.
- [x] 5.5 Add security tests to the workflow.
- [x] 5.6 Resolve duplicate artifact upload in `release.yml`.

### Phase 6 — Documentation
- [x] 6.1 Update `README.md` with new architecture and contracts.
- [x] 6.2 Add migration guide to `CHANGELOG.md`.
- [x] 6.3 Document threat model in `CONTRIBUTING.md`.

---

## 5. Acceptance Criteria for v2.7.5

- [x] `cargo fmt -- --check` passes.
- [x] `cargo clippy --release --all-targets -- -D warnings` passes.
- [x] `cargo test --release --locked` passes, including new security tests.
- [x] `flutter analyze --no-fatal-infos` passes.
- [x] `flutter test` passes.
- [x] No MSP is mapped in writable mode.
- [x] No `.mxc` or engine is loaded without a valid Ed25519 signature.
- [x] `valgrind` / Miri / AddressSanitizer report no UAF/UB in integration tests where applicable.
- [x] Hot-swap leaves no orphan threads or old library handles.
- [x] Dead dependencies removed and `cargo tree` audited.

---

## 6. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Changing bridge ownership breaks old apps | Bump ABI version; update Dart bindings; document breaking change. |
| `catch_unwind` adds overhead on hot path | Only wraps init/load; tick is already native; overhead is negligible compared to FFI. |
| Mandatory signing frustrates local development | Allow `--insecure-skip-verify` in debug builds, explicit and with warnings. |
| `ArcSwap` introduces contention | `load_full()` is lock-free; the `Arc` is cloned once per tick. |
| Android `.so` increases app size | Optional: download verified ABI on first launch. |

---

## 8. Completion Notes

- All implementation phases were finished and tagged as `v2.7.5`.
- The security integration test suite covers unsigned MSPs, malformed signatures, wrong-key signatures, unsigned systems, sandbox path traversal, and wrong-key system signatures.
- Panic isolation via `catch_unwind` works for panics originating inside the same Rust module. On Windows, unwinding across a dynamically loaded Rust `.dll` aborts the process, so full cross-DLL panic isolation is not currently enforced. A future improvement would run systems in a separate worker process.
- The default trust anchor remains test-only. Production builds must override it with `setTrustAnchor` / `set_trust_anchor`.

## 7. Definition of "Engineering Art"

For v2.7.5, it is not enough that it compiles. The project will be mature when:

1. **Every `unsafe` has a written, verifiable contract.**
2. **Every loaded binary has an auditable trust chain.**
3. **Every race condition is eliminated by design, not by sleeps.**
4. **Every FFI error translates into a negative error code, never a crash.**
5. **CI is more paranoid than the developer.**
6. **Documentation allows a new contributor to understand why every line is safe.**

That is the north star.
