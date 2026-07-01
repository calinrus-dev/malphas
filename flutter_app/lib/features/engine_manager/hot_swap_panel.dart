import 'package:flutter/material.dart';
import 'engine_controller.dart';

/// Hot-swap controls for the native engine runtime.
///
/// Provides buttons to reload the current MSP without stopping the system and
/// to perform a full system reload. While a reload is in progress the panel
/// blocks user input and shows a spinner.
class HotSwapPanel extends StatefulWidget {
  const HotSwapPanel({super.key});

  @override
  State<HotSwapPanel> createState() => _HotSwapPanelState();
}

class _HotSwapPanelState extends State<HotSwapPanel>
    with SingleTickerProviderStateMixin {
  final EngineController _controller = EngineController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reloadMsp() async {
    final env = _controller.activeEnvironment;
    if (env == null) return;
    final packIds =
        env.packageIds.isNotEmpty ? env.packageIds : const ['bouncing_demo'];
    _controller.reloadMsp(packIds.first);
  }

  Future<void> _reloadSystem() async {
    await _controller.reloadSystem(this);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBusy = _controller.isLoading;
    final canReload = _controller.isRunning && !isBusy;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xff0d0d0d),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xff161616)),
      ),
      child: AbsorbPointer(
        absorbing: isBusy,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HOT SWAP',
              style: TextStyle(
                fontFamily: 'Arial',
                fontSize: 9,
                color: Colors.white38,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: canReload ? _reloadMsp : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xff1b1b1b),
                      foregroundColor: theme.primaryColor,
                      disabledForegroundColor: Colors.white24,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: isBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white24,
                            ),
                          )
                        : const Icon(Icons.refresh, size: 16),
                    label: const Text(
                      'RELOAD MSP',
                      style: TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: canReload ? _reloadSystem : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xff1b1b1b),
                      foregroundColor: theme.primaryColor,
                      disabledForegroundColor: Colors.white24,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: isBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white24,
                            ),
                          )
                        : const Icon(Icons.power_settings_new, size: 16),
                    label: const Text(
                      'RELOAD SYSTEM',
                      style: TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_controller.errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _controller.errorMessage!,
                style: const TextStyle(
                  fontFamily: 'Courier',
                  color: Colors.redAccent,
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
