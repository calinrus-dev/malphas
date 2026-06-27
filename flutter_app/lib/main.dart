import 'package:flutter/material.dart';
import 'core/theme/theme.dart';
import 'features/workspace/workspace_screen.dart';

void main() {
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
      home: const WorkspaceScreen(),
    );
  }
}
