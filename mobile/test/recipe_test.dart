import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/core/network/api_exception.dart';
import 'package:zitlas_mobile/features/diet/data/recipe_repository.dart';
import 'package:zitlas_mobile/features/diet/models/recipe.dart';

/// "Get Easy ZITLAS Recipe" — Flutter-side contract tests.
///
/// Backend filtering/scoring itself (meal type, diet type, fitness goal,
/// cooking situation, region, "easy" preference, exclude_ids fallback) is
/// already exercised end-to-end against the real 637-recipe dataset in
/// backend/tests/test_recipes.py — duplicating that here would test the
/// SAME server-side code a second time from a slower harness. What Flutter
/// actually owns, and what these tests cover instead:
///   1. Recipe/RecipeRecommendation model parsing (a captured response, like
///      swap_integration_test.dart's SwapResult tests).
///   2. RecipeRepository builds the RIGHT query for each filter case —
///      verified by intercepting the real HTTP call via MockClient, so this
///      is testing the actual production code path, not a hand-rolled stub.
///   3. AthleteRecipeContext resolves the SAME user-doc fields
///      DietController.swapMeal already reads (no duplicate profile field).
///   4. Graceful degradation: malformed response, empty result, API failure.

Map<String, dynamic> _recipeMap({
  String id = 'ZITLAS-REC-0001',
  String name = 'ZITLAS Sattu Power Shot',
  List<String> mealType = const ['Breakfast'],
  List<String> fitnessGoals = const ['Weight Loss', 'General Fitness'],
  String dietType = 'Vegan',
  String difficulty = 'Easy',
  bool hostelFriendly = true,
  bool homeFriendly = true,
  String? regionalTag = 'Bihar-inspired',
}) {
  return {
    'id': id,
    'name': name,
    'description': 'A 2-minute no-cook drink-meal.',
    'category': 'Breakfast',
    'meal_type': mealType,
    'fitness_goals': fitnessGoals,
    'diet_type': dietType,
    'servings': 1,
    'prep_time_min': 2,
    'cook_time_min': 0,
    'total_time_min': 2,
    'difficulty': difficulty,
    'equipment': ['No-cook'],
    'cost_level': 'Budget',
    'ingredients': ['Sattu — 40 g', 'Water — 200 ml'],
    'instructions': ['Add sattu to a glass.', 'Whisk well.'],
    'nutrition_estimated': {
      'calories_kcal': 152,
      'protein_g': 8.0,
      'carbs_g': 22.8,
      'fat_g': 2.4,
      'fiber_g': 4.0,
    },
    'primary_protein_sources': ['Sattu'],
    'why_it_works': ['High protein with zero cooking'],
    'tags': ['Hostel Friendly', 'No Cook'],
    'regional_tag': regionalTag,
    'hostel_friendly': hostelFriendly,
    'home_friendly': homeFriendly,
    'zitlas_original': true,
  };
}

Map<String, dynamic> _recommendedResponse({List<Map<String, dynamic>>? recipes}) {
  final r = recipes ?? [_recipeMap()];
  return {
    'count': r.length,
    'recipes': r,
    'reasons': {
      for (final recipe in r)
        recipe['id']: ['Easy difficulty', 'Ready in 2 min', 'Fits your Weight Loss goal'],
    },
  };
}

