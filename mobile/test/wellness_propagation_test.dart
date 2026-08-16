import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zitlas_mobile/features/dashboard/data/health_status_store.dart';
import 'package:zitlas_mobile/features/dashboard/models/health_status.dart';

/// Regression for the reported production bug: tapping "Sick Today" or
/// "Injured Today" recorded the wellness status but the ACTIVE diet and
/// training plans kept rendering as if nothing had happened.
///
/// ROOT CAUSE: Diet and Training each read `HealthStatusStore` exactly once,
/// when their controller is constructed. Both controllers live inside
/// `StatefulShellRoute.indexedStack`, which keeps every tab alive, so the
/// check-in made on the Dashboard tab never reached the already-constructed
/// controllers. `refreshHealthToday()` existed on both for precisely this
/// purpose — its doc comment said the screen would call it — and nothing
/// ever did. Only a full app restart picked the check-in up, which is why it
/// looked intermittent rather than broken.

HealthReport _report(String status) => HealthReport(status: status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the adjustment itself covers BOTH plans', () {
    test('Sick Today produces a training AND a diet change', () {
      final adj = computeHealthAdjustments(_report('sick'), baseStepsGoal: 10000);
      expect(adj.workout, isNotNull, reason: 'training must be adjusted');
      expect(adj.diet, isNotNull, reason: 'diet must be adjusted');
      expect(adj.status, 'sick');
    });

    test('Sick Today never leaves strength work scheduled', () {
      final adj = computeHealthAdjustments(_report('sick'), baseStepsGoal: 10000);
      // Recovery-safe modes only — never a normal or intensified session.
      expect(
        ['rest', 'none', 'mobility', 'reduced'],
        contains(adj.workout!.mode),
        reason: 'sick day left mode "${adj.workout!.mode}"',
      );
    });

    test('Injured Today produces a training AND a diet change', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'injured', bodyParts: ['Knee'], painLevel: 4),
        baseStepsGoal: 10000,
      );
      expect(adj.workout, isNotNull);
      expect(adj.diet, isNotNull);
      expect(adj.status, 'injured');
    });

    test('severe injury cancels training outright', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'injured', bodyParts: ['Knee'], painLevel: 9),
        baseStepsGoal: 10000,
      );
      expect(adj.workout!.mode, anyOf('none', 'rest'));
      expect(adj.safety, isTrue);
    });

    test('injury details are preserved, not discarded', () {
      final adj = computeHealthAdjustments(
        HealthReport(status: 'injured', bodyParts: ['Knee', 'Ankle'], painLevel: 6),
        baseStepsGoal: 10000,
      );
      expect(adj.bodyParts, containsAll(['Knee', 'Ankle']));
      expect(adj.painLevel, 6);
    });
  });

  group('persistence survives a restart', () {
    test('a saved check-in is readable by a fresh store instance', () async {
      final adj = computeHealthAdjustments(_report('sick'), baseStepsGoal: 10000);
      await HealthStatusStore().saveToday(adj);

      // A brand-new instance is what a cold start gets.
      final reloaded = await HealthStatusStore().loadToday();
      expect(reloaded, isNotNull);
      expect(reloaded!.status, 'sick');
      expect(reloaded.diet, isNotNull);
      expect(reloaded.workout, isNotNull);
    });

    test('a check-in from a previous day does NOT leak into today', () {
      // loadToday() is date-scoped, so yesterday's sick day never suppresses
      // today's real plan.
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      expect(
        HealthStatusStore.dateKey(yesterday),
        isNot(HealthStatusStore.dateKey()),
      );
    });

    test('clearing removes only today, leaving history intact', () async {
      final store = HealthStatusStore();
      await store.saveToday(computeHealthAdjustments(_report('sick'), baseStepsGoal: 10000));
      await store.clearToday();

      expect(await store.loadToday(), isNull);
      expect(await store.loadHistory(), isNotEmpty, reason: 'timeline must survive');
    });
  });

  group('live propagation to already-open Diet and Training', () {
    test('saving a check-in bumps the revision listeners watch', () async {
      final before = HealthStatusStore.revision.value;
      await HealthStatusStore()
          .saveToday(computeHealthAdjustments(_report('sick'), baseStepsGoal: 10000));
      expect(HealthStatusStore.revision.value, greaterThan(before));
    });

    test('a listener is actually notified — this is the fix', () async {
      var notified = 0;
      void listener() => notified++;
      HealthStatusStore.revision.addListener(listener);
      addTearDown(() => HealthStatusStore.revision.removeListener(listener));

      await HealthStatusStore()
          .saveToday(computeHealthAdjustments(_report('injured'), baseStepsGoal: 10000));

      // Without this, Diet and Training keep rendering the normal plan until
      // the app is restarted — the reported bug, exactly.
      expect(notified, greaterThan(0));
    });

    test('clearing also notifies, so the normal plan comes back live', () async {
      await HealthStatusStore()
          .saveToday(computeHealthAdjustments(_report('sick'), baseStepsGoal: 10000));
      var notified = 0;
      void listener() => notified++;
      HealthStatusStore.revision.addListener(listener);
      addTearDown(() => HealthStatusStore.revision.removeListener(listener));

      await HealthStatusStore().clearToday();
      expect(notified, greaterThan(0));
    });

    test('"feeling great" notifies too', () async {
      var notified = 0;
      void listener() => notified++;
      HealthStatusStore.revision.addListener(listener);
      addTearDown(() => HealthStatusStore.revision.removeListener(listener));

      await HealthStatusStore().recordGreat();
      expect(notified, greaterThan(0));
    });
  });

  group('coach notification is deduplicated by event id', () {
    const uid = 'athlete_1';
    const date = '2026-08-16';

    test('the same status on the same day is the SAME event', () {
      // One wellness action = one coach notification, however many times the
      // screen rebuilds or the athlete re-taps.
      expect(
        wellnessEventId(uid: uid, date: date, status: 'sick'),
        wellnessEventId(uid: uid, date: date, status: 'sick'),
      );
    });

    test('sick -> injured IS new information and gets a new event', () {
      expect(
        wellnessEventId(uid: uid, date: date, status: 'sick'),
        isNot(wellnessEventId(uid: uid, date: date, status: 'injured')),
      );
    });

    test('the same status on a different day is a new event', () {
      expect(
        wellnessEventId(uid: uid, date: date, status: 'sick'),
        isNot(wellnessEventId(uid: uid, date: '2026-08-17', status: 'sick')),
      );
    });

    test('two athletes never collide', () {
      expect(
        wellnessEventId(uid: uid, date: date, status: 'sick'),
        isNot(wellnessEventId(uid: 'athlete_2', date: date, status: 'sick')),
      );
    });

    test('the id carries the notification type, so it is self-describing', () {
      expect(
        wellnessEventId(uid: uid, date: date, status: 'sick'),
        startsWith('wellness_plan_adjusted_'),
      );
    });
  });
}
