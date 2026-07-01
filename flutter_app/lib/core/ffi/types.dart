// ignore_for_file: unused_field

import 'dart:ffi';

/// ABI version expected by the Dart binding and written by Rust in
/// `init_engine`. Both sides must agree before any shared memory is trusted.
const int bridgeAbiVersion = 0x03000000;

/// C-ABI mirror of the Rust `DartRenderCommand`.
///
/// 64-byte struct as required by the v3.0.0 frontend contract.
/// Layout (packed, 1-byte alignment):
///   type      : u32  (4 bytes)
///   entityId  : u32  (4 bytes)
///   x         : f32  (4 bytes)
///   y         : f32  (4 bytes)
///   width     : f32  (4 bytes)
///   height    : f32  (4 bytes)
///   color     : u32  (4 bytes)
///   payloadId : u32  (4 bytes)
///   padding   : u32[8] (32 bytes)
/// Total: 64 bytes.
@Packed(1)
final class DartRenderCommand extends Struct {
  @Uint32()
  external int type;

  @Uint32()
  external int entityId;

  @Float()
  external double x;

  @Float()
  external double y;

  @Float()
  external double width;

  @Float()
  external double height;

  @Uint32()
  external int color;

  @Uint32()
  external int payloadId;

  @Array(8)
  external Array<Uint32> padding;
}

/// C-ABI mirror of the Rust `TextPayload`.
///
/// Kept for ABI compatibility. The string bytes follow this 12-byte header
/// immediately in memory.
@Packed(1)
final class TextPayload extends Struct {
  @Float()
  external double x;

  @Float()
  external double y;

  @Float()
  external double fontSize;
}

/// C-ABI mirror of the Rust `MalphasDoubleBufferBridge`.
///
/// * 64 bytes, 64-byte aligned.
/// * Fields are ordered exactly like the Rust `#[repr(C, align(64))]` struct.
/// * `atomicBackIndex` is flipped by Rust with Release ordering; Dart reads it
///   with Acquire ordering through the delegate functions.
/// * `abiVersion` is set by Rust during `init_engine` and must be verified by
///   Dart before the bridge is trusted.
final class MalphasDoubleBufferBridge extends Struct {
  @Uint32()
  external int bufferACommandCount;

  @Uint32()
  external int abiVersion;

  external Pointer<DartRenderCommand> bufferACommands;

  @Uint32()
  external int bufferBCommandCount;

  @Uint32()
  external int _padB;

  external Pointer<DartRenderCommand> bufferBCommands;

  @Uint8()
  external int atomicBackIndex;

  @Uint8()
  external int _padding2;

  @Uint8()
  external int _padding3;

  @Uint8()
  external int _padding4;

  @Uint32()
  external int commandsWritten;

  @Uint32()
  external int _padding5;

  @Uint32()
  external int _padding6;

  @Uint64()
  external int _padding7;

  @Uint64()
  external int _padding8;
}

/// C-ABI mirror of the Rust `MspHeader`.
///
/// 64-byte aligned header at the start of every `.msp` file.
/// Layout (packed, explicit offsets):
///   magic[4]                : 4 bytes
///   version                 : 4 bytes
///   entity_table_offset     : 4 bytes
///   entity_count            : 4 bytes
///   payload_section_offset  : 4 bytes
///   payload_section_size    : 4 bytes
///   checksum[32]            : 32 bytes
///   _padding[8]             : 8 bytes
/// Total: 64 bytes.
@Packed(1)
final class MspHeader extends Struct {
  @Array(4)
  external Array<Uint8> magic;

  @Uint32()
  external int version;

  @Uint32()
  external int entityTableOffset;

  @Uint32()
  external int entityCount;

  @Uint32()
  external int payloadSectionOffset;

  @Uint32()
  external int payloadSectionSize;

  @Array(32)
  external Array<Uint8> checksum;

  @Array(8)
  external Array<Uint8> padding;
}

/// C-ABI mirror of the Rust `MspEntityDescriptor`.
///
/// 64-byte aligned descriptor. The 4-byte gap between `entityId` and `tagMask`
/// carries `payloadTypeId`, matching the Rust `#[repr(C, align(64))]` layout.
/// Layout (packed, explicit offsets):
///   entity_id       : 4 bytes
///   payload_type_id : 4 bytes
///   tag_mask        : 8 bytes
///   payload_offset  : 4 bytes
///   payload_size    : 4 bytes
///   _padding[40]    : 40 bytes
/// Total: 64 bytes.
@Packed(1)
final class MspEntityDescriptor extends Struct {
  @Uint32()
  external int entityId;

  @Uint32()
  external int payloadTypeId;

  @Uint64()
  external int tagMask;

  @Uint32()
  external int payloadOffset;

  @Uint32()
  external int payloadSize;

  @Array(40)
  external Array<Uint8> padding;
}
