import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../tour/zino_tour_stops.dart';

/// `.zn-fab` (`frontend/assets/css/zino.css:136-168`) — the permanent Zino
/// launcher, ported pixel-for-pixel in intent.
///
/// POSITION IS DELIBERATE: the website pins this **top-right**
/// (`top: calc(78px + env(safe-area-inset-top)); right: 16px`), NOT as a
/// bottom-right material FAB. That's part of the ZITLAS design, so it is
/// preserved here rather than "corrected" to the usual Android convention —
/// see [ZinoFabOverlay], which owns the positioning.
///
/// APPEARANCE: a white circle with a 2.5px `#FF9900` border carrying the
/// Zino avatar, plus the `znPulse` ring that continuously scales 0.9 → 1.35
/// while fading out. The pulse is what makes Zino read as *present and
/// waiting* rather than as one more toolbar icon.
class ZinoFab extends StatefulWidget {
  const ZinoFab({super.key, required this.onTap, this.showBadge = false});

  final VoidCallback onTap;

  /// `.zn-fab-badge` — the unread dot. Hidden by default (`display: none`),
  /// exactly like the website.
  final bool showBadge;

  /// `.zn-fab { width: 52px; height: 52px }`
  static const double diameter = 52;

  /// `top: calc(78px + env(safe-area-inset-top))` — clears the page header so
  /// the button never sits on top of a title or the notification bell.
  static const double topOffset = 78;

  /// `right: 16px`
  static const double rightOffset = 16;

  @override
  State<ZinoFab> createState() => _ZinoFabState();
}

class _ZinoFabState extends State<ZinoFab> with SingleTickerProviderStateMixin {
  // `animation: znPulse 2.6s ease-out infinite`
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        // Sized generously so the expanding pulse ring isn't clipped —
        // `inset: -6px` plus a 1.35 scale reaches beyond the button itself.
        width: ZinoFab.diameter + 24,
        height: ZinoFab.diameter + 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // `.zn-fab::after` — the outward pulse. Non-interactive so it can
            // never swallow a tap meant for the button.
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  final t = _pulse.value;
                  // 0% scale .9 / opacity .9 → 70% scale 1.35 / opacity 0.
                  final progress = (t / 0.7).clamp(0.0, 1.0);
                  final scale = 0.9 + (1.35 - 0.9) * progress;
                  final opacity = t >= 0.7 ? 0.0 : (0.9 * (1 - progress));
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: ZinoFab.diameter + 12, // inset: -6px on each side
                      height: ZinoFab.diameter + 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          // rgba(255,153,0,0.55)
                          color: const Color(0xFF16A34A).withValues(alpha: 0.55 * opacity),
                          width: 2,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              width: ZinoFab.diameter,
              height: ZinoFab.diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: const Color(0xFF16A34A), width: 2.5),
                boxShadow: [
                  // 0 8px 22px rgba(255,122,0,0.32)
                  BoxShadow(
                    color: const Color(0xFFFF7A00).withValues(alpha: 0.32),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipOval(
                child: Image.asset(
                  'assets/images/zino.png',
                  fit: BoxFit.cover,
                  // A missing asset must still leave a tappable, recognisable
                  // control rather than a broken-image box.
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.auto_awesome,
                    color: ZitlasTokens.primary,
                    size: 24,
                  ),
                ),
              ),
            ),
            if (widget.showBadge)
              Positioned(
                // top: -3px; right: -3px relative to the 52px button
                top: 12 - 3,
                right: 12 - 3,
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE5484D),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Pins [ZinoFab] to the TOP-RIGHT of whatever it wraps.
///
/// Applied once in `AppShell` so every main screen gets Zino in the same
/// place — the website mounts its FAB on every page, and consistency is what
/// makes "always one tap away" true rather than a claim.
///
/// `SafeArea(bottom: false)` reproduces `env(safe-area-inset-top)`: the offset
/// is measured from BELOW the status bar / notch, so Zino never sits under a
/// cutout on a device like the OnePlus.
class ZinoFabOverlay extends StatelessWidget {
  const ZinoFabOverlay({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          right: ZinoFab.rightOffset,
          child: SafeArea(
            bottom: false,
            child: Padding(
              // -12 cancels the pulse-ring padding baked into ZinoFab's box,
              // so the visible circle lands exactly at the CSS offset.
              padding: const EdgeInsets.only(top: ZinoFab.topOffset - 12),
              // Keyed so the walkthrough's "And I'll always be right here 👋"
              // stop can spotlight the real launcher.
              child: KeyedSubtree(
                key: ZinoTourKeys.zinoFab,
                child: ZinoFab(onTap: onTap),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
