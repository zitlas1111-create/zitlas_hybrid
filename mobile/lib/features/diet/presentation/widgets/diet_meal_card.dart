import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/diet_meal.dart';
import '../../models/meal_slot.dart';

/// A single meal card: name/time/emoji, foods list, calories/protein, and
/// (when applicable) the expert-modified badge + swap action — matches
/// `renderDay()`'s meal card markup in `diet.js`.
class DietMealCard extends StatelessWidget {
  const DietMealCard({
    super.key,
    required this.meal,
    required this.onSwap,
    this.onGetRecipe,
    this.footer,
  });

  final DietMeal meal;
  final VoidCallback? onSwap;

  /// "Get Easy ZITLAS Recipe" — null (button hidden) for a recovery-day meal,
  /// same gating [onSwap] already gets below. Always rendered BEFORE the
  /// Swap button per the feature spec.
  final VoidCallback? onGetRecipe;

  /// Rendered under the meal's contents — the Meal Snap row for athletes with
  /// an active Personal Coach, absent for everyone else. Passed in rather than
  /// built here so this card keeps knowing nothing about coaching.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final slot = mealSlotFromName(meal.mealName);
    return ZitlasCard(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (meal.emoji != null) ...[
                Text(meal.emoji!, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meal.mealName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: ZitlasTokens.textPrimary,
                      ),
                    ),
                    if (meal.time != null)
                      Text(
                        meal.time!,
                        style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted),
                      ),
                  ],
                ),
              ),
              if (meal.expertModified)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x1F3A8F8B),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '✏️ Expert',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ZitlasTokens.hydrationTeal),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ...meal.foods.map(
            (food) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• ', style: TextStyle(color: ZitlasTokens.primary, fontWeight: FontWeight.w800)),
                  Expanded(
                    child: Text(
                      food,
                      style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (meal.purpose != null) ...[
            const SizedBox(height: 4),
            Text(
              meal.purpose!,
              style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textMuted, fontStyle: FontStyle.italic),
            ),
          ],
          // Communicates WHY this slot exists (item 21) — separate from the
          // action buttons below, which keep their normal generic labels.
          if (slot.isWorkoutSlot) ...[
            const SizedBox(height: 6),
            _PurposeBadge(slot: slot),
          ],
          if (meal.calories != null || meal.proteinG != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (meal.calories != null) _Stat(label: 'kcal', value: meal.calories!),
                if (meal.proteinG != null) ...[
                  const SizedBox(width: 14),
                  _Stat(label: 'g protein', value: meal.proteinG!),
                ],
              ],
            ),
          ],
          if ((onGetRecipe != null || onSwap != null) && !meal.recovery) ...[
            const SizedBox(height: 10),
            // Each action gets HALF the row via Expanded so the two buttons
            // can never overlap or spill past the card, on any screen size
            // (small/large phones, tablets) — a fixed-width Row previously
            // let "Easy Recipe" + "Swap" overflow and clip on narrow
            // devices. FittedBox inside each button shrinks the label/icon
            // rather than truncating or overflowing if space is still tight.
            Row(
              children: [
                // "Get Easy ZITLAS Recipe" BEFORE "Swap" — build order here
                // is also left-to-right visual order, satisfying the spec's
                // placement requirement.
                if (onGetRecipe != null)
                  Expanded(
                    child: _MealActionButton(
                      icon: Icons.egg_alt_outlined,
                      label: 'Easy Recipe',
                      color: ZitlasTokens.primary,
                      onPressed: onGetRecipe,
                    ),
                  ),
                if (onGetRecipe != null && onSwap != null) const SizedBox(width: 8),
                if (onSwap != null)
                  Expanded(
                    child: _MealActionButton(
                      icon: Icons.swap_horiz,
                      label: 'Swap',
                      color: ZitlasTokens.primaryDark,
                      onPressed: onSwap,
                    ),
                  ),
              ],
            ),
          ],
          ?footer,
        ],
      ),
    );
  }
}

/// Each action gets independent width via the parent's Expanded, and this
/// button itself never overflows THAT width: FittedBox scales the
/// icon+label down together rather than truncating or spilling past the
/// button's bounds on a narrow phone.
class _MealActionButton extends StatelessWidget {
  const _MealActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.35)),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// "⚡ Quick Energy" / "💪 Recovery" (item 21) — tells the athlete why this
/// slot's recommendation logic differs from a normal meal, without changing
/// the action buttons' own generic wording.
class _PurposeBadge extends StatelessWidget {
  const _PurposeBadge({required this.slot});
  final MealSlot slot;

  @override
  Widget build(BuildContext context) {
    final isPostWorkout = slot == MealSlot.postWorkout;
    final text = isPostWorkout ? '💪 Recovery' : '⚡ Quick Energy';
    final color = isPostWorkout ? ZitlasTokens.primaryDark : ZitlasTokens.primary;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final num value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '${value % 1 == 0 ? value.toInt() : value} ',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
          ),
          TextSpan(
            text: label,
            style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
          ),
        ],
      ),
    );
  }
}
