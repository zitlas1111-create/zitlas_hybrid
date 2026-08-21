import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/expert_models.dart';

/// Outcome of an accept/decline call to the coaching backend. The website
/// distinguishes a 409 ("already handled") from a generic failure
/// (ED:1544-1553), so the UI can too.
enum CoachingActionResult { success, alreadyHandled, failed }

/// Data access for the Expert Dashboard.
///
/// Every collection path, field name, query filter and endpoint here was
/// traced from `frontend/pages/experts/expert-dashboard.js` — no new
/// collections, no schema changes. Privileged operations (coaching
/// accept/reject, account deactivation) go through the existing FastAPI
/// backend with a Firebase ID token exactly as the website does; they are
/// deliberately NOT done as client Firestore writes (ED:1523-1528).
class ExpertRepository {
  ExpertRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
    ApiClient? apiClient,
  }) : _db = firestore,
       // ignore: prefer_initializing_formals
       _auth = auth,
       _api = apiClient ?? ApiClient() {
    // Always mint a fresh ID token per request rather than caching one.
    _api.authTokenProvider = () async => _auth.currentUser?.getIdToken();
  }

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final ApiClient _api;

  // ── Profile ────────────────────────────────────────────────────────────

  /// `experts/{uid}` — live, so an edit made anywhere reflects immediately.
  Stream<ExpertProfile?> watchProfile(String uid) {
    return _db.collection('experts').doc(uid).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return null;
      return ExpertProfile.fromMap(uid, data);
    });
  }

  /// Self-heal: the website writes a minimal `experts/{uid}` doc when an
  /// authenticated expert has none (ED:5158-5173). `verified`/`approved`
  /// are deliberately omitted — Firestore rules reserve them for the
  /// backend, and including them would make the write fail.
  Future<void> ensureExpertDoc(String uid, {String? name, String? email, String? photo}) {
    return _db.collection('experts').doc(uid).set({
      'uid': uid,
      'email': email ?? '',
      'name': name ?? 'Expert',
      'role': 'expert',
      'speciality': '',
      'photo': photo ?? '',
      'rating': 0,
      'reviews': 0,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// `saveProfile()` (ED:2743) — merge-write of the editable field set only.
  Future<void> saveProfile(String uid, ExpertProfile profile) {
    return _db.collection('experts').doc(uid).set(
      profile.toEditableMap(),
      SetOptions(merge: true),
    );
  }

  // ── Reviews inbox ──────────────────────────────────────────────────────

  /// `review_requests` where `expertId == uid`. No `orderBy` — the website
  /// avoids the composite index and sorts client-side (ED:940), so we do
  /// the same: newest first by `createdAt`.
  Stream<List<ReviewRequest>> watchReviewRequests(String uid) {
    return _db
        .collection('review_requests')
        .where('expertId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map((d) => ReviewRequest.fromMap(d.id, d.data())).toList();
          list.sort((a, b) {
            // isPremium first, then newest (ED:4596-4600).
            if (a.isPremium != b.isPremium) return a.isPremium ? -1 : 1;
            final ad = a.createdAt, bd = b.createdAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });
          return list;
        });
  }

  /// `_prAcceptReview` fallback path (ED:4732) — the direct status update
  /// used when the payment service isn't involved. Charging is handled
  /// server-side by `/api/payment/charge`; see [chargeForReview].
  Future<void> acceptReview(
    String reviewId, {
    required String expertId,
    String? chatId,
    bool chatUnlocked = true,
  }) {
    return _db.collection('review_requests').doc(reviewId).update({
      'status': ReviewStatus.inProgress,
      'acceptedAt': DateTime.now().toIso8601String(),
      'expertId': expertId,
      'chatId': ?chatId,
      'chatUnlocked': chatUnlocked,
    });
  }

  /// `POST /api/payment/charge` — the same escrow charge the website's
  /// `ZitlasPayment.attemptCharge()` performs on accept (payment-service.js:144).
  /// Returns null on success, or the backend's error code (e.g.
  /// `insufficient_balance`) so the UI can react like the website does.
  Future<String?> chargeForReview({
    required String athleteUid,
    required String requestId,
    required num amount,
    required String serviceType,
    required String serviceLabel,
    required String expertId,
    required String expertName,
    String? siblingRequestId,
    Map<String, dynamic>? onSuccessUpdate,
  }) async {
    try {
      final res = await _api.post('/api/payment/charge', body: {
        'athleteUid': athleteUid,
        'requestCollection': 'review_requests',
        'requestId': requestId,
        'amount': amount,
        'serviceType': serviceType,
        'serviceLabel': serviceLabel,
        'expertId': expertId,
        'expertName': expertName,
        'siblingRequestId': ?siblingRequestId,
        'onSuccessUpdate': ?onSuccessUpdate,
      });
      if (res is Map && res['success'] == true) return null;
      return (res is Map ? res['error'] as String? : null) ?? 'charge_failed';
    } on ApiException catch (e) {
      final body = e.body;
      if (body is Map && body['error'] is String) return body['error'] as String;
      return 'charge_failed';
    }
  }

  /// `_prRejectReview` (ED:4802) — also mirrors onto the bundled sibling,
  /// exactly as the website does.
  Future<void> rejectReview(String reviewId, {String? siblingId}) async {
    final payload = {
      'status': ReviewStatus.rejected,
      'rejectedAt': DateTime.now().toIso8601String(),
    };
    await _db.collection('review_requests').doc(reviewId).update(payload);
    if (siblingId != null && siblingId.isNotEmpty) {
      try {
        await _db.collection('review_requests').doc(siblingId).update(payload);
      } catch (_) {
        // Sibling may not exist; the website swallows this too.
      }
    }
  }

  /// `_prCompleteReviewFromChat` (ED:4921) — marks a review finished so the
  /// athlete sees it as reviewed.
  Future<void> completeReview(
    String reviewId, {
    required String expertId,
    required String expertName,
  }) async {
    // Idempotent, same as the plan-editor completions — see [_completeOnce].
    await _completeOnce(reviewId, (now) => {
          'status': ReviewStatus.reviewCompleted,
          'reviewedAt': now,
          'completedAt': now,
          'expertName': expertName,
          'expertId': expertId,
        });
  }

  // ── Diet/Workout review editing (modify-diet.html / modify-workout.html) ─

  /// The raw `review_requests/{id}` doc — needed for editing since
  /// `ReviewRequest` only carries inbox-summary fields, not `planData`.
  Future<Map<String, dynamic>?> fetchReviewRaw(String reviewId) async {
    final doc = await _db.collection('review_requests').doc(reviewId).get();
    return doc.data();
  }

  /// `savePlanEdits()` (expert-dashboard.js) / modify-diet.js's save —
  /// writes the expert-edited diet plan back onto the SAME `review_requests`
  /// doc the athlete's `DietController.acceptExpertReview()` already knows
  /// how to consume: `reviewedDietPlan` (full plan snapshot, edited meals
  /// carry `_edited: true`) + `mealChangeHistory` (the diff, read first) +
  /// `status: review_completed`. No new collection, no schema change.
  Future<void> submitDietReview({
    required String reviewId,
    required Map<String, dynamic> reviewedDietPlan,
    required List<Map<String, dynamic>> mealChangeHistory,
    required String expertId,
    required String expertName,
    String? expertNotes,
    String? athleteId,
  }) async {
    final applied = await _completeOnce(reviewId, (now) => {
          'status': ReviewStatus.reviewCompleted,
          'reviewedDietPlan': reviewedDietPlan,
          'mealChangeHistory': mealChangeHistory,
          'expertId': expertId,
          'expertName': expertName,
          'expertNotes': ?expertNotes,
          'reviewedAt': now,
          'completedAt': now,
        });
    // Only notify when THIS call is the one that completed the review —
    // otherwise a retry or a second device would send the athlete a duplicate
    // "your plan was reviewed" notification.
    if (applied && athleteId != null) {
      unawaited(_notifyReviewCompleted(athleteId: athleteId, expertName: expertName, action: 'diet'));
    }
  }

  /// Applies a completion payload EXACTLY ONCE.
  ///
  /// Runs in a transaction that re-reads the review first and no-ops when it
  /// is already `review_completed`. This is the last line of defence behind
  /// the UI's re-entry guards: a retry after a timeout, a second device, or a
  /// resumed app must never produce a second completion — which would
  /// overwrite `completedAt`, re-fire the athlete's notification, and (for a
  /// plan review) clobber an already-accepted plan snapshot.
  ///
  /// Returns whether this call is the one that performed the write.
  Future<bool> _completeOnce(
    String reviewId,
    Map<String, dynamic> Function(String nowIso) payload,
  ) async {
    final ref = _db.collection('review_requests').doc(reviewId);
    return _db.runTransaction<bool>((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) return false;
      if (snap.data()?['status'] == ReviewStatus.reviewCompleted) return false;
      txn.update(ref, payload(DateTime.now().toIso8601String()));
      return true;
    });
  }

  /// `ZitlasNotify.send()` equivalent for review completion — matches
  /// `review-sync.js`'s real event (website-originated reviews already
  /// notify this way; this closes the gap for reviews completed through
  /// this native editor).
  Future<void> _notifyReviewCompleted({required String athleteId, required String expertName, required String action}) {
    final now = DateTime.now();
    final id = 'NTF_${now.millisecondsSinceEpoch}_review';
    return _db.collection('notifications').doc(id).set({
      'notificationId': id,
      'userId': athleteId,
      'title': '⭐ $expertName reviewed your plan',
      'message': 'Your ${action == 'training' ? 'training' : 'diet'} plan has been reviewed — tap to see what changed.',
      'category': 'review',
      'icon': null,
      'type': 'review_completed',
      'action': action,
      'actionId': null,
      'expertId': null,
      'isRead': false,
      'priority': 'high',
      'createdAt': now.toIso8601String(),
    }).catchError((_) {});
  }

  /// Workout mirror of [submitDietReview] — `workoutChangeHistory` is the
  /// field `WorkoutController._maybeAutoSyncReview()` reads to auto-apply
  /// the change on the athlete's Training page (that page has no explicit
  /// "Accept" button by website design).
  Future<void> submitWorkoutReview({
    required String reviewId,
    required Map<String, dynamic> reviewedWorkoutPlan,
    required List<Map<String, dynamic>> workoutChangeHistory,
    required String expertId,
    required String expertName,
    String? expertNotes,
    String? athleteId,
  }) async {
    final applied = await _completeOnce(reviewId, (now) => {
          'status': ReviewStatus.reviewCompleted,
          'reviewedWorkoutPlan': reviewedWorkoutPlan,
          'workoutChangeHistory': workoutChangeHistory,
          'expertId': expertId,
          'expertName': expertName,
          'expertNotes': ?expertNotes,
          'reviewedAt': now,
          'completedAt': now,
        });
    if (applied && athleteId != null) {
      unawaited(_notifyReviewCompleted(athleteId: athleteId, expertName: expertName, action: 'training'));
    }
  }

  // ── Athlete profile (View Athlete Profile) ────────────────────────────

  /// `users/{athleteId}` narrowed to what an expert is authorized to see:
  /// goal, assessment survey, calculations/targets, SWOT, and the current
  /// Diet/Workout plan wrappers — the same fields `cprofile.js`'s
  /// `buildContextPackage()` sends TO an expert on request submission, so
  /// this is not new exposure, just a live read of the same data.
  Stream<Map<String, dynamic>?> watchAthleteProfile(String athleteId) {
    return _db.collection('users').doc(athleteId).snapshots().map((s) => s.data());
  }

  // ── Personal coaching ──────────────────────────────────────────────────

  // ── Private coach notes ────────────────────────────────────────────────

  /// The coach's own working notes on one athlete.
  ///
  /// Stored at `experts/{coachId}/athlete_notes/{athleteId}` — under the
  /// COACH, not the athlete. `coaching_plans/{athleteUid}` is readable by the
  /// athlete, so a note kept there would be visible to the person it is about.
  /// Security Rules grant this subcollection to its owner alone.
  Stream<String?> watchCoachNote({required String coachId, required String athleteId}) {
    return _db
        .collection('experts')
        .doc(coachId)
        .collection('athlete_notes')
        .doc(athleteId)
        .snapshots()
        .map((s) => s.data()?['note'] as String?);
  }

  Future<void> saveCoachNote({
    required String coachId,
    required String athleteId,
    required String note,
  }) {
    return _db
        .collection('experts')
        .doc(coachId)
        .collection('athlete_notes')
        .doc(athleteId)
        .set({
      'note': note,
      'athleteId': athleteId,
      'updatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// `personal_coach_requests` where `expertId == uid` (ED:1399).
  Stream<List<CoachingRequest>> watchCoachingRequests(String uid) {
    return _db
        .collection('personal_coach_requests')
        .where('expertId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map((d) => CoachingRequest.fromMap(d.id, d.data())).toList();
          list.sort((a, b) {
            if (a.isPremium != b.isPremium) return a.isPremium ? -1 : 1;
            final ad = a.createdAt, bd = b.createdAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });
          return list;
        });
  }

  /// `personal_coaching` where `coachId == uid` (ED:1315) — the expert's
  /// active coaching relationships ("My Users").
  Stream<List<CoachingRelationship>> watchCoachingRelationships(String uid) {
    return _db
        .collection('personal_coaching')
        .where('coachId', isEqualTo: uid)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => CoachingRelationship.fromMap(d.id, d.data())).toList());
  }

  /// `_pcUpdateRequestStatus` (ED:1529-1559) — server-authoritative accept
  /// and decline. The client never writes these Firestore docs itself.
  Future<CoachingActionResult> respondToCoachingRequest({
    required String requestId,
    required bool accept,
  }) async {
    final endpoint = accept ? '/api/coaching/accept' : '/api/coaching/reject';
    try {
      final res = await _api.post(endpoint, body: {'requestId': requestId});
      if (res is Map && res['success'] == true) return CoachingActionResult.success;
      return CoachingActionResult.failed;
    } on ApiException catch (e) {
      if (e.statusCode == 409) return CoachingActionResult.alreadyHandled;
      return CoachingActionResult.failed;
    } catch (_) {
      return CoachingActionResult.failed;
    }
  }

  // ── Chats ──────────────────────────────────────────────────────────────

  /// `chat_rooms` where `participants` array-contains uid (ED:1582).
  Stream<List<ChatRoom>> watchChatRooms(String uid) {
    return _db
        .collection('chat_rooms')
        .where('participants', arrayContains: uid)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map((d) => ChatRoom.fromMap(d.id, d.data(), uid)).toList();
          list.sort((a, b) {
            final ad = a.lastMessageAt, bd = b.lastMessageAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });
          return list;
        });
  }

  /// `chat_rooms/{id}/messages` ordered by `timestamp` (ED:1237).
  Stream<List<ChatMessage>> watchMessages(String chatId) {
    return _db
        .collection('chat_rooms')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp')
        .snapshots()
        .map((snap) => snap.docs.map((d) => ChatMessage.fromMap(d.id, d.data())).toList());
  }

  /// `_edSyncChatMessageToFirestore` (ED:197-225): upsert the room doc
  /// (merge) then write the message at a deterministic id — an idempotent
  /// `doc(id).set()`, not `add()`, exactly as the website does.
  Future<void> sendMessage({
    required String chatId,
    required String expertId,
    required String expertName,
    required String athleteId,
    required String athleteName,
    required String text,
    String? imageUrl,
  }) async {
    final now = DateTime.now();
    final messageId = 'msg_${now.millisecondsSinceEpoch}_${now.microsecond}';
    final payload = {
      'id': messageId,
      'conversationId': chatId,
      'senderId': expertId,
      'senderType': 'expert',
      'text': text,
      'type': imageUrl != null ? 'image' : 'text',
      'imageUrl': ?imageUrl,
      'timestamp': now.toIso8601String(),
    };

    final roomRef = _db.collection('chat_rooms').doc(chatId);
    await roomRef.set({
      'participants': [expertId, athleteId],
      'athleteId': athleteId,
      'athleteName': athleteName,
      'expertId': expertId,
      'expertName': expertName,
      'lastMessage': text,
      'lastMessageAt': now.toIso8601String(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await roomRef.collection('messages').doc(messageId).set(payload);

    // `ZitlasNotify.send()` equivalent for the athlete's in-app Notification
    // Center — `action: 'chat', actionId: expertId` matches
    // `navigateForAction()`'s exact mapping (opens this expert's profile
    // with the Ask Expert chat overlay). Never blocks the send.
    final notifId = 'NTF_${now.millisecondsSinceEpoch}_msg';
    unawaited(_db.collection('notifications').doc(notifId).set({
      'notificationId': notifId,
      'userId': athleteId,
      'title': '💬 New message from $expertName',
      'message': text.length > 80 ? '${text.substring(0, 80)}…' : text,
      'category': 'chat',
      'icon': null,
      'type': 'chat_message',
      'action': 'chat',
      'actionId': expertId,
      'expertId': expertId,
      'isRead': false,
      'priority': 'high',
      'createdAt': now.toIso8601String(),
    }).catchError((_) {}));
  }

  // ── Certificates ───────────────────────────────────────────────────────

  /// `expert_certificates` where `expertId == uid` (certificate-manager.js:239),
  /// newest first.
  Stream<List<ExpertCertificate>> watchCertificates(String uid) {
    return _db
        .collection('expert_certificates')
        .where('expertId', isEqualTo: uid)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map((d) => ExpertCertificate.fromMap(d.id, d.data())).toList();
          list.sort((a, b) {
            final ad = a.uploadedAt, bd = b.uploadedAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });
          return list;
        });
  }

  // ── Notifications ──────────────────────────────────────────────────────

  /// `notification-center.js`'s `listenUnreadCount` (line 116).
  Stream<int> watchUnreadNotificationCount(String uid) {
    return _db
        .collection('notifications')
        .where('userId', isEqualTo: uid)
        .where('isRead', isEqualTo: false)
        .snapshots()
        .map((snap) => snap.size);
  }

  // ── Account ────────────────────────────────────────────────────────────

  /// `_deaDeleteAccountPermanently` (ED:3229-3302). The backend deletes
  /// `experts/{uid}`, downgrades `users/{uid}` and revokes the expert claim;
  /// reviews/certificates/chats are preserved server-side by design.
  /// Returns true when the backend confirmed the deactivation.
  Future<bool> deactivateAccount(String uid) async {
    // Safety gate mirroring ED:3247 — refuse unless this really is an expert.
    final doc = await _db.collection('experts').doc(uid).get();
    if (!doc.exists || doc.data()?['role'] != 'expert') return false;

    try {
      final res = await _api.post('/api/admin/experts/deactivate', body: {'expertId': uid});
      return res is Map && res['success'] == true;
    } catch (_) {
      return false;
    }
  }
}
