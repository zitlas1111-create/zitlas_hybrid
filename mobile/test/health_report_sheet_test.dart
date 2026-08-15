import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/dashboard/dashboard_controller.dart';
import 'package:zitlas_mobile/features/dashboard/data/dashboard_repository.dart';
import 'package:zitlas_mobile/features/dashboard/models/health_status.dart';
import 'package:zitlas_mobile/features/dashboard/presentation/widgets/health_report_sheet.dart';

/// End-to-end proof for the reported bug: "after tapping a wellness status,
/// the follow-up options cannot reliably be selected." Pumps the REAL
/// `showHealthReportSheet` flow — not a hand-built stand-in — against a
/// real `DashboardController` backed by a fake Firestore, and drives actual
/// taps through the actual widget tree (`tester.tap`, not calling a
/// callback directly), the only way to catch a real hit-testing/gesture
/// defect if one exists.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  late DashboardController controller;

  Widget harness() {
    return ChangeNotifierProvider<DashboardController>.value(
      value: controller,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showHealthReportSheet(
                context,
                controller,
                const HealthStatusOption('unwell', '😐 Slightly Unwell'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    controller = DashboardController(uid: 'athlete-1', repository: DashboardRepository(FakeFirebaseFirestore()));
  });

  tearDown(() => controller.dispose());

  group('symptom chips (the "unwell/sick/other" follow-up flow)', () {
    testWidgets('a symptom chip actually toggles selected when tapped', (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Fatigue'), findsOneWidget, reason: 'the symptom chip must actually be on screen and hit-testable');

      await tester.tap(find.text('Fatigue'));
      await tester.pump();

      // A selected chip renders with FontWeight.w800 (see _MultiChips) — the
      // only observable proof from the test side that the tap registered
      // and setState actually ran.
      final fatigueText = tester.widget<Text>(find.text('Fatigue'));
      expect(fatigueText.style?.fontWeight, FontWeight.w800);
    });

    testWidgets('multiple symptom chips can be selected independently, one tap does not clear another', (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fatigue'));
      await tester.pump();
      await tester.tap(find.text('Headache'));
      await tester.pump();

      expect(tester.widget<Text>(find.text('Fatigue')).style?.fontWeight, FontWeight.w800);
      expect(tester.widget<Text>(find.text('Headache')).style?.fontWeight, FontWeight.w800);
    });

    testWidgets('a severity button is selectable and updates the draft', (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Moderate'));
      await tester.pump();

      final moderateText = tester.widget<Text>(find.text('Moderate'));
      expect(moderateText.style?.fontWeight, FontWeight.w800);
    });

    testWidgets('tapping "Update Today\'s Plan" after selecting a symptom actually submits — loading then success', (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fatigue'));
      await tester.pump();

      // The sheet's default test-window height (600px) is shorter than its
      // scrollable content — a real device just scrolls; the test does the
      // same explicitly rather than tapping through the viewport edge.
      await tester.ensureVisible(find.text('Update Today’s Plan'));
      await tester.tap(find.text('Update Today’s Plan'));
      // Immediately after the tap, the button shows its loading spinner.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Let the async submit (Firestore + SharedPreferences writes) resolve.
      await tester.pumpAndSettle();

      // Sheet closes and a confirmation SnackBar appears — the "no
      // confirmation" half of the bug report.
      expect(find.text('Update Today’s Plan'), findsNothing, reason: 'sheet should have closed on success');
      expect(find.textContaining('adjusted'), findsOneWidget);

      // And the adjustment is REALLY persisted — not just a UI illusion.
      expect(controller.healthToday, isNotNull);
      expect(controller.healthToday!.status, 'unwell');
      expect(controller.healthToday!.symptoms, contains('Fatigue'));
    });
  });

  group('injured flow — body part chips + pain slider', () {
    Widget injuredHarness() {
      return ChangeNotifierProvider<DashboardController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showHealthReportSheet(
                  context,
                  controller,
                  const HealthStatusOption('injured', '🤕 Injured'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a body-part chip is selectable', (tester) async {
      await tester.pumpWidget(injuredHarness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Knee'));
      await tester.pump();
      expect(tester.widget<Text>(find.text('Knee')).style?.fontWeight, FontWeight.w800);
    });

    testWidgets('submitting an injured report with a body part actually adjusts the plan', (tester) async {
      await tester.pumpWidget(injuredHarness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Knee'));
      await tester.pump();
      await tester.ensureVisible(find.text('Update Today’s Plan'));
      await tester.tap(find.text('Update Today’s Plan'));
      await tester.pumpAndSettle();

      expect(controller.healthToday, isNotNull);
      expect(controller.healthToday!.bodyParts, contains('Knee'));
      expect(controller.healthToday!.workout?.mode, 'modified');
    });
  });

  group('"Feeling Great" — submits immediately, no sheet at all', () {
    testWidgets('tapping it directly submits and shows a confirmation, matching the website\'s no-sheet behavior', (tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<DashboardController>.value(
          value: controller,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showHealthReportSheet(
                    context,
                    controller,
                    const HealthStatusOption('great', '😊 Feeling Great'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Update Today’s Plan'), findsNothing, reason: 'no follow-up sheet for "great"');
      expect(find.textContaining('normal'), findsOneWidget);
      expect(controller.healthToday, isNull, reason: '"great" clears any override rather than storing one');
    });
  });
}
