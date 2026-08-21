import 'package:flutter/foundation.dart';

/// Pure, dependency-free day/progress/milestone math for the step counter.
///
/// Everything here is deliberately side-effect free so the rules that matter
/// most — where a day starts and ends, and when a notification is allowed to
/// fire — are directly testable without a device, a clock, or Firestore.

/// `YYYY-MM-DD` for a LOCAL calendar date.
///
/// The step counter's day is the user's local calendar day, so this is
/// built from local Y/M/D components and never from `toIso8601String()` or
/// anything UTC-derived: at 01:00 IST the UTC date is still yesterday, which
/// would file a morning walk under the wrong day and make "today" appear to
/// reset at 05:30 local instead of midnight.
String localDayKey(DateTime local) {
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Local 00:00:00.000 of [now]'s calendar date.
///
/// `DateTime(y, m, d)` constructs in the device's CURRENT local zone, so this
/// stays correct across timezone changes and DST shifts — the boundary is
/// re-derived from whatever "local" means at call time rather than cached as
/// an absolute instant. On a DST-skipped midnight the platform normalises to
/// the following valid instant, which is the right behaviour: the day still
/// starts at the first moment that exists.
DateTime startOfLocalDay(DateTime now) => DateTime(now.year, now.month, now.day);

/// Local 00:00 of the NEXT calendar day.
///
/// Built by adding one to the day component rather than adding a 24-hour
/// Duration: on a DST transition a local day is 23 or 25 hours long, and
/// `+Duration(days: 1)` would land an hour early/late and clip or overrun the
/// day boundary.
DateTime startOfNextLocalDay(DateTime now) => DateTime(now.year, now.month, now.day + 1);

/// The four milestones ZITLAS notifies on, as whole percentages.
const kStepMilestones = <int>[25, 50, 75, 100];

/// Progress as a 0..1 fraction for the ring, clamped at 1.
///
/// A paused goal (0, i.e. Recovery-Mode "Rest") reads as a calm, complete
/// ring — matching `calculateStepProgress()` on the website, which returns
/// 100% when the daily goal is 0. The raw step count is always displayed
/// unclamped alongside it, so 10,532/8,000 still shows the real 10,532.
double stepProgressFraction({required int steps, required int goal}) {
  if (goal <= 0) return 1;
  if (steps <= 0) return 0;
  return (steps / goal).clamp(0.0, 1.0);
}

/// Whole-percent progress, uncapped, for status text ("132% of goal").
int stepProgressPercent({required int steps, required int goal}) {
  if (goal <= 0) return 100;
  if (steps <= 0) return 0;
  return ((steps / goal) * 100).round();
}

bool stepGoalReached({required int steps, required int goal}) {
  if (goal <= 0) return false; // A paused goal isn't an achievement.
  return steps >= goal;
}

/// Immutable record of which milestones have already been notified on a given
/// local date. Persisted so a restart can't re-fire them.
@immutable
class MilestoneState {
  const MilestoneState({required this.dayKey, required this.notified});

  final String dayKey;
  final Set<int> notified;

  static MilestoneState emptyFor(String dayKey) =>
      MilestoneState(dayKey: dayKey, notified: const <int>{});

  MilestoneState withNotified(Iterable<int> extra) => MilestoneState(
        dayKey: dayKey,
        notified: {...notified, ...extra},
      );

  /// A stored state only counts for the day it was recorded on — reading it on
  /// a new local date yields a fresh, empty state, which is what makes
  /// milestone eligibility reset at local midnight without a timer.
  MilestoneState forDay(String todayKey) =>
      dayKey == todayKey ? this : MilestoneState.emptyFor(todayKey);
}

/// Which single milestone (if any) should be notified right now.
///
/// Returns the milestone to announce plus every milestone that must be marked
/// as notified. Two deliberate rules:
///
///  * **At most one notification per check.** Steps often arrive in a batch
///    (the phone was in a pocket for an hour, or Health Connect synced a
///    watch), so several milestones can become eligible at once. Firing four
///    notifications back-to-back for one walk is spam, so only the HIGHEST
///    newly-crossed milestone is announced — and the ones it leapfrogged are
///    marked notified so they can never fire retroactively later.
///  * **Goal-complete outranks everything.** 100 is the milestone that
///    matters, and it's the highest, so the "announce the highest" rule
///    already guarantees it wins whenever it's newly crossed.
///
/// A paused/zero goal produces nothing: there is no target to be a percentage
/// of, and "you completed 0 steps" is not a thing worth buzzing a pocket for.
MilestoneDecision decideMilestone({
  required int steps,
  required int goal,
  required MilestoneState state,
  required String todayKey,
}) {
  final today = state.forDay(todayKey);
  if (goal <= 0) {
    return MilestoneDecision(announce: null, state: today);
  }
  final pct = (steps / goal) * 100;
  final crossed = kStepMilestones.where((m) => pct >= m && !today.notified.contains(m)).toList();
  if (crossed.isEmpty) {
    return MilestoneDecision(announce: null, state: today);
  }
  final highest = crossed.reduce((a, b) => a > b ? a : b);
  return MilestoneDecision(
    announce: highest,
    state: today.withNotified(crossed),
  );
}

@immutable
class MilestoneDecision {
  const MilestoneDecision({required this.announce, required this.state});

  /// The milestone to notify about, or null for "nothing to say".
  final int? announce;

  /// The state to persist — includes leapfrogged milestones so they're
  /// suppressed permanently for this day, even when nothing was announced.
  final MilestoneState state;
}

/// User-facing milestone copy. Concise, ZITLAS-branded, no exclamation spam.
String milestoneMessage({required int milestone, required int goal}) {
  final goalText = _thousands(goal);
  return switch (milestone) {
    25 => "Great start! You've completed 25% of today's step goal.",
    50 => "Halfway there! You've completed 50% of today's step goal.",
    75 => "Almost there! 75% of today's step goal is complete.",
    _ => 'Daily goal completed 🎉 You\'ve reached $goalText steps today.',
  };
}

String milestoneTitle(int milestone) =>
    milestone >= 100 ? 'Daily goal complete' : 'Step goal progress';

String _thousands(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
