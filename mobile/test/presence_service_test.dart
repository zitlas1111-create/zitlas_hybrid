import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/presence/presence_repository.dart';
import 'package:zitlas_mobile/core/presence/presence_service.dart';
import 'package:zitlas_mobile/core/presence/presence_status.dart';

/// The WRITE side: presence must follow the app lifecycle with no user
/// input at all.
///
/// The system this replaces had exactly one writer — a manual Online/Offline
/// pair of buttons in the expert's Edit Profile sheet. Nothing else ever
/// touched the field, which is why closing the app, logging out, or simply
/// never opening that sheet all left the dot green.

class _RecordingRepository extends PresenceRepository {
  final List<({String uid, String deviceId, bool online})> beats = [];

  @override
  Future<void> beat(String uid, String deviceId, {required bool online}) async {
    beats.add((uid: uid, deviceId: deviceId, online: online));
  }

  List<bool> get states => beats.map((b) => b.online).toList();
  List<String> get uids => beats.map((b) => b.uid).toList();
}

({PresenceService service, _RecordingRepository repo}) _build() {
  final repo = _RecordingRepository();
  return (
    service: PresenceService.createForTest(repository: repo, deviceId: 'dev_test'),
    repo: repo,
  );
}

void main() {
  // PresenceService registers a WidgetsBindingObserver.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signing in publishes an online beat immediately', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();

      expect(repo.states, [true]);
      expect(repo.beats.single.uid, 'athlete_1');
      expect(repo.beats.single.deviceId, 'dev_test');

      unawaited(service.stop());
      async.flushMicrotasks();
    });
  });

  test('the heartbeat keeps refreshing while the app stays open', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();

      async.elapse(kPresenceHeartbeat * 3 + const Duration(seconds: 1));
      // Without this the TTL would expire a user who is sitting right there
      // looking at the screen.
      expect(repo.states.where((s) => s).length, greaterThanOrEqualTo(4));

      unawaited(service.stop());
      async.flushMicrotasks();
    });
  });

  test('backgrounding the app goes offline and stops beating', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      repo.beats.clear();

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      async.flushMicrotasks();
      expect(repo.states, [false]);
      expect(service.isBeating, isFalse);

      // A backgrounded app must not keep publishing — that is the battery
      // cost and the lie a permanent background service would introduce.
      async.elapse(kPresenceHeartbeat * 5);
      expect(repo.states, [false]);
    });
  });

  test('an app killed from the recents list goes offline', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      repo.beats.clear();

      service.didChangeAppLifecycleState(AppLifecycleState.detached);
      async.flushMicrotasks();
      expect(repo.states, [false]);
      expect(service.isBeating, isFalse);
    });
  });

  test('a transient interruption does NOT flap the dot', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      repo.beats.clear();

      // Android fires `inactive` for the notification shade, an incoming
      // call banner and the app switcher — and again immediately before a
      // genuine pause. Acting on it would blink the dot every time the
      // user glanced at a notification.
      service.didChangeAppLifecycleState(AppLifecycleState.inactive);
      async.flushMicrotasks();
      expect(repo.beats, isEmpty);
      expect(service.isBeating, isTrue);

      unawaited(service.stop());
      async.flushMicrotasks();
    });
  });

  test('reopening the app comes back online and resumes beating', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      async.flushMicrotasks();
      repo.beats.clear();

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      async.flushMicrotasks();
      expect(repo.states.first, isTrue);
      expect(service.isBeating, isTrue);

      async.elapse(kPresenceHeartbeat + const Duration(seconds: 1));
      expect(repo.states.length, greaterThanOrEqualTo(2));

      unawaited(service.stop());
      async.flushMicrotasks();
    });
  });

  test('signing out retires the session', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      repo.beats.clear();

      unawaited(service.stop());
      async.flushMicrotasks();
      expect(repo.states, [false]);
      expect(repo.beats.single.uid, 'athlete_1');
      expect(service.isBeating, isFalse);
      expect(service.currentUid, isNull);
    });
  });

  test('an account switch retires the OUTGOING user before starting the new one', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      repo.beats.clear();

      unawaited(service.start('expert_2'));
      async.flushMicrotasks();

      // Otherwise the previous account keeps looking online from a phone
      // somebody else is now holding.
      expect(repo.beats.length, 2);
      expect(repo.beats[0], (uid: 'athlete_1', deviceId: 'dev_test', online: false));
      expect(repo.beats[1], (uid: 'expert_2', deviceId: 'dev_test', online: true));

      unawaited(service.stop());
      async.flushMicrotasks();
    });
  });

  test('re-starting the same uid is a no-op, so a rebuild cannot restart the heartbeat', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      repo.beats.clear();

      // The bootstrap sits inside a Consumer that rebuilds on every
      // AuthState change.
      unawaited(service.start('athlete_1'));
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      expect(repo.beats, isEmpty);

      // One timer, not three: exactly one beat per interval.
      async.elapse(kPresenceHeartbeat + const Duration(seconds: 1));
      expect(repo.beats.length, 1);

      unawaited(service.stop());
      async.flushMicrotasks();
    });
  });

  test('lifecycle events after sign-out publish nothing', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start('athlete_1'));
      async.flushMicrotasks();
      unawaited(service.stop());
      async.flushMicrotasks();
      repo.beats.clear();

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      async.flushMicrotasks();
      expect(repo.beats, isEmpty);
    });
  });

  test('an empty uid is never published', () {
    fakeAsync((async) {
      final (:service, :repo) = _build();
      unawaited(service.start(''));
      async.flushMicrotasks();
      expect(repo.beats, isEmpty);
      expect(service.currentUid, isNull);
    });
  });
}
