import 'package:flutter/material.dart';

/// The semantic purpose of a diet-plan meal slot — distinct from the
/// LLM-generated `DietMeal.mealName` free text ("Breakfast", "Pre-Workout
/// Snack", "Post-Workout", ... — see routes/assessment.py's prompt schema),
/// which is never contractually fixed wording. This is the ONE place that
/// classifies a meal name into a slot; nothing else should re-derive it with
/// its own ad hoc string checks (diet_meal_card.dart and diet_screen.dart
/// both reuse [mealSlotFromName]/[mealSlotFromApiValue]).
///
/// There is NO separate structured slot field anywhere in the diet-plan
/// data model to read instead — checked directly against every diet
/// generation path in backend/routes/assessment.py (all four JSON schemas:
/// the three "Breakfast | Mid-Morning | Lunch | Evening Snack | Dinner"
/// variants and the one transformation-goal "Breakfast | Pre-Workout |
/// Lunch | Post-Workout | Dinner" variant, plus the deterministic
/// no-LLM fallback generator) — `meal_name` free text is the ONLY field
/// that ever carries this information, for every plan type. Classifying
/// from it is therefore not a workaround; it is the only available source
/// of truth.
///
/// PRE_WORKOUT/POST_WORKOUT are NOT "a normal recipe with a fitness tag" —
/// the backend serves them from a completely separate, dedicated
/// workout-nutrition dataset (see backend/services/workout_nutrition_service.py),
/// never the 637-recipe database breakfast/lunch/dinner/snack use.
enum MealSlot { breakfast, lunch, dinner, snack, preWorkout, postWorkout, unknown }

extension MealSlotX on MealSlot {
  /// The exact `meal_type` query value `GET /api/recipes/recommended`
  /// understands (see backend/services/recipe_service.py's
  /// `resolve_meal_slot()` for the workout slots and `_MEAL_TYPE_ALIASES`
  /// for the rest) — never the raw meal name. [MealSlot.unknown] is never
  /// actually sent (see diet_screen.dart, which hides the recipe button
  /// entirely for an unrecognized meal name); this value exists only so a
  /// direct/defensive call degrades to a controlled empty result instead of
  /// guessing a real slot.
  String get apiValue => switch (this) {
        MealSlot.breakfast => 'breakfast',
        MealSlot.lunch => 'lunch',
        MealSlot.dinner => 'dinner',
        MealSlot.snack => 'snack',
        MealSlot.preWorkout => 'pre_workout',
        MealSlot.postWorkout => 'post_workout',
        MealSlot.unknown => 'unknown',
      };

  bool get isWorkoutSlot => this == MealSlot.preWorkout || this == MealSlot.postWorkout;

  /// Recipe screen heading — never the generic "ZITLAS Recipe" wording for
  /// a workout slot, so the athlete can tell at a glance this isn't just
  /// another breakfast/lunch/dinner pick, and never reads as "a recipe".
  String get recipeKicker => switch (this) {
        MealSlot.preWorkout => '⚡ Workout Fuel',
        MealSlot.postWorkout => '💪 Workout Recovery',
        _ => '🍳 ZITLAS Recipe',
      };

  String get recipeSubtitle => switch (this) {
        MealSlot.preWorkout => 'Quick energy before your workout',
        MealSlot.postWorkout => 'Recovery-focused nutrition after training',
        _ => '',
      };

  /// The Diet meal card's action-button wording — deliberately distinct
  /// per slot ("Do NOT use the same generic 'Get Easy Recipe' wording for
  /// all three").
  String get actionButtonLabel => switch (this) {
        MealSlot.preWorkout => 'Get Workout Fuel',
        MealSlot.postWorkout => 'Get Recovery Recipe',
        _ => 'Get Easy Recipe',
      };

  IconData get actionButtonIcon => switch (this) {
        MealSlot.preWorkout => Icons.bolt,
        MealSlot.postWorkout => Icons.fitness_center,
        _ => Icons.egg_alt_outlined,
      };

  /// The loading screen's "Finding ___ for you…" phrase — kept slot-aware
  /// so even the loading state never implies a workout slot is "a recipe".
  String get findingLabel => switch (this) {
        MealSlot.preWorkout => 'workout fuel',
        MealSlot.postWorkout => 'a recovery option',
        _ => 'the best ZITLAS recipe',
      };
}

/// Classifies a plan's free-text `meal_name` into a [MealSlot].
///
/// STRICT by design: matches only when the slot's keyword is the FIRST
/// thing the (letter-only, lowercased) name says, not merely present
/// somewhere inside it. A loose "does this string CONTAIN preworkout
/// anywhere" check is exactly what let a corrupted/verbose meal name
/// misclassify — e.g. an LLM echoing the prompt's own placeholder text
/// verbatim ("Breakfast | Pre-Workout | Lunch | Post-Workout | Dinner")
/// instead of picking one label would, under a `contains` check, match
/// "preworkout" (embedded after "breakfast") and silently turn a Breakfast
/// meal into Pre-Workout, since pre/post-workout were checked first. Under
/// `startsWith`, that same corrupted string starts with "breakfast" and
/// classifies as Breakfast — the first-mentioned label, and the only
/// defensible reading of malformed data. This also means check ORDER no
/// longer matters: a string can start with at most one candidate.
///
/// "Snack" is checked as a `contains`, not `startsWith`, because it
/// legitimately appears as the SECOND word in real generated names
/// ("Evening Snack") — the ambiguity risk that motivates `startsWith` for
/// the other five is specific to them being alternately a normal-meal
/// keyword AND a workout-purpose keyword; snack has no such conflict.
///
/// A name matching NONE of the six known slots (e.g. "Mid-Morning", a
/// custom meal added via the coach editor) returns [MealSlot.unknown] —
/// never a guess at breakfast, and never a guess at pre-workout. Callers
/// (diet_screen.dart) must treat [MealSlot.unknown] as "no recipe
/// recommendation available for this meal", not silently substitute one.
MealSlot mealSlotFromName(String mealName) {
  final compact = mealName.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (compact.startsWith('preworkout')) return MealSlot.preWorkout;
  if (compact.startsWith('postworkout')) return MealSlot.postWorkout;
  if (compact.startsWith('breakfast')) return MealSlot.breakfast;
  if (compact.startsWith('lunch')) return MealSlot.lunch;
  if (compact.startsWith('dinner')) return MealSlot.dinner;
  if (compact.contains('snack')) return MealSlot.snack;
  return MealSlot.unknown;
}

/// The reverse of [MealSlot.apiValue] — used by the recipe screen to render
/// the right kicker/subtitle for whatever `meal_type` it was opened with.
MealSlot? mealSlotFromApiValue(String value) {
  for (final slot in MealSlot.values) {
    if (slot.apiValue == value) return slot;
  }
  return null;
}
