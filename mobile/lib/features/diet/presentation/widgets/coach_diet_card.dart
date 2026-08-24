import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../coaching/models/coach_diet_plan.dart';
import '../../diet_controller.dart';
import 'meal_snap_button.dart';

/// The coach-authored diet, on the athlete's Diet screen.
///
/// Shown ABOVE the AI plan rather than replacing it: the coach's prescription
/// is what the athlete should follow, but the AI plan stays visible and intact
/// underneath. Nothing here writes anything — the athlete's only write to the
/// coach document is which option they picked, and Security Rules now allow
/// them nothing else.
///
/// A coach offers OPTIONS per meal (that is the shape of `coaching_plans.diet`
/// on the website too), so this renders every option and lets the athlete
/// choose, rather than flattening to the first one.
class CoachDietCard extends StatelessWidget {
  const CoachDietCard({
    super.key,
    required this.plan,
    required this.dayIndex,
    required this.coachName,
    required this.updatedAt,
    this.selections = const {},
    this.onSelect,
    this.controller,
    this.athleteName,
  });

  final CoachDietPlan plan;

  /// 0 = Monday, matching [kCoachPlanDays].
  final int dayIndex;

  final String coachName;
  final DateTime? updatedAt;

  /// `'<day>:<mealId>' -> option index`.
  final Map<String, int> selections;

  final void Function(String day, String mealId, int optionIndex)? onSelect;

  /// When set, each coach meal gets a "Snap Meal" row so the athlete sends the
  /// photo against the COACH's prescription (the plan they're actually
  /// following while coaching is active), not the AI reference plan below.
  /// Null on any screen that only displays the coach plan.
  final DietController? controller;
  final String? athleteName;

  @override
  Widget build(BuildContext context) {
    if (dayIndex < 0 || dayIndex >= plan.days.length) return const SizedBox.shrink();
    final day = plan.days[dayIndex];
    final meals = day.meals.where((m) => m.hasOptions).toList();
    if (meals.isEmpty) {
      // The coach hasn't filled this particular day in. Say so — a blank card
      // reads as a bug, and silently falling back to the AI plan would hide
      // that the coach has work left to do.
      return _Shell(
        coachName: coachName,
        updatedAt: updatedAt,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            '$coachName hasn\'t set ${day.day} yet — follow your plan below for today.',
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: ZitlasTokens.textSecondary,
            ),
          ),
        ),
      );
    }

    return _Shell(
      coachName: coachName,
      updatedAt: updatedAt,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Text(
                  day.day,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
                const Spacer(),
                if (day.representativeCalories > 0)
                  Text(
                    '~${day.representativeCalories.round()} kcal · '
                    '${day.representativeProtein.round()}g protein',
                    style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
                  ),
              ],
            ),
          ),
          for (final meal in meals)
            _MealBlock(
              day: day.day,
              meal: meal,
              selected: selections['${day.day}:${meal.id}'] ?? 0,
              onSelect: onSelect,
              controller: controller,
              athleteName: athleteName,
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.coachName, required this.updatedAt, required this.child});

  final String coachName;
  final DateTime? updatedAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.35), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: BoxDecoration(
              color: ZitlasTokens.primary.withValues(alpha: 0.08),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(17)),
            ),
            child: Row(
              children: [
                const Text('🤝', style: TextStyle(fontSize: 15)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // Matches the website's banner wording so an athlete
                        // switching devices reads the same sentence.
                        '✓ Reviewed & Updated by your nutritionist',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: ZitlasTokens.textPrimary,
                        ),
                      ),
                      Text(
                        updatedAt == null
                            ? coachName
                            : '$coachName · ${_relative(updatedAt!)}',
                        style: const TextStyle(fontSize: 11, color: ZitlasTokens.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  static String _relative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays} days ago';
  }
}

class _MealBlock extends StatelessWidget {
  const _MealBlock({
    required this.day,
    required this.meal,
    required this.selected,
    required this.onSelect,
    this.controller,
    this.athleteName,
  });

  final String day;
  final CoachMeal meal;
  final int selected;
  final void Function(String day, String mealId, int optionIndex)? onSelect;
  final DietController? controller;
  final String? athleteName;

  @override
  Widget build(BuildContext context) {
    final multiple = meal.options.length > 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                meal.name,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: ZitlasTokens.textPrimary,
                ),
              ),
              if (meal.time != null) ...[
                const SizedBox(width: 6),
                Text(
                  meal.time!,
                  style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
                ),
              ],
              const Spacer(),
              if (multiple)
                Text(
                  '${meal.options.length} options',
                  style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                ),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < meal.options.length; i++)
            _OptionRow(
              option: meal.options[i],
              // With a single option there is nothing to choose, so it renders
              // as a plain instruction rather than a radio the athlete has to
              // tick to no effect.
              selectable: multiple,
              selected: multiple && i == selected,
              onTap: multiple && onSelect != null
                  ? () => onSelect!(day, meal.id, i)
                  : null,
            ),
          // Snap this meal against the COACH's prescription. Keyed on the coach
          // meal name so the check-in lands on the right meal in the coach's
          // review workspace. Only present when a controller is supplied (i.e.
          // coaching is active); MealSnapRow itself re-checks hasActiveCoach.
          if (controller != null && athleteName != null)
            MealSnapRow(
              controller: controller!,
              mealName: meal.name,
              athleteName: athleteName!,
            ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.selectable,
    required this.selected,
    this.onTap,
  });

  final CoachMealOption option;
  final bool selectable;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final macros = <String>[
      if (option.calories != null) '${option.calories!.round()} kcal',
      if (option.protein != null) '${option.protein!.round()}g protein',
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? ZitlasTokens.primary.withValues(alpha: 0.10)
              : ZitlasTokens.bgCardLight,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? ZitlasTokens.primary : ZitlasTokens.borderSub,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectable)
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 8),
                child: Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 15,
                  color: selected ? ZitlasTokens.primary : ZitlasTokens.textMuted,
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 8),
                child: Text('•', style: TextStyle(color: ZitlasTokens.primary)),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: ZitlasTokens.textPrimary,
                    ),
                  ),
                  if (macros.isNotEmpty)
                    Text(
                      macros,
                      style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                    ),
                  if (option.notes != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        option.notes!,
                        style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: ZitlasTokens.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
