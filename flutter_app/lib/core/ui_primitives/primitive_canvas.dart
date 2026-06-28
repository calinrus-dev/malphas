import 'dart:ffi' as dffi;
import 'package:flutter/material.dart';
import 'package:ffi/ffi.dart' as ffi;
import '../ffi/malphas_bindings.dart';
import '../ffi/types.dart';

class PrimitiveCanvas extends StatelessWidget {
  final dffi.Pointer<CoreCommandBuffer>? bufferPtr;
  final Listenable repaintNotifier;

  const PrimitiveCanvas({super.key, this.bufferPtr, required this.repaintNotifier});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: EnginePainter(bufferPtr, repaint: repaintNotifier),
      child: const SizedBox.expand(),
    );
  }
}

class EnginePainter extends CustomPainter {
  final dffi.Pointer<CoreCommandBuffer>? bufferPtr;

  EnginePainter(this.bufferPtr, {required Listenable repaint}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xff000000);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    if (bufferPtr == null || bufferPtr == dffi.nullptr) return;

    final buffer = bufferPtr!.ref;
    final count = buffer.commandCount;
    final commands = buffer.commands;
    if (commands == dffi.nullptr || count <= 0) return;

    // Bidirectional normalization over immutable virtual matrix 1000x1000
    final scaleX = size.width / 1000.0;
    final scaleY = size.height / 1000.0;

    int i = 0;
    while (i < count) {
      final command = (commands + i).ref;
      final paint = Paint()..color = Color(command.colorRgba);

      switch (command.commandType) {
        case 1: // Solid Rectangle
          canvas.drawRect(
            Rect.fromLTWH(
              command.x * scaleX,
              command.y * scaleY,
              command.width * scaleX,
              command.height * scaleY,
            ),
            paint,
          );
          i += 1;
          break;
        case 2: // Text command (occupies 2 slots)
          final pointerSlot = (commands + i + 1).cast<dffi.Pointer<ffi.Utf8>>().value;
          _renderTextFromFonts(canvas, command, pointerSlot, scaleX, scaleY);
          i += 2; // Critical skip
          break;
        default:
          i += 1;
          break;
      }
    }
  }

  void _renderTextFromFonts(
    Canvas canvas,
    DartRenderCommand command,
    dffi.Pointer<ffi.Utf8> textPtr,
    double scaleX,
    double scaleY,
  ) {
    final bindings = MalphasBindings();
    final atlasImage = bindings.fontAtlasImage;
    if (atlasImage == null || textPtr == dffi.nullptr) return;

    final arenaStart = bindings.arena;
    if (arenaStart == dffi.nullptr) return;

    final arenaUint32 = arenaStart.cast<dffi.Uint32>();
    final metricsOffset = arenaUint32[5];

    // command.width represents the font size
    final fontSize = command.width > 0 ? command.width : 32.0;
    final fontScale = fontSize / 32.0;

    double currentX = command.x * scaleX;
    final double startY = command.y * scaleY;

    final paint = Paint()
      ..color = Color(command.colorRgba)
      ..filterQuality = FilterQuality.low;

    final dffi.Pointer<dffi.Uint8> bytes = textPtr.cast<dffi.Uint8>();
    int charIdx = 0;
    while (true) {
      final charCode = bytes[charIdx];
      if (charCode == 0) break; // null-terminator

      final glyphOffset = metricsOffset + (charCode * 16);
      final metricsData = (arenaStart.cast<dffi.Uint8>() + glyphOffset).cast<dffi.Uint16>();

      final int gx = metricsData[1];
      final int gy = metricsData[2];
      final int gw = metricsData[3];
      final int gh = metricsData[4];
      final int gXOffset = metricsData.cast<dffi.Int16>()[5];
      final int gAdvance = metricsData[6];

      if (gw > 0 && gh > 0) {
        final srcRect = Rect.fromLTWH(
          gx.toDouble(),
          gy.toDouble(),
          gw.toDouble(),
          gh.toDouble(),
        );

        final destRect = Rect.fromLTWH(
          currentX + (gXOffset * fontScale * scaleX),
          startY,
          gw * fontScale * scaleX,
          gh * fontScale * scaleY,
        );

        canvas.drawImageRect(atlasImage, srcRect, destRect, paint);
      }

      currentX += gAdvance * fontScale * scaleX;
      charIdx++;
    }
  }

  @override
  bool shouldRepaint(covariant EnginePainter oldDelegate) => true;
}
