import 'dart:ffi' as dffi;
import 'package:flutter/material.dart';
import '../ffi/types.dart';

class PrimitiveCanvas extends StatelessWidget {
  final dffi.Pointer<DartCommandBuffer>? bufferPtr;

  const PrimitiveCanvas({super.key, this.bufferPtr});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: EnginePainter(bufferPtr),
      child: const SizedBox.expand(),
    );
  }
}

class EnginePainter extends CustomPainter {
  final dffi.Pointer<DartCommandBuffer>? bufferPtr;

  EnginePainter(this.bufferPtr);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xff000000);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    if (bufferPtr == null || bufferPtr == dffi.nullptr) {
      return;
    }

    final buffer = bufferPtr!.ref;

    // Validación sádica del conteo y puntero a comandos
    var count = buffer.commandCount;
    if (count < 0) count = 0;
    if (count > malphasBindingsMaxSafeCount)
      count = malphasBindingsMaxSafeCount;

    final commands = buffer.commands;
    if (commands == dffi.nullptr) return;

    final scaleX = size.width / 1000.0;
    final scaleY = size.height / 1000.0;

    for (int i = 0; i < count; i++) {
      final command = (commands + i).ref;

      // Color empaquetado en ARGB nativo: 0xAARRGGBB
      final argb = command.colorRgba;
      final paint = Paint()..color = Color(argb);

      switch (command.commandType) {
        case 1: // Rectángulo
          canvas.drawRect(
            Rect.fromLTWH(
              command.x * scaleX,
              command.y * scaleY,
              command.width * scaleX,
              command.height * scaleY,
            ),
            paint,
          );
          break;
        default:
          break;
      }
    }
  }

  @override
  bool shouldRepaint(covariant EnginePainter oldDelegate) => true;
}

// Máximo seguro local
const int malphasBindingsMaxSafeCount = 2048;
