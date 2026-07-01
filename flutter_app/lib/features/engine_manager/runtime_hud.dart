import 'package:flutter/material.dart';
import '../../core/theme/theme.dart';
import 'engine_controller.dart';

/// Runtime heads-up overlay.
///
/// Displays FPS (calculated from the engine pulse notifier), entity count,
/// active system name and the active environment name. The widget does not
/// own the ticker; it reads frame deltas from [EngineController.frameNotifier].
class RuntimeHud extends StatefulWidget {
  const RuntimeHud({super.key});

  @override
  State<RuntimeHud> createState() => _RuntimeHudState();
}

class _RuntimeHudState extends State<RuntimeHud> {
  final EngineController _controller = EngineController();

  int _lastFrame = 0;
  Duration _lastElapsed = Duration.zero;
  double _fps = 0;

  @override
  void initState() {
    super.initState();
    _controller.frameNotifier.addListener(_onFrame);
  }

  @override
  void dispose() {
    _controller.frameNotifier.removeListener(_onFrame);
    super.dispose();
  }

  void _onFrame() {
    final now = DateTime.now();
    final elapsed = Duration(milliseconds: now.millisecondsSinceEpoch);
    final delta = elapsed - _lastElapsed;
    final frameDelta = _controller.frameNotifier.value - _lastFrame;

    if (delta.inMilliseconds > 0 && frameDelta > 0) {
      final instantFps = 1000.0 / delta.inMilliseconds * frameDelta;
      _fps = _fps == 0 ? instantFps : (_fps * 0.8 + instantFps * 0.2);
    }

    _lastFrame = _controller.frameNotifier.value;
    _lastElapsed = elapsed;

    // Throttle rebuilds to ~10 FPS so the HUD does not waste GPU time.
    if (frameDelta >= 6 && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = _controller.activeEnvironment;
    final entityCount = _controller.entityCount;
    final systemCount = _controller.loadedSystemCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: MalphasTheme.slate.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MalphasTheme.borderAccent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HudMetric(label: 'FPS', value: _fps.toStringAsFixed(1)),
          const SizedBox(width: 16),
          _HudMetric(label: 'ENTITIES', value: entityCount.toString()),
          const SizedBox(width: 16),
          _HudMetric(label: 'SYSTEMS', value: systemCount.toString()),
          const SizedBox(width: 16),
          _HudMetric(
            label: 'ENV',
            value: env?.name.toUpperCase() ?? 'NONE',
          ),
        ],
      ),
    );
  }
}

class _HudMetric extends StatelessWidget {
  final String label;
  final String value;

  const _HudMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Arial',
            fontSize: 7,
            color: Colors.white38,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 11,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
