import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/app/splash_gate.dart';

/// The gate used to hold the app on a branded splash for a 1200ms MINIMUM.
/// That custom startup screen has been removed, so the hold went with it —
/// [SplashGate.minimumDuration] is now zero and the gate opens on the next
/// event-loop turn.
///
/// What still matters, and is pinned below: the gate must open on its own
/// (never strand the app), it must open only AFTER the current turn (a
/// cold-start notification deep link waits on this so the router exists
/// first), and it must notify exactly once.
void main() {
  setUp(() => SplashGate.instance.resetForTest());
  tearDown(() => SplashGate.instance.resetForTest());

  test('the artificial hold is GONE — minimumDuration is zero', () {
    // Guards the regression directly: any non-zero value here reintroduces a
    // startup screen the user has to sit through.
    expect(SplashGate.minimumDuration, Duration.zero);
  });

  test('is not ready in the SAME turn as start() — the first frame still gets up', () {
    SplashGate.instance.start();
    expect(SplashGate.instance.isReady, isFalse,
        reason: 'app.dart defers a cold-start notification until after this');
  });

  test('opens on the next event-loop turn, and notifies exactly once', () {
    fakeAsync((elapse) {
      var notified = 0;
      SplashGate.instance.addListener(() => notified++);
      SplashGate.instance.start();

      elapse(Duration.zero);
      expect(SplashGate.instance.isReady, isTrue, reason: 'no waiting any more');
      // Exactly one notification — the router must not be re-triggered
      // repeatedly by the gate.
      expect(notified, 1);
    });
  });

  test('start() is idempotent — a second call cannot re-hold or stack timers', () {
    fakeAsync((elapse) {
      SplashGate.instance.start();
      SplashGate.instance.start(); // e.g. a hot restart
      elapse(Duration.zero);
      expect(SplashGate.instance.isReady, isTrue);
    });
  });

  test('a call AFTER the gate opened cannot close it again', () {
    fakeAsync((elapse) {
      SplashGate.instance.start();
      elapse(Duration.zero);
      SplashGate.instance.start();
      expect(SplashGate.instance.isReady, isTrue,
          reason: 'reopening the startup gate would re-show the holding frame');
    });
  });

  test('reading isReady self-starts the clock, so the app can never be stranded '
      'on the holding frame when start() was never called', () {
    fakeAsync((elapse) {
      // Deliberately do NOT call start() — mimics an entry path that skips main().
      expect(SplashGate.instance.isReady, isFalse);
      elapse(Duration.zero);
      expect(SplashGate.instance.isReady, isTrue);
    });
  });

  test('forceReadyForTest releases immediately', () {
    SplashGate.instance.forceReadyForTest();
    expect(SplashGate.instance.isReady, isTrue);
  });
}

/// Minimal fake-async helper so these tests don't wait in real time.
void fakeAsync(void Function(void Function(Duration) elapse) body) {
  FakeAsync().run((async) {
    body(async.elapse);
  });
}
