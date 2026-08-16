import 'package:flutter/foundation.dart';

/// Who actually cooks the athlete's food. Drives what "realistic" means:
/// a hostel resident cannot be told to slow-cook a curry, and someone whose
/// family cooks can't unilaterally change the household menu.
enum MealPreparer {
  family('family', '👨‍👩‍👧', 'Family cooks'),
  self('self', '🧑‍🍳', 'I cook'),
  hostelMess('hostel_mess', '🏫', 'Hostel mess'),
  tiffin('tiffin', '🍱', 'Tiffin service'),
  restaurant('restaurant', '🍽', 'Restaurant / outside'),
  cook('cook', '👩‍🍳', 'Cook at home');

  const MealPreparer(this.id, this.icon, this.label);
  final String id, icon, label;

  static MealPreparer? fromId(String? id) {
    for (final v in values) {
      if (v.id == id) return v;
    }
    return null;
  }
}

/// Maps onto the engine's existing `dietSuitable` tags — no new vocabulary.
enum DietPreference {
  vegetarian('Vegetarian', '🥦', 'Vegetarian'),
  eggetarian('Eggitarian', '🥚', 'Eggetarian'),
  nonVegetarian('Non-Vegetarian', '🍗', 'Non-vegetarian'),
  vegan('Vegan', '🌱', 'Vegan');

  /// The value the backend's `diet_tags_from_lifestyle` already understands.
  const DietPreference(this.id, this.icon, this.label);
  final String id, icon, label;

  static DietPreference? fromId(String? id) {
    for (final v in values) {
      if (v.id == id) return v;
    }
    return null;
  }
}

/// Budget tier. Maps to the engine's existing Low/Medium/High `budgetCategory`.
enum FoodBudget {
  economy('Low', '💰', 'Economy', 'Everyday, affordable foods'),
  standard('Medium', '💳', 'Standard', 'A balanced mix'),
  premium('High', '💎', 'Premium', 'No cost restriction');

  const FoodBudget(this.engineTier, this.icon, this.label, this.blurb);

  /// The tier string `budget_tier_from_lifestyle` already produces.
  final String engineTier;
  final String icon, label, blurb;

  static FoodBudget? fromEngineTier(String? t) {
    for (final v in values) {
      if (v.engineTier == t) return v;
    }
    return null;
  }
}

/// The athlete's permanent food profile — asked ONCE, editable forever after.
///
/// This is what lets ZITLAS recommend food someone can actually eat today
/// rather than food that merely scores well: a plan built without knowing who
/// cooks, what they can afford, and what they already like is a nutrition
/// exercise, not a usable diet.
///
/// Deliberately ONE Firestore block (`users/{uid}.dietProfile`) rather than
/// eight loose fields — it is written and read as a unit, and a partial write
/// would leave the engine personalising on half a picture.
///
/// LOCATION IS NOT HERE, on purpose: region comes from GPS
/// (`preferredDietRegion`) and is never asked for as a question.
@immutable
class DietProfile {
  const DietProfile({
    this.preparer,
    this.dietPreference,
    this.neverEaten = const [],
    this.allergies = const [],
    this.budget,
    this.lovedFoods = const [],
    this.dislikedFoods = const [],
    this.mealsPerDay = 3,
    this.completedAt,
  });

  final MealPreparer? preparer;
  final DietPreference? dietPreference;

  /// Foods the athlete has never eaten — excluded like a dislike, but kept
  /// separate because the reason differs and the athlete may want to revisit.
  final List<String> neverEaten;

  /// Hard safety exclusions. Never relaxed by any fallback, ever.
  final List<String> allergies;

  final FoodBudget? budget;
  final List<String> lovedFoods;
  final List<String> dislikedFoods;
  final int mealsPerDay;
  final DateTime? completedAt;

  /// The profile is usable once the questions that actually gate a safe,
  /// realistic plan are answered. Likes/dislikes/never-eaten are genuinely
  /// optional — an empty list is a valid answer, not an unfinished one.
  bool get isComplete =>
      preparer != null && dietPreference != null && budget != null;

