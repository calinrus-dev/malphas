# Malphas Agent Instructions -- v2.7.0

These rules define the design language, build/test workflow, FFI safety constraints, and agent conventions of the Malphas project. All agents modifying code, documentation, or system mechanics must follow them.

Version v2.7.0 -- Data-Oriented Memory Router replaces the bytecode VM and the shared writable Arena with a flat memory router: MSP files are memory-mapped, MXC systems are native dynamic libraries, and Flutter only pulses the engine and reads raw render commands through FFI.

## 1. Terminal Aesthetic

Malphas functions and behaves like an immersive graphical terminal. It rejects standard mobile app layouts, messaging bubbles, web navigation, or social media designs.

## 2. Radical Dark Palette

- **Base Color:** Black Absolute (`#000000`) to disable pixels on OLED screens.
- **Secondary Containers:** Matte Anthracite / Ultra Dark Grey (`#0D0D0D` / `#161616`).
- **Typography Tone:** High-contrast Bone/Ivory (`#E0DCD3`) to prevent eye fatigue.
- **Borders:** Thin, subtle separators (`#1B1B1B`).

## 3. Strict Typography

- **Titles & Structural Headers:** Classic serif fonts (e.g., Georgia) to evoke solemnity and high-quality premium craft.
- **Data, Stats & Telemetry:** Clean, strictly geometric sans-serif or monospaced fonts (e.g., Courier/Roboto) to present pure data.

## 4. Organic Geometry

- All docks, text inputs, and action overlays must float on top of the passive canvas rather than stick to the screen edges.
- Borders must use extreme rounded corners (e.g., radius of 24-30px) to form capsules for controls.

## 5. Architectural Integrity

- Keep the rendering pipeline repaint-driven. Do not trigger global Flutter build/re-layouts on high-speed ticks.
- Maintain the virtual coordinates matrix of `1000x1000` logical units and apply letterboxing to preserve aspect ratios on dynamic screens.
- Flutter owns the only clock. The engine advances one tick per VSync via `trigger_engine_pulse()`. Do not add timers or sleeps in the Rust simulation thread.
- The render command stream is a homogeneous array of 24-byte `DartRenderCommand` slots. Systems write these commands directly into the back buffer; Flutter reads the front buffer opposite using `get_back_index()`.
- `malphas_core` is a Rust `cdylib` with decoupled modules: `pipeline`, `bridge`, `input`, `crypto`, `msp_loader`, and `system_host`. It exports a minimal C-ABI boundary; Flutter is a passive display server that only pulses and reads the front buffer.
- `malphas-cli` is the canonical package compiler and signer. It consumes a v2.7.0 manifest and produces a `.msp` Silver Platter. `.mxc` system libraries are built separately by Cargo as `cdylib` crates.
- The Flutter engine and package managers must discover resources from disk (`flutter_app/motors/`, `examples/`, `packages/`). Do not hard-code mock engines, mock packages, or placeholder SHA-256 hashes. Engine integrity checks must compute real SHA-256 sums of the motor files.

## 6. Build, Test & Release Commands

Always verify changes with the relevant commands before finishing. All Rust commands run from the workspace root.

| Target | Command |
|--------|---------|
| Build Rust workspace (release) | `cargo build --release` |
| Rust unit tests | `cargo test --release` |
| Rust formatting check | `cargo fmt -- --check` |
| Rust Clippy | `cargo clippy --release -- -D warnings` |
| Cross-platform native build (Bash) | `./build.sh` |
| Cross-platform native build (PowerShell) | `.\build_core.ps1` |
| Compile example MSP | `cargo run --release -p malphas-cli -- compile examples/bouncing_demo/manifest.json` |
| Flutter unit tests | `cd flutter_app && flutter test` |
| Flutter analyze | `cd flutter_app && flutter analyze --no-fatal-infos --no-fatal-warnings` |
| Flutter Dart format check | `cd flutter_app && dart format --set-exit-if-changed .` |
| Flutter release build (Windows example) | `cd flutter_app && flutter build windows --release` |

The `./build.sh` script and `.\build_core.ps1` are kept in parity. They detect the host platform, build `malphas_core`, `malphas_cli`, and `bouncing_demo`, copy the native motor into `flutter_app/motors/` with a timestamped name, keep the three most recent motors, copy the CLI executable and the example system into the same folder, and deploy non-timestamped copies to the workspace root and into existing Flutter build directories.

When changing the C-ABI surface or the CI contract, run the full local verification sequence:

