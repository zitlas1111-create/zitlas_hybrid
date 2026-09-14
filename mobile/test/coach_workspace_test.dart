import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart' show SetOptions;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/coaching/data/coaching_plan_repository.dart';
import 'package:zitlas_mobile/features/coaching/models/coach_diet_plan.dart';
import 'package:zitlas_mobile/features/coaching/presentation/screens/coach_diet_editor_screen.dart';
import 'package:zitlas_mobile/features/coaching/presentation/widgets/coach_option_editor_sheet.dart';
import 'package:zitlas_mobile/features/diet/models/diet_profile.dart';
import 'package:zitlas_mobile/features/expert_dashboard/data/food_search_repository.dart';

/// The coach's diet editor.
///
/// What matters here is that the coach's work is safe and the athlete's
/// preferences are never out of sight: edits stay local until Publish, the
/// athlete's allergies are on screen while the week is being written, nothing
/// silently blocks the coach — and a publish on top of a NEWER plan (another
/// device, the website) is refused and can be reloaded, never overwritten.
void main() {
  const profile = DietProfile(
    dietPreference: DietPreference.vegetarian,
    allergies: ['Peanut'],
    neverEaten: ['Mushroom'],
    lovedFoods: ['Paneer'],
    budget: FoodBudget.economy,
    mealsPerDay: 4,
  );

  /// Stand-in for POST /api/coaching-plans/{id}/diet — the base-version check,
  /// then the plan. (The real endpoint also checks the coach, snapshots the
  /// version and notifies: backend/tests/test_coaching_plans.py.)
  ApiClient endpoint(FakeFirebaseFirestore db) => ApiClient(
        httpClient: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final ref = db.collection('coaching_plans').doc('athlete_1');
          final current = ((await ref.get()).data()?['dietVersion'] as num?)?.toInt() ?? 0;
          if (body['baseVersion'] != current) {
            return http.Response(
              jsonEncode({
                'detail': {'error': 'stale_version', 'baseVersion': body['baseVersion'], 'currentVersion': current},
              }),
              409,
            );
          }
          await ref.set(
            {'coachId': 'coach_1', 'diet': body['diet'], 'dietVersion': current + 1},
            SetOptions(merge: true),
          );
          return http.Response(jsonEncode({'success': true, 'dietVersion': current + 1}), 200);
        }),
        baseUrl: 'https://api.test',
      );

  ApiClient answering(int status, Object? detail) => ApiClient(
        httpClient: MockClient((_) async => http.Response(jsonEncode({'detail': detail}), status)),
        baseUrl: 'https://api.test',
      );

  Future<CoachingPlanRepository> pumpEditor(
    WidgetTester tester, {
    CoachDietPlan? initial,
    DietProfile athleteProfile = profile,
    FakeFirebaseFirestore? db,
    ApiClient? api,
    int baseVersion = 0,
  }) async {
    final store = db ?? FakeFirebaseFirestore();
    final repo = CoachingPlanRepository(firestore: store, apiClient: api ?? endpoint(store));
    await tester.pumpWidget(MaterialApp(
      home: CoachDietEditorScreen(
        athleteId: 'athlete_1',
        athleteName: 'Rohit',
        coachId: 'coach_1',
        coachName: 'Coach Rahul',
        planType: 'complete',
        initialPlan: initial ?? const CoachDietPlan(),
        athleteProfile: athleteProfile,
        baseVersion: baseVersion,
        repository: repo,
        foodRepository: FoodSearchRepository(),
      ),
    ));
    await tester.pumpAndSettle();
    return repo;
  }

  CoachDietPlan oneMeal(String food) => CoachDietPlan(days: [
        CoachDietDay(day: 'Monday', meals: [
          CoachMeal(id: 'm0', name: 'Breakfast', options: [CoachMealOption(name: food)]),
        ]),
      ]);

  Future<void> duplicateFirstMeal(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate meal'));
    await tester.pumpAndSettle();
  }

  Future<void> publish(WidgetTester tester) async {
    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
  }

  group('the editor opens ready to work', () {
    testWidgets('an empty plan starts as a blank week, not a blank screen',
        (tester) async {
      await pumpEditor(tester);
      expect(find.text('Mon'), findsOneWidget);
      expect(find.text('Sun'), findsOneWidget);
      expect(find.text('Breakfast'), findsOneWidget);
      // Dinner sits below the fold on a test-sized viewport — scroll the
      // editor's own list rather than searching for a Scrollable (the day
      // tabs are one too).
      await tester.drag(find.byType(ListView).last, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(find.text('Dinner'), findsOneWidget);
    });

    testWidgets('an existing plan opens on its own content', (tester) async {
      await pumpEditor(
        tester,
        initial: CoachDietPlan(days: [
          CoachDietDay(day: 'Monday', meals: [
            const CoachMeal(id: 'm0', name: 'Breakfast', options: [
              CoachMealOption(name: 'Paneer Bhurji', calories: 320, protein: 22),
            ]),
          ]),
        ]),
      );
      expect(find.text('Paneer Bhurji'), findsOneWidget);
      // Shown twice on purpose: the day total up top, and the option row.
      expect(find.textContaining('320 kcal'), findsWidgets);
    });
  });

  group('athlete preferences are never hidden', () {
    testWidgets('allergies and dislikes are on screen while editing',
        (tester) async {
      await pumpEditor(tester);
      expect(find.text('USER PREFERENCES'), findsOneWidget);
      expect(find.text('Peanut'), findsOneWidget);
      expect(find.text('Mushroom'), findsOneWidget);
      expect(find.text('Paneer'), findsOneWidget);
      expect(find.textContaining('Vegetarian'), findsWidgets);
    });

    testWidgets('an incomplete food profile says so rather than showing blanks',
        (tester) async {
      await pumpEditor(tester, athleteProfile: const DietProfile());
      expect(find.textContaining('food profile'), findsOneWidget);
    });

    testWidgets('a food that breaks the profile is flagged in place',
        (tester) async {
      await pumpEditor(
        tester,
        initial: CoachDietPlan(days: [
          CoachDietDay(day: 'Monday', meals: [
            const CoachMeal(id: 'm0', name: 'Breakfast', options: [
              CoachMealOption(name: 'Mushroom Omelette'),
            ]),
          ]),
        ]),
      );
      expect(find.textContaining('Never eats Mushroom'), findsWidgets);
      // 'Never eats' is a preference, not a safety issue, so the banner uses
      // its softer heading — allergens and diet-type breaks get the stronger one.
      expect(find.text('Worth a look before publishing'), findsOneWidget);
    });
  });

  group('publishing', () {
    testWidgets('Publish is disabled until something changes', (tester) async {
      await pumpEditor(tester);
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Publish'),
      );
      expect(button.onPressed, isNull,
          reason: 'nothing to publish means nothing to notify the athlete about');
    });

    testWidgets('edits stay LOCAL until Publish is pressed', (tester) async {
      // The athlete holds a live listener; a half-built week must not stream
      // to them meal by meal.
      final repo = await pumpEditor(tester);

      await duplicateFirstMeal(tester);

      expect((await repo.fetch('athlete_1')).exists, isFalse,
          reason: 'nothing reaches Firestore before Publish');

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Publish'),
      );
      expect(button.onPressed, isNotNull, reason: 'but Publish is now live');
    });

    testWidgets('Publish goes through the backend and the plan is live', (tester) async {
      final repo = await pumpEditor(tester, initial: oneMeal('Poha'));

      await duplicateFirstMeal(tester);
      await publish(tester);

      final doc = await repo.fetch('athlete_1');
      expect(doc.exists, isTrue);
      expect(doc.dietVersion, 1);
      expect(find.textContaining('Published to Rohit'), findsOneWidget);
    });

    testWidgets('a second publish from the same editor builds on the first', (tester) async {
      final repo = await pumpEditor(tester, initial: oneMeal('Poha'));

      await duplicateFirstMeal(tester);
      await publish(tester);
      await duplicateFirstMeal(tester);
      await publish(tester);

      expect((await repo.fetch('athlete_1')).dietVersion, 2,
          reason: 'the editor moves its base forward — no false conflict');
    });

    testWidgets('a publish on top of a newer plan is refused, and the latest can be loaded',
        (tester) async {
      // Another device already published v5; this editor opened on v4.
      final db = FakeFirebaseFirestore();
      await db.collection('coaching_plans').doc('athlete_1').set({
        'coachId': 'coach_1',
        'dietVersion': 5,
        'diet': oneMeal('Newer Upma').toMap(),
      });
      final repo = await pumpEditor(tester, db: db, baseVersion: 4, initial: oneMeal('Poha'));

      await duplicateFirstMeal(tester);
      await publish(tester);

      expect(find.text('A newer plan was published'), findsOneWidget);
      expect(find.textContaining('NOT published'), findsOneWidget);
      final stored = await repo.fetch('athlete_1');
      expect(stored.dietVersion, 5);
      expect(stored.diet.days.first.meals.first.options.first.name, 'Newer Upma',
          reason: 'nothing was overwritten');

      await tester.tap(find.text('Load latest'));
      await tester.pumpAndSettle();
      expect(find.text('Newer Upma'), findsOneWidget);
      expect(find.text('Poha'), findsNothing);

      // Rebased on v5: the next publish goes through.
      await duplicateFirstMeal(tester);
      await publish(tester);
      expect((await repo.fetch('athlete_1')).dietVersion, 6);
      expect(find.textContaining('Published to Rohit'), findsOneWidget);
    });

    testWidgets('keeping the draft after a conflict publishes nothing', (tester) async {
      final db = FakeFirebaseFirestore();
      await db.collection('coaching_plans').doc('athlete_1').set({
        'coachId': 'coach_1',
        'dietVersion': 5,
        'diet': oneMeal('Newer Upma').toMap(),
      });
      final repo = await pumpEditor(tester, db: db, baseVersion: 4, initial: oneMeal('Poha'));

      await duplicateFirstMeal(tester);
      await publish(tester);
      await tester.tap(find.text('Keep my draft'));
      await tester.pumpAndSettle();

      expect(find.text('Poha'), findsWidgets, reason: 'the draft is still on screen');
      final stored = await repo.fetch('athlete_1');
      expect(stored.dietVersion, 5);
      expect(stored.diet.days.first.meals.first.options.first.name, 'Newer Upma');
    });

    testWidgets('a refused publish says why and offers no retry', (tester) async {
      final repo = await pumpEditor(
        tester,
        api: answering(403, 'coaching_not_active'),
        initial: oneMeal('Poha'),
      );

      await duplicateFirstMeal(tester);
      await publish(tester);

      expect(find.text('This coaching has ended — the plan was NOT published.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect((await repo.fetch('athlete_1')).exists, isFalse);
    });

    testWidgets('a server failure says so and can be retried', (tester) async {
      await pumpEditor(tester, api: answering(500, null), initial: oneMeal('Poha'));

      await duplicateFirstMeal(tester);
      await publish(tester);

      expect(find.textContaining("couldn't publish"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('meal actions', () {
    testWidgets('a deleted meal can be undone', (tester) async {
      await pumpEditor(tester);
      expect(find.text('Breakfast'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete meal'));
      await tester.pumpAndSettle();

      expect(find.text('Breakfast'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Breakfast'), findsOneWidget);
    });

    testWidgets('days can be switched', (tester) async {
      await pumpEditor(tester);
      expect(find.text('Monday'), findsOneWidget);
      await tester.tap(find.text('Wed'));
      await tester.pumpAndSettle();
      expect(find.text('Wednesday'), findsOneWidget);
    });
  });

  group('the option editor', () {
    testWidgets('a blank macro stays blank rather than becoming zero',
        (tester) async {
      // A coach who has not measured the carbs has not said "zero carbs".
      CoachMealOption? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await showCoachOptionEditorSheet(
                  context,
                  option: const CoachMealOption(name: 'Poha', calories: 250),
                  mealName: 'Breakfast',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Protein (g)'), '9');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result!.protein, 9);
      expect(result!.calories, 250);
      expect(result!.carbs, isNull, reason: 'never touched, so still unknown');
      expect(result!.fat, isNull);
    });

    testWidgets('a nameless food is rejected with a reason', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showCoachOptionEditorSheet(
                context,
                option: const CoachMealOption(name: 'Poha'),
                mealName: 'Breakfast',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Food / quantity'), '');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(find.text('A food needs a name.'), findsOneWidget);
    });
  });
}
