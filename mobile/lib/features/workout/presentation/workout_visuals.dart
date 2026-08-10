import 'package:flutter/material.dart';

import '../../../core/theme/zitlas_tokens.dart';

/// `DAY_COLORS` (weekly-plan.js) — one accent per day, Mon→Sun.
///
/// Alternates Deep Green / Teal only — deliberately NOT `aiAccent` (Plum is
/// reserved for Zino/AI elsewhere in the app; reusing it here as a generic
/// weekday color would make an unrelated day look "AI-flagged").
const List<Color> kWorkoutDayColors = [
  ZitlasTokens.primary, // Day 1
  ZitlasTokens.hydrationTeal, // Day 2
  ZitlasTokens.primaryDark, // Day 3
  ZitlasTokens.hydrationTeal, // Day 4
  ZitlasTokens.primary, // Day 5
  ZitlasTokens.hydrationTeal, // Day 6
  ZitlasTokens.primaryDark, // Day 7
];

/// `DAY_SHORT` (weekly-plan.js) — exact 3-letter abbreviations.
const Map<String, String> kWorkoutDayShort = {
  'Monday': 'MON',
  'Tuesday': 'TUE',
  'Wednesday': 'WED',
  'Thursday': 'THU',
  'Friday': 'FRI',
  'Saturday': 'SAT',
  'Sunday': 'SUN',
};

const List<String> kWeekdayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

String todaysWeekdayName([DateTime? now]) => kWeekdayNames[(now ?? DateTime.now()).weekday % 7];

String workoutDayShort(String dayName) =>
    kWorkoutDayShort[dayName] ?? (dayName.isEmpty ? 'DAY' : dayName.substring(0, dayName.length >= 3 ? 3 : dayName.length).toUpperCase());

/// `iconForType(t)` (weekly-plan.js's `transformWorkoutPlan`).
String workoutIconForType(String? type) {
  final s = (type ?? '').toLowerCase();
  if (s.contains('rest')) return '😴';
  if (s.contains('recovery')) return '🧘';
  if (s.contains('walking')) return '🚶';
  if (s.contains('cardio')) return '🏃';
  if (s.contains('upper')) return '💪';
  if (s.contains('lower')) return '🦵';
  if (s.contains('hiit')) return '🔥';
  return '💪';
}
