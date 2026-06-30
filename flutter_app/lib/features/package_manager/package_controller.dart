import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/models/flat_models.dart';
import '../../core/compiler/package_compiler.dart';
import '../../core/services/app_state_persistence_service.dart';

class _ParsedPackageResult {
  final EntityPackage package;
  final List<Entity> entities;
  final List<EntityPayload> payloads;
  final List<EntityTag> tags;
  final List<EntityProperty> properties;

  const _ParsedPackageResult({
    required this.package,
    required this.entities,
    required this.payloads,
    required this.tags,
    required this.properties,
  });
}

class PackageController extends ChangeNotifier {
  static final PackageController _instance = PackageController._internal();
  factory PackageController() => _instance;
  PackageController._internal();

  static final Map<String, ui.Image> skinImages = {};

  final List<EntityPackage> _registry = [];
  final List<Entity> _entities = [];
  final List<EntityPayload> _payloads = [];
  final List<EntityTag> _tags = [];
  final List<EntityProperty> _properties = [];

  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  bool _initialized = false;
  String? _workspaceRootOverride;

  List<Entity> get entities => List.unmodifiable(_entities);
  List<EntityPayload> get payloads => List.unmodifiable(_payloads);
  List<EntityTag> get tags => List.unmodifiable(_tags);
  List<EntityProperty> get properties => List.unmodifiable(_properties);

  /// Clears the in-memory registry and resets the initialization flag.
  /// Intended for tests; do not call in production.
  void reset() {
    _registry.clear();
    _entities.clear();
    _payloads.clear();
    _tags.clear();
    _properties.clear();
    _initialized = false;
    notifyListeners();
  }

  /// Overrides the workspace root used for package scanning. Intended for
  /// tests; do not call in production.
  void setWorkspaceRootOverride(String path) {
    _workspaceRootOverride = path;
  }

  void clearWorkspaceRootOverride() {
    _workspaceRootOverride = null;
  }

  Future<void> updateWorkspaceRoot(String? path) async {
    _workspaceRootOverride = path;
    _persistence.saveWorkspaceRootOverride(path);
    _initialized = false;
    await init();
  }

