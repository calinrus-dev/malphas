import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/services/telemetry_service.dart';

/// Runtime telemetry overlay.
///
/// Polls [TelemetryService] on a low-frequency cadence and displays the
/// current memory budget, MSP mmap diagnostics, engine tick timing and the
/// optional GPS position.  It is opt-in via Settings.
class TelemetryOverlay extends StatefulWidget {
  const TelemetryOverlay({super.key});

  @override
  State<TelemetryOverlay> createState() => _TelemetryOverlayState();
}

class _TelemetryOverlayState extends State<TelemetryOverlay> {
  final TelemetryService _telemetry = TelemetryService();
  late Timer _timer;
  TelemetrySnapshot _snapshot = TelemetrySnapshot(
    memoryBudgetUsedBytes: 0,
    memoryBudgetLimitBytes: 0,
    mspMappedSizeBytes: 0,
    mspBuildTimeMicros: 0,
    vmTickMicros: 0,
    pulseLatencyMicros: 0,
    commandsGeneratedCount: 0,
    timestamp: DateTime.now(),
  );

  @override
  void initState() {
    super.initState();
    _snapshot = _telemetry.readSnapshot();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {
          _snapshot = _telemetry.readSnapshot();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _bytesToMb(int bytes) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xff0d0d0d).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xff161616)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'Courier',
          fontSize: 10,
          color: Colors.white,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TELEMETRY',
              style: TextStyle(
                fontFamily: 'Arial',
                fontSize: 7,
                color: Colors.white38,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            _metricRow('RAM USED', _bytesToMb(_snapshot.memoryBudgetUsedBytes)),
            _metricRow(
                'RAM LIMIT', _bytesToMb(_snapshot.memoryBudgetLimitBytes)),
            _metricRow('MSP MAPPED', _bytesToMb(_snapshot.mspMappedSizeBytes)),
            _metricRow('MSP BUILD', '${_snapshot.mspBuildTimeMicros} µs'),
            _metricRow('VM TICK', '${_snapshot.vmTickMicros} µs'),
            _metricRow('PULSE LAT', '${_snapshot.pulseLatencyMicros} µs'),
            _metricRow('COMMANDS', '${_snapshot.commandsGeneratedCount}'),
            ValueListenableBuilder(
              valueListenable: _telemetry.gpsPositionNotifier,
              builder: (context, position, _) {
                if (position == null) {
                  return _metricRow('GPS', 'OFF');
                }
                return _metricRow(
                  'GPS',
                  '${position.latitude.toStringAsFixed(4)}, '
                      '${position.longitude.toStringAsFixed(4)}',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 9),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
