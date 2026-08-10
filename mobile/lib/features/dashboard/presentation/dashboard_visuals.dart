import 'dart:ui';

import 'package:flutter/material.dart';

/// Dashboard visual tokens — mirrors `ZitlasTokens` and `theme.css` semantic system.
/// Scoped to the dashboard feature only, same pattern as `AuthColors` for the login flow.
/// This intentionally does not touch the global dark `ZitlasTheme` used by splash/loading.
///
/// SEMANTIC DESIGN SYSTEM:
/// All colors carry meaning — see ZitlasTokens.dart and theme.css for the full
/// semantic palette and the philosophy behind each color. This enables a cohesive
/// premium fitness + nutrition + AI platform that FEELS like one system.
abstract final class DashboardColors {
  // BACKGROUNDS — light foundation
  static const bgStart = Color(0xFFFAFAF7);
  static const bgEnd = Color(0xFFF3F0E6);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCardLight = Color(0xFFF3F0E6);

  // GREEN PALETTE — health, nutrition, ZITLAS brand
  static const sageGreen = Color(0xFFA8B79A);
  static const primary = Color(0xFF234B35);
  static const primaryHover = Color(0xFF2E5F47);
  static const primaryDark = Color(0xFF1A3A2A);

  static const success = Color(0xFF234B35);
  static const successDark = Color(0xFF1A3A2A);

  // SEMANTIC FUNCTIONAL COLORS
  static const fitnessOrange = Color(0xFFF28C28);
  static const achievementYellow = Color(0xFFF4C95D);
  static const hydrationTeal = Color(0xFF3A8F8B);
  static const aiPurple = Color(0xFF6B5878);
  static const wellnessCoral = Color(0xFFE76F51);

  static const aiAccent = Color(0xFF6B5878); // AI/Zino — purple

  static const textPrimary = Color(0xFF17221A);
  static const textSecondary = Color(0xFF66716A);
  static const textMuted = Color(0xFF8A968E);

  static const border = Color(0xFFE5EBE7);
  static const borderSub = Color(0x1417221A); // rgba(23,34,26,0.08) divider

  static const error = Color(0xFFE5484D);

  /// The frosted "premium card" recipe from theme.css
  /// (`.zitlas-premium-bg .goal-card, .qs-card, ...`) — wins visually over
  /// dashboard.css's own plainer local card style per CSS specificity, so
  /// this is the real card look, not dashboard.css's un-overridden rules.
  static const cardGlass = Color(0xC7FFFFFF); // rgba(255,255,255,0.78)
}

const double kDashboardRadiusLg = 28; // theme.css premium-card radius
const double kDashboardRadiusMd = 18; // dashboard.css local --radius
const double kDashboardRadiusSm = 14;

/// Premium-card shadow recipe using semantic ZITLAS green system.
const List<BoxShadow> kDashboardCardShadow = [
  BoxShadow(color: Color(0x15234B35), blurRadius: 40, offset: Offset(0, 15)), // primary green
  BoxShadow(color: Color(0x121A3A2A), blurRadius: 20, offset: Offset(0, 8)),  // dark green
];

/// Frosted-glass card wrapper — the real visual identity of every dashboard
/// section (goal card, SWOT, quick stats, etc.) per theme.css's shared
/// premium-card recipe over the `homebg.png` photo background.
class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = kDashboardRadiusLg,
    this.margin,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: kDashboardCardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: DashboardColors.cardGlass,
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
