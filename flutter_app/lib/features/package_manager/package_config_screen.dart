import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ffi' as dffi;
import 'package:flutter/material.dart';
import '../../core/compiler/package_compiler.dart';
import '../../core/ffi/malphas_bindings.dart';

class PackageConfigScreen extends StatefulWidget {
  const PackageConfigScreen({super.key});

  @override
  State<PackageConfigScreen> createState() => _PackageConfigScreenState();
}

class _PackageConfigScreenState extends State<PackageConfigScreen> {
  final List<String> _registeredObjects = ['Block_Primitive_Cube', 'Block_Curved_Sphere', 'Custom_Dock_Layout', 'Buffer_Static_Fluid'];
  bool _isCompiling = false;
  String _statusMessage = '';

  Future<void> _compileAndLoadPack() async {
    setState(() {
      _isCompiling = true;
      _statusMessage = 'Generando Font Atlas y empaquetando recursos...';
    });

    try {
      final compiler = MalphasPackageCompiler();
      final manifest = {
        "pack_id": "pack_custom_01",
        "pack_name": "Mecatron Core System",
        "version": "1.0.0",
        "target_canvas": {"width": 1000, "height": 1000},
        "objects": [
          {
            "object_id": 42,
            "name": "bouncing_cube",
            "properties": {
              "max_speed": "15.5",
              "collision_type": "bounding_box"
            }
          },
          {
            "object_id": 43,
            "name": "bouncing_text",
            "properties": {
              "font_size": "48.0",
              "color": "white"
            }
          }
        ]
      };

      final packBytes = await compiler.compilePackage(manifest);

      final workspace = Directory.current.path;
      final packagesDir = Directory('$workspace/packages');
      if (!packagesDir.existsSync()) {
        packagesDir.createSync(recursive: true);
      }

      final outputPath = '${packagesDir.path}/mecatron.malphas';
      final file = File(outputPath);
      await file.writeAsBytes(packBytes);

      final bindings = MalphasBindings();
      final loadRes = bindings.loadPack(outputPath);
      if (loadRes != 0) {
        throw Exception('load_resource_pack falló con error $loadRes');
      }

      final arena = bindings.arena;
      if (arena != dffi.nullptr) {
        final arenaBytes = arena.cast<dffi.Uint8>().asTypedList(8 * 1024 * 1024);
        final byteData = ByteData.view(arenaBytes.buffer, arenaBytes.offsetInBytes);

        arena.cast<dffi.Uint32>()[4] = 2;

        const text = "MALPHAS LIVE CORE";
        final textBytes = utf8.encode(text);
        for (int i = 0; i < textBytes.length; i++) {
          arenaBytes[2048 + i] = textBytes[i];
        }
        arenaBytes[2048 + textBytes.length] = 0;

        final e0 = 32;
        arenaBytes[e0 + 0] = 1; 
        arenaBytes[e0 + 1] = 0; 
        byteData.setFloat32(e0 + 4, 100.0, Endian.little); 
        byteData.setFloat32(e0 + 8, 150.0, Endian.little); 
        byteData.setFloat32(e0 + 12, 180.0, Endian.little); 
        byteData.setFloat32(e0 + 16, 120.0, Endian.little); 
        byteData.setUint32(e0 + 20, 0xFF00FFCC, Endian.little); 
        byteData.setFloat32(e0 + 24, 4.0, Endian.little); 
        byteData.setFloat32(e0 + 28, 3.0, Endian.little); 
        byteData.setFloat32(e0 + 32, 20.0, Endian.little); 
        byteData.setFloat32(e0 + 36, 800.0, Endian.little); 
        byteData.setFloat32(e0 + 40, 20.0, Endian.little); 
        byteData.setFloat32(e0 + 44, 860.0, Endian.little); 

        final e1 = 96;
        arenaBytes[e1 + 0] = 2; 
        arenaBytes[e1 + 1] = 1; 
        byteData.setFloat32(e1 + 4, 300.0, Endian.little); 
        byteData.setFloat32(e1 + 8, 400.0, Endian.little); 
        byteData.setFloat32(e1 + 12, 48.0, Endian.little); 
        byteData.setFloat32(e1 + 16, 0.0, Endian.little);
        byteData.setUint32(e1 + 20, 0xFFE0DCD3, Endian.little); 
        byteData.setFloat32(e1 + 24, -3.5, Endian.little); 
        byteData.setFloat32(e1 + 28, 2.5, Endian.little); 
        byteData.setFloat32(e1 + 32, 20.0, Endian.little); 
        byteData.setFloat32(e1 + 36, 450.0, Endian.little); 
        byteData.setFloat32(e1 + 40, 20.0, Endian.little); 
        byteData.setFloat32(e1 + 44, 880.0, Endian.little); 
        byteData.setUint32(e1 + 48, 2048, Endian.little); 
      }

      setState(() {
        _statusMessage = '¡Compilado y acoplado con éxito! Lógica bytecode activa.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pack compilado y cargado en caliente.'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error en compilación: $e';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() {
        _isCompiling = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('CONFIGURACIÓN DE PAQUETE', style: TextStyle(fontFamily: 'Georgia', fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xffe0dcd3))),
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios, size: 14), onPressed: () => Navigator.pop(context)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('DATOS BÁSICOS DEL ARCHIVO', style: TextStyle(fontFamily: 'Arial', fontSize: 10, color: theme.primaryColor, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
              const SizedBox(height: 12),
              _buildField('NOMBRE DEL PAQUETE', 'Mecatron Geometry Core'),
              _buildField('DESCRIPCIÓN GENERAL', 'Estructuras estáticas mapeadas en la raíz del metal nativo.'),
              
              Wrap(
                spacing: 12, runSpacing: 12,
                children: [
                  SizedBox(width: 150, child: _buildField('AUTOR', 'Calin Rus')),
                  SizedBox(width: 120, child: _buildField('VERSIÓN', 'v1.0.0')),
                ],
              ),
              const Divider(color: Colors.white10, height: 32),
              
              const Text('OBJETOS REGISTRADOS (ECOSISTEMA INTEGRAL):', style: TextStyle(fontFamily: 'Arial', fontSize: 10, color: Colors.white24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _registeredObjects.map((obj) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: theme.cardColor, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xff1b1b1b))),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.extension_outlined, size: 14, color: Colors.white30),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(obj, style: const TextStyle(fontFamily: 'Courier', fontSize: 11, color: Color(0xffe0dcd3), fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                )).toList(),
              ),
              const SizedBox(height: 32),
              
              if (_statusMessage.isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xff0d0d0d),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xff1b1b1b)),
                  ),
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(fontFamily: 'Courier', fontSize: 10, color: Color(0xffe0dcd3)),
                  ),
                ),
              ],

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  onPressed: _isCompiling ? null : _compileAndLoadPack,
                  child: _isCompiling
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                      : const Text('COMPILAR Y CARGAR EN CALIENTE (ZERO-COPY)', style: TextStyle(fontFamily: 'Courier', color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xff1b1b1b)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('VOLVER AL PANEL PRINCIPAL', style: TextStyle(fontFamily: 'Courier', color: Color(0xffe0dcd3), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      width: double.infinity,
      decoration: BoxDecoration(color: const Color(0xff0d0d0d), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xff141414))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontFamily: 'Arial', fontSize: 8, color: Colors.white24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontFamily: 'Arial', fontSize: 13, color: Colors.white)),
        ],
      ),
    );
  }
}
