# FFI Contract

This document is the authoritative specification of the Rust/Dart FFI boundary
for Malphas v3.0.0.  Both sides must keep these layouts, alignments, and memory
ordering guarantees in lockstep.

## `MalphasDoubleBufferBridge`

```rust
#[repr(C, align(64))]
pub struct MalphasDoubleBufferBridge {
    pub buffer_a_command_count: AtomicU32, // bytes  0.. 4
    pub abi_version: u32,                  // bytes  4.. 8
    pub buffer_a_commands: *mut DartRenderCommand, // bytes  8..16
    pub buffer_b_command_count: AtomicU32, // bytes 16..20
    pub _padding1: u32,                    // bytes 20..24
    pub buffer_b_commands: *mut DartRenderCommand, // bytes 24..32
    pub atomic_back_index: AtomicU8,       // byte  32
    pub _padding2: u8,                     // byte  33
    pub _padding3: u8,                     // byte  34
    pub _padding4: u8,                     // byte  35
    pub commands_written: AtomicU32,       // bytes 36..40
    pub _padding5: u32,                    // bytes 40..44
    pub _padding6: u32,                    // bytes 44..48
    pub _padding7: u64,                    // bytes 48..56
    pub _padding8: u64,                    // bytes 56..64
} // Total: 64 bytes, 64-byte aligned.
```

| Field | Offset | Size | Notes |
|-------|--------|------|-------|
| `buffer_a_command_count` | 0 | 4 | Atomic; written by Rust with `Release`. |
| `abi_version` | 4 | 4 | Constant after init; equals `BRIDGE_ABI_VERSION`. |
| `buffer_a_commands` | 8 | 8 | Pointer to back or front buffer A. |
| `buffer_b_command_count` | 16 | 4 | Atomic; written by Rust with `Release`. |
| `_padding1` | 20 | 4 | Unused. |
| `buffer_b_commands` | 24 | 8 | Pointer to back or front buffer B. |
| `atomic_back_index` | 32 | 1 | Atomic; flipped by Rust with `Release`. |
| `_padding2.._padding4` | 33 | 3 | Unused. |
| `commands_written` | 36 | 4 | Atomic; total commands written in last tick. |
| `_padding5.._padding8` | 40 | 24 | Unused. |

- **Total size:** 64 bytes.
- **Alignment:** 64 bytes.
- **Allocator:** Rust owns the bridge and the two command buffers.  Dart must
  not allocate, reallocate, or free them.

## `DartRenderCommand`

```rust
#[repr(C, align(64))]
pub struct DartRenderCommand {
    pub cmd_type: u32,   // bytes  0.. 4
    pub entity_id: u32,  // bytes  4.. 8
    pub x: f32,          // bytes  8..12
    pub y: f32,          // bytes 12..16
    pub width: f32,      // bytes 16..20
    pub height: f32,     // bytes 20..24
    pub color: u32,      // bytes 24..28
    pub payload_id: u32, // bytes 28..32
    pub _padding: [u32; 8], // bytes 32..64
} // Total: 64 bytes, 64-byte aligned.
```

| Field | Offset | Size | Meaning |
|-------|--------|------|---------|
| `cmd_type` | 0 | 4 | `1` = rectangle; `2` = text; `3` = sprite. |
| `entity_id` | 4 | 4 | Source entity identifier. |
| `x` | 8 | 4 | Rectangle: top-left X.  Text: font size / style. |
| `y` | 12 | 4 | Rectangle: top-left Y.  Text: reserved. |
| `width` | 16 | 4 | Rectangle: width.  Text/Sprite: low 32 bits of payload pointer. |
| `height` | 20 | 4 | Rectangle: height.  Text/Sprite: high 32 bits of payload pointer. |
| `color` | 24 | 4 | Packed `0xAARRGGBB` color. |
| `payload_id` | 28 | 4 | Asset or payload slot reference. |
| `_padding` | 32 | 32 | Reserved; must be zero. |

- **Total size:** 64 bytes.
- **Alignment:** 64 bytes.
- Dart must not perform pointer arithmetic on the command array; use
  `Pointer<DartRenderCommand>.elementAt(i)` with the count returned by Rust.

## Atomic Ordering

The double-buffer protocol is intentionally minimal:

1. Rust writes render commands into the **back buffer** (the buffer opposite to
   `atomic_back_index`).
2. Rust stores the new command count into the back buffer's
   `buffer_*_command_count` with `Ordering::Release`.
3. Rust stores the total into `commands_written` with `Ordering::Release`.
4. Rust flips `atomic_back_index` with `Ordering::Release`.
5. Dart reads `atomic_back_index` only through `get_back_index`, which uses
   `Ordering::Acquire`.
6. Dart treats the buffer opposite to the read back index as the **front buffer**.
7. Dart reads the front buffer count through `get_buffer_a_command_count` or
   `get_buffer_b_command_count`, which use `Ordering::Acquire`.

This Release/Acquire pair guarantees Dart never sees stale command data from
before the flip.

## Version Policy

The bridge embeds `BRIDGE_ABI_VERSION`:

```rust
pub const BRIDGE_ABI_VERSION: u32 = 0x03000000;
```

Format: `0xMMmmpp00`, where `MM` = major, `mm` = minor, `pp` = patch.  For
v3.0.0 this is `0x03000000`.

`initEngine` in Dart must read `bridge.abiVersion` (or call a Rust getter) and
refuse to run if the value is not `0x03000000`.  A mismatch means the Dart
binding and the native library are out of sync and the layout is not safe to
use.

## Allocation Ownership

