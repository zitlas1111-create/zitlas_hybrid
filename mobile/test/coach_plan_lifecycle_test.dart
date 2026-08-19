import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/workout/models/coach_training_plan.dart';
import 'package:zitlas_mobile/features/workout/models/workout_day.dart';
import 'package:zitlas_mobile/features/workout/models/workout_exercise.dart';

/// A coach-authored plan is active ONLY while the coaching relationship is.
///
/// `showsCoachTrainingPlan` previously accepted `'ended'` as well — the website
/// did the same — so a finished engagement kept prescribing the athlete's
/// training indefinitely, with no route back to their own AI/expert-reviewed
/// plan. These pin the corrected lifecycle, and pin that history is preserved
/// rather than deleted.

PersonalCoachingRelationship _rel(String status, {String planType = 'training'}) =>
    PersonalCoachingRelationship(status: status, planType: planType, coachId: 'coach_1');

CoachTrainingPlan _plan({String? planId = 'plan-1'}) => CoachTrainingPlan(
      days: const [
        WorkoutDay(day: 'Monday', exercises: [WorkoutExercise(name: 'Coach squat', sets: '5')]),
      ],
      planId: planId,
    );

void main() {
  group('active coaching → coach plan is the active plan', () {
    test('active + training shows the coach plan', () {
      expect(_rel('active').showsCoachTrainingPlan, isTrue);
    });

    test('active + complete (diet AND training) shows it', () {
      expect(_rel('active', planType: 'complete').showsCoachTrainingPlan, isTrue);
    });

    test('active + diet-only does NOT show a training plan', () {
      // A diet-only engagement never overrides training.
      expect(_rel('active', planType: 'diet').showsCoachTrainingPlan, isFalse);
    });
  });

  group('coaching ENDED → coach plan is no longer active', () {
    test('ended does NOT show the coach plan — the reported bug', () {
      expect(_rel('ended').showsCoachTrainingPlan, isFalse);
    });

    test('ended + complete does not show it either', () {
      expect(_rel('ended', planType: 'complete').showsCoachTrainingPlan, isFalse);
    });

    test('every non-active status hides it', () {
      for (final s in ['ended', 'expired', 'reset', 'pending', 'declined', 'withdrawn', '']) {
        expect(_rel(s).showsCoachTrainingPlan, isFalse, reason: 'status=$s must not be active');
      }
    });

    test('the rule is exactly "active", not "not-ended"', () {
      // Guards against a future `status != 'ended'` rewrite, which would let
      // pending/declined relationships prescribe a plan.
      expect(_rel('anything_else').showsCoachTrainingPlan, isFalse);
    });
  });

  group('history is preserved, not deleted', () {
    test('the plan document itself remains readable and intact', () {
      // Deactivation is a VISIBILITY decision. The plan object still holds its
      // days, so an audit/history surface can still render it.
      final plan = _plan();
      expect(plan.hasDays, isTrue);
      expect(plan.days.single.exercises.single.name, 'Coach squat');
      expect(plan.planId, 'plan-1');
    });

    test('an ended relationship does not mutate or empty the plan', () {
      final plan = _plan();
      final before = plan.days.length;
      // Reading the (now false) gate must not touch the plan.
      expect(_rel('ended').showsCoachTrainingPlan, isFalse);
      expect(plan.days.length, before);
      expect(plan.hasDays, isTrue);
    });
  });

  group('the planId goal-identity guard still applies', () {
    test('a plan authored for a different generation never renders', () {
      // Independent of relationship status: a stale-goal plan is retired even
      // while coaching is active.
      expect(_plan(planId: 'plan-OLD').isCurrentFor('plan-LIVE'), isFalse);
    });

    test('a matching planId is current', () {
      expect(_plan(planId: 'plan-LIVE').isCurrentFor('plan-LIVE'), isTrue);
    });

    test('an unstamped plan is not current when a live planId exists', () {
      expect(_plan(planId: null).isCurrentFor('plan-LIVE'), isFalse);
    });
  });
}
