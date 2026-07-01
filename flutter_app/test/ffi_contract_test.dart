import 'dart:ffi';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/ffi/types.dart';

void main() {
  test('DartRenderCommand is exactly 64 bytes', () {
    expect(sizeOf<DartRenderCommand>(), equals(64));
  });

  test('MalphasDoubleBufferBridge is exactly 64 bytes', () {
    expect(sizeOf<MalphasDoubleBufferBridge>(), equals(64));
  });

  test('MspHeader is exactly 64 bytes', () {
    expect(sizeOf<MspHeader>(), equals(64));
  });

  test('MspEntityDescriptor is exactly 64 bytes', () {
    expect(sizeOf<MspEntityDescriptor>(), equals(64));
  });
}
