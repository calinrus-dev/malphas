import 'dart:ffi' as ffi;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ffi/malphas_bindings.dart';
import '../ffi/types.dart';

/// Zero-copy native render target.
///
/// The painter reads [MalphasBindings.frontCommands] directly from the shared
/// double-buffer bridge on every vsync.  No command list is copied into Dart
/// memory; the only data moved is the handful of fields read by the GPU-bound
/// [Canvas] operations.
class PrimitiveCanvas extends StatefulWidget {
  final MalphasBindings bindings;

  const PrimitiveCanvas({
    super.key,
    required this.bindings,
  });

  @override
  State<PrimitiveCanvas> createState() => _PrimitiveCanvasState();
}

class _PrimitiveCanvasState extends State<PrimitiveCanvas>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final ValueNotifier<int> _frame;

  @override
  void initState() {
    super.initState();
    _frame = ValueNotifier<int>(0);
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    // Drive the Rust simulation thread once per vsync and bump the frame
    // notifier so the CustomPaint repaints without rebuilding the widget.
    widget.bindings.triggerEnginePulse();
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PrimitivePainter(
        bindings: widget.bindings,
        repaint: _frame,
      ),
      size: Size.infinite,
    );
  }
}

class _PrimitivePainter extends CustomPainter {
  static const double _logicalWidth = 1000.0;
  static const double _logicalHeight = 1000.0;

  final MalphasBindings _bindings;

  _PrimitivePainter({
    required MalphasBindings bindings,
    required Listenable repaint,
  })  : _bindings = bindings,
        super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Clear the frame.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff0a0a0a),
    );

    final commands = _bindings.frontCommands;
    final count = _bindings.frontCount;
    if (commands == ffi.nullptr || count <= 0) return;

    final scaleX = size.width / _logicalWidth;
    final scaleY = size.height / _logicalHeight;

    for (int i = 0; i < count; i++) {
      final cmd = commands[i];
      if (cmd.commandType == 1) {
        _drawRectangle(canvas, cmd, scaleX, scaleY);
      } else if (cmd.commandType == 2) {
        _drawTextFallback(canvas, cmd, scaleX, scaleY);
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
      ..color = Color(cmd.colorRgba)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, paint);
  }

  void _drawTextFallback(
    Canvas canvas,
    DartRenderCommand cmd,
    double scaleX,
    double scaleY,
  ) {
    // Systems are responsible for text content in v2.7.0.  Without an arena
    // atlas we render a small placeholder marker so text commands are still
    // visible during development.
    final center = Offset(cmd.x * scaleX, cmd.y * scaleY);
    final paint = Paint()
      ..color = Color(cmd.colorRgba)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.0, paint);
  }

  @override
  bool shouldRepaint(covariant _PrimitivePainter oldDelegate) => true;
}
