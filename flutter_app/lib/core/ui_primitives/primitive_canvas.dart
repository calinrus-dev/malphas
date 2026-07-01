import 'dart:ffi' as ffi;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ffi/malphas_bindings.dart';
import '../ffi/types.dart';

/// Zero-copy native render target.
///
/// The painter reads the front buffer directly from the shared double-buffer
/// bridge on every vsync. No command list is copied into Dart memory; the only
/// data moved is the handful of fields read by the GPU-bound [Canvas] ops.
class PrimitiveCanvas extends StatefulWidget {
  /// Logical coordinate space used by the native render buffer.
  static const double logicalWidth = 1000.0;
  static const double logicalHeight = 1000.0;

  final MalphasBindings bindings;

  /// Optional external repaint source. When provided, the canvas does NOT pulse
  /// the engine itself; it only paints in response to this notifier. This lets
  /// a parent [EngineController] own the single vsync ticker.
  final Listenable? repaint;

  /// Optional resolver that maps a [payloadId] to a loaded [ui.Image].
  /// When null, sprite commands fall back to the placeholder outline.
  final ui.Image? Function(int payloadId)? imageResolver;

  const PrimitiveCanvas({
    super.key,
    required this.bindings,
    this.repaint,
    this.imageResolver,
  });

  @override
  State<PrimitiveCanvas> createState() => _PrimitiveCanvasState();
}

class _PrimitiveCanvasState extends State<PrimitiveCanvas>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  ValueNotifier<int>? _frame;

  Listenable get _repaint => widget.repaint ?? _frame!;

  @override
  void initState() {
    super.initState();
    if (widget.repaint == null) {
      _frame = ValueNotifier<int>(0);
      _ticker = createTicker(_onTick)..start();
    }
  }

  void _onTick(Duration elapsed) {
    // Drive the Rust simulation thread once per vsync and bump the frame
    // notifier so the CustomPaint repaints without rebuilding the widget.
    widget.bindings.triggerEnginePulse();
    _frame!.value++;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PrimitivePainter(
        bindings: widget.bindings,
        repaint: _repaint,
        imageResolver: widget.imageResolver,
      ),
      size: Size.infinite,
    );
  }
}

class _PrimitivePainter extends CustomPainter {
  final MalphasBindings _bindings;
  final ui.Image? Function(int payloadId)? _imageResolver;

  _PrimitivePainter({
    required MalphasBindings bindings,
    required Listenable repaint,
    required ui.Image? Function(int payloadId)? imageResolver,
  })  : _bindings = bindings,
        _imageResolver = imageResolver,
        super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Clear the frame.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff0a0a0a),
    );

    // Atomic snapshot: one FFI call pins the front buffer pointer and count.
    final snapshot = _bindings.getFrontBufferSnapshot();
    final commands = snapshot.commands;
    final count = snapshot.count;
    if (commands == ffi.nullptr || count <= 0) return;

    final scaleX = size.width / PrimitiveCanvas.logicalWidth;
    final scaleY = size.height / PrimitiveCanvas.logicalHeight;

    for (int i = 0; i < count; i++) {
      final cmd = (commands + i).ref;
      final type = cmd.type;
      if (type == 1) {
        _drawRectangle(canvas, cmd, scaleX, scaleY);
      } else if (type == 2) {
        _drawText(canvas, cmd, scaleX, scaleY);
      } else if (type == 3) {
        _drawSprite(canvas, cmd, scaleX, scaleY);
      } else if (type == 4) {
        _drawCircle(canvas, cmd, scaleX, scaleY);
      }
    }
  }

  void _drawRectangle(
    Canvas canvas,
    DartRenderCommand cmd,
    double scaleX,
    double scaleY,
  ) {
    final rect = Rect.fromLTWH(
      cmd.x * scaleX,
      cmd.y * scaleY,
      cmd.width * scaleX,
      cmd.height * scaleY,
    );
    final paint = Paint()
      ..color = Color(cmd.color)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, paint);
  }

  void _drawCircle(
    Canvas canvas,
    DartRenderCommand cmd,
    double scaleX,
    double scaleY,
  ) {
    final center = Offset(cmd.x * scaleX, cmd.y * scaleY);
    final radius = (cmd.width * scaleX) / 2;
    final paint = Paint()
      ..color = Color(cmd.color)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, paint);
  }

  void _drawSprite(
    Canvas canvas,
    DartRenderCommand cmd,
    double scaleX,
    double scaleY,
  ) {
    final rect = Rect.fromLTWH(
      cmd.x * scaleX,
      cmd.y * scaleY,
      cmd.width * scaleX,
      cmd.height * scaleY,
    );
    final image = _imageResolver?.call(cmd.payloadId);
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        ),
        rect,
        Paint()..filterQuality = FilterQuality.low,
      );
      return;
    }
    final paint = Paint()
      ..color = Color(cmd.color).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, paint);
  }

  void _drawText(
    Canvas canvas,
    DartRenderCommand cmd,
    double scaleX,
    double scaleY,
  ) {
    final text = cmd.payloadId != 0 ? 'T${cmd.payloadId}' : 'TXT';
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontSize: 10,
    ));
    builder.pushStyle(ui.TextStyle(
      color: Color(cmd.color),
      fontFamily: 'Courier',
    ));
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: 200));
    canvas.drawParagraph(
      paragraph,
      Offset(cmd.x * scaleX, cmd.y * scaleY),
    );
  }

  @override
  bool shouldRepaint(covariant _PrimitivePainter oldDelegate) => true;
}
