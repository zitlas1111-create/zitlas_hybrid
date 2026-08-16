import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/presence/presence_status.dart';

/// Presence must be DERIVED from a fresh heartbeat, never read from a
/// stored flag.
///
/// The system this replaces had four independent fail-open defaults
/// (`status = 'online'` in the constructor, `?? 'online'` in `fromMap`,
/// `isOnline => status != 'offline'`, and `p?.isOnline ?? true` in the UI),
/// so an expert was green from the moment their document existed and stayed
/// green forever — killing the app changed nothing, because nothing but a
/// human tap ever wrote the field.
///
/// Every test below therefore pins the same property from a different
/// angle: an ambiguous answer resolves to OFFLINE.

PresenceSession _session({
  String deviceId = 'dev_a',
  bool online = true,
  Duration ago = Duration.zero,
  DateTime? now,
}) {
  return PresenceSession(
    deviceId: deviceId,
    online: online,
    lastSeen: (now ?? DateTime(2026, 8, 16, 12)).subtract(ago),
  );
}

void main() {
  final now = DateTime(2026, 8, 16, 12);

  group('a single session is live only while its heartbeat is fresh', () {
    test('a heartbeat from a moment ago is online', () {
      expect(_session(ago: const Duration(seconds: 5), now: now).isLiveAt(now), isTrue);
    });

    test('a heartbeat inside the TTL is still online', () {
      // One dropped beat on flaky mobile data must not flap the dot.
      expect(
        _session(ago: kPresenceTtl - const Duration(seconds: 1), now: now).isLiveAt(now),
        isTrue,
      );
    });

    test('a heartbeat past the TTL is offline with nobody writing anything', () {
      // THE core guarantee. Firestore has no onDisconnect, so a
      // force-stopped or battery-pulled phone never announces itself.
      expect(
        _session(ago: kPresenceTtl + const Duration(seconds: 1), now: now).isLiveAt(now),
        isFalse,
      );
    });

    test('the old stale user — last seen an hour ago — is offline', () {
      expect(_session(ago: const Duration(hours: 1), now: now).isLiveAt(now), isFalse);
    });

    test('a fresh beat that CLAIMS offline is offline', () {
      // The clean background write. Claim and freshness both matter.
      expect(_session(online: false, ago: Duration.zero, now: now).isLiveAt(now), isFalse);
    });

    test('a session with no heartbeat at all is offline, not online', () {
      const s = PresenceSession(deviceId: 'dev_a', online: true, lastSeen: null);
      expect(s.isLiveAt(now), isFalse);
    });

    test('the TTL leaves room for two dropped beats', () {
      // Guards the ratio itself: shrinking the TTL below 2 heartbeats would
      // make the dot flap on ordinary packet loss.
      expect(kPresenceTtl, greaterThanOrEqualTo(kPresenceHeartbeat * 2));
    });
  });

  group('parsing fails closed', () {
    test('a missing state field is offline', () {
      final s = PresenceSession.fromMap('dev_a', {'lastSeen': Timestamp.fromDate(now)});
      expect(s!.isLiveAt(now), isFalse);
    });

    test("an unexpected state string is offline — NOT `!= 'offline'`", () {
      // The precise inversion of the old bug: `active` used to read online.
      for (final junk in ['active', 'ONLINE', '', 'available', 'true']) {
        final s = PresenceSession.fromMap(
          'dev_a',
          {'state': junk, 'lastSeen': Timestamp.fromDate(now)},
        );
        expect(s!.isLiveAt(now), isFalse, reason: 'state=$junk must not be online');
      }
    });

    test('only the exact string `online` counts', () {
      final s = PresenceSession.fromMap(
        'dev_a',
        {'state': 'online', 'lastSeen': Timestamp.fromDate(now)},
      );
      expect(s!.isLiveAt(now), isTrue);
    });

    test('an unparseable lastSeen is offline', () {
      final s = PresenceSession.fromMap('dev_a', {'state': 'online', 'lastSeen': 'not-a-date'});
      expect(s!.isLiveAt(now), isFalse);
    });

    test('a pending serverTimestamp reads as fresh, so a device never shows ITSELF offline', () {
      // FieldValue.serverTimestamp() reads back null until the server acks.
      // Without the pendingWrite allowance the expert dashboard — which
      // renders the expert's own dot — would blink grey on every beat.
      final s = PresenceSession.fromMap(
        'dev_a',
        {'state': 'online', 'lastSeen': null},
        pendingWrite: true,
        now: now,
      );
      expect(s!.isLiveAt(now), isTrue);
    });

    test('a null lastSeen WITHOUT a pending write stays offline', () {
      final s = PresenceSession.fromMap('dev_a', {'state': 'online', 'lastSeen': null});
      expect(s!.isLiveAt(now), isFalse);
    });
  });

  group('multi-device: online if ANY device is live', () {
    test('phone foregrounded, tablet long dead — online', () {
      final status = PresenceStatus.fromSessions([
        _session(deviceId: 'phone', ago: const Duration(seconds: 5), now: now),
        _session(deviceId: 'tablet', ago: const Duration(hours: 3), now: now),
      ], now: now);
      expect(status.isOnline, isTrue);
    });

    test('closing one device does not black out the other', () {
      final status = PresenceStatus.fromSessions([
        _session(deviceId: 'phone', online: false, now: now),
        _session(deviceId: 'tablet', ago: const Duration(seconds: 3), now: now),
      ], now: now);
      expect(status.isOnline, isTrue);
    });

    test('every device stale — offline', () {
      final status = PresenceStatus.fromSessions([
        _session(deviceId: 'phone', ago: const Duration(minutes: 10), now: now),
        _session(deviceId: 'tablet', ago: const Duration(days: 2), now: now),
      ], now: now);
      expect(status.isOnline, isFalse);
    });

    test('a user with NO sessions is offline, not online', () {
      // The `p?.isOnline ?? true` bug, at the model layer.
      expect(PresenceStatus.fromSessions(const [], now: now).isOnline, isFalse);
    });

    test('the default status is offline', () {
      expect(PresenceStatus.unknown.isOnline, isFalse);
    });

    test('lastSeen is the most recent beat across all devices', () {
      final status = PresenceStatus.fromSessions([
        _session(deviceId: 'phone', ago: const Duration(hours: 5), now: now),
        _session(deviceId: 'tablet', ago: const Duration(minutes: 7), now: now),
      ], now: now);
      expect(status.lastSeen, now.subtract(const Duration(minutes: 7)));
    });
  });

  group('clock skew', () {
    test('a heartbeat from the near future is trusted rather than flapping', () {
      // The write demonstrably just happened; the reader's clock is simply
      // behind the server's.
      final s = PresenceSession(
        deviceId: 'dev_a',
        online: true,
        lastSeen: now.add(const Duration(seconds: 30)),
      );
      expect(s.isLiveAt(now), isTrue);
    });
  });

  group('last-seen label', () {
    test('a live user reads Online', () {
      const status = PresenceStatus(isOnline: true, lastSeen: null);
      expect(status.label(now: now), 'Online');
    });

    test('a never-seen user reads Offline, not "Active null ago"', () {
      expect(PresenceStatus.unknown.label(now: now), 'Offline');
    });

    test('recent absences read in minutes, then hours, then days', () {
      String at(Duration ago) => PresenceStatus(
            isOnline: false,
            lastSeen: now.subtract(ago),
          ).label(now: now);

      expect(at(const Duration(seconds: 20)), 'Active just now');
      expect(at(const Duration(minutes: 8)), 'Active 8m ago');
      expect(at(const Duration(hours: 5)), 'Active 5h ago');
      expect(at(const Duration(days: 3)), 'Active 3d ago');
    });

    test('a months-old absence degrades to plain Offline', () {
      // Coarse on purpose — an exact last-seen clock is more surveillance
      // than a fitness app needs.
      const status = PresenceStatus(isOnline: false, lastSeen: null);
      expect(status.label(now: now), 'Offline');
      expect(
        PresenceStatus(isOnline: false, lastSeen: now.subtract(const Duration(days: 400)))
            .label(now: now),
        'Offline',
      );
    });
  });
}
