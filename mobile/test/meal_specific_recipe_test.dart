import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/diet/data/recipe_repository.dart';

/// GET RECIPE MUST RETURN THE RECIPE FOR THE MEAL THAT WAS TAPPED.
///
/// The website was fixed for this; Flutter was not. `recipe_repository.dart`
/// still called `/api/recipes/recommended`, which takes the SLOT as its key
/// and draws from that slot's pool — so tapping the "Poha, Peanuts" card
/// could return "Masala Omelette", a different meal entirely, and no video
/// came back at all.
///
/// `/api/recipes/for-meal` takes the DISH as the key. These tests pin the
/// three things that make that true from the client side: the dish is sent,
/// the dish is what comes back, and the video that comes back is the one
/// attached to that dish's response rather than anything picked locally.
void main() {
  late Uri capturedUri;

  RecipeRepository repoWith(Map<String, dynamic> body) {
    final mock = MockClient((request) async {
      capturedUri = request.url;
      // Explicit charset: http defaults to Latin-1, which cannot represent
      // the em-dashes and Indian dish names these responses carry.
      return http.Response(
        jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    return RecipeRepository(
      apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      firestore: FakeFirebaseFirestore(),
    );
  }

  Map<String, dynamic> forMealResponse({
    required String dish,
    String? mealType,
    Map<String, dynamic>? video,
  }) => {
    'meal_name': dish,
    'meal_type': mealType,
    'recipe': {
      'id': 'ZITLAS-MEAL-${dish.toLowerCase().replaceAll(' ', '-')}',
      'name': dish,
      'description': 'A simple $dish.',
      'ingredients': ['1 cup $dish'],
      'instructions': ['Cook the $dish.'],
      'nutrition_estimated': {'calories': 320, 'protein_g': 12},
      'why_it_works': 'Balanced for this meal.',
      'meal_type': [?mealType],
    },
    'video': video,
    'video_note': video == null ? 'No exact cooking video found.' : null,
    'cached': false,
    'usage': {'feature': 'recipe', 'tier': 'free', 'used': 1, 'limit': 7},
  };

  // ── 7. The recipe is for the SELECTED meal ────────────────────────────
  group('the tapped dish is the primary key', () {
    test('the request goes to /api/recipes/for-meal, not /recommended',
        () async {
      final repo = repoWith(forMealResponse(dish: 'Poha'));
      await repo.getForMeal(mealName: 'Poha');
      expect(capturedUri.path, '/api/recipes/for-meal',
          reason: '/recommended keys off the SLOT and returns a random '
              'recipe from that pool — the bug this replaces');
    });

    test('meal_name carries the dish the athlete tapped', () async {
      final repo = repoWith(forMealResponse(dish: 'Poha, Peanuts'));
      await repo.getForMeal(mealName: 'Poha, Peanuts');
      expect(capturedUri.queryParameters['meal_name'], 'Poha, Peanuts');
    });

    test('the plan components travel pipe-separated, as the backend splits',
        () async {
      final repo = repoWith(forMealResponse(dish: 'Poha, Peanuts'));
      await repo.getForMeal(
        mealName: 'Poha, Peanuts',
        foods: ['Poha', 'Peanuts'],
      );
      expect(capturedUri.queryParameters['foods'], 'Poha|Peanuts');
    });

    // Breakfast, Lunch, Snack, Dinner — each returns ITS OWN dish.
    for (final (slot, dish) in const [
      ('breakfast', 'Poha'),
      ('lunch', 'Rajma Chawal'),
      ('snack', 'Roasted Chana'),
      ('dinner', 'Grilled Paneer Salad'),
    ]) {
      test('$slot returns $dish — never another slot\'s meal', () async {
        final repo = repoWith(forMealResponse(dish: dish, mealType: slot));
        final result = await repo.getForMeal(mealName: dish, mealType: slot);

        expect(capturedUri.queryParameters['meal_name'], dish);
        expect(capturedUri.queryParameters['meal_type'], slot);
        expect(result.recipe, isNotNull);
        expect(result.recipe!.name, dish,
            reason: 'the recipe must be named after the dish that was tapped');
        expect(result.mealName, dish);
      });
    }

    test('a dish with no recipe yields null rather than a substitute',
        () async {
      final repo = repoWith({
        'meal_name': 'Ragi Ambali',
        'recipe': null,
        'video': null,
        'cached': false,
      });
      final result = await repo.getForMeal(mealName: 'Ragi Ambali');
      expect(result.recipe, isNull,
          reason: 'an empty answer is correct; a different meal is not');
    });

    test('the generated nutrition shape is read, not silently dropped',
        () async {
      // The dataset uses `calories_kcal`; a generated recipe uses `calories`.
      // Reading only the first blanked the macro row on every meal-specific
      // recipe.
      final repo = repoWith(forMealResponse(dish: 'Poha'));
      final result = await repo.getForMeal(mealName: 'Poha');
      expect(result.recipe!.caloriesKcal, 320);
      expect(result.recipe!.proteinG, 12);
    });

    test('a single-sentence why_it_works is kept, not discarded', () async {
      final repo = repoWith(forMealResponse(dish: 'Poha'));
      final result = await repo.getForMeal(mealName: 'Poha');
      expect(result.recipe!.whyItWorks, ['Balanced for this meal.']);
    });
  });

  // ── 8. The VIDEO belongs to the selected meal ─────────────────────────
  group('the video belongs to the tapped dish', () {
    Map<String, dynamic> video(String title) => {
      'video_id': 'abc123',
      'video_url': 'https://www.youtube.com/watch?v=abc123',
      'title': title,
      'channel_name': 'Test Kitchen',
      'thumbnail_url': 'https://i.ytimg.com/vi/abc123/hq.jpg',
      'duration_seconds': 420,
      'relevance': 0.82,
    };

    test('the video from the dish\'s own response is what is shown', () async {
      final repo = repoWith(forMealResponse(
        dish: 'Rajma Chawal',
        mealType: 'lunch',
        video: video('Rajma Chawal Recipe | Restaurant Style'),
      ));
      final result = await repo.getForMeal(
          mealName: 'Rajma Chawal', mealType: 'lunch');

      expect(result.video, isNotNull);
      expect(result.video!.title, contains('Rajma Chawal'));
      expect(result.video!.videoId, 'abc123');
      expect(result.video!.relevance, 0.82);
    });

    test('each meal gets its own video, with no bleed between meals',
        () async {
      for (final (dish, title) in const [
        ('Poha', 'Poha Recipe'),
        ('Rajma Chawal', 'Rajma Chawal Recipe'),
        ('Grilled Paneer Salad', 'Grilled Paneer Salad Recipe'),
      ]) {
        final repo =
            repoWith(forMealResponse(dish: dish, video: video(title)));
        final result = await repo.getForMeal(mealName: dish);
        expect(result.video!.title, title);
        expect(result.recipe!.name, dish);
      }
    });

    test('no relevant video yields an explicit note, never a stand-in',
        () async {
      // The backend drops a video that does not clear the relevance bar. A
      // loosely-related video for a dish the athlete did not choose is the
      // same bug in a different place, so "none" must survive to the UI.
      final repo = repoWith(forMealResponse(dish: 'Ragi Ambali'));
      final result = await repo.getForMeal(mealName: 'Ragi Ambali');

      expect(result.video, isNull);
      expect(result.videoNote, isNotNull);
      expect(result.recipe, isNotNull,
          reason: 'a missing video must not cost the athlete the recipe');
    });

    test('a video with no id is discarded rather than half-rendered',
        () async {
      final repo = repoWith(forMealResponse(
        dish: 'Poha',
        video: {'title': 'Poha Recipe', 'video_id': null},
      ));
      final result = await repo.getForMeal(mealName: 'Poha');
      expect(result.video, isNull);
    });
  });

  // ── The recipe allowance still applies ────────────────────────────────
  group('entitlements are preserved', () {
    test('the usage the backend reports is surfaced, not recomputed',
        () async {
      final repo = repoWith(forMealResponse(dish: 'Poha'));
      final result = await repo.getForMeal(mealName: 'Poha');
      expect(result.usage?['limit'], 7, reason: 'free recipe limit');
      expect(result.usage?['tier'], 'free');
    });

    test('the ID token is attached so the backend can meter the call',
        () async {
      // Free 7/week, premium 27/week, keyed to the verified uid. A tokenless
      // request cannot be metered.
      final repo = repoWith(forMealResponse(dish: 'Poha'));
      expect(repo, isNotNull);
      final client = ApiClient(baseUrl: 'https://api.test');
      RecipeRepository(
          apiClient: client, firestore: FakeFirebaseFirestore());
      expect(client.authTokenProvider, isNotNull,
          reason: 'without a token provider every recipe would be unmetered');
    });
  });
}
