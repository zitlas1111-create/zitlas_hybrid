import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/auth/auth_state.dart';
import 'package:zitlas_mobile/features/diet/data/recipe_repository.dart';
import 'package:zitlas_mobile/features/diet/models/meal_recipe.dart';
import 'package:zitlas_mobile/features/diet/presentation/screens/recipe_screen.dart';
import 'package:zitlas_mobile/models/user_model.dart';

/// WHAT THE ATHLETE ACTUALLY SEES ON THE RECIPE SCREEN.
///
/// The payloads below are VERBATIM from a live `find_meal_video` call against
/// real YouTube — not invented. The reported bug was a 12-second clip of an
/// already-made shake being poured; the accepted replacement is an 85-second
/// preparation video for the same dish.
///
/// These drive the real `RecipeScreen`, so they check the last mile: that a
/// verified video renders as a video card, and that anything else renders as
/// "Recipe video coming soon." rather than a silently empty section.
void main() {
  /// The live payload for "Peanut Butter Banana Shake", 2026-08-22.
  const realShakeVideo = {
    'video_id': 'odtzzfLrsHc',
    'video_url': 'https://www.youtube.com/watch?v=odtzzfLrsHc',
    'title': 'Peanut Butter Banana Smoothie',
    'channel_name': 'The Dinner Bite',
    'thumbnail_url': 'https://i.ytimg.com/vi/odtzzfLrsHc/hqdefault.jpg',
    'duration_seconds': 85,
    'relevance': 0.89,
    'verified': true,
    'match_type': 'recipe_specific',
    'source': 'youtube',
  };

  Map<String, dynamic> response({Map<String, dynamic>? video, String? note}) => {
        'meal_name': 'Peanut Butter Banana Shake',
        'meal_type': 'breakfast',
        'recipe': {
          'id': 'ZITLAS-MEAL-pbbs',
          'name': 'Peanut Butter Banana Shake',
          'description': 'A quick high-protein shake.',
          'ingredients': ['1 banana', '2 tbsp peanut butter', '250ml milk'],
          'instructions': ['Add everything to a blender.', 'Blend and serve.'],
          'nutrition_estimated': {'calories': 420, 'protein_g': 18},
          'why_it_works': 'Protein and carbs in one glass.',
        },
        'video': video,
        'video_note': note,
        'cached': false,
      };

  Future<void> pumpRecipe(
      WidgetTester tester, Map<String, dynamic> body) async {
    final mock = MockClient((_) async => http.Response(
          jsonEncode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
    final repo = RecipeRepository(
      apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      firestore: FakeFirebaseFirestore(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthState>(
        create: (_) => _FakeAuthState(),
        child: MaterialApp(
          home: RecipeScreen(
            mealType: 'breakfast',
            mealName: 'Peanut Butter Banana Shake',
            foods: const ['Peanut Butter Banana Shake'],
            repository: repo,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Straight to the full recipe, where the video lives.
    await tester.tap(find.text('View Recipe'));
    await tester.pumpAndSettle();
  }

  group('a verified preparation video is displayed', () {
    testWidgets('the recipe screen shows the real 85s shake video',
        (tester) async {
      await pumpRecipe(tester, response(video: realShakeVideo));

      expect(find.text('Watch how to make it'), findsOneWidget);
      expect(find.text('Peanut Butter Banana Smoothie'), findsOneWidget);
      expect(find.text('The Dinner Bite'), findsOneWidget);
      expect(find.text('Recipe video coming soon.'), findsNothing);
    });

    testWidgets('the recipe on screen is the dish that was asked for',
        (tester) async {
      await pumpRecipe(tester, response(video: realShakeVideo));

      expect(find.text('Peanut Butter Banana Shake'), findsWidgets);
      expect(find.textContaining('peanut butter'), findsWidgets);
    });

    test('the live payload satisfies every rule in the spec', () {
      final v = MealRecipeVideo.fromMap(realShakeVideo)!;
      expect(v.durationSeconds, greaterThanOrEqualTo(20));
      expect(v.durationSeconds, lessThanOrEqualTo(90));
      expect(v.verified, isTrue);
      expect(v.matchType, 'recipe_specific');
      expect(v.title.toLowerCase(), contains('peanut butter banana'));
      for (final marker in ['#shorts', '#short', 'shorts']) {
        expect(v.title.toLowerCase().contains(marker), isFalse);
      }
    });
  });

  group('anything unverified shows the coming-soon message instead', () {
    testWidgets('no video at all', (tester) async {
      await pumpRecipe(tester,
          response(video: null, note: 'Recipe video coming soon.'));

      expect(find.text('Recipe video coming soon.'), findsOneWidget);
      expect(find.text('The Dinner Bite'), findsNothing);
    });

    testWidgets('an unverified video is NOT rendered, even if one arrives',
        (tester) async {
      // Defence in depth: the backend refuses to send this, and the screen
      // refuses to draw it. A clip that only shows the finished dish misleads
      // about what the athlete is meant to do.
      await pumpRecipe(tester, response(
        video: {...realShakeVideo, 'verified': false},
        note: 'Recipe video coming soon.',
      ));

      expect(find.text('Recipe video coming soon.'), findsOneWidget);
      expect(find.text('Peanut Butter Banana Smoothie'), findsNothing);
    });

    testWidgets('the recipe itself still renders in full with no video',
        (tester) async {
      await pumpRecipe(tester,
          response(video: null, note: 'Recipe video coming soon.'));

      expect(find.textContaining('banana'), findsWidgets);
      expect(find.textContaining('blender'), findsWidgets);
    });
  });
}

class _FakeAuthState extends ChangeNotifier implements AuthState {
  @override
  UserModel? get profile => const UserModel(
        uid: 'athlete_1',
        email: 'athlete@example.com',
        name: 'Test Athlete',
      );

  @override
  AuthStatus get status => AuthStatus.authenticated;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
