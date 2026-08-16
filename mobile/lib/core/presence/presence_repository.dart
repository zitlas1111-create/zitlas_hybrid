import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'presence_status.dart';

/// Firestore access for `presence_sessions/{uid}/sessions/{deviceId}`.
///
/// One document per device install. The subcollection shape (rather than a
/// map field on a single doc) is what makes multi-device safe: two phones
/// writing their own heartbeats never race, and `firestore.rules` can scope
/// writes to the owning uid with a plain path match.
class PresenceRepository {
  PresenceRepository({FirebaseFirestore? firestore}) : _injected = firestore;

  final FirebaseFirestore? _injected;

  /// `FirebaseFirestore.instance` throws when Firebase never initialised
  /// (see `ZitlasApp.firebaseReady`). Presence is an enhancement, never a
  /// reason to take the app down, so every path degrades to null.
  FirebaseFirestore? get _db {
    if (_injected != null) return _injected;
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      return null;
    }
  }

  CollectionReference<Map<String, dynamic>>? _sessions(String uid) {
    if (uid.isEmpty) return null;
    return _db?.collection('presence_sessions').doc(uid).collection('sessions');
  }

  /// Writes this device's heartbeat.
  ///
  /// `lastSeen` is a SERVER timestamp, never a client clock: the rules
  /// require `lastSeen == request.time`, so a tampered client cannot post
  /// a far-future heartbeat and pin itself green forever.
  ///
  /// Never throws — a failed beat simply lets the TTL expire the session,
  /// which is the correct outcome for a device that cannot reach Firestore.
  Future<void> beat(
    String uid,
    String deviceId, {
    required bool online,
  }) async {
    final ref = _sessions(uid)?.doc(deviceId);
    if (ref == null) return;
    try {
      await ref.set({
        'state': online ? 'online' : 'offline',
        'lastSeen': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Offline, rules rejection, or signed-out mid-write. Deliberately
      // swallowed: see doc comment.
    }
  }

  /// Live presence for [uid]. Emits [PresenceStatus.unknown] — i.e.
  /// offline — on error or when Firebase is unavailable, so a read failure
  /// can never paint somebody green.
  Stream<PresenceStatus> watch(String uid) {
    final sessions = _sessions(uid);
    if (sessions == null) return Stream.value(PresenceStatus.unknown);
    return sessions.snapshots().map(_derive).transform(
          StreamTransformer<PresenceStatus, PresenceStatus>.fromHandlers(
            // A permission or network error downgrades to offline rather
            // than killing the stream or leaving a stale green dot up.
            handleError: (error, stack, sink) => sink.add(PresenceStatus.unknown),
          ),
        );
  }

  static PresenceStatus _derive(QuerySnapshot<Map<String, dynamic>> snap) {
    final now = DateTime.now();
    final sessions = <PresenceSession>[];
    for (final doc in snap.docs) {
      final session = PresenceSession.fromMap(
        doc.id,
        doc.data(),
        pendingWrite: doc.metadata.hasPendingWrites,
        now: now,
      );
      if (session != null) sessions.add(session);
    }
    return PresenceStatus.fromSessions(sessions, now: now);
  }
}
