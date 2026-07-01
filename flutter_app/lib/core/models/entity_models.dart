/// Immutable entity identifier with lightweight presentation metadata.
///
/// Core DOD fields are [id] and [activePayloadId]. [packageId], [name] and
/// [category] are kept flat so the UI can render lists without extra joins.
final class Entity {
  final int id;
  final String packageId;
  final String name;
  final String category;
  final int activePayloadId;

  const Entity({
    required this.id,
    this.packageId = '',
    this.name = '',
    this.category = '',
    required this.activePayloadId,
  });
}

/// Raw payload reference.
///
/// Payloads are data blocks, not nested objects. [entityId] links the payload
/// to its owning entity, [assetPath] points to the on-disk binary and [type]
/// is a hint for the decode pipeline.
final class EntityPayload {
  final int id;
  final int entityId;
  final String name;
  final String assetPath;
  final String type;
  final String version;

  const EntityPayload({
    required this.id,
    required this.entityId,
    required this.name,
    required this.assetPath,
    this.type = 'binary',
    this.version = '1.0',
  });
}

/// Tag bitmask and label.
///
/// Each tag maps to a single bit in a u64 [bitmask]. Filtering uses bitwise
/// AND through [EntityStore]. Tags are owned by an entity via [entityId].
final class EntityTag {
  final int entityId;
  final String name;
  final bool isPublic;
  final int bitmask;

  const EntityTag({
    required this.entityId,
    required this.name,
    this.isPublic = true,
    this.bitmask = 0,
  });
}

/// Flat key/value property attached to an entity.
final class EntityProperty {
  final int entityId;
  final String key;
  final String value;

  const EntityProperty({
    required this.entityId,
    required this.key,
    required this.value,
  });
}

/// Engine status for the native core.
enum EngineStatus { active, standby, corrupt, unverified }

/// Supported native runtimes.
enum NativeRuntime { rust }

/// Native engine descriptor.
final class Engine {
  final String id;
  final String name;
  final String version;
  final NativeRuntime runtime;
  final String binaryName;
  final String sha256;
  final int allocatedMemoryBytes;
  final EngineStatus status;

  const Engine({
    required this.id,
    required this.name,
    required this.version,
    required this.runtime,
    required this.binaryName,
    required this.sha256,
    required this.allocatedMemoryBytes,
    required this.status,
  });
}
