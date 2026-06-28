# MALPHAS — Virtual Console Ecosystem

A high-performance, language-agnostic virtual console and passive deployment server. Malphas separates the logic engine from the graphical renderer through a **zero-copy shared-memory highway**. The Flutter chassis is a pure synchronous rasterizer that reads geometric primitives directly from physical RAM via FFI pointers and strict byte alignment (`#[repr(C)]`).

The intelligent layer — programmable in any language with a **C-ABI** (Rust, Zig, C++) — is free from GC penalties and serialization latency.

---

## Architecture

```
┌─────────────────────────────┐      Zero-Copy Shared Memory
│      Flutter Chassis        │ ◄────────────────────────────┐
│  (Pure Rasterizer @ 120Hz)  │                              │
└─────────────────────────────┘                              │
         │  FFI Bridge                                       │
         ▼                                                   │
┌─────────────────────────────┐                              │
│   malphas_core (Rust/C-ABI) │ ────── Arena ───────────────►│
│   Logic VM + Bytecode       │                              │
└─────────────────────────────┘                              │
         │                                                   │
         └──── DartRenderCommand[] ──────────────────────────┘
```

The virtual canvas is a fixed, normalized **1000×1000 logical unit** coordinate space. Letterboxing preserves aspect ratios on any physical display resolution.

---

## Single-Clock Pulse Engine

The native runtime is driven by a single background simulation thread that pulses at **~120 Hz** (8.33 ms frame budget). Flutter does **not** drive the simulation; it only observes the committed render buffer.

```
Dart:  ticker ──► read atomic_back_index ──► draw front buffer
                       │
Rust:  sleep(8.33ms) ◄─┘
       process_engine_tick_internal()
         ├─ drain input queue
         ├─ execute bytecode per entity
         ├─ write render commands to back buffer
         └─ atomic swap back/front index
```

### Lifecycle Guarantees

* `init_engine` acquires `INIT_LOCK`, stops any previous simulation thread, and **spin-waits** on `ACTIVE_THREADS` until the old thread has truly exited. No arbitrary sleeps are used.
* `shutdown_engine` signals the thread to stop and spin-waits until `ACTIVE_THREADS` reaches zero.
* `ActiveThreadGuard` decrements `ACTIVE_THREADS` even if the thread panics, preventing leaked lifecycle state.

---

## Lock-Free Runtime

### Double-Buffer Command Exchange

The FFI bridge uses two command buffers in shared physical RAM. The engine writes to the **back buffer** while Flutter reads from the **front buffer**.

```rust
#[repr(C, align(16))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: AtomicU8,
    pub commands_written: AtomicU32,
}
```

* `atomic_back_index` selects the back buffer with `Acquire`/`Release` ordering.
* `commands_written` is a diagnostic counter also published with `Release` ordering.
* Flutter reads the atomic index, then treats the opposite buffer as immutable and draws it through raw pointers.

### Bytecode Hot-Swap

Behaviour bytecode is stored in a lock-free `ArcSwap<Box<[u8]>>`. The simulation tick loads an `Arc` snapshot at frame start and executes from that immutable slice for the entire frame. Replacing the bytecode (via `load_resource_pack`) atomically swaps the `Arc` without blocking the engine or invalidating an in-flight tick.

---

## C-ABI FFI Structures (`#[repr(C)]`)

```rust
#[repr(C)]
#[derive(Clone, Copy)]
pub struct DartRenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub pad: u16,       // 2-byte padding to align f32 fields to 4-byte boundaries
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

#[repr(C, align(16))]
pub struct CoreCommandBuffer {
    pub command_count: AtomicU32,
    pub commands: *mut DartRenderCommand,
}
```

* `DartRenderCommand` is 24 bytes with 4-byte alignment.
* `CoreCommandBuffer` is 16 bytes with 16-byte alignment.
* `MalphasDoubleBufferBridge` is 48 bytes with 16-byte alignment.

These sizes and alignments are enforced by unit tests so layouts stay identical on x64, ARM64 and other strict architectures.

---

## Union Text Command

`command_type == 2` is a **text command**. The text command occupies **two consecutive slots** in the command buffer:

1. The first slot is a normal `DartRenderCommand` where:
   * `x`, `y` define the baseline position in logical units.
   * `width` is reused as the font size (32 px baseline).
   * `color_rgba` is the text tint.
2. The second slot stores a raw `*const u8` pointer to the null-terminated UTF-8 string in the Arena.

