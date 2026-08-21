import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/models/diet_meal.dart';
import 'package:zitlas_mobile/features/expert_dashboard/data/food_search_repository.dart';
import 'package:zitlas_mobile/features/expert_dashboard/presentation/widgets/exercise_editor_sheet.dart';
import 'package:zitlas_mobile/features/expert_dashboard/presentation/widgets/meal_editor_sheet.dart';
import 'package:zitlas_mobile/features/workout/models/workout_exercise.dart';

/// Expert plan editing — the expert must be able to change every detail
/// before it reaches the athlete, and must not be able to send something
/// nonsensical.

/// Pumps a sheet and returns whatever it pops.
Future<T?> openSheet<T>(
  WidgetTester tester,
  Future<T?> Function(BuildContext) open,
) async {
  T? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () async => result = await open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('meal editor', () {
    testWidgets('parses a stored food line into name / quantity / unit',
        (tester) async {
      const meal = DietMeal(mealName: 'Breakfast', foods: ['Poha (1 plate (200 g))']);
      await openSheet(tester, (ctx) => showMealEditorSheet(ctx, meal: meal));

      // The three parts appear as separate editable fields.
      expect(find.widgetWithText(TextField, 'Poha'), findsOneWidget);
      expect(find.widgetWithText(TextField, '1'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'plate (200 g)'), findsOneWidget);
    });

    testWidgets('every nutrition field is editable', (tester) async {
      const meal = DietMeal(
        mealName: 'Lunch',
        foods: ['Dal'],
        calories: 400,
        proteinG: 20,
      );
      await openSheet(tester, (ctx) => showMealEditorSheet(ctx, meal: meal));

      for (final label in ['Calories', 'Protein', 'Carbs', 'Fat']) {
        expect(find.widgetWithText(TextField, label), findsOneWidget,
            reason: '$label must be editable');
      }
      expect(find.text('Notes for the user'.toUpperCase()), findsOneWidget);
    });

    testWidgets('editing a food and saving returns the recomposed line',
        (tester) async {
      const meal = DietMeal(mealName: 'Breakfast', foods: ['Poha (1 plate (200 g))']);
      DietMeal? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showMealEditorSheet(context, meal: meal),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Poha'), 'Upma');
      await tester.tap(find.text('Save Meal'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.foods.single, 'Upma (1 plate (200 g))',
          reason: 'quantity and unit must be preserved around the new name');
      expect(saved!.edited, isTrue);
      expect(saved!.modifiedBy, 'Expert');
      expect(saved!.modifiedAt, isNotNull);
    });

    testWidgets('a food can be deleted', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice', 'Dal']);
      DietMeal? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showMealEditorSheet(context, meal: meal),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Meal'));
      await tester.pumpAndSettle();

      expect(saved!.foods.length, 1);
    });

    testWidgets('a food can be duplicated', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice']);
      DietMeal? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showMealEditorSheet(context, meal: meal),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Duplicate').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Meal'));
      await tester.pumpAndSettle();

      expect(saved!.foods, ['Rice', 'Rice']);
    });

    testWidgets('a blank food row can be added', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice']);
      await openSheet(tester, (ctx) => showMealEditorSheet(ctx, meal: meal));

      expect(find.byTooltip('Add blank row'), findsOneWidget);
      expect(find.text('Add from database'), findsOneWidget,
          reason: 'the expert must be able to pull from the real food database');
    });
  });

  group('meal validation — nothing invalid reaches the athlete', () {
    Future<DietMeal?> saveWith(WidgetTester tester, DietMeal meal,
        Future<void> Function(WidgetTester) edit) async {
      DietMeal? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showMealEditorSheet(context, meal: meal),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await edit(tester);
      await tester.tap(find.text('Save Meal'));
      await tester.pumpAndSettle();
      return saved;
    }

    testWidgets('clearing the ONLY food blocks the save', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice']);
      final saved = await saveWith(tester, meal, (t) async {
        await t.enterText(find.widgetWithText(TextField, 'Rice'), '');
      });

      expect(saved, isNull, reason: 'the sheet must stay open');
      // With nothing named left, "add at least one food" is the actionable
      // message — not a complaint about a specific row.
      expect(find.textContaining('at least one food'), findsOneWidget);
    });

    testWidgets('one blank row among several blocks the save', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice', 'Dal']);
      final saved = await saveWith(tester, meal, (t) async {
        await t.enterText(find.widgetWithText(TextField, 'Dal'), '');
      });

      expect(saved, isNull);
      expect(find.textContaining('needs a name'), findsOneWidget,
          reason: 'an unnamed row must be fixed or removed, never silently sent');
    });

    testWidgets('a meal with no foods at all blocks the save', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: []);
      final saved = await saveWith(tester, meal, (t) async {});

      expect(saved, isNull);
      expect(find.textContaining('at least one food'), findsOneWidget);
    });

    testWidgets('a negative calorie value cannot even be typed', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice']);
      final saved = await saveWith(tester, meal, (t) async {
        await t.enterText(find.widgetWithText(TextField, 'Calories'), '-100');
      });

      // The input formatter strips the minus sign, so the value that lands is
      // a positive 100 — a negative can never reach the plan.
      expect(saved, isNotNull);
      expect(saved!.calories, isNonNegative);
    });

    testWidgets('an implausible calorie total is rejected', (tester) async {
      const meal = DietMeal(mealName: 'Lunch', foods: ['Rice']);
      final saved = await saveWith(tester, meal, (t) async {
        await t.enterText(find.widgetWithText(TextField, 'Calories'), '50000');
      });

      expect(saved, isNull);
      expect(find.textContaining('too high'), findsOneWidget);
    });
  });

  group('exercise editor', () {
    testWidgets('every programming field is editable', (tester) async {
      const ex = WorkoutExercise(name: 'Squat');
      await openSheet(tester, (ctx) => showExerciseEditorSheet(ctx, exercise: ex));

      for (final label in [
        'Exercise name',
        'Sets',
        'Reps / Duration',
        'Weight',
        'Rest',
        'Instructions / form cue',
      ]) {
        expect(find.widgetWithText(TextField, label), findsOneWidget,
            reason: '$label must be editable');
      }
    });

    testWidgets('saving returns every edited field', (tester) async {
      const ex = WorkoutExercise(name: 'Squat');
      WorkoutExercise? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showExerciseEditorSheet(context, exercise: ex),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Sets'), '4');
      await tester.enterText(find.widgetWithText(TextField, 'Reps / Duration'), '8-10');
      await tester.enterText(find.widgetWithText(TextField, 'Weight'), '60 kg');
      await tester.enterText(find.widgetWithText(TextField, 'Rest'), '90 sec');
      await tester.enterText(
          find.widgetWithText(TextField, 'Instructions / form cue'), 'Keep chest up.');
      await tester.tap(find.text('Save Exercise'));
      await tester.pumpAndSettle();

      expect(saved!.sets, '4');
      expect(saved!.repsOrDuration, '8-10');
      expect(saved!.weight, '60 kg');
      expect(saved!.restSeconds, '90 sec');
      expect(saved!.tip, 'Keep chest up.');
    });

    testWidgets('an empty exercise name blocks the save', (tester) async {
      const ex = WorkoutExercise(name: 'Squat');
      WorkoutExercise? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showExerciseEditorSheet(context, exercise: ex),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Exercise name'), '');
      await tester.tap(find.text('Save Exercise'));
      await tester.pumpAndSettle();

      expect(saved, isNull);
      expect(find.textContaining('needs a name'), findsOneWidget);
    });

    testWidgets('semantic set/rep values are NOT rejected', (tester) async {
      // "3-4" and "AMRAP" are real programming, not invalid input.
      const ex = WorkoutExercise(name: 'Pull-ups');
      WorkoutExercise? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showExerciseEditorSheet(context, exercise: ex),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Sets'), '3-4');
      await tester.enterText(find.widgetWithText(TextField, 'Reps / Duration'), 'AMRAP');
      await tester.tap(find.text('Save Exercise'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.sets, '3-4');
      expect(saved!.repsOrDuration, 'AMRAP');
    });

    testWidgets('an absurd set count is rejected', (tester) async {
      const ex = WorkoutExercise(name: 'Squat');
      WorkoutExercise? saved;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async =>
                  saved = await showExerciseEditorSheet(context, exercise: ex),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Sets'), '300');
      await tester.tap(find.text('Save Exercise'));
      await tester.pumpAndSettle();

      expect(saved, isNull);
      expect(find.textContaining('typo'), findsOneWidget);
    });
  });

  group('schema safety — additive fields only', () {
    test('carbs/fat serialize under their own keys and round-trip', () {
      const meal = DietMeal(
        mealName: 'Lunch',
        foods: ['Dal'],
        calories: 400,
        proteinG: 20,
        carbsG: 45,
        fatG: 12,
      );
      final map = meal.toMap();
      expect(map['carbs_g'], 45);
      expect(map['fat_g'], 12);

      final restored = DietMeal.fromMap(map);
      expect(restored.carbsG, 45);
      expect(restored.fatG, 12);
    });

    test('an untouched meal writes NO carbs/fat keys at all', () {
      // Additive means absent-by-default: a plan the expert never touched
      // must serialize exactly as it did before these fields existed.
      const meal = DietMeal(mealName: 'Lunch', foods: ['Dal'], calories: 400);
      final map = meal.toMap();
      expect(map.containsKey('carbs_g'), isFalse);
      expect(map.containsKey('fat_g'), isFalse);
    });

    test('exercise weight serializes and round-trips', () {
      const ex = WorkoutExercise(name: 'Squat', sets: '4', weight: '60 kg');
      final map = ex.toMap();
      expect(map['weight'], '60 kg');
      expect(WorkoutExercise.fromMap(map).weight, '60 kg');
    });

    test('an untouched exercise writes no weight key', () {
      const ex = WorkoutExercise(name: 'Squat', sets: '4');
      expect(ex.toMap().containsKey('weight'), isFalse);
    });
  });

  group('food search results', () {
    test('a database row maps to the display string plans store', () {
      final food = FoodSearchResult.fromMap({
        'id': 1,
        'name': 'Poha',
        'display': 'Poha (1 plate (200 g))',
        'serving_size': '1 plate (200 g)',
        'calories': 181,
        'protein': 4.5,
        'region': 'West',
      })!;

      expect(food.name, 'Poha');
      expect(food.display, 'Poha (1 plate (200 g))');
      expect(food.calories, 181);
      expect(food.region, 'West');
    });

    test('a malformed row is dropped rather than crashing the picker', () {
      expect(FoodSearchResult.fromMap({'name': 'No id'}), isNull);
      expect(FoodSearchResult.fromMap({'id': 5}), isNull);
    });
  });
}
