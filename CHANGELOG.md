# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [2.7.0] - 2026-06-30

### Added
- **Data-Oriented Memory Router**: the Rust core is now a pure memory router that maps MSP files via `mmap` and dispatches ticks to native `.mxc` systems.
- **MSP v2 format**: rigid 64-byte aligned binary with `MspHeader` (64 bytes), `MspEntityDescriptor` (64 bytes), and a 64 KB Error Payload reserve.
- **Silver Platter**: a flat `*const u8` lookup table built once at load time; systems read payloads by direct pointer indexing.
- **MXC v2**: `.mxc` files are now real native dynamic libraries (`cdylib`) exporting `malphas_init_system` and `malphas_tick`, replacing the old bytecode VM container.
- `refresh_msp` FFI call for hot-swapping the mapped MSP without unloading loaded `.mxc` systems.
- `PayloadDecodeService` that runs JSON/local-file decoding in Dart `Isolate`s for the virtualized payload grid.
- `GridView.builder` payload grid in the package manager with async preview cards (image, JSON, text, binary).
- Workspace "Install / Update Environment" button that recompiles packages via `malphas-cli` and hot-swaps the MSP mmap.
- `bouncing_demo` system crate with internal SoA state, demonstrating bounce logic and native render-command emission.

### Changed
- `MalphasBindings` Dart API rewritten for v2.7.0: `init_engine`, `trigger_engine_pulse`, `load_msp`, `refresh_msp`, `load_system`, `malphas_alloc/free`.
- `PrimitiveCanvas` now reads render commands directly from the native front buffer pointer with **zero-copy**; no command list is materialized in Dart memory per frame.
- `MalphasPackageCompiler` now produces only `.msp`; `.mxc` artifacts are built separately by Cargo as native `cdylib`s.
- Updated `build.sh` and `build_core.ps1` to build the `bouncing_demo` system and copy it as `bouncing_demo.mxc`.
- Bumped app description and version to `2.7.0+1` in `pubspec.yaml`.
- Regenerated `examples/bouncing_demo/manifest.json` and payload binaries to the v2.7.0 schema (`pack_id` + `entities[].payload_file`).

### Removed
- The bytecode VM (`vm.rs`) and `.mxc` bytecode container semantics.
- The shared writable Arena and all arena-based entity setup (`arena_layout.dart`, `EntityBootstrapService`, `configureEntity`, `writeArenaText`, `setEntitiesCount`).
- Legacy resource-pack / SHA2 pack-loading logic.
- `arc-swap` dependency from the core.

### Fixed
- `MspEntityDescriptor` manual padding corrected to 40 bytes so the struct remains exactly 64 bytes including the implicit 4-byte padding before `tag_mask`.
- MSP loader checksum now covers the entity table + payload section deterministically.
- Flutter tests updated to the new FFI lifecycle and prebuilt `bouncing_demo` integration flow.
- `EngineController` now calls `verifyEngineSignature` matching the v2.7.0 FFI boundary.

## [2.6.5] - 2026-06-30

### Added
- Created `flat_models.dart` containing flat relational DOD structures (`Entity`, `EntityPayload`, `EntityTag`, `EntityProperty`, `EntityPackage`) in Dart, replacing object lists with relational pointer lists via integer IDs.
- Added flat FFI double-buffer command pointer and count getter FFI delegates to avoid pointer arithmetic in Dart.
- Guaranteed 64-byte boundary alignment in the FFI memory allocator (`malphas_alloc`/`malphas_free`) to prevent ARM64/SSE faults and cache line conflict overhead.
- Introduced `MxcHeader` and `.mxc` executable container format for VM bytecode logic.

### Changed
- Standardized file formats: eradicated MHP in favor of MSP (Malphas Source Pack) for resources, and MXC (Malphas eXecutable Core) for logic bytecode.
- Upgraded C-ABI structures (`MspHeader` (128 bytes), `MspEntityDescriptor` (64 bytes), `MxcHeader` (64 bytes), and `MalphasDoubleBufferBridge` (64 bytes)) to strict 64-byte alignments (`#[repr(C, align(64))]`) and calculated padding manually to align with cache lines.
- Updated the package compiler CLI to pad all binary sub-payload offsets to a multiple of 64 bytes to ensure memory mapped FFI alignment.
- Purged all custom OOP hierarchies and classes (e.g. `MalphasObject`, `MalphasSkin`) in Dart and Rust.
- Moved VM tick execution code (`execute_logic_tick`) out of `impl ResourcePackRuntime` and into a standalone function in `vm.rs`.
- Simplified VM test PRNG `Xorshift64` to a methodless struct with standalone helper functions.
- Renamed all binary headers, manifest keys, and struct parameters from "Object/Skin" to "Entity/Payload" across both Rust and Dart.

