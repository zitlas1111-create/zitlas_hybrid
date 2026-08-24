import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/coaching/models/coach_diet_plan.dart';
import 'package:zitlas_mobile/features/diet/presentation/widgets/coach_diet_card.dart';

/// WHAT THE FREE-TRIAL ATHLETE ACTUALLY SEES.
///
/// The gate tests prove the coach plan is now *eligible* for a FREE_TRIAL
/// (planType == null). These prove the last mile: that the nutritionist's
/// meals are the ones rendered, and that the athlete is told who changed them.
///
/// The data below mirrors the real production document inspected during the
/// diagnosis — coaching_plans/OqVB9GRjBudSjzX55ysI8rmRjeJ2, saved by "pratik"
/// at dietVersion 3, whose day-0 meals really are "Butter panner" and
/// "Puri bhaji".
void main() {
  CoachDietPlan planWith(String mealName, String optionName) {
    return CoachDietPlan.fromMap({
      'days': [
        {
          'day': 'Monday',
          'meals': [
            {
              'id': 'm1',
              'name': mealName,
              'options': [
                {'name': optionName, 'calories': 420, 'protein': 38, 'notes': ''},
              ],
            },
          ],
        },
      ],
    });
  }

  Future<void> pump(
    WidgetTester tester, {
    required String coachName,
    DateTime? updatedAt,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CoachDietCard(
            plan: planWith('Breakfast', 'Butter panner'),
            dayIndex: 0,
            coachName: coachName,
            updatedAt: updatedAt,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('the nutritionist-modified diet is what is displayed', () {
    testWidgets('the coach\'s meal is on screen', (tester) async {
      await pump(tester, coachName: 'pratik');
      expect(find.textContaining('Butter panner'), findsWidgets,
          reason: "the athlete must see the nutritionist's meal, not the AI one");
    });

    testWidgets('no AI meal is substituted for it', (tester) async {
      await pump(tester, coachName: 'pratik');
      expect(find.textContaining('Oats'), findsNothing);
    });
  });

  group('nutritionist attribution', () {
    testWidgets('says the plan was reviewed and updated', (tester) async {
      await pump(tester, coachName: 'pratik');
      expect(find.textContaining('Reviewed & Updated'), findsOneWidget,
          reason: 'the athlete has to be able to tell their expert has '
              'actually been through this plan');
    });

    testWidgets('names the actual nutritionist', (tester) async {
      await pump(tester, coachName: 'pratik');
      expect(find.textContaining('pratik'), findsWidgets);
    });

    testWidgets('shows when it was last updated', (tester) async {
      await pump(
        tester,
        coachName: 'pratik',
        updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      expect(find.textContaining('pratik ·'), findsWidgets,
          reason: 'a name without a date does not answer "is this current?"');
    });

    testWidgets('still names the coach when no timestamp exists',
        (tester) async {
      await pump(tester, coachName: 'pratik', updatedAt: null);
      expect(find.textContaining('pratik'), findsWidgets);
    });

    testWidgets('falls back gracefully with no coach name', (tester) async {
      await pump(tester, coachName: 'Your coach');
      expect(find.textContaining('Reviewed & Updated'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the two clients say the same thing', () {
    test('the website banner uses the same wording', () {
      // frontend/website/pages/diet/diet.js — an athlete moving between
      // phone and browser should read one consistent sentence.
      final js = _websiteDietSource();
      if (js == null) {
        markTestSkipped('website source not reachable from this run');
        return;
      }
      expect(js.contains('Reviewed &amp; Updated by'), isTrue);
      expect(js.contains('dietUpdatedAt'), isTrue,
          reason: 'the date must come from the same document as the meals, '
              'or the two can drift');
    });

    test('the website banner only renders for an ACTIVE relationship', () {
      final js = _websiteDietSource();
      if (js == null) return;
      expect(js.contains("_pcRel.status === 'active'"), isTrue);
      expect(js.contains('Coaching ended'), isTrue,
          reason: 'an ended relationship must say so rather than still '
              'claiming the plan is being actively managed');
    });
  });
}

String? _websiteDietSource() {
  for (final path in [
    '../frontend/website/pages/diet/diet.js',
    'frontend/website/pages/diet/diet.js',
  ]) {
    final f = File(path);
    if (f.existsSync()) return f.readAsStringSync();
  }
  return null;
}
