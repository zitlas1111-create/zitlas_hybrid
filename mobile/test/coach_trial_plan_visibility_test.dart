import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/diet_precedence.dart';
import 'package:zitlas_mobile/features/workout/models/coach_training_plan.dart';

/// A FREE TRIAL MUST SHOW THE COACH'S PLAN.
///
/// THE BUG THIS PINS. `routes/coaching.py` sets `plan_type_val = None` for a
/// FREE_TRIAL request — a trial is not one of the three paid plans — and
/// `/accept` copies that straight onto `personal_coaching/{uid}`. So a trial
/// relationship carries `planType: null`.
///
/// The COACH side already tolerated that (`cprofile.js` opens the workspace
/// with `planType: rel.planType || 'complete'`, and Flutter's
/// `canEditDiet` includes `planType == null`), which is why a nutritionist
/// could open the athlete, edit the diet and publish it successfully.
///
/// The ATHLETE side did not. `null` matched neither 'diet' nor 'complete', so
/// the plan was written to `coaching_plans` and the athlete's Diet page never
/// attached the listener, never rendered the meals, and never showed the
/// "Diet managed by [coach]" attribution. The athlete kept seeing their AI
/// plan while the expert saw a successful save.
void main() {
  PersonalCoachingRelationship rel({
    String status = 'active',
    String? planType,
    String coachingType = 'FREE_TRIAL',
  }) =>
      PersonalCoachingRelationship.fromMap({
        'coachId': 'expert_1',
        'coachName': 'Pavan Kumar',
        'athleteId': 'athlete_1',
        'status': status,
        'planType': planType,
        'coachingType': coachingType,
        'endDate': DateTime.now()
            .add(const Duration(days: 5))
            .toIso8601String(),
      });

  group('a free trial (planType null) shows the coach plan', () {
    test('training plan is visible', () {
      expect(rel(planType: null).showsCoachTrainingPlan, isTrue,
          reason: 'a trial stores planType null; refusing it means the coach '
              'publishes a plan the athlete can never see');
    });

    test('the diet gate uses the same rule', () {
      // The diet gate is the shared precedence rule (diet_precedence.dart,
      // identical to the website's diet-precedence.js), so it is exercised
      // directly with a trial's null planType.
      final trial = DietPrecedenceInput(
        now: DateTime.now(),
        hasRelationship: true,
        relStatus: 'active',
        relCoachId: 'expert_1',
        relPlanType: null,
        hasCoachPlan: true,
        coachPlanCoachId: 'expert_1',
        coachMealCount: 1,
      );
      expect(coachDietActive(trial), isTrue,
          reason: 'the diet gate must default a null planType to full '
              'coverage, exactly as the training gate and the coach side do');
    });
  });

  group('the paid plans are unchanged', () {
    test('complete shows training', () {
      expect(rel(planType: 'complete').showsCoachTrainingPlan, isTrue);
    });

    test('training shows training', () {
      expect(rel(planType: 'training').showsCoachTrainingPlan, isTrue);
    });

    test('a DIET-only plan does NOT show training', () {
      expect(rel(planType: 'diet').showsCoachTrainingPlan, isFalse,
          reason: 'a diet-only engagement must not prescribe training');
    });
  });

  group('the relationship must still be active', () {
    for (final status in ['ended', 'reset', 'pending', 'declined']) {
      test('$status does not show the coach plan', () {
        expect(rel(status: status, planType: null).showsCoachTrainingPlan,
            isFalse,
            reason: 'a finished or retired engagement must hand the athlete '
                'back to their own plan');
      });
    }

    test('a reset relationship is refused even for a trial', () {
      // Goal Reset retires the relationship to 'reset' — the athlete's brand
      // new AI plan must not be overridden by the previous coach's.
      expect(rel(status: 'reset', planType: null).showsCoachTrainingPlan,
          isFalse);
    });
  });

  group('the two clients cannot disagree', () {
    test('the website diet gate defaults null to complete', () {
      final f = File('../frontend/website/pages/diet/diet.js');
      if (!f.existsSync()) {
        markTestSkipped('website source not reachable from this run');
        return;
      }
      final src = f.readAsStringSync();
      final start = src.indexOf('function _pcShowsCoachPlan()');
      expect(start, greaterThan(-1));
      final body = src.substring(start, start + 320);
      expect(body.contains("planType || 'complete'"), isTrue,
          reason: 'the website must apply the same null default, or an '
              'athlete would see the coach plan on one client only');
    });

    test('the website training gate defaults null to complete', () {
      final f = File(
          '../frontend/website/pages/dashboard/weekly-plan/weekly-plan.js');
      if (!f.existsSync()) {
        markTestSkipped('website source not reachable from this run');
        return;
      }
      expect(f.readAsStringSync().contains("planType || 'complete'"), isTrue);
    });
  });
}
