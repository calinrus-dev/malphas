import 'dart:ffi';

final class DartRenderCommand extends Struct {
  @Uint8()
  external int commandType;

  @Uint8()
  external int layer;

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

final class DartCommandBuffer extends Struct {
  @Uint32()
  external int commandCount;

  external Pointer<DartRenderCommand> commands;
}
