import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../core/ffi/malphas_bindings.dart';
import '../../core/ui_primitives/primitive_canvas.dart';

import 'dart:ffi' as dffi;

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

// Top-level fallback ligero que cumple la API usada por la UI cuando la
// inicialización nativa falla. Devuelve un pointer nulo para `commandBuffer`
// y operaciones no-op para `tick` y `dispose`.
class _FallbackBindings {
  int tick() => 0;
  void dispose() {}
  dffi.Pointer? get commandBuffer => dffi.nullptr;
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  late final dynamic bindings;
  late final Ticker _ticker;
  String currentMode = 'MECATRON Core';

  @override
  void initState() {
    super.initState();

    // Inicialización robusta con captura de errores FFI; si falla creamos un
    // fallback ligero que cumple la API mínima usada por la UI.
    try {
      bindings = MalphasBindings();
    } catch (e) {
      bindings = _FallbackBindings();
    }

    // Ticker a 120Hz esperado por el motor; setState sólo actualiza el conteo
    _ticker = createTicker((elapsed) {
      bindings.tick();
      if (mounted) setState(() {});
    });
    _ticker.start();
  }

  MalphasBindings throwOnBindingsError(Object e) {
    // Ya manejado por el bloque catch; esta función ya no se usa pero
    // se mantiene para compatibilidad semántica.
    throw StateError('Unexpected call to throwOnBindingsError: $e');
  }

  // Fallback ligero que cumple la API usada por la UI cuando la inicialización
  // nativa falla. Devuelve un pointer nulo para `commandBuffer` y operaciones
  // no-op para `tick` y `dispose`.

  @override
  void dispose() {
    _ticker.dispose();
    try {
      bindings.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      drawer: Drawer(
        backgroundColor: const Color(0xff0d0d0d),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LIQUID 1.0',
                  style: TextStyle(
                    fontFamily: 'Georgia',
                    fontSize: 24,
                    color: Color(0xffe0dcd3),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 24),
                _sideTile('Active Session', 'Slot 01'),
                _sideTile('Dormant Memory', 'Slot 02'),
                const Spacer(),
                Row(
                  children: const [
                    Icon(Icons.person_outline, color: Color(0xffe0dcd3)),
                    SizedBox(width: 8),
                    Text(
                      'Calin Rus',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: PrimitiveCanvas(bufferPtr: bindings.commandBuffer),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xff0d0d0d),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: const Color(0xff1b1b1b), width: 1),
              ),
              child: Row(
                children: [
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: currentMode,
                      dropdownColor: const Color(0xff0d0d0d),
                      iconEnabledColor: Colors.white30,
                      items: ['MECATRON Core', 'Quiz Mode', 'Voice Mode']
                          .map(
                            (mode) => DropdownMenuItem(
                              value: mode,
                              child: Text(
                                mode,
                                style: const TextStyle(
                                  color: Color(0xffe0dcd3),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => currentMode = value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: TextField(
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Inyectar comando...',
                        hintStyle: TextStyle(
                          color: Colors.white24,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: Color(0xffe0dcd3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sideTile(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0x11111111),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
