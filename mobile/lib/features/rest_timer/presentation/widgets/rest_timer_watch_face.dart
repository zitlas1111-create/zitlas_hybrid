import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../rest_timer_colors.dart';

/// The premium smartwatch-style dial: stable bezel, tick marks, a progress
/// ring, and the countdown digits, all in one widget.
///
/// PERFORMANCE (§38, and the same discipline `ZitlasLoadingRing` already
/// follows): the bezel/ticks are STATIC — painted once and never touched by
/// the animation — and the only things that repaint every frame are the
/// progress arc and the breathing glow, both isolated inside their own
/// [RepaintBoundary]. The digits are plain [Text], rebuilt once per second
/// by the parent (driven by [RestTimerController]'s ticker), not every
/// animation frame.
///
/// Deliberately not a literal copy of any commercial watch face (per the
/// brief) — this is ZITLAS's own bezel/tick/ring construction, sized and
/// colored from the app's own tokens.
class RestTimerWatchFace extends StatefulWidget {
  const RestTimerWatchFace({
    super.key,
    required this.progress,
    required this.remainingLabel,
    required this.statusLabel,
    required this.color,
    required this.isPaused,
    required this.isCompleted,
    required this.isUrgent,
    this.isAlarming = false,
    this.size = 300,
  });

  /// 1.0 (full ring) -> 0.0 (empty), already smoothed by the caller (see
  /// [RestTimerScreen], which wraps this in a `TweenAnimationBuilder` so the
  /// ring eases between values instead of jumping once a second).
  final double progress;

  /// Pre-formatted `MM:SS`.
  final String remainingLabel;

  /// "RUNNING" / "PAUSED" / "REST COMPLETE" / "READY" — text, not just
  /// color, communicates state (accessibility §34).
  final String statusLabel;

  /// The current dynamic color (percentage band, paused-orange, or the
  /// completed deep-green) — computed by the caller via [RestTimerColors]
  /// so this widget stays a pure renderer.
  final Color color;

  final bool isPaused;
  final bool isCompleted;

  /// Final 10–15 seconds (§18) — adds a gentle pulse. Independent of which
  /// percentage color band is active; a 20-minute timer's coral band and its
  /// urgency window do not coincide, by design.
  final bool isUrgent;

  /// The alarm is actively ringing. Keeps the Deep Green + Warm Yellow
  /// completed identity (spec §6) as the solid ring/tip color — only the
  /// soft glow behind it gets a subtle Coral tint, and pulses a little more
  /// noticeably than the plain idle breathing glow. Never the aggressive
  /// full-screen-red or flashing effect the spec explicitly rules out.
  final bool isAlarming;

  final double size;

  @override
  State<RestTimerWatchFace> createState() => _RestTimerWatchFaceState();
}

class _RestTimerWatchFaceState extends State<RestTimerWatchFace> with SingleTickerProviderStateMixin {
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    // One continuous slow cycle drives BOTH the idle "breathing" glow and the
    // final-seconds pulse (faster-reading via the widened amplitude in
    // paint, not a second controller) — a single ticker, per §38.
    _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat();
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.size;
    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Static bezel + ticks + track — painted once, never rebuilt by
          // the animation below.
          RepaintBoundary(
            child: CustomPaint(
              size: Size.square(box),
              painter: _BezelPainter(),
            ),
          ),
          // Breathing glow + progress ring — the only per-frame repaint.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _breath,
              builder: (context, _) => CustomPaint(
                size: Size.square(box),
                painter: _RingPainter(
                  progress: widget.progress,
                  color: widget.color,
                  breath: _breath.value,
                  paused: widget.isPaused,
                  urgent: widget.isUrgent && !widget.isCompleted,
                  alarming: widget.isAlarming,
                ),
              ),
            ),
          ),
          // Center content — the countdown itself, updated once per second
          // by the parent, not by this widget's own ticker.
          _CenterContent(
            remainingLabel: widget.remainingLabel,
            statusLabel: widget.statusLabel,
            color: widget.color,
            isCompleted: widget.isCompleted,
          ),
        ],
      ),
    );
  }
}

class _CenterContent extends StatelessWidget {
  const _CenterContent({
    required this.remainingLabel,
    required this.statusLabel,
    required this.color,
    required this.isCompleted,
  });

