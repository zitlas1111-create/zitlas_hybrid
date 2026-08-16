import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/assessment/models/assessment_question.dart';
import 'package:zitlas_mobile/features/assessment/presentation/widgets/question_view.dart';

/// The food-preferences question driven through the REAL `QuestionView`
/// widget — not the question definition in isolation.
///
/// Definition-level checks live in creator_recipe_test.dart; these prove the
/// athlete can actually see it, select several foods, change their mind, and
/// continue — including with nothing selected, since an empty answer is
/// valid for a preference.
void main() {
  /// Mirrors how AssessmentScreen drives QuestionView: the parent owns the
  /// answers map, `onSetAnswer` writes into it, `onSubmitMultiselect`
  /// validates and advances.
  Widget harness({
    required Map<String, dynamic> answers,
    VoidCallback? onAdvance,
    dynamic existing,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: QuestionView(
          question: foodPreferencesQuestion,
          questionIndex: 5,
          totalQuestions: 16,
          existingAnswer: existing,
          onBack: () {},
          onAnswerAndAdvance: (f, v) async => answers[f] = v,
          onSubmitText: (q, raw) async => null,
          onSubmitMultiselect: (field) async {
            onAdvance?.call();
            return null; // null == accepted
          },
          onSetAnswer: (field, value) => answers[field] = value,
        ),
      ),
    );
  }

  group('the question is actually shown to the athlete', () {
    testWidgets('prompt and helper text render', (tester) async {
      await tester.pumpWidget(harness(answers: {}));
      expect(find.textContaining('What foods do you enjoy'), findsOneWidget);
      // The widget renders its own 'Select all that apply' label too, so
      // this asserts the question's specific helper sentence.
      expect(find.textContaining('personalize recipe and creator'), findsOneWidget);
    });

    testWidgets('the food options are on screen', (tester) async {
      await tester.pumpWidget(harness(answers: {}));
      expect(find.text('Pizza'), findsOneWidget);
      expect(find.text('Burger'), findsOneWidget);
      expect(find.text('Sandwich'), findsOneWidget);
    });
  });

  group('multi-select behaviour', () {
    testWidgets('selecting one food records its STABLE id, not the label', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(harness(answers: answers));

      await tester.tap(find.text('Pizza'));
      await tester.pump();
      // The chip toggles local state; the answer is committed on Continue —
      // this drives the REAL flow rather than a per-tap callback.
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();

      expect(answers['favorite_foods'], contains('pizza'));
      expect(answers['favorite_foods'], isNot(contains('Pizza')));
      expect(answers['favorite_foods'], isNot(contains('🍕')));
    });

    testWidgets('MULTIPLE foods can be selected together', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(harness(answers: answers));

      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.tap(find.text('Burger'));
      await tester.pump();
      await tester.tap(find.text('Sandwich'));
      await tester.pump();
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();

      final selected = (answers['favorite_foods'] as List).cast<String>();
      expect(selected, containsAll(['pizza', 'burger', 'sandwich']));
      expect(selected.length, 3);
    });

    testWidgets('tapping a selected food again DESELECTS it', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(harness(answers: answers));

      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.tap(find.text('Burger'));
      await tester.pump();

      await tester.tap(find.text('Pizza'));   // tap again = deselect
      await tester.pump();
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();

      final selected = (answers['favorite_foods'] as List).cast<String>();
      expect(selected, isNot(contains('pizza')));
      expect(selected, contains('burger'), reason: 'deselecting one must not clear the others');
    });

    testWidgets('a regional option records its snake_case id', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(harness(answers: answers));
      await tester.tap(find.text('North Indian'));
      await tester.pump();
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();
      expect(answers['favorite_foods'], contains('north_indian'));
    });
  });

  group('empty selection is valid — this is a preference, not a requirement', () {
    testWidgets('the athlete can continue without choosing anything', (tester) async {
      var advanced = false;
      await tester.pumpWidget(harness(answers: {}, onAdvance: () => advanced = true));

      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();

      expect(advanced, isTrue, reason: 'an empty food preference must not block the assessment');
    });
  });

  group('re-taking the assessment', () {
    testWidgets('previously chosen foods are restored as selected', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(harness(
        answers: answers,
        existing: const ['pizza', 'burger'],
      ));
      await tester.pump();

      // Toggling a THIRD food must extend the restored set, not replace it —
      // which is what makes editing preferences work rather than starting over.
      await tester.tap(find.text('Sandwich'));
      await tester.pump();
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();

      final selected = (answers['favorite_foods'] as List).cast<String>();
      expect(selected, containsAll(['pizza', 'burger', 'sandwich']));
    });

    testWidgets('a previously chosen food can be removed on a re-take', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(harness(
        answers: answers,
        existing: const ['pizza', 'burger'],
      ));
      await tester.pump();

      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();

      final selected = (answers['favorite_foods'] as List).cast<String>();
      expect(selected, isNot(contains('pizza')));
      expect(selected, contains('burger'));
    });
  });

  group('existing assessment questions are unaffected', () {
    testWidgets('the supplements multiselect still works the same way', (tester) async {
      final answers = <String, dynamic>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionView(
              question: supplementQuestion,
              questionIndex: 6,
              totalQuestions: 16,
              existingAnswer: null,
              onBack: () {},
              onAnswerAndAdvance: (f, v) async => answers[f] = v,
              onSubmitText: (q, raw) async => null,
              onSubmitMultiselect: (field) async => null,
              onSetAnswer: (field, value) => answers[field] = value,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Creatine'));
      await tester.pump();
      await tester.tap(find.text('Continue →'));
      await tester.pumpAndSettle();
      expect(answers['supplements_used'], contains('Creatine'));
    });
  });
}
