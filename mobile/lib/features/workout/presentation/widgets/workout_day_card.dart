import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/workout_day.dart';
import '../workout_visuals.dart';

/// `.wp-day-card` / `renderDayList()`'s per-card markup. Status is always
/// either "In Progress" (today, matched by weekday name) or "Scheduled" —
/// the "Completed" branch requires a `date` field the AI `weekly_plan`
/// schema never has, so it never fires (see `WorkoutWeekProgress`'s doc
/// comment for the same reasoning).
class WorkoutDayCard extends StatelessWidget {
  const WorkoutDayCard({
    super.key,
    required this.day,
    required this.index,
    required this.originalDay,
    required this.onTap,
  });

  final WorkoutDay day;
  final int index;

  /// The corresponding day in `originalWorkoutPlan`, used only to detect a
  /// focus-diff for the strikethrough theme rendering — `focusDiff` in
  /// `transformWorkoutPlan()`.
  final WorkoutDay? originalDay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final todayName = todaysWeekdayName();
    final isToday = day.day.toLowerCase() == todayName.toLowerCase();
    final accent = kWorkoutDayColors[index % kWorkoutDayColors.length];

    final focusDiff = day.modified &&
        originalDay != null &&
        originalDay!.theme.isNotEmpty &&
        day.theme.isNotEmpty &&
        originalDay!.theme != day.theme;

    final primaryName = day.exercises.isNotEmpty ? day.exercises.first.name : '';
    final primarySnip = primaryName.length > 44 ? '${primaryName.substring(0, 41)}…' : primaryName;

    return GestureDetector(
      onTap: onTap,
      child: ZitlasCard(
        margin: const EdgeInsets.only(bottom: 10),
        padding: EdgeInsets.zero,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, decoration: BoxDecoration(color: day.modified ? ZitlasTokens.success : accent)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            workoutDayShort(day.day),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: ZitlasTokens.textPrimary),
                          ),
                          const Spacer(),
                          _StatusBadge(isToday: isToday),
                        ],
                      ),
                      if (day.modified) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0x1F3A8F8B),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '✏️ Modified by ${day.modifiedBy ?? 'Expert'}',
                            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ZitlasTokens.hydrationTeal),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(workoutIconForType(day.type ?? day.focus), style: const TextStyle(fontSize: 16)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: focusDiff
                                ? Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: originalDay!.theme,
                                          style: const TextStyle(
                                            decoration: TextDecoration.lineThrough,
                                            color: ZitlasTokens.textMuted,
                                            fontSize: 13.5,
                                          ),
                                        ),
                                        const TextSpan(text: '  '),
                                        TextSpan(
                                          text: '✓ ${day.theme}',
                                          style: const TextStyle(
                                            color: ZitlasTokens.successDark,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : Text(
                                    day.theme,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
                                  ),
                          ),
                          const Text('›', style: TextStyle(fontSize: 18, color: ZitlasTokens.textMuted)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: ZitlasTokens.bgCardLight,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '⏱ ${day.durationMinutes != null ? '${day.durationMinutes} min' : '—'}',
                          style: const TextStyle(fontSize: 11, color: ZitlasTokens.textSecondary, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (primarySnip.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(text: 'Primary: ', style: TextStyle(fontWeight: FontWeight.w700)),
                              TextSpan(text: primarySnip),
                            ],
                          ),
                          style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.isToday});
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final color = isToday ? ZitlasTokens.primary : ZitlasTokens.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isToday ? 'In Progress' : 'Scheduled',
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
