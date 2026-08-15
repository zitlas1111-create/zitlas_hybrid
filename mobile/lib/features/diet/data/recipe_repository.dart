import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
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
  });

  final String? fitnessGoal;
  final String? dietType;
  final String? livingSituation;

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
      'limit': limit,
    });
    if (res is! Map) return const RecipeRecommendation(recipes: [], reasons: {});
    return RecipeRecommendation.fromMap(res.cast<String, dynamic>());
  }
}