  final String remainingLabel;
  final String statusLabel;
  final Color color;
  final bool isCompleted;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isCompleted ? Icons.check_circle_rounded : Icons.notifications_active_rounded,
          size: 22,
          color: isCompleted ? RestTimerColors.completedAccent : color,
        ),
        const SizedBox(height: 6),
        Text(
          remainingLabel,
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w800,
            color: ZitlasTokens.textPrimary,
            letterSpacing: 1,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          statusLabel,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// The stable part of the dial: outer bezel with a soft metallic-feeling
/// gradient (built from ZITLAS's own cream/charcoal tones, never pure black),
/// 60 minute ticks (5 major, 55 minor), and the background track the
/// progress arc sits on. Painted once — see the class doc above.
class _BezelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    // Outer bezel — a subtle light-to-shadow sweep gives it dimensionality
    // without literally rendering a photographic metal texture.
    final bezelPaint = Paint()
      ..shader = SweepGradient(
        center: Alignment.center,
        startAngle: -math.pi / 2,
        endAngle: 3 * math.pi / 2,
        colors: const [
          Color(0xFFFFFFFF),
          Color(0xFFEDEAE0),
          Color(0xFFD9D4C6),
          Color(0xFFEDEAE0),
          Color(0xFFFFFFFF),
        ],
        stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, bezelPaint);

    // Depth shadow just inside the bezel rim.
    canvas.drawCircle(
      center,
      radius - 3,
      Paint()
        ..color = ZitlasTokens.textPrimary.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Face — the readable surface the digits and ticks sit on.
    final faceRadius = radius - 14;
    canvas.drawCircle(
      center,
      faceRadius,
      Paint()
        ..shader = RadialGradient(
          colors: const [Color(0xFFFFFFFF), ZitlasTokens.bgCardLight],
          stops: const [0.6, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: faceRadius)),
    );

    // Minute ticks — 60 marks, every 5th one longer/bolder, exactly like a
    // real watch dial. Purely decorative (no numerals), which is what keeps
    // this from reading as a generic circular progress indicator.
    const tickCount = 60;
    for (var i = 0; i < tickCount; i++) {
      final major = i % 5 == 0;
      final angle = (i / tickCount) * 2 * math.pi - math.pi / 2;
      final outer = faceRadius - 6;
      final inner = outer - (major ? 14 : 6);
      final p1 = center + Offset(math.cos(angle) * outer, math.sin(angle) * outer);
      final p2 = center + Offset(math.cos(angle) * inner, math.sin(angle) * inner);
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = ZitlasTokens.textPrimary.withValues(alpha: major ? 0.28 : 0.12)
          ..strokeWidth = major ? 2.4 : 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Progress TRACK — the pale channel the colored arc travels around.
    canvas.drawCircle(
      center,
      faceRadius - 26,
      Paint()
        ..color = ZitlasTokens.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10,
    );

    // A single small crown-style marker at 12 o'clock — a nod to a real
    // watch's crown/marker without inventing an operable control.
    final markerCenter = center + const Offset(0, 1) * 0.0 + Offset(0, -(radius - 6));
    canvas.drawCircle(markerCenter, 3.4, Paint()..color = ZitlasTokens.textMuted.withValues(alpha: 0.5));
  }

  @override
  bool shouldRepaint(covariant _BezelPainter oldDelegate) => false;
}

/// The animated part: the colored progress arc, its glow, a small tip
/// indicator (like a hand-tip riding the arc's end), and the paused/urgent
/// pulse. Repaints every animation frame — kept as cheap as possible (no
/// gradients recomputed per-frame beyond what `Paint` already caches).
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.breath,
    required this.paused,
    required this.urgent,
    required this.alarming,
  });

  final double progress;
  final Color color;

  /// 0..1, one full [_RestTimerWatchFaceState._breath] cycle.
  final double breath;
  final bool paused;
  final bool urgent;
  final bool alarming;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 14 - 26; // matches the bezel's track radius
    const strokeWidth = 10.0;

    // Breathing amplitude: gentle while idle/running, tighter and faster-
    // *reading* in the final seconds or while ringing (still the SAME cycle
    // length — the widened swing is what makes it read as more urgent, not a
    // shake). Alarming gets the same gentle amplitude as urgent, per spec
    // §6/§18: noticeable, never aggressive.
    final wave = math.sin(breath * 2 * math.pi);
    final glowAmplitude = paused ? 0.0 : ((urgent || alarming) ? 0.55 : 0.28);
    final glowAlpha = (0.16 + glowAmplitude * 0.14 * (wave * 0.5 + 0.5)).clamp(0.0, 0.35);

    // Soft glow behind the arc — the "premium depth" layer. Absent while
    // paused, per §10 ("animation becomes static/subdued"). While alarming,
    // the glow (ONLY the glow — the solid arc/tip below stay Deep Green)
    // takes a subtle Coral tint: spec §6 asks for "optionally a subtle
    // Coral accent to communicate the active alarm" without turning the
    // ring itself red, which would read as "almost finished" (§17), the
    // opposite of what a completed/ringing timer means.
    if (!paused) {
      final glowColor = alarming ? Color.lerp(color, ZitlasTokens.wellnessCoral, 0.30)! : color;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = glowColor.withValues(alpha: glowAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth + 14
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
      );
    }

    // The progress arc itself, starting at 12 o'clock, sweeping clockwise —
    // full circle at 100%, nothing at 0%.
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0.001) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );

      // Tip indicator — a small bright marker at the arc's leading edge,
      // like a hand-tip riding the ring. Skipped at 0% (nothing to tip) and
      // frozen in place while paused (no pulsing scale) so "paused" reads as
      // genuinely still, not just slower.
      final tipAngle = -math.pi / 2 + sweep;
      final tip = center + Offset(math.cos(tipAngle), math.sin(tipAngle)) * radius;
      final tipScale = paused ? 1.0 : (1.0 + (urgent ? 0.35 : 0.12) * (wave * 0.5 + 0.5));
      canvas.drawCircle(tip, (strokeWidth / 2 + 2) * tipScale, Paint()..color = Colors.white);
      canvas.drawCircle(tip, strokeWidth / 2.6 * tipScale, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.breath != breath ||
      oldDelegate.paused != paused ||
      oldDelegate.urgent != urgent ||
      oldDelegate.alarming != alarming;
}
