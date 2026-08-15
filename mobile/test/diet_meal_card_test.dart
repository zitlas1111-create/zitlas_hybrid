import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/models/diet_meal.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/diet_meal_card.dart';

/// Regression test for the reported bug: "Easy Recipe" and "Swap" rendering
/// on top of each other (a RenderFlex overflow) on real Android phones. The
/// fix replaced a single unconstrained Row (stats + Spacer + two
/// TextButton.icon widgets, all fighting for the same line) with a stats row
/// followed by a dedicated actions row where each button is `Expanded` —
/// these tests assert that holds across the narrow/normal/tablet widths the
/// spec calls out, not just "looks fine on my device".
Future<void> _pumpCardAt(WidgetTester tester, double width, {required DietMeal meal}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: DietMealCard(
              meal: meal,
              onSwap: () {},
              onGetRecipe: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final meal = const DietMeal(
    mealName: 'Breakfast',
    time: '8:00 AM',
    foods: ['Poha (Home Style) (1 plate (200 g))'],
    calories: 201,
    proteinG: 5.3,
  );

  final preWorkoutMeal = const DietMeal(
    mealName: 'Pre-Workout Snack',
    time: '10:30 AM',
    foods: ['Banana'],
    calories: 105,
  );

  group('DietMealCard action row never overlaps (item 1/15/20)', () {
    testWidgets('small Android phone width (320dp) — no RenderFlex overflow', (tester) async {
      await _pumpCardAt(tester, 320, meal: meal);
      expect(tester.takeException(), isNull);
      expect(find.text('Get Easy Recipe'), findsOneWidget);
      expect(find.text('Swap'), findsOneWidget);
    });

    testWidgets('normal Android phone width (390dp) — no RenderFlex overflow', (tester) async {
      await _pumpCardAt(tester, 390, meal: meal);
      expect(tester.takeException(), isNull);
    });

    testWidgets('large phone / small tablet width (600dp) — no RenderFlex overflow', (tester) async {
      await _pumpCardAt(tester, 600, meal: meal);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tablet width (900dp) — no RenderFlex overflow', (tester) async {
      await _pumpCardAt(tester, 900, meal: meal);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the two buttons are independent touch targets — tapping one never triggers the other', (tester) async {
      var recipeTaps = 0;
      var swapTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: DietMealCard(
                meal: meal,
                onSwap: () => swapTaps++,
                onGetRecipe: () => recipeTaps++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Get Easy Recipe'));
      await tester.pump();
      expect(recipeTaps, 1);
      expect(swapTaps, 0);

      await tester.tap(find.text('Swap'));
      await tester.pump();
      expect(recipeTaps, 1);
      expect(swapTaps, 1);
    });
  });

  group('Pre/Post-workout purpose badge (item 21)', () {
    testWidgets('a Pre-Workout meal shows the Quick Energy badge AND the Workout Fuel button', (tester) async {
      await _pumpCardAt(tester, 390, meal: preWorkoutMeal);
      expect(tester.takeException(), isNull);
      expect(find.text('⚡ Quick Energy'), findsOneWidget);
      expect(find.text('Get Workout Fuel'), findsOneWidget);
      expect(find.text('Get Easy Recipe'), findsNothing);
    });

    testWidgets('a normal Breakfast meal shows no workout purpose badge, and the generic button label', (tester) async {
      await _pumpCardAt(tester, 390, meal: meal);
      expect(find.text('⚡ Quick Energy'), findsNothing);
      expect(find.text('💪 Recovery'), findsNothing);
      expect(find.text('Get Easy Recipe'), findsOneWidget);
    });

    testWidgets('a Post-Workout meal shows the Recovery badge AND the Recovery Recipe button', (tester) async {
      final postWorkoutMeal = const DietMeal(mealName: 'Post-Workout', foods: ['Protein Shake']);
      await _pumpCardAt(tester, 390, meal: postWorkoutMeal);
      expect(tester.takeException(), isNull);
      expect(find.text('💪 Recovery'), findsOneWidget);
      expect(find.text('Get Recovery Recipe'), findsOneWidget);
      expect(find.text('Get Easy Recipe'), findsNothing);
    });
  });

  group('Swap still works exactly as before (do not break existing functionality)', () {
    testWidgets('the Swap button is present and calls onSwap when onGetRecipe is null', (tester) async {
      var swapTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DietMealCard(meal: meal, onSwap: () => swapTaps++),
          ),
        ),
      );
      expect(find.text('Get Easy Recipe'), findsNothing);
      await tester.tap(find.text('Swap'));
      expect(swapTaps, 1);
    });

    testWidgets('a recovery-day meal keeps the recipe button but shows Swap as locked (matches diet.js)', (tester) async {
      // The website's diet.js only locks Swap for a `_recovery` meal
      // (`swap-btn--locked`, still visible) — `buildRecipeButton(meal)` is
      // unconditional. Flutter used to hide BOTH buttons for a recovery
      // meal, which was a real behavior mismatch once recovery meals
      // actually became reachable (the Health Status diet override).
      final recoveryMeal = const DietMeal(mealName: 'Breakfast', foods: ['Rest'], recovery: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DietMealCard(meal: recoveryMeal, onSwap: () {}, onGetRecipe: () {}),
          ),
        ),
      );
      expect(find.text('Get Easy Recipe'), findsOneWidget);
      expect(find.text('Swap'), findsNothing);
      expect(find.text('Recovery meal'), findsOneWidget);
    });

    testWidgets('tapping the locked Swap button never calls onSwap, only shows an explanation', (tester) async {
      var swapTaps = 0;
      final recoveryMeal = const DietMeal(mealName: 'Breakfast', foods: ['Rest'], recovery: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DietMealCard(meal: recoveryMeal, onSwap: () => swapTaps++, onGetRecipe: () {}),
          ),
        ),
      );
      await tester.tap(find.text('Recovery meal'));
      await tester.pump();
      expect(swapTaps, 0);
      expect(find.textContaining('swap is locked'), findsOneWidget);
    });
  });
}
