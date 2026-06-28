import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
      _statusMessage = 'Generating Font Atlas and packaging resources...';
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

      final output = await compiler.compilePackage(manifest);

      final workspace = Directory.current.path;
      final packagesDir = Directory('$workspace/packages');
      if (!packagesDir.existsSync()) {
        packagesDir.createSync(recursive: true);
      }

      final outputPathMhp = '${packagesDir.path}/mecatron.mhp';
      final outputPathMsp = '${packagesDir.path}/mecatron.msp';

      await File(outputPathMhp).writeAsBytes(output.mhpBytes);
      await File(outputPathMsp).writeAsBytes(output.mspBytes);

      final bindings = MalphasBindings();

      // Pause the engine so entity setup cannot race the simulation tick.
      bindings.pauseEngine(true);
      try {
        // Load MHP first (this sets up static metadata, fonts, layouts, and embedded logic)
        final loadResMhp = bindings.loadPack(outputPathMhp);
        if (loadResMhp != 0) {
          throw Exception('load_resource_pack (MHP) failed with error $loadResMhp');
        }

        // Hot-swap with standalone logic (.msp) to demonstrate dynamic loading
        final loadResMsp = bindings.loadPack(outputPathMsp);
        if (loadResMsp != 0) {
          throw Exception('load_resource_pack (MSP) failed with error $loadResMsp');
        }

        // Configure entities through the Rust-gated API instead of writing the
        // Arena directly from Dart.
        bindings.setEntitiesCount(2);

        const text = "MALPHAS LIVE CORE";
        final textBytes = utf8.encode(text);
        // Write the text payload header (geometry + font size) followed by the
        // null-terminated string bytes into the Arena.
        bindings.writeArenaText(
          2048,
          300.0, // x
          400.0, // y
          48.0,  // font size
          Uint8List.fromList([...textBytes, 0]),
        );

        bindings.configureEntity(
          entityId: 0,
          commandType: 1,
          layer: 0,
          x: 100.0,
          y: 150.0,
          width: 180.0,
          height: 120.0,
          colorRgba: 0xFF00FFCC,
          speedX: 4.0,
          speedY: 3.0,
          minX: 20.0,
          maxX: 800.0,
          minY: 20.0,
          maxY: 860.0,
        );

        bindings.configureEntity(
          entityId: 1,
          commandType: 2,
          layer: 1,
          x: 300.0,
          y: 400.0,
          width: 48.0,
          height: 0.0,
          colorRgba: 0xFFE0DCD3,
          speedX: -3.5,
          speedY: 2.5,
          minX: 20.0,
          maxX: 450.0,
          minY: 20.0,
          maxY: 880.0,
          strOffset: 2048,
        );
      } finally {
        bindings.pauseEngine(false);
      }

      setState(() {
        _statusMessage = 'Successfully compiled and hot-swapped! Bytecode logic active.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pack compiled and hot-swapped successfully.'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Compilation error: $e';
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
        title: const Text('PACKAGE CONFIGURATION', style: TextStyle(fontFamily: 'Georgia', fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xffe0dcd3))),
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
              Text('BASIC ARCHIVE DATA', style: TextStyle(fontFamily: 'Arial', fontSize: 10, color: theme.primaryColor, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
              const SizedBox(height: 12),
              _buildField('PACKAGE NAME', 'Mecatron Geometry Core'),
              _buildField('GENERAL DESCRIPTION', 'Static structures mapped to raw native memory.'),

              Wrap(
                spacing: 12, runSpacing: 12,
                children: [
                  SizedBox(width: 150, child: _buildField('AUTHOR', 'Calin Rus')),
                  SizedBox(width: 120, child: _buildField('VERSION', 'v1.0.0')),
                ],
              ),
              const Divider(color: Colors.white10, height: 32),

              const Text('REGISTERED OBJECTS (INTEGRAL ECOSYSTEM):', style: TextStyle(fontFamily: 'Arial', fontSize: 10, color: Colors.white24, fontWeight: FontWeight.bold)),
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
                      : const Text('COMPILE & HOT-SWAP (ZERO-COPY)', style: TextStyle(fontFamily: 'Courier', color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
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
                  child: const Text('BACK TO MAIN PANEL', style: TextStyle(fontFamily: 'Courier', color: Color(0xffe0dcd3), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
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
