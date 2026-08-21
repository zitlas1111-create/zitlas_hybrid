import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../diet/models/diet_profile.dart';
import '../../models/plan_compliance.dart';

/// What the athlete told us, always on screen for the coach (Step 6).
///
/// Never collapsed behind a tap. A coach who has to go looking for an allergy
/// is a coach who will sometimes not look — and the whole point of recording
/// these is that they are visible at the moment the plan is being written.
class AthletePreferenceStrip extends StatelessWidget {
  const AthletePreferenceStrip({super.key, required this.profile});

  final DietProfile profile;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String, List<String>, Color)>[
      if (profile.allergies.isNotEmpty)
        ('🚨', 'Allergies', profile.allergies, ZitlasTokens.danger),
      if (profile.neverEaten.isNotEmpty)
        ('🚫', 'Never eats', profile.neverEaten, ZitlasTokens.textPrimary),
      if (profile.dislikedFoods.isNotEmpty)
        ('😕', 'Dislikes', profile.dislikedFoods, ZitlasTokens.textSecondary),
      if (profile.lovedFoods.isNotEmpty)
        ('💚', 'Loves', profile.lovedFoods, ZitlasTokens.success),
    ];

    // `mealsPerDay` DEFAULTS to 3, so it is only a fact once the athlete has
    // actually been through the intake. Showing "🍽 3 meals/day" for someone
    // who recorded nothing presents a default as an answer — and it also made
    // the "no profile recorded" message below unreachable, because this chip
    // was always present.
    final answered = profile.completedAt != null ||
        profile.dietPreference != null ||
        profile.budget != null ||
        profile.preparer != null;

    final facts = <String>[
      if (profile.dietPreference != null)
        '${profile.dietPreference!.icon} ${profile.dietPreference!.label}',
      if (profile.budget != null) '${profile.budget!.icon} ${profile.budget!.label} budget',
      if (answered) '🍽 ${profile.mealsPerDay} meals/day',
      if (profile.preparer != null)
        '${profile.preparer!.icon} ${profile.preparer!.label}',
    ];

    if (rows.isEmpty && facts.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: ZitlasTokens.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ZitlasTokens.borderSub),
        ),
        child: const Text(
          "This user hasn't completed their food profile yet — no allergies, "
          'preferences or budget recorded. Ask them in chat before building the week.',
          style: TextStyle(fontSize: 11.5, height: 1.45, color: ZitlasTokens.textSecondary),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'USER PREFERENCES',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.7,
              color: ZitlasTokens.textMuted,
            ),
          ),
          const SizedBox(height: 7),
          if (facts.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in facts)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: ZitlasTokens.bgCardLight,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ZitlasTokens.borderSub),
                    ),
                    child: Text(
                      f,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: ZitlasTokens.textPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          for (final (icon, label, values, color) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(icon, style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 68,
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: ZitlasTokens.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      values.join(', '),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Problems found in the week being written — and the budget position.
///
/// Warns; never blocks. A coach may have a clinical reason to prescribe
/// something the athlete dislikes, and an editor that refuses to save is one
/// that gets worked around.
class ComplianceBanner extends StatelessWidget {
  const ComplianceBanner({super.key, required this.report});

  final PlanComplianceReport report;

  @override
  Widget build(BuildContext context) {
    if (report.isClean && report.budgetWarning == null) return const SizedBox.shrink();

    final severe = report.severe;
    final tint = severe.isNotEmpty ? ZitlasTokens.danger : ZitlasTokens.primary;

    // De-duplicated: the same food repeated across the week is one problem to
    // fix, not seven lines to scroll past.
    final unique = <String, ComplianceFlag>{};
    for (final f in report.flags) {
      unique['${f.issue.name}|${f.foodName}'] ??= f;
    }
    final shown = unique.values.take(6).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            severe.isNotEmpty
                ? 'Check these before publishing'
                : 'Worth a look before publishing',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: tint),
          ),
          const SizedBox(height: 6),
          for (final f in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '${f.issue.icon} ${f.foodName} — ${f.detail}'
                '${f.day != null ? " (${f.day}, ${f.mealName})" : ""}',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  fontWeight: f.issue.isSevere ? FontWeight.w700 : FontWeight.w500,
                  color: f.issue.isSevere
                      ? ZitlasTokens.danger
                      : ZitlasTokens.textSecondary,
                ),
              ),
            ),
          if (unique.length > shown.length)
            Text(
              '+${unique.length - shown.length} more',
              style: const TextStyle(fontSize: 11, color: ZitlasTokens.textMuted),
            ),
          if (report.budgetWarning != null) ...[
            const SizedBox(height: 6),
            Text(
              '💰 ${report.budgetWarning}',
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: ZitlasTokens.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
