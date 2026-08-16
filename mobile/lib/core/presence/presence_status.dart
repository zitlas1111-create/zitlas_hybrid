import 'package:cloud_firestore/cloud_firestore.dart';

/// How often a foregrounded device refreshes its heartbeat.
const Duration kPresenceHeartbeat = Duration(seconds: 25);

/// How long a heartbeat stays trustworthy.
///
/// Deliberately ~3x the heartbeat, so a couple of dropped writes on flaky
/// mobile data don't flap somebody offline, while a genuinely dead app
/// still expires inside a minute.
///
/// This TTL — not the offline write — is what actually makes presence
/// correct. Cloud Firestore has no `onDisconnect` primitive (that belongs
/// to Realtime Database), so a force-stopped, crashed or battery-pulled
/// phone never gets to announce anything. Readers therefore DERIVE online
/// from a fresh heartbeat instead of trusting a stored flag. That is the
/// whole difference from the old `status != 'offline'` field, which no
/// process ever set back to `'offline'` and which consequently reported
/// every expert as green forever.
const Duration kPresenceTtl = Duration(seconds: 75);

DateTime? _asDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

/// One device install's view of a user's presence.
///
/// A user signed in on a phone and a tablet has two of these; they are
/// combined by [PresenceStatus.fromSessions] rather than overwriting each
/// other, so closing the tablet does not mark the phone offline.
class PresenceSession {
  const PresenceSession({
    required this.deviceId,
    required this.online,
    this.lastSeen,
  });

  final String deviceId;

  /// What the device last *claimed*. Never sufficient on its own — a claim
  /// of `online` from an hour ago is a dead app, which is why [isLiveAt]
  /// also requires a fresh [lastSeen].
  final bool online;
  final DateTime? lastSeen;

  /// Fail-closed by construction: an absent, unparseable or stale
  /// heartbeat is offline. Every ambiguous case resolves to "not online",
  /// the opposite of the field this replaces.
  bool isLiveAt(DateTime now) {
    final seen = lastSeen;
    if (!online || seen == null) return false;
    // A negative difference means the server's clock ran ahead of this
    // reader's. Trusting the beat is right there — the write demonstrably
    // just happened — and it avoids flapping on modest clock skew.
    return now.difference(seen) <= kPresenceTtl;
  }

  /// [pendingWrite] is true when this snapshot still carries our own
  /// unacknowledged write. `FieldValue.serverTimestamp()` reads back as
  /// null until the server acks, so without this the device that just
  /// wrote its own heartbeat would briefly render ITSELF offline — very
  /// visible on the expert dashboard, which shows the expert their own
  /// dot. A pending write is by definition freshly made locally.
  static PresenceSession? fromMap(
    String deviceId,
    Map<String, dynamic>? m, {
    bool pendingWrite = false,
    DateTime? now,
  }) {
    if (m == null) return null;
    var lastSeen = _asDate(m['lastSeen']);
    if (lastSeen == null && pendingWrite) lastSeen = now ?? DateTime.now();
    return PresenceSession(
      deviceId: deviceId,
      // Strict equality, not `!= 'offline'`: a null, empty or unexpected
      // value is offline.
      online: m['state'] == 'online',
      lastSeen: lastSeen,
    );
  }
}

/// A user's presence, derived from all of their device sessions.
class PresenceStatus {
  const PresenceStatus({required this.isOnline, this.lastSeen});

  final bool isOnline;

  /// The most recent heartbeat across every device — drives the
  /// "Active 5m ago" line. Null when the user has never been seen.
  final DateTime? lastSeen;

  /// What a reader shows before any snapshot arrives, and for a user with
  /// no presence documents at all. Offline, never online: an unknown
  /// answer must not render as a green dot.
  static const unknown = PresenceStatus(isOnline: false, lastSeen: null);

  /// Online if ANY device is live. Multi-device by design.
  factory PresenceStatus.fromSessions(
    Iterable<PresenceSession> sessions, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    var online = false;
    DateTime? latest;
    for (final session in sessions) {
      if (session.isLiveAt(at)) online = true;
      final seen = session.lastSeen;
      if (seen != null && (latest == null || seen.isAfter(latest))) {
        latest = seen;
      }
    }
    return PresenceStatus(isOnline: online, lastSeen: latest);
  }

  /// Instagram-style caption. Coarse on purpose — an exact last-seen clock
  /// is more surveillance than a fitness app needs.
  String label({DateTime? now}) {
    if (isOnline) return 'Online';
    final seen = lastSeen;
    if (seen == null) return 'Offline';
    final gap = (now ?? DateTime.now()).difference(seen);
    if (gap.isNegative || gap < const Duration(minutes: 1)) return 'Active just now';
    if (gap < const Duration(hours: 1)) return 'Active ${gap.inMinutes}m ago';
    if (gap < const Duration(days: 1)) return 'Active ${gap.inHours}h ago';
    if (gap < const Duration(days: 7)) return 'Active ${gap.inDays}d ago';
    return 'Offline';
  }
}
