import 'dart:ui';

enum EngineStatus { active, standby, corrupt, unverified }

enum NativeRuntime { rust }

final class EntityTag {
  final int entityId;
  final String name;
  final bool isPublic;

  const EntityTag(this.entityId, this.name, this.isPublic);
}

final class EntityPayload {
  final int id;
  final int entityId;
  final String name;
  final String assetPath;
  final String version;

  const EntityPayload(
      this.id, this.entityId, this.name, this.assetPath, this.version);
}

final class EntityProperty {
  final int entityId;
  final String key;
  final String value;

  const EntityProperty(this.entityId, this.key, this.value);
}

final class Entity {
  final int id;
  final String packageId;
  final String name;
  final String category;
  final int activePayloadId;

  const Entity(
      this.id, this.packageId, this.name, this.category, this.activePayloadId);
}

final class EntityPackage {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String? coverImagePath;
  final bool isLoaded;

  const EntityPackage(this.id, this.name, this.version, this.author,
      this.description, this.coverImagePath, this.isLoaded);
}

final class Engine {
  final String id;
  final String name;
  final String version;
  final NativeRuntime runtime;
  final String binaryName;
  final String sha256;
  final int allocatedMemoryBytes;
  final EngineStatus status;

  const Engine(this.id, this.name, this.version, this.runtime, this.binaryName,
      this.sha256, this.allocatedMemoryBytes, this.status);
}

final class Environment {
  final String id;
  final String name;
  final Color accentColor;
  final bool isPinned;
  final String? engineId;

  const Environment(
      this.id, this.name, this.accentColor, this.isPinned, this.engineId);
}