  /// Resolves the repository root. If the current working directory is
  /// `flutter_app/`, walks up one level so that `examples/` and `packages/`
  /// are found consistently in tests and CI.
  String resolveWorkspaceRoot() {
    if (_workspaceRootOverride != null) return _workspaceRootOverride!;

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
      final savedOverride = _persistence.loadWorkspaceRootOverride();
      if (savedOverride != null && savedOverride.isNotEmpty) {
        _workspaceRootOverride = savedOverride;
      } else if (Platform.isAndroid || Platform.isIOS) {
        final docDir = await getApplicationDocumentsDirectory();
        _workspaceRootOverride = docDir.path;
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
      final persistedIds = _persistence.loadRegistryIds();

      // Scan examples/**/*.msp
      final examplesDir = Directory('$workspace/examples');
      if (examplesDir.existsSync()) {
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
              _registerPackageData(pack, result.entities, result.payloads,
                  result.tags, result.properties);
            }
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
            _registerPackageData(pack, result.entities, result.payloads,
                result.tags, result.properties);
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
    List<EntityProperty> packProperties,
  ) {
    _registry.removeWhere((p) => p.id == pack.id);
    _entities.removeWhere((e) => e.packageId == pack.id);
    final entIds = packEntities.map((e) => e.id).toSet();
    _payloads.removeWhere((p) => entIds.contains(p.entityId));
    _tags.removeWhere((t) => entIds.contains(t.entityId));
    _properties.removeWhere((prop) => entIds.contains(prop.entityId));

    _registry.add(pack);
    _entities.addAll(packEntities);
    _payloads.addAll(packPayloads);
    _tags.addAll(packTags);
    _properties.addAll(packProperties);
  }

  void _persistRegistry() {
    _persistence.saveRegistryIds(
      _registry.where((p) => p.isLoaded).map((p) => p.id).toList(),
    );
  }

  /// Parses a valid MLPS binary and returns a [_ParsedPackageResult] containing relational tables.
  _ParsedPackageResult? _parseMspPackage(File file) {
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.length < 128) return null;

      // Verify magic header: 'MLPS'
      if (bytes[0] != 0x4D ||
          bytes[1] != 0x4C ||
          bytes[2] != 0x50 ||
          bytes[3] != 0x53) {
        return null;
      }

      final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
      final version = data.getUint32(4, Endian.little);

      // Read pack_id (16 bytes ASCII at offset 48)
      final packIdBytes = bytes.sublist(48, 64);
      final packId = utf8.decode(packIdBytes.takeWhile((b) => b != 0).toList());

      final entitiesCount = data.getUint32(80, Endian.little);
      final entitiesTableOffset = data.getUint32(76, Endian.little);

      final List<Entity> parsedEntities = [];
      final List<EntityTag> parsedTags = [];
      final List<EntityPayload> parsedPayloads = [];
      final List<EntityProperty> parsedProperties = [];

      for (int i = 0; i < entitiesCount; i++) {
        final entryOffset = entitiesTableOffset + (i * 64);
        if (entryOffset + 64 > bytes.length) break;

        final entId = data.getUint32(entryOffset, Endian.little);

        parsedEntities.add(
          Entity(
            entId,
            packId,
            'Voxel_Entity_$entId',
            'Compiled Archetype',
            0,
          ),
        );
        parsedTags.add(EntityTag(entId, 'Zero-Copy', true));
        parsedProperties.add(EntityProperty(entId, 'ID', '$entId'));
      }

      final manifestCandidates = [
        File('${file.parent.path}/$packId.manifest.json'),
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
          final List<EntityProperty> richProperties = [];

          final manifestEntities =
              manifestJson['entities'] ?? manifestJson['objects'];
          if (manifestEntities is List) {
            for (var entJson in manifestEntities) {
              final idVal =
                  entJson['entity_id'] ?? entJson['object_id'] ?? entJson['id'];
              final intId =
                  idVal is int ? idVal : (int.tryParse(idVal.toString()) ?? 1);
              final nameVal = entJson['name'] as String? ?? 'Entity $intId';
              final categoryVal =
                  entJson['category'] as String? ?? 'Compiled Archetype';

              final props = Map<String, dynamic>.from(
                  entJson['properties'] as Map? ?? {});
              props.forEach((k, v) {
                richProperties.add(EntityProperty(intId, k, v.toString()));
              });

              if (entJson['tags'] is List) {
                for (var t in entJson['tags']) {
                  if (t is String) {
                    richTags.add(EntityTag(intId, t, true));
                  } else if (t is Map) {
                    richTags.add(EntityTag(intId, t['name'] as String,
                        t['isPublic'] as bool? ?? true));
                  }
                }
              } else {
                richTags.add(EntityTag(intId, 'Zero-Copy', true));
              }

              final manifestPayloads = entJson['payloads'] ?? entJson['skins'];
              int activePayloadId = 0;
              if (manifestPayloads is List) {
                for (int pIdx = 0; pIdx < manifestPayloads.length; pIdx++) {
                  final s = manifestPayloads[pIdx];
                  final payloadId = pIdx + 1;
                  richPayloads.add(EntityPayload(
                    payloadId,
                    intId,
                    s['name'] as String? ?? 'Payload $payloadId',
                    s['assetPath'] as String? ?? 'none',
                    s['version'] as String? ?? '1.0',
                  ));
                  if (s['assetPath'] != null &&
                      s['assetPath'] != 'none' &&
                      activePayloadId == 0) {
                    activePayloadId = payloadId;
                  }
                }
              }

              richEntities.add(Entity(
                intId,
                packId,
                nameVal,
                categoryVal,
                activePayloadId,
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
            properties:
                richProperties.isNotEmpty ? richProperties : parsedProperties,
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
        properties: parsedProperties,
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
    final output = await compiler.compilePackage(manifest);

    final packId = manifest['pack_id'] as String? ?? 'bouncing_demo';

    File(
      '$workspace/examples/bouncing_demo/$packId.msp',
    ).writeAsBytesSync(output.mspBytes);
  }

  List<EntityPackage> getAllPackages() => List.unmodifiable(_registry);
  List<EntityPackage> getActivePackages() =>
      List.unmodifiable(_registry.where((p) => p.isLoaded));

  void setPackageLoaded(String id, {required bool loaded}) {
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
    _persistRegistry();
    notifyListeners();
  }

  void injectPackage(EntityPackage pack) {
    _registry.add(pack);
    _persistRegistry();
    notifyListeners();
  }

  void deletePackage(String id) {
    _registry.removeWhere((p) => p.id == id);
    _entities.removeWhere((e) => e.packageId == id);
    _persistRegistry();
    notifyListeners();
  }

  void updateEntityActivePayload(int entityId, int activePayloadId) {
    final index = _entities.indexWhere((e) => e.id == entityId);
    if (index != -1) {
      final e = _entities[index];
      _entities[index] = Entity(
        e.id,
        e.packageId,
        e.name,
        e.category,
        activePayloadId,
      );
      notifyListeners();
    }
  }

  /// Preloads skins/sprites for the active package into unmanaged C++ memory (ui.Image).
  Future<void> preloadSkins(EntityPackage pack) async {
    await disposeSkins();

    final packEntities =
        _entities.where((e) => e.packageId == pack.id).map((e) => e.id).toSet();
    final packPayloads =
        _payloads.where((p) => packEntities.contains(p.entityId));

    for (final payload in packPayloads) {
      final path = payload.assetPath;
      if (path.isEmpty || path == 'none') continue;
      if (skinImages.containsKey(path)) continue;

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
          skinImages[path] = frame.image;
        }
      } catch (_) {
        // Skip individual failed loads
      }
    }
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
              s.id,
              s.entityId,
              s.name,
              'packages/$packId/sprites/$filename',
              s.version,
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

    // 2. Build the stripped minimal manifest for malphas-cli
    final strippedManifest = {
      'pack_id': packId,
      'canvas_width': canvasWidth,
      'canvas_height': canvasHeight,
      'entities': entities.map((ent) {
        final entProps = properties
            .where((p) => p.entityId == ent.id)
            .fold<Map<String, String>>({}, (acc, p) {
          acc[p.key] = p.value;
          return acc;
        });
        return {
          'entity_id': ent.id,
          'properties': entProps,
        };
      }).toList(),
    };

    // 3. Compile using MalphasPackageCompiler
    final compiler = MalphasPackageCompiler();
    final output = await compiler.compilePackage(strippedManifest);

    // 4. Save files to packages/
    final mspFile = File('${packagesDir.path}/$packId.msp');
    final manifestFile = File('${packagesDir.path}/$packId.manifest.json');

    await mspFile.writeAsBytes(output.mspBytes);
    await manifestFile.writeAsString(jsonEncode(richManifest));

    // 5. Reload registry
    _initialized = false;
    await init();
  }
}
