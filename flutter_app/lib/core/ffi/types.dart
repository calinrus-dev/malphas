import 'dart:ffi';

final class DartRenderCommand extends Struct {
  @Uint8()
  external int commandType;
  
  @Uint8()
  external int layer;
  
  @Uint16()
  external int pad; // 2-byte alignment padding to align f32 fields to 4-byte boundaries

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

final class CoreCommandBuffer extends Struct {
  @Uint32()
  external int commandCount;

  external Pointer<DartRenderCommand> commands;
}

final class MalphasDoubleBufferBridge extends Struct {
  external CoreCommandBuffer bufferA;
  external CoreCommandBuffer bufferB;

  @Uint8()
  external int atomicBackIndex;
}

