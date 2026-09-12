import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../models/meal_checkin.dart';
import 'meal_photo_uploader.dart';

/// `meal_checkins/{checkinId}` — photographed meals and the coach's reviews.
///
/// Reuses the collection and document shape `frontend/pages/diet/diet.js`
/// already writes, so a meal submitted on the phone appears in the website's
/// coaching workspace and vice versa. Notifications go through the existing
/// `notifications` + `coaching_notifications` pair, matching what the website
/// sends on the same events.
class MealCheckinRepository {
  MealCheckinRepository({
    FirebaseFirestore? firestore,
    MealPhotoUploader? uploader,
    ApiClient? api,
    FirebaseAuth? auth,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _uploader = uploader ?? MealPhotoUploader(),
        // Nullable so the repository falls back to FirebaseAuth.instance
        // lazily — the same pattern as DietRepository.
        // ignore: prefer_initializing_formals
        _auth = auth,
        _api = api ?? ApiClient() {
    // EVERY backend call from here verifies its caller: the two push triggers
    // (/api/notifications/meal-checkin and /meal-review) and the nutrition
    // estimate (/api/meal/estimate-nutrition). This ApiClient used to carry
    // no token at all, so each of them was rejected 401 and the failure was
    // swallowed as "best-effort" — a coach was never pushed about a meal
    // submitted from the app, nor the athlete about its review.
    _api.authTokenProvider ??= () async {
      try {
        return await (_auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  final FirebaseFirestore _db;
  final MealPhotoUploader _uploader;
  final FirebaseAuth? _auth;
  final ApiClient _api;

  /// This athlete's check-ins, live. Newest first.
  Stream<List<MealCheckin>> watchForAthlete(String athleteId) {
    return _db
        .collection('meal_checkins')
        .where('athleteId', isEqualTo: athleteId)
        .snapshots()
        .map(_parse);
  }

  /// Everything awaiting or carrying this coach's review, live.
  Stream<List<MealCheckin>> watchForCoach(String coachId) {
    return _db
        .collection('meal_checkins')
        .where('coachId', isEqualTo: coachId)
        .snapshots()
        .map(_parse);
  }

  List<MealCheckin> _parse(QuerySnapshot<Map<String, dynamic>> snap) {
    final list = [
      for (final d in snap.docs) ?MealCheckin.fromMap(d.data()),
    ];
    // Sorted client-side so no composite index is needed alongside the
    // equality filter — a coaching relationship is 30 days of meals at most.
    list.sort((a, b) {
      final at = a.timestamp, bt = b.timestamp;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    if (kDebugMode) debugPrint('[MEAL CHECKIN] snapshot — ${list.length} total');
    return list;
  }

  /// Uploads the photo, estimates its nutrition, writes the check-in and
  /// notifies the coach.
  ///
  /// The AI estimate runs ALONGSIDE the upload and is allowed to fail: a
  /// nutrition guess is a bonus, and losing the athlete's check-in because a
  /// vision model timed out would be absurd. Its fields stay null in that
  /// case — null meaning "not estimated", never "zero".
  Future<MealCheckin> submit({
    required File photo,
    required String athleteId,
    required String athleteName,
    required String coachId,
    required String mealName,
    required String day,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final stamp = at.millisecondsSinceEpoch;
    final id = 'MCI_${stamp}_${(stamp % 100000).toRadixString(36)}';

    if (kDebugMode) debugPrint('[MEAL CHECKIN] submitting $mealName for $athleteId');

    // Decode/normalize the photo ONCE (HEIC/HEIF -> JPEG via the platform's
    // own codec, or a resize of an already-supported format) and use the
    // SAME bytes + Content-Type for the upload and the AI estimate below, so
    // neither can see a different format than the other. Throws a short,
    // athlete-facing message (never lets a raw exception through) if the
    // photo is unusable.
    final prepared = await _uploader.prepare(photo);

    // requireDurable: imageUrl below is persisted on the check-in and opened
    // by the NUTRITIONIST days later. The /api/chat/upload fallback stores on
    // the container's ephemeral disk — every existing meal_checkins record
    // took that path and every one of them now 404s in the reviewer's Meal
    // Reviews tab. Never save a URL that will not survive; fail loudly here
    // instead, while the athlete still has the photo and can retry.
    final results = await Future.wait([
      _uploader.uploadPrepared(prepared, requireDurable: true),
      _estimateNutrition(prepared),
    ]);
    final imageUrl = results[0] as String;
    final estimate = results[1] as Map<String, dynamic>?;

    final checkin = MealCheckin(
      checkinId: id,
      athleteId: athleteId,
      athleteName: athleteName,
      coachId: coachId,
      day: day,
      mealType: mealName.toLowerCase(),
      mealName: mealName,
      imageUrl: imageUrl,
      timestamp: at,
      status: 'pending',
      estimatedCalories: estimate == null ? null : asNumOrNull(estimate['calories']),
      estimatedProtein: estimate == null ? null : asNumOrNull(estimate['protein']),
      estimatedCarbs: estimate == null ? null : asNumOrNull(estimate['carbs']),
      estimatedFat: estimate == null ? null : asNumOrNull(estimate['fat']),
      foodRecognition: [
        if (estimate?['food_recognition'] is List)
          for (final f in estimate!['food_recognition'] as List)
            if (f is String && f.trim().isNotEmpty) f.trim(),
      ],
      confidenceScore: estimate == null ? null : asNumOrNull(estimate['confidence_score']),
    );

    // A successful photo upload does NOT mean the review record was created —
    // verified separately, after the write actually completes.
    await _db.collection('meal_checkins').doc(id).set(checkin.toMap());
    if (kDebugMode) {
      // coachingId: there is no separate field — the relationship is 1:1
      // keyed by personal_coaching/{athleteId}, so athleteId doubles as the
      // coaching-session identifier the coach's read rule (isActiveCoachOf)
      // looks up.
      debugPrint('[MEAL_SNAP_SUBMIT] athleteId=$athleteId coachId=$coachId '
          'expertId=$coachId coachingId=$athleteId mealType=${checkin.mealType} '
          'mealId=$id status=${checkin.status} '
          'collection/path=meal_checkins/$id');
    }

    await _notifyCoach(checkin);
    // Real FCM push so the coach is told on a locked/closed phone — the writes
    // in _notifyCoach only create in-app documents. The backend re-reads this
    // check-in, verifies the caller is its athlete, and derives the coach from
    // the document, so the recipient is never client-supplied. Best-effort:
    // the check-in is already saved and must not fail over a push.
    try {
      await _api.post('/api/notifications/meal-checkin', body: {'checkinId': id});
    } catch (e) {
      if (kDebugMode) debugPrint('[MEAL CHECKIN] push trigger failed (non-fatal): $e');
    }
    return checkin;
  }

  /// The coach's verdict. Writes the review and notifies the athlete.
  ///
  /// `status`, `reaction`, `score`, `comment`, `reviewedAt` and `reviewedBy`
  /// are exactly the fields the website's own review sets, so a meal reviewed
  /// here shows as reviewed there — plus the star dimensions the expert
  /// dashboard now writes (`overallRating` and the three optional ones).
  ///
  /// `reaction` and `score` are still written and are NOT redundant:
  /// meal_compliance.dart scores adherence purely off `reaction.isCompliant`,
  /// and the website's "Avg Score" chip reads `score` on a 1-10 scale.
  ///
  /// [overall] is the 1-5 star rating. When omitted it is derived from
  /// [reaction], so existing callers keep working unchanged.
  Future<void> review({
    required MealCheckin checkin,
    required MealReaction reaction,
    required String coachName,
    String? comment,
    int? overall,
    int? taste,
    int? presentation,
    int? nutrition,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final overallStars = overall ?? reaction.score;
    if (kDebugMode) {
      debugPrint('[MEAL RATING] ${checkin.checkinId} -> ${reaction.id} '
          'overall=$overallStars taste=$taste presentation=$presentation '
          'nutrition=$nutrition');
    }

    await _db.collection('meal_checkins').doc(checkin.checkinId).set({
      'status': 'reviewed',
      'reaction': reaction.id,
      // 1-10, matching the website. reaction.score is 1-5, so a 5-star meal
      // reads 10/10 on both clients instead of 5/10 on one of them.
      'score': overallStars * 2,
      'overallRating': overallStars,
      'tasteRating': taste,
      'presentationRating': presentation,
      'nutritionRating': nutrition,
      'comment': (comment?.trim().isEmpty ?? true) ? null : comment!.trim(),
      'reviewedAt': at.toIso8601String(),
      'reviewedBy': coachName,
    }, SetOptions(merge: true));

    await _notifyAthlete(checkin: checkin, reaction: reaction, comment: comment, coachName: coachName);
    // Push the verdict to the athlete's phone (see submit() for why this is a
    // backend call and why it is best-effort).
    try {
      await _api.post('/api/notifications/meal-review',
          body: {'checkinId': checkin.checkinId});
    } catch (e) {
      if (kDebugMode) debugPrint('[MEAL CHECKIN] review push trigger failed (non-fatal): $e');
    }
  }

  /// `POST /api/meal/estimate-nutrition` — the route that already exists.
  ///
  /// Takes the SAME prepared (decoded + normalized) bytes [submit] uploads,
  /// so this never independently re-reads the raw file and risks sending a
  /// format the backend rejects. Returns null on any failure. Deliberately
  /// swallows everything: this is a nice-to-have running in parallel with the
  /// upload, and the caller treats null as "not estimated".
  Future<Map<String, dynamic>?> _estimateNutrition(PreparedMealPhoto photo) async {
    try {
      final res = await _api.postMultipartBytes(
        '/api/meal/estimate-nutrition',
        fileField: 'file',
        fileName: photo.fileName,
        fileBytes: photo.bytes,
        contentType: photo.contentType,
        timeout: const Duration(seconds: 45),
      );
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return res.cast<String, dynamic>();
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[MEAL CHECKIN] nutrition estimate unavailable: $e');
      return null;
    }
  }

  Future<void> _notifyCoach(MealCheckin c) async {
    final at = DateTime.now();
    final stamp = at.millisecondsSinceEpoch;
    final name = c.athleteName ?? 'Your athlete';
    try {
      // Both records the website writes on this event, so the coach's existing
      // in-app toast AND their Notification Centre both fire.
      await _db.collection('coaching_notifications').doc('CN_${stamp}_meal').set({
        'id': 'CN_${stamp}_meal',
        'toId': c.coachId,
        'fromId': c.athleteId,
        'fromName': name,
        'text': '📸 $name submitted ${c.mealName} for review.',
        'type': 'meal_checkin',
        'createdAt': at.toIso8601String(),
        'read': false,
      });
      await _db.collection('notifications').doc('NTF_${stamp}_meal').set({
        'notificationId': 'NTF_${stamp}_meal',
        'userId': c.coachId,
        'title': '📷 $name submitted a meal',
        'message': '${c.mealName} — ${c.day ?? "today"}. Review pending.',
        'category': 'meal_snap',
        'icon': null,
        'type': 'meal_checkin',
        'action': 'expert_dashboard',
        'actionId': null,
        'expertId': null,
        'isRead': false,
        'priority': 'high',
        'createdAt': at.toIso8601String(),
      });
    } catch (e) {
      // The check-in is already saved. Losing a notification is worth a log,
      // not a failed submit the athlete would retry (and thereby double-post).
      if (kDebugMode) debugPrint('[MEAL CHECKIN] coach notification failed: $e');
    }
  }

  Future<void> _notifyAthlete({
    required MealCheckin checkin,
    required MealReaction reaction,
    required String coachName,
    String? comment,
  }) async {
    final at = DateTime.now();
    final stamp = at.millisecondsSinceEpoch;
    final trimmed = comment?.trim();
    try {
      await _db.collection('notifications').doc('NTF_${stamp}_mealrev').set({
        'notificationId': 'NTF_${stamp}_mealrev',
        'userId': checkin.athleteId,
        'title': '${reaction.icon} ${checkin.mealName} reviewed — ${reaction.label}',
        'message': (trimmed == null || trimmed.isEmpty)
            ? '$coachName reviewed your ${checkin.mealName.toLowerCase()}.'
            : trimmed,
        'category': 'meal_snap',
        'icon': null,
        'type': 'meal_reviewed',
        'action': 'diet',
        'actionId': null,
        'expertId': null,
        'isRead': false,
        'priority': 'high',
        'createdAt': at.toIso8601String(),
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[MEAL CHECKIN] athlete notification failed: $e');
    }
  }
}

/// Local coercion so a string from the vision model still parses.
num? asNumOrNull(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}
