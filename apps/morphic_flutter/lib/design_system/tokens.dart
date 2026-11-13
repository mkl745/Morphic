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

  // Selection surfaces remain legible with each theme's primary text.
  static const selectionDark = Color(0xFF17423F);
  static const selectionLight = Color(0xFFCDECE8);

  // Tonal error surfaces keep both explanatory text and recovery actions legible.
  static const errorContainerDark = Color(0xFF402025);
  static const errorContainerLight = Color(0xFFFFEDEC);

  // Semantic (shared hues)
  static const accent = Color(0xFF4FD1C5);
  static const accentDark = Color(0xFF0D9488);
  // The light accent is suitable for graphics, but small action text needs a deeper shade.
  static const accentTextLight = Color(0xFF0F766E);
  static const info = Color(0xFF60A5FA);

  /// Deeper blue for light surfaces, the way [accentDark] pairs with [accent]. `info` itself
  /// only reaches 2.5:1 on white, below the 3:1 WCAG 1.4.11 floor for a meaningful graphic.
  static const infoDark = Color(0xFF2563EB);
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const error = Color(0xFFF87171);

  /// Series colours for multi-line charts, in engine order (most frequent series first).
  ///
  /// Eight entries because `MAX_SERIES` is eight. Every entry clears 3:1 against its theme's
  /// card surface — the WCAG 1.4.11 floor for a graphic that carries meaning — and the order
  /// alternates hue families so neighbouring series are not two blues. Colour is never the
  /// only channel: the legend names each series and the scrub tooltip and table repeat the
  /// names beside the numbers.
  static const List<Color> seriesDark = [
    Color(0xFF4FD1C5), // teal
    Color(0xFFC084FC), // purple
    Color(0xFFFBBF24), // amber
    Color(0xFF60A5FA), // blue
    Color(0xFFF87171), // red
    Color(0xFF22D3EE), // cyan
    Color(0xFFFB923C), // orange
    Color(0xFF34D399), // green
  ];

  /// Light-surface counterparts. The bright dark-theme hues fall to ~1.9:1 on white, so these
  /// are deeper tones of the same families rather than the same values.
  static const List<Color> seriesLight = [
    Color(0xFF0D9488), // teal
    Color(0xFF7E22CE), // purple
    Color(0xFFB45309), // amber
    Color(0xFF2563EB), // blue
    Color(0xFFB91C1C), // red
    Color(0xFF0E7490), // cyan
    Color(0xFFC2410C), // orange
    Color(0xFF047857), // green
  ];

  /// Severity lanes for the timeline. Unlike an arbitrary series, `ERROR` should look like an
  /// error in every workspace, so recognised levels get a fixed semantic hue and only unrecognised
  /// labels fall back to [seriesDark]/[seriesLight] by lane order.
  ///
  /// All ten clear 3:1 on their own card surface (dark on #12151C, light on #FFFFFF), measured
  /// the same way as the series palette. `muted` is for debug/trace: present and legible, but
  /// deliberately the least loud thing on the chart.
  static const severityErrorDark = error;
  static const severityWarningDark = warning;
  static const severityInfoDark = info;
  static const severityOkDark = success;
  static const severityMutedDark = textSecondaryDark;

  static const severityErrorLight = Color(0xFFB91C1C);
  static const severityWarningLight = Color(0xFFB45309);
  static const severityInfoLight = infoDark;
  static const severityOkLight = Color(0xFF047857);
  static const severityMutedLight = textSecondaryLight;

  /// Text-safe semantic colors, including on white surfaces in light mode.
  static Color warningText(Brightness brightness) =>
      brightness == Brightness.dark ? warning : severityWarningLight;
  static Color successText(Brightness brightness) =>
      brightness == Brightness.dark ? success : severityOkLight;
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
  static const Duration stagger = Duration(milliseconds: 40);
  static const Duration entranceLimit = Duration(milliseconds: 400);
  static const double entranceRise = 4;
  static const Curve easing = Cubic(0.2, 0, 0, 1);
}

abstract final class MorphicTypography {
  static const String ui = 'Inter';
  static const String data = 'JetBrainsMono';

  /// Tabular figures keep values aligned without changing the engine's formatting.
  static TextStyle? dataStyle(TextStyle? base) => base?.copyWith(
        fontFamily: data,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}

/// Builds both themes from the same tokens. A light theme is not an inverted dark one.
abstract final class MorphicTheme {
  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? MorphicColors.bgDark : MorphicColors.bgLight;
    final surface = dark ? MorphicColors.surfaceDark : MorphicColors.surfaceLight;
    final text = dark ? MorphicColors.textPrimaryDark : MorphicColors.textPrimaryLight;
    final muted = dark ? MorphicColors.textSecondaryDark : MorphicColors.textSecondaryLight;
    final border = dark ? MorphicColors.borderDark : MorphicColors.borderLight;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: dark ? MorphicColors.accent : MorphicColors.accentDark,
      // White on the light accent is only 3.7:1; dark ink clears 4.5:1 in both themes.
      onPrimary: dark ? MorphicColors.bgDark : MorphicColors.textPrimaryLight,
      secondary: dark ? MorphicColors.info : MorphicColors.infoDark,
      onSecondary: dark ? MorphicColors.bgDark : MorphicColors.surfaceLight,
      secondaryContainer: dark ? MorphicColors.selectionDark : MorphicColors.selectionLight,
      onSecondaryContainer: text,
      error: dark ? MorphicColors.error : MorphicColors.severityErrorLight,
      onError: dark ? MorphicColors.bgDark : MorphicColors.surfaceLight,
      errorContainer: dark ? MorphicColors.errorContainerDark : MorphicColors.errorContainerLight,
      onErrorContainer: text,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: muted,
      outline: border,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: MorphicTypography.ui,
    );
    TextStyle? scaled(TextStyle? style, double size, FontWeight weight) =>
        style?.copyWith(fontSize: size, fontWeight: weight, height: 1.4);
    final typography = base.textTheme.apply(bodyColor: text, displayColor: text);
    final textTheme = typography.copyWith(
      headlineMedium: scaled(typography.headlineMedium, 28, FontWeight.w600),
      titleLarge: scaled(typography.titleLarge, 20, FontWeight.w600),
      titleMedium: scaled(typography.titleMedium, 16, FontWeight.w600),
      titleSmall: scaled(typography.titleSmall, 16, FontWeight.w600),
      bodyLarge: scaled(typography.bodyLarge, 16, FontWeight.w400),
      bodyMedium: scaled(typography.bodyMedium, 14, FontWeight.w400),
      bodySmall: scaled(typography.bodySmall, 12, FontWeight.w400),
      labelLarge: scaled(typography.labelLarge, 14, FontWeight.w500),
      labelMedium: scaled(typography.labelMedium, 12, FontWeight.w500),
      labelSmall: scaled(typography.labelSmall, 11, FontWeight.w500),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MorphicRadius.md),
      side: BorderSide(color: border),
    );
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(MorphicRadius.sm),
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: MorphicSpace.xs),
        shape: shape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: dark ? MorphicColors.accent : MorphicColors.accentTextLight,
          minimumSize: const Size(48, 48),
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: dark ? MorphicColors.accent : MorphicColors.accentTextLight,
          minimumSize: const Size(48, 48),
        ),
      ),
    );
  }
}
