import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../../core/ffi/malphas_bindings.dart';

/// A snapshot of runtime telemetry data.
class TelemetrySnapshot {
  final int memoryBudgetUsedBytes;
  final int memoryBudgetLimitBytes;
  final int mspMappedSizeBytes;
  final int mspBuildTimeMicros;
  final int vmTickMicros;
  final int pulseLatencyMicros;
  final int commandsGeneratedCount;
  final Position? gpsPosition;
  final DateTime timestamp;

  const TelemetrySnapshot({
    required this.memoryBudgetUsedBytes,
    required this.memoryBudgetLimitBytes,
    required this.mspMappedSizeBytes,
    required this.mspBuildTimeMicros,
    required this.vmTickMicros,
    required this.pulseLatencyMicros,
    required this.commandsGeneratedCount,
    this.gpsPosition,
    required this.timestamp,
  });
}

/// Collects engine memory diagnostics and optional GPS telemetry.
///
/// GPS is disabled by default and must be enabled by the user.  Location data
/// is kept in Dart memory only; it is never passed to native systems unless the
/// user explicitly opts in via a future systems-telemetry bridge.
class TelemetryService {
  static final TelemetryService _instance = TelemetryService._internal();
  factory TelemetryService() => _instance;
  TelemetryService._internal();

  final MalphasBindings _bindings = MalphasBindings();
  StreamSubscription<Position>? _gpsSubscription;
  Position? _lastPosition;
  bool _gpsEnabled = false;

  bool get gpsEnabled => _gpsEnabled;

  final ValueNotifier<Position?> gpsPositionNotifier =
      ValueNotifier<Position?>(null);

  /// Reads a single telemetry snapshot from the engine.
  TelemetrySnapshot readSnapshot() {
    return TelemetrySnapshot(
      memoryBudgetUsedBytes: _bindings.memoryBudgetUsedBytes,
      memoryBudgetLimitBytes: _bindings.memoryBudgetLimitBytes,
      mspMappedSizeBytes: _bindings.mspMappedSizeBytes,
      mspBuildTimeMicros: _bindings.mspBuildTimeMicros,
      vmTickMicros: _bindings.vmTickMicros,
      pulseLatencyMicros: _bindings.pulseLatencyMicros,
      commandsGeneratedCount: _bindings.commandsGeneratedCount,
      gpsPosition: _lastPosition,
      timestamp: DateTime.now(),
    );
  }

  /// Enables GPS updates.  Returns false if permission is denied.
  Future<bool> enableGps() async {
    if (_gpsEnabled) return true;

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('TelemetryService: location services disabled');
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return false;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return false;
      }

      _gpsSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          distanceFilter: 10,
        ),
      ).listen((position) {
        _lastPosition = position;
        gpsPositionNotifier.value = position;
      }, onError: (e) {
        debugPrint('TelemetryService GPS error: $e');
      });

      _gpsEnabled = true;
      return true;
    } catch (e) {
      debugPrint('TelemetryService enableGps failed: $e');
      return false;
    }
  }

  /// Disables GPS updates and clears the last known position.
  void disableGps() {
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _lastPosition = null;
    _gpsEnabled = false;
    gpsPositionNotifier.value = null;
  }

  /// Toggles GPS collection.
  ///
  /// Persisted state is managed by the caller so the service stays decoupled
  /// from the settings store.
  Future<bool> setGpsEnabled(bool enabled) async {
    if (enabled) {
      final ok = await enableGps();
      if (!ok) disableGps();
      return ok;
    }
    disableGps();
    return true;
  }

  void dispose() {
    disableGps();
    gpsPositionNotifier.dispose();
  }
}
