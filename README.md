# Malphas v2.7.0 — Data-Oriented Memory Router

**Malphas is not an object engine. It is a flat memory router.**

This project is a declaration of war against object-oriented code in the hot path. The core is written in Rust, the interface in Flutter, and both communicate through a minimal C-ABI bridge that does not serialize, does not copy, and does not let the Garbage Collector decide when a critical line of code runs.

> **v2.7.0 — The Data-Oriented Router** completely removes the bytecode VM, the entity model with methods, and the shared write Arena. The flow is now simple: flat data on disk (`MSP`) → memory-mapped (`mmap`) → native systems (`MXC`) → raw render commands → screen. Period.

---

## 1. DOD Philosophy (Data-Oriented Design)

Malphas spits on inheritance, virtual methods, and object trees.

- **NO objects in the hot path.** An "entity" is not a class. It is a `u32`.
- **NO Garbage Collector in the critical frame.** Rust owns the memory; Dart only reads pointers.
- **EVERYTHING is aligned to 64 bytes.** Every header, descriptor, and payload respects the size of an L1 cache line. If it does not fit in one line, it does not get in.
- **Zero-copy by design.** An `MSP` on disk is identical to an `MSP` in memory. It is loaded with `mmap`; it is not deserialized.
- **Stateless by contract.** `.mxc` systems receive a read-only pointer table (Silver Platter) and keep their own flat state in contiguous arrays (SoA). They never mutate the MSP.

If you are still thinking in `object.update()`, you are in the wrong engine.

---

## 2. Architecture: MSP and MXC

### 2.1 MSP — Malphas Source Pack

The `MSP` is Malphas' flat data unit. It is a rigid, 64-byte-aligned binary file composed of:

1. **`MspHeader`** (64 bytes): `MLPS` magic, version, offsets, checksum.
2. **`MspEntityDescriptor[]`** (64 bytes each): maps `entity_id` → payload offset/size.
3. **Payload section**: raw memory blobs, each aligned to 64 bytes. The last 64 KB are reserved for *Error Payloads*: a safe fallback for invalid IDs.

```rust
#[repr(C, align(64))]
pub struct MspHeader {
    pub magic: [u8; 4],              // 4 bytes
    pub version: u32,                // 4 bytes
    pub entity_table_offset: u32,    // 4 bytes
    pub entity_count: u32,           // 4 bytes
    pub payload_section_offset: u32, // 4 bytes
    pub payload_section_size: u32,   // 4 bytes
    pub checksum: u64,               // 8 bytes
    pub _padding: [u8; 32],          // 32 bytes
}                                   // = 64 bytes, 1 cache line

#[repr(C, align(64))]
pub struct MspEntityDescriptor {
    pub entity_id: u32,              // 4 bytes
    // 4 bytes of implicit padding to align tag_mask
    pub tag_mask: u64,               // 8 bytes
    pub payload_offset: u32,         // 4 bytes
    pub payload_size: u32,           // 4 bytes
    pub _padding: [u8; 40],          // 40 bytes
}                                   // = 64 bytes, 1 cache line
```

On load, `malphas_core` builds the **Silver Platter**: a flat array of `*const u8` pointers indexed by `entity_id`. Systems do `unsafe { *lookup_table.add(id) }` and they already have their payload. No hash maps. No methods. No indirections.

### 2.2 MXC — Malphas eXecutable Core

An `MXC` is a native dynamic library (`dll`/`so`/`dylib`) that exports exactly two symbols:

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

- `init` runs once to reserve the system's internal SoA state.
- `tick` runs every frame: reads the Silver Platter, mutates its own flat arrays, and writes render commands directly into the FFI bridge back buffer.
- The system **never** writes to the MSP. The MSP is sacred and read-only.

---

## 3. Strict Glossary

