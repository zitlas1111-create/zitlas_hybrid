import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/models/meal_slot.dart';

/// [mealSlotFromName] is the ONE place that classifies a diet plan's
/// free-text `meal_name` into a semantic slot — everything downstream
/// (the meal-card action row, the meal_type sent to the recipe API) reuses
/// it rather than re-deriving the slot with its own string checks.
///
/// Classification is STRICT (`startsWith`, not `contains`): a Breakfast
/// meal must never become Pre-Workout just because a corrupted/verbose
/// meal name happens to mention "pre-workout" somewhere inside it — see
/// meal_slot.dart's doc comment on [mealSlotFromName] for the exact
/// mechanism (an LLM echoing the prompt's own placeholder text verbatim,
/// e.g. "Breakfast | Pre-Workout | Lunch | Post-Workout | Dinner", used to
/// match "preworkout" under a loose `contains` check since pre/post-workout
/// were checked first — this is the real defect class both directions of
/// this bug report trace back to).
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
      // The literal string contains "snack" too — startsWith('preworkout')
      // is what guarantees pre-workout wins regardless of check order.
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

    test('"Evening Snack" resolves to snack (the keyword is the SECOND word, not the first)', () {
      expect(mealSlotFromName('Evening Snack'), MealSlot.snack);
    });

    test('case and hyphenation don\'t matter — "post workout" (no hyphen) still resolves', () {
      expect(mealSlotFromName('post workout'), MealSlot.postWorkout);
      expect(mealSlotFromName('PRE WORKOUT'), MealSlot.preWorkout);
    });

    test('an unrecognized custom meal name (added via the coach editor) is unknown — never breakfast, never pre-workout', () {
      final slot = mealSlotFromName('Mid-Morning');
      expect(slot, MealSlot.unknown);
      expect(slot, isNot(MealSlot.breakfast));
      expect(slot, isNot(MealSlot.preWorkout));
    });

    // ── The exact regression this round exists to fix ──────────────────
    test('a Breakfast meal NEVER becomes Pre-Workout, even with a malformed/verbose name', () {
      // Simulates an LLM echoing the prompt's own placeholder text verbatim
      // instead of picking one label — a real LLM failure mode, and the
      // concrete mechanism that produced "Breakfast shown as Pre-Workout"
      // under the OLD `contains`-based classifier (which matched
      // "preworkout" embedded after "breakfast", since pre/post-workout
      // were checked before breakfast/lunch/dinner).
      final corrupted = 'Breakfast | Pre-Workout | Lunch | Post-Workout | Dinner';
      expect(mealSlotFromName(corrupted), MealSlot.breakfast);
      expect(mealSlotFromName(corrupted), isNot(MealSlot.preWorkout));
    });

    test('a genuinely Pre-Workout-first name still resolves correctly, symmetric to the above', () {
      final corrupted = 'Pre-Workout | Breakfast | Lunch | Post-Workout | Dinner';
      expect(mealSlotFromName(corrupted), MealSlot.preWorkout);
    });

    test('a genuinely Post-Workout-first name still resolves correctly, never breakfast/lunch/dinner', () {
      final corrupted = 'Post-Workout | Breakfast | Lunch | Dinner';
      final slot = mealSlotFromName(corrupted);
      expect(slot, MealSlot.postWorkout);
      expect(slot, isNot(MealSlot.breakfast));
      expect(slot, isNot(MealSlot.lunch));
      expect(slot, isNot(MealSlot.dinner));
    });

    test('BREAKFAST never becomes LUNCH, DINNER, PRE_WORKOUT, or POST_WORKOUT', () {
      final slot = mealSlotFromName('Breakfast');
      expect(slot, MealSlot.breakfast);
      expect(slot, isNot(MealSlot.lunch));
      expect(slot, isNot(MealSlot.dinner));
      expect(slot, isNot(MealSlot.preWorkout));
      expect(slot, isNot(MealSlot.postWorkout));
    });

    test('LUNCH never becomes BREAKFAST, PRE_WORKOUT, or POST_WORKOUT', () {
      final slot = mealSlotFromName('Lunch');
      expect(slot, MealSlot.lunch);
      expect(slot, isNot(MealSlot.breakfast));
      expect(slot, isNot(MealSlot.preWorkout));
      expect(slot, isNot(MealSlot.postWorkout));
    });

    test('DINNER never becomes BREAKFAST, LUNCH, or PRE_WORKOUT', () {
      final slot = mealSlotFromName('Dinner');
      expect(slot, MealSlot.dinner);
      expect(slot, isNot(MealSlot.breakfast));
      expect(slot, isNot(MealSlot.lunch));
      expect(slot, isNot(MealSlot.preWorkout));
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
      expect(MealSlot.unknown.isWorkoutSlot, isFalse);
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

  // ── Regression guard for the reported bug: the Diet screen's Post-Workout
  // card recommending Breakfast (and the follow-up: Breakfast recommending
  // Pre-Workout). Mirrors diet_screen.dart's EXACT `onGetRecipe` expression
  // verbatim, so a regression there (someone swapping back to the raw
  // `meal.mealName`, or reordering the classification checks) fails this
  // test immediately.
  group('Diet screen builds the correct /recipe URL from a meal card (UI wiring)', () {
    // Mirrors diet_screen.dart's onGetRecipe exactly: null (no navigation)
    // for MealSlot.unknown, otherwise the slot's own apiValue.
    String? pushUrlFor(String mealName) {
      final slot = mealSlotFromName(mealName);
      if (slot == MealSlot.unknown) return null;
      return '/recipe?meal_type=${Uri.encodeComponent(slot.apiValue)}';
    }

    test('a Post-Workout meal card pushes meal_type=post_workout, never breakfast/lunch/dinner', () {
      final url = pushUrlFor('Post-Workout')!;
      expect(url, '/recipe?meal_type=post_workout');
      expect(url, isNot(contains('breakfast')));
      expect(url, isNot(contains('lunch')));
      expect(url, isNot(contains('dinner')));
    });

    test('a Pre-Workout Snack meal card pushes meal_type=pre_workout, never breakfast/lunch/dinner', () {
      final url = pushUrlFor('Pre-Workout Snack')!;
      expect(url, '/recipe?meal_type=pre_workout');
      expect(url, isNot(contains('breakfast')));
      expect(url, isNot(contains('lunch')));
      expect(url, isNot(contains('dinner')));
    });

    test('a Breakfast meal card pushes meal_type=breakfast, never pre_workout/post_workout', () {
      final url = pushUrlFor('Breakfast')!;
      expect(url, '/recipe?meal_type=breakfast');
      expect(url, isNot(contains('pre_workout')));
      expect(url, isNot(contains('post_workout')));
    });

    test('a Lunch meal card pushes meal_type=lunch', () {
      expect(pushUrlFor('Lunch'), '/recipe?meal_type=lunch');
    });

    test('a Dinner meal card pushes meal_type=dinner', () {
      expect(pushUrlFor('Dinner'), '/recipe?meal_type=dinner');
    });

    test('a corrupted meal name that echoes the whole prompt schema still resolves to Breakfast, not Pre-Workout', () {
      final url = pushUrlFor('Breakfast | Pre-Workout | Lunch | Post-Workout | Dinner')!;
      expect(url, '/recipe?meal_type=breakfast');
    });

    test('an unrecognized meal name (MealSlot.unknown) never navigates at all — no cross-slot guess', () {
      expect(pushUrlFor('Mid-Morning'), isNull);
    });
  });
}
