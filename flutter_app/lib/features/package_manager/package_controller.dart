import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/models/flat_models.dart';
import '../../core/state/entity_store.dart';
import '../../core/compiler/package_compiler.dart';
import '../../core/services/app_state_persistence_service.dart';
import '../../core/services/user_workspace_directory_service.dart';

class _ParsedPackageResult {
  final EntityPackage package;
  final List<Entity> entities;
  final List<EntityPayload> payloads;
  final List<EntityTag> tags;

  const _ParsedPackageResult({
    required this.package,
    required this.entities,
    required this.payloads,
    required this.tags,
  });
}

class PackageController extends ChangeNotifier {
  static final PackageController _instance = PackageController._internal();
  factory PackageController() => _instance;
  PackageController._internal();

  static const int _maxSkinImages = 32;
  static const int _maxSkinImageBytes = 128 * 1024 * 1024; // 128 MB
  static final LinkedHashMap<String, ui.Image> skinImages =
      LinkedHashMap<String, ui.Image>();
  static int _skinImageBytes = 0;

  final List<EntityPackage> _registry = [];
  final EntityStore _store = EntityStore();

  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  final UserWorkspaceDirectoryService _userWorkspace =
      UserWorkspaceDirectoryService();
  bool _initialized = false;
  String? _workspaceRootOverride;
  String? _resolvedWorkspaceRoot;

  EntityStore get store => _store;
  List<Entity> get entities => _store.entities.whereType<Entity>().toList();
  List<EntityPayload> get payloads =>
      _store.payloads.whereType<EntityPayload>().toList();
  List<EntityTag> get tags => _store.tags;
  List<EntityProperty> get properties => _store.properties;

  /// Clears the in-memory registry and resets the initialization flag.
  /// Intended for tests; do not call in production.
  void reset() {
    _registry.clear();
    _store.clear();
    _initialized = false;
    notifyListeners();
  }

  /// Overrides the workspace root used for package scanning. Intended for
  /// tests; do not call in production.
  void setWorkspaceRootOverride(String path) {
    _workspaceRootOverride = path;
    _resolvedWorkspaceRoot = path;
  }

  void clearWorkspaceRootOverride() {
    _workspaceRootOverride = null;
    _resolvedWorkspaceRoot = null;
  }

  Future<void> updateWorkspaceRoot(String? path) async {
    if (path == null) {
      await _userWorkspace.resetToDefault();
    } else {
      await _userWorkspace.setUserWorkspaceDirectory(path);
    }
    _workspaceRootOverride = null;
    _resolvedWorkspaceRoot = null;
    _initialized = false;
    await init();
  }

  /// Resolves the user workspace root where packages and systems are stored.
  ///
  /// Priority:
  /// 1. In-memory test override.
  /// 2. Cached root resolved during [init].
  /// 3. Repository root detection (development fallback).
  String resolveWorkspaceRoot() {
    if (_workspaceRootOverride != null) return _workspaceRootOverride!;
    if (_resolvedWorkspaceRoot != null) return _resolvedWorkspaceRoot!;

    final current = Directory.current.path;
    final separator = Platform.pathSeparator;
    final parts = current.split(separator);
    // Walk up the path components until we find the repository root marker
    // (Cargo.toml) or the Malphas examples folder.
    for (int i = parts.length; i > 0; i--) {
      final candidate = parts.sublist(0, i).join(separator);
      if (File('$candidate${separator}Cargo.toml').existsSync()) {
        return candidate;
      }
      if (Directory('$candidate${separator}examples').existsSync()) {
        return candidate;
      }
    }
    return current;
  }