### Fixed
- Fixed library resolution in `malphas_bindings.dart` to walk up to the repository root directory when running unit tests from `flutter_app/`, resolving local DLL test lookup errors.
- Cleaned up stale built DLL copies under `flutter_app/`.

## [2.5.1] - 2026-06-29

### Added
- Shared Arena layout constants in `malphas_core/src/arena_layout.rs` and `flutter_app/lib/core/ffi/arena_layout.dart`.
- Rust FFI getter `get_text_payload_pointer` to keep Dart pointer arithmetic off the C-ABI boundary.
- `_checkFfiResult` wrappers in Dart for critical FFI calls (`initEngine`, `loadPack`, `setEntity`, etc.).
- Rust integration test: end-to-end `init → load pack → set entities → pulse → shutdown`.
- `EntityBootstrapService` decouples entity setup from `WorkspaceScreen`.
- `MalphasEnvironment` persistence and reactive `ChangeNotifier` controllers.
- `CHANGELOG.md`, `CONTRIBUTING.md`, GitHub issue/PR templates, and real `flutter_app/README.md`.
- Android release workflow (`android_release.yml`) building AAB/APK and attaching them to GitHub Releases.
- Android `.so` signature step in `android_build.yml` using `TEST_SIGNING_KEY`.
- CI version-sync check ensuring `Cargo.toml`, `pubspec.yaml`, `README.md`, and `AGENTS.md` agree.

### Changed
- Bumped workspace and app version to `2.5.1+1` to resolve `v2.5.0`/`v2.5.1` drift in commit history.
- `malphas-cli` manifest parsing now uses typed `serde` structs with strict validation and rejects empty signing keys.
- `malphas-cli` accepts hex keys with optional `0x`/`0X` prefix.
- `build.sh` Android cross-compilation now fails if any ABI does not build.
- `flutter_ci.yml` runs `flutter test` correctly (no invalid `--binding-type=test`, no duplicated `cd flutter_app`).

### Fixed
- Clippy warning in `malphas_core/src/bridge.rs` related to `Send`/`Sync` of the double-buffer bridge.
- `engine_signature_test.dart` now restores the original `.sig` even if assertions throw.
- `PrimitiveCanvas` no longer performs pointer arithmetic on `DartRenderCommand`.
- Font atlas bounds are validated before `decodeImageFromPixels`.
- Workspace auto-load errors are now visible in the UI as well as via `SnackBar`.

## [2.5.0] - 2026-06-29

### Added
- Multi-architecture Android deployment with NDK r26c for `arm64-v8a`, `armeabi-v7a`, and `x86_64`.
- Decoupled onboarding loop: `WorkspaceScreen` auto-loads the active package on entry.
- Real example package under `examples/bouncing_demo/` compiled by `malphas-cli`.
- Flutter engine and package discovery from disk (`flutter_app/motors/`, `examples/`, `packages/`).
- Native headless test binding and CI pipeline for Rust and Flutter.
- Shared-memory command stream via homogeneous 24-byte `DartRenderCommand` slots.
- Double-buffer bridge (`MalphasDoubleBufferBridge`) with exported pointer getters.
- `malphas-cli` package compiler and Ed25519 signer.
- Dart FFI bindings in `flutter_app/lib/core/ffi/`.
- Lock-free resource and bytecode hot-swap.
- Deterministic bytecode VM fuzz tests.
- Cross-platform build scripts `build.sh` and `build_core.ps1`.

### Changed
- Flutter frontend acts as a passive display server driven by a single VSync clock.
- Rust core is built as a `cdylib` with a small, explicit C-ABI boundary.

### Fixed
- Engine integrity checks now compute real SHA-256 sums of motor files instead of using placeholders.
- Input event queue is bounded to 256 events with duplicate coalescing.

### Removed
- Hard-coded mock engines, mock packages, and placeholder SHA-256 hashes.
