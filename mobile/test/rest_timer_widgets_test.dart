import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';
import 'package:zitlas_mobile/features/rest_timer/presentation/widgets/rest_timer_card.dart';
import 'package:zitlas_mobile/features/rest_timer/rest_timer_controller.dart';

/// Widget-level smoke tests for the Rest Timer's actual rendered UI (TEST 10
/// and the "digits must never be clipped" / "no overflow" requirements of
/// §33). The engine correctness itself (drift, pause/resume math,
/// persistence) is covered by `rest_timer_controller_test.dart` with a fake
/// clock and no real Timer — this file instead exercises the REAL
/// `RestTimerController.instance` singleton through the widgets that
/// actually read it (`RestTimerCard`, and — reached by tapping the card —
/// `RestTimerScreen`), the same object graph the app itself uses.
///
/// `RestTimerController.instance` is a process-lifetime singleton (by
/// design — see its class doc), so it is explicitly reset before every test
/// here rather than reconstructed, to stop state leaking between cases in
/// this file.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await LocalStorageService.init();
    await RestTimerController.instance.init();
  });

  setUp(() async {
    await RestTimerController.instance.reset();
    RestTimerController.instance.setDuration(300);
  });

  // `RestTimerWatchFace` runs its breathing-glow `AnimationController` on an
  // infinite `repeat()` for as long as the screen is mounted (by design — it
  // is what makes the dial feel "alive" at rest, not just while counting
  // down), and a real countdown keeps its own `Timer.periodic` alive too.
  // BOTH mean `pumpAndSettle()` can never return while `RestTimerScreen` is
  // on screen or a countdown is active — this file uses bounded `pump()`
  // calls instead wherever that applies. This teardown guarantees no test's
  // ticker survives into the next one (the controller is a real
  // process-lifetime singleton, not recreated per test).
  tearDown(() async {
    await RestTimerController.instance.reset();
  });

  /// Pumps in small, bounded steps until [finder] resolves or [timeout] is
  /// exhausted — used ONLY around a `MaterialPageRoute` push/pop, never
  /// while a countdown or the watch face's breathing glow might be running
  /// (both are infinite tickers `pumpAndSettle()` cannot get past; see the
  /// `tearDown` comment above). A single fixed `pump(Duration(milliseconds:
  /// 300))` — exactly the default route-transition duration — proved
  /// inconsistent depending on which tests ran earlier in the same file
  /// (frame-quantization against that exact boundary, not a source bug:
  /// the same navigation is exercised directly, with no such polling, by
  /// `rest_timer_controller_test.dart`'s deterministic engine tests).
  /// Polling in 50ms steps sidesteps the boundary entirely under
  /// `flutter_test`'s `FakeAsync`, with no real wall-clock wait.
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder, {String? because}) async {
    for (var i = 0; i < 20; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Timed out waiting for ${because ?? finder} to appear after a route transition.');
  }

  Widget wrap(Size size) {
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: const MaterialApp(
        home: Scaffold(body: Padding(padding: EdgeInsets.all(12), child: RestTimerCard())),
      ),
    );
  }

  group('RestTimerCard', () {
    testWidgets('idle state shows the selected duration and "Tap to set"', (tester) async {
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();

      expect(find.text('Rest Timer'), findsOneWidget);
      expect(find.text('Tap to set'), findsOneWidget);
      expect(find.text('05:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without overflow on a small phone width', (tester) async {
      // A common small-Android baseline (spec §33: "must work on small
      // Android phones ... never clipped").
      await tester.pumpWidget(wrap(const Size(320, 568)));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without overflow on a large phone width', (tester) async {
      await tester.pumpWidget(wrap(const Size(430, 932)));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('full flow via the actual widgets (TEST 10 — Training integration)', () {
    testWidgets('Training card -> Timer screen -> Start -> Pause -> Resume -> Reset -> back to card', (tester) async {
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();

      // Training Day card: tap opens the dedicated screen. Tapping the
      // chevron (a leaf) rather than `find.byType(RestTimerCard)` — hit-
      // testing the outer composing StatelessWidget directly proved
      // unreliable through this much Semantics/Material/InkWell nesting,
      // even though the element genuinely exists in the tree; the icon is
      // an unambiguous, always-correctly-positioned tap target within the
      // same InkWell. `pump(duration)` rather than `pumpAndSettle()` — see
      // the file-level comment on `tearDown` above for why settling never
      // completes on this screen.
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntilFound(tester, find.text('REST TIMER'), because: 'the Rest Timer screen header');
      expect(tester.takeException(), isNull);

      expect(find.text('REST TIMER'), findsOneWidget);
      expect(find.text('Choose Duration'), findsOneWidget);
      // The idle watch face shows the full selected duration and a READY
      // status label — accessibility §34: state is TEXT, not only color.
      expect(find.text('05:00'), findsWidgets);
      expect(find.text('READY'), findsOneWidget);

      // Start.
      await tester.tap(find.widgetWithText(ElevatedButton, 'START'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'PAUSE'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Reset'), findsOneWidget);
      // Duration chips are hidden once a countdown is in flight — nothing to
      // pick mid-countdown (spec: no "resize a running timer").
      expect(find.text('Choose Duration'), findsNothing);

      // Pause.
      await tester.tap(find.widgetWithText(ElevatedButton, 'PAUSE'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'RESUME'), findsOneWidget);

      // Resume.
      await tester.tap(find.widgetWithText(ElevatedButton, 'RESUME'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('RUNNING'), findsOneWidget);

      // Reset -> back to idle, duration selector reappears.
      await tester.tap(find.widgetWithText(OutlinedButton, 'Reset'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('READY'), findsOneWidget);
      expect(find.text('Choose Duration'), findsOneWidget);

      // Back out to the Training card — it must reflect the (now idle) state
      // live, since both widgets watch the SAME singleton.
      await tester.pageBack();
      await pumpUntilFound(tester, find.text('Tap to set'), because: 'the Training card after popping back');
      expect(tester.takeException(), isNull);
      expect(find.text('Tap to set'), findsOneWidget);
    });

    testWidgets('duration chips select a preset and the watch reflects it', (tester) async {
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntilFound(tester, find.text('Choose Duration'), because: 'the duration selector');

      // "10" preset chip (600s = 10:00).
      await tester.tap(find.text('10'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('10:00'), findsWidgets);
    });

    testWidgets('the Training card live-updates while a timer from elsewhere is running', (tester) async {
      // Simulates "the countdown was started on the Timer screen, and the
      // Training card (a different widget instance, same singleton) must
      // show it" — without even opening the Timer screen in THIS pump.
      await RestTimerController.instance.start();
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();

      expect(find.text('Rest Timer'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('05:00'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // `testWidgets` runs each test body inside its own `FakeAsync` zone,
      // and the global `tearDown()` hook runs OUTSIDE that zone once it has
      // already unwound — too late for Flutter's own "no pending Timer"
      // invariant check, which runs before `tearDown`. The periodic
      // `Timer` started above must therefore be cancelled from INSIDE this
      // test body, not left to the shared teardown (kept as a belt-and-
      // suspenders reset for state other than the ticker).
      await RestTimerController.instance.reset();
    });
  });

  // These exercise the REAL `RestTimerController.instance` singleton and real
  // widgets, but reach ALARMING via `debugForceAlarming()` rather than by
  // waiting out a real countdown: `RestTimerController.instance` has no
  // injectable clock, so `tester.pump(Duration(seconds: 61))` fires the real
  // `Timer.periodic` under `FakeAsync` without ever advancing
  // `DateTime.now()`, and the completion check never trips. The time-based
  // trigger is exhaustively covered by `rest_timer_controller_test.dart`'s
  // fake-clock tests; this group proves what the actual UI does once ALARMING
  // is reached.
  group('persistent alarm (TEST 1) — real widgets reacting to ALARMING', () {
    testWidgets('reaching zero shows the alarm UI with Stop Alarm, not Start Again', (tester) async {
      RestTimerController.instance.setDuration(60);
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntilFound(tester, find.text('START'), because: 'the Start button');

      await tester.tap(find.widgetWithText(ElevatedButton, 'START'));
      await tester.pump();
      expect(find.text('RUNNING'), findsOneWidget);

      // Forces entry into ALARMING without waiting on real time.
      // `RestTimerController.instance` has no injectable clock, so
      // `FakeAsync.elapse()` (what `tester.pump(duration)` drives) fires the
      // real `Timer.periodic` but `DateTime.now()` never actually advances —
      // the time-based trigger condition is exhaustively covered by
      // `rest_timer_controller_test.dart`'s fake-clock tests instead. This
      // file exists to prove the real widgets react correctly once that
      // condition is met, which `debugForceAlarming()` reaches directly.
      await RestTimerController.instance.debugForceAlarming();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('REST COMPLETE'), findsWidgets); // watch face + card-style label
      expect(find.text('Your rest period is over.'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'STOP ALARM'), findsOneWidget);
      // Must NOT show Start Again yet — that only appears after Stop Alarm.
      expect(find.widgetWithText(ElevatedButton, 'START AGAIN'), findsNothing);

      await RestTimerController.instance.reset(); // silence the alarm before the test ends
    });

    testWidgets('Stop Alarm silences it and reveals Start Again; Training card reflects both phases', (tester) async {
      RestTimerController.instance.setDuration(60);
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntilFound(tester, find.text('START'), because: 'the Start button');
      await tester.tap(find.widgetWithText(ElevatedButton, 'START'));
      await tester.pump();
      await RestTimerController.instance.debugForceAlarming();
      await tester.pump();
      expect(find.widgetWithText(ElevatedButton, 'STOP ALARM'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'STOP ALARM'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(ElevatedButton, 'STOP ALARM'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'START AGAIN'), findsOneWidget);
      expect(find.text('Your rest period is over.'), findsNothing);

      // Back to the Training card: completed state, not the "ALARM RINGING"
      // wording — the alarm was already stopped.
      await tester.pageBack();
      await pumpUntilFound(tester, find.text('Rest Complete'), because: 'the completed Training card');
      expect(find.text('Rest Complete'), findsOneWidget);
      expect(find.text('Start again'), findsOneWidget);
      expect(find.text('ALARM RINGING'), findsNothing);
    });

    testWidgets('Training card shows "ALARM RINGING" while ringing, reachable without opening the screen', (tester) async {
      RestTimerController.instance.setDuration(60);
      await RestTimerController.instance.start();

      // Forces completion with ONLY the Training card mounted — no Rest
      // Timer screen open at all, proving the alarm triggers from the
      // singleton itself, not from the screen's presence.
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await RestTimerController.instance.debugForceAlarming();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Rest Timer'), findsOneWidget);
      expect(find.text('REST COMPLETE'), findsOneWidget);
      expect(find.text('ALARM RINGING'), findsOneWidget);

      // Tapping it must still open the timer/alarm screen (spec §14).
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntilFound(tester, find.widgetWithText(ElevatedButton, 'STOP ALARM'), because: 'the Stop Alarm button');
      expect(find.widgetWithText(ElevatedButton, 'STOP ALARM'), findsOneWidget);

      await RestTimerController.instance.reset();
    });

    testWidgets('only ONE alarm cycle starts even if the screen rebuilds while ringing', (tester) async {
      // Duplicate-alarm protection (TEST 4 / spec §11-12) at the widget
      // level: multiple rebuilds of the SAME alarming state (forced here by
      // repeatedly nudging the frame) must not multiply anything the UI
      // would expose as duplicated controls.
      RestTimerController.instance.setDuration(60);
      await tester.pumpWidget(wrap(const Size(390, 844)));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await pumpUntilFound(tester, find.text('START'), because: 'the Start button');
      await tester.tap(find.widgetWithText(ElevatedButton, 'START'));
      await tester.pump();
      await RestTimerController.instance.debugForceAlarming();
      await tester.pump();

      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(ElevatedButton, 'STOP ALARM'), findsOneWidget);
      expect(RestTimerController.instance.debugAlarmActive, isTrue);

      await RestTimerController.instance.reset();
    });
  });
}
