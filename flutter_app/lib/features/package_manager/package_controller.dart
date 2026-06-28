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
    // Simula la llamada a los directorios raíz externos del proyecto (../packages/ y ../motors/)
  }

  List<MalphasPackage> getAllPackages() => _registry;
  List<MalphasPackage> getActivePackages() => _registry.where((p) => p.isLoaded).toList();
  void injectPackage(MalphasPackage pack) => _registry.add(pack);
  void deletePackage(String id) => _registry.removeWhere((p) => p.id == id);
}
