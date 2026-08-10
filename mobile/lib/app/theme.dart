import 'package:flutter/material.dart';

/// Official ZITLAS color tokens for the DARK premium surfaces (splash,
/// loading, and a couple of legacy dark screens/sheets) — see
/// `core/theme/zitlas_tokens.dart` for the LIGHT tokens the rest of the app
/// (both dashboards, diet, training, experts, profile) uses. The two exist
/// side by side deliberately: the brand's splash/loading experience is
/// specified as dark+near-black with a green glow, while the main app
/// surfaces are light+white+green — see the brand system doc for both.
///
/// REBRAND (orange -> green, matches the green ZITLAS logo): brand accent
/// was orange (`#FF8C00` family); now ZITLAS green (`#16A34A` family). The
/// dark surface colors (bgPrimary/bgCard/border) are UNCHANGED — the splash
/// is meant to stay dark/near-black, only its accent color moved to green.
/// `aiAccent` (cyan) and `error` (red) are semantic, not brand, and UNCHANGED.
abstract final class ZitlasColors {
  static const bgPrimary = Color(0xFF000000);
  static const bgCard = Color(0xFF111111);
  static const bgCardLight = Color(0xFF171717);

  /// Primary ZITLAS green.
  static const primary = Color(0xFF234B35);
  static const primaryHover = Color(0xFF22C55E);
  static const primaryDark = Color(0xFF1A3A2A);

  static const success = Color(0xFF234B35);
  static const successDark = Color(0xFF1A3A2A);

  static const aiAccent = Color(0xFF00C2FF);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF9CA3AF);
  static const textMuted = Color(0xFF6B7280);

  static const border = Color(0xFF222222);
  static const shadow = Color(0x3316A34A); // rgba(22,163,74,0.20)

  /// Not an official brand token (COLOR_GUIDELINES.md forbids new brand
  /// accents) — used only to satisfy Flutter's mandatory ColorScheme.error.
  static const error = Color(0xFFEF4444);
}

/// Cards use a 22px radius per COLOR_GUIDELINES.md's "Component Rules".
const double kCardRadius = 22;

class ZitlasTheme {
  ZitlasTheme._();

  static ThemeData get dark {
    final colorScheme = const ColorScheme.dark(
      primary: ZitlasColors.primary,
      onPrimary: ZitlasColors.textPrimary,
      secondary: ZitlasColors.aiAccent,
      onSecondary: ZitlasColors.textPrimary,
      surface: ZitlasColors.bgCard,
      onSurface: ZitlasColors.textPrimary,
      error: ZitlasColors.error,
      onError: ZitlasColors.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: ZitlasColors.bgPrimary,
      canvasColor: ZitlasColors.bgPrimary,
      fontFamily: 'Roboto',
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: ZitlasColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: ZitlasColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: ZitlasColors.textPrimary),
        bodyMedium: TextStyle(color: ZitlasColors.textSecondary),
        bodySmall: TextStyle(color: ZitlasColors.textMuted),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ZitlasColors.bgPrimary,
        foregroundColor: ZitlasColors.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: ZitlasColors.bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kCardRadius),
          side: const BorderSide(color: ZitlasColors.border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ZitlasColors.primary,
          foregroundColor: ZitlasColors.textPrimary,
          shadowColor: ZitlasColors.shadow,
          elevation: 6,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: ZitlasColors.primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ZitlasColors.bgCardLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ZitlasColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ZitlasColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ZitlasColors.primary),
        ),
        hintStyle: const TextStyle(color: ZitlasColors.textMuted),
      ),
      // Kept light/neutral (rather than ZitlasColors.bgCard/dark) even
      // though the rest of this theme is dark — the Home tab now renders
      // the real (light) Athlete Dashboard per theme.css, and a dark bar
      // directly beneath a light dashboard reproduced exactly the
      // black-framing defect fixed for the auth screens. The still-dark
      // placeholder tabs (Diet/Training/Experts/Profile) tolerate a light
      // nav bar fine until their own migration.
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFFFFFFFF),
        selectedItemColor: Color(0xFF234B35),
        unselectedItemColor: Color(0xFF94A3B8),
        type: BottomNavigationBarType.fixed,
      ),
      dividerTheme: const DividerThemeData(color: ZitlasColors.border),
    );
  }
}
