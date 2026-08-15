import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_checkin_repository.dart';
import 'package:zitlas_mobile/features/coaching/data/meal_photo_uploader.dart';
import 'package:zitlas_mobile/features/dashboard/models/health_status.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/diet/diet_controller.dart';
import 'package:zitlas_mobile/features/diet/models/diet_day.dart';
import 'package:zitlas_mobile/features/diet/models/diet_meal.dart';
import 'package:zitlas_mobile/features/diet/models/diet_plan_content.dart';
import 'package:zitlas_mobile/features/diet/models/diet_storage.dart';
import 'package:zitlas_mobile/features/experts/data/experts_repository.dart';
import 'package:zitlas_mobile/features/workout/data/workout_repository.dart';
import 'package:zitlas_mobile/features/workout/models/workout_day.dart';
import 'package:zitlas_mobile/features/workout/models/workout_exercise.dart';
import 'package:zitlas_mobile/features/workout/workout_controller.dart';

const _weekdayNames = [
  'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
];
String get _todayName => _weekdayNames[(DateTime.now().weekday - 1) % 7];
String get _tomorrowName => _weekdayNames[DateTime.now().weekday % 7];

/// A do-nothing `FirebaseAuth` — `ExpertsRepository` only needs SOME
/// instance to construct; nothing in these tests exercises auth-gated
/// behavior, so every call safely falls through to `null`.
class _FakeAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Proves the actual regression this round exists to fix: a wellness
/// check-in producing an adjustment is NOT the same as the Diet/Training
/// screens actually rendering it. Before this round, `HealthAdjustment` was
/// computed and persisted correctly but never read by `DietController` or
/// `WorkoutController` at all (confirmed by grep: neither file referenced
/// `HealthAdjustment`/`healthToday` anywhere) — so "Today's meals adjusted
/// on the Diet page" was a claim the dashboard card made that nothing
/// actually fulfilled.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  HealthAdjustment adjustmentWithDietMeals() {
    return computeHealthAdjustments(
      HealthReport(status: 'unwell', symptoms: ['Fatigue']),
      baseStepsGoal: 7000,
    );
  }

  group('DietController.healthOverrideAppliesTo / effectiveMealsFor', () {
    late DietController controller;

    setUp(() {
      final fake = FakeFirebaseFirestore();
      controller = DietController(
        uid: 'athlete-1',
        repository: DietRepository(firestore: fake),
        coachingPlans: CoachingPlanRepository(firestore: fake),
        experts: ExpertsRepository(firestore: fake, auth: _FakeAuth()),
        mealCheckins: MealCheckinRepository(firestore: fake, uploader: MealPhotoUploader(auth: _FakeAuth())),
      );
    });

    tearDown(() => controller.dispose());

    DietDay dayNamed(String name) => DietDay(
      day: name,
      meals: [DietMeal(mealName: 'Breakfast', foods: const ['Original planned meal'])],
    );

    test('applies for today when a real diet override exists and no coach plan is active', () {
      controller.healthToday = adjustmentWithDietMeals();
      final today = dayNamed(_todayName);
      expect(controller.healthOverrideAppliesTo(today), isTrue);

      final effective = controller.effectiveMealsFor(today);
      expect(effective, isNot(same(today.meals)), reason: 'must be the recovery template, not the original meals');
      expect(effective.every((m) => m.recovery), isTrue);
    });

    test('does NOT apply to a different day than today', () {
      controller.healthToday = adjustmentWithDietMeals();
      final tomorrow = dayNamed(_tomorrowName);
      expect(controller.healthOverrideAppliesTo(tomorrow), isFalse);
      expect(controller.effectiveMealsFor(tomorrow), same(tomorrow.meals));
    });

    test('does NOT apply when there is no health check-in today', () {
      controller.healthToday = null;
      final today = dayNamed(_todayName);
      expect(controller.healthOverrideAppliesTo(today), isFalse);
    });

    test('"Feeling Great" produces a null diet block, so it never overrides anything', () {
      controller.healthToday = computeHealthAdjustments(HealthReport(status: 'great'), baseStepsGoal: 7000);
      final today = dayNamed(_todayName);
      expect(controller.healthOverrideAppliesTo(today), isFalse);
    });

    test('never applies over an active expert/coach-authored plan', () {
      controller.healthToday = adjustmentWithDietMeals();
      final plan = DietPlanContent(days: [dayNamed(_todayName)]);
      controller.dietStorage = DietStorage(originalDietPlan: plan, currentDietPlan: plan, isExpertPlan: true);
      expect(controller.healthOverrideAppliesTo(dayNamed(_todayName)), isFalse);
    });

    test('the base stored plan itself is never mutated by the override', () {
      controller.healthToday = adjustmentWithDietMeals();
      final today = dayNamed(_todayName);
      final originalMealsRef = today.meals;
      controller.effectiveMealsFor(today);
      expect(today.meals, same(originalMealsRef), reason: 'reading the override must not mutate the DietDay');
    });
  });

  group('WorkoutController.healthOverrideAppliesTo / effectiveExercisesFor', () {
    late WorkoutController controller;

    setUp(() {
      controller = WorkoutController(uid: 'athlete-1', repository: WorkoutRepository(FakeFirebaseFirestore()));
    });

    tearDown(() => controller.dispose());

    WorkoutDay dayNamed(String name) => WorkoutDay(
      day: name,
      exercises: const [WorkoutExercise(name: 'Original heavy squat session', sets: '5')],
    );

    test('applies for today when the check-in actually produced replacement exercises', () {
      controller.healthToday = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 9),
        baseStepsGoal: 7000,
      );
      final today = dayNamed(_todayName);
      expect(controller.healthOverrideAppliesTo(today), isTrue);
      final exercises = controller.effectiveExercisesFor(today);
      expect(exercises, isNot(same(today.exercises)));
      expect(exercises, isNotEmpty);
    });

    test('a moderate-stress adjustment (empty exercise list) never overrides the real session', () {
      controller.healthToday = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 4),
        baseStepsGoal: 7000,
      );
      final today = dayNamed(_todayName);
      expect(controller.healthOverrideAppliesTo(today), isFalse);
      expect(controller.effectiveExercisesFor(today), same(today.exercises));
    });

    test('does not apply to a different weekday', () {
      controller.healthToday = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 9),
        baseStepsGoal: 7000,
      );
      expect(controller.healthOverrideAppliesTo(dayNamed(_tomorrowName)), isFalse);
    });

    test('the base stored workout day is never mutated', () {
      controller.healthToday = computeHealthAdjustments(
        HealthReport(status: 'stress', stressLevel: 9),
        baseStepsGoal: 7000,
      );
      final today = dayNamed(_todayName);
      final originalRef = today.exercises;
      controller.effectiveExercisesFor(today);
      expect(today.exercises, same(originalRef));
    });
  });
}
