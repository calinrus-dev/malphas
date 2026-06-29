import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'models.dart';
import '../../core/compiler/package_compiler.dart';
import '../../core/services/app_state_persistence_service.dart';

class PackageController extends ChangeNotifier {
  static final PackageController _instance = PackageController._internal();
  factory PackageController() => _instance;
  PackageController._internal();

  static final Map<String, ui.Image> skinImages = {};

  final List<MalphasPackage> _registry = [];
  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  bool _initialized = false;
  String? _workspaceRootOverride;

  /// Clears the in-memory registry and resets the initialization flag.
  /// Intended for tests; do not call in production.
  void reset() {
    _registry.clear();
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
      final workspace = resolveWorkspaceRoot();
      final packagesDir = Directory('$workspace/packages');
      if (!packagesDir.existsSync()) {
        packagesDir.createSync(recursive: true);
      }

      // If the bouncing_demo manifest exists but the compiled package does not,
      // compile it on demand using the native CLI.
      await _ensureBouncingDemoCompiled(workspace);

      // Restore previously loaded package ids so `isLoaded` state survives
      // across app launches.
      final persistedIds = _persistence.loadRegistryIds();

      // Scan examples/**/*.mhp
      final examplesDir = Directory('$workspace/examples');
      if (examplesDir.existsSync()) {
        for (final entity in examplesDir.listSync(recursive: true)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.mhp')) {
            final pack = _parseMhpPackage(entity);
            if (pack != null) {
              _registry.removeWhere((p) => p.id == pack.id);
              if (persistedIds.contains(pack.id)) {
                pack.isLoaded = true;
              }
              _registry.add(pack);
            }
          }
        }
      }

      // Scan packages/*.mhp
      for (final file in packagesDir.listSync()) {
        if (file is File && file.path.toLowerCase().endsWith('.mhp')) {
          final pack = _parseMhpPackage(file);
          if (pack != null) {
            _registry.removeWhere((p) => p.id == pack.id);
            if (persistedIds.contains(pack.id)) {
              pack.isLoaded = true;
            }
            _registry.add(pack);
          }
        }
      }

