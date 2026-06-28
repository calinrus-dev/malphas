# MALPHAS — Virtual Console Ecosystem

A high-performance, language-agnostic virtual console and passive deployment server. Malphas radically separates the logic engine from the graphical renderer through a **Zero-Copy shared memory highway**, where the Flutter chassis acts as a pure synchronous rasterizer running at up to 120 Hz, reading geometric primitives directly from physical RAM via pointers and strict byte alignment (`#[repr(C)]`).

The intelligent layer — programmable in any language with a **C-ABI** (Rust, Zig, C++) — is completely free from GC penalties and serialization latency.

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

## Zero-Copy Double Buffer Bridge

To eliminate screen tearing and decouple the Flutter UI thread from the native engine's logic thread, FFI communication uses a **double command buffer** in shared physical RAM.

### C-ABI FFI Structures (`#[repr(C)]`)

```rust
#[repr(C)]
pub struct DartRenderCommand {
    pub command_type: u8,
    pub layer: u8,
    pub pad: u16,       // 2-byte padding to align f32 to 4-byte boundaries
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color_rgba: u32,
}

#[repr(C)]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a: CoreCommandBuffer,
    pub buffer_b: CoreCommandBuffer,
    pub atomic_back_index: std::sync::atomic::AtomicU8,
}
```

### Synchronisation Mechanic
1. **Allocation** — Flutter allocates the `MalphasDoubleBufferBridge` and two command arrays (2048 commands each), initialising `atomic_back_index` to `0`.
2. **Native write** — The engine writes into the buffer pointed to by `atomic_back_index` (the *Back Buffer*).
3. **Atomic commit** — On frame completion, the engine performs an atomic swap (`store` with `SeqCst` ordering).
4. **Flutter read @ 120 Hz** — Flutter's hardware ticker reads the atomic index. The *Front Buffer* (not currently being written) is treated as immutable and drawn via raw pointers.

---

## Binary Resource Package (`.malphas`)

| Offset | Type | Field | Description |
|--------|------|-------|-------------|
| `0` | `[u8; 4]` | `magic` | ASCII header: `'M', 'L', 'P', 'H'` |
| `4` | `u32` | `manifest_size` | Size in bytes of the JSON manifest segment |
| `8` | `u32` | `font_metrics_offset` | Start address of the glyph metrics table |
| `12` | `u32` | `font_atlas_offset` | Start address of the A8 font atlas pixels |
| `16` | `u32` | `table_of_jumps_offset` | Start address of the object jump directory |
| `20` | `u32` | `table_of_jumps_size` | Total size of the jump table |
| `24` | `u32` | `bytecode_offset` | Start address of the behaviour bytecode vector |
| `28` | `u32` | `bytecode_size` | Size of the behaviour bytecode binary |
| `32` | `[u8]` | `manifest_data` | Contiguous UTF-8 JSON configuration string |

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
| `28` | 4 bytes | `table_of_jumps_offset` | Absolute offset of the jump table |

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

```powershell
cargo test --manifest-path malphas_core/Cargo.toml
```

### 3. Launch the Virtual Console

```powershell
cd flutter_app
flutter run -d windows
```

Once running, open the **PACKS** tab, tap the gear icon to open **Package Config**, then press **COMPILE & HOT-SWAP (ZERO-COPY)**. This compiles the font atlas, injects the bytecode into the shared Arena, and begins rasterizing animated entities in real time at 120 Hz.

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
