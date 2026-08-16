import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../diet/models/diet_plan_content.dart';
import '../../expert_dashboard/models/expert_models.dart';
import '../../workout/models/workout_plan_content.dart';
import '../models/expert_listing.dart';

/// Why a coaching request was refused, in words an athlete can act on.
///
/// [code] is the backend's own machine-readable reason (`open_request_exists`,
/// `active_coaching_exists`, ...) so callers can branch without matching on
/// prose.
class CoachingRequestException implements Exception {
  const CoachingRequestException(this.message, {this.code});

  final String message;
  final String? code;

  /// False when retrying the exact same request cannot possibly succeed —
  /// the athlete has to change something first.
  bool get isRetryable => code == null;

  @override
  String toString() => message;
}

/// Athlete-side data access for the Expert marketplace/profile/review-request
/// system. Every collection and field name here was traced read-only from
/// `frontend/pages/coaches/coaches.js` and `frontend/pages/coaches/cprofile.js`
/// — no new collections (`experts`, `expert_certificates`, `review_requests`,
/// `personal_coach_requests`, `personal_coaching`, `chat_rooms` only), no
/// schema changes.
class ExpertsRepository {
  ExpertsRepository({
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
    ApiClient? apiClient,
  }) : _db = firestore,
       // ignore: prefer_initializing_formals
       _auth = auth,
       _api = apiClient ?? ApiClient() {
    _api.authTokenProvider = () async => _auth.currentUser?.getIdToken();
  }

  final FirebaseFirestore _db;
  // ignore: unused_field
  final FirebaseAuth _auth;
  final ApiClient _api;

  // ── Marketplace ────────────────────────────────────────────────────────

  /// `loadExpertsFromFirebase()` (coaches.js) — a one-time `.get()`, NOT a
  /// live listener; Firestore is the single source of truth for the expert
  /// list, no localStorage fallback (that cache only exists for the
  /// website's offline path and would just be empty here).
  /// Returns EVERY document in `experts` — including unapproved ones.
  ///
  /// This is the defect that puts test accounts in the production
  /// marketplace: signup writes `experts/{uid}` with `approved: false` and
  /// tells the applicant "your application is under review", the admin API
  /// flips the flag via `POST /api/admin/experts/approve`, and this read
  /// honours none of it.
  ///
  /// The gate is BUILT and TESTED — [ExpertListing.listedInMarketplace] —
  /// but deliberately NOT wired in here yet. Enabling it is a one-line
  /// change:
  ///
  ///     .where((e) => e.listedInMarketplace)
  ///
  /// It is held back because signup writes `approved: false` for every
  /// expert, so if the live experts were never run through the approve
  /// endpoint the filter would empty the marketplace rather than clean it.
  /// That has to be confirmed against production first — see the report
  /// accompanying this change.
  Future<List<ExpertListing>> fetchExperts() async {
    final snap = await _db.collection('experts').get();
    return snap.docs.map((d) => ExpertListing.fromMap(d.id, d.data())).toList();
  }

  /// `experts/{id}` single doc — `cprofile.js init()`'s primary lookup.
  /// Returns `null` when the doc genuinely doesn't exist (never falls back
  /// to a "first expert"/demo placeholder — a review sent to a nonexistent
  /// uid is unrecoverable).
  Future<ExpertListing?> fetchExpert(String expertId) async {
    final doc = await _db.collection('experts').doc(expertId).get();
    if (!doc.exists) return null;
    return ExpertListing.fromMap(doc.id, doc.data()!);
  }

  // ── Certificates ───────────────────────────────────────────────────────

