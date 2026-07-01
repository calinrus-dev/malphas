import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/compiler/package_compiler.dart';
import '../../core/services/app_state_persistence_service.dart';
import '../../core/theme/theme.dart';
import '../../core/ui_primitives/malphas_widgets.dart';
import '../../core/ui_primitives/primitive_canvas.dart';
import '../engine_manager/engine_controller.dart';
import '../engine_manager/engine_manager_screen.dart';
import '../engine_manager/runtime_hud.dart';
import '../engine_manager/telemetry_overlay.dart';
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
  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  final GlobalKey _canvasKey = GlobalKey();

  bool _isInstalling = false;
  bool _telemetryOverlayEnabled = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _engineController.addListener(_onEngineChanged);
    _loadTelemetrySettings();
    _engineController.loadEnvironment(widget.environment, this);
  }

  Future<void> _loadTelemetrySettings() async {
    final enabled = await _persistence.loadTelemetryOverlayEnabled();
    if (mounted) {
      setState(() => _telemetryOverlayEnabled = enabled);
    }
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

  void _handleCanvasInput(int eventType, Offset localPosition) {
    final renderBox =
        _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    if (size.width <= 0 || size.height <= 0) return;

    final x = localPosition.dx / size.width * PrimitiveCanvas.logicalWidth;
    final y = localPosition.dy / size.height * PrimitiveCanvas.logicalHeight;
    _engineController.bindings.processInputEvent(eventType, x, y);

    if (eventType == 0) {
      _selectEntityAt(Offset(x, y));
    }
  }

  void _selectEntityAt(Offset logicalPosition) {
    final snapshot = _engineController.bindings.getFrontBufferSnapshot();
    final commands = snapshot.commands;
    final count = snapshot.count;
    if (commands == ffi.nullptr || count <= 0) return;

    for (int i = 0; i < count; i++) {
      final cmd = (commands + i).ref;
      final rect = Rect.fromLTWH(cmd.x, cmd.y, cmd.width, cmd.height);
      if (rect.contains(logicalPosition)) {
        _showSnackBar('Selected entity ${cmd.entityId}');
        return;
      }
    }
  }

  ui.Image? _resolvePayloadImage(int payloadId) {
    final payload = _packageController.store.getPayload(payloadId);
    if (payload == null) return null;
    final path = payload.assetPath;
    if (path.isEmpty || path == 'none') return null;
    return PackageController.skinImages[path];
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
        backgroundColor: MalphasTheme.slate,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: MalphasTheme.accent),
        ),
        content: Text(
          message,
          style: const TextStyle(
            fontFamily: 'Courier',
            color: MalphasTheme.accent,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MalphasTheme.ink,
      appBar: AppBar(
        title: Text(
          widget.environment.name.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Georgia',
            fontSize: 16,
            color: MalphasTheme.bone,
          ),
        ),
        backgroundColor: MalphasTheme.ink,
        elevation: 0,
        leading: MalphasIconButton(
          icon: Icons.arrow_back_ios,
          tooltip: 'Back to hub',
          size: 14,
          onPressed: () => Navigator.of(context).pop(),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: MalphasTheme.bone,
          labelColor: MalphasTheme.bone,
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
        backgroundColor: MalphasTheme.slate,
        foregroundColor: MalphasTheme.accent,
        icon: _isInstalling
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: MalphasTheme.accent,
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
      return const MalphasLoadingIndicator(message: 'STARTING ENGINE');
    }
    if (!_engineController.isRunning) {
      return MalphasEmptyState(
        icon: Icons.memory_outlined,
        title: 'ENGINE IDLE',
        subtitle:
            'The native runtime is not active. Install a package or tap an Environment card to start it.',
        actionLabel: 'INSTALL / UPDATE',
        onAction: _isInstalling ? null : _installOrUpdateEnvironment,
      );
    }
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => _handleCanvasInput(0, details.localPosition),
          onPanUpdate: (details) =>
              _handleCanvasInput(1, details.localPosition),
          onPanEnd: (_) => _handleCanvasInput(2, Offset.zero),
          child: PrimitiveCanvas(
            key: _canvasKey,
            bindings: _engineController.bindings,
            repaint: _engineController.frameNotifier,
            imageResolver: _resolvePayloadImage,
          ),
        ),
        const Positioned(
          top: 16,
          right: 16,
          child: RuntimeHud(),
        ),
        if (_telemetryOverlayEnabled)
          const Positioned(
            top: 80,
            right: 16,
            child: TelemetryOverlay(),
          ),
      ],
    );
  }

  Widget _buildErrorOverlay(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: MalphasCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.redAccent, size: 32),
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
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: MalphasTheme.accent,
                  foregroundColor: MalphasTheme.ink,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: _installOrUpdateEnvironment,
                child: const Text(
                  'RETRY',
                  style: TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
