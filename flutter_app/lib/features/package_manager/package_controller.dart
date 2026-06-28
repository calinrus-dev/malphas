import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'models.dart';
import '../../core/compiler/package_compiler.dart';

class PackageController {
  static final PackageController _instance = PackageController._internal();
  factory PackageController() => _instance;
  PackageController._internal();

  final List<MalphasPackage> _registry = [];

  Future<void> init() async {
    final workspace = Directory.current.path;
    final packagesDir = Directory('$workspace/packages');
    if (!packagesDir.existsSync()) {
      packagesDir.createSync(recursive: true);
    }

    // If the bouncing_demo manifest exists but the compiled package does not,
    // compile it on demand using the native CLI.
    await _ensureBouncingDemoCompiled(workspace);

    // Scan examples/**/*.mhp
    final examplesDir = Directory('$workspace/examples');
    if (examplesDir.existsSync()) {
      for (final entity in examplesDir.listSync(recursive: true)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.mhp')) {
          final pack = _parseMhpPackage(entity);
          if (pack != null) {
            _registry.removeWhere((p) => p.id == pack.id);
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
          _registry.add(pack);
        }
      }
    }
  }

  /// Parses a valid MLPH binary and returns a [MalphasPackage] using the same
  /// header layout the existing scanner relied on.
  MalphasPackage? _parseMhpPackage(File file) {
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.length < 112) return null;

      // Verify magic header: 'MLPH'
      if (bytes[0] != 0x4D || bytes[1] != 0x4C || bytes[2] != 0x50 || bytes[3] != 0x48) {
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
        description: 'Estructura binaria mapeada en zero-copy con cabeceras alineadas.',
        objects: parsedObjects,
      )..isLoaded = true;
    } catch (e) {
      // Silent skip for individual malformed files.
      return null;
    }
  }

  /// Compiles `examples/bouncing_demo/manifest.json` if the manifest is present
  /// but its `.mhp` artifact is missing. Guards against a missing CLI and never
  /// fails silently.
  Future<void> _ensureBouncingDemoCompiled(String workspace) async {
    final manifestFile = File('$workspace/examples/bouncing_demo/manifest.json');
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

  List<MalphasPackage> getAllPackages() => _registry;
  List<MalphasPackage> getActivePackages() => _registry.where((p) => p.isLoaded).toList();
  void injectPackage(MalphasPackage pack) => _registry.add(pack);
  void deletePackage(String id) => _registry.removeWhere((p) => p.id == id);
}
