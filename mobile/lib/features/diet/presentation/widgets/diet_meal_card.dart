import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/diet_meal.dart';

/// A single meal card: name/time/emoji, foods list, calories/protein, and
/// (when applicable) the expert-modified badge + swap action — matches
/// `renderDay()`'s meal card markup in `diet.js`.
class DietMealCard extends StatelessWidget {
  const DietMealCard({
    super.key,
    required this.meal,
    required this.onSwap,
    this.footer,
  });

  final DietMeal meal;
  final VoidCallback? onSwap;

  /// Rendered under the meal's contents — the Meal Snap row for athletes with
  /// an active Personal Coach, absent for everyone else. Passed in rather than
  /// built here so this card keeps knowing nothing about coaching.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
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
          const SizedBox(height: 10),
          Row(
            children: [
              if (meal.calories != null) _Stat(label: 'kcal', value: meal.calories!),
              if (meal.proteinG != null) ...[
                const SizedBox(width: 14),
                _Stat(label: 'g protein', value: meal.proteinG!),
              ],
              const Spacer(),
              if (onSwap != null && !meal.recovery)
                TextButton.icon(
                  onPressed: onSwap,
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: const Text('Swap'),
                  style: TextButton.styleFrom(
                    foregroundColor: ZitlasTokens.primaryDark,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
          ?footer,
        ],
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
