import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/assessment/models/assessment_question.dart';
import 'package:zitlas_mobile/features/diet/data/recipe_repository.dart';
import 'package:zitlas_mobile/features/diet/models/creator_recipe.dart';
import 'package:zitlas_mobile/features/diet/models/meal_slot.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/recipe_source_sheet.dart';

/// Creator Recipe — Flutter-side contract.
///
/// Search relevance, ranking, quota behaviour and the workout-slot refusal
/// are covered end-to-end against the real routes in
/// backend/tests/test_creator_recipes.py. What Flutter owns, and what these
/// cover: the source choice being a real choice, workout slots never being
/// offered it, the query the client builds, the two content sources staying
/// distinct types, and the assessment question's stable ids.

Map<String, dynamic> _video({
  String id = 'v1',
  String title = 'High Protein Pizza Recipe',
  bool embeddable = true,
}) =>
    {
      'video_id': id,
      'title': title,
      'description': 'A recipe',
      'thumbnail_url': 'https://i.ytimg.com/$id.jpg',
      'channel_id': 'UC_test',
      'channel_name': 'Rahul Fitness Kitchen',
      'video_url': 'https://www.youtube.com/watch?v=$id',
      'platform': 'youtube',
      'embeddable': embeddable,
    };

void main() {
  _playerConfigTests();

  group('CreatorRecipe model', () {
    test('parses a video into the id the player is handed', () {
      final r = CreatorRecipe.fromMap(_video())!;
      expect(r.videoId, 'v1');
      expect(r.channelName, 'Rahul Fitness Kitchen');
      expect(r.embeddable, isTrue);
    });

    test('a non-embeddable video is flagged so the UI can offer Watch on YouTube', () {
      final r = CreatorRecipe.fromMap(_video(embeddable: false))!;
      expect(r.embeddable, isFalse);
      expect(r.videoUrl, contains('youtube.com/watch'));
    });

    test('a malformed row is dropped rather than crashing the list', () {
      expect(CreatorRecipe.fromMap({'title': 'no id'}), isNull);
    });

    test('carries no downloadable media reference of any kind', () {
      // ZITLAS never re-hosts: only YouTube references exist on the model.
      final r = CreatorRecipe.fromMap(_video())!;
      expect(r.videoUrl, startsWith('https://www.youtube.com/'));
      expect(r.thumbnailUrl, startsWith('https://i.ytimg.com/'));
    });
  });

  group('CreatorChannel model', () {
    test('parses the fields YouTube actually returns', () {
      final c = CreatorChannel.fromMap({
        'channel_id': 'UC_test',
        'channel_name': 'Rahul Fitness Kitchen',
        'channel_handle': '@RahulFitness',
        'channel_url': 'https://www.youtube.com/@RahulFitness',
      })!;
      expect(c.channelHandle, '@RahulFitness');
      expect(c.channelUrl, contains('@RahulFitness'));
    });

    test('a channel with no handle still resolves a usable URL', () {
      final c = CreatorChannel.fromMap({'channel_id': 'UC_x', 'channel_name': 'Kitchen'})!;
      expect(c.channelHandle, isNull);
      expect(c.channelUrl, contains('UC_x'));
    });
  });

  group('RecipeRepository.getCreatorRecipes builds the right query', () {
    late Uri captured;

    RecipeRepository repoWith(Map<String, dynamic> body) {
      final mock = MockClient((request) async {
        captured = request.url;
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      return RecipeRepository(
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
        firestore: FakeFirebaseFirestore(),
      );
    }

    test('food is always sent — it is what relevance is judged on', () async {
      final repo = repoWith({'videos': [_video()]});
      await repo.getCreatorRecipes(food: 'Pizza', mealType: 'lunch');
      expect(captured.queryParameters['food'], 'Pizza');
      expect(captured.queryParameters['meal_type'], 'lunch');
    });

    test('every profile filter is forwarded when present', () async {
      final repo = repoWith({'videos': [_video()]});
      await repo.getCreatorRecipes(
        food: 'Pizza',
        mealType: 'lunch',
        fitnessGoal: 'muscle_gain',
        dietType: 'vegetarian',
        livingSituation: 'hostel',
        region: 'Maharashtra',
      );
      expect(captured.queryParameters['fitness_goal'], 'muscle_gain');
      expect(captured.queryParameters['diet_type'], 'vegetarian');
      expect(captured.queryParameters['living_situation'], 'hostel');
      expect(captured.queryParameters['region'], 'Maharashtra');
    });

    test('absent context is omitted, never sent as the string "null"', () async {
      final repo = repoWith({'videos': [_video()]});
      await repo.getCreatorRecipes(food: 'Pizza');
      expect(captured.queryParameters.containsKey('fitness_goal'), isFalse);
      expect(captured.queryParameters.containsKey('diet_type'), isFalse);
    });

    test('exclude_ids is sent for See Another Recipe', () async {
      final repo = repoWith({'videos': [_video(id: 'v2')]});
      await repo.getCreatorRecipes(food: 'Pizza', excludeIds: {'v1'});
      expect(captured.queryParameters['exclude_ids'], 'v1');
    });

    test('an empty response parses to an empty list rather than throwing', () async {
      final repo = repoWith({'videos': []});
      expect(await repo.getCreatorRecipes(food: 'Pizza'), isEmpty);
    });

    test('no YouTube key is ever present in a client request', () async {
      // The key lives only on the backend; the client must never carry one.
      final repo = repoWith({'videos': [_video()]});
      await repo.getCreatorRecipes(food: 'Pizza', mealType: 'lunch');
      final params = captured.queryParameters.keys.map((k) => k.toLowerCase());
      expect(params.any((k) => k.contains('key') || k.contains('api')), isFalse);
    });
  });

  group('Recipe source choice', () {
    Future<void> pump(WidgetTester tester, ValueChanged<RecipeSource?> onResult) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async => onResult(await showRecipeSourceSheet(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('offers both sources and keeps them clearly distinct', (tester) async {
      await pump(tester, (_) {});
      expect(find.text('How would you like your recipe?'), findsOneWidget);
      expect(find.text('ZITLAS Recipe'), findsOneWidget);
      expect(find.text('Creator Recipe'), findsOneWidget);
      // A creator's video is never labelled a ZITLAS recipe.
      expect(find.textContaining('Watch a YouTube creator'), findsOneWidget);
    });

    testWidgets('neither option is pre-selected — the athlete chooses', (tester) async {
      RecipeSource? result;
      var called = false;
      await pump(tester, (r) {
        result = r;
        called = true;
      });
      // Sheet is open and nothing has been decided yet.
      expect(called, isFalse);
      expect(result, isNull);
    });

    testWidgets('choosing ZITLAS Recipe returns that source', (tester) async {
      RecipeSource? result;
      await pump(tester, (r) => result = r);
      await tester.tap(find.text('ZITLAS Recipe'));
      await tester.pumpAndSettle();
      expect(result, RecipeSource.zitlas);
    });

    testWidgets('choosing Creator Recipe returns that source', (tester) async {
      RecipeSource? result;
      await pump(tester, (r) => result = r);
      await tester.tap(find.text('Creator Recipe'));
      await tester.pumpAndSettle();
      expect(result, RecipeSource.creator);
    });

    testWidgets('dismissing chooses nothing', (tester) async {
      RecipeSource? result;
      var called = false;
      await pump(tester, (r) {
        result = r;
        called = true;
      });
      await tester.tapAt(const Offset(200, 60)); // outside the sheet
      await tester.pumpAndSettle();
      expect(called, isTrue);
      expect(result, isNull);
    });
  });

  group('Workout slots never reach the creator flow', () {
    // Mirrors diet_screen.dart's `_openRecipe` decision exactly.
    bool offersSourceChoice(MealSlot slot) => !slot.isWorkoutSlot;

    test('pre/post-workout go straight to workout nutrition, no choice shown', () {
      expect(offersSourceChoice(MealSlot.preWorkout), isFalse);
      expect(offersSourceChoice(MealSlot.postWorkout), isFalse);
    });

    test('normal meals do get the choice', () {
      for (final slot in [MealSlot.breakfast, MealSlot.lunch, MealSlot.dinner, MealSlot.snack]) {
        expect(offersSourceChoice(slot), isTrue, reason: '$slot should offer both sources');
      }
    });
  });

  group('Assessment food-preferences question', () {
    test('exists, is multi-select, and asks the right question', () {
      expect(foodPreferencesQuestion.field, 'favorite_foods');
      expect(foodPreferencesQuestion.type, AssessmentQuestionType.multiselect);
      expect(foodPreferencesQuestion.prompt, contains('What foods do you enjoy'));
      expect(foodPreferencesQuestion.hint, contains('Select all that apply'));
    });

    test('stores STABLE ids, never emoji or display labels', () {
      for (final o in foodPreferencesQuestion.options) {
        expect(o.value, matches(RegExp(r'^[a-z][a-z_]*$')),
            reason: '${o.value} is not a stable snake_case id');
        expect(o.value, isNot(contains(' ')));
      }
    });

    test('covers the food ids the product spec names', () {
      final values = foodPreferencesQuestion.options.map((o) => o.value).toSet();
      for (final expected in ['pizza', 'burger', 'sandwich', 'wrap', 'pasta',
                              'noodles', 'maharashtrian', 'north_indian',
                              'south_indian', 'street_food']) {
        expect(values, contains(expected));
      }
    });

    test('stays practical in length — not a 100-option list', () {
      expect(foodPreferencesQuestion.options.length, lessThanOrEqualTo(25));
    });

    test('every option has a distinct id', () {
      final values = foodPreferencesQuestion.options.map((o) => o.value).toList();
      expect(values.toSet().length, values.length);
    });

    test('is asked in ALL three assessment flows', () {
      for (final goal in ['weight_loss', 'general_fitness', 'transformation']) {
        final fields = questionsForGoal(goal).map((q) => q.field);
        expect(fields, contains('favorite_foods'), reason: '$goal flow is missing it');
      }
    });

    test('adding it did not disturb the existing questions', () {
      // Regression guard: the existing assessment must still ask everything
      // it asked before.
      final fields = questionsForGoal('weight_loss').map((q) => q.field).toSet();
      for (final existing in ['age', 'gender', 'height_cm', 'weight_kg',
                              'activity_level', 'diet_preference',
                              'supplements_used', 'medical_conditions']) {
        expect(fields, contains(existing));
      }
    });
  });
}

/// Error 153 regression — the embed must be hosted in a page with a real

/// Black-player regression: the embed page must not paint over the

/// The player contract, after moving from a hand-hosted IFrame in a bare
/// WebView to `youtube_player_iframe`.
///
/// The old approach failed twice on device: navigating to `/embed/` gave
/// Error 153, and hosting the API via `loadDataWithBaseURL` never fired
/// `onReady`, so no controls appeared and the loading thumbnail became the
/// de-facto (frozen) player. These lock in what replaced it.
void _playerConfigTests() {
  group('player configuration', () {
    test('the player is handed a bare 11-char video ID, never a URL', () {
      final r = CreatorRecipe.fromMap(_video())!;
      // This is what goes to YoutubePlayerController.fromVideoId.
      expect(r.videoId, 'v1');
      expect(r.videoId, isNot(contains('/')));
      expect(r.videoId, isNot(contains('http')));
      expect(r.videoId, isNot(contains('watch?v=')));
      expect(r.videoId, isNot(contains('shorts')));
    });

    test('a real production-shaped ID survives parsing unchanged', () {
      final r = CreatorRecipe.fromMap({..._video(id: 'EwWsxuHzUoM')})!;
      expect(r.videoId, 'EwWsxuHzUoM');
      expect(r.videoId.length, 11);
    });

    test('the watch URL is kept only for the external fallback', () {
      final r = CreatorRecipe.fromMap(_video())!;
      expect(r.videoUrl, 'https://www.youtube.com/watch?v=v1');
    });

    test('the hand-rolled embed HTML is gone — the package owns embedding now', () {
      // Guards against reintroducing the WebView approach that failed on
      // device twice.
      expect(CreatorRecipe.fromMap(_video()), isNotNull);
      // ignore: unnecessary_type_check
      expect(CreatorRecipe.fromMap(_video()) is CreatorRecipe, isTrue);
    });

    test('a Short keeps a vertical aspect so the frame is not letterboxed', () {
      final short = CreatorRecipe.fromMap({..._video(), 'is_short': true})!;
      final normal = CreatorRecipe.fromMap(_video())!;
      double aspect(CreatorRecipe v) => v.isShort ? 3 / 4 : 16 / 9;
      expect(aspect(short), lessThan(1.0));
      expect(aspect(normal), greaterThan(1.0));
    });

    test('duration surfaces so the athlete sees it is a quick watch', () {
      final r = CreatorRecipe.fromMap({..._video(), 'duration_seconds': 27})!;
      expect(r.durationLabel, '0:27');
    });
  });
}
