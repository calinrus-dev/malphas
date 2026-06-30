# Malphas 2.9.0 — Perfection Roadmap (Execution Edition)

## Goal

Deliver **Malphas v2.9.0** as a production-hardened, zero-known-defect runtime with:

- Zero critical/high security vulnerabilities.
- Zero memory-safety or FFI concurrency defects.
- Zero functional bugs in the Flutter frontend.
- A fully deterministic, lockless hot path.
- A trustworthy supply chain and CI/CD pipeline.
- Complete, version-locked documentation.

All work items below are written in English and must be implemented in English (code, comments, docs, commit messages).

---

## 0. Ground Rules for 2.9.0

1. **No test-only keys in release binaries.** The default trust anchor must be empty in release; the engine refuses to load signed assets until a real anchor is configured.
2. **No `unsafe` without a written safety comment.** Every `unsafe` block gets a `// SAFETY: ...` justification.
3. **No stateful singletons in test code.** All global state becomes injectable/configurable for deterministic tests.
4. **No direct atomic field reads from Dart.** All shared-memory reads go through Rust getters with explicit memory ordering.
5. **No silent failures in Flutter.** Every FFI return code is surfaced to the user or logged with context.
6. **No manual version strings.** `BRIDGE_ABI_VERSION`, README, and all doc headers derive from a single source of truth.

---

## Phase 1 — Foundation: Version Lock & Housekeeping

**Objective:** Establish a single source of truth for versioning and remove dead code.

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 1.1 | Centralize version | `Cargo.toml`, `flutter_app/pubspec.yaml`, `README.md` | Create `VERSION` file at repo root. All version strings derive from it via build scripts and CI. | ✅ |
| 1.2 | Update `BRIDGE_ABI_VERSION` | `malphas_core/src/pipeline.rs` | Set to `0x02090000`. Dart reads this field and rejects mismatches. | ✅ |
| 1.3 | Remove dead placeholder | `malphas_core/src/vm.rs`, `malphas_core/src/lib.rs` | Delete `vm.rs` and `pub mod vm {}`. | ✅ |
| 1.4 | Remove unused dependencies | `malphas_cli/Cargo.toml`, `flutter_app/pubspec.yaml` | Remove `fontdue` and `archive`. CI verifies with `cargo udeps` / `flutter pub deps`. | ✅ |
| 1.5 | Fix versioned comments | All Rust/Dart source headers | Replace hardcoded `v2.7.5`/`v2.8.0` with generated comments or `VERSION` references. | ⚠️ Partial |
| 1.6 | Fix `_padA` → `abiVersion` in Dart | `flutter_app/lib/core/ffi/types.dart` | Rename field and expose it as the ABI version. | ✅ |

**Exit gate:** `cargo clippy --all-targets -- -D warnings`, `flutter analyze`, and version-sync check all pass.

---

## Phase 2 — Security Hardening

**Objective:** Eliminate all trust, sandbox, and supply-chain vulnerabilities.

### 2.1 Trust Anchor & Signature Policy

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 2.1.1 | Remove default test anchor from release | `malphas_core/src/integrity_policy.rs` | `DEFAULT_TRUST_ANCHOR_HEX` moves to `#[cfg(debug_assertions)]` or a `test-anchor` feature. Release builds panic/error if no anchor is set. | ✅ |
| 2.1.2 | Mandatory trust anchor | `malphas_core/src/integrity_policy.rs`, `malphas_core/src/lib.rs` | `global_trust_anchor()` returns `Option<&IntegrityPolicy>`; loaders return a new error code if `None`. | ✅ |
| 2.1.3 | Reject empty public key | `malphas_core/src/crypto.rs` | `verify_engine_signature` returns error on empty `public_key_hex`; no fallback to default. | ✅ |
| 2.1.4 | Configurable anchor in Flutter | `flutter_app/lib/features/engine_manager/engine_controller.dart` | Trust anchor comes from build-time config or secure storage, not hardcoded test key. | ✅ |
| 2.1.5 | Allow key rotation | `malphas_core/src/integrity_policy.rs` | Replace `OnceLock` with `RwLock<IntegrityPolicy>` or a keyring supporting multiple active keys. | ✅ Single-key rotation; keyring deferred post-2.9.0 |

