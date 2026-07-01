import 'package:flutter/material.dart';

class MalphasTheme {
  static const Color ink = Color(0xff000000); // Absolute black
  static const Color slate = Color(0xff0d0d0d); // Matte anthracite
  static const Color bone = Color(0xffe0dcd3); // High-contrast bone
  static const Color borderAccent = Color(0xff1b1b1b); // Outline gray
  static const Color mist = Color(0xff8a8a8a); // Secondary data
  static const Color accent = Color(0xff00ffcc); // Signature teal

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
          fontSize: 28,
          fontWeight: FontWeight.w700,
          color: bone,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'Georgia',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: bone,
        ),
        titleMedium: TextStyle(
          fontFamily: 'Arial',
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: bone,
          letterSpacing: 0.2,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Courier',
          fontSize: 13,
          color: mist,
          height: 1.4,
        ),
        labelSmall: TextStyle(
          fontFamily: 'Courier',
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: bone,
        ),
      ),
    );
  }
}
