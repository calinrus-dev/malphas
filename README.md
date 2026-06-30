# Malphas v2.7.0 — Zero-Copy, Cache-Aligned, Native Memory Router

**Malphas is not a game engine. It is a memory router.**

A high-performance Data-Oriented Design (DOD) runtime that bypasses managed-language bottlenecks by offloading all logic, state, and render production to native, memory-mapped code. Built for longevity in an ecosystem where garbage collectors, JIT restrictions, and framework churn erode performance sovereignty.

The core is Rust. The display terminal is Flutter. Between them stands a minimal C-ABI bridge that does not serialize, does not copy, and does not ask permission from a garbage collector.

> **v2.7.0 — The Memory Router** removes the bytecode VM, the entity-as-object model, and the shared writable Arena. The pipeline is now: flat data on disk (`MSP`) → memory-mapped (`mmap`) → native systems (`MXC`) → raw render commands → screen. Nothing else is allowed in the hot path.

---

## 1. Executive Summary

Malphas treats memory as the primary interface. Data is not deserialized into objects; it is mapped into address space and routed to native systems as raw pointers. The result is a runtime where:

- **Zero-copy** is the default, not an optimization.
- **Cache alignment** is a first-class contract, not a comment.
- **The hot path contains no objects, no methods, and no GC stalls.**
- **Systems are dependency-free native libraries** that can outlive any UI framework.

This architecture is designed to survive increasingly restricted mobile environments. While managed runtimes trade performance for convenience, Malphas keeps the critical path in native memory that the host OS cannot reinterpret, relocate, or collect.

---

## 2. The Architecture: The Triad

Malphas is composed of three inseparable layers. Each layer has exactly one responsibility and one contract with the next.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MALPHAS v2.7.0                                  │
│                                                                         │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────────────────┐  │
│   │     MSP     │────▶│  Rust Core  │────▶│          MXC            │  │
│   │  (on disk)  │mmap │(Memory Router)│   │  (native system libs)   │  │
│   └─────────────┘     └──────┬──────┘     └─────────────────────────┘  │
│                              │                                          │
│                              ▼                                          │
│                    ┌─────────────────────┐                              │
│                    │   Silver Platter    │                              │
│                    │ (lookup table of    │                              │
│                    │  payload pointers)  │                              │
│                    └─────────────────────┘                              │
│                              │                                          │
│                              ▼                                          │
│                    ┌─────────────────────┐                              │
│                    │  MalphasDouble      │                              │
│                    │  BufferBridge       │                              │
│                    │  (FFI shared mem)   │                              │
│                    └─────────────────────┘                              │
│                              │                                          │
│                              ▼                                          │
│                    ┌─────────────────────┐                              │
│                    │   Flutter Canvas    │                              │
│                    │   (Blind Painter)   │                              │
│                    └─────────────────────┘                              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.1 MSP — Malphas Source Pack

The MSP is the immutable data unit of Malphas. It is a rigid, 64-byte-aligned binary file that is **byte-identical on disk and in memory**.

Layout:

```
MSP File
├── MspHeader                 64 bytes
├── Entity Table              entity_count × 64 bytes
│   ├── MspEntityDescriptor[0]
│   ├── MspEntityDescriptor[1]
│   └── ...
└── Payload Section           aligned to 64 bytes
    ├── Payload[0]
    ├── Payload[1]
    └── ...
    └── Error Payload Reserve 64 KB (safe fallback for invalid IDs)
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
}                                   // = 64 bytes, exactly 1 cache line

#[repr(C, align(64))]
pub struct MspEntityDescriptor {
    pub entity_id: u32,              // the u32 identity
    // 4 bytes implicit padding
    pub tag_mask: u64,               // filter bits
    pub payload_offset: u32,         // byte offset into payload section
    pub payload_size: u32,           // byte length of payload
    pub _padding: [u8; 40],          // pad to 64 bytes
}                                   // = 64 bytes, exactly 1 cache line
```

Key properties:

