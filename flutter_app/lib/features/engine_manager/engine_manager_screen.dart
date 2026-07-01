import 'package:flutter/material.dart';
import 'engine_controller.dart';
import 'hot_swap_panel.dart';
import 'models.dart';

class EngineManagerPanel extends StatefulWidget {
  const EngineManagerPanel({super.key});

  @override
  State<EngineManagerPanel> createState() => _EngineManagerPanelState();
}

class _EngineManagerPanelState extends State<EngineManagerPanel> {
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

  void _verify(String id) {
    _controller.verifyEngineIntegrity(id);
  }

  void _swap(String id) {
    _controller.hotSwapEngine(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _controller.getAllEngines();

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Padding(
          padding: const EdgeInsets.only(
            top: 100,
            left: 16,
            right: 16,
            bottom: 95,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Engine Depot', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text(
                'Signature status and verification in ../motors/',
                style: TextStyle(
                  fontFamily: 'Arial',
                  fontSize: 11,
                  color: Colors.white24,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff161616)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'NATIVE ARENA TELEMETRY',
                      style: TextStyle(
                        fontFamily: 'Arial',
                        fontSize: 9,
                        color: Colors.white38,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      alignment: WrapAlignment.start,
                      children: [
                        _statBlock('MAPPED RAMPOOL', '24 BYTES/CMD'),
                        _statBlock('ALIGNMENT', '#[repr(C)]'),
                        _statBlock('VSYNC REFRESH', '120 HZ LOOP'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const HotSwapPanel(),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: list.length,
                  itemBuilder: (context, idx) {
                    final engine = list[idx];
                    Color statusColor = Colors.white24;
                    IconData statusIcon = Icons.help_outline;
                    String statusLabel = 'UNVERIFIED';
                    String actionText = 'VERIFY';
                    VoidCallback action = () => _verify(engine.id);

                    if (engine.status == EngineStatus.active) {
                      statusColor = Colors.green;
                      statusIcon = Icons.verified_user_sharp;
                      statusLabel = 'ACTIVE RUNNING';
                      actionText = 'ACTIVE';
                      action = () {};
                    } else if (engine.status == EngineStatus.standby) {
                      statusColor = Colors.blue;
                      statusIcon = Icons.check_circle_outline;
                      statusLabel = 'STANDBY';
                      actionText = 'HOT-SWAP';
                      action = () => _swap(engine.id);
                    } else if (engine.status == EngineStatus.corrupt) {
                      statusColor = Colors.red;
                      statusIcon = Icons.error_outline;
                      statusLabel = 'CORRUPT / NOT FOUND';
                      actionText = 'RETRY';
                      action = () => _verify(engine.id);
                    }

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: theme.cardColor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xff141414)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        title: Text(
                          engine.name,
                          style: const TextStyle(
                            fontFamily: 'Arial',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Runtime: ${engine.runtimeLabel}\nStatus: $statusLabel\nHash: ${engine.sha256.length >= 16 ? '${engine.sha256.substring(0, 16)}...' : engine.sha256}',
                            style: const TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 10,
                              color: Colors.white24,
                              height: 1.3,
                            ),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(statusIcon, color: statusColor, size: 16),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: action,
                              style: TextButton.styleFrom(
                                backgroundColor: const Color(0xff1b1b1b),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                actionText,
                                style: const TextStyle(
                                  fontFamily: 'Arial',
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xff050505),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xff111111)),
                ),
                child: const Text(
                  '[SYSTEM] Passive Display Server coupled to the GPU synchronously.',
                  style: TextStyle(
                    fontFamily: 'Arial',
                    fontSize: 10,
                    color: Colors.white38,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statBlock(String label, String val) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Arial',
            fontSize: 8,
            color: Colors.white24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          val,
          style: const TextStyle(
            fontFamily: 'Courier',
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
