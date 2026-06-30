# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

## [2.6.5] - 2026-06-30

### Added
- Created `flat_models.dart` containing flat relational DOD structures (`Entity`, `EntityPayload`, `EntityTag`, `EntityProperty`, `EntityPackage`) in Dart, replacing object lists with relational pointer lists via integer IDs.
- Added flat FFI double-buffer command pointer and count getter FFI delegates to avoid pointer arithmetic in Dart.
- Guaranteed 64-byte boundary alignment in the FFI memory allocator (`malphas_alloc`/`malphas_free`) to prevent ARM64/SSE faults and cache line conflict overhead.

### Changed
- Refactored `MalphasDoubleBufferBridge` to a flat Rust struct layout, moving atomic counts directly to the root structure.
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
