import 'package:flutter/material.dart';
import 'core/theme/theme.dart';
import 'features/splash/splash_screen.dart';
import 'features/package_manager/package_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar asíncronamente el gestor de paquetes persistentes en disco
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
          const MalphasSplashScreen(), // Arranca directamente en el Splash interactivo
    );
  }
}
