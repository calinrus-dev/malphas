/// Shared Arena memory layout constants.
///
/// These offsets must stay in sync with `malphas_core/src/arena_layout.rs`.
/// The first 32 bytes of the Arena form a fixed header written by Rust and
/// read by both sides.
class ArenaLayout {
  ArenaLayout._();

  static const int arenaHeaderSize = 32;

  static const int staticResourcesOffset = 4;
  static const int staticResourcesSize = 8;
  static const int entitiesOffset = 12;
  static const int entitiesCount = 16;
  static const int fontMetricsOffset = 20;
  static const int fontAtlasOffset = 24;
  static const int objectsTableOffset = 28;

  static const int defaultStaticResourcesOffset = 1024;
  static const int defaultEntitiesOffset = 32;

  static const int entitySlotSize = 64;
  static const int entityStrOffset = 48;

  static const int textPayloadSize = 12;
  static const int renderCommandSize = 24;
}
