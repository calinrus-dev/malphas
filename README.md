# Malphas v2.5.0 — Multi-Architecture Android Deployment

A high-performance, terminal-inspired graphical engine with a modular Rust core and a passive Flutter frontend. The two sides communicate through a small, explicit C-ABI boundary and share memory directly instead of marshalling messages across an isolating bridge.

> **v2.5.0** extends the decoupled onboarding loop to multi-architecture Android deployment: real `examples/bouncing_demo/` packages are compiled by `malphas-cli`, the Flutter front-end auto-loads packages when entering a workspace, discovers engines and packages from disk instead of using hard-coded mocks, CI runs native headless tests with the automated terminal binding, and the Android pipeline locks the NDK r26c path for consistent cross-compilation of `arm64-v8a`, `armeabi-v7a`, and `x86_64` engines.

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Flutter (Dart)                                                             │
│  ─────────────                                                              │
│  Ticker / VSync  ───────────────────────┐                                   │
│  Reads front command buffer <───────────┤                                   │
└─────────────────────────────────────────┼───────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  malphas_core (Rust cdylib)                                                 │
│  ──────────────────────────                                                 │
│  ┌─────────┐ ┌─────┐ ┌────────┐ ┌─────────┐ ┌──────────┐                    │
│  │ pipeline│ │ vm  │ │ bridge │ │ input   │ │ crypto   │                    │
│  │         │ │     │ │        │ │         │ │          │                    │
│  │ MHP/MSP │ │byte-│ │ double │ │ 256-evt │ │ Ed25519  │                    │
│  │ loader  │ │code │ │ buffer │ │ queue   │ │ verify   │                    │
│  └─────────┘ └─────┘ └────────┘ └─────────┘ └──────────┘                    │
│                         │                                                   │
│  C-ABI exports ◄────────┘                                                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                          ▲
                                          │
┌─────────────────────────────────────────────────────────────────────────────┐
│  malphas-cli (Rust executable)                                              │
│  ─────────────────────────────                                              │
│  compile manifest.json ──► <pack_id>.mhp + <pack_id>.msp                    │
│  sign <file> <private_key_hex> ──► <file>.sig                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

Flutter owns the only clock and acts as a passive display server. Every vertical sync it sends one pulse through `trigger_engine_pulse()`. The Rust simulation thread wakes up, drains pending input, executes one frame of bytecode logic, writes render commands into the back buffer, and flips the bridge. Flutter reads the front buffer on the next frame.

The `malphas-cli` compiler is a standalone Rust executable. It parses `manifest.json`, builds the font atlas, assembles the MHP/MSP binaries, and signs outputs with Ed25519. Dart's `MalphasPackageCompiler` is now a thin wrapper that locates the CLI and invokes it.

This single-clock design eliminates drift between the Dart scheduler and the native simulation, keeps battery use low, and makes the engine trivially pausable by stopping the pulse.

## Shared-memory command stream

Render commands are exchanged through a homogeneous array of `DartRenderCommand` structs. The array is always 24 bytes per slot and is allocated with `malphas_alloc` so it is 16-byte aligned on every target platform.

### `DartRenderCommand` logical union (24 bytes)

```rust
#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,   // 1 = rectangle, 2 = text
    pub layer: u8,
    pub pad: u16,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}
```

| Bytes | Field |
|-------|-------|
| 0 | `command_type` |
| 1 | `layer` |
| 2–3 | `pad` |
| 4–7 | `x` |
| 8–11 | `y` |
| 12–15 | `width` |
| 16–19 | `height` |
| 20–23 | `color_rgba` |

- For a rectangle (`command_type == 1`) the `x`, `y`, `width`, and `height` fields are geometry.
- For a text command (`command_type == 2`) the same bytes are reinterpreted:
  - `x` = text length in bytes
  - `y` = style / font size
  - `width` / `height` = low / high 32 bits of a 64-bit `TextPayload` pointer in the Arena

Keeping the command array homogeneous means the rasterizer can walk it with a fixed stride; text metadata lives in the Arena, not in the stream.

### Double-buffer bridge

```rust
#[repr(C, align(16))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: AtomicU8,
    pub commands_written: AtomicU32,
}
```

