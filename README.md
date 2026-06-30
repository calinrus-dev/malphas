# Malphas Engine v2.10.0

[![CI](https://github.com/calinrus-dev/malphas/actions/workflows/rust_ci.yml/badge.svg)](https://github.com/calinrus-dev/malphas/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/Rust-1.79%2B-orange.svg)](https://rust-lang.org)
[![Flutter](https://img.shields.io/badge/Flutter-3.22%2B-02569B.svg)](https://flutter.dev)

> **A zero-copy, cache-aligned, Data-Oriented Design runtime.**
> Logic runs in native metal. The UI is a dumb terminal. Memory is the API.

---

## The Problem

Modern software is a stack of bloated abstractions. A chat application consumes 500 MB of RAM because it embeds an entire web browser. A game engine ships with a garbage collector that pauses your frame loop to clean up strings. Platform vendors close APIs on a whim, rendering yesterday's architecture obsolete.

We built Malphas to escape this trap.

Malphas is not a framework. It is a **sovereign execution environment**: a native runtime that owns its memory, verifies its binaries, and renders through Flutter without ever letting Flutter touch the logic. If a platform vendor restricts tomorrow's APIs, your engine survives. The UI is replaceable. The silicon is yours.

---

## What Malphas Is

Malphas is a **Data-Oriented Design (DOD) engine** that separates three concerns with surgical precision:

1. **Data** — Immutable, cache-aligned, memory-mapped binary packages (`.msp`).
2. **Logic** — Stateless, signed, native dynamic libraries (`.mxc`).
3. **Vision** — A zero-copy Flutter canvas that reads native command buffers via FFI.

You edit resources in a visual workspace. The CLI compiles them into a flat binary. The engine maps that binary into RAM and injects a pointer table into your logic. The UI reads the result directly from shared memory. No serialization. No garbage collection in the hot path. No frameworks between your code and the CPU cache.

---

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    FLUTTER (The Blind Painter)               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Workspace  │  │   Engine    │  │  PrimitiveCanvas    │  │
│  │   Editor    │  │  Controller │  │  (FFI zero-copy)    │  │
│  │  (No-Code)  │  │             │  │                     │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                     │             │
│    compile             load_msp            read commands    │
│         │                │                     │             │
└─────────┼────────────────┼─────────────────────┼─────────────┘
          │                │                     │
          │                │                     │
          ▼                ▼                     ▼
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │  .msp file   │  │  Rust Core   │  │  .mxc file   │
   │  (Entities + │  │  (Memory     │  │  (Stateless  │
   │   Payloads)  │  │   Router)    │  │   Logic)     │
   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
          │                 │                 │
          └─────────────────┴─────────────────┘
                            │
                     ┌──────┴──────┐
                     │    mmap     │
                     │  (read-only)│
                     └─────────────┘
```

**The flow:**

1. You create **Entities** (`u32` IDs) and assign **Payloads** (raw assets) in the workspace.
2. `malphas-cli compile` flattens the workspace into a 64-byte aligned `.msp` binary.
3. The Rust core `mmap`s the `.msp` into virtual memory.
4. It builds the **Silver Platter**: a flat array of pointers where `table[entity_id]` points directly to the entity's payload in the mapped memory.
5. It loads your `.mxc` system (verified by Ed25519 signature), injects the Silver Platter, and starts the tick loop.
6. Your system writes `DartRenderCommand` structs into a double-buffer shared with Flutter.
7. Flutter's `CustomPainter` reads those commands via FFI and draws. Zero copies. Zero allocations. Zero GC pressure.

---

## The Three Laws

These are non-negotiable. They are the axioms of the engine.

| Law | Definition | Violation |
|-----|------------|-----------|
| **Entity** | An immutable `u32` ID. It has no methods, no logic, no state. | Using `class`, `Object`, or inheritance. |
| **Payload** | A 64-byte aligned block of raw memory (texture, audio, geometry). | Nesting objects, JSON parsing, or runtime asset loading. |
| **System** | A compiled `.mxc` dynamic library. Stateless. Logic-only. | Putting simulation logic in the UI, or using GC'd languages for the hot path. |

---

## The Blind Painter

Flutter does not simulate. It does not decide. It does not allocate.

Flutter is a **Blind Painter**: a dumb terminal that reads a native memory buffer and executes draw commands. The buffer is a contiguous array of 64-byte aligned structs written by Rust. Dart reads them via FFI using atomic snapshot getters. No `List.from()`. No `jsonDecode`. No `copyWith`.

If Flutter dies, the engine keeps running. If the engine dies, Flutter shows an error screen. They are decoupled by design.

---

## The Silver Platter

Traditional engines look up assets by string name or hash map. That is a cache miss and a branch misprediction.

Malphas pre-computes a **flat pointer array** at load time:

```rust
let silver_platter: *const *const u8 = ...;
let payload = unsafe { *silver_platter.add(entity_id as usize) };
// Cost: 1 CPU cycle. Zero branches. Zero cache misses.
```

Your `.mxc` system receives this table once at initialization. Every tick, it resolves any entity's data in a single indexed load. This is how a cartridge addressed its ROM in 1990. We brought it back, but with modern cache lines and vectorized math.

---

## Security & Sovereignty

Malphas does not trust its inputs. Every binary is guilty until proven innocent.

- **Ed25519 signatures**: Every `.msp` and `.mxc` carries a sidecar signature. The engine verifies it before `mmap` or `dlopen`.
- **Path sandbox**: No `..`, no absolute paths, no symlinks. Files must resolve under approved workspace roots.
- **Trust anchor**: The public key is injected via secure storage (Android Keystore / iOS Keychain / OS keyring), never hardcoded.
- **Panic isolation**: A buggy or malicious `.mxc` that panics is caught by `catch_unwind`. The system is marked tainted and skipped. The app survives.
- **Read-only data**: The `.msp` is mapped read-only. Systems cannot corrupt their own assets.

This is not paranoia. It is the minimum viable security for a runtime that loads user-generated native code.

---

## What You Can Build

Malphas is agnostic to semantics. The same engine runs a 2D platformer, a CAD interface, or an IoT dashboard.

| Use Case | MSP (Data) | MXC (Logic) | Flutter (UI) |
|----------|------------|-------------|--------------|
| Game | Sprites, tilemaps, sound effects | Physics, collision, AI | HUD, menus, touch controls |
| Professional Tool | Icons, fonts, SVG widgets | Layout engine, event routing | Panels, property editors |
| Simulation | 3D meshes, textures, parameters | Particle systems, solvers | Viewport camera, timeline |
| IoT / Industrial | Sensor configs, alert thresholds | Real-time control loops | Status dashboard, logs |

The community can mod your game by editing the `.msp` (swapping textures, adding entities) without recompiling your `.mxc` logic. As long as the `u32` entity IDs remain stable, the engine never breaks.

---

## Quick Start

```bash
# 1. Build the native core
cargo build --release

# 2. Compile a demo package
cargo run --bin malphas-cli -- compile examples/bouncing_demo/manifest.json

# 3. Run the Flutter frontend
cd flutter_app
flutter pub get
flutter run
```

---

## Technical Glossary

| Term | Definition |
|------|------------|
| Entity | Immutable `u32` identifier. The only handle to an object in the engine. |
| Payload | Raw, 64-byte aligned memory block attached to an entity. No type system overhead. |
| System | Compiled `.mxc` dynamic library containing pure logic. No state except internal SoA arrays. |
| MSP | Malphas Source Pack. A single binary file with all entities, payloads, and indices. Loaded via `mmap`. |
| MXC | Malphas eXecutable Core. A native library loaded at runtime. Verified before execution. |
| Environment | A runtime instance pairing one MSP with one or more MXC systems. |
| Silver Platter | Flat pointer array built by the core. Injected into systems for O(1) payload lookup. |
| Blind Painter | Flutter's rendering layer. Reads native command buffers via FFI without copying or parsing. |

---

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). The short version:

- DOD is mandatory. OOP is forbidden in hot paths.
- Every FFI struct is `#[repr(C, align(64))]`.
- Every `unsafe` block has a `// SAFETY:` comment.
- All code, comments, and docs are in English.
- `cargo clippy --all-targets -- -D warnings` and `flutter analyze` must pass.

---

## License

MIT. See [LICENSE](LICENSE).
