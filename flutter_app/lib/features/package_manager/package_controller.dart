import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'models.dart';

class PackageController {
  static final PackageController _instance = PackageController._internal();
  factory PackageController() => _instance;
  PackageController._internal();

  final List<MalphasPackage> _registry = [
    MalphasPackage(
      id: 'pack_core_geometry',
      name: 'Standard Geometry Pack',
      version: 'v1.0.0',
      author: 'Malphas Architecture',
      description: 'Librería elemental de estructuras rígidas, bloques de datos vectoriales y mapas de texturas directas.',
      objects: [
        MalphasObject(
          id: 'vox_cube_01',
          name: 'Block_Primitive_Cube',
          category: 'Solid Voxel',
          properties: {'Friction': '0.6', 'Mass': '1.5', 'LightEmission': '0'},
          tags: [
            const MalphasTag(name: 'Solid', isPublic: true),
            const MalphasTag(name: 'Core', isPublic: true),
            const MalphasTag(name: 'Voxel', isPublic: true),
            const MalphasTag(name: 'Static', isPublic: true),
          ],
          skins: [
            const MalphasSkin(id: 'sk_cube_dark', name: 'Anthracite Matte', assetPath: '../packages/assets/dark_cube.raw', version: '1.0'),
            const MalphasSkin(id: 'sk_cube_wire', name: 'Neon Wireframe', assetPath: '../packages/assets/wire_cube.raw', version: '1.2'),
          ],
        ),
        MalphasObject(
          id: 'vox_sphere_02',
          name: 'Block_Curved_Sphere_Mesh_Unit',
          category: 'Complex Geometry',
          properties: {'Radius': '0.5', 'Segments': '32', 'Tessellation': 'None'},
          tags: [
            const MalphasTag(name: 'Solid', isPublic: true),
            const MalphasTag(name: 'Complex', isPublic: true),
            const MalphasTag(name: 'Static', isPublic: true),
          ],
          skins: [
            const MalphasSkin(id: 'sk_sphere_std', name: 'Standard Layer', assetPath: '../packages/assets/sphere.raw', version: '1.0'),
          ],
        )
      ],
    ),
  ];

  Future<void> init() async {
    final workspace = Directory.current.path;
    final packagesDir = Directory('$workspace/packages');
    if (!packagesDir.existsSync()) {
      packagesDir.createSync(recursive: true);
    }

    final List<FileSystemEntity> files = packagesDir.listSync();
    for (final file in files) {
      if (file is File && file.path.endsWith('.mhp')) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.length < 112) continue;
          
          // Verify magic header: 'MLPH'
          if (bytes[0] != 0x4D || bytes[1] != 0x4C || bytes[2] != 0x50 || bytes[3] != 0x48) {
            continue;
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

          final newPack = MalphasPackage(
            id: packId,
            name: 'MHP Pack ($packId)',
            version: 'v$version.0.0',
            author: 'Compiled Artifact',
            description: 'Estructura binaria mapeada en zero-copy con cabeceras alineadas.',
            objects: parsedObjects,
          )..isLoaded = true;

          // Replace or add to registry
          _registry.removeWhere((p) => p.id == packId);
          _registry.add(newPack);
        } catch (e) {
          // Silent skip
        }
      }
    }
  }

  List<MalphasPackage> getAllPackages() => _registry;
  List<MalphasPackage> getActivePackages() => _registry.where((p) => p.isLoaded).toList();
  void injectPackage(MalphasPackage pack) => _registry.add(pack);
  void deletePackage(String id) => _registry.removeWhere((p) => p.id == id);
}
