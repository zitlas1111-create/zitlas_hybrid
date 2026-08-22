import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../expert_dashboard/models/expert_models.dart' show ExpertProfile;
import '../models/diet_calculations.dart';
import '../models/diet_plan_content.dart';
import '../models/diet_review_request.dart';
import '../models/diet_storage.dart';
import '../models/swap_result.dart';

/// Firestore + backend access for the Diet feature. Every collection path
/// and field name here was traced from `frontend/pages/diet/diet.js`,
/// `frontend/assets/js/cloud-sync.js`, and
/// `frontend/pages/experts/modify-diet.js` — no new collections, no schema
/// changes. See docs/MIGRATION_INVENTORY.md for the full audit.
class DietRepository {
  DietRepository({
    required FirebaseFirestore firestore,
    ApiClient? apiClient,
    FirebaseAuth? auth,
  }) : _db = firestore,
       // Nullable by design so the repo can fall back to
       // FirebaseAuth.instance lazily, matching role_repository.
       // ignore: prefer_initializing_formals
       _auth = auth,
       _api = apiClient ?? ApiClient() {
    // EVERY backend call from this repository carries the athlete's ID
    // token. `/api/diet/swap` meters swaps per week against the verified
    // uid (free 70, premium unlimited) and now REJECTS a tokenless request
    // outright — without this the app could not swap at all, and before the
    // backend was tightened it swapped without ever being counted.
    _api.authTokenProvider ??= () async {
      try {
        return await (_auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  final FirebaseFirestore _db;
  final ApiClient _api;
  final FirebaseAuth? _auth;

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _db.collection('users').doc(uid);

  /// Live `users/{uid}` doc, narrowed to the fields Diet needs: `dietPlan`
  /// (the wrapper), `planId` (goal-identity stamp), `calculations`
  /// (targets), and `dietPlanMaster` (recovery snapshot) — all on the same
  /// doc, so one listener covers everything `cloud-sync.js`'s
  /// `attachRealtime()` would keep live for Diet.
  Stream<Map<String, dynamic>?> watchUserDoc(String uid) {
    return _userDoc(uid).snapshots().map((snap) => snap.data());
  }

  /// `saveDietStorage()` on the website (diet.js:331-334) — the single
  /// write path, always both the wrapper and a fresh `lastUpdated`.
  Future<void> saveDietStorage(String uid, DietStorage storage) {
    return _userDoc(uid).set({
      'dietPlan': storage.toMap(),
      'dietPlanUpdatedAt': DateTime.now().toIso8601String(),
    }, SetOptions(merge: true));
  }

  /// Explicit clear — mirrors `discardDietStorage()` (diet.js:280-286),
  /// used when a stored wrapper fails the `planId` fail-closed check.
  Future<void> discardDietStorage(String uid) {
    return _userDoc(uid).set({'dietPlan': null}, SetOptions(merge: true));
  }

  /// `review_requests` where `userId == uid && reviewType == 'diet'`. No
  /// `orderBy` — same reasoning as the website (diet.js/expert-dashboard.js
  /// both avoid the composite index requirement and sort client-side).
  Stream<List<DietReviewRequest>> watchDietReviews(String uid) {
    return _db
        .collection('review_requests')
        .where('userId', isEqualTo: uid)
        .where('reviewType', isEqualTo: 'diet')
        .snapshots()
        .map((snap) {
          final list =
              snap.docs.map((d) => DietReviewRequest.fromMap(d.id, d.data())).toList();
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

  /// `submitVerifyRequest()` (diet.js:1617+) — the exact `review_requests`
  /// doc shape the Expert Dashboard's Reviews Inbox already reads.
  Future<void> submitReviewRequest({
    required String reviewId,
    required String userId,
    required String userName,
    required String expertId,
    required String expertName,
    required String expertRole,
    required DietPlanContent planData,
    required Map<String, dynamic> assessmentData,
    required Map<String, dynamic> profileBasics,
    Map<String, dynamic>? goal,
    String? planId,
    num totalPrice = 0,
    bool isPremium = false,
  }) {
    final now = DateTime.now().toIso8601String();
    return _db.collection('review_requests').doc(reviewId).set({
      'id': reviewId,
      'userId': userId,
      'athleteId': userId,
      'athleteName': userName,
      'userName': userName,
      'athlete_name': userName,
      'expertId': expertId,
      'expertName': expertName,
      'expertRole': expertRole,
      'reviewType': 'diet',
      'planData': planData.toMap(),
      'assessmentData': assessmentData,
      'profileBasics': profileBasics,
      'goal': goal,
      'planId': planId,
      'serviceType': 'verification',
      'totalPrice': totalPrice,
      'fee': totalPrice,
      'isPremium': isPremium,
      'paymentStatus': 'unpaid',
      'status': 'pending',
      'createdAt': now,
      'submittedAt': now,
      'completedAt': null,
      'serverTimestamp': FieldValue.serverTimestamp(),
    });
  }

  /// `POST /api/diet/swap` — the DETERMINISTIC swap engine.
  ///
  /// Migrated off `/api/ai/swap-meal`, which routed every swap through an LLM
  /// for ~12 seconds to produce a food the engine had already chosen in 4ms.
  /// The model contributed an optional display name and a tips array; the
  /// engine's `find_swap_combos()` output was substituted over everything
  /// else it wrote. Removing it costs nothing and returns ~50x the speed.
  ///
  /// Returns the engine's top-N ranked options verbatim — this method does no
  /// re-ranking, filtering, or truncation, so what Flutter shows is exactly
  /// what `find_swap_combos()` produced.
  Future<SwapResult> swapMeal({
    required String mealName,
    required String? mealTime,
    required List<String> currentFoods,
    required String reason,
    required Map<String, dynamic> userProfile,
    required Map<String, dynamic> lifestyleData,
    required List<String> rejectedFoods,
    required List<Map<String, dynamic>> previousSuggestions,
    required String fitnessGoal,
    List<String> todaysFoods = const [],
    int options = 5,
  }) async {
    final previousFoodNames = previousSuggestions
        .map((s) => (s['foods'] is List
            ? (s['foods'] as List).map((e) => e.toString()).toList()
            : <String>[]))
        .toList();

    try {
      final res = await _api.post(
        '/api/diet/swap',
        // No LLM in this path — the engine answers in milliseconds. The budget
        // only needs to cover transport.
        timeout: const Duration(seconds: 20),
        body: {
          'meal_name': mealName,
          'meal_time': mealTime ?? '',
          'current_foods': currentFoods,
          'reason': reason,
          'user_profile': userProfile,
          'lifestyle_data': lifestyleData,
          'rejected_foods': rejectedFoods,
          'previous_suggestions': previousFoodNames,
          'fitness_goal': fitnessGoal,
          'todays_foods': todaysFoods,
          'options': options,
        },
      );

      if (res is! Map) {
        throw FormatException('Unexpected swap response: ${res.runtimeType}');
      }
      return SwapResult.fromMap(res.cast<String, dynamic>());
    } on ApiException catch (e) {
      // The deterministic endpoint is missing on this server.
      //
      // 404 = route genuinely absent. 405 = the request fell through to the
      // static-file mount at "/", which only answers GET/HEAD — that is what
      // a POST to an undeployed API path looks like from outside, and it is
      // indistinguishable from a routing bug unless you know to expect it.
      //
      // The app ships ahead of the backend, so rather than showing "Swap is
      // broken" until a deploy lands, fall back to the older LLM endpoint,
      // which is still live. Slower and single-option, but it works, and this
      // path disappears on its own the moment /api/diet/swap is deployed.
      if (e.statusCode != 404 && e.statusCode != 405) rethrow;
      if (kDebugMode) {
        debugPrint('[SWAP] /api/diet/swap unavailable (${e.statusCode}) — '
            'falling back to /api/ai/swap-meal. Deploy the backend to get '
            'the 5-option deterministic engine.');
      }
      return _legacySwap(
        mealName: mealName,
        mealTime: mealTime,
        currentFoods: currentFoods,
        reason: reason,
        userProfile: userProfile,
        lifestyleData: lifestyleData,
        rejectedFoods: rejectedFoods,
        previousFoodNames: previousFoodNames,
        fitnessGoal: fitnessGoal,
      );
    }
  }

  /// Legacy `/api/ai/swap-meal` adapted into [SwapResult].
  ///
  /// That endpoint runs the SAME `food_engine.find_swap_combos()` under an LLM
  /// wrapper, so the foods are already engine-chosen — it simply returns at
  /// most two of them (`swap` + `alternative`) and takes ~12s. Mapping it to
  /// the same result type keeps the UI code identical on both paths.
  Future<SwapResult> _legacySwap({
    required String mealName,
    required String? mealTime,
    required List<String> currentFoods,
    required String reason,
    required Map<String, dynamic> userProfile,
    required Map<String, dynamic> lifestyleData,
    required List<String> rejectedFoods,
    required List<List<String>> previousFoodNames,
    required String fitnessGoal,
  }) async {
    final res = await _api.post(
      '/api/ai/swap-meal',
      // This path DOES call an LLM behind a provider-failover chain.
      timeout: const Duration(seconds: 60),
      body: {
        'meal_name': mealName,
        'meal_time': mealTime ?? '',
        'current_foods': currentFoods,
        'reason': reason,
        'user_profile': userProfile,
        'lifestyle_data': lifestyleData,
        'rejected_foods': rejectedFoods,
        'previous_suggestions': previousFoodNames,
        'fitness_goal': fitnessGoal,
      },
    );

    final structured = (res is Map ? res['structured'] : null);
    if (structured is! Map) {
      throw FormatException('Unexpected legacy swap response: ${res.runtimeType}');
    }

    final options = <Map<String, dynamic>>[];
    for (final key in ['swap', 'alternative']) {
      final block = structured[key];
      if (block is Map) options.add(block.cast<String, dynamic>());
    }

    return SwapResult.fromMap({
      'options': options,
      'relaxed_match': false,
      // Told plainly rather than dressed up — on this path there are fewer
      // choices and no nutrition-band guarantee.
      'match_note': 'Limited options (server update pending)',
      'llm_used': true,
    });
  }

  /// Sourced directly from the `experts` collection (approved-only) rather
  /// than the website's `zitlas_nutritionists` localStorage cache — that
  /// cache is only populated by browsing the Experts marketplace page,
  /// which is still a placeholder in this app. Reading the same
  /// authoritative collection the marketplace itself reads from is more
  /// robust, not a schema change.
  Future<List<ExpertProfile>> fetchApprovedExperts({int limit = 10}) async {
    final snap = await _db
        .collection('experts')
        .where('approved', isEqualTo: true)
        .limit(limit)
        .get();
    return snap.docs.map((d) => ExpertProfile.fromMap(d.id, d.data())).toList();
  }

  /// Fresh Firestore-generated id for a new `review_requests` doc — mirrors
  /// the website's `crypto.randomUUID()`-style client-generated id, just
  /// sourced from the SDK instead.
  String newReviewRequestId() => _db.collection('review_requests').doc().id;

  /// Stamps `athleteAccepted: true` on the review doc once the athlete has
  /// applied its changes locally (`acceptExpertPlan()` does the same on
  /// the website) — suppresses the accept banner on future renders.
  Future<void> markReviewAccepted(String reviewId) {
    return _db.collection('review_requests').doc(reviewId).update({'athleteAccepted': true});
  }

  DietCalculations parseCalculations(Map<String, dynamic>? userDoc) {
    return DietCalculations.fromMap(
      (userDoc?['calculations'] as Map?)?.cast<String, dynamic>(),
    );
  }
}