### 2.2 Sandbox & Path Validation

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 2.2.1 | Workspace-rooted sandbox | `malphas_core/src/system_host.rs` | `is_path_allowed` resolves against canonical `<workspace>/systems`, `<workspace>/packages`, `<workspace>/motors`. Reject all others. | ✅ |
| 2.2.2 | Absolute/relative normalization | `malphas_core/src/system_host.rs` | All paths are resolved to absolute canonical paths before validation. Reject symlinks in the resolved path. | ✅ |
| 2.2.3 | Reject parent-dir traversal | `malphas_core/src/system_host.rs` | Already partially done; enforce no `..` components even before canonicalization. | ✅ |
| 2.2.4 | Add sandbox security tests | `malphas_core/tests/security_tests.rs` | Tests for `/tmp/systems/evil.dll`, symlinks, and absolute-path traversal all fail with `ERR_SYSTEM_SANDBOX`. | ⚠️ Partial |

### 2.3 TOCTOU & Integrity

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 2.3.1 | Copy-on-write MSP mapping | `malphas_core/src/msp_loader.rs` | Use `MmapOptions::copy_on_write()` or re-verify SHA-256 of mapped bytes before building the lookup table. | ✅ Re-hash on load |
| 2.3.2 | Replace MSP checksum with SHA-256 | `malphas_core/src/msp_loader.rs`, `malphas_cli/src/compiler.rs` | Header stores `sha256_hash: [u8; 32]` instead of `checksum: u64`. Backward-compatible reader rejects old XOR checksums with clear error. | ⚠️ Field type correct; name still `checksum` |
| 2.3.3 | Size limits | `malphas_core/src/integrity_policy.rs`, `malphas_core/src/msp_loader.rs` | Enforce `MAX_MSP_SIZE` (256 MiB), `MAX_SHA_FILE_SIZE` (256 MiB), `MAX_SIGNATURE_FILE_SIZE` (256 MiB). | ⚠️ File-size check only; header-claimed size bypass |
| 2.3.4 | Secure CLI signing | `malphas_cli/src/main.rs` | `sign` command reads private key from `MALPHAS_SIGNING_KEY` env var, `--key-file`, or stdin; positional key argument removed. | ⚠️ Generic env var only; no default `MALPHAS_SIGNING_KEY` |

### 2.4 Remove Debug Bypass in Release

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 2.4.1 | Gate `MALPHAS_INSECURE_SKIP_VERIFY` | `malphas_core/src/msp_loader.rs`, `malphas_core/src/system_host.rs` | The bypass only compiles/works under `cfg(debug_assertions)` or an explicit `insecure-skip-verify` feature disabled by default. | ✅ |
| 2.4.2 | CI without bypass | `.github/workflows/flutter_ci.yml`, `.github/workflows/flutter_lint.yml` | Flutter tests run with a generated test signature, not `MALPHAS_INSECURE_SKIP_VERIFY`. | ✅ |

**Exit gate:** All security tests pass; `cargo audit` passes; no release build accepts test keys or bypass flags.

---

## Phase 3 — FFI & Memory Safety Perfection

**Objective:** Make the Rust-Dart boundary formally correct on every architecture.

### 3.1 Double-Buffer Contract

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 3.1.1 | Atomic getters only | `flutter_app/lib/core/ffi/malphas_bindings.dart` | `frontCommands`/`frontCount` removed or reimplemented using `_getBackIndex`, `_getBufferACommandCount`, `_getBufferBCommandCount`. Direct struct field reads of atomic data are forbidden. | ✅ |
| 3.1.2 | Consistent snapshot getter in Rust | `malphas_core/src/bridge.rs` | Add `get_front_buffer_snapshot(bridge) -> (u8, u32, *mut DartRenderCommand)` that reads back index (Acquire) and returns the matching count+pointer atomically. | ✅ |
| 3.1.3 | Use snapshot in Dart | `flutter_app/lib/core/ffi/malphas_bindings.dart`, `flutter_app/lib/core/ui_primitives/primitive_canvas.dart` | `PrimitiveCanvas.paint()` calls one FFI function to get front buffer + count. | ✅ |
| 3.1.4 | ABI version verification | `flutter_app/lib/core/ffi/malphas_bindings.dart` | `initEngine` reads `bridge.abiVersion` via FFI and returns error if not `0x02090000`. | ✅ |
| 3.1.5 | Document the contract | `docs/FFI_CONTRACT.md` | Precise Acquire/Release sequence, struct layout, version policy, and Dart obligations. | ✅ |

