import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../diet/models/diet_plan_content.dart';
import '../expert_dashboard/models/expert_models.dart';
import '../workout/models/workout_plan_content.dart';
import 'data/expert_rating_repository.dart';
import 'data/experts_repository.dart';
import 'models/expert_listing.dart';
import 'models/expert_rating.dart';

/// `_VP_ACTIVE_STATUSES` / `_VP_TERMINAL_RENDERED` (cprofile.js:2380-2384) —
/// a fail-closed WHITELIST, not a blocklist. Anything not explicitly listed
/// (withdrawn, superseded, dismissed, declined, expired, cancelled, or any
/// future status the backend introduces) degrades to the idle "Request
/// Review" state rather than getting stuck. A prior blocklist implementation
/// on the website caused a permanently-stuck "Under Review" UI once Goal
/// Reset started writing a `'dismissed'` status that predated it — never
/// repeat that mistake here.
const _activeStatuses = ['pending', 'accepted', 'in_progress', 'expert_reviewing'];
const _terminalRendered = ['completed', 'review_completed', 'rejected'];

enum VerifyButtonState {
  requestReview,
  pendingWithdraw,
  awaitingPayment,
  chatWithExpert,
  inProgress,
  completed,
  rejected,
}

class VerifyButtonInfo {
  const VerifyButtonInfo({required this.state, required this.label, this.review});
  final VerifyButtonState state;
  final String label;
  final ReviewRequest? review;
}

/// `_getMyLatestPlanReview(coach)` (cprofile.js:2437-2452), extracted as a
/// pure function so the fail-closed whitelist can be unit-tested without a
/// live Firestore instance. Prefers an ACTIVE-status doc over a terminal
/// one; within each group, the first match wins (callers pass reviews
/// newest-first).
ReviewRequest? latestReviewOfTypePure(List<ReviewRequest> reviews, String type) {
  ReviewRequest? active, terminal;
  for (final r in reviews) {
    if (r.reviewType != type) continue;
    if (_activeStatuses.contains(r.status)) {
      active ??= r;
    } else if (_terminalRendered.contains(r.status)) {
      terminal ??= r;
    }
  }
  return active ?? terminal;
}

/// `updateVerifyBtnState(coach)` (cprofile.js:2510-2614) — exact button
/// text/state per status. Any status not in either whitelist (withdrawn,
/// superseded, dismissed, declined, expired, cancelled, or a future unknown
/// status) falls through to the default `requestReview` case — the
/// fail-closed behavior this whole mechanism exists to guarantee.
VerifyButtonInfo verifyButtonStatePure(ReviewRequest? review) {
  if (review == null) {
    return const VerifyButtonInfo(state: VerifyButtonState.requestReview, label: 'Request Review');
  }
  switch (review.status) {
    case 'pending':
      return VerifyButtonInfo(state: VerifyButtonState.pendingWithdraw, label: 'Review Requested', review: review);
    case 'accepted':
      if (review.awaitingPayment) {
        return VerifyButtonInfo(state: VerifyButtonState.awaitingPayment, label: 'Complete Payment ₹${review.totalPrice ?? 0}', review: review);
      }
      return VerifyButtonInfo(state: VerifyButtonState.chatWithExpert, label: 'Chat with Expert', review: review);
    case 'in_progress':
    case 'expert_reviewing':
      return VerifyButtonInfo(state: VerifyButtonState.inProgress, label: 'Expert Reviewing…', review: review);
    case 'completed':
    case 'review_completed':
      return VerifyButtonInfo(state: VerifyButtonState.completed, label: 'Expert Reviewed', review: review);
    case 'rejected':
      return VerifyButtonInfo(state: VerifyButtonState.rejected, label: 'Review Rejected', review: review);
    default:
      return const VerifyButtonInfo(state: VerifyButtonState.requestReview, label: 'Request Review');
  }
}

/// `submitBtn` handler's lifecycle guard (cprofile.js:2969-2985) — only one
/// active review per athlete↔expert at a time.
bool canSubmitNewReviewPure(ReviewRequest? latest) =>
    latest == null || !_activeStatuses.contains(latest.status);

/// Backing state for the athlete-facing Expert Profile screen — mirrors
/// `cprofile.js`'s `init()` + `updateVerifyBtnState()` + review lifecycle.
class ExpertProfileController extends ChangeNotifier {
  ExpertProfileController({
    required this.expertId,
    required this.userId,
    required this.userName,
    required ExpertsRepository repository,
    required FirebaseFirestore firestore,
    ExpertRatingRepository? ratings,
  }) : _repository = repository,
       _db = firestore,
       _ratings = ratings ?? ExpertRatingRepository() {
    _init();
  }

