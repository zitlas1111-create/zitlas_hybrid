import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/core/storage/local_storage_service.dart';
import 'package:zitlas_mobile/features/rest_timer/data/rest_timer_notification_service.dart';
import 'package:zitlas_mobile/features/rest_timer/models/rest_timer_state.dart';
import 'package:zitlas_mobile/features/rest_timer/rest_timer_controller.dart';

/// No platform channel calls at all — every real
/// [RestTimerNotificationService] call touches `flutter_local_notifications`
/// / `flutter_timezone` plugin channels that plain `flutter_test` does not
/// mock. Overriding rather than mocking a channel keeps these tests focused
/// on the ENGINE (end-time math, persistence, single-timer enforcement),
/// which is the actual safety-critical logic — the notification plumbing
/// itself is exercised by reading the real service's source, not by a test
/// double pretending a platform channel exists.
class _NoopNotifications extends RestTimerNotificationService {
  int scheduleCalls = 0;
  int cancelCalls = 0;

  @override
  Future<void> scheduleCompletion(DateTime endTime) async {
    scheduleCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStorageService storage;
  late _MutableClock clock;
  late _NoopNotifications notifications;

  RestTimerController build() => RestTimerController.debug(
        storage: storage,
        notifications: notifications,
        clock: () => clock.now,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await LocalStorageService.init();
    clock = _MutableClock(DateTime(2026, 1, 1, 12, 0, 0));
    notifications = _NoopNotifications();
  });

  group('idle state and duration selection', () {
    test('defaults to 5:00 idle', () {
      final c = build();
      expect(c.status, RestTimerStatus.idle);
      expect(c.durationSeconds, 300);
      expect(c.remainingSeconds, 300);
      expect(c.progress, 1.0);
    });

    test('setDuration clamps to the 1-20 minute range', () {
      final c = build();
      c.setDuration(30); // below 1 min
      expect(c.durationSeconds, 60);
      c.setDuration(999999); // above 20 min
      expect(c.durationSeconds, 1200);
      c.setDuration(600);
      expect(c.durationSeconds, 600);
    });

    test('setDuration is a no-op while a timer is active (spec: cannot resize a running timer)', () async {
      final c = build();
      c.setDuration(120);
      await c.start();
      c.setDuration(600); // must be ignored
      expect(c.durationSeconds, 120);
      await c.pause();
      c.setDuration(600); // still ignored while paused
      expect(c.durationSeconds, 120);
    });
  });

  group('end-time-based countdown (TEST: no drift)', () {
    test('remainingSeconds is derived from endEpochMs, not decremented', () async {
      final c = build();
      c.setDuration(300);
      await c.start();
      expect(c.remainingSeconds, 300);

      clock.advance(const Duration(seconds: 42));
      // No ticker involved in this assertion — proves the getter itself is
      // timestamp-derived, exactly per spec §13.
      expect(c.remainingSeconds, 258);

      clock.advance(const Duration(minutes: 3, seconds: 38)); // total 260s elapsed
      expect(c.remainingSeconds, 40);
    });

    test('a huge, unrealistic gap (simulating the app being dead for hours) still resolves correctly', () async {
      final c = build();
      c.setDuration(60);
      await c.start();
      clock.advance(const Duration(hours: 6));
      // Must clamp to 0, never go negative or wrap.
      expect(c.remainingSeconds, 0);
    });
  });

  group('pause / resume accuracy (TEST 4)', () {
    test('pausing freezes remaining time exactly, even across a long real-world wait', () async {
      final c = build();
      c.setDuration(300);
      await c.start();
      clock.advance(const Duration(seconds: 78)); // 5:00 -> 3:42
      expect(c.remainingSeconds, 222); // 03:42

      await c.pause();
      expect(c.status, RestTimerStatus.paused);
      expect(c.remainingSeconds, 222);

      // "wait 2 minutes while paused" — spec is explicit that this must NOT
      // change the displayed time.
      clock.advance(const Duration(minutes: 2));
      expect(c.remainingSeconds, 222);
      expect(c.status, RestTimerStatus.paused);
    });

    test('resume continues from the frozen value, not from re-adding paused time', () async {
      final c = build();
      c.setDuration(300);
      await c.start();
      clock.advance(const Duration(seconds: 78));
      await c.pause();
      clock.advance(const Duration(minutes: 5)); // long pause
      await c.resume();

      expect(c.status, RestTimerStatus.running);
      expect(c.remainingSeconds, 222); // still 03:42 the instant resume fires

      clock.advance(const Duration(seconds: 1));
      expect(c.remainingSeconds, 221); // ticks down normally afterwards
    });

    test('pause cancels the scheduled notification; resume reschedules it', () async {
      final c = build();
      await c.start();
      expect(notifications.scheduleCalls, 1);
      await c.pause();
      expect(notifications.cancelCalls, 1);
      await c.resume();
      expect(notifications.scheduleCalls, 2);
    });
  });