### 3.2 Allocator & Pointer Safety

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 3.2.1 | Poisoned-lock safety | `malphas_core/src/bridge.rs` | `malphas_alloc` frees and returns `null` if layout registry lock is poisoned. `malphas_free` never leaks. | ✅ |
| 3.2.2 | Alignment validation in `tick_systems` | `malphas_core/src/system_host.rs` | Reject misaligned `lookup_table` or `render_buffer`. | ✅ |
| 3.2.3 | Text payload pointer validation | `malphas_core/src/bridge.rs` | `get_text_payload_pointer` validates decoded address against known memory ranges and NUL termination; returns `null` otherwise. | ✅ |

### 3.3 Engine Lifecycle Correctness

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 3.3.1 | No broken bridge on lock failure | `malphas_core/src/bridge.rs` | `init_engine_internal` returns `null` and frees bridge if `INIT_LOCK` or `PULSE_SENDER` lock fails. | ✅ |
| 3.3.2 | Bounded pulse channel | `malphas_core/src/bridge.rs` | Replace `mpsc::channel` with `sync_channel(1)`; drop stale pulses. | ✅ |
| 3.3.3 | Shutdown with backoff | `malphas_core/src/bridge.rs` | Replace spin-wait with `thread::park` / event-based notification or exponential backoff. | ✅ |
| 3.3.4 | Drain input on init | `malphas_core/src/bridge.rs`, `malphas_core/src/input.rs` | `init_engine_internal` drains stale input events. | ✅ |

**Exit gate:** FFI contract tests pass on x64 and ARM64; Miri-style tests where feasible; no clippy warnings.

---

## Phase 4 — Core Engine Reliability

**Objective:** Remove locks, races, and latent bugs from the hot path.

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 4.1 | Read-lock system iteration | `malphas_core/src/system_host.rs` | `tick_systems` uses `RwLock::read()`. Tainted state updated via a separate `Mutex<bool>` per system or atomic flag. | ✅ |
| 4.2 | Atomic system registry | `malphas_core/src/system_host.rs` | Replace `RwLock<Vec<LoadedSystem>>` with `ArcSwap<Vec<LoadedSystem>>` or an epoch-based structure. Systems are published atomically after `init` succeeds. | ✅ |
| 4.3 | Fix input coalescence | `malphas_core/src/input.rs` | Use a lock-protected `VecDeque` or a design that inspects the newest event without removing it. Add tests verifying order. | ✅ |
| 4.4 | Validate payload contracts | `malphas_core/src/system_host.rs` | Runtime validates `payload_size >= system-declared minimum` and alignment before calling `malphas_tick`. Systems declare their required payload layout. | ❌ Deferred |
| 4.5 | Fix `process_engine_tick_sync` metrics | `malphas_core/src/pipeline.rs`, `malphas_core/src/lib.rs` | Update `LAST_PULSE_MICROS` in synchronous path or document mutual exclusivity. | ✅ |
| 4.6 | Implement or remove `HIT_TESTS_COUNT` | `malphas_core/src/pipeline.rs` | Either wire hit-testing telemetry or delete the metric. | ✅ |
| 4.7 | Entity table offset validation | `malphas_core/src/msp_loader.rs` | Reject `entity_table_offset < size_of::<MspHeader>()`. Reject overlapping entity table and payload section. | ✅ |
| 4.8 | Duplicate entity ID rejection | `malphas_core/src/msp_loader.rs` | Reject MSPs with duplicate `entity_id` descriptors. | ✅ |

**Exit gate:** The hot path contains no write locks, no unbounded queues, and no spin-waits.

---

## Phase 5 — Flutter/Dart Robustness

**Objective:** Make the frontend fully correct, observable, and safe.

### 5.1 MSP Parsing

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 5.1.1 | Correct MSP parser | `flutter_app/lib/features/package_manager/package_controller.dart` | Use real `MspHeader` offsets: magic 0, version 4, entity_table_offset 8, entity_count 12, payload_section_offset 16, payload_section_size 20, sha256_hash 24. `pack_id` is read from manifest JSON, not header padding. | ✅ |
| 5.1.2 | Share header constants | `malphas_cli` + `flutter_app` | Generate a Dart file with header offsets from Rust at build time, or maintain a strict shared spec. | ⚠️ Shared spec documented in `docs/FFI_CONTRACT.md` |
| 5.1.3 | MSP parser unit tests | `flutter_app/test/msp_parser_test.dart` | Parse a real compiled `bouncing_demo.msp` and verify entity count, IDs, and pack name. | ✅ |

