import 'package:flutter/foundation.dart';
import '../models/entity_models.dart';

/// Relational store for DOD-style entity/payload/tag/property state.
///
/// All lookups are index-based through flat [List]s. There is no
/// ChangeNotifier per entity; only the store itself notifies.
class EntityStore extends ChangeNotifier {
  static final EntityStore _instance = EntityStore._internal();
  factory EntityStore() => _instance;
  EntityStore._internal();

  final List<Entity?> _entities = [];
  final List<EntityPayload?> _payloads = [];
  final List<EntityTag> _tags = [];
  final List<EntityProperty> _properties = [];

  /// Sparse entity array indexed by entity id. Grows on demand.
  List<Entity?> get entities => List.unmodifiable(_entities);

  /// Sparse payload array indexed by payload id. Grows on demand.
  List<EntityPayload?> get payloads => List.unmodifiable(_payloads);

  /// Flat tag list.
  List<EntityTag> get tags => List.unmodifiable(_tags);

  /// Flat property list.
  List<EntityProperty> get properties => List.unmodifiable(_properties);

  /// Total number of registered entities (including null slots).
  int get entityCount => _entities.length;

  /// Total number of registered payloads (including null slots).
  int get payloadCount => _payloads.length;

  /// Resolves an entity by id in O(1).
  Entity? getEntity(int id) =>
      id >= 0 && id < _entities.length ? _entities[id] : null;

  /// Resolves a payload by id in O(1).
  EntityPayload? getPayload(int id) =>
      id >= 0 && id < _payloads.length ? _payloads[id] : null;

  /// Resolves the active payload for an entity in O(1).
  EntityPayload? getActivePayload(int entityId) {
    final entity = getEntity(entityId);
    if (entity == null) return null;
    return getPayload(entity.activePayloadId);
  }

  /// Inserts or replaces an entity. The store grows the sparse array if needed.
  void setEntity(Entity entity) {
    if (entity.id >= _entities.length) {
      _entities.length = entity.id + 1;
    }
    _entities[entity.id] = entity;
    notifyListeners();
  }

  /// Inserts or replaces a payload.
  void setPayload(EntityPayload payload) {
    if (payload.id >= _payloads.length) {
      _payloads.length = payload.id + 1;
    }
    _payloads[payload.id] = payload;
    notifyListeners();
  }

  /// Registers a tag.
  void addTag(EntityTag tag) {
    _tags.add(tag);
    notifyListeners();
  }

  /// Registers a property.
  void addProperty(EntityProperty property) {
    _properties.add(property);
    notifyListeners();
  }

  /// Replaces all properties for [entityId].
  void setPropertiesForEntity(int entityId, List<EntityProperty> properties) {
    _properties.removeWhere((p) => p.entityId == entityId);
    _properties.addAll(properties);
    notifyListeners();
  }

  /// Removes all state belonging to [packageId].
  void removePackageData(String packageId) {
    final entityIds = <int>{};
    for (int i = 0; i < _entities.length; i++) {
      final entity = _entities[i];
      if (entity != null && entity.packageId == packageId) {
        entityIds.add(i);
        _entities[i] = null;
      }
    }
    _payloads.removeWhere((p) => p != null && entityIds.contains(p.entityId));
    _tags.removeWhere((t) => entityIds.contains(t.entityId));
    _properties.removeWhere((p) => entityIds.contains(p.entityId));
    notifyListeners();
  }

  /// Clears all state.
  void clear() {
    _entities.clear();
    _payloads.clear();
    _tags.clear();
    _properties.clear();
    notifyListeners();
  }

  /// Returns entity ids whose effective tag mask shares at least one bit with
  /// [mask]. An entity with no registered tags is treated as mask 0.
  List<int> filterByTagMask(int mask) {
    final result = <int>[];
    for (int i = 0; i < _entities.length; i++) {
      final entity = _entities[i];
      if (entity == null) continue;
      final entityMask = _effectiveTagMask(entity.id);
      if (mask == 0) {
        if (entityMask == 0) result.add(i);
      } else if ((entityMask & mask) != 0) {
        result.add(i);
      }
    }
    return result;
  }

  int _effectiveTagMask(int entityId) {
    int mask = 0;
    for (final tag in _tags) {
      if (tag.entityId == entityId) {
        mask |= tag.bitmask;
      }
    }
    return mask;
  }
}