  DietProfile copyWith({
    MealPreparer? preparer,
    DietPreference? dietPreference,
    List<String>? neverEaten,
    List<String>? allergies,
    FoodBudget? budget,
    List<String>? lovedFoods,
    List<String>? dislikedFoods,
    int? mealsPerDay,
    DateTime? completedAt,
  }) =>
      DietProfile(
        preparer: preparer ?? this.preparer,
        dietPreference: dietPreference ?? this.dietPreference,
        neverEaten: neverEaten ?? this.neverEaten,
        allergies: allergies ?? this.allergies,
        budget: budget ?? this.budget,
        lovedFoods: lovedFoods ?? this.lovedFoods,
        dislikedFoods: dislikedFoods ?? this.dislikedFoods,
        mealsPerDay: mealsPerDay ?? this.mealsPerDay,
        completedAt: completedAt ?? this.completedAt,
      );

  Map<String, dynamic> toMap() => {
        'preparer': preparer?.id,
        'dietPreference': dietPreference?.id,
        'neverEaten': neverEaten,
        'allergies': allergies,
        'budget': budget?.engineTier,
        'lovedFoods': lovedFoods,
        'dislikedFoods': dislikedFoods,
        'mealsPerDay': mealsPerDay,
        'completedAt': completedAt?.toIso8601String(),
      };

  static DietProfile fromMap(Map<String, dynamic>? m) {
    if (m == null) return const DietProfile();
    List<String> strings(Object? v) =>
        v is List ? [for (final e in v) e.toString()] : const [];
    return DietProfile(
      preparer: MealPreparer.fromId(m['preparer'] as String?),
      dietPreference: DietPreference.fromId(m['dietPreference'] as String?),
      neverEaten: strings(m['neverEaten']),
      allergies: strings(m['allergies']),
      budget: FoodBudget.fromEngineTier(m['budget'] as String?),
      lovedFoods: strings(m['lovedFoods']),
      dislikedFoods: strings(m['dislikedFoods']),
      mealsPerDay: (m['mealsPerDay'] as num?)?.toInt() ?? 3,
      completedAt: DateTime.tryParse(m['completedAt'] as String? ?? ''),
    );
  }

  /// The shape the BACKEND already understands.
  ///
  /// Deliberately mapped onto `lifestyle_data`'s existing keys rather than a
  /// new schema: `diet_type`, `daily_budget`, `living_situation`,
  /// `favorite_foods`, `disliked_foods` and `allergies` are what
  /// `_engine_query_context` already reads, so this profile personalises the
  /// engine without a parallel pipeline to keep in sync.
  Map<String, dynamic> toLifestyleData() => {
        if (dietPreference != null) 'diet_type': dietPreference!.id,
        if (budget != null) 'daily_budget': _budgetToDailyRupees(budget!),
        if (preparer != null) 'living_situation': _preparerToLivingSituation(preparer!),
        // ONLY when actually set — this map is spread LAST over the
        // assessment's own values (see DietController.swapMeal), so an
        // unconditional empty list here silently erased the athlete's
        // Assessment food preferences on every swap. Nothing collects
        // `lovedFoods` yet, so that was every athlete, always.
        // Conditional emission matches the other fields above and preserves
        // the documented precedence: the permanent profile wins when it has
        // an answer, the assessment is the fallback when it doesn't.
        if (lovedFoods.isNotEmpty) 'favorite_foods': lovedFoods,
        // Never-eaten foods behave exactly like dislikes at selection time.
        'disliked_foods': [...dislikedFoods, ...neverEaten],
        'allergies': allergies,
        'meals_per_day': mealsPerDay,
        if (preparer != null) 'meal_preparer': preparer!.id,
      };

  /// `budget_tier_from_lifestyle` parses a rupee figure out of this string,
  /// so the midpoint of each tier is what it should see.
  static String _budgetToDailyRupees(FoodBudget b) => switch (b) {
        FoodBudget.economy => '70',
        FoodBudget.standard => '150',
        FoodBudget.premium => '400',
      };

  /// `living_tag_from_lifestyle` maps these onto the dataset's
  /// `livingSuitable` tags (Home / Hostel / PG).
  static String _preparerToLivingSituation(MealPreparer p) => switch (p) {
        MealPreparer.family || MealPreparer.cook || MealPreparer.self => 'Home',
        MealPreparer.hostelMess => 'Hostel',
        MealPreparer.tiffin || MealPreparer.restaurant => 'PG',
      };
}
