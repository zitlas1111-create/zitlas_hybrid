import 'dart:ui';

import 'package:flutter/material.dart';

/// Shared ZITLAS design tokens ported from the CURRENT
/// `frontend/website/assets/css/theme.css` — the single stylesheet every
/// authenticated page loads (athlete dashboard, expert dashboard, diet,
/// training, experts, profile). It is a LIGHT theme (`--bg-primary:
/// #F7FAF5`), which is why both dashboards render light even though the
/// app's global Flutter `ZitlasTheme` (built earlier from the now-stale
/// `COLOR_GUIDELINES.md`) is dark.
///
/// REBRAND (orange -> green, matches the green ZITLAS logo): the brand
/// accent was orange (`#FF9800` family). It is now ZITLAS green (`#16A34A`
/// family). Non-brand semantics — `danger` (red) and `aiAccent` (cyan) —
/// are UNCHANGED; this is a brand-color swap, not a "make everything green"
/// pass. Kept numerically identical to `theme.css` so the two dashboards
/// (and the web pages the WebView loads) can't visually drift apart.
abstract final class ZitlasTokens {
  static const bgStart = Color(0xFFF7FAF5);
  static const bgEnd = Color(0xFFF0FDF4);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCardLight = Color(0xFFF0FDF4);

  /// Primary ZITLAS green — the main brand/action color.
  static const primary = Color(0xFF16A34A);
  static const primaryHover = Color(0xFF15803D);
  static const primaryDark = Color(0xFF14532D);

  /// Brand energy green — sparingly: glow/highlight accents only, never
  /// large text or fills (contrast is too low on white for body content).
  static const brandEnergy = Color(0xFF39FF14);

  /// Converged with the ZITLAS green family per the brand system (was a
  /// separate olive-green) — one coherent green, not two.
  static const success = Color(0xFF16A34A);
  static const successDark = Color(0xFF14532D);
  static const aiAccent = Color(0xFF0E9BB5);

  static const textPrimary = Color(0xFF17221A);
  static const textSecondary = Color(0xFF647267);
  /// Derived from [textSecondary], capped to keep >=4.5:1 contrast on white
  /// — a straight proportional lighten (as the old palette's secondary->muted
  /// step used) lands at ~2.7:1, which fails WCAG AA for text.
  static const textMuted = Color(0xFF657168);

  static const border = Color(0xFFE3EAE4);
  static const borderSub = Color(0x14172A1A); // rgba(23,34,26,0.08)

  /// `#E5484D` — the exact red the expert dashboard uses for its
  /// notification dot and destructive actions. UNCHANGED — semantic, not brand.
  static const danger = Color(0xFFE5484D);

  /// `rgba(255,255,255,0.78)` frosted premium-card fill.
  static const cardGlass = Color(0xC7FFFFFF);
}

const double kZitlasRadiusLg = 28;
const double kZitlasRadiusMd = 18;
const double kZitlasRadiusSm = 14;

/// theme.css premium-card shadow recipe — both layers are green now (was
/// green + orange); depth comes from primary-green + dark-green instead.
const List<BoxShadow> kZitlasCardShadow = [
  BoxShadow(color: Color(0x1A16A34A), blurRadius: 40, offset: Offset(0, 15)),
  BoxShadow(color: Color(0x1414532D), blurRadius: 20, offset: Offset(0, 8)),
  BoxShadow(color: Color(0x1A39FF14), blurRadius: 30),
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