- **Entity ≠ Object.** An entity is a `u32` index. It has no methods, no vtable, and no lifecycle beyond its index.
- **Payload ≠ Object.** A payload is a raw byte block. Its meaning is defined by the system that consumes it, not by a class hierarchy.
- **Loading is mapping.** The core loads an MSP with `mmap`. There is no parser, no allocator, and no deserialization step in the hot path.
- **Immutable by contract.** Once mapped, the MSP is read-only. Systems that mutate it are broken and will be rejected.

### 2.2 MXC — Malphas eXecutable Core

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
- **The system never writes to the MSP.** The MSP is sacred.
- **The system never calls back into the core.** No dynamic dispatch, no runtime services, no framework hooks.

This makes an MXC a self-contained unit of execution. It can be compiled today, signed, shipped, and loaded tomorrow without recompiling the engine.

### 2.3 The Memory Router — Rust Core

The Rust core has one job: keep the hot path as a straight line through memory.

When an MSP is loaded:

1. The file is `mmap`-ed into the process.
2. The header and entity table are validated.
3. The core builds the **Silver Platter**: a flat array of `*const u8` where index `i` points directly to the payload of entity `i`.

```
Silver Platter
┌─────────────────────────────────────────────┐
│ lookup_table[0] ──────▶ Payload[0]          │
│ lookup_table[1] ──────▶ Payload[1]          │
│ lookup_table[2] ──────▶ Payload[2]          │
│ ...                                         │
│ lookup_table[N] ──────▶ Error Payload       │
└─────────────────────────────────────────────┘
```

A system performs a lookup with a single instruction:

```rust
let payload: *const u8 = unsafe { *lookup_table.add(entity_id as usize) };
```

No hash map. No binary search. No cache miss chain. The entity ID is the array index, and the array is contiguous. This is 0-cycle logical lookup time; the real cost is one cache-line fetch, which is unavoidable.

The core also owns the double-buffer bridge, spawns the background tick thread, and enforces the ordering guarantees between Rust producer and Dart consumer.

---

## 3. The Flutter FFI Bridge — The Blind Painter

Flutter is not part of the engine. It is a display terminal that happens to run on the same device.

Dart has no knowledge of entities, payloads, systems, or simulation logic. It knows only:

1. A pointer to `MalphasDoubleBufferBridge`.
2. How many commands are in the front buffer.
3. How to paint a rectangle from raw fields.

```rust
#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32,         // 4
    pub _padding0: u32,                            // 4
    pub buffer_a_commands: *mut DartRenderCommand, // 8
    pub buffer_b_command_count: AtomicU32,         // 4
    pub _padding1: u32,                            // 4
    pub buffer_b_commands: *mut DartRenderCommand, // 8
    pub atomic_back_index: AtomicU8,               // 1
    pub _padding2: u8,                             // 1
    pub _padding3: u8,                             // 1
    pub _padding4: u8,                             // 1
    pub commands_written: AtomicU32,               // 4
    pub _padding5: u32,                            // 4
    pub _padding6: u32,                            // 4
    pub _padding7: u64,                            // 8
    pub _padding8: u64,                            // 8
}                                                  // = 64 bytes
```

```rust
#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,   // 1 = rectangle, 2 = text marker
    pub layer: u8,          // paint order
    pub pad: u16,           // alignment
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,    // 0xAARRGGBB
}                           // = 24 bytes
```

### Frame sequence

```
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

No `List<DartRenderCommand>`. No `jsonDecode`. No `copyWith`. No per-frame allocation. There is a pointer, an atomic count, and a `Canvas.drawRect`.

This is the **Blind Painter** pattern: the UI renders what it is told to render, as fast as the memory bus allows, without understanding what it means.

---

## 4. Data-Oriented Workflow

A workspace starts as human-readable source files and ends as cache-perfect silicon binaries.

```
Workspace Source
├── manifest.json              // human-readable entity declarations
├── payload_0.bin              // raw entity data
├── payload_1.bin
└── ...

        │ malphas-cli compile
        ▼

