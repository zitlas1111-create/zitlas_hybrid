/// The semantic purpose of a diet-plan meal slot — distinct from the
/// LLM-generated `DietMeal.mealName` free text ("Breakfast", "Pre-Workout
/// Snack", "Post-Workout", ... — see routes/assessment.py's prompt schema),
/// which is never contractually fixed wording. This is the ONE place that
/// classifies a meal name into a slot; nothing else should re-derive it with
/// its own ad hoc string checks (diet_meal_card.dart and recipe_screen.dart
/// both reuse [mealSlotFromName]/[mealSlotFromApiValue]).
enum MealSlot { breakfast, lunch, dinner, snack, preWorkout, postWorkout }

extension MealSlotX on MealSlot {
  /// The exact `meal_type` query value `GET /api/recipes/recommended`
  /// understands (see backend/services/recipe_service.py's
  /// `resolve_meal_slot()` for the workout slots and `_MEAL_TYPE_ALIASES`
  /// for the rest) — never the raw meal name.
  String get apiValue => switch (this) {
        MealSlot.breakfast => 'breakfast',
        MealSlot.lunch => 'lunch',
        MealSlot.dinner => 'dinner',
        MealSlot.snack => 'snack',
        MealSlot.preWorkout => 'pre_workout',
        MealSlot.postWorkout => 'post_workout',
      };

  bool get isWorkoutSlot => this == MealSlot.preWorkout || this == MealSlot.postWorkout;

  /// Recipe screen heading (item 16) — never the generic "ZITLAS Recipe"
  /// wording for a workout slot, so the athlete can tell at a glance this
  /// isn't just another breakfast/lunch/dinner pick.
  String get recipeKicker => switch (this) {
        MealSlot.preWorkout => '⚡ Pre-Workout',
        MealSlot.postWorkout => '💪 Post-Workout',
        _ => '🍳 ZITLAS Recipe',
      };

  String get recipeSubtitle => switch (this) {
        MealSlot.preWorkout => 'Quick energy before your workout',
        MealSlot.postWorkout => 'Recovery-focused nutrition after training',
        _ => '',
      };
}

/// Classifies a plan's free-text `meal_name` into a [MealSlot]. Keyword-based
/// rather than an exact-string switch since the generator's exact wording
/// isn't fixed (e.g. "Pre-Workout" vs "Pre-Workout Snack"). An unrecognized
/// name (a custom meal added via the coach editor, e.g. "Mid-Morning") is
/// treated as a generic snack rather than defaulting to breakfast — item 10's
/// "never fall back to the closest generic meal type" applies just as much to
/// classification as it does to the backend's own recommendation pool.
MealSlot mealSlotFromName(String mealName) {
  final compact = mealName.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (compact.contains('preworkout')) return MealSlot.preWorkout;
  if (compact.contains('postworkout')) return MealSlot.postWorkout;
  if (compact.contains('breakfast')) return MealSlot.breakfast;
  if (compact.contains('lunch')) return MealSlot.lunch;
  if (compact.contains('dinner')) return MealSlot.dinner;
  return MealSlot.snack;
}

/// The reverse of [MealSlot.apiValue] — used by the recipe screen to render
/// the right kicker/subtitle for whatever `meal_type` it was opened with.
MealSlot? mealSlotFromApiValue(String value) {
  for (final slot in MealSlot.values) {
    if (slot.apiValue == value) return slot;
  }
  return null;
}
