import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/ffi/malphas_bindings.dart';
import '../../core/services/entity_bootstrap_service.dart';
import '../../core/ui_primitives/primitive_canvas.dart';
import '../hub/environment_model.dart';
import '../package_manager/package_manager_screen.dart';
import '../package_manager/package_controller.dart';
import '../package_manager/models.dart';
import '../engine_manager/engine_manager_screen.dart';

class WorkspaceScreen extends StatefulWidget {
  final MalphasEnvironment environment;
  const WorkspaceScreen({super.key, required this.environment});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  late final MalphasBindings bindings;
  late final Ticker _ticker;
  int _currentViewIndex = 0;
  late final EntityBootstrapService _bootstrap;
  String? _autoLoadError;

  @override
  void initState() {
    super.initState();
    bindings = MalphasBindings();
    _bootstrap = EntityBootstrapService(bindings);

    _ticker = createTicker((elapsed) {
      // Single-clock sync: one engine pulse per vsync from Flutter's Ticker.
      bindings.tick();
      // Repaint-driven visual refresh without high-frequency global re-layouts (Rule 5).
    });
    _ticker.start();

    _autoLoadPackages();
  }

  /// Loads the environment's first package (or the default bouncing demo) into
  /// the native core, configures the entities, and starts the simulation pulse.
  Future<void> _autoLoadPackages() async {
    try {
      await PackageController().init();

      final packageIds = widget.environment.packageIds;
      final targetPackId =
          packageIds.isNotEmpty ? packageIds.first : 'bouncing_demo';

      final mhpFile = _resolveMhpFile(targetPackId);
      if (mhpFile == null || !mhpFile.existsSync()) {
        _showAutoLoadError('No compiled package found for "$targetPackId".');
        return;
      }

      if (!bindings.isNativeAvailable) {
        _showAutoLoadError('Native core is not available in this session.');
        return;
      }

      bindings.pauseEngine(true);
      try {
        final loadResult = bindings.loadPack(mhpFile.path);
        if (loadResult != 0) {
          _showAutoLoadError('loadPack failed with code $loadResult.');
          return;
        }

        final registry = PackageController();
        final pack = registry.getAllPackages().firstWhere(
              (p) => p.id == targetPackId,
              orElse: () => MalphasPackage(
                id: targetPackId,
                name: targetPackId,
                version: '1.0.0',
                author: 'Unknown',
                description: '',
                objects: [],
              ),
            );

        if (pack.objects.isNotEmpty) {
          _bootstrap.configurePackageScene(pack);
        } else {
          _bootstrap.configureDefaultScene();
        }

        registry.preloadSkins(pack).then((_) {
          if (mounted) setState(() {});
        });
      } finally {
        bindings.pauseEngine(false);
      }
    } catch (e, stack) {
      debugPrint('Workspace auto-load failed: $e');
      debugPrint(stack.toString());
      _showAutoLoadError('Auto-load failed: $e');
    }
  }

  /// Searches the compiled package in `examples/` and `packages/`.
  File? _resolveMhpFile(String packId) {
    final workspace = PackageController().resolveWorkspaceRoot();
    final candidates = [
      File('$workspace/examples/bouncing_demo/$packId.mhp'),
      File('$workspace/examples/$packId/$packId.mhp'),
      File('$workspace/packages/$packId.mhp'),
      File('$workspace/examples/$packId.mhp'),
    ];
    for (final candidate in candidates) {
      if (candidate.existsSync()) return candidate;
    }
    return null;
  }

  void _showAutoLoadError(String message) {
    debugPrint('Workspace auto-load: $message');
    if (!mounted) return;
    setState(() {
      _autoLoadError = message;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xff0d0d0d),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xff1b1b1b)),
          ),
          content: Text(
            'AUTO-LOAD ERROR: $message',
            style: const TextStyle(
              fontFamily: 'Courier',
              fontSize: 11,
              color: Color(0xffe0dcd3),
            ),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    // MalphasBindings is a process-wide singleton; do not dispose it here.
    // Shared-memory teardown is handled at app shutdown.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: IndexedStack(
              index: _currentViewIndex,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      onTapDown: (details) {
                        final localPos = details.localPosition;
                        final double width = constraints.maxWidth;
                        final double height = constraints.maxHeight;
                        final double scale =
                            (width < height ? width : height) / 1000.0;
                        final double offsetX = (width - (1000.0 * scale)) / 2.0;
                        final double offsetY =
                            (height - (1000.0 * scale)) / 2.0;

                        final double logicalX = (localPos.dx - offsetX) / scale;
                        final double logicalY = (localPos.dy - offsetY) / scale;
                        bindings.processInputEvent(0, logicalX, logicalY);
                      },
                      child: PrimitiveCanvas(
                        bindings: bindings,
                        repaintNotifier: bindings,
                      ),
                    );
                  },
                ),
                PackageManagerPanel(
                  environment: widget.environment,
                  onRunLive: () {
                    setState(() {
                      _currentViewIndex = 0;
                    });
                  },
                ),
                const EngineManagerPanel(),
              ],
            ),
          ),

          // Top anti-overflow bar with horizontal scroll when tabs do not fit.
          Positioned(
            top: 40,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  icon: const Icon(
                    Icons.arrow_back_ios,
                    size: 16,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _topTab('CANVAS', 0),
                        const SizedBox(width: 6),
                        _topTab('PACKS', 1),
                        const SizedBox(width: 6),
                        _topTab('ENGINES', 2),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (!bindings.isNativeAvailable && _currentViewIndex == 0)
            Positioned(
              top: 90,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.02),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Text(
                  'CHASIS FFI: PASIVE SIMULATION CORE MODE',
                  style: TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 9,
                    color: Color(0xffe0dcd3),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          if (_autoLoadError != null && _currentViewIndex == 0)
            Positioned(
              top: 90,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                child: Text(
                  'AUTO-LOAD ERROR: ${_autoLoadError!}',
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 11,
                    color: Color(0xffe0dcd3),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topTab(String label, int index) {
    final isSel = _currentViewIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentViewIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSel ? const Color(0xffe0dcd3) : const Color(0xff0d0d0d),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSel ? Colors.transparent : const Color(0xff1b1b1b),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Arial',
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: isSel ? Colors.black : const Color(0xffe0dcd3),
          ),
        ),
      ),
    );
  }
}
