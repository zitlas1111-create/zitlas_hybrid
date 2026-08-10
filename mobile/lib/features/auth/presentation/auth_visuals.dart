import 'package:flutter/material.dart';

/// Visual tokens for the login/auth pages — mirrors the semantic design system
/// from `ZitlasTokens.dart` and `theme.css`. The login pages use a light
/// "glassmorphism landing page" aesthetic that is intentionally distinct from
/// the in-app theme and dark splash/loading. Field names (`orange`, `orange2`)
/// are kept for backward compatibility despite now holding green values.
abstract final class AuthColors {
  static const bg = Color(0xFFF7F3EA); // --z-bg
  static const ink = Color(0xFF101828); // --z-ink
  static const muted = Color(0xFF667085); // --z-muted
  static const cardGlass = Color(0xB8FFFFFF); // --z-card: rgba(255,255,255,.72)
  static const cardSolid = Color(0xFFFFFFFF); // --z-card-solid
  static const border = Color(0x1A111827); // --z-border: rgba(17,24,39,.10)

  // Primary ZITLAS green — brand actions, buttons
  static const orange = Color(0xFF234B35); // semantic: primary green (field name kept for compat)
  static const orange2 = Color(0xFF2E5F47); // semantic: primary green hover

  // Semantic accents
  static const green = Color(0xFF22C55E); // success
  static const purple = Color(0xFF6B5878); // AI/intelligence
  static const cyan = Color(0xFF6B5878); // backward compat alias (now purple)

  // Error and input states
  static const errorBorder = Color(0x99EF4444); // .input-error border
  static const btnLoginText = Color(0xFF101010); // .btn-login color
  static const inputFill = Color(0xA6FFFFFF); // rgba(255,255,255,.65)
  static const inputFillFocus = Color(0xE6FFFFFF); // rgba(255,255,255,.9)
  static const roleTrackBg = Color(0x0D111827); // rgba(17,24,39,.05)
  static const overlayBg = Color(0xEBF7F3EA); // rgba(247,243,234,.92)
}

// --radius-xl / --radius-lg / --radius-md
const double kAuthRadiusXl = 34;
const double kAuthRadiusLg = 26;
const double kAuthRadiusMd = 18;

/// Login card shadow — semantic green glow using primary ZITLAS green.
const List<BoxShadow> kAuthCardShadow = [
  BoxShadow(color: Color(0x1F101828), blurRadius: 80, offset: Offset(0, 24)),
  BoxShadow(color: Color(0x17234B35), blurRadius: 60), // primary green
];

/// Login button glow — semantic primary green ambient effect.
const List<BoxShadow> kAuthButtonGlow = [
  BoxShadow(color: Color(0x3D234B35), blurRadius: 46),
];
