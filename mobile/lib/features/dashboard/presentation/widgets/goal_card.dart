import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../../core/utils/safe_image.dart';
import '../../dashboard_controller.dart';
import '../dashboard_visuals.dart';

/// `.goal-card` / `renderGoalCard()` — the Current Goal hero card. Ring
/// math, days-left wording, and date formatting all match dashboard.js
/// exactly (`CIRCUMFERENCE = 188.496`, `en-IN` `d MMM y` dates).
class GoalCard extends StatelessWidget {
  const GoalCard({super.key});

  static const _circumference = 188.496;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DashboardController>();
    final goal = controller.goal;
    final dateFmt = DateFormat('d MMM y');

    final pct = goal?.progressPercent ?? 0;
    final title = goal?.displayName ?? 'No goal set yet.';
    final current = goal != null ? _fmtNum(goal.currentVal) : '—';
    final target = goal != null ? _fmtNum(goal.targetVal) : '—';
    final labelA = goal != null ? 'Current ${goal.unit}' : 'Current';
    final labelB = goal != null ? 'Target ${goal.unit}' : 'Target';
    final startDate = goal != null ? dateFmt.format(goal.startDate) : '—';
    final endDate = goal != null ? dateFmt.format(goal.endDate) : '—';

    String daysLeftText;
    if (goal == null) {
      daysLeftText = 'Set a goal to begin';
    } else {
      final days = goal.daysLeft;
      daysLeftText = days == 0 ? 'Goal ends today!' : '$days Days Left';
    }

    return DashboardCard(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'CURRENT GOAL',
                            style: TextStyle(
                              color: DashboardColors.primary,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        _GoalActionButton(hasGoal: goal != null),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DashboardColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _GoalRing(pct: pct, circumference: _circumference),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _StatRow(label: labelA, value: current),
                              const SizedBox(height: 4),
                              _StatRow(label: labelB, value: target, accent: true),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0x1FFF9800),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: const Color(0x40FF9800)),
                                ),
                                child: Text(
                                  '⏳ $daysLeftText',
                                  style: const TextStyle(
                                    color: DashboardColors.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.only(top: 4),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: DashboardColors.borderSub)),
                      ),
                      child: Row(
                        children: [
                          _DateBlock(label: 'STARTED', value: startDate),
                          const Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: DashboardColors.textMuted,
                          ),
                          _DateBlock(label: 'ENDS', value: endDate, alignEnd: true),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _GoalPlayerPanel(
              photoUrl: controller.photoUrl,
              initials: _initialsOf(controller.displayName),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtNum(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// `getUserInitials()` — first letters of the first two name words,
  /// uppercased; `'ZT'` when no name is known.
  static String _initialsOf(String? name) {
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) return 'ZT';
    final words = trimmed.split(RegExp(r'\s+')).take(2);
    final letters = words.map((w) => w.isEmpty ? '' : w[0]).join().toUpperCase();
    return letters.isEmpty ? 'ZT' : letters;
  }
}

/// `.goal-player-panel` + `applyProfileImages()`'s goal-card branch: the
/// athlete's own photo filling the panel, falling back to large translucent
/// initials — never a generic stock icon.
class _GoalPlayerPanel extends StatelessWidget {
  const _GoalPlayerPanel({required this.photoUrl, required this.initials});

  final String? photoUrl;
  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 90,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DashboardColors.primary.withValues(alpha: 0.06),
            DashboardColors.primary.withValues(alpha: 0.2),
          ],
        ),
      ),
      child: !isNetworkImageUrl(photoUrl)
          ? Center(child: _Initials(initials))
          : Image.network(
              photoUrl!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              // `img.onerror` on the website falls back to the same initials.
              errorBuilder: (_, _, _) => Center(child: _Initials(initials)),
            ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        color: DashboardColors.primary.withValues(alpha: 0.5),
      ),
    );
  }
}

class _GoalActionButton extends StatelessWidget {
  const _GoalActionButton({required this.hasGoal});
  final bool hasGoal;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Set Goal / Reset Goal are BOTH entry points to a fresh Assessment —
      // the goal is derived from the assessment, so a manual goal form or a
      // pre-emptive wipe were both wrong doors.
      //
      // Nothing is cleared here on purpose. The previous Reset flow called
      // DashboardController.resetGoal() BEFORE pushing the wizard, so an
      // athlete who opened it and backed out had already lost their goal and
      // plan. AssessmentRepository.saveAssessmentResult() writes the new
      // `goal` in the same merge as the new plan, and only after generation
      // succeeds — so the existing goal now survives an abandoned run and is
      // replaced at exactly the moment a new one exists.
      //
      // Freshness needs no reset call either: /assessment builds a new
      // ChangeNotifierProvider<AssessmentController> per push (keyed by uid),
      // and that controller starts at screen=welcome with answers={} and
      // index=0, so every entry is already a clean session for the
      // authenticated user.
      onTap: () => context.push('/assessment'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          gradient: hasGoal
              ? null
              : const LinearGradient(
                  colors: [DashboardColors.primary, DashboardColors.primaryHover],
                ),
          color: hasGoal ? DashboardColors.bgCardLight : null,
          border: hasGoal ? Border.all(color: DashboardColors.border) : null,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          hasGoal ? '🔄 Reset Goal' : '🎯 Set Goal',
          style: TextStyle(
            color: hasGoal ? DashboardColors.textPrimary : Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _GoalRing extends StatelessWidget {
  const _GoalRing({required this.pct, required this.circumference});
  final int pct;
  final double circumference;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 68,
      height: 68,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: pct / 100),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) {
              return CustomPaint(
                size: const Size(68, 68),
                painter: _RingPainter(progress: value, circumference: circumference),
              );
            },
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pct%',
                style: const TextStyle(
                  color: DashboardColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Text(
                'COMPLETE',
                style: TextStyle(
                  color: DashboardColors.textMuted,
                  fontSize: 7.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.circumference});
  final double progress;
  final double circumference;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const strokeWidth = 7.0;
    final radius = (size.width - strokeWidth) / 2;

    final track = Paint()
      ..color = DashboardColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);

    final fill = Paint()
      ..shader = LinearGradient(
        colors: [DashboardColors.hydrationTeal, DashboardColors.hydrationTeal.withValues(alpha: 0.7)],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final sweep = 2 * 3.14159265359 * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159265359 / 2,
      sweep,
      false,
      fill,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.accent = false});
  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: DashboardColors.textMuted,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: accent ? DashboardColors.hydrationTeal : DashboardColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _DateBlock extends StatelessWidget {
  const _DateBlock({required this.label, required this.value, this.alignEnd = false});
  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: DashboardColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: DashboardColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