  group('reset (TEST 5)', () {
    test('reset returns to idle at the selected duration and does not auto-start', () async {
      final c = build();
      c.setDuration(180);
      await c.start();
      clock.advance(const Duration(seconds: 60));
      await c.reset();

      expect(c.status, RestTimerStatus.idle);
      expect(c.durationSeconds, 180);
      expect(c.remainingSeconds, 180);
      expect(notifications.cancelCalls, greaterThanOrEqualTo(1));
    });

    test('reset from paused also returns cleanly to idle', () async {
      final c = build();
      c.setDuration(90);
      await c.start();
      await c.pause();
      await c.reset();
      expect(c.status, RestTimerStatus.idle);
      expect(c.remainingSeconds, 90);
    });
  });

  group('completion enters ALARMING, not completed directly (spec §1/§5)', () {
    test('reaching zero flips to alarming (not completed), full ring, alarm active', () async {
      final c = build();
      c.setDuration(60);
      await c.start();
      clock.advance(const Duration(seconds: 60));

      // Simulates the controller's own periodic tick discovering expiry
      // while the app is alive (the production path taken by the real
      // Timer.periodic).
      await c.debugTick();

      expect(c.status, RestTimerStatus.alarming);
      expect(c.isAlarming, isTrue);
      expect(c.remainingSeconds, 0);
      expect(c.progress, 1.0);
      expect(c.debugAlarmActive, isTrue);
      // The pending system notification must be cancelled once the in-app
      // alarm is showing — no redundant duplicate alert.
      expect(notifications.cancelCalls, greaterThanOrEqualTo(1));
      // Must NOT auto-resolve to completed on its own — only Stop Alarm does.
      expect(c.status, isNot(RestTimerStatus.completed));
    });

    test('stopAlarm moves ALARMING -> COMPLETED and turns the alarm off', () async {
      final c = build();
      c.setDuration(60);
      await c.start();
      clock.advance(const Duration(seconds: 60));
      await c.debugTick();
      expect(c.status, RestTimerStatus.alarming);
      expect(c.debugAlarmActive, isTrue);

      await c.stopAlarm();

      expect(c.status, RestTimerStatus.completed);
      expect(c.debugAlarmActive, isFalse);
      expect(c.remainingSeconds, 0);
      expect(c.progress, 1.0);
    });

    test('stopAlarm is a no-op when not actually alarming', () async {
      final c = build();
      await c.stopAlarm(); // idle — must not throw or change anything
      expect(c.status, RestTimerStatus.idle);

      c.setDuration(60);
      await c.start();
      await c.stopAlarm(); // running, not yet alarming — must not skip ahead
      expect(c.status, RestTimerStatus.running);
    });

    test('start again is only available AFTER stopAlarm, and begins a fresh full-duration countdown', () async {
      final c = build();
      c.setDuration(60);
      await c.start();
      clock.advance(const Duration(seconds: 60));
      await c.debugTick();
      expect(c.status, RestTimerStatus.alarming);

      // Start is a no-op while alarming — hasActiveTimer covers it, same as
      // running/paused (spec §30 applied to the ringing phase too).
      await c.start();
      expect(c.status, RestTimerStatus.alarming);

      await c.stopAlarm();
      await c.start();
      expect(c.status, RestTimerStatus.running);
      expect(c.remainingSeconds, 60);
    });

    test('a completion discovered retroactively (app was dead) resolves straight to completed, silently', () async {
      // This exercises init()'s reconciliation path directly, which is the
      // ONLY place a "the app was closed when it expired" completion is
      // discovered — see RestTimerController.init's doc for why that path
      // must resolve silently (the real alert already fired via the OS
      // notification at the real time, and no AudioPlayer survived process
      // death to loop anything).
      final c = build();
      c.setDuration(60);
      await c.start();
      final scheduledAfterStart = notifications.scheduleCalls;
      clock.advance(const Duration(seconds: 120)); // well past expiry

      final fresh = RestTimerController.debug(
        storage: storage,
        notifications: notifications,
        clock: () => clock.now,
      );
      await fresh.init();

      expect(fresh.status, RestTimerStatus.completed);
      expect(fresh.debugAlarmActive, isFalse);
      // No NEW schedule call from the reconciliation path — a silently
      // resolved retroactive completion has nothing left to alert about.
      expect(notifications.scheduleCalls, scheduledAfterStart);
    });

    test('a persisted ALARMING snapshot found on cold boot also resolves to completed, silently', () async {
      // Simulates: the process was killed WHILE ringing. There is no
      // AudioPlayer left to loop on relaunch, so this must not attempt to
      // resume the alarm — same silence rationale as the expired-running
      // case above.
      await storage.setJson('zitlas_rest_timer', const RestTimerSnapshot(
        durationSeconds: 60,
        status: RestTimerStatus.alarming,
      ).toJson());

      final fresh = RestTimerController.debug(
        storage: storage,
        notifications: notifications,
        clock: () => clock.now,
      );
      await fresh.init();

      expect(fresh.status, RestTimerStatus.completed);
      expect(fresh.debugAlarmActive, isFalse);
      expect(notifications.scheduleCalls, 0);
    });

    test('a completion discovered on RESUME (process alive, backgrounded) DOES start ringing', () async {
      // Different from the cold-boot case above: the process was alive the
      // whole time it was backgrounded (just not ticking, e.g. a throttled
      // Timer), so — per the controller's own doc on this — it must ring
      // now, not resolve silently. This is TEST 2/TEST 9's "background"
      // scenario at the engine level.
      final c = build();
      c.setDuration(60);
      await c.start();
      clock.advance(const Duration(seconds: 90)); // already past expiry

      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(c.status, RestTimerStatus.alarming);
      expect(c.debugAlarmActive, isTrue);
    });
  });

