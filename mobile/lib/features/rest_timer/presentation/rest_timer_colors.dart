import 'package:flutter/material.dart';

import '../../../core/theme/zitlas_tokens.dart';

/// The Rest Timer's percentage-based color progression (spec §8–9).
///
/// Deliberately a function of `remaining / total`, never of absolute
/// seconds — the whole point is that a 1-minute timer and a 20-minute timer
/// pass through the SAME visual bands at the SAME percentages, just at
/// different real-world speeds. `activeColor()` interpolates continuously
/// across each 20pp-wide band edge (percentage points) rather than switching
/// abruptly at the boundary, per §8's "must transition smoothly" / "do NOT
/// abruptly switch colors".
abstract final class RestTimerColors {
  /// Paused — a fixed color, not a point on the percentage gradient, so it
  /// reads as a distinct STATE rather than "wherever the countdown happened
  /// to be when paused" (spec §10).
  static const paused = ZitlasTokens.fitnessOrange; // Tangerine #F28C28

  /// Completed — Deep Green with a Warm Yellow celebration accent (§17).
  /// Never Coral after completion: Coral means "almost finished", not "done".
  static const completedPrimary = ZitlasTokens.primary; // #234B35
  static const completedAccent = ZitlasTokens.achievementYellow; // #F4C95D

  // The six named stops, in the order the countdown actually passes through
  // them (100% -> 0%).
  static const _deepGreen = ZitlasTokens.primary; // #234B35
  static const _freshGreen = ZitlasTokens.freshGreen; // #4F9D69
  static const _sage = ZitlasTokens.sageGreen; // #A8B79A
  static const _warmYellow = ZitlasTokens.achievementYellow; // #F4C95D
  static const _tangerine = ZitlasTokens.fitnessOrange; // #F28C28
  static const _coral = ZitlasTokens.wellnessCoral; // #E76F51

  /// `progress` is 1.0 at full duration, 0.0 at zero (matches
  /// `RestTimerController.progress`). Bands, per spec §8:
  ///   100–70%  Deep Green  -> Fresh Green
  ///    70–50%  Fresh Green -> Sage
  ///    50–30%  Sage        -> Warm Yellow
  ///    30–15%  Warm Yellow -> Tangerine
  ///    15–5%   Tangerine   -> Coral
  ///     5–0%   Coral (held — there is nothing past it on the gradient)
  static Color activeColor(double progress) {
    final p = progress.clamp(0.0, 1.0);
    if (p >= 0.70) {
      return Color.lerp(_freshGreen, _deepGreen, _bandT(p, 0.70, 1.00))!;
    }
    if (p >= 0.50) {
      return Color.lerp(_sage, _freshGreen, _bandT(p, 0.50, 0.70))!;
    }
    if (p >= 0.30) {
      return Color.lerp(_warmYellow, _sage, _bandT(p, 0.30, 0.50))!;
    }
    if (p >= 0.15) {
      return Color.lerp(_tangerine, _warmYellow, _bandT(p, 0.15, 0.30))!;
    }
    if (p >= 0.05) {
      return Color.lerp(_coral, _tangerine, _bandT(p, 0.05, 0.15))!;
    }
    return _coral;
  }

  /// Where `p` sits between `lo` and `hi`, as 0..1 — the interpolation
  /// fraction for [Color.lerp] within one band.
  static double _bandT(double p, double lo, double hi) => ((p - lo) / (hi - lo)).clamp(0.0, 1.0);
}
