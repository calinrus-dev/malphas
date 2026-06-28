import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/ffi/malphas_bindings.dart';
import '../../core/ui_primitives/primitive_canvas.dart';
import '../hub/hub_screen.dart';
import '../package_manager/package_manager_screen.dart';
import '../package_manager/package_controller.dart';
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

  @override
  void initState() {
    super.initState();
    bindings = MalphasBindings();

    _ticker = createTicker((elapsed) {
      // Single-clock sync: one engine pulse per vsync from Flutter's Ticker.
      bindings.tick();
      // Refresco visual repaint-driven sin re-layouts globales en alta frecuencia (Regla 5)
    });
    _ticker.start();

    _autoLoadPackages();
  }

  /// Loads the environment's first package (or the default bouncing demo) into
  /// the native core, configures the entities, and starts the simulation pulse.
  Future<void> _autoLoadPackages() async {
    await PackageController().init();

    final packageIds = widget.environment.packageIds;
    final targetPackId =
        packageIds.isNotEmpty ? packageIds.first : 'bouncing_demo';

    final mhpFile = await _resolveMhpFile(targetPackId);
    if (mhpFile == null || !mhpFile.existsSync()) {
      debugPrint('Workspace auto-load: no .mhp found for $targetPackId');
      return;
    }

    if (!bindings.isNativeAvailable) {
      debugPrint('Workspace auto-load: native core not available');
      return;
    }

    bindings.pauseEngine(true);
    try {
      final loadResult = bindings.loadPack(mhpFile.path);
      if (loadResult != 0) {
        debugPrint('Workspace auto-load: loadPack failed with $loadResult');
        return;
      }

      _configureDefaultEntities();
    } finally {
      bindings.pauseEngine(false);
    }
  }

  /// Searches the compiled package in `examples/` and `packages/`.
  Future<File?> _resolveMhpFile(String packId) async {
    final workspace = PackageController.resolveWorkspaceRoot();
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

  /// Configures a default rectangle + text scene matching the integration test.
  void _configureDefaultEntities() {
    bindings.setEntitiesCount(2);

    bindings.configureEntity(
      entityId: 0,
      commandType: 1, // rectangle
      layer: 0,
      x: 50.0,
      y: 50.0,
      width: 100.0,
      height: 100.0,
      colorRgba: 0xFF00FFCC,
      speedX: 4.0,
      speedY: 3.0,
      minX: 0.0,
      maxX: 1000.0,
      minY: 0.0,
      maxY: 1000.0,
    );

    const textOffset = 8192;
    bindings.writeArenaText(
      textOffset,
      100.0,
      100.0,
      24.0,
      Uint8List.fromList([...utf8.encode('MALPHAS'), 0]),
    );

    bindings.configureEntity(
      entityId: 1,
      commandType: 2, // text
      layer: 1,
      x: 100.0,
      y: 100.0,
      width: 24.0,
      height: 0.0,
      colorRgba: 0xFFFFFFFF,
      speedX: 0.0,
      speedY: 0.0,
      minX: 0.0,
      maxX: 1000.0,
      minY: 0.0,
      maxY: 1000.0,
      strOffset: textOffset,
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    bindings.dispose();
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
                        final double logicalX =
                            (localPos.dx / constraints.maxWidth) * 1000.0;
                        final double logicalY =
                            (localPos.dy / constraints.maxHeight) * 1000.0;
                        bindings.processInputEvent(0, logicalX, logicalY);
                      },
                      child: PrimitiveCanvas(
                          bindings: bindings, repaintNotifier: bindings),
                    );
                  },
                ),
                const PackageManagerPanel(),
                const EngineManagerPanel(),
              ],
            ),
          ),

          // BARRA SUPERIOR ANTIOVERFLOW (Scroll horizontal integrado si no caben las pestañas)
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
                  icon: const Icon(Icons.arrow_back_ios,
                      size: 16, color: Colors.white),
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
                )
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
                    border: Border.all(color: Colors.white10)),
                child: const Text('CHASIS FFI: PASIVE SIMULATION CORE MODE',
                    style: TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 9,
                        color: Color(0xffe0dcd3),
                        fontWeight: FontWeight.bold)),
              ),
            )
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
                color: isSel ? Colors.transparent : const Color(0xff1b1b1b))),
        child: Text(label,
            style: TextStyle(
                fontFamily: 'Arial',
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isSel ? Colors.black : const Color(0xffe0dcd3))),
      ),
    );
  }
}
