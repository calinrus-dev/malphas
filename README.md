# Malphas v2.2

A high-performance, terminal-inspired graphical engine with a Rust core and a Flutter frontend. The two sides communicate through a small, explicit C-ABI boundary and share memory directly instead of marshalling messages across an isolating bridge.

## Architecture at a glance

```
Flutter (Dart)                Rust (malphas_core)
------------------            -------------------
Ticker / VSync --------------> trigger_engine_pulse()
   |                                    |
   |                            simulation thread
   |                                    |
   |                            double-buffer bridge
   +<--------------------------- render commands
```

Flutter owns the only clock. Every vertical sync it sends one pulse through `trigger_engine_pulse()`. The Rust simulation thread wakes up, drains pending input, executes one frame of bytecode logic, writes render commands into the back buffer, and flips the bridge. Flutter reads the front buffer on the next frame.

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

- For a rectangle (`command_type == 1`) the float fields are geometry.
- For a text command (`command_type == 2`) the same bytes are reinterpreted:
  - `x` = text length in bytes
  - `y` = style / font size
  - `width` / `height` = low / high 32 bits of a 64-bit pointer to a `TextPayload` in the Arena

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

Malphas packages are self-describing binary blobs with 16-byte aligned headers.

### MHP — Malphas Host Package

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

The header is followed by the font metrics table, the alpha font atlas, the objects table, the data pool, and an optional embedded MSP payload. Every section is padded to a 16-byte boundary before the next section starts. The SHA-256 checksum covers everything after the header.

The alpha font atlas is a 512x512 A8 texture. Dart converts it to `rgba8888` by filling RGB with white and using the stored alpha value as the alpha channel (`rgbaBytes[i * 4 + 3] = alpha`).

### MSP — Malphas Script Package

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

MSP contains sandboxed bytecode for the entity VM. The checksum covers the bytecode payload only. MSP files can be loaded standalone or embedded inside an MHP file.

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

The Rust test suite includes deterministic fuzz tests that exercise the bytecode VM with:

- 100,000 random bytecodes of varying length
- truncated bytecodes
- out-of-bounds jump targets
- misaligned Arena accesses

Unit tests also verify struct sizes and alignments, the 16-byte aligned allocator round-trip, the lock-free bytecode container read latency, and the full engine thread lifecycle.

## Build, test and release

```powershell
# Windows native core release
powershell -ExecutionPolicy Bypass -File .\build_core.ps1

# Rust unit tests
cargo test --manifest-path malphas_core/Cargo.toml --release

# Flutter unit tests
cd flutter_app && flutter test

# Windows release build
cd flutter_app && flutter build windows --release
```

The `build_core.ps1` script compiles `malphas_core.dll` and copies it to the project root, into `flutter_app/`, and into any existing Windows runner build directories.

## Repository layout

```
malphas_core/          Rust cdylib, C-ABI exports, entity VM, package loader
flutter_app/           Flutter UI, FFI bindings, package compiler
  lib/core/ffi/        Dart mirrors of Rust structs and the bindings class
  lib/core/compiler/   MHP/MSP assembler and font-atlas generator
  lib/features/        Engine manager, package manager, workspace UI
.agents/AGENTS.md      Agent conventions, build commands and FFI safety rules
.github/workflows/     CI/CD pipeline (Rust builds first, Flutter consumes artifacts)
```

## License

MIT
