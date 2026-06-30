import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../hub/hub_screen.dart';

class MalphasSplashScreen extends StatefulWidget {
  const MalphasSplashScreen({super.key});

  @override
  State<MalphasSplashScreen> createState() => _MalphasSplashScreenState();
}

class _MalphasSplashScreenState extends State<MalphasSplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<String> _letters = ['M', 'A', 'L', 'P', 'H', 'A', 'S'];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );

    _controller.forward().then((_) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, anim, secondaryAnim) =>
                const MalphasHubScreen(),
            transitionsBuilder: (context, anim, secondaryAnim, child) =>
                FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 600),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final value = _controller.value;
          return Stack(
            children: [
              Center(
                child: Opacity(
                  opacity: value < 0.8
                      ? (value / 0.8).clamp(0.0, 1.0)
                      : (1.0 - (value - 0.8) / 0.2).clamp(0.0, 1.0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: List.generate(_letters.length, (index) {
                      final angle = (index * (2 * math.pi / _letters.length)) +
                          (value * 2 * math.pi);
                      // Letters orbit radially and collapse toward the center (radius tends to zero)
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
            ],
          );
        },
      ),
    );
  }
}
