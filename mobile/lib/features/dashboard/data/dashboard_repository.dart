import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/activity_day_model.dart';
import '../models/assigned_coach.dart';
import '../models/goal_model.dart';
import '../models/weight_entry.dart';

String todayKey([DateTime? now]) {
  final d = now ?? DateTime.now();
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// Firestore access for the Athlete Dashboard. Every path/field here matches
/// the real production schema traced from `cloud-sync.js`, `activity-service.js`,
/// and `dashboard.js` — no new collections, no schema changes. See
/// docs/MIGRATION_INVENTORY.md §3 for the wider collection map.
///
/// `users/{uid}` fields used (subset of `cloud-sync.js`'s `FIELD_MAP`):
/// `goal`, `swot`, `workoutPlan`, `personalInfo`, `currentStreak`,
/// `longestStreak`, `dailyStepGoal`. Reset clears the same
/// `GOAL_SCOPED_FIELDS` the website's `clearGoalData()` clears.
class DashboardRepository {
  DashboardRepository(this._firestore);

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Live `users/{uid}` doc — mirrors `cloud-sync.js`'s `attachRealtime`,
  /// the only sections the website keeps cross-device-live for (goal, swot,
  /// workout plan existence, profile name/photo, streak).
  Stream<Map<String, dynamic>?> watchUserDoc(String uid) {
    return _userDoc(uid).snapshots().map((snap) => snap.data());
  }

  Future<ActivityDayModel> fetchTodayActivity(String uid, {DateTime? now}) async {
    final key = todayKey(now);
    final doc = await _userDoc(uid).collection('activity').doc(key).get();
    if (!doc.exists) return ActivityDayModel.empty(key);
    return ActivityDayModel.fromMap(key, doc.data()!);
  }

  /// The archived day docs behind the Mon–Sun strip and the adaptive-goal
  /// suggestion. The website keeps a 90-day localStorage history cache; the
  /// same records live authoritatively at `users/{uid}/activity/{date}`
  /// (written by `_syncDayToFirestore`), so Flutter reads those directly.
  /// Keyed by `YYYY-MM-DD`, today excluded — callers pass today separately.
  Future<Map<String, ActivityDayModel>> fetchActivityHistory(
    String uid, {
    int days = 14,
    DateTime? now,
  }) async {
    final today = todayKey(now);
    final snap = await _userDoc(uid)
        .collection('activity')
        .orderBy('date', descending: true)
        .limit(days)
        .get();
    final out = <String, ActivityDayModel>{};
    for (final doc in snap.docs) {
      if (doc.id == today) continue;
      out[doc.id] = ActivityDayModel.fromMap(doc.id, doc.data());
    }
    return out;
  }

  /// `ZitlasActivity.setDailyGoal(n)` — the athlete's BASE step goal. The
  /// website mirrors it onto `users/{uid}.dailyStepGoal` via `_mergeUserDoc`;
  /// that field is this app's source of truth for the goal.
  Future<void> setDailyStepGoal(String uid, int goal) {
    return _userDoc(uid).set({'dailyStepGoal': goal}, SetOptions(merge: true));
  }

  /// Mirrors `activity-service.js`'s `_syncDayToFirestore` — the day doc the
  /// Activity card, the Mon–Sun strip, and the coach's Overview all read.
  ///
  /// `merge: true` deliberately: this doc also carries water/sleep/workout
  /// fields written by other flows, and a step sync must never clobber them.
  /// Local storage is written first by [StepTrackingService], so a failure
  /// here costs a sync, never the steps themselves.
  Future<void> saveDailySteps(
    String uid, {
    required String date,
    required int steps,
    required int goal,
    required bool goalCompleted,
  }) {
    return _userDoc(uid).collection('activity').doc(date).set({
      'date': date,
      'steps': steps,
      'goal': goal,
      'goalCompleted': goalCompleted,
      'lastUpdated': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Persists both streaks on the user doc.
  ///
  /// Same two fields the website maintains (`currentStreak`/`longestStreak`),
  /// so a streak earned on the phone is the streak the web dashboard and the
  /// coach view show.
  Future<void> saveStreaks(
    String uid, {
    required int current,
    required int longest,
  }) {
    return _userDoc(uid).set({
      'currentStreak': current,
      'longestStreak': longest,
    }, SetOptions(merge: true));
  }

  Future<List<WeightEntry>> fetchWeightHistory(String uid, {int limit = 14}) async {
    final snap = await _userDoc(uid)
        .collection('weight_log')
        .orderBy('date', descending: true)
        .limit(limit)
        .get();
    return snap.docs.map((d) => WeightEntry.fromMap(d.data())).toList();
  }

  /// `daily-score.js` input: 0-10 average of today's *reviewed*
  /// `meal_checkins` for this athlete. Matches `renderDailyScoreCard()`'s
  /// query exactly — note the doc's `day` field is a recurring weekday
  /// name, not a date, so filtering must use the real `timestamp` field
  /// against today's calendar date, same as the website does.
  Future<double?> fetchTodayMealScoreAvg(String uid, {DateTime? now}) async {
    final snap = await _firestore
        .collection('meal_checkins')
        .where('athleteId', isEqualTo: uid)
        .get();
    final today = now ?? DateTime.now();
    final todayStr = '${today.year}-${today.month}-${today.day}';
    final scores = <double>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      if (data['status'] != 'reviewed') continue;
      final score = data['score'];
      if (score == null) continue;
      final ts = data['timestamp'];
      DateTime? when;
      if (ts is Timestamp) when = ts.toDate();
      if (ts is String) when = DateTime.tryParse(ts);
      if (when == null) continue;
      final whenStr = '${when.year}-${when.month}-${when.day}';
      if (whenStr != todayStr) continue;
      scores.add((score as num).toDouble());
    }
    if (scores.isEmpty) return null;
    return scores.reduce((a, b) => a + b) / scores.length;
  }

  Future<bool> hasActiveCoaching(String uid) async {
    final doc = await _firestore.collection('personal_coaching').doc(uid).get();
    return doc.exists && doc.data()?['status'] == 'active';
  }

  /// The athlete's assigned coach, live.
  ///
  /// `personal_coaching/{uid}` IS the assignment — there is no separate
  /// assignment collection and deliberately no denormalised `assignedCoachId`
  /// on the user doc. One document, written only by the backend inside the
  /// accept transaction, is what makes "no duplicate assignments" true by
  /// construction: the doc id is the athlete's uid, so a second concurrent
  /// accept overwrites rather than duplicating, and the transaction rejects
  /// it anyway (`athlete_has_other_active_coach`).
  ///
  /// The coach's photo and verified badge come from `experts/{coachId}`,
  /// which is readable by any signed-in user — those are public professional
  /// details, not private ones.
  Stream<AssignedCoach?> watchAssignedCoach(String uid) {
    return _firestore.collection('personal_coaching').doc(uid).snapshots().asyncMap(
      (snap) async {
        final data = snap.data();
        if (kDebugMode) {
          debugPrint(
            '[COACH VISIBILITY] personal_coaching/$uid — '
            'docExists=${snap.exists} '
            'coachId=${data?['coachId']} '
            'status=${data?['status']} '
            'endDate=${data?['endDate']}',
          );
        }
        if (data == null || data['status'] != 'active') {
          if (kDebugMode) {
            debugPrint(
              data == null
                  ? '[COACH VISIBILITY] -> assignedCoach=null — no personal_coaching doc for this athlete'
                  : "[COACH VISIBILITY] -> assignedCoach=null — status is '${data['status']}', not 'active'",
            );
          }
          return null;
        }
        final coachId = data['coachId'] as String?;
        if (coachId == null) {
          if (kDebugMode) {
            debugPrint('[COACH VISIBILITY] -> assignedCoach=null — status is active but coachId is missing');
          }
          return null;
        }

        Map<String, dynamic>? expert;
        try {
          expert = (await _firestore.collection('experts').doc(coachId).get()).data();
        } catch (e) {
          // The card still renders from the relationship alone — a missing
          // expert doc costs a photo and a badge, not the assignment.
          if (kDebugMode) debugPrint('[COACH] expert profile unavailable: $e');
        }

        final assigned = AssignedCoach.from(relationship: data, expert: expert);
        if (kDebugMode) {
          debugPrint(
            assigned == null
                ? '[COACH VISIBILITY] -> assignedCoach=null — status active but AssignedCoach.from rejected the data (coachId blank?)'
                : '[COACH VISIBILITY] -> assignedCoach=AssignedCoach(coachId=${assigned.coachId}, '
                    'coachName=${assigned.coachName}) — MyCoachCard + End Coaching button WILL render',
          );
        }
        return assigned;
      },
    );
  }

  Future<void> saveGoal(String uid, GoalModel goal) {
    return _userDoc(uid).set({
      'goal': goal.toMap(),
      'goalUpdatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Matches `cloud-sync.js`'s `clearGoalData()` — the same
  /// `GOAL_SCOPED_FIELDS` set to null, plus a `goalResetAt` timestamp.
  Future<void> resetGoal(String uid) {
    const goalScopedFields = [
      'goal',
      'assessment',
      'survey',
      'calculations',
      'swot',
      'dietPlan',
      'workoutPlan',
      'roadmap',
      'precautions',
      'planGeneratedAt',
      'planId',
      'dietPlanMaster',
      'workoutPlanMaster',
    ];
    final updates = <String, dynamic>{
      for (final field in goalScopedFields) field: null,
      'goalResetAt': DateTime.now().toIso8601String(),
    };
    return _userDoc(uid).set(updates, SetOptions(merge: true));
  }

  Future<void> logWater(String uid, int deltaMl, {DateTime? now}) async {
    final key = todayKey(now);
    final ref = _userDoc(uid).collection('activity').doc(key);
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      final current = (snap.data()?['waterMl'] as num?)?.toInt() ?? 0;
      txn.set(ref, {
        'date': key,
        'waterMl': current + deltaMl,
        'waterGoalMl': snap.data()?['waterGoalMl'] ?? 2500,
      }, SetOptions(merge: true));
    });
  }

  Future<void> logSleep(String uid, double hours, {DateTime? now}) {
    final key = todayKey(now);
    return _userDoc(uid).collection('activity').doc(key).set({
      'date': key,
      'sleepHours': hours,
    }, SetOptions(merge: true));
  }

  Future<void> logWeight(String uid, double weightKg, {DateTime? now}) {
    final key = todayKey(now);
    return _userDoc(uid).collection('weight_log').doc(key).set({
      'date': key,
      'weightKg': weightKg,
      'loggedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Mirrors `_syncDayToFirestore`'s goal fields: after a health report the
  /// day doc must describe the goal actually in force, so the Activity card
  /// and the coach dashboard both see Recovery Mode. `goal` (the base) is
  /// left untouched — only the effective goal and the flag change.
  Future<void> applyRecoveryGoalToToday(
    String uid, {
    required int baseGoal,
    required int effectiveGoal,
    required bool recoveryMode,
    DateTime? now,
  }) {
    final key = todayKey(now);
    return _userDoc(uid).collection('activity').doc(key).set({
      'date': key,
      'goal': baseGoal,
      'goalEffective': effectiveGoal,
      'recoveryMode': recoveryMode,
    }, SetOptions(merge: true));
  }

  /// `alertCoach(adj)` — only fires when a Personal Coach relationship is
  /// `active`. Writes the same three records the website does:
  /// `health_alerts`, `coaching_notifications`, and a system-style message
  /// into the coaching chat room. Returns silently when there's no coach.
  Future<void> sendHealthAlert({
    required String uid,
    required String athleteName,
    required Map<String, dynamic> alert,
    required String summary,
    required String chatText,
    required String eventId,
    required String title,
    required String message,
  }) async {
    final relSnap = await _firestore.collection('personal_coaching').doc(uid).get();
    final rel = relSnap.data();
    if (rel == null || rel['status'] != 'active') return;
    final coachId = rel['coachId'] as String?;
    if (coachId == null) return;

    final now = DateTime.now();
    final nowIso = now.toIso8601String();

    // DETERMINISTIC ids, derived from athlete + date + status.
    //
    // These were `millisecondsSinceEpoch`, so every re-tap, screen rebuild
    // or retry created a brand-new alert, a brand-new coach notification
    // and a brand-new chat message. Tapping "Sick Today" twice spammed the
    // coach twice for one piece of information.
    //
    // Same athlete + same day + same status now resolves to the same three
    // document ids, so a repeat is an idempotent overwrite. Changing status
    // (sick -> injured) genuinely IS new information and produces a new id,
    // which is the behaviour we want.
    final alertId = 'HA_$eventId';
    await _firestore.collection('health_alerts').doc(alertId).set({
      'alertId': alertId,
      'athleteId': uid,
      'athleteName': athleteName,
      'coachId': coachId,
      'eventId': eventId,
      ...alert,
      'createdAt': nowIso,
      'timestamp': nowIso,
    });

    final nid = 'CN_$eventId';
    await _firestore.collection('coaching_notifications').doc(nid).set({
      'id': nid,
      'toId': coachId,
      'fromId': uid,
      'fromName': athleteName,
      'title': title,
      'text': message,
      'type': 'wellness_plan_adjusted',
      // Enough for the expert dashboard to identify the athlete and open the
      // right coaching context without a second lookup.
      'athleteId': uid,
      'athleteName': athleteName,
      'coachId': coachId,
      'status': alert['status'],
      'date': alert['date'],
      'eventId': eventId,
      'alertId': alertId,
      'action': 'coaching_workspace',
      'actionId': uid,
      'createdAt': nowIso,
      'timestamp': nowIso,
      'read': false,
    });

    final chatId = 'chat_${uid}_$coachId';
    final msgId = 'msg_$eventId';
    final room = _firestore.collection('chat_rooms').doc(chatId);
    await room.set({
      'participants': [uid, coachId],
      'athleteId': uid,
      'athleteName': athleteName,
      'expertId': coachId,
      'expertName': rel['coachName'] ?? 'Coach',
      'lastMessage': chatText.split('\n').first,
      'lastMessageAt': nowIso,
    }, SetOptions(merge: true));
    await room.collection('messages').doc(msgId).set({
      'id': msgId,
      'conversationId': chatId,
      'senderId': uid,
      'senderType': 'athlete',
      'text': chatText,
      'type': 'text',
      'imageUrl': null,
      'timestamp': nowIso,
    });
  }

  /// `notifySelf(adj)` — a notification in the athlete's own centre, sent
  /// whether or not they have a coach. Same `notifications` collection the
  /// header bell counts.
  Future<void> sendSelfNotification({
    required String uid,
    required String title,
    required String message,
    required String type,
    required String priority,
  }) {
    final id = 'N_${DateTime.now().millisecondsSinceEpoch}_hs';
    return _firestore.collection('notifications').doc(id).set({
      'id': id,
      'userId': uid,
      'title': title,
      'message': message,
      'category': 'health',
      'type': type,
      'action': 'dashboard',
      'priority': priority,
      'isRead': false,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  /// Mirrors `notification-center.js`'s `listenUnreadCount` — live query,
  /// drives the header bell badge.
  Stream<int> watchUnreadNotificationCount(String uid) {
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.size);
  }
}