  final String expertId;
  final String userId;
  final String userName;
  final ExpertsRepository _repository;
  final FirebaseFirestore _db;
  final ExpertRatingRepository _ratings;
  bool _disposed = false;

  /// Athlete star ratings of THIS expert, read through the backend (not
  /// Firestore) because that is where non-consented transformation photos
  /// are stripped — `firestore.rules` deliberately denies a third party any
  /// direct read of `expert_ratings`.
  List<ExpertRating> expertRatings = const [];

  bool loading = true;
  bool notFound = false;
  Object? error;
  ExpertListing? expert;

  List<ExpertCertificate> certificates = const [];
  List<ReviewRequest> myReviews = const [];
  List<CoachingRequest> myCoachingRequests = const [];
  CoachingRelationship? myCoachingRelationship;

  Map<String, dynamic>? _userDoc;
  bool submitting = false;
  Object? submitError;

  StreamSubscription? _certSub, _reviewsSub, _coachReqSub, _coachRelSub, _userDocSub;

  bool get hasDietPlan => _userDoc?['dietPlan'] != null;
  bool get hasWorkoutPlan => _userDoc?['workoutPlan'] != null;
  String? get livePlanId => _userDoc?['planId'] as String?;

  DietPlanContent? get dietPlan {
    final wrapper = _userDoc?['dietPlan'] as Map?;
    if (wrapper == null) return null;
    final current = wrapper['currentDietPlan'] ?? wrapper['originalDietPlan'];
    return current is Map ? DietPlanContent.fromMap(current.cast<String, dynamic>()) : null;
  }

  WorkoutPlanContent? get workoutPlan {
    final wrapper = _userDoc?['workoutPlan'] as Map?;
    if (wrapper == null) return null;
    final current = wrapper['currentWorkoutPlan'] ?? wrapper['originalWorkoutPlan'];
    return current is Map ? WorkoutPlanContent.fromMap(current.cast<String, dynamic>()) : null;
  }

  Map<String, dynamic> get assessmentData => {
    'assessment': _userDoc?['assessment'],
    'calculations': _userDoc?['calculations'],
    'swot': _userDoc?['swot'],
  };

  Map<String, dynamic> get profileBasics {
    final a = (_userDoc?['assessment'] as Map?)?.cast<String, dynamic>() ?? const {};
    final goal = (_userDoc?['goal'] as Map?)?.cast<String, dynamic>() ?? const {};
    return {
      'age': a['age'],
      'gender': a['gender'],
      'weight_kg': a['weight_kg'],
      'height_cm': a['height_cm'],
      'goal_weight_kg': a['goal_weight_kg'],
      'activity_level': a['activity_level'],
      'diet_preference': a['diet_preference'],
      'workout_preference': a['workout_preference'],
      'fitness_goal': goal['type'] ?? a['fitness_goal'],
      'fitness_level': a['fitness_level'],
      'biggest_struggle': a['biggest_struggle'] ?? a['struggle'],
    };
  }

  Future<void> _init() async {
    try {
      expert = await _repository.fetchExpert(expertId);
    } catch (e) {
      error = e;
    }
    if (expert == null && error == null) notFound = true;
    loading = false;
    _safeNotify();
    if (expert == null) return;

    _certSub = _repository.watchCertificates(expertId).listen((c) {
      certificates = c;
      _safeNotify();
    });
    _reviewsSub = _repository.watchMyReviews(userId: userId, expertId: expertId).listen((r) {
      myReviews = r;
      _safeNotify();
    });
    _coachReqSub = _repository.watchMyCoachingRequests(userId: userId, expertId: expertId).listen((r) {
      myCoachingRequests = r;
      _safeNotify();
    });
    _coachRelSub = _repository.watchMyCoachingRelationship(userId).listen((r) {
      myCoachingRelationship = r;
      _safeNotify();
    });
    _userDocSub = _db.collection('users').doc(userId).snapshots().listen((snap) {
      _userDoc = snap.data();
      _safeNotify();
    });
    unawaited(_loadExpertRatings());
  }

