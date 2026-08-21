import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../zino/tour/zino_tour_stops.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../data/diet_repository.dart';
import '../../diet_controller.dart';
import '../../models/diet_meal.dart';
import '../../models/meal_slot.dart';
import '../widgets/recipe_source_sheet.dart';
import '../widgets/coach_diet_card.dart';
import '../widgets/diet_day_focus_card.dart';
import '../widgets/diet_day_selector.dart';
import '../widgets/diet_empty_state.dart';
import '../widgets/diet_expert_review_banner.dart';
import '../widgets/diet_meal_card.dart';
import '../widgets/diet_meal_swap_sheet.dart';
import '../widgets/meal_snap_button.dart';
import '../widgets/diet_plan_header_card.dart';
import '../widgets/diet_request_review_sheet.dart';

/// Native rebuild of `frontend/pages/diet/diet.html` + `diet.js` — the real
/// Diet screen, replacing the Phase-1 placeholder. Renders
/// `DietController.effectivePlan` (never a raw/unmodified plan), the
/// expert-review accept banner when one is pending, and wires meal swap +
/// request-review actions to the same `review_requests`/`users/{uid}`
/// records the Expert Dashboard already operates on. See
/// docs/MIGRATION_INVENTORY.md for exactly which website behaviors are
/// deferred (Personal Coaching diet mode, Snap Meal photo logging) and why.
class DietScreen extends StatelessWidget {
  const DietScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthState>().profile?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return ChangeNotifierProvider<DietController>(
      key: ValueKey(uid),
      create: (_) => DietController(
        uid: uid,
        repository: DietRepository(firestore: FirebaseFirestore.instance),
      ),
      child: const _DietBody(),
    );
  }
}