| Term | Definition | What it is NOT |
|---|---|---|
| **Entity** | A relational `u32` (`entity_id`). An index into a table. | A class. It has no methods, state, or behavior. |
| **Payload** | A raw byte block, aligned to 64 bytes, pointed to by the Silver Platter. | An object. It has no interface. It is flat memory interpreted by the system. |
| **Silver Platter** | Flat array of `*const u8` built when loading the MSP. `lookup_table[entity_id]` returns the payload. | A map, dictionary, or lookup structure. |
| **System (.mxc)** | Native dynamic library that consumes payloads and writes commands. | An interpreted script, a class, or a virtual machine. |
| **Environment** | An MSP mapped into memory plus one or more loaded systems. | A scene with GameObjects. |
| **FFI Bridge** | `MalphasDoubleBufferBridge`: 64 bytes shared between Rust and Dart. | A message bus, JSON, or event channel. |

**Golden rule:** if you say "object", "method", or "class" inside the core, you have lost the game.

---

## 4. The Flutter FFI Bridge — The Blind Painter

Flutter is not an engine. It is a rendering terminal.

Dart knows nothing about entities, payloads, or game logic. It only knows a pointer to `MalphasDoubleBufferBridge` and the golden rule of the double-buffer:

```rust
#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32, // 4
    pub _padding0: u32,                    // 4
    pub buffer_a_commands: *mut DartRenderCommand, // 8
    pub buffer_b_command_count: AtomicU32, // 4
    pub _padding1: u32,                    // 4
    pub buffer_b_commands: *mut DartRenderCommand, // 8
    pub atomic_back_index: AtomicU8,       // 1
    pub _padding2: u8,                     // 1
    pub _padding3: u8,                     // 1
    pub _padding4: u8,                     // 1
    pub commands_written: AtomicU32,       // 4
    pub _padding5: u32,                    // 4
    pub _padding6: u32,                    // 4
    pub _padding7: u64,                    // 8
    pub _padding8: u64,                    // 8
}                                          // = 64 bytes
```

Every frame Flutter does:

1. `trigger_engine_pulse()` → wakes up the Rust thread.
2. Rust runs `tick` of the systems loaded into the **back buffer**.
3. Rust flips `atomic_back_index` with Release/Acquire ordering.
4. Dart reads the opposite **front buffer** using `get_back_index()`.
5. `PrimitiveCanvas` iterates the raw commands directly from the native pointer and paints them.

```rust
#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,   // 1 = rect, 2 = text marker
    pub layer: u8,          // paint order
    pub pad: u16,           // alignment
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,    // 0xAARRGGBB
}                           // = 24 bytes
```

No `List<DartRenderCommand>`. No `fromJson`. No `copyWith`. There is a pointer, an atomic count, and a `Canvas.drawRect`.

---

## 5. Data Flow in a Frame

```
Disk
 ├── bouncing_demo.msp   (MSP) ──mmap──► RAM: Silver Platter
 └── bouncing_demo.mxc   (MXC) ──dlopen► Rust: loaded system

Flutter VSync
 └── trigger_engine_pulse()
      └── Rust tick_systems(lookup_table, back_buffer)
           └── MXC malphas_tick() writes DartRenderCommand[]
      └── flip atomic_back_index

Flutter Paint
 └── PrimitiveCanvas
      └── front_commands = buffer opposite to back_index
      └── for i in 0..front_count: Canvas.drawRect(commands[i])
```

---

## 6. Build and Run

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

## 7. Architectural Verification Commands

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

## 8. Contribution Contract

If you send a PR:

1. Every shared structure must be `#[repr(C)]` or `#[repr(C, align(64))]` and its size must be a multiple of 64.
2. No `.mxc` system may mutate the MSP or make FFI calls back into the core during `tick`.
3. Dart only reads pointers; it never builds objects per frame.
4. `cargo fmt`, `cargo clippy --release -- -D warnings`, `cargo test --release`, `flutter analyze`, and `flutter test` must pass.

Read `CONTRIBUTING.md` for the full process.

---

## 9. License

MIT — see `LICENSE`.