Rust writes into the buffer selected by `atomic_back_index`; Flutter reads from the opposite buffer. Dart never performs pointer arithmetic on the bridge layout. All nested pointers are retrieved through exported getter functions (`get_buffer_a_ptr`, `get_command_count`, `get_commands_pointer`, etc.) so the Rust compiler is free to keep the layout strictly aligned.

When Rust needs the address of a field that Dart also observes, it uses `std::ptr::addr_of_mut!` instead of creating a temporary `&mut`. This avoids aliasing violations and keeps Miri and strict-provenance tools happy.

## Memory model and allocation

Every shared-memory buffer used by both sides must be allocated through the exported Rust allocator:

```rust
#[no_mangle]
pub extern "C" fn malphas_alloc(size: usize) -> *mut u8;

#[no_mangle]
pub extern "C" fn malphas_free(ptr: *mut u8, size: usize);
```

The allocator returns 16-byte aligned memory, which is required by `CoreCommandBuffer`, `MalphasDoubleBufferBridge`, `MhpHeader`, `MspHeader`, and ARM64 loads. Dart must not use `ffi.calloc` or `malloc` for the bridge, command arrays, or Arena.

When freeing, pass the exact size that was originally requested so Rust can reconstruct the correct `Layout`.

## Resource packages: MHP and MSP

Malphas packages are self-describing binary blobs with 16-byte aligned headers. The canonical producer is `malphas-cli compile <manifest.json>`.

### MHP — Malphas Host Package

`MhpHeader` is 112 bytes, `#[repr(C, align(16))]`.

```rust
#[repr(C, align(16))]
pub struct MhpHeader {
    pub magic: [u8; 4],              // b"MLPH"
    pub version: u32,
    pub total_size: u64,
    pub checksum: [u8; 32],
    pub pack_id: [u8; 16],
    pub canvas_width: u16,
    pub canvas_height: u16,
    pub font_metrics_offset: u32,
    pub font_atlas_offset: u32,
    pub objects_table_offset: u32,
    pub objects_table_count: u32,
    pub skins_offset: u32,
    pub skins_size: u32,
    pub has_embedded_msp: u32,
    pub embedded_msp_offset: u32,
    pub embedded_msp_size: u32,
    pub padding: [u8; 4],
}
```

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | `magic` `[u8; 4]` (`b"MLPH"`) |
| 4 | 4 | `version` `u32` |
| 8 | 8 | `total_size` `u64` |
| 16 | 32 | `checksum` `[u8; 32]` (SHA-256) |
| 48 | 16 | `pack_id` `[u8; 16]` |
| 64 | 2 | `canvas_width` `u16` |
| 66 | 2 | `canvas_height` `u16` |
| 68 | 4 | `font_metrics_offset` `u32` |
| 72 | 4 | `font_atlas_offset` `u32` |
| 76 | 4 | `objects_table_offset` `u32` |
| 80 | 4 | `objects_table_count` `u32` |
| 84 | 4 | `skins_offset` `u32` |
| 88 | 4 | `skins_size` `u32` |
| 92 | 4 | `has_embedded_msp` `u32` |
| 96 | 4 | `embedded_msp_offset` `u32` |
| 100 | 4 | `embedded_msp_size` `u32` |
| 104 | 4 | `padding` `[u8; 4]` |
| **108** | **4** | *alignment padding to 16 bytes* |
| **112** | | **total size** |

The header is followed by the font metrics table, the alpha font atlas, the objects table, the data pool, and an optional embedded MSP payload. Every section is padded to a 16-byte boundary before the next section starts. The SHA-256 checksum covers everything after the header.

#### `MhpObjectDescriptor` (32 bytes)

```rust
#[repr(C, align(16))]
pub struct MhpObjectDescriptor {
    pub object_id: u32,
    pub properties_offset: u32,
    pub properties_size: u32,
    pub skins_offset: u32,
    pub skins_size: u32,
    pub padding: [u8; 12],
}
```

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | `object_id` `u32` |
| 4 | 4 | `properties_offset` `u32` |
| 8 | 4 | `properties_size` `u32` |
| 12 | 4 | `skins_offset` `u32` |
| 16 | 4 | `skins_size` `u32` |
| 20 | 12 | `padding` `[u8; 12]` |
| **32** | | **total size** |

The alpha font atlas is a 512×512 A8 texture generated by `malphas-cli`. Dart converts it to `rgba8888` by filling RGB with white and using the stored alpha value as the alpha channel (`rgbaBytes[i * 4 + 3] = alpha`).

