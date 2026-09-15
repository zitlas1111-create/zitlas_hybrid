import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/diet/models/diet_calculations.dart';
import 'package:zitlas_mobile/features/diet/models/diet_meal.dart';
import 'package:zitlas_mobile/features/diet/models/diet_plan_content.dart';
import 'package:zitlas_mobile/features/diet/models/swap_result.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/diet_meal_card.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/diet_meal_swap_sheet.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/diet_plan_header_card.dart';

/// Calorie tracking is not part of the current diet experience: the Diet
/// screen, the diet meal cards and the Meal Swap cards show what the food IS
/// (name, diet type, cuisine, why it fits) — never "149 kcal · 6.2g P · 8.2g
/// C · 13.0g F". The numbers are still parsed and kept on the models, because
/// the backend and dataset keep them; only the display is gone.

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

Finder _text(Pattern p) => find.textContaining(p, findRichText: true);

/// The exact option from the report, as /api/diet/swap sends it.
final Map<String, dynamic> _reportedOption = {
  'name': 'Moong Dal Chilla',
  'foods': ['Moong Dal Chilla (2 pieces)'],
  'calories': 149,
  'protein_g': 6.2,
  'carbs_g': 8.2,
  'fat_g': 13.0,
  'reason': 'Moong Dal Chilla — a vegetarian breakfast dish. Also genuinely high in protein.',
  'availability': 'Commonly available in Maharashtra',
  'budget_level': 'Economy',
  'high_protein': true,
  'quality_labels': ['Comparable portion'],
  'diet_type': 'Vegetarian',
  'cuisine': 'Maharashtrian',
};

Future<void> _pumpOption(WidgetTester tester, SwapOption option) => tester.pumpWidget(
      _host(SwapOptionCard(option: option, rank: 1, selected: false, onTap: () {})),
    );

void main() {
  group('Meal Swap option card', () {
    test('the model still keeps the nutrition numbers and reads diet type + cuisine', () {
      final option = SwapOption.fromMap(_reportedOption)!;
      expect(option.calories, 149);
      expect(option.proteinG, 6.2);
      expect(option.carbsG, 8.2);
      expect(option.fatG, 13.0);
      expect(option.dietType, 'Vegetarian');
      expect(option.cuisine, 'Maharashtrian');
    });

    testWidgets('shows name, reason, diet type, cuisine and suitability — no calories or macros',
        (tester) async {
      await _pumpOption(tester, SwapOption.fromMap(_reportedOption)!);
      expect(tester.takeException(), isNull);

      expect(find.text('Moong Dal Chilla'), findsOneWidget);
      expect(_text('genuinely high in protein'), findsOneWidget);
      expect(find.text('🟢 Veg'), findsOneWidget);
      expect(find.text('🍛 Maharashtrian'), findsOneWidget);
      expect(find.text('📍 Commonly available in Maharashtra'), findsOneWidget);
      expect(find.text('✨ Comparable portion'), findsOneWidget);

      expect(_text(RegExp('kcal', caseSensitive: false)), findsNothing);
      expect(_text(RegExp(r'\b149\b')), findsNothing);
      expect(_text(RegExp(r'\d+(\.\d+)?\s*g\s*[PCF]\b')), findsNothing);
      expect(_text('6.2'), findsNothing);
      expect(_text('13.0'), findsNothing);
    });

    testWidgets('egg and non-veg options are labelled; an unknown type shows no diet tag',
        (tester) async {
      await _pumpOption(tester, SwapOption.fromMap({..._reportedOption, 'diet_type': 'Egg'})!);
      expect(find.text('🥚 Egg'), findsOneWidget);

      await _pumpOption(
          tester, SwapOption.fromMap({..._reportedOption, 'diet_type': 'Non-Vegetarian'})!);
      expect(find.text('🔴 Non-veg'), findsOneWidget);

      await _pumpOption(tester, SwapOption.fromMap({..._reportedOption, 'diet_type': ''})!);
      expect(find.text('🟢 Veg'), findsNothing);
      expect(find.text('🥚 Egg'), findsNothing);
      expect(find.text('🔴 Non-veg'), findsNothing);
    });

    testWidgets('a pan-Indian option (no cuisine) shows no cuisine tag', (tester) async {
      await _pumpOption(tester, SwapOption.fromMap({..._reportedOption, 'cuisine': ''})!);
      expect(_text('🍛'), findsNothing);
    });
  });

  group('Diet meal card', () {
    testWidgets('shows the foods and actions but no calories or protein count', (tester) async {
      const meal = DietMeal(
        mealName: 'Breakfast',
        time: '8:00 AM',
        foods: ['Poha (1 plate (200 g))'],
        calories: 201,
        proteinG: 5.3,
      );
      await tester.pumpWidget(_host(DietMealCard(meal: meal, onSwap: () {}, onGetRecipe: () {})));
      expect(tester.takeException(), isNull);

      expect(_text('Poha'), findsWidgets);
      expect(find.text('Swap'), findsOneWidget);
      expect(_text(RegExp('kcal', caseSensitive: false)), findsNothing);
      expect(_text(RegExp(r'\b201\b')), findsNothing);
      expect(_text('5.3'), findsNothing);
    });
  });

  group('Diet plan header card', () {
    testWidgets('shows protein and water targets but no calorie target', (tester) async {
      await tester.pumpWidget(_host(DietPlanHeaderCard(
        plan: const DietPlanContent(planName: 'Your Diet Plan', dailyCaloriesTarget: 2200),
        calculations: const DietCalculations(
          calorieTargetKcal: 2200,
          proteinTargetG: 120,
          waterTargetLiters: 3,
        ),
        isExpertPlan: false,
        expertName: null,
        onRequestReview: () {},
      )));
      expect(tester.takeException(), isNull);

      expect(find.text('Protein'), findsOneWidget);
      expect(find.text('120 g'), findsOneWidget);
      expect(find.text('Water'), findsOneWidget);
      expect(find.text('3 L'), findsOneWidget);
      expect(_text(RegExp('calorie', caseSensitive: false)), findsNothing);
      expect(_text(RegExp('kcal', caseSensitive: false)), findsNothing);
      expect(_text('2200'), findsNothing);
    });
  });
}