      notifyListeners();
      // Only mark initialized after all work completes so a failure leaves the
      // controller in a retryable state.
      _initialized = true;
    } catch (e) {
      _initialized = false;
      rethrow;
    }
  }

  void _persistRegistry() {
    _persistence.saveRegistryIds(
      _registry.where((p) => p.isLoaded).map((p) => p.id).toList(),
    );
  }

  /// Parses a valid MLPH binary and returns a [MalphasPackage] using the same
  /// header layout the existing scanner relied on.
  MalphasPackage? _parseMhpPackage(File file) {
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.length < 112) return null;

      // Verify magic header: 'MLPH'
      if (bytes[0] != 0x4D ||
          bytes[1] != 0x4C ||
          bytes[2] != 0x50 ||
          bytes[3] != 0x48) {
        return null;
      }

      final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
      final version = data.getUint32(4, Endian.little);

      // Read pack_id (16 bytes ASCII at offset 48)
      final packIdBytes = bytes.sublist(48, 64);
      final packId = utf8.decode(packIdBytes.takeWhile((b) => b != 0).toList());

      final objectsCount = data.getUint32(80, Endian.little);
      final objectsTableOffset = data.getUint32(76, Endian.little);

      final List<MalphasObject> parsedObjects = [];
      for (int i = 0; i < objectsCount; i++) {
        final entryOffset = objectsTableOffset + (i * 32);
        if (entryOffset + 32 > bytes.length) break;

        final objId = data.getUint32(entryOffset, Endian.little);

        parsedObjects.add(
          MalphasObject(
            id: 'vox_obj_$objId',
            name: 'Voxel_Object_$objId',
            category: 'Compiled Archetype',
            properties: {'ID': '$objId'},
            tags: [const MalphasTag(name: 'Zero-Copy', isPublic: true)],
            skins: [],
          ),
        );
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
          final name = manifestJson['name'] as String? ?? 'MHP Pack ($packId)';
          final manifestVersion =
              manifestJson['version'] as String? ?? 'v$version.0.0';
          final author =
              manifestJson['author'] as String? ?? 'Compiled Artifact';
          final description = manifestJson['description'] as String? ??
              'Zero-copy binary structure with aligned headers.';

          final List<MalphasObject> richObjects = [];
          if (manifestJson['objects'] is List) {
            for (var objJson in manifestJson['objects']) {
              final idVal = objJson['object_id'] ?? objJson['id'];
              final nameVal = objJson['name'] as String? ?? 'Object $idVal';
              final categoryVal =
                  objJson['category'] as String? ?? 'Compiled Archetype';
              final props = Map<String, dynamic>.from(
                  objJson['properties'] as Map? ?? {});
              final propsStr = props.map((k, v) => MapEntry(k, v.toString()));

              final tagsList = <MalphasTag>[];
              if (objJson['tags'] is List) {
                for (var t in objJson['tags']) {
                  if (t is String) {
                    tagsList.add(MalphasTag(name: t, isPublic: true));
                  } else if (t is Map) {
                    tagsList.add(MalphasTag(
                        name: t['name'] as String,
                        isPublic: t['isPublic'] as bool? ?? true));
                  }
                }
              } else {
                tagsList
                    .add(const MalphasTag(name: 'Zero-Copy', isPublic: true));
              }

              final skinsList = <MalphasSkin>[];
              if (objJson['skins'] is List) {
                for (var s in objJson['skins']) {
                  skinsList.add(MalphasSkin(
                    id: s['id'] as String? ?? 'none',
                    name: s['name'] as String? ?? 'None',
                    assetPath: s['assetPath'] as String? ?? 'none',
                    version: s['version'] as String? ?? '1.0',
                  ));
                }
              }

              richObjects.add(MalphasObject(
                id: idVal.toString(),
                name: nameVal,
                category: categoryVal,
                properties: propsStr,
                tags: tagsList,
                skins: skinsList,
              ));
            }
          }

          return MalphasPackage(
            id: packId,
            name: name,
            version: manifestVersion,
            author: author,
            description: description,
            objects: richObjects.isNotEmpty ? richObjects : parsedObjects,
          );
        } catch (_) {
          // Fallback if manifest is malformed
        }
      }

      return MalphasPackage(
        id: packId,
        name: 'MHP Pack ($packId)',
        version: 'v$version.0.0',
        author: 'Compiled Artifact',
        description: 'Zero-copy binary structure with aligned headers.',
        objects: parsedObjects,
      );
    } catch (e) {
      // Silent skip for individual malformed files.
      return null;
    }
  }

  /// Compiles `examples/bouncing_demo/manifest.json` if the manifest is present
  /// but its `.mhp` artifact is missing. Guards against a missing CLI and never
  /// fails silently.
  Future<void> _ensureBouncingDemoCompiled(String workspace) async {
    final manifestFile = File(
      '$workspace/examples/bouncing_demo/manifest.json',
    );
    final mhpFile = File('$workspace/examples/bouncing_demo/bouncing_demo.mhp');

    if (!manifestFile.existsSync() || mhpFile.existsSync()) {
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
    final mspFile = File('$workspace/examples/bouncing_demo/$packId.msp');

    File(
      '$workspace/examples/bouncing_demo/$packId.mhp',
    ).writeAsBytesSync(output.mhpBytes);
    mspFile.writeAsBytesSync(output.mspBytes);
  }

  List<MalphasPackage> getAllPackages() => List.unmodifiable(_registry);
  List<MalphasPackage> getActivePackages() =>
      List.unmodifiable(_registry.where((p) => p.isLoaded));

  void setPackageLoaded(String id, {required bool loaded}) {
    final index = _registry.indexWhere((p) => p.id == id);
    if (index == -1) return;
    _registry[index].isLoaded = loaded;
    _persistRegistry();
    notifyListeners();
  }

  void injectPackage(MalphasPackage pack) {
    _registry.add(pack);
    _persistRegistry();
    notifyListeners();
  }

  void deletePackage(String id) {
    _registry.removeWhere((p) => p.id == id);
    _persistRegistry();
    notifyListeners();
  }

  /// Preloads skins/sprites for the active package into unmanaged C++ memory (ui.Image).
  /// Safely disposes and clears any previously loaded skins first to prevent memory leaks.
  Future<void> preloadSkins(MalphasPackage pack) async {
    await disposeSkins();

    for (final obj in pack.objects) {
      for (final skin in obj.skins) {
        final path = skin.assetPath;
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
    required List<MalphasObject> objects,
  }) async {
    final workspace = resolveWorkspaceRoot();
    final packagesDir = Directory('$workspace/packages');
    if (!packagesDir.existsSync()) {
      packagesDir.createSync(recursive: true);
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
      'objects': objects
          .map((obj) => {
                'object_id': int.tryParse(obj.id) ?? 1,
                'name': obj.name,
                'category': obj.category,
                'tags': obj.tags
                    .map((t) => {'name': t.name, 'isPublic': t.isPublic})
                    .toList(),
                'skins': obj.skins.map((s) => s.toJson()).toList(),
                'properties': obj.properties,
              })
          .toList(),
    };

    // 2. Build the stripped minimal manifest for malphas-cli
    final strippedManifest = {
      'pack_id': packId,
      'canvas_width': canvasWidth,
      'canvas_height': canvasHeight,
      'objects': objects
          .map((obj) => {
                'object_id': int.tryParse(obj.id) ?? 1,
                'properties': obj.properties,
              })
          .toList(),
    };

    // 3. Compile using MalphasPackageCompiler
    final compiler = MalphasPackageCompiler();
    final output = await compiler.compilePackage(strippedManifest);

    // 4. Save files to packages/
    final mhpFile = File('${packagesDir.path}/$packId.mhp');
    final mspFile = File('${packagesDir.path}/$packId.msp');
    final manifestFile = File('${packagesDir.path}/$packId.manifest.json');

    await mhpFile.writeAsBytes(output.mhpBytes);
    await mspFile.writeAsBytes(output.mspBytes);
    await manifestFile.writeAsString(jsonEncode(richManifest));

    // 5. Reload registry
    _initialized = false;
    await init();
  }
}
