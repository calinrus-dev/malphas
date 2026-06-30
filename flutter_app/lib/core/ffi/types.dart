// ignore_for_file: unused_field

import 'dart:ffi';

/// C-ABI mirror of the Rust `DartRenderCommand`.
///
/// * 24 bytes, 4-byte aligned.
/// * `commandType == 1` = rectangle (`x`, `y`, `width`, `height` are geometry).
/// * `commandType == 2` = text label.  The float fields form a logical union:
///   `x` holds the text length, `y` holds the text style/font size, and
///   `width`/`height` hold the low/high 32 bits of a `Pointer<TextPayload>`.
final class DartRenderCommand extends Struct {
  @Uint8()
  external int commandType;

  @Uint8()
  external int layer;

  @Uint16()
  external int pad;

  @Float()
  external double x;

  @Float()
  external double y;

  @Float()
  external double width;

  @Float()
  external double height;

  @Uint32()
  external int colorRgba;
}

/// C-ABI mirror of the Rust `TextPayload`.
///
/// Kept for ABI compatibility.  The string bytes follow this 12-byte header
/// immediately in memory.
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
final class MalphasDoubleBufferBridge extends Struct {
  @Uint32()
  external int bufferACommandCount;

  @Uint32()
  external int _padA;

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