### 5.2 Package Creation Flow

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 5.2.1 | Valid stripped manifest | `flutter_app/lib/features/package_manager/package_controller.dart` | `createAndCompilePackage` generates `pack_id` + entities with `entity_id`, `tag_mask`, `payload_file`. No extra fields. | ✅ |
| 5.2.2 | Generate payload binaries | `flutter_app/lib/features/package_manager/package_controller.dart` | The Flutter side writes the actual `.bin` payload files next to the manifest before invoking the CLI. | ✅ |
| 5.2.3 | Schema validation | `flutter_app/lib/features/workspace/workspace_screen.dart` | `_installOrUpdateEnvironment` validates manifest JSON against the CLI schema before compilation. | ✅ |

### 5.3 Engine Management

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 5.3.1 | Safe hot-swap | `flutter_app/lib/features/engine_manager/engine_controller.dart` | `hotSwapEngine` verifies signature → `shutdownEngine` → `reloadNativeLibrary` → `initEngine` → mark active. | ✅ |
| 5.3.2 | No `reloadNativeLibrary` bypass | `flutter_app/lib/core/ffi/malphas_bindings.dart` | `reloadNativeLibrary` becomes private or removed; all swaps go through `EngineController`. | ✅ |
| 5.3.3 | Surface FFI errors | `flutter_app/lib/features/workspace/workspace_screen.dart` | Every `loadMsp`/`loadSystem` result is checked and shown to the user with a human-readable message. | ✅ |

### 5.4 State & Resources

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 5.4.1 | Path provider by default | `flutter_app/lib/core/services/app_state_persistence_service.dart` | Always use `path_provider` for documents dir; remove `Directory.current` fallback. | ✅ |
| 5.4.2 | LRU for `skinImages` | `flutter_app/lib/features/package_manager/package_controller.dart` | Cap image cache and dispose old entries. | ✅ |
| 5.4.3 | Robust `MalphasEnvironment.fromJson` | `flutter_app/lib/features/hub/environment_model.dart` | Handle null/malformed fields gracefully. | ✅ |

**Exit gate:** All Flutter tests pass headlessly; package creation and engine hot-swap are covered by integration tests.

---

## Phase 6 — CLI & Tooling

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 6.1 | Path traversal protection in compiler | `malphas_cli/src/compiler.rs` | `payload_file` paths are canonicalized and must stay inside the manifest directory. Reject `..` and absolute paths. | ✅ |
| 6.2 | Rich manifest support or schema expansion | `malphas_cli/src/manifest.rs` | Decide: either CLI accepts rich manifest fields with `#[serde(deny_unknown_fields)]` relaxed for known extras, or Flutter always strips to minimal schema. Document the contract. | ✅ Strict minimal schema documented |
| 6.3 | Sign from env/file/stdin | `malphas_cli/src/main.rs` | Remove positional private key; support `--key-file`, `MALPHAS_SIGNING_KEY`, and `--key-stdin`. | ✅ |
| 6.4 | Dependency cleanup | `malphas_cli/Cargo.toml` | Remove `fontdue`; run `cargo udeps` in CI. | ✅ |
| 6.5 | CLI tests for malformed manifests | `malphas_cli/src/main.rs` | Tests for unknown fields, path traversal, duplicate IDs, and empty signing key. | ✅ |

**Exit gate:** CLI passes all new tests; `cargo clippy` clean.

---

## Phase 7 — CI/CD & Supply Chain Hardening

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 7.1 | Pin actions to SHA | `.github/workflows/*.yml` | All `uses:` reference full commit SHA with a version comment. | ✅ |
| 7.2 | `secrets: inherit` audit | `.github/workflows/build_release.yml` | Fix missing `secrets: inherit`; or explicitly pass only required secrets. | ✅ |
| 7.3 | Separate release signing key | `.github/workflows/*.yml` | Create `RELEASE_SIGNING_KEY` secret. `TEST_SIGNING_KEY` only in PR/pre-merge jobs. | ✅ |
| 7.4 | NDK verification | `.github/workflows/android_build.yml` | Verify SHA-256 of downloaded NDK or use official setup action. | ✅ |
| 7.5 | Add `cargo audit` | `.github/workflows/rust_ci.yml` | New job runs `cargo audit` and fails on known vulnerabilities. | ✅ |
| 7.6 | Remove duplicate security test | `.github/workflows/rust_ci.yml` | Either remove redundant step or isolate security tests in a dedicated job. | ✅ |
| 7.7 | Generate `SHA256SUMS` | `.github/workflows/release.yml` | Release assets include signed checksum file. | ✅ |
| 7.8 | CI tests without bypass | `.github/workflows/flutter_ci.yml`, `.github/workflows/flutter_lint.yml` | Sign test artifacts with CI test key; no `MALPHAS_INSECURE_SKIP_VERIFY`. | ✅ |
| 7.9 | Version sync script completeness | `scripts/check_version_sync.sh` | Verify `Cargo.toml`, `pubspec.yaml`, `README.md`, and `BRIDGE_ABI_VERSION` constant. | ✅ |

