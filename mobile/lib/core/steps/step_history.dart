import 'package:flutter/foundation.dart';

import 'step_day.dart';
import 'step_tracking_service.dart';

/// Read-only views over the stored daily summaries.
///
/// Pure functions over a `YYYY-MM-DD -> StepDaySummary` map, so every number
/// the History screen and the Dashboard show — yesterday, the weekly average,
/// both streaks — is derived from the same recorded days and is testable
/// without a device, a clock or Firestore.
///
/// A day that was never recorded is ABSENT, not zero. The distinction matters:
/// a day ZITLAS wasn't installed for, or a day the user's phone was off, is
/// unknown — averaging it in as a 0 would quietly punish them for days that
/// were never measured.
@immutable
class StepHistory {
  const StepHistory(this.days);

  /// Keyed by local `YYYY-MM-DD`.
  final Map<String, StepDaySummary> days;

  static const empty = StepHistory({});

  bool get isEmpty => days.isEmpty;

  StepDaySummary? forDay(String dayKey) => days[dayKey];

  StepDaySummary? forDate(DateTime date) => days[localDayKey(date)];

  /// The [count] calendar days ending at [today], most recent first.
  ///
  /// Every date in the window is returned, present or not — the History screen
  /// shows "No data" for a gap rather than silently closing it up, which would
  /// make a missing Tuesday look like it never existed.
  List<StepHistoryEntry> window({required DateTime today, required int count}) {
    final out = <StepHistoryEntry>[];
    for (var i = 0; i < count; i++) {
      final date = DateTime(today.year, today.month, today.day - i);
      final key = localDayKey(date);
      out.add(StepHistoryEntry(date: date, dayKey: key, summary: days[key]));
    }
    return out;
  }

  /// Mean steps across the RECORDED days in the window.
  ///
  /// Null when nothing in the window was recorded. Divides by the number of
  /// days that actually have data, not by [count] — see the note above about
  /// unmeasured days.
  double? averageSteps({required DateTime today, required int count}) {
    final recorded = window(today: today, count: count)
        .where((e) => e.summary != null)
        .map((e) => e.summary!.steps)
        .toList();
    if (recorded.isEmpty) return null;
    return recorded.reduce((a, b) => a + b) / recorded.length;
  }

  /// Consecutive goal-completed days ending today or yesterday.
  ///
  /// TODAY IS NOT REQUIRED TO BE COMPLETE. A streak is a record of finished
  /// days; counting an unfinished today against it would show every athlete a
  /// broken streak from midnight until whenever they hit their goal, which is
  /// both wrong and demoralising. Today only ever extends the streak.
  int currentStreak({required DateTime today}) {
    var streak = 0;
    var cursor = today;

    final todaysEntry = days[localDayKey(today)];
    if (todaysEntry?.completed == true) {
      streak = 1;
    }
    // Walk backwards from yesterday either way.
    cursor = DateTime(today.year, today.month, today.day - 1);

    while (true) {
      final day = days[localDayKey(cursor)];
      if (day == null || !day.completed) break;
      streak++;
      cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
    }
    return streak;
  }

  /// The longest run of consecutive completed days anywhere in the record.
  int longestStreak() {
    if (days.isEmpty) return 0;
    final completed = days.values.where((d) => d.completed).map((d) => d.date).toSet();
    if (completed.isEmpty) return 0;

    var best = 0;
    for (final key in completed) {
      final date = _parseDayKey(key);
      if (date == null) continue;
      // Only start counting from the beginning of a run, so each run is
      // measured once instead of once per day in it.
      final previous = localDayKey(DateTime(date.year, date.month, date.day - 1));
      if (completed.contains(previous)) continue;

      var run = 0;
      var cursor = date;
      while (completed.contains(localDayKey(cursor))) {
        run++;
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      }
      if (run > best) best = run;
    }
    return best;
  }

  static DateTime? _parseDayKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
}

/// One row of the History screen: a calendar date and what (if anything) was
/// recorded for it.
@immutable
class StepHistoryEntry {
  const StepHistoryEntry({
    required this.date,
    required this.dayKey,
    required this.summary,
  });

  final DateTime date;
  final String dayKey;

  /// Null when the day has no record at all.
  final StepDaySummary? summary;

  bool get hasData => summary != null;
  int get steps => summary?.steps ?? 0;
  int get goal => summary?.goal ?? 0;
  bool get completed => summary?.completed ?? false;
}
