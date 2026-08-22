import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
import '../models/creator_recipe.dart';
import '../models/meal_recipe.dart';
import '../models/recipe.dart';

/// The athlete's existing context, resolved from the SAME `users/{uid}`
/// fields `DietController.swapMeal` already reads (`assessment.fitness_goal`
/// / `goal.type`, `assessment.diet_preference`, `assessment.living_situation`,
/// `preferredDietRegion`) — never a new profile field, never a second
/// read of a value the Swap feature doesn't already trust. A fresh one-shot
/// read rather than a live stream: recipe recommendations don't need to be
/// reactive to a profile edit made while the recipe screen happens to be open.
class AthleteRecipeContext {
  const AthleteRecipeContext({
    this.fitnessGoal,
    this.dietType,
    this.livingSituation,
    this.state,
    this.favoriteFoods = const [],
  });

  final String? fitnessGoal;
  final String? dietType;
  final String? livingSituation;

  /// Stable food ids from the Assessment's "What foods do you enjoy?"
  /// question. A PREFERENCE: used to break ties between equally-relevant
  /// creator videos, never to override the food actually on the meal card.
  final List<String> favoriteFoods;

  /// The athlete's confirmed region (`preferredDietRegion` — never live GPS;
  /// same field the diet-generation and swap paths already use, so a
  /// recipe recommendation and a fresh diet plan always agree on region).
  final String? state;