```bash
cargo fmt -- --check
cargo test --release
cargo clippy --release -- -D warnings
./build.sh
cargo run --release -p malphas-cli -- compile examples/bouncing_demo/manifest.json
cd flutter_app && flutter analyze --no-fatal-infos --no-fatal-warnings
cd flutter_app && dart format --set-exit-if-changed .
cd flutter_app && flutter test
cd flutter_app && flutter build windows --release
```

## 7. FFI Safety Rules

Malphas shares memory between Dart and Rust. Breaking these rules causes crashes on ARM64, torn frames, or use-after-free.

### 7.1 Shared Memory Allocation

- **All** shared-memory buffers (double-buffer bridge, command arrays) must be allocated through the exported Rust allocator:
  - `malphas_alloc(size)`
  - `malphas_free(ptr, size)`
- Do **not** use `ffi.calloc` / `malloc` for shared memory. The system allocator may only provide 8-byte alignment. Our FFI allocator guarantees 64-byte alignment to prevent cache-line conflicts and keep strict ARM64/SSE alignments happy.
- Free buffers with the **same size** that was passed to `malphas_alloc` so the Rust allocator can reconstruct the correct `Layout`.

### 7.2 Struct Layout Stability

- All C-ABI structs are `#[repr(C)]` and explicitly aligned to 64 bytes where required (`#[repr(C, align(64))]`).
- Do **not** change field order, sizes, or alignment of `DartRenderCommand`, `MalphasDoubleBufferBridge`, `MspHeader`, or `MspEntityDescriptor` without updating both Rust and Dart definitions and the layout tests in `malphas_core`.
- Dart FFI struct mirrors live in `flutter_app/lib/core/ffi/types.dart` and must remain byte-compatible with the Rust side.

### 7.3 Pointer Delegates

- Dart must never perform pointer arithmetic on `MalphasDoubleBufferBridge` or copy nested structs by value.
- Always use the exported getter functions:
  - `get_buffer_a_commands(bridge)`
  - `get_buffer_b_commands(bridge)`
  - `get_buffer_a_command_count(bridge)`
  - `get_buffer_b_command_count(bridge)`
  - `get_back_index(bridge)`
  - `get_commands_written(bridge)`

### 7.4 MSP / Silver Platter

- The MSP is read-only after load. Systems receive `lookup_table: *const *const u8` and read payloads by direct indexing.
- Mutating the mapped MSP from Dart or from a system is a contract violation.
- Invalid `entity_id` values resolve to the Error Payload region; systems must still handle null payloads defensively.

### 7.5 MXC Systems

- A `.mxc` file is a native dynamic library exporting `malphas_init_system` and `malphas_tick`.
- `init` allocates the system's own flat SoA state from the read-only payloads.
- `tick` reads the fresh Silver Platter, mutates only its internal arrays, and writes `DartRenderCommand` slots into the provided back buffer.
- Systems must not call back into the core or perform FFI during `tick`.

### 7.6 Input Events

- Input events are pushed through `process_input_event(event_type, x, y)`. Dart never writes input coordinates directly into shared memory.
- The engine drains the input queue at the start of each tick. The queue is bounded to 256 events; old events are dropped on overflow.

### 7.7 Thread Lifecycle

- `init_engine` and `shutdown_engine` are serialised by `INIT_LOCK`.
- The background simulation thread is parked on the pulse channel and woken by `trigger_engine_pulse` once per vsync.
- `shutdown_engine` sets `ENGINE_RUNNING = false` and drops the pulse sender so the thread exits immediately without waiting for the next pulse.
- After signalling shutdown, both sides spin-wait on `ACTIVE_THREADS` until the background simulation thread exits.
- Any code spawned by `init_engine` must be wrapped in `ActiveThreadGuard` so `ACTIVE_THREADS` is decremented even on panic.

### 7.8 MSP Hot-Swap

- `refresh_msp(path)` replaces the mapped Silver Platter atomically without unloading loaded `.mxc` systems.
- Systems continue running with their internal SoA state; on the next tick they receive the new lookup table.

## 8. Package Compiler Conventions

