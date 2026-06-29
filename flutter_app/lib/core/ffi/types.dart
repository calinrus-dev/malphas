// ignore_for_file: unused_field

import 'dart:ffi';

/// C-ABI mirror of the Rust `DartRenderCommand`.
///
/// * 24 bytes, 4-byte aligned.
/// * `commandType == 1` = rectangle (`x`, `y`, `width`, `height` are geometry).
/// * `commandType == 2` = text.  The float fields form a logical union:
///   `x` holds the text length, `y` holds the text style/font size, and
///   `width`/`height` hold the low/high 32 bits of a `Pointer<TextPayload>`
///   to the Arena-resident text object.  The command array stays homogeneous.
final class DartRenderCommand extends Struct {
  @Uint8()
  external int commandType;

  @Uint8()
  external int layer;

  @Uint16()
  external int
      pad; // 2-byte alignment padding to align f32 fields to 4-byte boundaries

  @Float()
  external double x;

  @Float()
  external double y;

  @Float()
  external double width;

  @Float()
  external double height;

  @Uint32()
  external int colorRgba; // Direct native ARGB format (0xAARRGGBB)
}

/// C-ABI mirror of the Rust `TextPayload`.
///
/// The string bytes follow this 12-byte header immediately in Arena memory.
final class TextPayload extends Struct {
  @Float()
  external double x;

  @Float()
  external double y;

  @Float()
  external double fontSize;
}

/// C-ABI mirror of the Rust `CoreCommandBuffer`.
///
/// * 16 bytes, 16-byte aligned.
/// * `commandCount` is written by Rust with Release ordering and read by Dart
///   with Acquire ordering; it is NOT a normal Dart field write.
final class CoreCommandBuffer extends Struct {
  @Uint32()
  external int commandCount;

  external Pointer<DartRenderCommand> commands;
}

/// C-ABI mirror of the Rust `MalphasDoubleBufferBridge`.
///
/// * 48 bytes, 16-byte aligned.
/// * The two `_padding` fields mirror the 8 trailing alignment bytes that Rust
///   reserves for `#[repr(C, align(16))]`. They must not be read or written.
/// * Dart never performs pointer arithmetic on this struct; it uses the Rust
///   exported getter functions (`get_buffer_a_ptr`, `get_back_index`, etc.).
final class MalphasDoubleBufferBridge extends Struct {
  external CoreCommandBuffer bufferA;
  external CoreCommandBuffer bufferB;

  @Uint8()
  external int atomicBackIndex;

  @Uint32()
  external int commandsWritten;

  @Uint32()
  external int _padding0;

  @Uint32()
  external int _padding1;
}
