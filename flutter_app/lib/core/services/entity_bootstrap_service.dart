import 'dart:convert';
import 'dart:typed_data';
import '../../features/package_manager/models.dart';
import '../ffi/malphas_bindings.dart';

/// Shared Arena layout constants between Dart and Rust.
///
/// These offsets must stay in sync with the Rust side. They are duplicated
/// here as Dart constants so the bootstrap service can place TextPayload and
/// string data at known, non-overlapping locations without hard-coding magic
/// numbers in the UI layer.
class ArenaLayout {
  static const int textPayloadOffset = 8192;
  static const int logicalWidth = 1000;
  static const int logicalHeight = 1000;
  static const int defaultRectangleColor = 0xFF00FFCC;
  static const int defaultTextColor = 0xFFFFFFFF;
}

/// Decouples entity setup from the workspace UI.
///
/// Given a [MalphasPackage], the service translates its objects into native
/// entity configuration through the Rust-gated helpers. If the package does
/// not contain enough metadata to drive entity setup, a safe default scene
/// (one bouncing rectangle + one static text label) is configured instead.
class EntityBootstrapService {
  final MalphasBindings bindings;

  const EntityBootstrapService(this.bindings);

  /// Configures entities for [pack]. The engine must already be paused by the
  /// caller; this method only writes entity state.
  void configureFromPackage(MalphasPackage pack) {
    if (!bindings.isNativeAvailable) return;

    if (pack.objects.isEmpty) {
      // Packages without object metadata fall back to the well-tested default
      // scene so the workspace is never left empty.
      _configureDefaultScene();
      return;
    }

    // Map each parsed package object to a deterministic entity. Spatial
    // properties are not yet exposed by the manifest schema, so we lay objects
    // out in a stable grid and derive the command type from the object category.
    bindings.setEntitiesCount(pack.objects.length);

    const cols = 4;
    const spacing = 120.0;
    const startX = 50.0;
    const startY = 50.0;

    for (int i = 0; i < pack.objects.length; i++) {
      final obj = pack.objects[i];
      final col = i % cols;
      final row = i ~/ cols;
      final x = startX + col * spacing;
      final y = startY + row * spacing;
      final isText = obj.category.toLowerCase().contains('text');

      bindings.configureEntity(
        entityId: i,
        commandType: isText ? 2 : 1,
        layer: i,
        x: x,
        y: y,
        width: isText ? 80.0 : 80.0,
        height: isText ? 24.0 : 80.0,
        colorRgba: _colorForIndex(i),
        speedX: 0.0,
        speedY: 0.0,
        minX: 0.0,
        maxX: ArenaLayout.logicalWidth.toDouble(),
        minY: 0.0,
        maxY: ArenaLayout.logicalHeight.toDouble(),
      );
    }
  }

  /// A safe, well-tested default scene: one bouncing rectangle and one label.
  void configureDefaultScene() => _configureDefaultScene();

  static int _colorForIndex(int index) {
    const palette = <int>[
      0xFF00FFCC,
      0xFFFF6B6B,
      0xFF4ECDC4,
      0xFFFFE66D,
      0xFF1A535C,
      0xFFFF9F1C,
      0xFF9B5DE5,
      0xFFF15BB5,
    ];
    return palette[index % palette.length];
  }

  void _configureDefaultScene() {
    bindings.setEntitiesCount(2);

    bindings.configureEntity(
      entityId: 0,
      commandType: 1, // rectangle
      layer: 0,
      x: 50.0,
      y: 50.0,
      width: 100.0,
      height: 100.0,
      colorRgba: ArenaLayout.defaultRectangleColor,
      speedX: 4.0,
      speedY: 3.0,
      minX: 0.0,
      maxX: ArenaLayout.logicalWidth.toDouble(),
      minY: 0.0,
      maxY: ArenaLayout.logicalHeight.toDouble(),
    );

    bindings.writeArenaText(
      ArenaLayout.textPayloadOffset,
      100.0,
      100.0,
      24.0,
      Uint8List.fromList([...utf8.encode('MALPHAS'), 0]),
    );

    bindings.configureEntity(
      entityId: 1,
      commandType: 2, // text
      layer: 1,
      x: 100.0,
      y: 100.0,
      width: 24.0,
      height: 0.0,
      colorRgba: ArenaLayout.defaultTextColor,
      speedX: 0.0,
      speedY: 0.0,
      minX: 0.0,
      maxX: ArenaLayout.logicalWidth.toDouble(),
      minY: 0.0,
      maxY: ArenaLayout.logicalHeight.toDouble(),
      strOffset: ArenaLayout.textPayloadOffset,
    );
  }
}
