import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../core/steps/presentation/step_consent_sheet.dart';
import '../../../../core/steps/step_metrics.dart';
import '../../../../core/steps/step_tracking_service.dart';
import '../../dashboard_controller.dart';
import '../../models/activity_week.dart';
import '../dashboard_visuals.dart';
import 'section_header.dart';

/// `#stepCounterSection` / `renderStepCounterCard()` (the `.sac-*` classes).
/// Reads real `users/{uid}/activity/{today}` data — for accounts with no
/// native step source wired up yet this is honestly 0/goal, matching the
/// same status-message logic the website uses for a real zero rather than
/// inventing placeholder numbers.
///
/// The native Health Connect / step-sensor plugin itself is still not ported
/// (its Capacitor implementation was removed when this repo became a Flutter
/// project — see the Phase 1 migration inventory), so on-device step *capture*
/// is the one remaining deferred piece; everything this card renders on top of
/// the day doc — Recovery Mode, the Mon–Sun strip, the adaptive-goal
/// suggestion and all four status messages — is now at parity.
class ActivityCard extends StatelessWidget {
  const ActivityCard({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DashboardController>();
    final activity = controller.todayActivity;
    final snapshot = controller.stepSnapshot;

    // Live device reading wins over the synced day doc — it's the fresher of
    // the two by definition (the doc is written FROM it). Falling back to the
    // doc keeps the last known count on screen while a read is in flight and
    // covers a second device that synced steps for the same day.
    final steps = snapshot?.isAvailable == true
        ? snapshot!.steps
        : (activity?.steps ?? 0);
    final baseGoal = activity?.goal ?? controller.effectiveStepGoal;
    final goal = controller.effectiveStepGoal;
    final restDay = activity?.isRestDay ?? false;
    final recovery = activity?.recoveryMode ?? false;

    // Tracking not usable yet — offer the real action instead of a fake 0.
    //
    // `noReadingYet` is deliberately NOT routed here when a synced day doc
    // exists: tracking is on and granted, the sensor simply hasn't reported
    // this minute, and swapping a working card for an "Enable" button is what
    // made the feature look like it switches itself off.
    if (snapshot != null &&
        !snapshot.isAvailable &&
        !(snapshot.unavailableReason == StepUnavailableReason.noReadingYet &&
            activity != null)) {
      return _StepTrackingPrompt(reason: snapshot.unavailableReason);
    }

    // A paused (Rest) goal shows a full, calm ring — `calculateStepProgress()`
    // returns 100% when `daily_step_goal` is 0.
    final pct = goal > 0 ? ((steps / goal) * 100).clamp(0, 100) : 100.0;
    final pctRounded = pct.round();
    final goalDone = pctRounded >= 100;
    final streak = controller.currentStreak;

    // Real derived figures for today, plus the history stats the Dashboard is
    // meant to show. All computed from recorded step counts — see step_metrics.
    final km = distanceKm(steps: steps);
    final kcal = estimatedCalories(steps: steps);
    final history = controller.stepHistory;
    final now = DateTime.now();
    final yesterday = history.forDate(DateTime(now.year, now.month, now.day - 1));
    final weeklyAverage = history.averageSteps(today: now, count: 7);

    final mins = activity?.activeMinutes ?? estimatedActiveMinutes(steps: steps) ?? 0;
    final timeStr = mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '${mins}m';

    final statusText = controller.activityStatus;
    final motiveMsg = pctRounded >= 100
        ? '🔥 Goal achieved! Keep moving!'
        : "🚶 Keep going, you're $pctRounded% of the way there!";
    final suggestion = controller.adaptiveGoalSuggestion;

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            emoji: '👣',
            title: "Today's Activity",
            subtitle: restDay ? 'Recovery rest day' : '$pctRounded% of daily goal',
          ),
          const SizedBox(height: 18),
          Column(
            children: [
              SizedBox(
                width: 180,
                height: 180,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: pct / 100),
                      duration: const Duration(milliseconds: 900),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) {
                        return CustomPaint(
                          size: const Size(180, 180),
                          painter: _StepRingPainter(progress: value, done: goalDone),
                        );
                      },
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _thousands(steps),
                          style: const TextStyle(
                            color: DashboardColors.textPrimary,
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.5,
                          ),
                        ),
                        const Text(
                          'STEPS',
                          style: TextStyle(
                            color: DashboardColors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          '$pctRounded%',
                          style: const TextStyle(
                            color: DashboardColors.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                restDay
                    ? '🎯 Today\'s Target: Rest & recover'
                    : '🎯 Today\'s Target: ${_thousands(goal)} Steps',
                style: const TextStyle(color: DashboardColors.textSecondary, fontSize: 13),
              ),
              // Recovery Mode line — health-status.js reduced/paused the goal.
              if (recovery) ...[
                const SizedBox(height: 4),
                Text(
                  restDay
                      ? '🛟 Recovery Mode — step goal paused for today. '
                            'Back to ${_thousands(baseGoal)} tomorrow.'
                      : '🛟 Recovery Mode — today\'s goal reduced to ${_thousands(goal)} steps. '
                            'Back to ${_thousands(baseGoal)} tomorrow.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF0EA5E9),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: goalDone ? DashboardColors.success : DashboardColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              // Adaptive goal suggestion — one tap applies it, never silent.
              if (suggestion != null) ...[
                const SizedBox(height: 8),
                _AdaptiveGoalLine(
                  suggestion: suggestion,
                  onApply: () async {
                    await controller.applyAdaptiveGoal(suggestion.suggestedGoal);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '🎯 Daily step goal updated to ${_thousands(suggestion.suggestedGoal)}',
                        ),
                      ),
                    );
                  },
                ),
              ],
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: DashboardColors.bgCard,
                  border: Border.all(color: DashboardColors.border),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    // Derived from the real step count rather than read from
                    // the day doc: nothing on mobile writes calories/distance
                    // into Firestore, so those fields are always 0 and the card
                    // used to show "0 kcal · 0.00 km" next to a full ring.
                    _StatBlock(icon: '🔥', value: '$kcal kcal', label: 'Calories'),
                    const SizedBox(height: 40, child: VerticalDivider(color: DashboardColors.border)),
                    _StatBlock(
                      icon: '🚶',
                      value: '${km.toStringAsFixed(2)} km',
                      label: 'Distance',
                    ),
                    const SizedBox(height: 40, child: VerticalDivider(color: DashboardColors.border)),
                    _StatBlock(icon: '⏱', value: timeStr, label: 'Active Time'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _WeekStrip(days: controller.weeklySummary),
              const SizedBox(height: 14),
              _HistorySummary(
                yesterday: yesterday?.steps,
                weeklyAverage: weeklyAverage,
                currentStreak: streak,
                longestStreak: controller.longestStreak,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => context.push('/activity'),
                  style: TextButton.styleFrom(
                    foregroundColor: DashboardColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text(
                    'View step history',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                motiveMsg,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: DashboardColors.textSecondary,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _thousands(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// Yesterday, the weekly average and both streaks.
///
/// Every value comes from days that were actually recorded. A figure with no
/// data behind it renders as "—" rather than 0, so an athlete on their first
/// day isn't shown a wall of zeroes that reads like a bad week.
class _HistorySummary extends StatelessWidget {
  const _HistorySummary({
    required this.yesterday,
    required this.weeklyAverage,
    required this.currentStreak,
    required this.longestStreak,
  });

  final int? yesterday;
  final double? weeklyAverage;
  final int currentStreak;
  final int longestStreak;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DashboardColors.bgCardLight,
        border: Border.all(color: DashboardColors.borderSub),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Row(
          children: [
            _MiniStat(
              label: 'Yesterday',
              value: yesterday == null ? '—' : _compact(yesterday!),
            ),
            _MiniStat(
              label: '7-day avg',
              value: weeklyAverage == null ? '—' : _compact(weeklyAverage!.round()),
            ),
            _MiniStat(
              label: 'Streak',
              value: currentStreak > 0 ? '🔥 $currentStreak' : '—',
            ),
            _MiniStat(
              label: 'Best',
              value: longestStreak > 0 ? '$longestStreak' : '—',
            ),
          ],
        ),
      ),
    );
  }

  static String _compact(int n) =>
      n >= 10000 ? '${(n / 1000).toStringAsFixed(1)}k' : n.toString();
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: label == 'Streak' ? DashboardColors.achievementYellow : DashboardColors.hydrationTeal,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: DashboardColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// The honest "no step data yet" state.
///
/// Replaces what would otherwise be a permanent, misleading `0 steps` ring —
/// the athlete can't tell a real rest day from a permission they never
/// granted. Each reason gets its own copy and, where one exists, a real
/// action.
class _StepTrackingPrompt extends StatelessWidget {
  const _StepTrackingPrompt({required this.reason});

  final StepUnavailableReason? reason;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<DashboardController>();
    final (String message, String? action) = switch (reason) {
      StepUnavailableReason.permissionDenied => (
          'Step tracking is turned off. Enable it to see your daily activity.',
          'Enable',
        ),
      StepUnavailableReason.providerUpdateRequired => (
          'Health Connect needs an update before ZITLAS can read your steps.',
          'Fix',
        ),
      StepUnavailableReason.deviceUnsupported => (
          "This device doesn't report step data to ZITLAS.",
          null,
        ),
      // Tracking IS on. Nothing to enable, nothing to fix — the counter just
      // hasn't reported yet today. Offering an "Enable" button here would ask
      // the athlete to re-grant a permission they already gave.
      StepUnavailableReason.noReadingYet => (
          'Waiting for your first steps today. This updates as you move.',
          null,
        ),
      _ => ('Track your daily steps and hit your goal.', 'Enable'),
    };

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            emoji: '👣',
            title: "Today's Activity",
            subtitle: reason == StepUnavailableReason.noReadingYet
                ? 'Tracking on'
                : 'Step tracking not enabled',
          ),
          const SizedBox(height: 14),
          Text(
            message,
            style: const TextStyle(
              color: DashboardColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => controller.enableStepTracking(
                  runConsentFlow: () => showStepConsentSheet(
                    context,
                    service: StepTrackingService(),
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: DashboardColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  action,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// `.sac-week-row` — Mon…Sun with ✅ / ❌ / · / – per `getWeeklySummary()`.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.days});

  final List<WeekDaySummary> days;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: days.map((d) {
        final isToday = d.status == WeekDayStatus.today;
        return Column(
          children: [
            Text(
              d.day,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: isToday ? DashboardColors.primary : DashboardColors.textMuted,
              ),
            ),
            const SizedBox(height: 3),
            Text(d.mark, style: const TextStyle(fontSize: 12)),
          ],
        );
      }).toList(),
    );
  }
}

/// `#sacApplyGoal` — the adaptive-goal reason line plus its inline
/// "Set N" apply button.
class _AdaptiveGoalLine extends StatelessWidget {
  const _AdaptiveGoalLine({required this.suggestion, required this.onApply});

  final AdaptiveGoalSuggestion suggestion;
  final Future<void> Function() onApply;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: [
        Text(
          '💡 ${suggestion.reason}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: DashboardColors.textSecondary),
        ),
        GestureDetector(
          onTap: onApply,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0x24FF9800),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Set ${_thousandsOf(suggestion.suggestedGoal)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: DashboardColors.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _thousandsOf(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({required this.icon, required this.value, required this.label});
  final String icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        child: Column(
          children: [
            Text(icon, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                color: DashboardColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: DashboardColors.textMuted, fontSize: 9.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRingPainter extends CustomPainter {
  _StepRingPainter({required this.progress, required this.done});
  final double progress;
  final bool done;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const strokeWidth = 14.0;
    final radius = (size.width - strokeWidth) / 2;
    final color = done ? DashboardColors.hydrationTeal : DashboardColors.hydrationTeal;

    final track = Paint()
      ..color = DashboardColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);

    final glow = Paint()
      ..color = DashboardColors.hydrationTeal.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final sweep = 2 * 3.14159265359 * progress;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159265359 / 2,
      sweep,
      false,
      glow,
    );

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.14159265359 / 2,
      sweep,
      false,
      fill,
    );
  }

  @override
  bool shouldRepaint(covariant _StepRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.done != done;
}
