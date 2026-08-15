import 'package:flutter/foundation.dart';

import '../../../core/util/json_coerce.dart';

/// One ZITLAS recipe, copied field-for-field from `GET /api/recipes/*`
/// (backend/routes/recipes.py + services/recipe_service.py) — the SAME 637-
/// recipe dataset (backend/recipes/data/zitlas_recipes.json) the website's
/// Diet section reads, never duplicated into the app. Field names match the
/// backend schema exactly (see recipe_service.py's REQUIRED_FIELDS); nothing
/// here renames, drops, or reinterprets a field.
@immutable
class Recipe {
  const Recipe({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.mealType,
    required this.fitnessGoals,
    required this.dietType,
    required this.servings,
    required this.prepTimeMin,
    required this.cookTimeMin,
    required this.totalTimeMin,
    required this.difficulty,
    required this.equipment,
    required this.costLevel,
    required this.ingredients,
    required this.instructions,
    required this.caloriesKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.fiberG,
    required this.primaryProteinSources,
    required this.whyItWorks,
    required this.tags,
    required this.regionalTag,
    required this.hostelFriendly,
    required this.homeFriendly,
    required this.zitlasOriginal,
  });

  final String id;
  final String name;
  final String description;
  final String category;
  final List<String> mealType;
  final List<String> fitnessGoals;
  final String dietType;
  final int servings;
  final int prepTimeMin;
  final int cookTimeMin;
  final int totalTimeMin;
  final String difficulty;
  final List<String> equipment;
  final String costLevel;

  /// Full ingredient lines WITH exact quantities (e.g. "Sattu — 40 g"),
  /// verbatim from the dataset — never re-derived or summarized.
  final List<String> ingredients;

  /// Numbered steps, in order — index 0 is step 1.
  final List<String> instructions;

  // `nutrition_estimated.*` flattened — every consumer needs these
  // individually (macro row, nutrition grid), and Recipe is otherwise flat.
  final num? caloriesKcal;
  final num? proteinG;
  final num? carbsG;
  final num? fatG;
  final num? fiberG;

  final List<String> primaryProteinSources;
  final List<String> whyItWorks;
  final List<String> tags;

  /// e.g. "Maharashtrian-inspired" — null for a large share of the dataset
  /// (no specific regional origin), which is real data, not a gap.
  final String? regionalTag;

  final bool hostelFriendly;
  final bool homeFriendly;
  final bool zitlasOriginal;

  int get totalTimeComputed => prepTimeMin + cookTimeMin;

  static Recipe? fromMap(Map<String, dynamic> m) {
    final id = asText(m['id']);
    final name = asText(m['name']);
    if (id == null || name == null) return null;
    final nutrition = asMap(m['nutrition_estimated']) ?? const {};
    return Recipe(
      id: id,
      name: name,
      description: asText(m['description']) ?? '',
      category: asText(m['category']) ?? '',
      mealType: asStringList(m['meal_type']),
      fitnessGoals: asStringList(m['fitness_goals']),
      dietType: asText(m['diet_type']) ?? '',
      servings: asInt(m['servings']) ?? 1,
      prepTimeMin: asInt(m['prep_time_min']) ?? 0,
      cookTimeMin: asInt(m['cook_time_min']) ?? 0,
      totalTimeMin: asInt(m['total_time_min']) ?? 0,
      difficulty: asText(m['difficulty']) ?? '',
      equipment: asStringList(m['equipment']),
      costLevel: asText(m['cost_level']) ?? '',
      ingredients: asStringList(m['ingredients']),
      instructions: asStringList(m['instructions']),
      caloriesKcal: asNum(nutrition['calories_kcal']),
      proteinG: asNum(nutrition['protein_g']),
      carbsG: asNum(nutrition['carbs_g']),
      fatG: asNum(nutrition['fat_g']),
      fiberG: asNum(nutrition['fiber_g']),
      primaryProteinSources: asStringList(m['primary_protein_sources']),
      whyItWorks: asStringList(m['why_it_works']),
      tags: asStringList(m['tags']),
      regionalTag: asText(m['regional_tag']),
      hostelFriendly: m['hostel_friendly'] == true,
      homeFriendly: m['home_friendly'] == true,
      zitlasOriginal: m['zitlas_original'] == true,
    );
  }
}

/// `GET /api/recipes/recommended`'s full response — the recipe(s) plus the
/// SAME short, data-backed reasons the website's recipe page shows (see
/// services/recipe_service.py's explain_recommendation), keyed by recipe id.
/// Never fabricated client-side; if the backend didn't say why, this list is
/// empty and the UI shows a neutral fallback line instead of inventing one.
@immutable
class RecipeRecommendation {
  const RecipeRecommendation({required this.recipes, required this.reasons});

  final List<Recipe> recipes;
  final Map<String, List<String>> reasons;

  bool get isEmpty => recipes.isEmpty;
  Recipe? get first => recipes.isEmpty ? null : recipes.first;
  List<String> reasonsFor(String recipeId) => reasons[recipeId] ?? const [];

  static RecipeRecommendation fromMap(Map<String, dynamic> m) {
    final recipes = [
      for (final r in (m['recipes'] as List? ?? const []))
        if (r is Map) ?Recipe.fromMap(r.cast<String, dynamic>()),
    ];
    // `asMap`'s `.cast<String, dynamic>()` is a lazy view — a non-String key
    // (e.g. a malformed row with no id, see recipe_test.dart) throws only
    // once iterated, not at cast time. Filter on the raw, uncasted map first.
    final rawReasons = m['reasons'];
    return RecipeRecommendation(
      recipes: recipes,
      reasons: {
        if (rawReasons is Map)
          for (final entry in rawReasons.entries)
            if (entry.key is String) entry.key as String: asStringList(entry.value),
      },
    );
  }
}
