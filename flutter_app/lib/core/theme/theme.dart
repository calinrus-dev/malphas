import 'package:flutter/material.dart';

class MalphasTheme {
  static const Color ink = Color(0xff000000);
  static const Color slate = Color(0xff0d0d0d);
  static const Color bone = Color(0xffe0dcd3);
  static const Color mist = Color(0xff8a8a8a);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: ink,
      primaryColor: bone,
      cardColor: slate,
      colorScheme: const ColorScheme.dark(
        primary: bone,
        surface: slate,
        onSurface: bone,
        secondary: mist,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontFamily: 'Georgia',
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: bone,
        ),
        titleMedium: TextStyle(fontFamily: 'Arial', fontSize: 14, color: bone),
        bodyMedium: TextStyle(fontFamily: 'Arial', fontSize: 13, color: mist),
      ),
    );
  }
}
