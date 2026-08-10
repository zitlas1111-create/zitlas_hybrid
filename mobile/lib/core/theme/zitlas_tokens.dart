import 'dart:ui';

import 'package:flutter/material.dart';

/// ZITLAS semantic design token system — paired with `frontend/website/assets/css/theme.css`.
/// Both platforms use identical token values to prevent visual drift across native and WebView.
///
/// COLOR SYSTEM PHILOSOPHY:
/// 60–70% white/cream foundation (content, cards, surfaces)
/// 15–20% green (health, nutrition, ZITLAS brand, progress)
/// 5–10% orange (fitness, training, energy, action)
/// 3–5% other functional accents (achievement yellow, hydration teal, AI purple, wellness coral)
///
/// Each color carries SEMANTIC meaning:
/// • Green = health, nutrition, brand, progress
/// • Orange = fitness, training, energy, action
/// • Yellow = achievement, milestone, reward
/// • Teal = hydration, recovery, water
/// • Purple = AI, Zino, intelligence
/// • Coral = mood, wellness, stress
/// • White/Cream = cleanliness, content, main UI
///
/// The result: a cohesive premium fitness + nutrition + AI platform that FEELS like one system.
abstract final class ZitlasTokens {
  // BACKGROUNDS — light foundation with subtle variety
  static const bgPrimary = Color(0xFFFAFAF7);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCardLight = Color(0xFFF3F0E6); // cream
  static const bgStart = Color(0xFFFAFAF7);
  static const bgEnd = Color(0xFFF3F0E6);

  // GREEN PALETTE — health, nutrition, ZITLAS brand
  /// Subtle wellness accent (cards, selections, backgrounds).
  static const sageGreen = Color(0xFFA8B79A);

  /// Primary ZITLAS Deep Green — brand identity, health, selected states.
  /// LOCKED PALETTE: #234B35
  static const primary = Color(0xFF234B35);
  static const primaryHover = Color(0xFF2E5F47);
  static const primaryDark = Color(0xFF1A3A2A);

  /// Fresh Green — LOCKED PALETTE: #4F9D69. Sits between Deep Green and Sage
  /// in the brand's own progression (e.g. the Rest Timer's percentage-based
  /// color band), distinct from `primaryHover` which is a UI-state tint of
  /// Deep Green, not an independent brand color.
  static const freshGreen = Color(0xFF4F9D69);

  /// One coherent green system — success states use primary.
  static const success = Color(0xFF234B35);
  static const successDark = Color(0xFF1A3A2A);

  // SEMANTIC FUNCTIONAL COLORS
  /// Fitness, training, energy, active workout, calories burned.
  static const fitnessOrange = Color(0xFFF28C28);

  /// Achievement, milestone, badge, reward, streak celebration.
  static const achievementYellow = Color(0xFFF4C95D);

  /// Hydration, recovery, water intake, health metrics.
  static const hydrationTeal = Color(0xFF3A8F8B);

  /// AI, Zino, intelligent recommendations, premium AI functionality.
  static const aiPurple = Color(0xFF6B5878);

  /// Mood, wellbeing, stress, emotional state.
  static const wellnessCoral = Color(0xFFE76F51);

  // Alias for compatibility (was cyan, now purple per new semantic system).
  static const aiAccent = Color(0xFF6B5878);

  // TYPOGRAPHY
  static const textPrimary = Color(0xFF17221A);
  static const textSecondary = Color(0xFF66716A);
  static const textMuted = Color(0xFF8A968E);

  // BORDERS & UTILITIES
  static const border = Color(0xFFE5EBE7);
  static const borderSub = Color(0x1417221A); // rgba(23,34,26,0.08)

  /// Error / destructive — semantic, not brand.
  static const danger = Color(0xFFE5484D);

  /// Frosted premium-card fill.
  static const cardGlass = Color(0xC7FFFFFF);
}

const double kZitlasRadiusLg = 28;
const double kZitlasRadiusMd = 18;
const double kZitlasRadiusSm = 14;

/// Premium-card shadow recipe using LOCKED Deep Green (#234B35).
const List<BoxShadow> kZitlasCardShadow = [
  BoxShadow(color: Color(0x15234B35), blurRadius: 40, offset: Offset(0, 15)), // Deep Green primary
  BoxShadow(color: Color(0x121A3A2A), blurRadius: 20, offset: Offset(0, 8)),  // Deep Green dark
];

/// Frosted-glass card — the shared visual identity of every dashboard
/// section on both the athlete and expert sides.
class ZitlasCard extends StatelessWidget {
  const ZitlasCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = kZitlasRadiusLg,
    this.margin,
    this.color = ZitlasTokens.cardGlass,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final EdgeInsets? margin;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: kZitlasCardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The `.zitlas-premium-bg` page background: `homebg.png` under a light
/// wash. Used as the root layer of both dashboards.
class ZitlasPremiumBackground extends StatelessWidget {
  const ZitlasPremiumBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/images/homebg.png', fit: BoxFit.cover),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ZitlasTokens.bgStart.withValues(alpha: 0.45),
                  ZitlasTokens.bgStart.withValues(alpha: 0.55),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
