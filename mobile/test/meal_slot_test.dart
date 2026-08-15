import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/models/meal_slot.dart';

/// [mealSlotFromName] is the ONE place that classifies a diet plan's
/// free-text `meal_name` into a semantic slot — everything downstream
/// (the meal-card action row, the meal_type sent to the recipe API) reuses
/// it rather than re-deriving the slot with its own string checks. These
/// tests exist because the diet generator's exact wording isn't
/// contractually fixed (see routes/assessment.py's prompt schema:
/// "Breakfast | Pre-Workout | Lunch | Post-Workout | Dinner"), and a wrong
/// classification here is exactly the bug this feature-fix task reported:
/// "Pre-Workout Snack" silently being treated as a normal meal.
void main() {
  group('mealSlotFromName classifies the diet plan\'s real meal names', () {
    test('"Pre-Workout Snack" (the exact wording from the bug report) is a pre-workout slot', () {
      expect(mealSlotFromName('Pre-Workout Snack'), MealSlot.preWorkout);
    });

    test('"Pre-Workout" alone is a pre-workout slot', () {
      expect(mealSlotFromName('Pre-Workout'), MealSlot.preWorkout);
    });

    test('"Post-Workout" is a post-workout slot, never treated as a normal meal', () {
      expect(mealSlotFromName('Post-Workout'), MealSlot.postWorkout);
    });

    test('"Pre-Workout Snack" is NEVER classified as the generic "snack" slot', () {
      // The literal string contains "snack" too — this is the exact
      // ordering bug this test guards against (pre-workout must win).
      expect(mealSlotFromName('Pre-Workout Snack'), isNot(MealSlot.snack));
    });

    test('"Breakfast" resolves to breakfast', () {
      expect(mealSlotFromName('Breakfast'), MealSlot.breakfast);
    });

    test('"Lunch" resolves to lunch', () {
      expect(mealSlotFromName('Lunch'), MealSlot.lunch);
    });

    test('"Dinner" resolves to dinner', () {
      expect(mealSlotFromName('Dinner'), MealSlot.dinner);
    });

    test('case and hyphenation don\'t matter — "post workout" (no hyphen) still resolves', () {
      expect(mealSlotFromName('post workout'), MealSlot.postWorkout);
      expect(mealSlotFromName('PRE WORKOUT'), MealSlot.preWorkout);
    });

    test('an unrecognized custom meal name (added via the coach editor) falls back to snack, never breakfast', () {
      expect(mealSlotFromName('Mid-Morning'), MealSlot.snack);
    });
  });

  group('MealSlot.apiValue is exactly what the backend recipe API expects', () {
    test('workout slots map to the dedicated snake_case slot keys', () {
      expect(MealSlot.preWorkout.apiValue, 'pre_workout');
      expect(MealSlot.postWorkout.apiValue, 'post_workout');
    });

    test('normal meals map to their plain lowercase values', () {
      expect(MealSlot.breakfast.apiValue, 'breakfast');
      expect(MealSlot.lunch.apiValue, 'lunch');
      expect(MealSlot.dinner.apiValue, 'dinner');
      expect(MealSlot.snack.apiValue, 'snack');
    });

    test('mealSlotFromApiValue is the exact inverse of apiValue for every slot', () {
      for (final slot in MealSlot.values) {
        expect(mealSlotFromApiValue(slot.apiValue), slot);
      }
    });

    test('an unrecognized api value resolves to null rather than guessing', () {
      expect(mealSlotFromApiValue('dessert'), isNull);
    });
  });

  group('isWorkoutSlot / recipe screen framing', () {
    test('only the two workout slots report isWorkoutSlot', () {
      expect(MealSlot.preWorkout.isWorkoutSlot, isTrue);
      expect(MealSlot.postWorkout.isWorkoutSlot, isTrue);
      expect(MealSlot.breakfast.isWorkoutSlot, isFalse);
      expect(MealSlot.lunch.isWorkoutSlot, isFalse);
      expect(MealSlot.dinner.isWorkoutSlot, isFalse);
      expect(MealSlot.snack.isWorkoutSlot, isFalse);
    });

    test('pre/post-workout kickers are distinct from the generic recipe kicker', () {
      expect(MealSlot.preWorkout.recipeKicker, contains('Workout Fuel'));
      expect(MealSlot.postWorkout.recipeKicker, contains('Workout Recovery'));
      expect(MealSlot.breakfast.recipeKicker, isNot(contains('Workout')));
    });

    test('action button labels are distinct per slot — never the same generic wording for all three', () {
      expect(MealSlot.preWorkout.actionButtonLabel, 'Get Workout Fuel');
      expect(MealSlot.postWorkout.actionButtonLabel, 'Get Recovery Recipe');
      expect(MealSlot.breakfast.actionButtonLabel, 'Get Easy Recipe');
      expect(MealSlot.lunch.actionButtonLabel, 'Get Easy Recipe');
      expect(MealSlot.dinner.actionButtonLabel, 'Get Easy Recipe');
      expect(MealSlot.snack.actionButtonLabel, 'Get Easy Recipe');
    });
  });
}
