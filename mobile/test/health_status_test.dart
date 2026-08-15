import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/dashboard/models/health_status.dart';
import 'package:zitlas_mobile/features/diet/models/diet_meal.dart';
import 'package:zitlas_mobile/features/workout/models/workout_exercise.dart';

/// `computeHealthAdjustments` — the deterministic rule engine behind the
/// "How are you feeling today?" check-in. These tests exist because the
/// feature had ZERO test coverage before this round (verified: no test file
/// anywhere references it), and specifically guard the fix for the reported
/// bug: selecting a wellness reason produced an adjustment whose `diet`/
/// `workout` blocks carried only informational bullet TEXT (`items`), never
/// an actual replacement meal/exercise LIST — so nothing the athlete could
/// see on the Diet/Training screens ever changed. `meals` is that list.
void main() {
  group('"Feeling Great" — no adjustment at all', () {
    test('produces no workout or diet override', () {
      final adj = computeHealthAdjustments(HealthReport(status: 'great'), baseStepsGoal: 7000);
      expect(adj.workout, isNull);
      expect(adj.diet, isNull);
      expect(adj.stepsGoal, 7000);
      expect(adj.safety, isFalse);
    });
  });

  group('Very Tired (status=unwell, symptom=Fatigue) — a real workout AND diet change', () {
    test('workout is reduced to mobility-only, not a normal session', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'unwell', symptoms: ['Fatigue']),
        baseStepsGoal: 7000,
      );
      expect(adj.workout?.mode, 'mobility');
      expect(adj.workout!.items, isNotEmpty);
    });

    test('diet actually carries a replacement meal list, not just bullet text', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'unwell', symptoms: ['Fatigue']),
        baseStepsGoal: 7000,
      );
      expect(adj.diet, isNotNull);
      expect(adj.diet!.meals, isNotEmpty, reason: 'this is the exact regression: meals used to be silently dropped');
      // Every entry must be genuinely DietMeal.fromMap-compatible.
      final meal = DietMeal.fromMap(adj.diet!.meals.first);
      expect(meal.mealName, isNotEmpty);
      expect(meal.recovery, isTrue, reason: 'a recovery meal must disable Swap on the card, same as the website');
    });

    test('steps goal is reduced, never left at the normal target', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'unwell', symptoms: ['Fatigue']),
        baseStepsGoal: 7000,
      );
      expect(adj.stepsGoal, lessThan(7000));
    });
  });

  group('Poor Sleep — workout adjusted, diet gets a real meal list', () {
    test('under 5 hours slept -> a light recovery session', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'poor_sleep', sleepHours: 3),
        baseStepsGoal: 7000,
      );
      expect(adj.workout?.title, contains('recovery session'));
      expect(adj.diet!.meals, isNotEmpty);
    });

    test('a normal night (7h) still reduces intensity, but less aggressively', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'poor_sleep', sleepHours: 7),
        baseStepsGoal: 7000,
      );
      expect(adj.workout?.title, 'Reduce intensity today');
      expect(adj.stepsGoal, (7000 * 0.8).round());
    });
  });

  group('Pain / Injury — workout modified around the injury, never a normal hard session', () {
    test('a knee injury removes leg work, keeps upper-body strength', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'injured', bodyParts: ['Knee'], painLevel: 5),
        baseStepsGoal: 7000,
      );
      expect(adj.workout?.mode, 'modified');
      expect(adj.workout!.items, contains(contains('Leg work removed')));
      expect(adj.diet!.meals, isNotEmpty);
    });

    test('pain level 8+ trips the safety gate — no workout at all, coach-review posture', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'injured', bodyParts: ['Knee'], painLevel: 8),
        baseStepsGoal: 7000,
      );
      expect(adj.safety, isTrue);
      expect(adj.workout?.mode, 'none');
      expect(adj.workout!.meals, isEmpty, reason: 'safety-gate workout is a hard stop, not a substitute session');
      expect(adj.diet!.meals, isNotEmpty, reason: 'diet still gets a real gentle-recovery meal list even under the safety gate');
    });
  });

  group('Stomach Discomfort (modelled as unwell/other + symptom) — lighter diet', () {
    test('Stomach Pain produces a light/easy-to-digest recovery diet', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'unwell', symptoms: ['Stomach Pain']),
        baseStepsGoal: 7000,
      );
      expect(adj.diet, isNotNull);
      expect(adj.diet!.meals, isNotEmpty);
    });
  });

  group('Sick / Fever — rest, never strenuous exercise, practical nutrition only', () {
    test('workout is cancelled outright (Recovery Day), not just reduced', () {
      final adj = computeHealthAdjustments(HealthReport(status: 'sick'), baseStepsGoal: 7000);
      expect(adj.workout?.mode, 'rest');
      expect(adj.workout!.meals, isEmpty, reason: 'rest day has no substitute exercises to do');
      expect(adj.diet!.meals, isNotEmpty);
    });

    test('a critical pre-existing condition trips the safety gate for a sick report', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'sick'),
        baseStepsGoal: 7000,
        hasCriticalCondition: true,
      );
      expect(adj.safety, isTrue);
    });
  });

  group('Stressed / Mentally Drained — reduced, never a full activity wipeout', () {
    test('high stress (8+) drops to calming mobility work, not zero activity', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 9),
        baseStepsGoal: 7000,
      );
      expect(adj.workout?.mode, 'mobility');
      expect(adj.workout!.meals, isNotEmpty, reason: 'high stress genuinely replaces the session with calming movement');
    });

    test('moderate stress keeps the normal workout — no exercise substitution forced', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 4),
        baseStepsGoal: 7000,
      );
      expect(adj.workout?.mode, 'reduced');
      expect(adj.workout!.meals, isEmpty, reason: '"Moderate workout is fine" must not force a substitute session');
    });
  });

  group('Every non-empty workout.meals block is genuinely WorkoutExercise-compatible', () {
    test('a mobility override parses into real exercises', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 9),
        baseStepsGoal: 7000,
      );
      final exercises = adj.workout!.meals.map(WorkoutExercise.fromMap).toList();
      expect(exercises, isNotEmpty);
      expect(exercises.first.name, isNotEmpty);
    });
  });

  group('HealthAdjustment round-trips through toMap/fromMap without losing meals', () {
    test('diet.meals and workout.meals both survive a save/load cycle', () {
      final original = computeHealthAdjustments(
        HealthReport(status: 'unwell', symptoms: ['Fatigue']),
        baseStepsGoal: 7000,
      );
      final restored = HealthAdjustment.fromMap(original.toMap());
      expect(restored.diet!.meals, isNotEmpty);
      expect(restored.diet!.meals.length, original.diet!.meals.length);
      expect(restored.workout!.meals.length, original.workout!.meals.length);
    });
  });
}
