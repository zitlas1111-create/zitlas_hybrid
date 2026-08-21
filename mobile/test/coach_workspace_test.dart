import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// athlete's allergies are on screen while the week is being written, and
/// nothing silently blocks the coach.
void main() {
  const profile = DietProfile(
    dietPreference: DietPreference.vegetarian,
    allergies: ['Peanut'],
    neverEaten: ['Mushroom'],
    lovedFoods: ['Paneer'],
    budget: FoodBudget.economy,
    mealsPerDay: 4,
  );

  Future<CoachingPlanRepository> pumpEditor(
    WidgetTester tester, {
    CoachDietPlan? initial,
    DietProfile athleteProfile = profile,
  }) async {
    final db = FakeFirebaseFirestore();
    final repo = CoachingPlanRepository(firestore: db);
    await tester.pumpWidget(MaterialApp(
      home: CoachDietEditorScreen(
        athleteId: 'athlete_1',
        athleteName: 'Rohit',
        coachId: 'coach_1',
        coachName: 'Coach Rahul',
        planType: 'complete',
        initialPlan: initial ?? const CoachDietPlan(),
        athleteProfile: athleteProfile,
        repository: repo,
        foodRepository: FoodSearchRepository(),
      ),
    ));
    await tester.pumpAndSettle();
    return repo;
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

      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate meal'));
      await tester.pumpAndSettle();

      expect((await repo.fetch('athlete_1')).exists, isFalse,
          reason: 'nothing reaches Firestore before Publish');

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Publish'),
      );
      expect(button.onPressed, isNotNull, reason: 'but Publish is now live');
    });

    testWidgets('Publish writes the plan, a version and a notification',
        (tester) async {
      final repo = await pumpEditor(
        tester,
        initial: CoachDietPlan(days: [
          CoachDietDay(day: 'Monday', meals: [
            const CoachMeal(id: 'm0', name: 'Breakfast', options: [
              CoachMealOption(name: 'Poha'),
            ]),
          ]),
        ]),
      );

      await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate meal'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();

      final doc = await repo.fetch('athlete_1');
      expect(doc.exists, isTrue);
      expect(doc.dietVersion, 1);
      expect((await repo.watchVersions('athlete_1', type: 'diet').first).length, 1);
      expect(find.textContaining('Published to Rohit'), findsOneWidget);
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
