import 'dart:ffi';

final class DartRenderCommand extends Struct {
  @Uint8()
  external int commandType;
  
  @Uint8()
  external int layer;
  
  @Uint16()
  external int pad; // Padding de alineación de 2 bytes para ajustar los f32 a fronteras de 4 bytes

  @Float()
  external double x;

  @Float()
  external double y;

  @Float()
  external double width;

  @Float()
  external double height;

  @Uint32()
  external int colorRgba; // Formato nativo directo ARGB (0xAARRGGBB)
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

