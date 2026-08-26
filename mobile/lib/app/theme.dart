import 'package:flutter/material.dart';

import '../core/theme/zitlas_tokens.dart';

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

  /// THE APP-WIDE THEME IS LIGHT.
  ///
  /// It used to be `Brightness.dark` with white default text, left over from
  /// before the light rebrand. Meanwhile 89 files migrated to the LIGHT
  /// tokens in `core/theme/zitlas_tokens.dart` and paint white cards and
  /// cream surfaces. Every widget that did not set a colour of its own
  /// therefore inherited WHITE text and drew it on a white background:
  /// unreadable labels in the survey (Medical Conditions), the Meal Snap
  /// flow, dialogs, dropdowns, snackbars and pickers — anywhere a default
  /// was relied on.
  ///
  /// Fixing individual screens would have left the NEXT new screen broken
  /// the same way, so the default itself is now dark-text-on-light. The
  /// genuinely dark surfaces that remain (splash, loading ring) set their
  /// colours explicitly from [ZitlasColors] and are unaffected.
  ///
  /// [dark] is kept as a forwarder so existing call sites keep working;
  /// [light] is the honest name.
  static ThemeData get dark => light;

  static ThemeData get light {
    const colorScheme = ColorScheme.light(
      primary: ZitlasTokens.primary,
      onPrimary: Color(0xFFFFFFFF), // on the dark green button — correct
      secondary: ZitlasTokens.aiAccent,
      onSecondary: Color(0xFFFFFFFF),
      surface: ZitlasTokens.bgCard,
      onSurface: ZitlasTokens.textPrimary, // near-black on white
      error: ZitlasTokens.danger,
      onError: Color(0xFFFFFFFF),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: ZitlasTokens.bgPrimary,
      canvasColor: ZitlasTokens.bgPrimary,
      fontFamily: 'Roboto',
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          color: ZitlasTokens.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: TextStyle(
          color: ZitlasTokens.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: ZitlasTokens.textPrimary),
        bodyMedium: TextStyle(color: ZitlasTokens.textSecondary),
        bodySmall: TextStyle(color: ZitlasTokens.textMuted),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: ZitlasTokens.bgCard,
        foregroundColor: ZitlasTokens.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: ZitlasTokens.bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kCardRadius),
          side: const BorderSide(color: ZitlasTokens.border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ZitlasTokens.primary,
          // White is correct here: the button itself is dark green.
          foregroundColor: const Color(0xFFFFFFFF),
          shadowColor: ZitlasTokens.borderSub,
          elevation: 6,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: ZitlasTokens.primary),
      ),
      // Dialogs, sheets and menus inherit these, and they were the worst of
      // it: on a dark ThemeData a Material dialog paints a dark surface with
      // light text, but these sit on light screens, so the text came out
      // white on white.
      dialogTheme: const DialogThemeData(
        backgroundColor: ZitlasTokens.bgCard,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: ZitlasTokens.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w800,
        ),
        contentTextStyle: TextStyle(
          color: ZitlasTokens.textSecondary,
          fontSize: 14,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: ZitlasTokens.bgCard,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: ZitlasTokens.bgCard,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: ZitlasTokens.bgCard,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: ZitlasTokens.textPrimary),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        textStyle: TextStyle(color: ZitlasTokens.textPrimary),
      ),
      // Snackbars stay DARK deliberately — a floating toast reads better as
      // a dark slab over light content — so their white text is correct.
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF17221A),
        contentTextStyle: TextStyle(color: Color(0xFFFFFFFF)),
        actionTextColor: ZitlasTokens.achievementYellow,
        behavior: SnackBarBehavior.floating,
      ),
      // Selection controls: the tick/dot is white on a filled green box,
      // which is correct. The LABEL beside it comes from textTheme above —
      // that is what was unreadable on Medical Conditions.
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ZitlasTokens.primary
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Color(0xFFFFFFFF)),
        side: const BorderSide(color: ZitlasTokens.border, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ZitlasTokens.primary
              : ZitlasTokens.textMuted,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0xFFFFFFFF)
              : ZitlasTokens.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ZitlasTokens.primary
              : ZitlasTokens.border,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: ZitlasTokens.textPrimary,
        iconColor: ZitlasTokens.textSecondary,
      ),
      iconTheme: const IconThemeData(color: ZitlasTokens.textSecondary),
      // Date/time pickers are full Material surfaces; on the old dark
      // defaults they lost their labels against a light app.
      datePickerTheme: const DatePickerThemeData(
        backgroundColor: ZitlasTokens.bgCard,
        surfaceTintColor: Colors.transparent,
        headerForegroundColor: ZitlasTokens.textPrimary,
      ),
      timePickerTheme: const TimePickerThemeData(
        backgroundColor: ZitlasTokens.bgCard,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ZitlasTokens.bgCardLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ZitlasTokens.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ZitlasTokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: ZitlasTokens.primary),
        ),
        labelStyle: const TextStyle(color: ZitlasTokens.textSecondary),
        // textSecondary, not textMuted: muted (#8A968E) on the cream fill
        // (#F3F0E6) measures 2.7:1, below even the relaxed 3:1 bar for
        // secondary text — a placeholder nobody can read is the same bug in
        // a quieter register. Still clearly softer than the entered value,
        // which uses textPrimary.
        hintStyle: const TextStyle(color: ZitlasTokens.textSecondary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: ZitlasTokens.bgCard,
        selectedItemColor: ZitlasTokens.primary,
        unselectedItemColor: ZitlasTokens.textMuted,
        type: BottomNavigationBarType.fixed,
      ),
      dividerTheme: const DividerThemeData(color: ZitlasTokens.border),
    );
  }
}