| Resource | Owner | Notes |
|----------|-------|-------|
| `MalphasDoubleBufferBridge` | Rust | Allocated by `init_engine`, freed by `shutdown_engine`. |
| Command buffers A and B | Rust | Same lifetime as the bridge. |
| MSP mmap | Rust | Released when `unload_msp` / `shutdown_engine` runs. |
| Loaded `.mxc` libraries | Rust | Unloaded when `clear_systems` / `shutdown_engine` runs. |
| `malphas_alloc` memory | Rust/Dart shared | Allocated by Rust; caller must later call `malphas_free` with the same pointer. |

Dart must never:

- Allocate its own `MalphasDoubleBufferBridge` or command buffers.
- Free the bridge pointer returned by `init_engine`.
- Cache command-buffer pointers across engine shutdown/restart.
- Read atomic fields directly by copying the struct; always use the exported
  getter functions with Acquire ordering.

## Engine Lifecycle Functions

### `init_engine(max_commands: u32) -> *mut MalphasDoubleBufferBridge`

- Returns a non-null bridge pointer on success.
- Returns `null` if `max_commands == 0`, allocation fails, or the engine is
  already shutting down.
- Spawns a background simulation thread driven by `trigger_engine_pulse`.

### `shutdown_engine() -> i32`

- Stops the simulation thread, frees the bridge and command buffers, unloads the
  MSP, and clears loaded systems.
- Returns `0` on success.

### `trigger_engine_pulse() -> i32`

| Code | Meaning |
|------|---------|
| `0`  | Pulse sent successfully. |
| `-1` | Engine not running. |
| `-2` | Pulse lock poisoned. |
| `-3` | Pulse channel not yet initialized. |
| `-4` | Failed to send pulse (receiver dropped). |

### `pause_engine(paused: i32) -> i32`

- `paused != 0` pauses tick processing; pulses are still accepted but ticks are
  skipped.
- Returns `0`.

## System Loading and Integrity Functions

### `set_trust_anchor(public_key_hex: *const c_char) -> i32`

| Code | Meaning |
|------|---------|
| `0`  | Trust anchor configured. |
| `-1` | Null or invalid C string. |
| `-2` | Hex decode error. |
| `-3` | Invalid public key length. |
| `-4` | Invalid Ed25519 public key. |
| `-5` | Other error. |

### `load_system(filepath: *const c_char) -> i32`

| Code | Meaning |
|------|---------|
| `0`  | System loaded and initialized. |
| `-1` | Null or invalid path. |
| `-200` | Failed to open the dynamic library. |
| `-201` | Missing `malphas_init_system` symbol. |
| `-202` | Missing `malphas_tick` symbol. |
| `-203` | Internal system registry error. |
| `-210` | Sandbox violation (`ERR_SYSTEM_SANDBOX`). |
| `-211` | Missing sidecar signature file. |
| `-212` | Invalid sidecar signature. |
| `-213` | System `init` panicked. |

### `load_msp(filepath: *const c_char) -> i32`

| Code | Meaning |
|------|---------|
| `0`  | MSP loaded and mapped. |
| `-1` | Null or invalid path. |
| `-100` | I/O error opening the file. |
| `-101` | `mmap` failed. |
| `-102` | File smaller than `MspHeader`. |
| `-103` | Bad MSP magic. |
| `-104` | Unsupported MSP version. |
| `-105` | Misaligned entity table or payload section. |
| `-106` | Entity table out of bounds. |
| `-107` | Payload section out of bounds. |
| `-108` | Payload section smaller than error reserve (64 KB). |
| `-109` | SHA-256 checksum mismatch. |
| `-120` | Missing MSP sidecar signature. |
| `-121` | Invalid MSP sidecar signature. |
| `-122` | MSP file exceeds 256 MiB. |

### `verify_engine_signature(filepath, signature_hex, public_key_hex) -> i32`

| Code | Meaning |
|------|---------|
| `0`  | Signature valid. |
| `-1` | Null or invalid file path. |
| `-2` | Null or invalid signature string. |
| `-3` | Null or invalid public key string. |
| `-4` | Hex decode error. |
| `-5` | Empty or malformed public key. |
| `-6` | Invalid signature length. |
| `-7` | Other public key error. |
| `-8` | I/O error reading file. |
| `-9` | File too large. |
| `-10` | Signature cryptographically invalid. |
| `-11` | File too large for signature verifier. |
| `-12` | Other signature error. |

### `verify_binary_integrity(filepath, expected_sha) -> i32`

| Code | Meaning |
|------|---------|
| `0`  | SHA-256 matches. |
| `1`  | SHA-256 mismatch. |
| `-1` | Null or invalid file path. |
| `-2` | Null or invalid expected hash string. |
| `-3` | I/O error reading file. |
| `-4` | Hex decode error. |
| `-5` | Invalid hash length. |
| `-9` | File too large. |
| `-6` | Other error. |

## Compliance Checklist for FFI Changes

When modifying the Rust/Dart boundary:

- [ ] Keep `MalphasDoubleBufferBridge` exactly 64 bytes and 64-byte aligned.
- [ ] Keep `DartRenderCommand` exactly 64 bytes and 64-byte aligned.
- [ ] Update `BRIDGE_ABI_VERSION` whenever either layout changes.
- [ ] Mirror every field order change in both `pipeline.rs` and `types.dart`.
- [ ] Use only atomic getters with Acquire/Release ordering for shared fields.
- [ ] Add or update the layout assertions in `pipeline.rs` and Dart tests.
- [ ] Update this document (`docs/FFI_CONTRACT.md`) before merging.
