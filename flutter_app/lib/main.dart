import 'package:flutter/material.dart';
import 'core/theme/theme.dart';
import 'features/splash/splash_screen.dart';
import 'features/package_manager/package_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the package registry. It will scan compiled .msp packs on disk
  // and restore the previously loaded state from JSON persisted in the app
  // documents directory.
  await PackageController().init();

  runApp(const MalphasConsole());
}

class MalphasConsole extends StatelessWidget {
  const MalphasConsole({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Malphas',
      theme: MalphasTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home:
          const MalphasSplashScreen(), // Boots straight into the interactive splash screen
    );
  }
}