```
slot i:   DartRenderCommand { command_type=2, ..., width=font_size, color_rgba=tint }
slot i+1: *const u8 ──► "MALPHAS LIVE CORE\0"
```

This union keeps the command stream compact while avoiding extra struct fields or serialization overhead. The rasterizer skips the pointer slot when advancing through the buffer.

---

## Safe Arena Helpers

Direct Dart pointer writes into the shared Arena would race the simulation tick. Instead, all entity setup goes through Rust-gated helpers that acquire `ARENA_WRITE_LOCK`:

| FFI Function | Purpose |
|--------------|---------|
| `set_entities_count(count)` | Write the live entity count. |
| `write_arena_bytes(offset, ptr, len)` | Copy a byte blob into the Arena inside bounds. |
| `set_entity(...)` | Write a full 64-byte entity record. |

The engine tick also holds `ARENA_WRITE_LOCK` while reading entity state, so Dart setup and Rust simulation are mutually exclusive. Pause the engine around multi-step setup to avoid observing torn state between calls.

### Entity Record Layout (64 bytes)

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| `0` | 1 byte | `command_type` | 0 = inactive, 1 = rectangle, 2 = text |
| `1` | 1 byte | `layer` | Draw order layer |
| `4` | 4 bytes | `x` | Logical X position (f32) |
| `8` | 4 bytes | `y` | Logical Y position (f32) |
| `12` | 4 bytes | `width` | Width or font size (f32) |
| `16` | 4 bytes | `height` | Height (f32) |
| `20` | 4 bytes | `color_rgba` | Tint/Colour (u32) |
| `24` | 4 bytes | `speed_x` | Horizontal velocity (f32) |
| `28` | 4 bytes | `speed_y` | Vertical velocity (f32) |
| `32` | 4 bytes | `min_x` | Left bounce bound (f32) |
| `36` | 4 bytes | `max_x` | Right bounce bound (f32) |
| `40` | 4 bytes | `min_y` | Top bounce bound (f32) |
| `44` | 4 bytes | `max_y` | Bottom bounce bound (f32) |
| `48` | 4 bytes | `str_offset` | Arena offset of the entity's text string |

---

## Aligned Native Allocator

All shared buffers (bridge, command arrays, Arena) are allocated through the exported Rust allocator to guarantee **16-byte alignment** on ARM64:

```rust
#[no_mangle]
pub extern "C" fn malphas_alloc(size: usize) -> *mut u8;

#[no_mangle]
pub extern "C" fn malphas_free(ptr: *mut u8, size: usize);
```

Dart must never use `ffi.calloc` for shared-memory buffers because the system allocator may only provide 8-byte alignment.

---

## Binary Resource Package (`.malphas` / `.mhp`)

### MHP Header (`MhpHeader`, 112 bytes)

| Offset | Type | Field | Description |
|--------|------|-------|-------------|
| `0` | `[u8; 4]` | `magic` | ASCII header: `'M', 'L', 'P', 'H'` |
| `4` | `u32` | `version` | Package format version |
| `8` | `u64` | `total_size` | Total package size in bytes |
| `16` | `[u8; 32]` | `checksum` | SHA-256 over payload |
| `48` | `[u8; 16]` | `pack_id` | UTF-8 package identifier |
| `64` | `u16` | `canvas_width` | Virtual canvas width |
| `66` | `u16` | `canvas_height` | Virtual canvas height |
| `68` | `u32` | `font_metrics_offset` | Offset of glyph metrics table |
| `72` | `u32` | `font_atlas_offset` | Offset of A8 font atlas pixels |
| `76` | `u32` | `objects_table_offset` | Offset of object jump directory |
| `80` | `u32` | `objects_table_count` | Number of object descriptors |
| `84` | `u32` | `skins_offset` | Offset of skin/property data pool |
| `88` | `u32` | `skins_size` | Size of skin/property data pool |
| `92` | `u32` | `has_embedded_msp` | `1` if an MSP bytecode blob is embedded |
| `96` | `u32` | `embedded_msp_offset` | Offset of embedded MSP bytecode |
| `100` | `u32` | `embedded_msp_size` | Size of embedded MSP bytecode |
| `104` | `[u8; 8]` | `padding` | Reserved / padding |

