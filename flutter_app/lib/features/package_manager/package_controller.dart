import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'models.dart';
import '../../core/compiler/package_compiler.dart';
import '../../core/services/app_state_persistence_service.dart';

class PackageController extends ChangeNotifier {
  static final PackageController _instance = PackageController._internal();
  factory PackageController() => _instance;
  PackageController._internal();

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
    final manifestFile =
        File('$workspace/examples/bouncing_demo/manifest.json');
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

    File('$workspace/examples/bouncing_demo/$packId.mhp')
        .writeAsBytesSync(output.mhpBytes);
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
}