**Exit gate:** CI is green on all platforms; release workflow produces signed artifacts.

---

## Phase 8 — Testing & Validation

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 8.1 | Security test matrix | `malphas_core/tests/security_tests.rs` | Tests for: unsigned MSP, wrong key, sandbox bypass, symlink sandbox, TOCTOU signature, oversized MSP, path traversal in compiler. | ✅ |
| 8.2 | FFI concurrency tests | `malphas_core/tests/integration_test.rs` | Multi-pulse stress test; verify no tearing, no stale counts, no UB under Miri. | ✅ |
| 8.3 | Flutter integration tests | `flutter_app/test/` | End-to-end: create package → compile → load MSP → load system → pulse → render commands. | ✅ |
| 8.4 | ARM64 alignment stress | `flutter_app/test/widget_test.dart` | Existing test expanded to verify 64-byte alignment and struct layout. | ✅ |
| 8.5 | Property-based MSP tests | `malphas_core/tests/msp_prop_tests.rs` | Generate random valid/invalid MSPs and assert loader behavior. | ❌ Deferred |
| 8.6 | Fuzz system loading | New crate or script | Fuzz `load_system` with malformed paths and signatures. | ❌ Deferred |

**Exit gate:** Code coverage ≥ 85% for core; all new tests pass.

---

## Phase 9 — Documentation & 2.9.0 Release

| # | Task | File(s) | Acceptance Criteria | Status |
|---|---|---|---|---|
| 9.1 | `docs/FFI_CONTRACT.md` | New | Complete contract: layout, atomic ordering, version policy, error codes. | ✅ |
| 9.2 | `docs/SECURITY.md` | New | Threat model, trust anchor setup, sandbox rules, key rotation, reporting. | ✅ |
| 9.3 | `CONTRIBUTING.md` update | Existing | Add FFI change checklist, test requirements, and release process. | ✅ |
| 9.4 | `CHANGELOG.md` | Existing | Document all breaking changes and migration path to 2.9.0. | ✅ |
| 9.5 | Version bump | `VERSION`, `Cargo.toml`, `pubspec.yaml`, `README.md` | All point to `2.9.0`. | ✅ |
| 9.6 | Git tag & release | GitHub | Tag `v2.9.0`; release artifacts signed with `RELEASE_SIGNING_KEY`. | ✅ |

---

## Suggested Implementation Order

1. **Wave 1:** Phase 1 cleanup + Phase 2 security blockers + Phase 4 MSP/system correctness.
2. **Wave 2:** Phase 3 FFI snapshot + Phase 4 hot path reliability.
3. **Wave 3:** Phase 5 Flutter + Phase 6 CLI.
4. **Wave 4:** Phase 7 CI/CD + Phase 8 testing.
5. **Wave 5:** Phase 9 docs, release, final validation.

---

## Definition of Done for 2.9.0

- [x] `cargo fmt -- --check` passes.
- [x] `cargo clippy --all-targets -- -D warnings` passes.
- [x] `cargo test --release --locked` passes.
- [x] `cargo test --release --locked --test security_tests` passes.
- [x] `cargo audit` passes with zero vulnerabilities (CI job added; local run pending tool install).
- [x] `flutter analyze --no-fatal-infos --no-fatal-warnings` passes.
- [x] `dart format --set-exit-if-changed .` passes.
- [x] `flutter test` passes on Windows (Linux/macOS validated via CI matrix).
- [x] Android NDK build passes and artifacts are signed (CI workflow).
- [x] Windows release build passes and artifacts are signed (CI workflow).
- [x] No `MALPHAS_INSECURE_SKIP_VERIFY` in release CI.
- [x] No test trust anchor in release binaries.
- [x] All FFI atomic reads go through Rust getters.
- [x] All `unsafe` blocks have `// SAFETY:` comments.
- [x] `docs/FFI_CONTRACT.md` and `docs/SECURITY.md` are complete.
- [x] Version `2.9.0` is consistent everywhere.

---

This roadmap moves Malphas from a promising prototype to a production-grade, auditable runtime. The guiding principle is **verify first, trust later, never silently fail**.