### Glyph Metrics Table
Exactly 256 fixed 16-byte blocks (one per ASCII/extended byte value):
- `2 bytes` (uint16): Character code
- `2 bytes` (uint16): X coordinate in the font atlas
- `2 bytes` (uint16): Y coordinate in the font atlas
- `2 bytes` (uint16): Glyph width in pixels
- `2 bytes` (uint16): Glyph height in pixels
- `2 bytes` (int16): Horizontal draw offset (X-offset)
- `2 bytes` (uint16): Cumulative horizontal advance

---

## Bytecode Sandbox VM

Behaviour logic is compiled into binary bytecode and interpreted by a micro-interpreter in the Rust native layer. Each instruction occupies exactly **4 bytes**:
- **Byte 0:** Opcode
- **Byte 1:** Destination register (r0–r7)
- **Bytes 2–3:** 16-bit unsigned constant (`val_u16`)

| Opcode | Mnemonic | Operation |
|--------|----------|-----------|
| `0x00` | HALT | Stop the current VM logic thread |
| `0x01` | LOAD_REG_CONST | Load a 16-bit constant into the destination register |
| `0x02` | ADD_REG | Add source register to destination register |
| `0x03` | SUB_REG | Subtract source register from destination register |
| `0x04` | WRITE_ARENA_F32 | Write register float to a relative entity position in the Arena |
| `0x05` | READ_ARENA_F32 | Read a float from the Arena (entity-relative) into destination register |
| `0x06` | WRITE_ARENA_U8 | Write register byte to the Arena |
| `0x07` | READ_ARENA_U8 | Read a byte from the Arena into destination register |
| `0x08` | JMP_LT | Jump to target instruction if `reg1 < reg2` |
| `0x09` | JMP | Unconditional jump to target instruction |
| `0x0A` | WRITE_ARENA_U32 | Write a 32-bit value to the Arena |
| `0x0B` | MUL_REG | Multiply destination register by source register |
| `0x0C` | DIV_REG | Divide destination register by source register |

---

## Shared Memory Arena Layout

| Arena Offset | Size | Field | Description |
|--------------|------|-------|-------------|
| `0` | 4 bytes | `magic` | `'M', 'A', 'M', 'P'` |
| `4` | 4 bytes | `static_resources_offset` | Load offset of the `.malphas` binary (typically `1024`) |
| `8` | 4 bytes | `static_resources_size` | Size in bytes of the loaded binary resource |
| `12` | 4 bytes | `entities_offset` | Start address of the entity pool (typically `32`) |
| `16` | 4 bytes | `entities_count` | Total number of logical entities registered in current execution |
| `20` | 4 bytes | `font_metrics_offset` | Absolute offset of glyph metrics |
| `24` | 4 bytes | `font_atlas_offset` | Absolute offset of font atlas pixels |
| `28` | 4 bytes | `objects_table_offset` | Absolute offset of the object jump table |

---

## Getting Started

### Dependencies
- [Git](https://git-scm.com)
- [Rust / Cargo](https://rustup.rs) (Edition 2021)
- [Flutter SDK](https://flutter.dev) (stable channel, Dart 3.0+)

### 1. Build the Native Core

```powershell
powershell -ExecutionPolicy Bypass -File .\build_core.ps1
```

This compiles `malphas_core.dll` in release mode and copies it into the Flutter runner directory automatically.

### 2. Run Unit Tests

Rust:
```powershell
cargo test --manifest-path malphas_core/Cargo.toml
```

Flutter:
```powershell
cd flutter_app
flutter test
```

### 3. Launch the Virtual Console

```powershell
cd flutter_app
flutter run -d windows
```

Once running, open the **PACKS** tab, tap the gear icon to open **Package Config**, then press **COMPILE & HOT-SWAP (ZERO-COPY)**. This compiles the font atlas, injects the bytecode into the shared Arena, and begins rasterizing animated entities in real time at 120 Hz.

### 4. Release Build

```powershell
cd flutter_app
flutter build windows --release
```

---

## CI Status

| Workflow | Status |
|----------|--------|
| Flutter CI | ![Flutter CI](https://github.com/calinrus-dev/malphas/actions/workflows/flutter_ci.yml/badge.svg) |
| Flutter Lint | ![Flutter Lint](https://github.com/calinrus-dev/malphas/actions/workflows/flutter_lint.yml/badge.svg) |
| Rust CI | ![Rust CI](https://github.com/calinrus-dev/malphas/actions/workflows/rust_ci.yml/badge.svg) |

---

## License

[MIT](./LICENSE)