### MSP — Malphas Script Package

`MspHeader` is 64 bytes, `#[repr(C, align(16))]`.

```rust
#[repr(C, align(16))]
pub struct MspHeader {
    pub magic: [u8; 4],              // b"MLPS"
    pub version: u32,
    pub checksum: [u8; 32],
    pub bytecode_size: u32,
    pub entry_point: u32,
    pub padding: [u8; 16],
}
```

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | `magic` `[u8; 4]` (`b"MLPS"`) |
| 4 | 4 | `version` `u32` |
| 8 | 32 | `checksum` `[u8; 32]` (SHA-256) |
| 40 | 4 | `bytecode_size` `u32` |
| 44 | 4 | `entry_point` `u32` |
| 48 | 16 | `padding` `[u8; 16]` |
| **64** | | **total size** |

MSP contains sandboxed bytecode for the entity VM. The checksum covers the bytecode payload only. MSP files can be loaded standalone or embedded inside an MHP file.

## `malphas-cli` usage

```bash
# Compile a manifest into <pack_id>.mhp and <pack_id>.msp
malphas-cli compile <manifest.json>

# Sign any file with a 32-byte Ed25519 private key in hex
malphas-cli sign <file> <private_key_hex>
```

The `sign` subcommand writes a 64-byte Ed25519 signature to `<file>.sig`. The core verifies these signatures when loading packages if signature checking is enabled.

## Runtime hot-swap

The live resource pack runtime is stored in a lock-free atomic pointer:

```rust
static RUNTIME: AtomicPtr<ResourcePackRuntime> = AtomicPtr::new(std::ptr::null_mut());
```

Package loading builds a new `ResourcePackRuntime` on the heap, pauses the engine, acquires the Arena write lock, and swaps the pointer with `AcqRel` ordering. The old runtime is dropped only after the swap, so the simulation tick never observes a partially constructed package. The tick loads the pointer with `Acquire` and executes from an immutable snapshot for the entire frame.

Bytecode is stored similarly in an `ArcSwap<Box<[u8]>>`. Replacing bytecode is atomic and does not block the engine; an in-flight tick simply continues using the snapshot it loaded at frame start.

## Entity VM and bytecode sandbox

The bytecode VM is intentionally tiny. Each instruction is four bytes and each entity gets an instruction budget, so malformed bytecode can only halt the offending entity, never the engine clock.

Supported operations include register loads, arithmetic, Arena reads/writes with alignment and bounds checks, and conditional jumps. All Arena accesses verify that the offset does not overflow, that the access fits inside the Arena, and that multi-byte reads/writes are naturally aligned.

## Input and lifecycle

Input events are pushed through `process_input_event(event_type, x, y)`. They land in a bounded Mutex queue with a capacity of 256 events; on overflow the oldest events are dropped. Consecutive events with identical coordinates are coalesced. The engine drains the queue once per tick.

Engine startup and shutdown are serialised by `INIT_LOCK`. `shutdown_engine` drops the pulse sender so the simulation thread exits immediately without waiting for the next vsync, then spin-waits on `ACTIVE_THREADS` until the background thread is gone. Every spawned thread is wrapped in `ActiveThreadGuard` so `ACTIVE_THREADS` is decremented even on panic.

## Fuzzing and correctness

The Rust workspace test suite includes deterministic fuzz tests that exercise the bytecode VM with:

- 100,000 random bytecodes of varying length
- truncated bytecodes
- out-of-bounds jump targets
- misaligned Arena accesses

Unit tests also verify struct sizes and alignments, the 16-byte aligned allocator round-trip, the lock-free bytecode container read latency, and the full engine thread lifecycle.

## Build, test and release

All Rust commands are run from the workspace root:

```bash
# Build the entire Rust workspace in release mode
cargo build --release

# Run Rust tests
cargo test --release

# Check Rust formatting
cargo fmt -- --check

# Run Rust lints
cargo clippy --release -- -D warnings

# Cross-platform native core + CLI build (Linux, macOS, Windows Git Bash)
./build.sh

# Windows PowerShell equivalent
.\build_core.ps1

# Flutter analyze
cd flutter_app && flutter analyze --no-fatal-infos --no-fatal-warnings

# Flutter unit tests (expects malphas_core in flutter_app/motors/)
cd flutter_app && flutter test

# Flutter release build (example: Windows)
cd flutter_app && flutter build windows --release
```