  Stream<List<ExpertCertificate>> watchCertificates(String expertId) {
    return _db
        .collection('expert_certificates')
        .where('expertId', isEqualTo: expertId)
        // REQUIRED, not cosmetic. Security Rules evaluate a LIST against the
        // QUERY, not per returned document: a non-owner may read a cert only
        // when `verificationStatus == 'verified'`, and Firestore can only
        // prove that if the query itself constrains that field. Without this
        // line the whole listener fails with PERMISSION_DENIED and the
        // athlete sees no certificates at all. cprofile.js:103-105 carries
        // the identical pair of filters — this had simply been dropped in the
        // port. It also matches what this section claims to be: "Verified
        // Certificates".
        .where('verificationStatus', isEqualTo: 'verified')
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

  // ── Review requests (Verify Plan) ─────────────────────────────────────

  /// `_getAllMyPlanReviews(coach)` (cprofile.js:2418) — every review the
  /// current athlete has ever sent to this expert, newest first.
  Stream<List<ReviewRequest>> watchMyReviews({required String userId, required String expertId}) {
    return _db
        .collection('review_requests')
        .where('userId', isEqualTo: userId)
        .where('expertId', isEqualTo: expertId)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map((d) => ReviewRequest.fromMap(d.id, d.data())).toList();
          list.sort((a, b) {
            final ad = a.createdAt, bd = b.createdAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });
          return list;
        });
  }

  String newRequestId() => _db.collection('review_requests').doc().id;

  /// `initVerifyPlanBtn()`'s submit handler (cprofile.js:2964-3183) — builds
  /// the doc(s) via the pure, unit-testable [buildReviewRequestDocs], then
  /// writes each with the live Firestore server timestamp attached.
  Future<void> submitReviewRequest({
    required String userId,
    required String userName,
    required String expertId,
    required String expertName,
    required String expertRole,
    required String reviewType,
    required String serviceType,
    DietPlanContent? dietPlan,
    WorkoutPlanContent? workoutPlan,
    required Map<String, dynamic> assessmentData,
    required Map<String, dynamic> profileBasics,
    String? planId,
    num totalPrice = 0,
    bool isPremium = false,
    int nextVersion = 1,
  }) async {
    final docs = buildReviewRequestDocs(
      idFactory: newRequestId,
      userId: userId,
      userName: userName,
      expertId: expertId,
      expertName: expertName,
      expertRole: expertRole,
      reviewType: reviewType,
      serviceType: serviceType,
      dietPlanData: dietPlan?.toMap(),
      workoutPlanData: workoutPlan?.toMap(),
      assessmentData: assessmentData,
      profileBasics: profileBasics,
      planId: planId,
      totalPrice: totalPrice,
      isPremium: isPremium,
      nextVersion: nextVersion,
    );
    await Future.wait(docs.map((doc) => _db
        .collection('review_requests')
        .doc(doc['id'] as String)
        .set({...doc, 'serverTimestamp': FieldValue.serverTimestamp()})));
  }

  /// `withdrawConfirmBtn` handler (cprofile.js:2835-2903) — a Firestore
  /// transaction that only proceeds if the doc is still `pending` server-side
  /// at the moment of the write, so a withdrawal can never stomp a review the
  /// expert accepted moments earlier. Updates, never deletes.
  Future<bool> withdrawReview(String reviewId, {String? siblingId}) async {
    final docRef = _db.collection('review_requests').doc(reviewId);
    try {
      await _db.runTransaction((tx) async {
        final snap = await tx.get(docRef);
        if (!snap.exists) throw StateError('not_found');
        if (snap.data()?['status'] != 'pending') throw StateError('not_pending');
        tx.update(docRef, {'status': 'withdrawn', 'withdrawnAt': DateTime.now().toIso8601String()});
      });
    } catch (_) {
      return false;
    }
    if (siblingId != null && siblingId.isNotEmpty) {
      try {
        await _db.collection('review_requests').doc(siblingId).update({
          'status': 'withdrawn',
          'withdrawnAt': DateTime.now().toIso8601String(),
        });
      } catch (_) {
        // Sibling may not exist; the website swallows this too.
      }
    }
    return true;
  }

  // ── Personal coaching (athlete side) ──────────────────────────────────

  Stream<List<CoachingRequest>> watchMyCoachingRequests({
    required String userId,
    required String expertId,
  }) {
    return _db
        .collection('personal_coach_requests')
        .where('athleteId', isEqualTo: userId)
        .where('expertId', isEqualTo: expertId)
        .snapshots()
        .map((snap) {
          final list = snap.docs.map((d) => CoachingRequest.fromMap(d.id, d.data())).toList();
          list.sort((a, b) {
            final ad = a.createdAt, bd = b.createdAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });
          return list;
        });
  }

  /// `personal_coaching/{athleteUid}` — this athlete's single active
  /// relationship doc, keyed by athlete uid (ED:1315 comment: `coachId ==
  /// uid` on the expert side; on the athlete side the doc id IS the athlete
  /// uid, mirrored by `CoachingRelationship.fromMap`'s `id` fallback).
  Stream<CoachingRelationship?> watchMyCoachingRelationship(String userId) {
    return _db.collection('personal_coaching').doc(userId).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return null;
      return CoachingRelationship.fromMap(snap.id, data);
    });
  }

  /// `initPersonalCoaching()`'s submit handler — routes through the REAL
  /// backend escrow transaction (`POST /api/coaching/request`), not a direct
  /// Firestore write. The backend reserves the plan price out of the
  /// athlete's wallet (`paymentStatus: 'reserved'`, 48h `expiresAt`) inside
  /// a transaction and sends the "Request Sent" in-app notification — none
  /// of which a client-side write could reproduce correctly. `planLabel`/
  /// `isPremium`/exact `price` are also server-computed from the expert's
  /// own pricing, so this call only needs `expertId`/`planType`.
  Future<void> submitCoachingRequest({required String expertId, required String planType}) async {
    try {
      await _api.post('/api/coaching/request', body: {'expertId': expertId, 'planType': planType});
    } on ApiException catch (e) {
      // The backend's refusals are specific and mostly UNRETRYABLE — telling
      // an athlete who already has a pending request to "try again" sends
      // them round a loop that can only fail. Each one gets the sentence that
      // actually explains what to do next.
      throw CoachingRequestException(_messageFor(e), code: _codeOf(e));
    }
  }

  static String? _codeOf(ApiException e) {
    final body = e.body;
    if (body is! Map) return null;
    final detail = body['detail'];
    if (detail is String) return detail;
    if (detail is Map && detail['error'] is String) return detail['error'] as String;
    return null;
  }

  static String _messageFor(ApiException e) {
    final detail = (e.body is Map) ? (e.body as Map)['detail'] : null;
    switch (_codeOf(e)) {
      case 'open_request_exists':
        return 'You already have a coaching request awaiting a response. '
            'Withdraw it before requesting another coach.';
      case 'active_coaching_exists':
        return 'You already have an active personal coach. End that coaching '
            'before starting with someone else.';
      case 'expert_not_found':
        return "This coach isn't available right now. Please choose another.";
      case 'insufficient_balance':
        final required = (detail is Map) ? detail['required'] : null;
        return required == null
            ? "Your wallet doesn't have enough to reserve this plan."
            : "Your wallet doesn't have enough to reserve this plan (₹$required needed).";
      case 'invalid_plan_type':
        return 'That coaching plan is no longer offered. Please pick another.';
    }
    if (e.statusCode == 503) {
      return "Coaching isn't reachable right now. Please try again in a moment.";
    }
    return 'Could not send your request. Please try again.';
  }

  /// `POST /api/coaching/withdraw` — releases the wallet reservation via the
  /// same transactional path the expert's /reject uses, rather than a bare
  /// client-side status flip that would leave the athlete's money "stuck".
  Future<bool> withdrawCoachingRequest(String requestId) async {
    try {
      await _api.post('/api/coaching/withdraw', body: {'requestId': requestId});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `openEndCoachingModal()` confirm handler — athlete-initiated end of an
  /// active relationship.
  /// Ends the athlete's Personal Coaching.
  ///
  /// Routed through `POST /api/coaching/end` rather than writing Firestore
  /// directly, for two reasons the client cannot satisfy on its own: the
  /// change spans the relationship AND the originating request (which no
  /// client may write at all), and both parties must be notified. The backend
  /// does all of it inside one transaction.
  ///
  /// Access revocation needs no separate call — `isActiveCoachOf()` in
  /// firestore.rules gates every coach read on `status == 'active'`, so the
  /// coach loses the athlete's profile, plans, versions and meal photos the
  /// moment that field changes.
  Future<void> endCoaching(String athleteUid) async {
    try {
      await _api.post('/api/coaching/end');
    } on ApiException catch (e) {
      final detail = (e.body is Map) ? (e.body as Map)['detail'] : null;
      if (detail == 'no_coaching_relationship') {
        throw Exception('You do not have an active Personal Coach.');
      }
      // A 404/405 means the ROUTE is missing from the server that answered —
      // an unfinished deployment, not the athlete's network. Telling them to
      // check their connection would send them chasing a problem they cannot
      // fix and cannot see.
      if (e.statusCode == 404 || e.statusCode == 405) {
        throw Exception(
          "Ending coaching isn't available on the server yet. Please try again "
          'later, or contact support if it persists.',
        );
      }
      throw Exception(
        'Could not end your coaching just now. Please check your connection '
        'and try again.',
      );
    }
  }

  // ── Chat (Ask Expert) ──────────────────────────────────────────────────

  Stream<ChatRoom?> watchChatRoom(String chatId) {
    return _db.collection('chat_rooms').doc(chatId).snapshots().map((snap) {
      final data = snap.data();
      if (data == null) return null;
      return ChatRoom.fromMap(snap.id, data, '');
    });
  }

  Stream<List<ChatMessage>> watchMessages(String chatId) {
    return _db
        .collection('chat_rooms')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp')
        .snapshots()
        .map((snap) => snap.docs.map((d) => ChatMessage.fromMap(d.id, d.data())).toList());
  }

  /// Athlete-side mirror of `ExpertRepository.sendMessage` — same upsert
  /// pattern (`_edSyncChatMessageToFirestore`), `senderType: 'athlete'`.
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
      'senderId': athleteId,
      'senderType': 'athlete',
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

    // `ZitlasNotify.send()` equivalent — the expert's in-app Notification
    // Center (and bell badge) picks this up the same way it already does
    // for website-originated chat messages. Routes to the Expert Dashboard
    // (not the athlete-only `chat` action) since the recipient here is the
    // expert. Never blocks the send.
    final notifId = 'NTF_${now.millisecondsSinceEpoch}_msg';
    unawaited(_db.collection('notifications').doc(notifId).set({
      'notificationId': notifId,
      'userId': expertId,
      'title': '💬 New message from $athleteName',
      'message': text.length > 80 ? '${text.substring(0, 80)}…' : text,
      'category': 'chat',
      'icon': null,
      'type': 'chat_message',
      'action': 'expert_dashboard',
      'actionId': athleteId,
      'expertId': null,
      'isRead': false,
      'priority': 'high',
      'createdAt': now.toIso8601String(),
    }).catchError((_) {}));
  }

  /// `chat_<athleteId>_<expertId>` — the deterministic room id used
  /// throughout cprofile.js's `openChatOverlay()`.
  String chatIdFor({required String athleteId, required String expertId}) =>
      'chat_${athleteId}_$expertId';
}