  static AthleteRecipeContext fromUserDoc(Map<String, dynamic>? data) {
    if (data == null) return const AthleteRecipeContext();
    final assessment = (data['assessment'] as Map?)?.cast<String, dynamic>() ?? const {};
    final goal = (data['goal'] as Map?)?.cast<String, dynamic>();
    return AthleteRecipeContext(
      fitnessGoal: (goal?['type'] as String?) ?? (assessment['fitness_goal'] as String?),
      dietType: assessment['diet_preference'] as String?,
      livingSituation: assessment['living_situation'] as String?,
      state: data['preferredDietRegion'] as String?,
      // Written by the Assessment's food-preferences question. Absent for
      // athletes who completed the assessment before it existed — an empty
      // list simply means "no preference signal", never an error.
      favoriteFoods: ((assessment['favorite_foods'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(),
    );
  }
}

/// Backend access for "Get Easy ZITLAS Recipe" — talks to the EXISTING
/// recipe API (backend/routes/recipes.py + services/recipe_service.py,
/// serving backend/recipes/data/zitlas_recipes.json) and nothing else. No
/// recipe data is ever cached to disk or duplicated into the app; the
/// backend remains the single source of truth for all 637 recipes.
class RecipeRepository {
  // `auth` stays genuinely nullable (no `?? FirebaseAuth.instance` default)
  // — the recipe endpoints don't require authentication at all, so nothing
  // here should force Firebase Auth to be initialized just to construct
  // this repository (a real cost in tests, and an unnecessary one in
  // production too). When absent, requests simply carry no bearer token,
  // exactly like an unauthenticated caller.
  RecipeRepository({ApiClient? apiClient, FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _api = apiClient ?? ApiClient(),
      _db = firestore ?? FirebaseFirestore.instance,
      _auth = auth {
    _api.authTokenProvider = () async => _auth?.currentUser?.getIdToken();
  }

  final ApiClient _api;
  final FirebaseFirestore _db;
  final FirebaseAuth? _auth;

  Future<AthleteRecipeContext> resolveContext(String uid) async {
    final snap = await _db.collection('users').doc(uid).get();
    return AthleteRecipeContext.fromUserDoc(snap.data());
  }

  /// "Get Easy ZITLAS Recipe" / "Get Another Recipe" — one call for both;
  /// the caller passes `excludeIds` (recipe ids already shown this session)
  /// on every call after the first so a repeat isn't offered as "another".
  ///
  /// `mealType` is the ONLY required filter (item 2 of the spec: never a
  /// different meal's recipe). Every other parameter is optional and either
  /// comes from [AthleteRecipeContext] or an explicit filter override the
  /// athlete picked on the recipe screen — overrides always win.
  Future<RecipeRecommendation> getRecommended({
    required String mealType,
    String? fitnessGoal,
    String? dietType,
    String? livingSituation,
    String? state,
    String? difficulty,
    Set<String>? excludeIds,
    int? minutesUntilWorkout,
    int limit = 1,
  }) async {
    final res = await _api.get('/api/recipes/recommended', query: {
      'meal_type': mealType,
      'fitness_goal': ?fitnessGoal,
      'diet_type': ?dietType,
      'living_situation': ?livingSituation,
      'state': ?state,
      'difficulty': ?difficulty,
      if (excludeIds != null && excludeIds.isNotEmpty) 'exclude_ids': excludeIds.join(','),
      // Pre-workout only, and only when the athlete actually picked a
      // window. Omitted means "no workout time known" — the backend then
      // applies its own stated default rather than ZITLAS pretending to
      // know when training starts (there is no workout start-time field
      // anywhere in the app).
      'minutes_until_workout': ?minutesUntilWorkout,
      'limit': limit,
    });
    if (res is! Map) return const RecipeRecommendation(recipes: [], reasons: {});
    return RecipeRecommendation.fromMap(res.cast<String, dynamic>());
  }

  /// `GET /api/recipes/for-meal` — THE recipe for the dish the athlete
  /// tapped, plus a video verified to be about that same dish.
  ///
  /// This is what [getRecommended] should have been for this button.
  /// `/recommended` treats the SLOT as the key and draws a recipe from that
  /// slot's pool, so tapping the "Poha" card could return "Masala Omelette"
  /// — a different meal entirely. Here [mealName] is the primary key end to
  /// end: it drives the recipe, the cache and the video query, and the
  /// backend forces the returned recipe's name back to it.
  ///
  /// [foods] are the plan components shown under the meal name; they sharpen
  /// generation but never replace the dish as the identifier.
  ///
  /// Metered by the backend against the verified uid — free 7/week,
  /// premium 27/week — which is why the ID token travels with it.
  Future<MealRecipeResult> getForMeal({
    required String mealName,
    String? mealType,
    List<String> foods = const [],
    String? description,
    String? dietType,
    String? fitnessGoal,
  }) async {
    final res = await _api.get('/api/recipes/for-meal', query: {
      'meal_name': mealName,
      'meal_type': ?mealType,
      // Pipe-separated, matching the website's `data-recipe-foods` and the
      // backend's own split on '|'.
      if (foods.isNotEmpty) 'foods': foods.join('|'),
      'description': ?description,
      'diet_type': ?dietType,
      'fitness_goal': ?fitnessGoal,
    });
    if (res is! Map) {
      throw FormatException('Unexpected for-meal response: ${res.runtimeType}');
    }
    return MealRecipeResult.fromMap(res.cast<String, dynamic>());
  }

  // ── Creator Recipes (YouTube) ─────────────────────────────────────────
  // A SEPARATE content source from the ZITLAS recipe database above, served
  // by /api/creator-recipes. Deliberately methods on THIS repository rather
  // than a second one: they need the same ApiClient and the same
  // AthleteRecipeContext, and a parallel HTTP layer would be exactly the
  // duplication to avoid. No YouTube key is ever present client-side — the
  // backend holds it and this class only ever sees normalized results.

  /// Ranked creator videos for [food]. Returns a LIST so "See Another
  /// Recipe" can walk it locally without another backend round trip (which
  /// in turn avoids another YouTube search against a limited daily quota).
  ///
  /// The backend REFUSES pre/post-workout meal types outright — those slots
  /// have their own purpose-built nutrition system and must not be answered
  /// with a generic recipe video.
  Future<List<CreatorRecipe>> getCreatorRecipes({
    required String food,
    String? mealType,
    String? fitnessGoal,
    String? dietType,
    String? livingSituation,
    String? region,
    List<String> favoriteFoods = const [],
    Set<String>? excludeIds,
    int limit = 5,
  }) async {
    final res = await _api.get('/api/creator-recipes/recommended', query: {
      'food': food,
      'meal_type': ?mealType,
      'fitness_goal': ?fitnessGoal,
      'diet_type': ?dietType,
      'living_situation': ?livingSituation,
      'region': ?region,
      // Tie-breaker only — the meal's own food still drives the search.
      if (favoriteFoods.isNotEmpty) 'favorite_foods': favoriteFoods.join(','),
      if (excludeIds != null && excludeIds.isNotEmpty) 'exclude_ids': excludeIds.join(','),
      'limit': limit,
    });
    if (res is! Map) return const [];
    final raw = (res['videos'] as List?) ?? const [];
    return [
      for (final v in raw)
        if (v is Map) ?CreatorRecipe.fromMap(v.cast<String, dynamic>()),
    ];
  }

  /// Public channel info for the Creator Profile screen.
  Future<CreatorChannel?> getCreatorChannel(String channelId) async {
    final res = await _api.get('/api/creator-recipes/channel/$channelId');
    if (res is! Map) return null;
    return CreatorChannel.fromMap(res.cast<String, dynamic>());
  }
}
