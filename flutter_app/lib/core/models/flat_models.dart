import 'dart:ui';
export 'entity_models.dart';

/// Legacy package descriptor. Retained until UI squads migrate fully to
/// EntityStore + MSP path scanning.
final class EntityPackage {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String? coverImagePath;
  final bool isLoaded;

  const EntityPackage(
    this.id,
    this.name,
    this.version,
    this.author,
    this.description,
    this.coverImagePath,
    this.isLoaded,
  );
}

/// Legacy environment descriptor. New code should use [Environment] from
/// `environment_model.dart`.
final class Environment {
  final String id;
  final String name;
  final Color accentColor;
  final bool isPinned;
  final String? engineId;

  const Environment(
    this.id,
    this.name,
    this.accentColor,
    this.isPinned,
    this.engineId,
  );
}