  Future<void> init() async {
    if (_initialized) return;

    try {
      final savedOverride = await _persistence.loadWorkspaceRootOverride();
      if (savedOverride != null && savedOverride.isNotEmpty) {
        _workspaceRootOverride = savedOverride;
      }

      if (_workspaceRootOverride != null) {
        _resolvedWorkspaceRoot = _workspaceRootOverride;
      } else {
        _resolvedWorkspaceRoot =
            await _userWorkspace.resolveUserWorkspaceRoot();
      }

      final workspace = resolveWorkspaceRoot();
      final packagesDir = Directory('$workspace/packages');
      if (!packagesDir.existsSync()) {
        packagesDir.createSync(recursive: true);
      }

      if (Platform.isAndroid || Platform.isIOS) {
        final demoMsp = File('${packagesDir.path}/bouncing_demo.msp');
        final demoMxc = File('${packagesDir.path}/bouncing_demo.mxc');
        final demoMeta =
            File('${packagesDir.path}/bouncing_demo.manifest.json');

        if (!demoMsp.existsSync() ||
            !demoMxc.existsSync() ||
            !demoMeta.existsSync()) {
          try {
            final mspBytes =
                await rootBundle.load('assets/packages/bouncing_demo.msp');
            await demoMsp.writeAsBytes(mspBytes.buffer
                .asUint8List(mspBytes.offsetInBytes, mspBytes.lengthInBytes));

            final mxcBytes =
                await rootBundle.load('assets/packages/bouncing_demo.mxc');
            await demoMxc.writeAsBytes(mxcBytes.buffer
                .asUint8List(mxcBytes.offsetInBytes, mxcBytes.lengthInBytes));

            final metaBytes = await rootBundle
                .load('assets/packages/bouncing_demo.manifest.json');
            await demoMeta.writeAsBytes(metaBytes.buffer
                .asUint8List(metaBytes.offsetInBytes, metaBytes.lengthInBytes));
          } catch (e) {
            debugPrint('Error unpacking bouncing_demo assets: $e');
          }
        }
      }

      await _ensureBouncingDemoCompiled(workspace);

      // Restore previously loaded package ids so `isLoaded` state survives
      // across app launches.
      final persistedIds = await _persistence.loadRegistryIds();

      // Scan examples/**/*.msp
      final examplesDir = Directory('$workspace/examples');
      if (!examplesDir.existsSync()) {
        examplesDir.createSync(recursive: true);
      }
      for (final entity in examplesDir.listSync(recursive: true)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.msp')) {
          final result = _parseMspPackage(entity);
          if (result != null) {
            final isLoaded = persistedIds.contains(result.package.id);
            final pack = EntityPackage(
              result.package.id,
              result.package.name,
              result.package.version,
              result.package.author,
              result.package.description,
              result.package.coverImagePath,
              isLoaded,
            );
            _registerPackageData(
                pack, result.entities, result.payloads, result.tags);
          }
        }
      }

      // Scan packages/*.msp
      for (final file in packagesDir.listSync()) {
        if (file is File && file.path.toLowerCase().endsWith('.msp')) {
          final result = _parseMspPackage(file);
          if (result != null) {
            final isLoaded = persistedIds.contains(result.package.id);
            final pack = EntityPackage(
              result.package.id,
              result.package.name,
              result.package.version,
              result.package.author,
              result.package.description,
              result.package.coverImagePath,
              isLoaded,
            );
            _registerPackageData(
                pack, result.entities, result.payloads, result.tags);
          }
        }
      }

      notifyListeners();
      _initialized = true;
    } catch (e) {
      _initialized = false;
      rethrow;
    }
  }

  void _registerPackageData(
    EntityPackage pack,
    List<Entity> packEntities,
    List<EntityPayload> packPayloads,
    List<EntityTag> packTags,
  ) {
    _registry.removeWhere((p) => p.id == pack.id);

    _registry.add(pack);
    for (final entity in packEntities) {
      _store.setEntity(entity);
    }
    for (final payload in packPayloads) {
      _store.setPayload(payload);
    }
    for (final tag in packTags) {
      _store.addTag(tag);
    }
  }

  Future<void> _persistRegistry() async {
    await _persistence.saveRegistryIds(
      _registry.where((p) => p.isLoaded).map((p) => p.id).toList(),
    );
  }

  int _tagMaskFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('render')) return 1;
    if (lower.contains('physics')) return 2;
    if (lower.contains('input')) return 4;
    if (lower.contains('audio')) return 8;
    return 16;
  }

  /// Build a 64-byte aligned payload blob from typed entity properties.
  ///
  /// The `physics_body` layout matches the `EntityPayload` struct consumed by
  /// the built-in `bouncing_demo` system.  Other payload types are stored as
  /// opaque 64-byte placeholders for now.
  Uint8List _buildPayloadBytes(
    String payloadType,
    int entityId,
    Map<String, String> props,
  ) {
    const payloadSize = 64;
    final bytes = Uint8List(payloadSize);
    final data = ByteData.view(bytes.buffer);

    switch (payloadType) {
      case 'physics_body':
        final tagMask = int.tryParse(props['tagMask'] ?? '1') ?? 1;
        final x = double.tryParse(props['x'] ?? '0') ?? 0.0;
        final y = double.tryParse(props['y'] ?? '0') ?? 0.0;
        final width = double.tryParse(props['width'] ?? '10') ?? 10.0;
        final height = double.tryParse(props['height'] ?? '10') ?? 10.0;
        final speedX = double.tryParse(props['speedX'] ?? '0') ?? 0.0;
        final speedY = double.tryParse(props['speedY'] ?? '0') ?? 0.0;
        final color = _parseHexColor(props['color'] ?? '0xFF00FFCC');
        final flags = int.tryParse(props['flags'] ?? '0') ?? 0;
        final minX = double.tryParse(props['minX'] ?? '0') ?? 0.0;
        final maxX = double.tryParse(props['maxX'] ?? '1000') ?? 1000.0;
        final minY = double.tryParse(props['minY'] ?? '0') ?? 0.0;
        final maxY = double.tryParse(props['maxY'] ?? '1000') ?? 1000.0;

        data.setUint64(0, tagMask, Endian.little);
        data.setFloat32(8, x, Endian.little);
        data.setFloat32(12, y, Endian.little);
        data.setFloat32(16, width, Endian.little);
        data.setFloat32(20, height, Endian.little);
        data.setFloat32(24, speedX, Endian.little);
        data.setFloat32(28, speedY, Endian.little);
        data.setUint32(32, color, Endian.little);
        data.setUint32(36, flags, Endian.little);
        data.setFloat32(40, minX, Endian.little);
        data.setFloat32(44, maxX, Endian.little);
        data.setFloat32(48, minY, Endian.little);
        data.setFloat32(52, maxY, Endian.little);
      default:
        // Opaque placeholder: entity id header plus JSON properties.
        data.setUint32(0, entityId, Endian.little);
        final propText = utf8.encode(jsonEncode(props));
        final copyLength = propText.length > payloadSize - 4
            ? payloadSize - 4
            : propText.length;
        bytes.setRange(4, 4 + copyLength, propText);
    }

    return bytes;
  }

  int _parseHexColor(String hex) {
    var cleaned = hex.trim().replaceFirst('0x', '').replaceFirst('0X', '');
    if (cleaned.length == 6) cleaned = 'FF$cleaned';
    return int.tryParse(cleaned, radix: 16) ?? 0xFF00FFCC;
  }

  String _payloadTypeNameFromId(int id) {
    switch (id) {
      case 1:
        return 'rectangle';
      case 2:
        return 'sprite';
      case 3:
        return 'sound';
      case 4:
        return 'text';
      case 5:
        return 'physics_body';
      case 6:
        return 'transform';
      default:
        return 'unknown';
    }
  }

  /// Parses a valid MLPS binary and returns a [_ParsedPackageResult] containing relational tables.
  _ParsedPackageResult? _parseMspPackage(File file) {
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.length < 56) return null;

      // Verify magic header: 'MLPS'
      if (bytes[0] != 0x4D ||
          bytes[1] != 0x4C ||
          bytes[2] != 0x50 ||
          bytes[3] != 0x53) {
        return null;
      }

      final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
      final version = data.getUint32(4, Endian.little);

      final entitiesTableOffset = data.getUint32(8, Endian.little);
      final entitiesCount = data.getUint32(12, Endian.little);
      final payloadSectionOffset = data.getUint32(16, Endian.little);
      final payloadSectionSize = data.getUint32(20, Endian.little);
      // checksum at bytes 24-56

      // Validate header values are within file bounds.
      if (entitiesTableOffset > bytes.length ||
          payloadSectionOffset > bytes.length) {
        return null;
      }
      if (payloadSectionOffset + payloadSectionSize > bytes.length) {
        return null;
      }

      String? packId;
      final manifestCandidates = [
        File(
            '${file.parent.path}/${file.uri.pathSegments.last.split('.').first}.manifest.json'),
        File('${file.parent.path}/manifest.json'),
      ];
      File? manifestFile;
      for (final candidate in manifestCandidates) {
        if (candidate.existsSync()) {
          manifestFile = candidate;
          break;
        }
      }

      if (manifestFile != null) {
        try {
          final manifestJson = jsonDecode(manifestFile.readAsStringSync())
              as Map<String, dynamic>;
          packId = manifestJson['pack_id'] as String?;
        } catch (_) {
          // Ignore malformed manifest; fall through to null packId.
        }
      }

      packId ??= file.uri.pathSegments.last.split('.').first;

      final List<Entity> parsedEntities = [];
      final List<EntityTag> parsedTags = [];
      final List<EntityPayload> parsedPayloads = [];

      const descriptorSize = 64;
      for (int i = 0; i < entitiesCount; i++) {
        final entryOffset = entitiesTableOffset + (i * descriptorSize);
        if (entryOffset < 0 || entryOffset + descriptorSize > bytes.length) {
          break;
        }

        final entId = data.getUint32(entryOffset, Endian.little);
        final payloadTypeId = data.getUint32(entryOffset + 4, Endian.little);
        final payloadTypeName = _payloadTypeNameFromId(payloadTypeId);
        parsedEntities.add(Entity(
          id: entId,
          packageId: packId,
          name: 'Entity $entId',
          category: payloadTypeName,
          activePayloadId: 0,
        ));
        parsedTags.add(EntityTag(
          entityId: entId,
          name: 'entity_$entId',
          bitmask: 1 << (entId % 64),
        ));
      }

      if (manifestFile != null) {
        try {
          final manifestJson = jsonDecode(manifestFile.readAsStringSync())
              as Map<String, dynamic>;
          final name = manifestJson['name'] as String? ?? 'MSP Pack ($packId)';
          final manifestVersion =
              manifestJson['version'] as String? ?? 'v$version.0.0';
          final author =
              manifestJson['author'] as String? ?? 'Compiled Artifact';
          final description = manifestJson['description'] as String? ??
              'Zero-copy binary structure with aligned headers.';

          final List<Entity> richEntities = [];
          final List<EntityTag> richTags = [];
          final List<EntityPayload> richPayloads = [];

          final manifestEntities =
              manifestJson['entities'] ?? manifestJson['objects'];
          if (manifestEntities is List) {
            for (var entJson in manifestEntities) {
              final idVal =
                  entJson['entity_id'] ?? entJson['object_id'] ?? entJson['id'];
              final intId =
                  idVal is int ? idVal : (int.tryParse(idVal.toString()) ?? 1);

              final manifestPayloads = entJson['payloads'] ?? entJson['skins'];
              int activePayloadId = 0;
              if (manifestPayloads is List) {
                for (int pIdx = 0; pIdx < manifestPayloads.length; pIdx++) {
                  final s = manifestPayloads[pIdx];
                  final payloadId = pIdx + 1;
                  richPayloads.add(EntityPayload(
                    id: payloadId,
                    entityId: intId,
                    name: s['name'] as String? ?? 'Payload $payloadId',
                    assetPath: s['assetPath'] as String? ?? 'none',
                    type: s['type'] as String? ?? 'binary',
                  ));
                  if (s['assetPath'] != null &&
                      s['assetPath'] != 'none' &&
                      activePayloadId == 0) {
                    activePayloadId = payloadId;
                  }
                }
              }

              int tagMask = 1;
              if (entJson['tags'] is List) {
                for (var t in entJson['tags']) {
                  final label = t is String
                      ? t
                      : (t is Map ? t['name'] as String? : null);
                  if (label != null) {
                    tagMask |= _tagMaskFromName(label);
                  }
                }
              }
              richTags.add(EntityTag(
                entityId: intId,
                name: 'entity_$intId',
                bitmask: tagMask,
              ));
              richEntities.add(Entity(
                id: intId,
                packageId: packId,
                name: entJson['name'] as String? ?? 'Entity $intId',
                category: entJson['category'] as String? ?? 'Dynamic Sprite',
                activePayloadId: activePayloadId,
              ));
            }
          }

          final pack = EntityPackage(
            packId,
            name,
            manifestVersion,
            author,
            description,
            manifestJson['coverImagePath'] as String?,
            false,
          );

          return _ParsedPackageResult(
            package: pack,
            entities: richEntities.isNotEmpty ? richEntities : parsedEntities,
            payloads: richPayloads,
            tags: richTags.isNotEmpty ? richTags : parsedTags,
          );
        } catch (_) {
          // Fallback if manifest is malformed
        }
      }

      final pack = EntityPackage(
        packId,
        'MSP Pack ($packId)',
        'v$version.0.0',
        'Compiled Artifact',
        'Zero-copy binary structure with aligned headers.',
        null,
        false,
      );

      return _ParsedPackageResult(
        package: pack,
        entities: parsedEntities,
        payloads: parsedPayloads,
        tags: parsedTags,
      );
    } catch (e) {
      return null;
    }
  }

  /// Compiles `examples/bouncing_demo/manifest.json` if the manifest is present
  /// but its `.msp` artifact is missing.
  Future<void> _ensureBouncingDemoCompiled(String workspace) async {
    final manifestFile = File(
      '$workspace/examples/bouncing_demo/manifest.json',
    );
    final mspFile = File('$workspace/examples/bouncing_demo/bouncing_demo.msp');

    if (!manifestFile.existsSync() || mspFile.existsSync()) {
      return;
    }

    final compiler = MalphasPackageCompiler();
    if (!await compiler.isCliAvailable()) {
      throw Exception(
        'malphas-cli is not available, cannot compile examples/bouncing_demo/manifest.json',
      );
    }

    final manifestText = manifestFile.readAsStringSync();
    final manifest = jsonDecode(manifestText) as Map<String, dynamic>;

    // Copy the manifest and any referenced payload files into a working
    // directory so the compiler can resolve relative payload_file paths.
    final compileDir =
        await Directory.systemTemp.createTemp('malphas_compile_bouncing_demo_');
    await manifestFile.copy('${compileDir.path}/manifest.json');
    final entities = manifest['entities'];
    if (entities is List) {
      for (final ent in entities) {
        final payloadFile = ent['payload_file'] as String?;
        if (payloadFile != null && payloadFile.isNotEmpty) {
          final source = File('$workspace/examples/bouncing_demo/$payloadFile');
          if (source.existsSync()) {
            await source.copy('${compileDir.path}/$payloadFile');
          }
        }
      }
    }

    final output = await compiler.compilePackage(
      manifest,
      sourceDir: compileDir,
    );

    final packId = manifest['pack_id'] as String? ?? 'bouncing_demo';

    await File(
      '$workspace/examples/bouncing_demo/$packId.msp',
    ).writeAsBytes(output.mspBytes);
  }

  List<EntityPackage> getAllPackages() => List.unmodifiable(_registry);
  List<EntityPackage> getActivePackages() =>
      List.unmodifiable(_registry.where((p) => p.isLoaded));

  Future<void> setPackageLoaded(String id, {required bool loaded}) async {
    final index = _registry.indexWhere((p) => p.id == id);
    if (index == -1) return;
    final p = _registry[index];
    _registry[index] = EntityPackage(
      p.id,
      p.name,
      p.version,
      p.author,
      p.description,
      p.coverImagePath,
      loaded,
    );
    await _persistRegistry();
    notifyListeners();
  }

  Future<void> injectPackage(EntityPackage pack) async {
    _registry.add(pack);
    await _persistRegistry();
    notifyListeners();
  }

  Future<void> deletePackage(String id) async {
    _registry.removeWhere((p) => p.id == id);
    _store.removePackageData(id);
    await _persistRegistry();
    notifyListeners();
  }

  void updateEntityActivePayload(int entityId, int activePayloadId) {
    final entity = _store.getEntity(entityId);
    if (entity != null) {
      _store.setEntity(Entity(
        id: entity.id,
        packageId: entity.packageId,
        name: entity.name,
        category: entity.category,
        activePayloadId: activePayloadId,
      ));
    }
  }

  /// Preloads skins/sprites for the active package into unmanaged C++ memory (ui.Image).
  Future<void> preloadPayloads(EntityPackage pack) async {
    await disposeSkins();

    final packEntities = _store.entities
        .whereType<Entity>()
        .where((e) => e.packageId == pack.id)
        .map((e) => e.id)
        .toSet();
    final packPayloads = _store.payloads
        .whereType<EntityPayload>()
        .where((p) => packEntities.contains(p.entityId));

    for (final payload in packPayloads) {
      final path = payload.assetPath;
      if (path.isEmpty || path == 'none') continue;

      try {
        File file = File(path);
        if (!file.existsSync()) {
          final ws = resolveWorkspaceRoot();
          file = File('$ws/$path');
        }
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          _putSkinImage(path, frame.image);
        }
      } catch (_) {
        // Skip individual failed loads
      }
    }
  }

  static int _imageSizeBytes(ui.Image image) {
    return image.width * image.height * 4;
  }

  void _putSkinImage(String path, ui.Image image) {
    if (skinImages.containsKey(path)) {
      // Move to most-recently-used position and refresh byte accounting.
      final old = skinImages.remove(path);
      if (old != null) _skinImageBytes -= _imageSizeBytes(old);
    }

    final incoming = _imageSizeBytes(image);
    while (skinImages.isNotEmpty &&
        (skinImages.length >= _maxSkinImages ||
            _skinImageBytes + incoming > _maxSkinImageBytes)) {
      final evicted = skinImages.remove(skinImages.keys.first);
      if (evicted != null) {
        _skinImageBytes -= _imageSizeBytes(evicted);
        try {
          evicted.dispose();
        } catch (_) {
          // Safe check
        }
      }
    }

    skinImages[path] = image;
    _skinImageBytes += incoming;
  }

  /// Explicitly disposes of all loaded ui.Image structures to free native RAM.
  Future<void> disposeSkins() async {
    for (final image in skinImages.values) {
      try {
        image.dispose();
      } catch (_) {
        // Safe check
      }
    }
    skinImages.clear();
    _skinImageBytes = 0;
  }

  /// Compiles a custom package and registers it.
  Future<void> createAndCompilePackage({
    required String packId,
    required String name,
    required String version,
    required String author,
    required String description,
    required int canvasWidth,
    required int canvasHeight,
    required List<Entity> entities,
    required List<EntityPayload> payloads,
    required List<EntityTag> tags,
    required List<EntityProperty> properties,
  }) async {
    final workspace = resolveWorkspaceRoot();
    final packagesDir = Directory('$workspace/packages');
    if (!packagesDir.existsSync()) {
      packagesDir.createSync(recursive: true);
    }

    final spritesDir = Directory('${packagesDir.path}/$packId/sprites');
    if (!spritesDir.existsSync()) {
      spritesDir.createSync(recursive: true);
    }

    final List<EntityPayload> processedPayloads = [];
    for (final s in payloads) {
      final srcPath = s.assetPath;
      if (srcPath.isNotEmpty && srcPath != 'none') {
        try {
          File srcFile = File(srcPath);
          if (!srcFile.existsSync()) {
            final ws = resolveWorkspaceRoot();
            srcFile = File('$ws/$srcPath');
          }
          if (srcFile.existsSync()) {
            final filename = srcFile.uri.pathSegments.last;
            final destFile = File('${spritesDir.path}/$filename');
            await srcFile.copy(destFile.path);
            processedPayloads.add(EntityPayload(
              id: s.id,
              entityId: s.entityId,
              name: s.name,
              assetPath: 'packages/$packId/sprites/$filename',
              type: s.type,
              version: s.version,
            ));
          } else {
            processedPayloads.add(s);
          }
        } catch (_) {
          processedPayloads.add(s);
        }
      } else {
        processedPayloads.add(s);
      }
    }

    // 1. Build the full rich manifest JSON map
    final richManifest = {
      'pack_id': packId,
      'name': name,
      'version': version,
      'author': author,
      'description': description,
      'canvas_width': canvasWidth,
      'canvas_height': canvasHeight,
      'entities': entities.map((ent) {
        final entProps = properties
            .where((p) => p.entityId == ent.id)
            .fold<Map<String, String>>({}, (acc, p) {
          acc[p.key] = p.value;
          return acc;
        });

        final entTags = tags
            .where((t) => t.entityId == ent.id)
            .map((t) => {'name': t.name, 'isPublic': t.isPublic})
            .toList();

        final entPayloads = processedPayloads
            .where((p) => p.entityId == ent.id)
            .map((p) => {
                  'id': p.id,
                  'name': p.name,
                  'assetPath': p.assetPath,
                  'version': p.version,
                })
            .toList();

        return {
          'entity_id': ent.id,
          'name': ent.name,
          'category': ent.category,
          'tags': entTags,
          'payloads': entPayloads,
          'properties': entProps,
        };
      }).toList(),
    };

    // 2. Prepare a working directory and generate real aligned payload files.
    final compileDir =
        await Directory.systemTemp.createTemp('malphas_compile_');
    final compilerProcessedPayloads = <EntityPayload>[];

    final strippedEntities = <Map<String, dynamic>>[];
    for (final ent in entities) {
      // Collect the entity's typed properties.
      final entProps = properties
          .where((p) => p.entityId == ent.id)
          .fold<Map<String, String>>({}, (acc, p) {
        acc[p.key] = p.value;
        return acc;
      });
      final payloadType = entProps['payloadType'] ?? 'unknown';
      final payloadFileName = 'entity_${ent.id}.bin';
      final payloadFile = File('${compileDir.path}/$payloadFileName');

      final payloadBytes = _buildPayloadBytes(payloadType, ent.id, entProps);
      await payloadFile.writeAsBytes(payloadBytes);

      compilerProcessedPayloads.add(EntityPayload(
        id: ent.activePayloadId == 0 ? 1 : ent.activePayloadId,
        entityId: ent.id,
        name: 'Payload ${ent.id}',
        assetPath: 'packages/$packId/$payloadFileName',
        type: payloadType,
        version: '1.0',
      ));

      strippedEntities.add({
        'entity_id': ent.id,
        'tag_mask': tags
                .where((t) => t.entityId == ent.id)
                .fold<int>(0, (mask, t) => mask | _tagMaskFromName(t.name)) |
            1,
        'payload_type': payloadType,
        'payload_file': payloadFileName,
      });
    }

    // 3. Build the stripped minimal manifest for malphas-cli.
    final strippedManifest = {
      'pack_id': packId,
      'entities': strippedEntities,
    };

    // 4. Compile using MalphasPackageCompiler.
    final compiler = MalphasPackageCompiler();
    final output = await compiler.compilePackage(
      strippedManifest,
      sourceDir: compileDir,
    );

    // 5. Save files to packages/.
    final mspFile = File('${packagesDir.path}/$packId.msp');
    final manifestFile = File('${packagesDir.path}/$packId.manifest.json');

    await mspFile.writeAsBytes(output.mspBytes);
    await manifestFile.writeAsString(jsonEncode(richManifest));

    // 6. Update processed payloads to reference the generated payload files.
    processedPayloads.clear();
    processedPayloads.addAll(compilerProcessedPayloads);

    // 7. Reload registry.
    _initialized = false;
    await init();
  }

  /// Compiles an arbitrary package manifest via [MalphasPackageCompiler] and
  /// exports the resulting `.msp` to `packages/`.
  ///
  /// Returns the path of the generated `.msp` file on success. Throws on
  /// compilation error or missing CLI.
  Future<String> compileAndExportPackage(
    String packId,
    Map<String, dynamic> manifest, {
    Directory? sourceDir,
  }) async {
    final compiler = MalphasPackageCompiler();
    if (!await compiler.isCliAvailable()) {
      throw Exception('malphas-cli is not available');
    }

    final workspace = resolveWorkspaceRoot();
    final packagesDir = Directory('$workspace/packages');
    if (!packagesDir.existsSync()) {
      packagesDir.createSync(recursive: true);
    }

    final output =
        await compiler.compilePackage(manifest, sourceDir: sourceDir);
    final mspPath = '${packagesDir.path}/$packId.msp';
    await File(mspPath).writeAsBytes(output.mspBytes);

    // Persist the rich manifest next to the binary for UI consumption.
    final manifestPath = '${packagesDir.path}/$packId.manifest.json';
    await File(manifestPath).writeAsString(jsonEncode(manifest));

    // Refresh registry so the new package is immediately available.
    _initialized = false;
    await init();
    notifyListeners();

    return mspPath;
  }
}
