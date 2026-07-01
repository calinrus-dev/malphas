import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/services/app_state_persistence_service.dart';
import '../hub/hub_screen.dart';
import '../onboarding/onboarding_screen.dart';

/// Themed, skippable splash screen.
///
/// First launch plays the full intro animation. Subsequent launches show a
/// shorter version so repeat users are not blocked by a hard 2.5 s wait.
/// Tapping the screen skips the remaining animation and navigates to the hub.
class MalphasSplashScreen extends StatefulWidget {
  const MalphasSplashScreen({super.key});

  @override
  State<MalphasSplashScreen> createState() => _MalphasSplashScreenState();
}

class _MalphasSplashScreenState extends State<MalphasSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  final List<String> _letters = ['M', 'A', 'L', 'P', 'H', 'A', 'S'];

  bool _firstLaunch = true;
  bool _navigating = false;

  static const String _version = '3.0.0';
  static const String _build = '1';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _loadLaunchStateAndRun();
  }

  Future<void> _loadLaunchStateAndRun() async {
    final shown = await _persistence.loadSplashShown();
    final onboardingCompleted = await _persistence.loadOnboardingCompleted();
    setState(() => _firstLaunch = !shown);

    if (!shown) {
      await _persistence.saveSplashShown();
    }

    _controller.forward().then((_) {
      _navigateAfterSplash(onboardingCompleted);
    });
  }

  void _skip() {
    if (_navigating) return;
    _controller.stop();
    _navigateAfterSplash(null);
  }

  void _navigateAfterSplash(bool? onboardingCompleted) {
    if (_navigating) return;
    _navigating = true;

    final completed = onboardingCompleted ?? true;
    final destination =
        completed ? const MalphasHubScreen() : const MalphasOnboardingScreen();

    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, anim, secondaryAnim) => destination,
          transitionsBuilder: (context, anim, secondaryAnim, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 600),
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targetDuration = _firstLaunch
        ? const Duration(milliseconds: 2500)
        : const Duration(milliseconds: 800);

    if (_controller.duration != targetDuration) {
      _controller.duration = targetDuration;
    }

    return GestureDetector(
      onTap: _skip,
      behavior: HitTestBehavior.opaque,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final value = _controller.value;
            final fadeOpacity = value < 0.8
                ? (value / 0.8).clamp(0.0, 1.0)
                : (1.0 - (value - 0.8) / 0.2).clamp(0.0, 1.0);

            return Stack(
              children: [
                Center(
                  child: Opacity(
                    opacity: fadeOpacity,
                    child: Stack(
                      alignment: Alignment.center,
                      children: List.generate(_letters.length, (index) {
                        final angle =
                            (index * (2 * math.pi / _letters.length)) +
                                (value * 2 * math.pi);
                        final radius = (1.0 - value) * 120.0;
                        final x = math.cos(angle) * radius;
                        final y = math.sin(angle) * radius;

                        return Transform.translate(
                          offset: Offset(x, y),
                          child: Text(
                            _letters[index],
                            style: const TextStyle(
                              fontFamily: 'Georgia',
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Color(0xffe0dcd3),
                              letterSpacing: 2,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 48,
                  left: 0,
                  right: 0,
                  child: Opacity(
                    opacity: fadeOpacity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'MALPHAS',
                          style: TextStyle(
                            fontFamily: 'Georgia',
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xff00ffcc),
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // ignore: prefer_const_constructors
                        Text(
                          'v$_version  ·  build $_build',
                          style: const TextStyle(
                            fontFamily: 'Courier',
                            fontSize: 10,
                            color: Colors.white38,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'tap to skip',
                          style: TextStyle(
                            fontFamily: 'Arial',
                            fontSize: 9,
                            color: Colors.white.withValues(alpha: 0.25),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
