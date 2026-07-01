import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Lightweight wrapper around `audioplayers` for Malphas sound payloads.
///
/// The service caches one [AudioPlayer] per active sound path so rapid,
/// overlapping triggers are possible without allocating a player per event.
class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final Map<String, AudioPlayer> _players = {};
  bool _enabled = true;

  bool get enabled => _enabled;

  void setEnabled(bool value) {
    _enabled = value;
    if (!_enabled) {
      stopAll();
    }
  }

  /// Plays the sound at [path].
  ///
  /// Returns immediately.  Errors are logged and swallowed so audio failures
  /// never crash the engine or UI.
  Future<void> play(String path) async {
    if (!_enabled) return;
    if (path.isEmpty || path == 'none') return;

    try {
      final file = File(path);
      if (!file.existsSync()) return;

      final player = _players.putIfAbsent(path, AudioPlayer.new);
      await player.stop();
      await player.play(DeviceFileSource(file.path));
    } catch (e) {
      debugPrint('AudioService play failed for $path: $e');
    }
  }

  /// Stops every cached player.
  Future<void> stopAll() async {
    for (final player in _players.values) {
      try {
        await player.stop();
      } catch (_) {}
    }
  }

  /// Releases all players.
  Future<void> dispose() async {
    for (final player in _players.values) {
      try {
        await player.dispose();
      } catch (_) {}
    }
    _players.clear();
  }
}
