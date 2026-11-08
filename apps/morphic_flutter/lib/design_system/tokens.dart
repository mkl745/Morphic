/// MORPHIC design tokens (docs/design/design-system.md).
///
/// Single source of truth for color, spacing, radius, and motion. Feature code must not
/// hardcode colors/sizes; it consumes these tokens. Dark is the reference theme.
library;

import 'package:flutter/material.dart';

abstract final class MorphicColors {
  // Dark (reference)
  static const bgDark = Color(0xFF0A0C10);
  static const surfaceDark = Color(0xFF12151C);
  static const surfaceElevatedDark = Color(0xFF1A1F29);
  static const borderDark = Color(0xFF232A37);
  static const textPrimaryDark = Color(0xFFE6EAF2);
  static const textSecondaryDark = Color(0xFF9AA3B2);

  // Light
  static const bgLight = Color(0xFFF7F8FA);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const borderLight = Color(0xFFE3E7ED);
  static const textPrimaryLight = Color(0xFF14181F);
  static const textSecondaryLight = Color(0xFF5B6472);

  // Semantic (shared hues)
  static const accent = Color(0xFF4FD1C5);
  static const accentDark = Color(0xFF0D9488);
  static const info = Color(0xFF60A5FA);

  /// Deeper blue for light surfaces, the way [accentDark] pairs with [accent]. `info` itself
  /// only reaches 2.5:1 on white, below the 3:1 WCAG 1.4.11 floor for a meaningful graphic.
  static const infoDark = Color(0xFF2563EB);
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const error = Color(0xFFF87171);
}

abstract final class MorphicSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class MorphicRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

abstract final class MorphicMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 250);
}

/// Builds the dark and light [ThemeData] from tokens, on a Material 3 foundation.
abstract final class MorphicTheme {
  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? MorphicColors.accent : MorphicColors.accentDark,
      onPrimary: isDark ? MorphicColors.bgDark : Colors.white,
      secondary: MorphicColors.info,
      onSecondary: Colors.white,
      error: MorphicColors.error,
      onError: Colors.white,
      surface: isDark ? MorphicColors.surfaceDark : MorphicColors.surfaceLight,
      onSurface:
          isDark ? MorphicColors.textPrimaryDark : MorphicColors.textPrimaryLight,
    );
    // Phase 0 keeps the theme minimal and low-risk. Custom card chrome, Inter /
    // JetBrains Mono bundling, and the full token application land in the M1.6 design pass.
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? MorphicColors.bgDark : MorphicColors.bgLight,
    );
  }
}
