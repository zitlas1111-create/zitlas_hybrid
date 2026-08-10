import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The ZITLAS loading composition: the `lodo.png` badge sitting still, with a
/// neon-green arc sweeping around it.
///
/// The asset is drawn EXACTLY as shipped — never rotated, recoloured or
/// transformed. Only the arc animates, so the runner stays upright and stable
/// while the ring moves.
///
/// `lodo.png` is a landscape image whose meaningful content is a centred
/// circular badge, with decorative light streaks running off to the left and
/// right. It is therefore clipped to a circle ([ClipOval] + [BoxFit.cover]),
/// which keeps the runner and its own glow and crops the streaks, leaving a
/// clean disc for the animated arc to orbit.
///
/// The disc's edge used to be invisible because it sat on a solid black
/// background. The WebView hand-off now shows the previous Flutter screen
/// blurred and dimmed behind it instead (see `_TransitionScrim`), so the disc
/// reads as a deliberate badge on that backdrop rather than as an invisible
/// crop. Nothing here changed for that — the asset is still drawn exactly as
/// shipped, opaque and with no blend mode, which is why it stays the brightest,
/// sharpest element on any background.
///
/// PERFORMANCE: one [AnimationController] drives every layer (rotation, sweep
/// length and the pulse), so there is a single ticker. The [AnimatedBuilder]
/// wraps ONLY the painter — the image is built once and never rebuilt — and the
/// painter sits inside a [RepaintBoundary], so each frame repaints just the
/// ring, not the surrounding tree (or the WebView behind it).
class ZitlasLoadingRing extends StatefulWidget {
  const ZitlasLoadingRing({super.key, this.size = 168});

  /// Diameter of the badge. The arc is drawn in a slightly larger box around
  /// it, so the widget's own footprint is [size] * [_ringScale].
  final double size;

  static const _ringScale = 1.28;

  @override
  State<ZitlasLoadingRing> createState() => _ZitlasLoadingRingState();
}

class _ZitlasLoadingRingState extends State<ZitlasLoadingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 1.5s per revolution: fast enough to read as active, slow enough to look
    // deliberate rather than frantic.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    // Stops the ticker and frees it — no leak when the overlay is removed.
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final badge = widget.size;
    final box = badge * ZitlasLoadingRing._ringScale;

    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The moving arc + glow. Painted UNDER the badge so the glow bleeds
          // outward rather than across the runner.
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _RingPainter(_controller.value),
                ),
              ),
            ),
          ),
          // lodo.png — stationary, unrotated, unmodified.
          SizedBox(
            width: badge,
            height: badge,
            child: ClipOval(
              child: Image.asset(
                'assets/images/lodo.png',
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                // If the asset were ever missing the ring still animates, so
                // the screen never shows a broken-image box.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the neon track, the sweeping highlight, its glow, and a subtle pulse.
class _RingPainter extends CustomPainter {
  const _RingPainter(this.t);

  /// Controller value, 0..1, one full revolution per cycle.
  final double t;

  // Brand green (ZitlasColors.success, "health/progress") for the track, with a
  // brighter neon tip so the moving head reads as the active edge.
  static const _track = Color(0xFF22C55E);
  static const _neon = Color(0xFF6EF83A);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // Stroke scales with the widget so the ring looks identical on a small
    // phone and a tablet — nothing here is a fixed pixel offset.
    final stroke = size.shortestSide * 0.035;
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final twoPi = math.pi * 2;
    final rotation = t * twoPi;

    // Sweep length breathes between ~55° and ~130° so the highlight feels like
    // progress rather than a rigid segment spinning at constant length.
    final breathe = (math.sin(t * twoPi) + 1) / 2; // 0..1, seamless at the wrap
    final sweep = (55 + 75 * breathe) * math.pi / 180;
    // Start angle offset by the sweep so the LEADING edge is what advances.
    final start = rotation - math.pi / 2;

    // 1. Very subtle pulse behind everything. Deliberately faint (max ~7%
    //    alpha) — the brief asked for barely-there, not flashy.
    final pulse = 0.03 + 0.04 * breathe;
    canvas.drawCircle(
      center,
      radius * (1.02 + 0.03 * breathe),
      Paint()
        ..color = _track.withValues(alpha: pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 3),
    );

    // 2. Full faint track, so the ring reads as a complete circle even where
    //    the highlight is not.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.55
        ..color = _track.withValues(alpha: 0.16),
    );

    // 3. Glow under the highlight — same arc, blurred and wider.
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke * 2.1
        ..color = _neon.withValues(alpha: 0.30)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 1.5),
    );

    // 4. The highlight itself, fading from transparent at the tail to full neon
    //    at the head via a SweepGradient rotated with the arc — this is what
    //    makes the bright section appear to travel around the circle.
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: sweep,
          transform: GradientRotation(start),
          colors: [
            _track.withValues(alpha: 0.0),
            _track.withValues(alpha: 0.85),
            _neon,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rect),
    );

    // 5. A small bright head at the leading edge — the detail that sells the
    //    "premium" feel and makes direction of travel obvious.
    final headAngle = start + sweep;
    final head = center + Offset(math.cos(headAngle), math.sin(headAngle)) * radius;
    canvas.drawCircle(
      head,
      stroke * 0.62,
      Paint()..color = _neon,
    );
    canvas.drawCircle(
      head,
      stroke * 1.5,
      Paint()
        ..color = _neon.withValues(alpha: 0.45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 1.2),
    );
  }

  // Repaints only when the animation actually advanced.
  @override
  bool shouldRepaint(_RingPainter oldDelegate) => oldDelegate.t != t;
}
