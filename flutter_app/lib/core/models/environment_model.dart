import 'dart:ui';

/// Runtime instance pairing one MSP with one or more MXC systems.
///
/// No serialization methods live inside this class. Use standalone top-level
/// functions in [AppStatePersistenceService] for JSON conversion.
final class Environment {
  final String id;
  final String? engineId;
  final List<int> packageIds;
  final bool isPinned;
  final String name;
  final Color accentColor;

  const Environment({
    required this.id,
    required this.name,
    required this.accentColor,
    this.engineId,
    this.packageIds = const [],
    this.isPinned = false,
  });
}
