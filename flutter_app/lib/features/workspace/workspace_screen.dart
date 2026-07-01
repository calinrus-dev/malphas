import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/compiler/package_compiler.dart';
import '../../core/ui_primitives/primitive_canvas.dart';
import '../engine_manager/engine_controller.dart';
import '../engine_manager/engine_manager_screen.dart';
import '../engine_manager/runtime_hud.dart';
import '../hub/environment_model.dart';
import '../package_manager/package_controller.dart';
import '../package_manager/package_manager_screen.dart';

class WorkspaceScreen extends StatefulWidget {
  final MalphasEnvironment environment;

  const WorkspaceScreen({super.key, required this.environment});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final EngineController _engineController = EngineController();
  final PackageController _packageController = PackageController();

  bool _isInstalling = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _engineController.addListener(_onEngineChanged);
    _engineController.loadEnvironment(widget.environment, this);
  }

  @override
  void dispose() {
    _engineController.removeListener(_onEngineChanged);
    _engineController.unloadEnvironment();
    _tabController.dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _installOrUpdateEnvironment() async {
    setState(() {
      _isInstalling = true;
    });

    try {
      final compiler = MalphasPackageCompiler();
      final packIds = widget.environment.packageIds.isNotEmpty
          ? widget.environment.packageIds
          : const ['bouncing_demo'];

      for (final packId in packIds) {
        final manifestPath = _resolveManifestPath(packId);
        if (manifestPath == null) continue;

        final manifestJson = jsonDecode(File(manifestPath).readAsStringSync())
            as Map<String, dynamic>;
        await compiler.compilePackage(manifestJson);

        final mspPath = _resolveMspPath(packId);
        if (mspPath != null) {
          _engineController.reloadMsp(packId);
        }
      }

      _showSnackBar('Environment installed / updated');
    } catch (e) {
      _showSnackBar('UPDATE ERROR: $e');
    } finally {
      setState(() => _isInstalling = false);
    }
  }

  String? _resolveMspPath(String packId) {
    final workspace = _packageController.resolveWorkspaceRoot();
    final candidates = [
      '$workspace/examples/$packId/$packId.msp',
      '$workspace/packages/$packId.msp',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String? _resolveManifestPath(String packId) {
    final workspace = _packageController.resolveWorkspaceRoot();
    final candidates = [
      '$workspace/examples/$packId/manifest.json',
      '$workspace/packages/$packId.manifest.json',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xff0d0d0d),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xff00ffcc)),
        ),
        content: Text(
          message,
          style: const TextStyle(
            fontFamily: 'Courier',
            color: Color(0xff00ffcc),
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.environment.name.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Georgia',
            fontSize: 16,
            color: Color(0xffe0dcd3),
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios,
              size: 14, color: Color(0xffe0dcd3)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xffe0dcd3),
          labelColor: const Color(0xffe0dcd3),
          unselectedLabelColor: Colors.white38,
          labelStyle: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
          tabs: const [
            Tab(text: 'CANVAS'),
            Tab(text: 'PACKS'),
            Tab(text: 'ENGINES'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildCanvasTab(),
          PackageManagerPanel(environment: widget.environment),
          const EngineManagerPanel(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xff0d0d0d),
        foregroundColor: const Color(0xff00ffcc),
        icon: _isInstalling
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xff00ffcc),
                ),
              )
            : const Icon(Icons.install_desktop, size: 18),
        label: Text(
          _isInstalling ? 'INSTALLING...' : 'INSTALL / UPDATE ENVIRONMENT',
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        onPressed: _isInstalling ? null : _installOrUpdateEnvironment,
      ),
    );
  }

  Widget _buildCanvasTab() {
    final error = _engineController.errorMessage;
    if (error != null) {
      return _buildErrorOverlay(error);
    }
    if (_engineController.isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xffe0dcd3)),
      );
    }
    if (!_engineController.isRunning) {
      return const Center(
        child: Text(
          'Engine is not running.',
          style: TextStyle(
            fontFamily: 'Courier',
            color: Colors.white38,
            fontSize: 12,
          ),
        ),
      );
    }
    return Stack(
      children: [
        PrimitiveCanvas(
          bindings: _engineController.bindings,
          repaint: _engineController.frameNotifier,
        ),
        const Positioned(
          top: 16,
          right: 16,
          child: RuntimeHud(),
        ),
      ],
    );
  }

  Widget _buildErrorOverlay(String message) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xff0d0d0d),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xff1b1b1b)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 32),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Courier',
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