  group('single active timer (TEST 11)', () {
    test('calling start while already running does not create a second countdown', () async {
      final c = build();
      c.setDuration(300);
      await c.start();
      final callsAfterFirstStart = notifications.scheduleCalls;

      await c.start(); // attempted second start
      expect(c.durationSeconds, 300);
      expect(notifications.scheduleCalls, callsAfterFirstStart); // no re-schedule
      expect(c.status, RestTimerStatus.running);
    });

    test('hasActiveTimer is true exactly while running, paused, or alarming', () async {
      final c = build();
      expect(c.hasActiveTimer, isFalse);
      await c.start();
      expect(c.hasActiveTimer, isTrue);
      await c.pause();
      expect(c.hasActiveTimer, isTrue);
      await c.resume();
      clock.advance(const Duration(minutes: 10));
      await c.debugTick();
      expect(c.status, RestTimerStatus.alarming);
      expect(c.hasActiveTimer, isTrue);
      await c.stopAlarm();
      expect(c.hasActiveTimer, isFalse);
    });

    test('reset defensively silences an active alarm (spec §3: must never survive a reset)', () async {
      final c = build();
      c.setDuration(60);
      await c.start();
      clock.advance(const Duration(seconds: 60));
      await c.debugTick();
      expect(c.debugAlarmActive, isTrue);

      await c.reset();

      expect(c.debugAlarmActive, isFalse);
      expect(c.status, RestTimerStatus.idle);
    });
  });

  group('pause/resume across completion (TEST 5)', () {
    test('no alarm while paused; resuming and letting it expire still rings normally', () async {
      final c = build();
      c.setDuration(60);
      await c.start();
      await c.pause();
      expect(c.debugAlarmActive, isFalse);
      expect(c.status, RestTimerStatus.paused);

      await c.resume();
      clock.advance(const Duration(seconds: 60));
      await c.debugTick();

      expect(c.status, RestTimerStatus.alarming);
      expect(c.debugAlarmActive, isTrue);
    });
  });

  group('persistence (TEST 6 / TEST 7 underpinning)', () {
    test('a running timer survives being reconstructed (simulating app relaunch)', () async {
      final c = build();
      c.setDuration(300);
      await c.start();
      clock.advance(const Duration(seconds: 100));

      // A brand-new controller reading the SAME persisted storage — this is
      // exactly what happens across "leave the timer screen and return" or
      // "kill and reopen the app": the singleton is gone, but the snapshot
      // on disk is not.
      final reloaded = RestTimerController.debug(
        storage: storage,
        notifications: notifications,
        clock: () => clock.now,
      );
      await reloaded.init();

      expect(reloaded.status, RestTimerStatus.running);
      expect(reloaded.remainingSeconds, 200);
    });

    test('a paused timer survives reconstruction at its exact frozen value', () async {
      final c = build();
      c.setDuration(300);
      await c.start();
      clock.advance(const Duration(seconds: 78));
      await c.pause();

      final reloaded = RestTimerController.debug(
        storage: storage,
        notifications: notifications,
        clock: () => clock.now,
      );
      await reloaded.init();

      expect(reloaded.status, RestTimerStatus.paused);
      expect(reloaded.remainingSeconds, 222);
    });
  });

  group('RestTimerSnapshot JSON round-trip', () {
    test('idle snapshot', () {
      final s = RestTimerSnapshot.idle(300);
      final back = RestTimerSnapshot.fromJson(s.toJson());
      expect(back.status, RestTimerStatus.idle);
      expect(back.durationSeconds, 300);
      expect(back.endEpochMs, isNull);
    });

    test('running snapshot preserves endEpochMs', () {
      const s = RestTimerSnapshot(
        durationSeconds: 300,
        status: RestTimerStatus.running,
        endEpochMs: 1234567890,
      );
      final back = RestTimerSnapshot.fromJson(s.toJson());
      expect(back.status, RestTimerStatus.running);
      expect(back.endEpochMs, 1234567890);
    });

    test('malformed status string falls back to idle rather than throwing', () {
      final back = RestTimerSnapshot.fromJson({'durationSeconds': 300, 'status': 'not_a_real_status'});
      expect(back.status, RestTimerStatus.idle);
    });
  });
}

/// A settable "now" for deterministic end-time math — no real `Timer` or
/// wall-clock waiting anywhere in this file.
class _MutableClock {
  _MutableClock(this.now);
  DateTime now;
  void advance(Duration d) => now = now.add(d);
}