- The canonical compiler is `malphas-cli`, a Rust executable in `malphas_cli/`.
- `MalphasPackageCompiler` in `flutter_app/lib/core/compiler/package_compiler.dart` is a thin wrapper that resolves the `malphas-cli` executable and invokes it with `compile <manifest.json>`.
- The CLI produces `<pack_id>.msp` next to the manifest. It does **not** produce `.mxc`; system libraries are built by Cargo as `cdylib` crates.
- All binary sections must be padded to 64-byte alignment before the next section starts.
- Real examples must live under `examples/` (e.g., `examples/bouncing_demo/manifest.json`). The Flutter package controller may compile or load them on startup instead of shipping synthetic placeholders.
- Engine and CLI discovery must be dynamic: scan `flutter_app/motors/` at runtime and resolve the correct file extension per platform (`.so`, `.dylib`, `.dll`). Do not embed absolute paths in source code.

## 9. Unified Cross-Platform Build

- Both `./build.sh` and `.\build_core.ps1` are first-class build entry points and must remain in parity.
- They build the workspace in release mode, then copy the native motor into `flutter_app/motors/` using a timestamped filename (`malphas_core_YYYYMMDD_HHMMSS.<ext>`).
- They keep only the three most recent timestamped motors plus their `.sig` files to avoid unbounded growth.
- They also copy the CLI executable and the `bouncing_demo` system (as `.dll`/`.so`/`.dylib` and as `.mxc`) into `flutter_app/motors/` so Dart can invoke them.
- On Linux and macOS, `./build.sh` additionally cross-compiles `libmalphas_core.so` for Android (`arm64-v8a`, `armeabi-v7a`, `x86_64`) when `ANDROID_NDK_HOME` is set, deploying the results into `flutter_app/android/app/src/main/jniLibs/<abi>/`. The `.github/workflows/android_build.yml` workflow validates this on every push.
- Neither script should leave the repository in a state that requires manual copying before `flutter test` or `flutter build` can succeed.

## 10. Workspace Auto-Load

- `WorkspaceScreen` must auto-load the environment's packages (or the default `examples/bouncing_demo/` demo) in `initState`.
- The load sequence must be: call `MalphasBindings.initEngine()`, call `load_msp(path)` for the MSP, call `load_system(path)` for the `.mxc`, and let the VSync ticker pulse the engine.
- The canvas must be live immediately; do not require the user to open the `PACKS` tab or compile manually.

## 11. Fuzzing and Correctness

- The Rust workspace contains unit and integration tests for the MSP loader, allocator, and FFI delegates. Do not disable or weaken them.
- When modifying the MSP loader, system host, or package compiler, add tests that exercise edge conditions (truncated input, out-of-bounds descriptors, misaligned sections, bad checksums).

## 12. Minimal, Surgical Changes

- Preserve existing file and style conventions.
- Do not refactor for style; only change what is necessary for the task.
- When in doubt, prefer explicit, commented, safe code over cleverness.
- Do not break the C-ABI layouts or the single-clock VSync-driven pulse model.

## 13. CI/CD Artifact Protection

- Native binaries (`malphas_core`, `malphas-cli`, `bouncing_demo`) must never be committed to git. They are produced by `./build.sh` / `.\build_core.ps1` locally or downloaded from CI artifacts in GitHub Actions.
- `rust_ci.yml` must upload the motor, CLI, and `bouncing_demo` system artifacts per OS so downstream Flutter jobs can consume them.
- `flutter_ci.yml` must download the motor, CLI, and system artifacts, place them in `flutter_app/motors/` and in `examples/bouncing_demo/`, and export `LD_LIBRARY_PATH` (Linux/macOS) before running `flutter test`.
- `flutter_lint.yml` must download the motor artifact so `flutter analyze` can resolve FFI bindings, and must run `dart format --set-exit-if-changed .` to enforce code style.
- CI failures caused by stale artifact paths, missing `LD_LIBRARY_PATH`, or outdated format checks are treated as release blockers.

## 14. Version Unification

- The Rust workspace version in `Cargo.toml` and the Flutter version in `flutter_app/pubspec.yaml` must remain in sync with the title in `README.md`.
- Use the workspace `version` key for both crates; do not override per-crate versions manually.
- A version bump is a deliberate release action and must be accompanied by an updated tag and release notes.
- Pushing a tag matching `v*` triggers `.github/workflows/release.yml`, which builds the Rust core for Windows/Linux/macOS, the Flutter Windows bundle, and the Android AAB/APK, then creates a GitHub Release. Ensure `TEST_SIGNING_KEY` is set as a repository secret before publishing.

## 15. Dart Formatting

- All Dart source files must be formatted with the project's bundled `dart format`.
- Run `cd flutter_app && dart format --set-exit-if-changed .` before considering Flutter work complete.
- Do not mix formatting-only changes with logic changes in the same commit unless the logic change is tiny.
