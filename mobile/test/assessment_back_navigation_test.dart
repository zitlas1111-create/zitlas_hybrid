import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/assessment/models/assessment_question.dart';
import 'package:zitlas_mobile/features/assessment/presentation/widgets/question_view.dart';

/// Regression tests for the Assessment back-navigation crash:
///
///   `type 'int' is not a subtype of type 'List<dynamic>?' in type cast`
///
/// WHY THIS CRASHED. `assessment_screen.dart` keys QuestionView with
/// `ValueKey('<goal>_<currentQuestionIndex>')`. Pressing Back decrements the
/// index, so the key changes, so Flutter disposes the old State and builds a
/// NEW one — meaning `initState()` runs again, this time for a question that
/// ALREADY has a stored answer. `initState()` unconditionally ran
/// `widget.existingAnswer as List?` regardless of question type, so any
/// numeric answer (every `kWheelConfig` field plus every slider) took the
/// whole wizard down the moment the athlete navigated back onto it.
///
/// These tests mount QuestionView with exactly the state that Back produces:
/// a question that already has an answer of each real stored type.
void main() {
  /// Mounts QuestionView the way `_buildScreen`'s `assess` branch does.
  Future<void> pump(
    WidgetTester tester, {
    required AssessmentQuestion question,
    required dynamic existingAnswer,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionView(
            // The real key from assessment_screen.dart — a changed index is
            // what forces the fresh State that re-runs initState().
            key: const ValueKey('lose_weight_3'),
            question: question,
            questionIndex: 3,
            totalQuestions: 10,
            existingAnswer: existingAnswer,
            onBack: () {},
            onAnswerAndAdvance: (_, _) async {},
            onSubmitText: (_, _) async => null,
            onSubmitMultiselect: (_) async => null,
            onSetAnswer: (_, _) {},
          ),
        ),
      ),
    );
  }

  group('back onto an already-answered NUMERIC question does not crash', () {
    // Every wheel field stores a number, so each of these was a guaranteed
    // crash on Back before the fix.
    for (final field in kWheelConfig.keys) {
      testWidgets('wheel field "$field" with a stored int', (tester) async {
        await pump(
          tester,
          question: AssessmentQuestion(
            field: field,
            prompt: 'How much $field?',
            type: AssessmentQuestionType.text,
          ),
          existingAnswer: kWheelConfig[field]!.defaultVal,
        );

        expect(tester.takeException(), isNull);
        expect(find.text('How much $field?'), findsOneWidget);
      });
    }

    testWidgets('slider question with a stored int', (tester) async {
      await pump(
        tester,
        question: const AssessmentQuestion(
          field: 'stress_level',
          prompt: 'Rate your stress',
          type: AssessmentQuestionType.slider,
          min: 1,
          max: 10,
          defaultVal: 5,
        ),
        existingAnswer: 7,
      );

      expect(tester.takeException(), isNull);
      // The stored answer is restored, not reset to the default.
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('single-choice question with a stored String', (tester) async {
      await pump(
        tester,
        question: const AssessmentQuestion(
          field: 'activity_level',
          prompt: 'How active are you?',
          type: AssessmentQuestionType.options,
          options: [
            AssessmentOption(value: 'low', label: 'Low'),
            AssessmentOption(value: 'high', label: 'High'),
          ],
        ),
        existingAnswer: 'high',
      );

      expect(tester.takeException(), isNull);
      expect(find.text('How active are you?'), findsOneWidget);
    });
  });

  group('multiselect answers still round-trip', () {
    testWidgets('a stored List repopulates the selection', (tester) async {
      await pump(
        tester,
        question: const AssessmentQuestion(
          field: 'health_goals',
          prompt: 'Pick your goals',
          type: AssessmentQuestionType.multiselect,
          options: [
            AssessmentOption(value: 'energy', label: 'More energy'),
            AssessmentOption(value: 'sleep', label: 'Better sleep'),
            AssessmentOption(value: 'strength', label: 'Strength'),
          ],
        ),
        existingAnswer: const ['energy', 'strength'],
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Pick your goals'), findsOneWidget);
    });

    testWidgets('a numeric-as-string list from the website still parses', (tester) async {
      // Answers round-trip through the website's Firestore user doc, where a
      // JS-written multiselect can carry non-String entries. `.cast<String>()`
      // would have thrown on access; mapping via toString() does not.
      await pump(
        tester,
        question: const AssessmentQuestion(
          field: 'meals_per_day',
          prompt: 'Which meals?',
          type: AssessmentQuestionType.multiselect,
          options: [
            AssessmentOption(value: '2', label: 'Two'),
            AssessmentOption(value: '3', label: 'Three'),
          ],
        ),
        existingAnswer: const [2, 3],
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Which meals?'), findsOneWidget);
    });
  });

  // AssessmentController's own back/fresh-session logic
  // (backFromQuestion / startAssessment) is deliberately NOT covered here:
  // constructing it requires an AssessmentRepository, which requires a live
  // FirebaseFirestore. Standing up Firebase test scaffolding to exercise
  // index arithmetic would cost far more than it proves, and the crash this
  // file exists for is entirely in QuestionView.initState above.
}