  Future<void> _loadExpertRatings() async {
    try {
      expertRatings = await _ratings.fetchForExpert(expertId);
      _safeNotify();
    } catch (e) {
      // The profile's existing rating summary and legacy inline reviews are
      // unaffected — a failed ratings fetch costs this one section, never
      // the screen.
      if (kDebugMode) debugPrint('[EXPERT PROFILE] ratings unavailable: $e');
    }
  }

  /// Re-reads after the athlete submits, so their own review appears without
  /// leaving the screen.
  Future<void> refreshRatings() => _loadExpertRatings();

  /// `_getMyLatestPlanReview(coach)` (cprofile.js:2437-2452) — prefers an
  /// ACTIVE-status doc over a terminal one, newest first within each group.
  ReviewRequest? latestReviewOfType(String type) => latestReviewOfTypePure(myReviews, type);

  /// `updateVerifyBtnState(coach)` (cprofile.js:2510-2614) — collapsed to the
  /// button-state enum; exact copy lives in the widget layer.
  VerifyButtonInfo verifyButtonState({String type = 'diet'}) =>
      verifyButtonStatePure(latestReviewOfType(type));

  /// `submitBtn` handler's lifecycle guard (cprofile.js:2969-2985) — only
  /// one active review per athlete↔expert at a time.
  bool canSubmitNewReview(String type) => canSubmitNewReviewPure(latestReviewOfType(type));

  Future<bool> submitReviewRequest({
    required String reviewType,
    required String serviceType,
  }) async {
    submitting = true;
    submitError = null;
    _safeNotify();
    try {
      final e = expert!;
      num total = 0;
      final needsType = serviceType == 'verification' || serviceType == 'verification_chat';
      if (needsType) {
        total += switch (reviewType) {
          'diet' => e.pricing.dietReviewPrice,
          'workout' => e.pricing.workoutReviewPrice,
          'both' => e.pricing.bothReviewPrice,
          _ => 0,
        };
      }
      if (serviceType == 'chat' || serviceType == 'verification_chat') {
        total += e.pricing.chatPrice;
      }
      final type = serviceType == 'chat' ? 'chat_only' : reviewType;
      await _repository.submitReviewRequest(
        userId: userId,
        userName: userName,
        expertId: expertId,
        expertName: e.name,
        expertRole: e.role,
        reviewType: type,
        serviceType: serviceType,
        dietPlan: dietPlan,
        workoutPlan: workoutPlan,
        assessmentData: assessmentData,
        profileBasics: profileBasics,
        planId: livePlanId,
        totalPrice: total,
      );
      return true;
    } catch (e) {
      submitError = e;
      return false;
    } finally {
      submitting = false;
      _safeNotify();
    }
  }

  Future<bool> withdraw(ReviewRequest review) async {
    if (review.status != 'pending') return false;
    return _repository.withdrawReview(review.id, siblingId: review.siblingId);
  }

  Future<bool> submitCoachingRequest({required String planType}) async {
    submitting = true;
    _safeNotify();
    try {
      await _repository.submitCoachingRequest(expertId: expertId, planType: planType);
      return true;
    } catch (e) {
      submitError = e;
      return false;
    } finally {
      submitting = false;
      _safeNotify();
    }
  }

  String chatId() => _repository.chatIdFor(athleteId: userId, expertId: expertId);

  /// The single, canonical End Coaching call — see `ActiveCoachingBanner`.
  ///
  /// After the backend confirms, the relationship is flipped to `'ended'`
  /// LOCALLY and the UI is notified at once — the same optimistic refresh the
  /// website does (`cprofile.js`: `_myCoaching.status='ended'; updateCoachButtons()`).
  /// Without this the banner would linger until the `personal_coaching`
  /// snapshot round-tripped back through Firestore, which on any latency reads
  /// as "End Coaching did nothing". The `_coachRelSub` listener later emits the
  /// same `'ended'` status — idempotent, so applying it twice is harmless. The
  /// optimistic update runs ONLY after the await succeeds, so a failed request
  /// (which rethrows) correctly leaves the banner up for the error toast.
  Future<void> endCoaching() async {
    await _repository.endCoaching(userId);
    final rel = myCoachingRelationship;
    if (rel != null && rel.status == 'active') {
      myCoachingRelationship = rel.copyWith(status: 'ended');
      _safeNotify();
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _certSub?.cancel();
    _reviewsSub?.cancel();
    _coachReqSub?.cancel();
    _coachRelSub?.cancel();
    _userDocSub?.cancel();
    super.dispose();
  }
}