Output Binaries
├── package.msp                // 64-byte-aligned binary pack
├── package.mxc                // native system library (cdylib)
└── bindings.rs                // inlined entity/tag constants
```

The CLI:

1. Reads the manifest and validates IDs, tag masks, and payload paths.
2. Builds the MSP header and entity descriptors with exact 64-byte layout.
3. Pads every payload to a 64-byte boundary.
4. Reserves the trailing 64 KB error-payload region.
5. Computes a deterministic checksum over the binary.
6. Generates `bindings.rs` so systems can inline entity constants at `-O3`.

The result is a binary that is ready to be `mmap`-ed and executed without further transformation.

---

## 5. Why This Survives

Managed runtimes are not getting faster relative to hardware constraints. They are getting more restricted. Malphas sidesteps the problem by keeping the critical path outside the managed domain:

- **Memory sovereignty.** Native memory mapped from a file cannot be relocated or collected by the host runtime.
- **Framework decoupling.** An MXC depends only on the C ABI. If Flutter disappears, the systems survive.
- **Deterministic cache behavior.** Every hot-path structure is sized to a cache line. No hidden allocations, no surprise pauses.
- **Signature verification.** Engine binaries and MSP files can be signed and verified before load, making the supply chain auditable.

The UI is replaceable. The data format is stable. The systems are sovereign.

---

## 6. Technical Glossary

| Term | Definition | What it is NOT |
|---|---|---|
| **Entity** | A relational `u32` (`entity_id`). An index into a flat table. | A class, object, GameObject, or component. |
| **Payload** | A raw, 64-byte-aligned byte block pointed to by the Silver Platter. | An object, asset, or interface-bearing type. |
| **Silver Platter** | A flat array of `*const u8` built at MSP load time. `lookup_table[entity_id]` yields the payload pointer. | A hash map, dictionary, tree, or runtime lookup structure. |
| **System (.mxc)** | A native `cdylib` that consumes payloads and writes render commands. | A script, VM bytecode, class, or service locator. |
| **MSP** | Malphas Source Pack. Immutable, 64-byte-aligned binary data file. | A scene file, JSON document, or archive. |
| **MXC** | Malphas eXecutable Core. Stateless native dynamic library exporting `malphas_init_system` and `malphas_tick`. | A plugin that depends on engine internals. |
| **Environment** | An MSP mapped into memory plus one or more loaded MXC systems. | A scene graph or object hierarchy. |
| **FFI Bridge** | `MalphasDoubleBufferBridge`. A 64-byte shared-memory structure between Rust and Dart. | A message bus, event channel, or serialization protocol. |

**Golden rule:** if you use the words "object", "method", "class", "component", or "skin" inside the core, you have lost the game.

---

## 7. Build and Run

### Rust

```bash
# Engine, CLI, and example system
cargo build --release --package malphas_core
cargo build --release --package malphas_cli
cargo build --release --package bouncing_demo

# Strict verification
cargo fmt -- --check
cargo clippy --release -- -D warnings
cargo test --release
```

### Example MSP

```bash
# Build the MSP from the v2.7.0 manifest
cargo run --release -p malphas_cli -- compile examples/bouncing_demo/manifest.json
```

This generates `examples/bouncing_demo/bouncing_demo.msp` and `examples/bouncing_demo/bindings.rs`.

### Flutter

```bash
cd flutter_app
flutter pub get
flutter analyze --no-fatal-infos
flutter test
dart format .
```

---

## 8. Architectural Verification Commands

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

## 9. Contribution Contract

If you send a PR:

1. Every shared structure must be `#[repr(C)]` or `#[repr(C, align(64))]` and its size must be a multiple of 64.
2. No `.mxc` system may mutate the MSP or make FFI calls back into the core during `tick`.
3. Dart only reads pointers; it never builds objects per frame.
4. `cargo fmt`, `cargo clippy --release -- -D warnings`, `cargo test --release`, `flutter analyze`, and `flutter test` must pass.

Read `CONTRIBUTING.md` for the full process.

---

## 10. License

MIT — see `LICENSE`.