class _DietBody extends StatelessWidget {
  const _DietBody();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<DietController>();
    final userName = context.watch<AuthState>().profile?.name ?? 'User';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        body: Stack(
          children: [
            const ZitlasPremiumBackground(),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Row(
                      children: [
                        Text('🥗', style: TextStyle(fontSize: 22)),
                        SizedBox(width: 8),
                        Text(
                          'Diet Plan',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _DietContent(controller: controller, userName: userName),
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

class _DietContent extends StatelessWidget {
  const _DietContent({required this.controller, required this.userName});

  final DietController controller;
  final String userName;

  @override
  Widget build(BuildContext context) {
    if (controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final plan = controller.effectivePlan;
    if (plan == null || !plan.hasDays) {
      return DietEmptyState(onStartAssessment: () => context.push('/assessment'));
    }

    final dayIndex = controller.selectedDayIndex.clamp(0, plan.days.length - 1);
    final day = plan.days[dayIndex];
    final pendingReview = controller.pendingAcceptableReview;
    final storage = controller.dietStorage;
    // Health Status recovery override (`controller.healthOverrideAppliesTo`) —
    // swaps ONLY today's meals for the deterministic recovery template the
    // athlete's "How are you feeling today?" check-in selected. Everything
    // else on this screen (header, day selector, coach card) is untouched;
    // the underlying stored plan is never modified, so tomorrow's render of
    // this same day reverts automatically once the override no longer
    // applies (a new day, or `_hsToday` expires).
    final showsRecoveryDay = controller.healthOverrideAppliesTo(day);
    final meals = controller.effectiveMealsFor(day);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        if (pendingReview != null)
          DietExpertReviewBanner(
            review: pendingReview,
            onAccept: () => controller.acceptExpertReview(pendingReview),
          ),
        KeyedSubtree(
          key: ZinoTourKeys.dietFocusCard,
          child: DietPlanHeaderCard(
            plan: plan,
            calculations: controller.calculations,
            isExpertPlan: storage?.isExpertPlan ?? false,
            expertName: storage?.expertName,
            onRequestReview: () =>
                showRequestReviewSheet(context, controller: controller, userName: userName),
          ),
        ),
        const SizedBox(height: 16),
        DietDaySelector(
          days: plan.days,
          selectedIndex: dayIndex,
          onSelect: controller.selectDay,
        ),
        const SizedBox(height: 16),
        // The coach's prescription sits ABOVE the AI plan, not instead of it:
        // the athlete follows their coach, but the generated plan stays
        // visible and untouched underneath. Absent for anyone without a coach,
        // so this screen is unchanged for them.
        if (controller.activeCoachDiet != null)
          CoachDietCard(
            plan: controller.activeCoachDiet!,
            dayIndex: dayIndex,
            coachName: controller.coachPlan?.coachName ?? 'Your coach',
            updatedAt: controller.coachPlan?.dietUpdatedAt,
            selections: controller.coachPlan?.selections ?? const {},
            onSelect: controller.selectCoachMealOption,
            // Meal Snap lives on the COACH plan while coaching is active — the
            // athlete follows (and snaps against) the coach's prescription, and
            // the AI plan below is a read-only reference.
            controller: controller,
            athleteName: userName,
          ),
        DietDayFocusCard(day: day),
        if (day.theme != null || day.nutritionTip != null) const SizedBox(height: 16),
        if (showsRecoveryDay) ...[
          const SizedBox(height: 4),
          _RecoveryDietBanner(focus: controller.healthToday?.diet?.title),
          const SizedBox(height: 12),
        ],
        ...List.generate(meals.length, (mealIndex) {
          final meal = meals[mealIndex];
          final slot = mealSlotFromName(meal.mealName);
          return DietMealCard(
            meal: meal,
            // When a coach diet is active the snap moved UP to the coach plan
            // (that is the plan the athlete follows), and this AI plan is a
            // read-only reference — so no snap here. Without a coach diet the
            // snap sits on the AI plan as before (and renders as nothing unless
            // an active coach exists, so the no-coach case is unchanged).
            footer: controller.activeCoachDiet != null
                ? null
                : MealSnapRow(
                    controller: controller,
                    mealName: meal.mealName,
                    athleteName: userName,
                  ),
            onSwap: () => showMealSwapSheet(
              context,
              controller: controller,
              dayIndex: dayIndex,
              mealIndex: mealIndex,
              meal: meal,
            ),
            // The slot (breakfast/lunch/dinner/snack/pre_workout/
            // post_workout) — NEVER the raw, unclassified `meal.mealName`
            // ("Pre-Workout Snack" doesn't match any backend meal_type
            // value on its own). `MealSlot.unknown` (a meal name that
            // matches none of the known slots — e.g. a custom coach-added
            // meal) hides the button entirely rather than guessing which
            // recipe pool to query: no cross-slot fallback, in either
            // direction, is ever acceptable.
            onGetRecipe: slot == MealSlot.unknown
                ? null
                : () => _openRecipe(context, slot: slot, meal: meal),
          );
        }),
      ],
    );
  }
}

/// Opens a recipe for [meal], asking WHICH source first.
///
/// PRE/POST-WORKOUT NEVER SEE THE CHOICE. Those slots are served by the
/// purpose-built workout-nutrition system, which exists precisely because
/// generic recipe content is the wrong answer around training — offering a
/// YouTube search there would undo it. They go straight to the fuel/recovery
/// screen, exactly as before this feature existed.
Future<void> _openRecipe(
  BuildContext context, {
  required MealSlot slot,
  required DietMeal meal,
}) async {
  final zitlasRoute = '/recipe?meal_type=${Uri.encodeComponent(slot.apiValue)}';

  if (slot.isWorkoutSlot) {
    context.push(zitlasRoute);
    return;
  }

  final source = await showRecipeSourceSheet(context);
  if (source == null || !context.mounted) return;

  switch (source) {
    case RecipeSource.zitlas:
      context.push(zitlasRoute);
    case RecipeSource.creator:
      // Relevance is judged on the FOOD, not the slot name — "Lunch" is not
      // something a creator makes a video about. Falls back to the meal name
      // only when the plan listed no foods.
      final food = meal.foods.isNotEmpty ? meal.foods.first : meal.mealName;
      context.push(
        '/creator-recipe?food=${Uri.encodeComponent(food)}'
        '&meal_type=${Uri.encodeComponent(slot.apiValue)}',
      );
  }
}

/// `#hsDietBanner` — tells the athlete WHY today's meals look different
/// from their normal plan, and that it's temporary. Rendered directly above
/// the meal list, exactly where the website inserts it (`diet.js`'s
/// `mealList.parentNode.insertBefore(_hsBanner, mealList)`).
class _RecoveryDietBanner extends StatelessWidget {
  const _RecoveryDietBanner({required this.focus});
  final String? focus;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ZitlasTokens.primary.withValues(alpha: 0.08),
        border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: '🛟 Recovery meals for today — ', style: TextStyle(fontWeight: FontWeight.w800)),
            TextSpan(text: focus ?? "adjusted for how you're feeling"),
            const TextSpan(text: '. Your normal plan resumes tomorrow.'),
          ],
          style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textPrimary, height: 1.4),
        ),
      ),
    );
  }
}
