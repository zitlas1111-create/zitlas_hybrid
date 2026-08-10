import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/diet_calculations.dart';
import '../../models/diet_plan_content.dart';

/// Plan name + calorie/protein/water targets, matching the summary strip at
/// the top of `diet.js`'s rendered plan. Targets come from
/// `users/{uid}.calculations` (server-computed), never recalculated here.
class DietPlanHeaderCard extends StatelessWidget {
  const DietPlanHeaderCard({
    super.key,
    required this.plan,
    required this.calculations,
    required this.isExpertPlan,
    required this.expertName,
    required this.onRequestReview,
  });

  final DietPlanContent plan;
  final DietCalculations calculations;
  final bool isExpertPlan;
  final String? expertName;
  final VoidCallback onRequestReview;

  @override
  Widget build(BuildContext context) {
    return ZitlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.planName ?? 'Your Diet Plan',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: ZitlasTokens.textPrimary,
                  ),
                ),
              ),
              if (isExpertPlan)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0x1F3A8F8B),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0x403A8F8B)),
                  ),
                  child: Text(
                    expertName != null ? 'Reviewed by $expertName' : 'Expert Reviewed',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ZitlasTokens.hydrationTeal,
                    ),
                  ),
                ),
            ],
          ),
          if (plan.summary != null) ...[
            const SizedBox(height: 6),
            Text(
              plan.summary!,
              style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary, height: 1.4),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              _Target(label: 'Calories', value: _fmt(calculations.calorieTargetKcal, 'kcal')),
              _Target(label: 'Protein', value: _fmt(calculations.proteinTargetG, 'g')),
              _Target(label: 'Water', value: _fmt(calculations.waterTargetLiters, 'L')),
            ],
          ),
          if (plan.keyRules.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: plan.keyRules
                  .map(
                    (rule) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: ZitlasTokens.bgCardLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        rule,
                        style: const TextStyle(fontSize: 11.5, color: ZitlasTokens.textSecondary),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onRequestReview,
              style: OutlinedButton.styleFrom(
                foregroundColor: ZitlasTokens.primaryDark,
                side: const BorderSide(color: ZitlasTokens.primary),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Ask an Expert to Review', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(num? value, String unit) {
    if (value == null) return '—';
    final rounded = value % 1 == 0 ? value.toInt().toString() : value.toStringAsFixed(1);
    return '$rounded $unit';
  }
}

class _Target extends StatelessWidget {
  const _Target({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
