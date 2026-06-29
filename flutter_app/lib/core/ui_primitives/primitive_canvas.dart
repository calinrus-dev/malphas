import 'dart:collection';
import 'dart:ffi' as dffi;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../ffi/arena_layout.dart';
import '../ffi/malphas_bindings.dart';
import '../ffi/types.dart';

/// A pure synchronous rasterizer backed by the native command buffer.
///
/// Wrapped in a [RepaintBoundary] so the 120 Hz paint phase is isolated from
/// the rest of the widget tree and cannot trigger accidental re-layouts.
class PrimitiveCanvas extends StatelessWidget {
  final MalphasBindings bindings;
  final Listenable repaintNotifier;

  const PrimitiveCanvas(
      {super.key, required this.bindings, required this.repaintNotifier});

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

  EnginePainter(this.bindings, {required Listenable repaint})
      : super(repaint: repaint);

  /// Set to `true` to render a small frame-time overlay in the top-left corner.
  /// Disabled by default to avoid any overhead in production builds.
  static bool debugShowFrameTime = false;

  static final Paint _backgroundPaint = Paint()
    ..color = const Color(0xff000000);

  /// Bounded LRU cache of [Paint] objects keyed by the 32-bit native color.
  /// Two independent caches are kept so that text-specific properties
  /// (e.g. [FilterQuality.low]) never leak into rectangle paints.
  final _PaintCache _rectPaints = _PaintCache();
  final _PaintCache _textPaints = _PaintCache(filterQualityLow: true);

  final Stopwatch _frameTimer = Stopwatch();
  int _lastFrameMicros = 0;

  @override
  void paint(Canvas canvas, Size size) {
    _frameTimer.reset();
    _frameTimer.start();

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      _backgroundPaint,
    );

    final bufferPtr = bindings.commandBuffer;
    if (bufferPtr == null || bufferPtr == dffi.nullptr) {
      _stopAndMaybeDrawOverlay(canvas);
      return;
    }

    final count = bindings.getCommandCount(bufferPtr);
    final commands = bindings.getCommandsPointer(bufferPtr);
    if (commands == dffi.nullptr || count <= 0) {
      _stopAndMaybeDrawOverlay(canvas);
      return;
    }

    // Bidirectional normalization over immutable virtual matrix 1000x1000
    final scaleX = size.width / 1000.0;
    final scaleY = size.height / 1000.0;

    int i = 0;
    while (i < count) {
      // Count is validated above; use element pointer arithmetic (the
      // non-deprecated spelling of Pointer.elementAt in this SDK version).
      final command = (commands + i).ref;
      final colorRgba = command.colorRgba;

      switch (command.commandType) {
        case 1: // Solid Rectangle
          final paint = _rectPaints.getPaint(colorRgba);
          final x = command.x * scaleX;
          final y = command.y * scaleY;
          final w = command.width * scaleX;
          final h = command.height * scaleY;
          canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
          i += 1;
          break;
        case 2: // Union text command: metadata in x/y, pointer in width/height.
          final paint = _textPaints.getPaint(colorRgba);
          final payloadPtr = bindings.getTextPayloadPointer(commands + i);
          if (payloadPtr != dffi.nullptr) {
            _renderTextFromFonts(
                canvas, command, payloadPtr, scaleX, scaleY, paint);
          }
          i += 1;
          break;
        default:
          i += 1;
          break;
      }
    }

    _stopAndMaybeDrawOverlay(canvas);
  }

  void _stopAndMaybeDrawOverlay(Canvas canvas) {
    _frameTimer.stop();
    _lastFrameMicros = _frameTimer.elapsedMicroseconds;
    if (debugShowFrameTime) {
      _drawFrameTimeOverlay(canvas);
    }
  }

  void _drawFrameTimeOverlay(Canvas canvas) {
    final ms = _lastFrameMicros / 1000.0;
    final telemetry = bindings.readTelemetry();

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontSize: 14,
      ),
    )
      ..pushStyle(ui.TextStyle(color: Colors.white))
      ..addText('frame ${ms.toStringAsFixed(2)} ms\n')
      ..addText('vm ${telemetry.vmTickMicros} us\n')
      ..addText('pulse ${telemetry.pulseLatencyMicros} us\n')
      ..addText('hits ${telemetry.hitTestsCount}\n')
      ..addText('cmds ${telemetry.commandsGeneratedCount}');

    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 160));

    canvas.drawParagraph(paragraph, const Offset(8, 8));
  }

  void _renderTextFromFonts(
    Canvas canvas,
    DartRenderCommand command,
    dffi.Pointer<TextPayload> payloadPtr,
    double scaleX,
    double scaleY,
    Paint paint,
  ) {
    final atlasImage = bindings.fontAtlasImage;
    if (atlasImage == null || payloadPtr == dffi.nullptr) return;

    final arenaStart = bindings.arena;
    if (arenaStart == dffi.nullptr) return;

    final payload = payloadPtr.ref;
    final fontSize = payload.fontSize > 0 ? payload.fontSize : 32.0;
    final fontScale = fontSize / 32.0;

    double currentX = payload.x * scaleX;
    final double startY = payload.y * scaleY;

    final arenaUint32 = arenaStart.cast<dffi.Uint32>();
    final metricsOffset = arenaUint32[ArenaLayout.fontMetricsOffset ~/ 4];

    // Reject obviously invalid font metrics tables before indexing.
    if (metricsOffset < 0 || metricsOffset >= bindings.arenaSize) return;
    const int metricsEntrySize = 16;

    // The command's x field carries the text length; use it as a safety cap
    // and fall back to scanning for the null terminator.
    final maxChars = command.x > 0 ? command.x.toInt() : 0x7FFFFFFF;
    final stringStart =
        payloadPtr.cast<dffi.Uint8>() + dffi.sizeOf<TextPayload>();

    int charIdx = 0;
    while (charIdx < maxChars) {
      final charCode = stringStart[charIdx];
      if (charCode == 0) break; // null-terminator

      final glyphOffset = metricsOffset + (charCode * 16);
      // Bounds-check the 16-byte metrics entry before reading.
      if (glyphOffset < 0 ||
          glyphOffset + metricsEntrySize > bindings.arenaSize) {
        break;
      }
      final metricsData =
          (arenaStart.cast<dffi.Uint8>() + glyphOffset).cast<dffi.Uint16>();

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

/// Bounded LRU cache of [Paint] objects keyed by a 32-bit color.
///
/// The cache is intentionally simple: it uses a [LinkedHashMap] iteration
/// order to evict the least-recently used entry once [maxSize] is exceeded.
class _PaintCache {
  static const int maxSize = 128;

  final Map<int, Paint> _cache = <int, Paint>{};
  final bool _filterQualityLow;

  _PaintCache({bool filterQualityLow = false})
      : _filterQualityLow = filterQualityLow;

  Paint getPaint(int colorRgba) {
    Paint? paint = _cache.remove(colorRgba);
    if (paint == null) {
      paint = Paint()..color = Color(colorRgba);
      if (_filterQualityLow) {
        paint.filterQuality = FilterQuality.low;
      }
      if (_cache.length >= maxSize) {
        _cache.remove(_cache.keys.first);
      }
    }
    _cache[colorRgba] = paint;
    return paint;
  }
}
