import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/ffi/malphas_bindings.dart';
import '../../core/ui_primitives/primitive_canvas.dart';
import '../hub/hub_screen.dart';
import '../package_manager/package_manager_screen.dart';
import '../engine_manager/engine_manager_screen.dart';

class WorkspaceScreen extends StatefulWidget {
  final MalphasEnvironment environment;
  const WorkspaceScreen({super.key, required this.environment});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> with SingleTickerProviderStateMixin {
  late final MalphasBindings bindings;
  late final Ticker _ticker;
  int _currentViewIndex = 0;

  @override
  void initState() {
    super.initState();
    bindings = MalphasBindings();

    _ticker = createTicker((elapsed) {
      bindings.tick();
      // Refresco visual repaint-driven sin re-layouts globales en alta frecuencia (Regla 5)
    });
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
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
                PrimitiveCanvas(bufferPtr: bindings.commandBuffer, repaintNotifier: bindings),
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
                  icon: const Icon(Icons.arrow_back_ios, size: 16, color: Colors.white),
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
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.02), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
                child: const Text('CHASIS FFI: PASIVE SIMULATION CORE MODE', style: TextStyle(fontFamily: 'Courier', fontSize: 9, color: Color(0xffe0dcd3), fontWeight: FontWeight.bold)),
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
        decoration: BoxDecoration(color: isSel ? const Color(0xffe0dcd3) : const Color(0xff0d0d0d), borderRadius: BorderRadius.circular(14), border: Border.all(color: isSel ? Colors.transparent : const Color(0xff1b1b1b))),
        child: Text(label, style: TextStyle(fontFamily: 'Arial', fontSize: 10, fontWeight: FontWeight.bold, color: isSel ? Colors.black : const Color(0xffe0dcd3))),
      ),
    );
  }
}