/// `initVerifyPlanBtn()`'s submit handler (cprofile.js:2964-3183), extracted
/// as a pure function (no Firestore) so the doc-shape/bundle logic is
/// unit-testable: one doc for `diet`/`workout`/`chat_only`, two linked docs
/// for `both` (primary carries the full price, secondary carries ₹0 and
/// mirrors the primary's `bundleId`/`siblingId`).
List<Map<String, dynamic>> buildReviewRequestDocs({
  required String Function() idFactory,
  required String userId,
  required String userName,
  required String expertId,
  required String expertName,
  required String expertRole,
  required String reviewType,
  required String serviceType,
  Map<String, dynamic>? dietPlanData,
  Map<String, dynamic>? workoutPlanData,
  required Map<String, dynamic> assessmentData,
  required Map<String, dynamic> profileBasics,
  String? planId,
  num totalPrice = 0,
  bool isPremium = false,
  int nextVersion = 1,
  DateTime? now,
}) {
  final nowStr = (now ?? DateTime.now()).toIso8601String();

  Map<String, dynamic> baseDoc({
    required String id,
    required String type,
    required Map<String, dynamic>? planData,
    required num price,
    String? bundleId,
    String? bundleRole,
    String? siblingId,
  }) {
    return {
      'id': id,
      'userId': userId,
      'athleteName': userName,
      'userName': userName,
      'expertId': expertId,
      'expertName': expertName,
      'expertRole': expertRole,
      'reviewType': type,
      'version': nextVersion,
      'planId': planId,
      'planData': planData,
      'assessmentData': assessmentData,
      'profileBasics': profileBasics,
      'serviceType': serviceType,
      'totalPrice': price,
      'isPremium': isPremium,
      'paymentStatus': 'unpaid',
      'bundleId': bundleId,
      'bundleRole': bundleRole,
      'siblingId': siblingId,
      'status': 'pending',
      'createdAt': nowStr,
      'submittedAt': nowStr,
      'completedAt': null,
    };
  }

  if (reviewType == 'chat_only') {
    final id = idFactory();
    return [baseDoc(id: id, type: 'chat_only', planData: null, price: totalPrice)];
  }

  if (reviewType == 'both') {
    final dietId = idFactory();
    final workoutId = idFactory();
    final bundleId = 'BND_${(now ?? DateTime.now()).millisecondsSinceEpoch}';
    return [
      baseDoc(
        id: dietId,
        type: 'diet',
        planData: dietPlanData,
        price: totalPrice,
        bundleId: bundleId,
        bundleRole: 'primary',
        siblingId: workoutId,
      ),
      baseDoc(
        id: workoutId,
        type: 'workout',
        planData: workoutPlanData,
        price: 0,
        bundleId: bundleId,
        bundleRole: 'secondary',
        siblingId: dietId,
      ),
    ];
  }

  final id = idFactory();
  final planData = reviewType == 'diet' ? dietPlanData : workoutPlanData;
  return [baseDoc(id: id, type: reviewType, planData: planData, price: totalPrice)];
}
