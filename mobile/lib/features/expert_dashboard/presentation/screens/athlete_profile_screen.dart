import 'package:flutter/material.dart';

import '../../../../core/steps/step_history.dart';
import '../../../../core/theme/zitlas_tokens.dart';
import '../../../coaching/data/coaching_plan_repository.dart';
import '../../../coaching/presentation/screens/coach_diet_editor_screen.dart';
import '../../../coaching/presentation/screens/meal_review_screen.dart';
import '../../../coaching/presentation/widgets/coach_notes_sheet.dart';
import '../../../coaching/presentation/widgets/plan_history_sheet.dart';
import '../../../diet/models/diet_profile.dart';
import '../../data/expert_repository.dart';
import '../widgets/athlete_profile_sections.dart';

/// The coach's workspace for one athlete.
///
/// Was a thin read-only summary; it is now the surface a coach actually works
/// from — the athlete's full picture, plus the entry points to author their
/// diet, review the version history, and keep private notes.
///
/// Everything renders from `users/{athleteId}` live. Security Rules only grant
/// that read to `isActiveCoachOf(athleteId)`, so a coach who is no longer
/// assigned loses this screen's data automatically — the gate is the database's,
/// not this widget's.
class AthleteProfileScreen extends StatelessWidget {
  const AthleteProfileScreen({
    super.key,
    required this.repository,
    required this.athleteId,
    required this.athleteName,
    this.coachId,
    this.coachName,
    this.planType = 'complete',
    this.coachingPlans,
  });

  final ExpertRepository repository;
  final String athleteId;
  final String athleteName;

  /// When present, this screen is the coaching workspace rather than a
  /// read-only profile: editing, history and private notes appear.
  final String? coachId;
  final String? coachName;
  final String planType;

  final CoachingPlanRepository? coachingPlans;

  bool get _isCoachView => coachId != null;

  @override
  Widget build(BuildContext context) {
    final plans = coachingPlans ?? CoachingPlanRepository();

    return Scaffold(
      backgroundColor: ZitlasTokens.bgStart,
      appBar: AppBar(
        backgroundColor: ZitlasTokens.bgCard,
        title: Text(
          athleteName,
          style: const TextStyle(
            color: ZitlasTokens.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        iconTheme: const IconThemeData(color: ZitlasTokens.textPrimary),
      ),
      body: SafeArea(
        child: StreamBuilder<Map<String, dynamic>?>(
          stream: repository.watchAthleteProfile(athleteId),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: ZitlasTokens.primary),
              );
            }
            if (snap.hasError) {
              // Almost always a permission failure — the relationship ended
              // or lapsed. Say that, rather than showing a blank profile.
              return const _Message(
                'This user\'s profile is no longer available to you. '
                'That usually means the coaching relationship has ended.',
              );
            }
            final data = snap.data;
            if (data == null) {
              return const _Message('No profile data found for this user.');
            }

            final profile = DietProfile.fromMap(
              (data['dietProfile'] as Map?)?.cast<String, dynamic>(),
            );

            return StreamBuilder<CoachingPlanDoc>(
              stream: plans.watch(athleteId),
              builder: (context, planSnap) {
                final planDoc = planSnap.data ?? const CoachingPlanDoc();
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
                  children: [
                    AthleteIdentityCard(data: data, name: athleteName),
                    const SizedBox(height: 12),
                    if (_isCoachView) ...[
                      _PlanActions(
                        planDoc: planDoc,
                        onEditDiet: () => _openDietEditor(context, plans, data, profile, planDoc),
                        onHistory: () => showPlanHistorySheet(
                          context,
                          athleteId: athleteId,
                          athleteName: athleteName,
                          coachId: coachId!,
                          coachName: coachName ?? 'Coach',
                          planType: planType,
                          repository: plans,
                          athletePlanId: data['planId'] as String?,
                        ),
                        onNotes: () => showCoachNotesSheet(
                          context,
                          athleteId: athleteId,
                          coachId: coachId!,
                          repository: repository,
                        ),
                        onMeals: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => MealReviewScreen(
                              coachId: coachId!,
                              coachName: coachName ?? 'Coach',
                              athleteId: athleteId,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    AthleteFoodPreferencesCard(profile: profile),
                    const SizedBox(height: 12),
                    AthleteLifestyleCard(data: data),
                    const SizedBox(height: 12),
                    AthleteFitnessCard(
                      data: data,
                      history: StepHistory(const {}),
                    ),
                    const SizedBox(height: 12),
                    AthleteAssessmentCard(data: data),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _openDietEditor(
    BuildContext context,
    CoachingPlanRepository plans,
    Map<String, dynamic> athleteDoc,
    DietProfile profile,
    CoachingPlanDoc planDoc,
  ) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CoachDietEditorScreen(
          athleteId: athleteId,
          athleteName: athleteName,
          coachId: coachId!,
          coachName: coachName ?? 'Coach',
          planType: planType,
          initialPlan: planDoc.diet,
          athleteProfile: profile,
          athletePlanId: athleteDoc['planId'] as String?,
          repository: plans,
        ),
      ),
    );
  }
}

/// The coach's three actions on this user's plans.
class _PlanActions extends StatelessWidget {
  const _PlanActions({
    required this.planDoc,
    required this.onEditDiet,
    required this.onHistory,
    required this.onNotes,
    required this.onMeals,
  });

  final CoachingPlanDoc planDoc;
  final VoidCallback onEditDiet, onHistory, onNotes, onMeals;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.borderSub),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'COACHING',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                  color: ZitlasTokens.textMuted,
                ),
              ),
              const Spacer(),
              if (planDoc.dietVersion > 0)
                Text(
                  'Diet v${planDoc.dietVersion}',
                  style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
                ),
            ],
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: _Action(
                  icon: Icons.restaurant_menu_rounded,
                  label: planDoc.diet.hasDays ? 'Edit diet' : 'Build diet',
                  primary: true,
                  // A coach paid for training only must not rewrite the
                  // athlete's food — the engagement they sold decides.
                  onTap: planDoc.canEditDiet ? onEditDiet : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Action(
                  icon: Icons.history_rounded,
                  label: 'History',
                  onTap: planDoc.dietVersion > 0 || planDoc.trainingVersion > 0
                      ? onHistory
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Action(
                  icon: Icons.lock_rounded,
                  label: 'Notes',
                  onTap: onNotes,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: _Action(
              icon: Icons.photo_camera_rounded,
              label: 'Meal reviews',
              onTap: onMeals,
            ),
          ),
          if (!planDoc.canEditDiet)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'This is a training-only engagement, so the diet is read-only.',
                style: TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled
        ? ZitlasTokens.textMuted
        : (primary ? Colors.white : ZitlasTokens.textPrimary);
    return Material(
      color: !enabled
          ? ZitlasTokens.bgCardLight
          : (primary ? ZitlasTokens.primary : ZitlasTokens.bgCardLight),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: primary && enabled ? ZitlasTokens.primary : ZitlasTokens.borderSub,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: ZitlasTokens.textSecondary,
          ),
        ),
      ),
    );
  }
}