The `./build.sh` script and `build_core.ps1` are kept in parity. They detect the host platform, build `malphas_core` and `malphas_cli` from the workspace root, copy the resulting native library to `flutter_app/motors/` with a timestamped name, keep the three most recent motors, copy the CLI executable into the same folder, and deploy a non-timestamped motor plus signature into existing Flutter build directories.

On Linux and macOS, `./build.sh` also cross-compiles `libmalphas_core.so` for Android (`arm64-v8a`, `armeabi-v7a`, `x86_64`) when the `ANDROID_NDK_HOME` environment variable points to a valid Android NDK. The resulting libraries are placed in `flutter_app/android/app/src/main/jniLibs/<abi>/` so the Android Gradle Plugin bundles them into the APK/AAB automatically. The dedicated `android_build.yml` workflow performs the same cross-compilation on every push.

When running Flutter tests locally or in CI, the dynamic linker must be able to find the native motor. On Linux this is done by exporting `LD_LIBRARY_PATH` to include `flutter_app/motors/`; on Windows the motor is picked up from the same directory automatically once copied. On Android, the motor is loaded from the bundled `jniLibs` via the standard platform search path.

## Auto-load behavior

When a user enters a workspace from the Hub, `WorkspaceScreen` automatically loads the environment's first package (or the default `examples/bouncing_demo/` demo) into the native core, configures the rectangle and text entities in the Arena, and starts the VSync-driven simulation pulse. No manual visit to the `PACKS` tab is required; the canvas is live on entry.

## Repository layout

```
malphas_core/          Rust cdylib, C-ABI exports, decoupled modules (pipeline/vm/bridge/input/crypto)
malphas_cli/           Rust executable, package compiler and Ed25519 signer
flutter_app/           Flutter UI, FFI bindings, package compiler wrapper
  lib/core/ffi/        Dart mirrors of Rust structs and the bindings class
  lib/core/compiler/   Dart wrapper that invokes malphas-cli
  lib/features/        Engine manager, package manager, workspace UI
  motors/              Populated by build.sh / build_core.ps1; ignored by git
examples/              Real Malphas packages (e.g., bouncing_demo)
build.sh               Cross-platform Bash build script
build_core.ps1         Windows PowerShell build script (parity with build.sh)
.agents/AGENTS.md      Agent conventions, build commands and FFI safety rules
.github/workflows/     CI/CD pipeline (Rust builds first, Flutter consumes artifacts)
```

## CI/CD pipeline

GitHub Actions is split into small, focused workflows that keep Rust and Flutter verification fast and deterministic:

- `rust_ci.yml` — builds `malphas_core` and `malphas_cli` on Linux, macOS, and Windows, runs `cargo fmt --check`, `cargo clippy --release`, and `cargo test --release`, then uploads the CLI and native motor artifacts.
- `flutter_ci.yml` — downloads the CLI artifact for the runner OS, downloads the matching native motor artifact, places both in `flutter_app/motors/`, exports `LD_LIBRARY_PATH` so the dynamic linker can find the motor, and runs `flutter test`.
- `flutter_lint.yml` — downloads the native motor artifact, runs `flutter analyze --no-fatal-infos --no-fatal-warnings`, and verifies `dart format --set-exit-if-changed .`.

Native binaries are intentionally not committed; they are produced by the build scripts or downloaded from CI artifacts. This keeps the repository small and guarantees that Flutter tests always exercise the current Rust build.

## Releases

Tagged versions are built and published automatically by GitHub Actions. Pushing a tag that starts with `v` triggers a release workflow that:

1. Builds the native Rust core for Windows, Linux, and macOS.
2. Builds the Flutter Windows release executable.
3. Packages the native libraries and the Windows app bundle.
4. Creates a GitHub Release and attaches the binaries.

To publish a new version:

```bash
git tag -a v2.5.0 -m "Release v2.5.0"
git push origin v2.5.0
```

> **Note:** The release workflow depends on the repository secret `TEST_SIGNING_KEY` to sign the native engine artifacts. Make sure the secret is configured before pushing the tag.

After the workflow finishes, the release will be available on the repository's [Releases](../../releases) page.

## License

MIT
