# Malphas v2.8.0 — Fortress CI

[![Rust CI](https://github.com/calinrus-dev/malphas/actions/workflows/rust_ci.yml/badge.svg)](https://github.com/calinrus-dev/malphas/actions/workflows/rust_ci.yml)
[![Flutter CI](https://github.com/calinrus-dev/malphas/actions/workflows/flutter_ci.yml/badge.svg)](https://github.com/calinrus-dev/malphas/actions/workflows/flutter_ci.yml)
[![Flutter Lint](https://github.com/calinrus-dev/malphas/actions/workflows/flutter_lint.yml/badge.svg)](https://github.com/calinrus-dev/malphas/actions/workflows/flutter_lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Malphas is not a game engine, a framework, or a fantasy console.**
> **It is a sovereign, data-oriented execution environment that keeps the hot path outside managed runtimes.**

Malphas is a high-performance **Data-Oriented Design (DOD)** runtime. All logic, state, and render production live in native, memory-mapped code. Flutter is treated as a passive display terminal; the Rust core owns every byte that matters.

**v2.8.0 — Fortress CI** polishes the v2.7.5 hardening and makes the entire delivery pipeline green:

- Cross-platform CI/CD parity: Rust, Flutter, Android, and Windows release builds are all verified on every push.
- Reusable workflows inherit secrets correctly, and artifact downloads are robust across Linux, macOS, and Windows.
- Android NDK r26c cross-compilation uses the correct versioned LLVM toolchains.
- Flaky tests fixed: input-queue tests are serialized and security tests use absolute paths to avoid `chdir` races.
- Asset packaging fixed: `flutter_app/assets/packages/.gitkeep` guarantees the directory exists on a clean checkout.

The v2.7.5 runtime hardening remains in place:

- Rust-owned FFI bridge and command buffers.
- Ed25519 sidecar signatures for the engine, `.msp` packs, and `.mxc` systems.
- Runtime sandbox that only loads systems from `systems/`, `packages/`, or `motors/`.
- `catch_unwind` isolation for misbehaving systems.
- Lockless input queue, real `dt`, and deterministic alignment validation.

The pipeline stays the same:

```text
flat data on disk (MSP) → memory-mapped (mmap) → native systems (MXC) → raw render commands → screen
```

---

## Table of Contents

1. [What Malphas Is](#what-malphas-is)
2. [Architecture](#architecture)
3. [Security Model](#security-model)
4. [Build and Run](#build-and-run)
5. [Example](#example)
6. [Testing](#testing)
7. [Verification Commands](#verification-commands)
8. [Contributing](#contributing)
9. [License](#license)

---

## What Malphas Is

Malphas treats memory as the primary interface. Data is not deserialized into objects; it is mapped into address space and routed to native systems as raw pointers.

- **Zero-copy** is the default.
- **Cache alignment** is a first-class contract.
- **The hot path contains no objects, no methods, and no GC stalls.**
- **Systems are dependency-free native libraries** that can outlive any UI framework.

If you are still thinking in `object.update()`, you are in the wrong execution environment.

---

## Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                  MALPHAS v2.8.0 — SOVEREIGN RUNTIME                 │
│                                                                     │
│   ┌────────────┐   ┌───────────────┐   ┌─────────────────────────┐ │
│   │    MSP     │──▶│ Memory Router │──▶│          MXC            │ │
│   │  (on disk) │mmap│  (Rust core) │   │   (native systems)      │ │
│   └────────────┘   └───────┬───────┘   └─────────────────────────┘ │
│                            │                                        │
│                            ▼                                        │
│                  ┌─────────────────────┐                            │
│                  │   Silver Platter    │                            │
│                  │ (flat pointer table)│                            │
│                  └─────────────────────┘                            │
│                            │                                        │
│                            ▼                                        │
│                  ┌─────────────────────┐                            │
│                  │ MalphasDoubleBuffer │                            │
│                  │     Bridge (FFI)    │                            │
│                  └─────────────────────┘                            │
│                            │                                        │
│                            ▼                                        │
│                  ┌─────────────────────┐                            │
│                  │   Flutter Canvas    │                            │
│                  │    (Blind Painter)  │                            │
│                  └─────────────────────┘                            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### MSP — Malphas Source Pack

The MSP is the immutable data unit. It is a rigid, 64-byte-aligned binary file that is **byte-identical on disk and in memory**.

```text
MSP File
├─ MspHeader                        64 bytes
├─ Entity Table                     entity_count × 64 bytes
│  ├─ MspEntityDescriptor[0]
│  ├─ MspEntityDescriptor[1]
│  └─ ...
└─ Payload Section                  aligned to 64 bytes
   ├─ Payload[0]
   ├─ Payload[1]
   ├─ ...
   └─ Error Payload Reserve         64 KB
```

```rust
#[repr(C, align(64))]
pub struct MspHeader {
    pub magic: [u8; 4],              // "MLPS"
    pub version: u32,                // 2
    pub entity_table_offset: u32,    // offset to descriptor array
    pub entity_count: u32,           // number of entities
    pub payload_section_offset: u32, // offset to first payload
    pub payload_section_size: u32,   // total payload bytes
    pub checksum: u64,               // deterministic integrity value
    pub _padding: [u8; 32],          // pad to 64 bytes
}                                   // exactly 1 cache line

#[repr(C, align(64))]
pub struct MspEntityDescriptor {
    pub entity_id: u32,              // the u32 identity
    // 4 bytes implicit padding
    pub tag_mask: u64,               // filter bits
    pub payload_offset: u32,         // byte offset into payload section
    pub payload_size: u32,           // byte length of payload
    pub _padding: [u8; 40],          // pad to 64 bytes
}                                   // exactly 1 cache line
```

Key properties:

- **Entity ≠ Object.** An entity is a `u32` index. It has no methods, no vtable, and no lifecycle beyond its index.
- **Payload ≠ Object.** A payload is a raw byte block. Its meaning is defined by the system that consumes it.
- **Loading is mapping.** The core loads an MSP with `mmap`. There is no parser, no allocator, and no deserialization step in the hot path.
- **Immutable by contract.** Once mapped, the MSP is read-only.

### MXC — Malphas eXecutable Core

An MXC is a native dynamic library (`dll` / `so` / `dylib`) built as a `cdylib`. It exports exactly two symbols and depends on nothing except the C ABI.

```rust
#[no_mangle]
pub extern "C" fn malphas_init_system(
    lookup_table: *const *const u8,
    entity_count: u32,
) -> i32;

#[no_mangle]
pub extern "C" fn malphas_tick(
    lookup_table: *const *const u8,
    entity_count: u32,
    dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
);
```

Contract:

- `malphas_init_system` runs once, reserves the system's internal Structure-of-Arrays state, and returns `0` on success.
- `malphas_tick` runs every frame. It reads from the Silver Platter, updates its own flat arrays, and writes `DartRenderCommand` structs into the provided back buffer.
- **The system never writes to the MSP.**
- **The system never calls back into the core.**

This makes an MXC a self-contained unit of execution. It can be compiled today, signed, shipped, and loaded tomorrow without recompiling the engine.

### The Memory Router — Rust Core

The Rust core has one job: keep the hot path as a straight line through memory.

When an MSP is loaded:

1. The file is `mmap`-ed into the process.
2. The header and entity table are validated.
3. The core builds the **Silver Platter**: a flat array of `*const u8` where index `i` points directly to the payload of entity `i`.

```text
Silver Platter
┌──────────────────────────────────────────────┐
│ lookup_table[0]  ────────────────▶ Payload[0] │
│ lookup_table[1]  ────────────────▶ Payload[1] │
│ lookup_table[2]  ────────────────▶ Payload[2] │
│ ...                                          │
│ lookup_table[N]  ────────────────▶ Error     │
│                                    Payload   │
└──────────────────────────────────────────────┘
```

A system performs a lookup with a single instruction:

```rust
let payload: *const u8 = unsafe { *lookup_table.add(entity_id as usize) };
```

No hash map. No binary search. No cache-miss chain. The entity ID is the array index, and the array is contiguous.

### The Flutter FFI Bridge — The Blind Painter

Flutter is not part of the engine. It is a display terminal that happens to run on the same device.

Dart has no knowledge of entities, payloads, systems, or simulation logic. It knows only:

1. A pointer to `MalphasDoubleBufferBridge`.
2. How many commands are in the front buffer.
3. How to paint a rectangle from raw fields.

```rust
#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32,
    pub _padding0: u32,
    pub buffer_a_commands: *mut DartRenderCommand,
    pub buffer_b_command_count: AtomicU32,
    pub _padding1: u32,
    pub buffer_b_commands: *mut DartRenderCommand,
    pub atomic_back_index: AtomicU8,
    pub _padding2: u8,
    pub _padding3: u8,
    pub _padding4: u8,
    pub commands_written: AtomicU32,
    pub _padding5: u32,
    pub _padding6: u32,
    pub _padding7: u64,
    pub _padding8: u64,
}                                  // = 64 bytes

#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,   // 1 = rectangle
    pub layer: u8,          // paint order
    pub pad: u16,           // alignment
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,    // 0xAARRGGBB
}                           // = 24 bytes
```

Frame sequence:

```text
Flutter VSync
│
├─▶ trigger_engine_pulse()
│    │
│    ├─▶ Rust writes into back buffer via MXC malphas_tick()
│    │
│    └─▶ Rust flips atomic_back_index (Release ordering)
│
├─▶ Dart reads atomic_back_index (Acquire ordering)
│    │
│    └─▶ front buffer = buffer opposite to back_index
│
└─▶ PrimitiveCanvas iterates front_commands[..front_count]
     └── Canvas.drawRect(commands[i])
```

No `List<DartRenderCommand>`. No `jsonDecode`. No per-frame allocation. There is a pointer, an atomic count, and a `Canvas.drawRect`.

---

## Security Model

v2.8.0 makes the supply chain auditable and the runtime fail-safe.

| Asset | Protection |
|-------|------------|
| Engine library (`malphas_core`) | Ed25519 sidecar signature verified before Flutter loads it. |
| MSP data pack | Ed25519 sidecar signature (`.msp.sig`) verified before `mmap`. |
| MXC system library | Ed25519 sidecar signature (`.sig`) verified before `dlopen`. |
| Trust anchor | Configurable at runtime via `setTrustAnchor` / `set_trust_anchor`. |
| System loading | Path sandbox: only paths under `systems/`, `packages/`, or `motors/` are allowed. |
| Panic isolation | `catch_unwind` around system `init` and `tick`; a panicking system is tainted, not the engine. |
| Integrity utilities | Streaming SHA-256, constant-time comparison, ZIP bomb/symlink defences. |

The default trust anchor in the repository is a **test-only keypair**. Production releases must call `setTrustAnchor` with their own Ed25519 public key.

For local development you can set `MALPHAS_INSECURE_SKIP_VERIFY=1`. **Never use this in production.**

---

## Continuous Integration

Every push to `main` is verified by:

| Workflow | What it checks |
|---|---|
| **Rust CI** | `cargo fmt`, `cargo clippy --all-targets`, `cargo test --release --locked`, security tests, and native artifact signing. |
| **Flutter CI** | Flutter analyze, unit/integration tests against the downloaded native motor, and manifest compilation. |
| **Flutter Lint** | Dart format, `flutter analyze`, and headless Flutter tests. |
| **Flutter Windows Release Build** | Full Windows release build and artifact packaging. |
| **Android Build** | Cross-compilation for `arm64-v8a`, `armeabi-v7a`, and `x86_64` plus `.so` signing. |
| **Native Core Release Build** | Production-ready native libraries for all desktop platforms. |

All workflows now pass on Ubuntu, macOS, and Windows.

---

## Build and Run

### Rust

```bash
# Engine, CLI, and example system
cargo build --release --package malphas_core
cargo build --release --package malphas_cli
cargo build --release --package bouncing_demo

# Strict verification
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --release --locked
```

### Example MSP

```bash
# Build the MSP from the manifest
cargo run --release -p malphas-cli -- compile examples/bouncing_demo/manifest.json
```

This generates `examples/bouncing_demo/bouncing_demo.msp` and `examples/bouncing_demo/bindings.rs`.

To sign the artifacts for a non-test trust anchor:

```bash
export MALPHAS_SIGNING_KEY="<32-byte-hex-private-key>"
cargo run --release -p malphas-cli -- sign examples/bouncing_demo/bouncing_demo.msp
```

### Flutter

```bash
cd flutter_app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

### Cross-platform build scripts

```bash
# Linux / macOS / Git Bash on Windows
./build.sh

# Windows PowerShell
.\build_core.ps1
```

Both scripts build `malphas_core`, `malphas_cli`, and `bouncing_demo`, timestamp the native motor, keep the three most recent motors, and deploy non-timestamped copies plus signatures to the workspace root and existing Flutter build directories.

---

## Example

The repository includes a working `bouncing_demo` package under `examples/bouncing_demo/`:

```bash
./build_core.ps1                              # or ./build.sh
cargo run --release -p malphas-cli -- compile examples/bouncing_demo/manifest.json
cd flutter_app && flutter run
```

The Flutter workspace auto-loads the demo on startup: it initializes the engine, loads the MSP, loads the `.mxc` system, and pulses the engine on every VSync.

---

## Testing

| Suite | Command |
|-------|---------|
| Rust formatting | `cargo fmt -- --check` |
| Rust lints | `cargo clippy --all-targets -- -D warnings` |
| Rust tests | `cargo test --release --locked` |
| Security tests | `cargo test --release --locked --test security_tests` |
| Flutter analyze | `cd flutter_app && flutter analyze --no-fatal-infos` |
| Flutter format | `cd flutter_app && dart format --set-exit-if-changed .` |
| Flutter tests | `cd flutter_app && flutter test` |

On Linux and macOS, set `LD_LIBRARY_PATH` so Flutter tests can find the motor:

```bash
export LD_LIBRARY_PATH="$PWD/flutter_app/motors:$LD_LIBRARY_PATH"
cd flutter_app && flutter test
```

---

## Verification Commands

```bash
# No broken alignments
git grep "align(16)" || echo "OK: no align(16) found"

# No OOP in the core
git grep -i "class.*Object" malphas_core/ || echo "OK: no object classes in Rust"

# Critical structures are 64 bytes
grep -n "size_of::<MspHeader>()" malphas_core/src/msp_loader.rs
grep -n "size_of::<MspEntityDescriptor>()" malphas_core/src/msp_loader.rs
grep -n "size_of::<MalphasDoubleBufferBridge>()" malphas_core/src/pipeline.rs
```

---

## Glossary

| Term | Definition | What it is NOT |
|------|------------|----------------|
| **Entity** | A relational `u32` (`entity_id`). An index into a flat table. | A class, object, GameObject, or component. |
| **Payload** | A raw, 64-byte-aligned byte block pointed to by the Silver Platter. | An object, asset, or interface-bearing type. |
| **Silver Platter** | A flat array of `*const u8` built at MSP load time. | A hash map, dictionary, tree, or runtime lookup structure. |
| **System (.mxc)** | A native `cdylib` that consumes payloads and writes render commands. | A script, VM bytecode, class, or service locator. |
| **MSP** | Malphas Source Pack. Immutable, 64-byte-aligned binary data file. | A scene file, JSON document, or archive. |
| **MXC** | Malphas eXecutable Core. Stateless native dynamic library exporting `malphas_init_system` and `malphas_tick`. | A plugin that depends on engine internals. |
| **Environment** | An MSP mapped into memory plus one or more loaded MXC systems. | A scene graph or object hierarchy. |
| **FFI Bridge** | `MalphasDoubleBufferBridge`. A 64-byte shared-memory structure between Rust and Dart. | A message bus, event channel, or serialization protocol. |

**Golden rule:** if you use the words "object", "method", "class", "component", or "skin" inside the core, you have lost the game.

---

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full process.

In short:

1. Every shared structure must be `#[repr(C)]` or `#[repr(C, align(64))]` and its size must be a multiple of 64.
2. No `.mxc` system may mutate the MSP or make FFI calls back into the core during `tick`.
3. Dart only reads pointers; it never builds objects per frame.
4. `cargo fmt`, `cargo clippy --all-targets -- -D warnings`, `cargo test --release --locked`, `flutter analyze`, and `flutter test` must pass.

---

## License

MIT — see [`LICENSE`](LICENSE).
