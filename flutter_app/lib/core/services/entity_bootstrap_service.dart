import 'dart:convert';
import 'dart:typed_data';
import '../ffi/malphas_bindings.dart';
import '../../features/package_manager/models.dart';

/// Scene layout constants used by the entity bootstrap service.
///
/// These values are Dart-side defaults for positioning and styling entities.
/// They are intentionally separate from the low-level Arena header offsets in
/// [ArenaLayout] so the two contracts cannot be confused.
class SceneLayout {
  SceneLayout._();

  static const int textPayloadOffset = 8192;
  static const int logicalWidth = 1000;
  static const int logicalHeight = 1000;
  static const int defaultRectangleColor = 0xFF00FFCC;
  static const int defaultTextColor = 0xFFFFFFFF;
}

/// Decouples entity setup from the workspace UI.
///
/// The service configures a safe default scene through the Rust-gated helpers.
/// Future package-driven setups should receive the parsed package metadata and
/// pause the engine around multi-step writes to avoid torn state.
class EntityBootstrapService {
  final MalphasBindings bindings;

  const EntityBootstrapService(this.bindings);

  /// A safe, well-tested default scene: one bouncing rectangle and one label.
  void configureDefaultScene() => _configureDefaultScene();

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
      colorRgba: SceneLayout.defaultRectangleColor,
      speedX: 4.0,
      speedY: 3.0,
      minX: 0.0,
      maxX: SceneLayout.logicalWidth.toDouble(),
      minY: 0.0,
      maxY: SceneLayout.logicalHeight.toDouble(),
    );

    bindings.writeArenaText(
      SceneLayout.textPayloadOffset,
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
      colorRgba: SceneLayout.defaultTextColor,
      speedX: 0.0,
      speedY: 0.0,
      minX: 0.0,
      maxX: SceneLayout.logicalWidth.toDouble(),
      minY: 0.0,
      maxY: SceneLayout.logicalHeight.toDouble(),
      strOffset: SceneLayout.textPayloadOffset,
    );
  }

  void configurePackageScene(MalphasPackage pack) {
    bindings.setEntitiesCount(pack.objects.length);

    int textOffsetAccumulator =
        4 * 1024 * 1024; // Allocate text strings at offset 4MB in Arena

    for (int i = 0; i < pack.objects.length; i++) {
      final obj = pack.objects[i];
      final props = obj.properties;

      final kind = props['kind'] ?? 'rectangle';
      final commandType = kind == 'text' ? 2 : 1;

      final double x = double.tryParse(props['x'] ?? '') ?? (50.0 + i * 40.0);
      final double y = double.tryParse(props['y'] ?? '') ?? (50.0 + i * 40.0);
      final double w = double.tryParse(props['width'] ?? '') ?? 80.0;
      final double h = double.tryParse(props['height'] ?? '') ?? 80.0;
      final double speedX =
          double.tryParse(props['speedX'] ?? '') ?? (2.0 + i * 1.5);
      final double speedY =
          double.tryParse(props['speedY'] ?? '') ?? (1.5 + i * 1.0);

      final colorStr = props['color'] ?? '0xFF00FFCC';
      final int colorVal = int.tryParse(
              colorStr.replaceFirst('0x', '').replaceFirst('0X', ''),
              radix: 16) ??
          0xFF00FFCC;

      if (commandType == 2) {
        // Text entity
        final text = props['text'] ?? 'BLOCK';
        bindings.writeArenaText(
          textOffsetAccumulator,
          x,
          y,
          w, // font size
          Uint8List.fromList([...utf8.encode(text), 0]),
        );

        bindings.configureEntity(
          entityId: i,
          commandType: 2,
          layer: i,
          x: x,
          y: y,
          width: w, // font size
          height: 0,
          colorRgba: colorVal,
          speedX: speedX,
          speedY: speedY,
          minX: 0,
          maxX: SceneLayout.logicalWidth.toDouble(),
          minY: 0,
          maxY: SceneLayout.logicalHeight.toDouble(),
          strOffset: textOffsetAccumulator,
        );
        textOffsetAccumulator += 1024;
      } else {
        // Rectangle entity
        bindings.configureEntity(
          entityId: i,
          commandType: 1,
          layer: i,
          x: x,
          y: y,
          width: w,
          height: h,
          colorRgba: colorVal,
          speedX: speedX,
          speedY: speedY,
          minX: 0,
          maxX: SceneLayout.logicalWidth.toDouble(),
          minY: 0,
          maxY: SceneLayout.logicalHeight.toDouble(),
        );
      }
    }
  }
}