void main() {
  // ── 1. Recipe model parsing ────────────────────────────────────────────
  group('Recipe.fromMap', () {
    test('every field survives parsing, verbatim from the backend', () {
      final recipe = Recipe.fromMap(_recipeMap())!;
      expect(recipe.id, 'ZITLAS-REC-0001');
      expect(recipe.name, 'ZITLAS Sattu Power Shot');
      expect(recipe.mealType, ['Breakfast']);
      expect(recipe.fitnessGoals, ['Weight Loss', 'General Fitness']);
      expect(recipe.dietType, 'Vegan');
      expect(recipe.difficulty, 'Easy');
      expect(recipe.caloriesKcal, 152);
      expect(recipe.proteinG, 8.0);
      expect(recipe.ingredients, ['Sattu — 40 g', 'Water — 200 ml']);
      expect(recipe.instructions, ['Add sattu to a glass.', 'Whisk well.']);
      expect(recipe.hostelFriendly, isTrue);
      expect(recipe.homeFriendly, isTrue);
      expect(recipe.zitlasOriginal, isTrue);
      expect(recipe.regionalTag, 'Bihar-inspired');
    });

    test('cook_time_min of 0 is a real value, not "missing"', () {
      // A common falsy-zero trap (already fixed once on the website side) —
      // this locks it down on the Flutter side too.
      final recipe = Recipe.fromMap(_recipeMap())!;
      expect(recipe.cookTimeMin, 0);
      expect(recipe.totalTimeComputed, 2); // prep(2) + cook(0)
    });

    test('a null regional_tag (Pan-India / no specific region) parses as null, not a crash', () {
      final recipe = Recipe.fromMap(_recipeMap(regionalTag: null))!;
      expect(recipe.regionalTag, isNull);
    });

    test('missing id or name returns null rather than a half-built object', () {
      expect(Recipe.fromMap({'name': 'X'}), isNull);
      expect(Recipe.fromMap({'id': 'ZITLAS-REC-0001'}), isNull);
    });
  });

  // ── 13. Invalid API response ────────────────────────────────────────────
  group('RecipeRecommendation.fromMap — malformed responses degrade safely', () {
    test('one unusable recipe row is dropped, the rest still parse', () {
      final broken = _recommendedResponse(recipes: [_recipeMap(), {'calories_kcal': 100}]);
      final result = RecipeRecommendation.fromMap(broken);
      expect(result.recipes.length, 1, reason: 'the row with no id/name must not crash the whole response');
    });

    test('an empty recipes list is reported as empty, not a crash', () {
      final result = RecipeRecommendation.fromMap({'count': 0, 'recipes': [], 'reasons': {}});
      expect(result.isEmpty, isTrue);
      expect(result.first, isNull);
    });

    test('a completely absent recipes key is handled', () {
      final result = RecipeRecommendation.fromMap({});
      expect(result.isEmpty, isTrue);
      expect(result.reasonsFor('anything'), isEmpty);
    });

    test('reasons are keyed by recipe id and reachable via reasonsFor', () {
      final result = RecipeRecommendation.fromMap(_recommendedResponse());
      expect(result.reasonsFor('ZITLAS-REC-0001'), contains('Easy difficulty'));
      expect(result.reasonsFor('unknown-id'), isEmpty);
    });
  });

  // ── AthleteRecipeContext — reuses DietController.swapMeal's exact fields ──
  group('AthleteRecipeContext.fromUserDoc', () {
    test('resolves fitness_goal from goal.type first, assessment.fitness_goal as fallback', () {
      final ctx = AthleteRecipeContext.fromUserDoc({
        'goal': {'type': 'muscle_gain'},
        'assessment': {'fitness_goal': 'weight_loss'},
      });
      expect(ctx.fitnessGoal, 'muscle_gain');
    });

    test('falls back to assessment.fitness_goal when goal.type is absent', () {
      final ctx = AthleteRecipeContext.fromUserDoc({
        'assessment': {'fitness_goal': 'weight_loss', 'diet_preference': 'vegetarian', 'living_situation': 'hostel'},
      });
      expect(ctx.fitnessGoal, 'weight_loss');
      expect(ctx.dietType, 'vegetarian');
      expect(ctx.livingSituation, 'hostel');
    });

    test('resolves region from preferredDietRegion — the SAME field the diet/swap engines use', () {
      final ctx = AthleteRecipeContext.fromUserDoc({'preferredDietRegion': 'Maharashtra'});
      expect(ctx.state, 'Maharashtra');
    });

    test('a null/absent user doc degrades to an all-null context, never throws', () {
      final ctx = AthleteRecipeContext.fromUserDoc(null);
      expect(ctx.fitnessGoal, isNull);
      expect(ctx.dietType, isNull);
      expect(ctx.livingSituation, isNull);
      expect(ctx.state, isNull);
    });
  });

  // ── RecipeRepository — query-building via a real HTTP round trip ────────
  group('RecipeRepository.getRecommended builds the right query', () {
    late Uri capturedUri;
    RecipeRepository repoWith(Map<String, dynamic> responseBody) {
      final mock = MockClient((request) async {
        capturedUri = request.url;
        // http.Response defaults to Latin-1 for the body encoding, which
        // can't represent the em-dashes real recipe ingredient/instruction
        // strings use (see recipe_service.py's dataset) — an explicit
        // content-type is what makes ApiClient/http decode as UTF-8.
        return http.Response(
          jsonEncode(responseBody), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      return RecipeRepository(
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
        firestore: FakeFirebaseFirestore(),
      );
    }

    // ── 3-5. Breakfast/Lunch/Dinner filtering ──
    test('meal_type is always sent — item 2: never a different meal\'s recipe', () async {
      final repo = repoWith(_recommendedResponse());
      for (final mealType in ['breakfast', 'lunch', 'dinner']) {
        await repo.getRecommended(mealType: mealType);
        expect(capturedUri.queryParameters['meal_type'], mealType);
      }
    });

    // ── 6. Vegetarian filtering ──
    test('diet_type is sent when the athlete has one', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast', dietType: 'vegetarian');
      expect(capturedUri.queryParameters['diet_type'], 'vegetarian');
    });

    // ── 7. Goal filtering ──
    test('fitness_goal is sent when resolved', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast', fitnessGoal: 'weight_loss');
      expect(capturedUri.queryParameters['fitness_goal'], 'weight_loss');
    });

    // ── 8. Hostel filtering (cooking situation) ──
    test('living_situation is sent when resolved — the existing assessment field, not a new one', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast', livingSituation: 'hostel');
      expect(capturedUri.queryParameters['living_situation'], 'hostel');
    });

    // ── 9. Regional filtering ──
    test('state is sent when the athlete has a confirmed region', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast', state: 'Maharashtra');
      expect(capturedUri.queryParameters['state'], 'Maharashtra');
    });

    // ── 10. Combined filtering ──
    test('every provided filter is sent together, none dropped', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(
        mealType: 'lunch',
        fitnessGoal: 'muscle_gain',
        dietType: 'non-vegetarian',
        livingSituation: 'home',
        state: 'Karnataka',
      );
      expect(capturedUri.queryParameters['meal_type'], 'lunch');
      expect(capturedUri.queryParameters['fitness_goal'], 'muscle_gain');
      expect(capturedUri.queryParameters['diet_type'], 'non-vegetarian');
      expect(capturedUri.queryParameters['living_situation'], 'home');
      expect(capturedUri.queryParameters['state'], 'Karnataka');
    });

    test('omitted filters are not sent at all — never as the literal string "null"', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast');
      expect(capturedUri.queryParameters.containsKey('fitness_goal'), isFalse);
      expect(capturedUri.queryParameters.containsKey('diet_type'), isFalse);
      expect(capturedUri.queryParameters.containsKey('state'), isFalse);
    });

    // ── 12. Get Another Recipe ──
    test('exclude_ids is sent as a comma-joined list, only when non-empty', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast', excludeIds: {'ZITLAS-REC-0001', 'ZITLAS-REC-0002'});
      final sent = capturedUri.queryParameters['exclude_ids']!.split(',');
      expect(sent, containsAll(['ZITLAS-REC-0001', 'ZITLAS-REC-0002']));
    });

    test('an empty exclude_ids set is not sent (first fetch, nothing seen yet)', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'breakfast', excludeIds: <String>{});
      expect(capturedUri.queryParameters.containsKey('exclude_ids'), isFalse);
    });

    // ── 11. No-match fallback ──
    test('an empty recipes response parses to an empty recommendation, not an error', () async {
      final repo = repoWith(_recommendedResponse(recipes: []));
      final result = await repo.getRecommended(mealType: 'dinner', dietType: 'vegan');
      expect(result.isEmpty, isTrue);
    });

    // ── Pre-workout / Post-workout — the exact slot key, never breakfast/
    // lunch/dinner/snack as a "closest meal type" fallback ──
    test('pre_workout is sent verbatim as meal_type, never translated to breakfast', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'pre_workout');
      expect(capturedUri.queryParameters['meal_type'], 'pre_workout');
    });

    test('post_workout is sent verbatim as meal_type, never translated to lunch/dinner', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'post_workout');
      expect(capturedUri.queryParameters['meal_type'], 'post_workout');
    });

    test('a pre_workout request still carries goal/diet/cooking/region context, same as any other slot', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(
        mealType: 'pre_workout',
        fitnessGoal: 'weight_loss',
        dietType: 'vegetarian',
        livingSituation: 'hostel',
        state: 'Maharashtra',
      );
      expect(capturedUri.queryParameters['meal_type'], 'pre_workout');
      expect(capturedUri.queryParameters['fitness_goal'], 'weight_loss');
      expect(capturedUri.queryParameters['diet_type'], 'vegetarian');
      expect(capturedUri.queryParameters['living_situation'], 'hostel');
      expect(capturedUri.queryParameters['state'], 'Maharashtra');
    });

    test('"Get Another Recipe" on a post_workout screen excludes the current id and keeps the slot', () async {
      final repo = repoWith(_recommendedResponse());
      await repo.getRecommended(mealType: 'post_workout', excludeIds: {'ZITLAS-REC-0489'});
      expect(capturedUri.queryParameters['meal_type'], 'post_workout');
      expect(capturedUri.queryParameters['exclude_ids'], 'ZITLAS-REC-0489');
    });
  });

  // ── 14. API failure ──────────────────────────────────────────────────────
  group('API failure', () {
    test('a 503 from the recipe service surfaces as an ApiException, not a crash', () async {
      final mock = MockClient((request) async => http.Response('{"detail":"unavailable"}', 503));
      final repo = RecipeRepository(
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
        firestore: FakeFirebaseFirestore(),
      );
      await expectLater(
        () => repo.getRecommended(mealType: 'breakfast'),
        throwsA(isA<ApiException>()),
      );
    });

    test('resolveContext degrades to an all-null context rather than throwing when the user doc is missing', () async {
      final mock = MockClient((request) async => http.Response('{}', 200));
      final repo = RecipeRepository(
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
        firestore: FakeFirebaseFirestore(), // no users/{uid} doc written
      );
      final ctx = await repo.resolveContext('some-uid-with-no-doc');
      expect(ctx.fitnessGoal, isNull);
    });
  });
}
