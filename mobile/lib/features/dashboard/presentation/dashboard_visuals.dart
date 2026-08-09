import 'dart:ui';

import 'package:flutter/material.dart';

/// Visual tokens ported from the CURRENT
/// `frontend/website/assets/css/theme.css` — this is the shared theme for
/// the whole authenticated app (dashboard, diet, training, experts,
/// profile), and it is a LIGHT theme (`--bg-primary: #F7FAF5`). This does
/// NOT match `COLOR_GUIDELINES.md` / the app's existing `ZitlasColors`
/// (which are dark and were built from that now-stale doc, not from
/// theme.css directly) — theme.css is the real, current, authoritative
/// source, confirmed by direct file read. Scoped to the dashboard feature
/// only, same pattern as `AuthColors` for the login flow — this
/// intentionally does not touch the global dark `ZitlasTheme` used by the
/// splash/loading surfaces.
///
/// REBRAND (orange -> green, matches the green ZITLAS logo): brand accent
/// was orange (`#FF9800` family); now ZITLAS green (`#16A34A` family).
/// `aiAccent` (cyan) and `error` (red) are semantic, not brand, and UNCHANGED.
abstract final class DashboardColors {
  static const bgStart = Color(0xFFF7FAF5);
  static const bgEnd = Color(0xFFF0FDF4);
  static const bgCard = Color(0xFFFFFFFF);
  static const bgCardLight = Color(0xFFF0FDF4);

  static const primary = Color(0xFF16A34A);
  static const primaryHover = Color(0xFF15803D);
  static const primaryDark = Color(0xFF14532D);

  static const success = Color(0xFF16A34A);
  static const successDark = Color(0xFF14532D);
  static const aiAccent = Color(0xFF0E9BB5);

  static const textPrimary = Color(0xFF17221A);
  static const textSecondary = Color(0xFF647267);
  /// Capped to keep >=4.5:1 contrast on white — see zitlas_tokens.dart's
  /// textMuted for the same fix and reasoning.
  static const textMuted = Color(0xFF657168);

  static const border = Color(0xFFE3EAE4);
  static const borderSub = Color(0x14172A1A); // rgba(23,34,26,0.08)-ish divider

  static const error = Color(0xFFFF3B30);

  /// The frosted "premium card" recipe from theme.css
  /// (`.zitlas-premium-bg .goal-card, .qs-card, ...`) — wins visually over
  /// dashboard.css's own plainer local card style per CSS specificity, so
  /// this is the real card look, not dashboard.css's un-overridden rules.
  static const cardGlass = Color(0xC7FFFFFF); // rgba(255,255,255,0.78)
}

const double kDashboardRadiusLg = 28; // theme.css premium-card radius
const double kDashboardRadiusMd = 18; // dashboard.css local --radius
const double kDashboardRadiusSm = 14;

/// theme.css: `box-shadow: 0 15px 40px rgba(22,163,74,.10), 0 8px 20px rgba(20,83,45,.08)`
/// (+ extra `0 0 30px rgba(57,255,20,.10)` energy-green glow on hero cards,
/// applied here too since touch devices don't get the CSS `:hover` variant
/// to fall back to).
const List<BoxShadow> kDashboardCardShadow = [
  BoxShadow(color: Color(0x1A16A34A), blurRadius: 40, offset: Offset(0, 15)),
  BoxShadow(color: Color(0x1414532D), blurRadius: 20, offset: Offset(0, 8)),
  BoxShadow(color: Color(0x1A39FF14), blurRadius: 30),
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
