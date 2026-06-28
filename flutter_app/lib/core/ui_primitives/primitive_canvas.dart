import 'dart:ffi' as dffi;
import 'package:flutter/material.dart';
import '../ffi/malphas_bindings.dart';
import '../ffi/types.dart';

/// A pure synchronous rasterizer backed by the native command buffer.
///
/// Wrapped in a [RepaintBoundary] so the 120 Hz paint phase is isolated from
/// the rest of the widget tree and cannot trigger accidental re-layouts.
class PrimitiveCanvas extends StatelessWidget {
  final MalphasBindings bindings;
  final Listenable repaintNotifier;

  const PrimitiveCanvas({super.key, required this.bindings, required this.repaintNotifier});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: EnginePainter(bindings, repaint: repaintNotifier),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class EnginePainter extends CustomPainter {
  final MalphasBindings bindings;

  EnginePainter(this.bindings, {required Listenable repaint}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xff000000);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    final bufferPtr = bindings.commandBuffer;
    if (bufferPtr == null || bufferPtr == dffi.nullptr) return;

    final count = bindings.getCommandCount(bufferPtr);
    final commands = bindings.getCommandsPointer(bufferPtr);
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
        case 2: // Union text command: metadata in x/y, pointer in width/height.
          final textPtr = _decodeTextPointer(commands + i);
          if (textPtr != dffi.nullptr) {
            _renderTextFromFonts(canvas, command, textPtr, scaleX, scaleY);
          }
          i += 1;
          break;
        default:
          i += 1;
          break;
      }
    }
  }

  /// Decodes the 64-bit pointer stored across the `width` (low 32 bits) and
  /// `height` (high 32 bits) fields of a text command.  The fields are read as
  /// raw integers to avoid any NaN canonicalisation that could happen when
  /// round-tripping through Dart `double` values.
  dffi.Pointer<dffi.Uint8> _decodeTextPointer(dffi.Pointer<DartRenderCommand> cmdPtr) {
    const widthOffset = 12; // offset of `width` inside DartRenderCommand
    const heightOffset = 16; // offset of `height` inside DartRenderCommand
    final lowPtr = dffi.Pointer<dffi.Uint32>.fromAddress(cmdPtr.address + widthOffset);
    final highPtr = dffi.Pointer<dffi.Uint32>.fromAddress(cmdPtr.address + heightOffset);
    final address = lowPtr.value | (highPtr.value << 32);
    if (address == 0) return dffi.nullptr;
    return dffi.Pointer<dffi.Uint8>.fromAddress(address);
  }

  void _renderTextFromFonts(
    Canvas canvas,
    DartRenderCommand command,
    dffi.Pointer<dffi.Uint8> textPtr,
    double scaleX,
    double scaleY,
  ) {
    final atlasImage = bindings.fontAtlasImage;
    if (atlasImage == null || textPtr == dffi.nullptr) return;

    final arenaStart = bindings.arena;
    if (arenaStart == dffi.nullptr) return;

    final payload = textPtr.cast<TextPayload>().ref;
    final fontSize = payload.fontSize > 0 ? payload.fontSize : 32.0;
    final fontScale = fontSize / 32.0;

    double currentX = payload.x * scaleX;
    final double startY = payload.y * scaleY;

    final paint = Paint()
      ..color = Color(command.colorRgba)
      ..filterQuality = FilterQuality.low;

    final arenaUint32 = arenaStart.cast<dffi.Uint32>();
    final metricsOffset = arenaUint32[5];

    // The command's x field carries the text length; use it as a safety cap
    // and fall back to scanning for the null terminator.
    final maxChars = command.x > 0 ? command.x.toInt() : 0x7FFFFFFF;
    final stringStart = textPtr + dffi.sizeOf<TextPayload>();

    int charIdx = 0;
    while (charIdx < maxChars) {
      final charCode = stringStart[charIdx];
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
  bool shouldRepaint(covariant EnginePainter oldDelegate) => false;
}
