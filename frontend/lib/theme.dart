import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// "Care ledger" palette: warm paper, ink, deep teal, marigold for pending.
class C {
  static const paper = Color(0xFFFBF7F0);
  static const card = Color(0xFFFFFFFF);
  static const ink = Color(0xFF1F2A44);
  static const muted = Color(0xFF6B7385);
  static const line = Color(0xFFE9E2D6);
  static const teal = Color(0xFF0F6B5C);
  static const tealSoft = Color(0xFFE3F1EE);
  static const marigold = Color(0xFFD9861F);
  static const marigoldSoft = Color(0xFFFCEFDC);
  static const rose = Color(0xFFB4433C);
  static const roseSoft = Color(0xFFF8E3E1);
  static const plum = Color(0xFF5B4B8A);
  static const plumSoft = Color(0xFFECE8F6);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: C.teal,
      primary: C.teal,
      surface: C.paper,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: C.paper,
  );
  final body = GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
    bodyColor: C.ink,
    displayColor: C.ink,
  );
  return base.copyWith(
    textTheme: body.copyWith(
      headlineLarge: GoogleFonts.fraunces(fontSize: 34, fontWeight: FontWeight.w600, color: C.ink, height: 1.1),
      headlineMedium: GoogleFonts.fraunces(fontSize: 26, fontWeight: FontWeight.w600, color: C.ink),
      titleLarge: GoogleFonts.fraunces(fontSize: 20, fontWeight: FontWeight.w600, color: C.ink),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: C.paper,
      foregroundColor: C.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.teal, width: 1.6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.teal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.ink,
        side: const BorderSide(color: C.line),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
