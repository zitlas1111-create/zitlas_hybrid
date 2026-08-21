import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/expert_repository.dart';
import 'models/expert_models.dart';

/// Drives the whole Expert Dashboard. Mirrors `renderAll()` (ED:5010): one
/// place attaches every realtime listener, and each section reads the
/// resulting state.
///
/// Every stream has its own error slot so one failing collection (e.g. a
/// missing composite index on `personal_coach_requests`) can't blank the
/// entire dashboard — the website gets the same isolation from its
/// per-listener `.catch` handlers.
class ExpertDashboardController extends ChangeNotifier {
  ExpertDashboardController({
    required this.uid,
    required ExpertRepository repository,
    String? authName,
    String? authEmail,
    String? authPhoto,
  }) : // ignore_for_file: prefer_initializing_formals
       _repository = repository,
       _authName = authName,
       _authEmail = authEmail,
       _authPhoto = authPhoto {
    _init();
  }

  final String uid;
  final ExpertRepository _repository;
  final String? _authName;
  final String? _authEmail;
  final String? _authPhoto;

  ExpertRepository get repository => _repository;

  final _subs = <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  // ── State ──────────────────────────────────────────────────────────────
  bool profileLoading = true;
  ExpertProfile? profile;
  Object? profileError;

  List<ReviewRequest> reviews = const [];
  bool reviewsLoading = true;
  Object? reviewsError;

  List<CoachingRequest> coachingRequests = const [];
  bool coachingLoading = true;
  Object? coachingError;

  List<CoachingRelationship> relationships = const [];

  List<ChatRoom> chatRooms = const [];
  bool chatsLoading = true;
  Object? chatsError;

  List<ExpertCertificate> certificates = const [];
  bool certificatesLoading = true;

  int unreadNotifications = 0;

  // ── Derived: review buckets (renderInbox, ED:4533-4538) ────────────────
  List<ReviewRequest> get pendingReviews =>
      reviews.where((r) => r.status == ReviewStatus.pending).toList();
  List<ReviewRequest> get inProgressReviews =>
      reviews.where((r) => r.status == ReviewStatus.inProgress).toList();
  List<ReviewRequest> get completedReviews => reviews
      .where((r) => r.status == ReviewStatus.reviewCompleted || r.status == ReviewStatus.rejected)
      .toList();

  // ── Derived: coaching buckets (ED:1441-1446) ───────────────────────────
  List<CoachingRequest> get pendingCoaching =>
      coachingRequests.where((r) => r.status == 'pending').toList();
  List<CoachingRequest> get activeCoaching =>
      coachingRequests.where((r) => r.status == 'active').toList();
  List<CoachingRequest> get pastCoaching => coachingRequests
      .where((r) => const {
            'declined',
            'expired',
            'completed',
            'ended',
            'withdrawn',
          }.contains(r.status))
      .toList();

  /// "My Users" — active paid relationships only (ED:1327-1331).
  List<CoachingRelationship> get myAthletes =>
      relationships.where((r) => r.isActive).toList();

  /// Requests this expert declined. Split out from [pastCoaching] (which also
  /// holds expired/ended/withdrawn) so the coaching summary can report what
  /// the EXPERT decided separately from what simply lapsed.
  List<CoachingRequest> get declinedCoaching =>
      coachingRequests.where((r) => r.status == 'declined').toList();

  // ── Derived: stats grid ────────────────────────────────────────────────
  //
  // The website has two competing writers for these numbers
  // (`updateDashboardStats` ED:863 reading Firestore vs `renderInbox`
  // ED:4560 reading a localStorage cache) that disagree. We use the
  // Firestore-derived definitions, since Firestore is authoritative and the
  // localStorage cache only exists on web as an offline mirror.

  /// Pending + in-progress (what `renderInbox` shows, ED:4562).
  int get statPending => pendingReviews.length + inProgressReviews.length;

  /// Every review request that wasn't rejected (ED:4563).
  int get statClients => reviews.where((r) => r.status != ReviewStatus.rejected).length;

  /// `count × fee`, computed client-side exactly as the website does
  /// (ED:4565) — there is no wallet/transaction ledger read behind this.
  int get statEarnings {
    final done = reviews.where((r) => r.status == ReviewStatus.reviewCompleted).length;
    return done * (profile?.fee ?? 0);
  }

  /// Live chat rooms that have at least one message. The website's
  /// `#statMessages` is dead code (hardcoded `0`, ED:326, never
  /// recomputed), so rather than reproduce a broken counter we show the
  /// real number of active conversations under the same "Chats" tile.
  int get statChats => chatRooms.where((c) => c.lastMessage != null).length;

  int get navBadgeReviews => pendingReviews.length + inProgressReviews.length;
  int get navBadgeCoaching => pendingCoaching.length;

  /// The relationship for an athlete, if any — drives the chat read-only
  /// lock (`_pcChatIsReadOnlyFor`, ED:85).
  CoachingRelationship? relationshipFor(String? athleteId) {
    if (athleteId == null) return null;
    for (final r in relationships) {
      if (r.athleteId == athleteId) return r;
    }
    return null;
  }

  bool isChatReadOnly(String? athleteId) => relationshipFor(athleteId)?.hasEnded ?? false;

  // ── Init ───────────────────────────────────────────────────────────────
  void _init() {
    _listen<ExpertProfile?>(
      _repository.watchProfile(uid),
      (p) async {
        profileLoading = false;
        profileError = null;
        if (p == null) {
          // Self-heal, exactly as the website does when an authenticated
          // expert has no experts/{uid} doc yet (ED:5158).
          try {
            await _repository.ensureExpertDoc(
              uid,
              name: _authName,
              email: _authEmail,
              photo: _authPhoto,
            );
          } catch (e) {
            profileError = e;
          }
        } else {
          profile = p;
        }
      },
      (e) {
        profileLoading = false;
        profileError = e;
      },
    );

    _listen<List<ReviewRequest>>(
      _repository.watchReviewRequests(uid),
      (list) {
        reviews = list;
        reviewsLoading = false;
        reviewsError = null;
      },
      (e) {
        reviewsLoading = false;
        reviewsError = e;
      },
    );

    _listen<List<CoachingRequest>>(
      _repository.watchCoachingRequests(uid),
      (list) {
        coachingRequests = list;
        coachingLoading = false;
        coachingError = null;
      },
      (e) {
        coachingLoading = false;
        coachingError = e;
      },
    );

    _listen<List<CoachingRelationship>>(
      _repository.watchCoachingRelationships(uid),
      (list) => relationships = list,
      (_) {},
    );

    _listen<List<ChatRoom>>(
      _repository.watchChatRooms(uid),
      (list) {
        chatRooms = list;
        chatsLoading = false;
        chatsError = null;
      },
      (e) {
        chatsLoading = false;
        chatsError = e;
      },
    );

    _listen<List<ExpertCertificate>>(
      _repository.watchCertificates(uid),
      (list) {
        certificates = list;
        certificatesLoading = false;
      },
      (_) => certificatesLoading = false,
    );

    _listen<int>(
      _repository.watchUnreadNotificationCount(uid),
      (count) => unreadNotifications = count,
      (_) {},
    );
  }

  void _listen<T>(
    Stream<T> stream,
    FutureOr<void> Function(T) onData,
    void Function(Object) onError,
  ) {
    _subs.add(stream.listen(
      (value) async {
        await onData(value);
        _safeNotify();
      },
      onError: (Object e) {
        onError(e);
        _safeNotify();
      },
    ));
  }

  // ── Actions ────────────────────────────────────────────────────────────

  /// Accept a review. Charges the athlete's wallet through the existing
  /// backend first (the website's `attemptCharge`), then flips the request
  /// to in_progress. Returns null on success or an error code to surface.
  Future<String?> acceptReview(ReviewRequest review) async {
    final expert = profile;
    if (expert == null) return 'no_profile';

    final amount = review.totalPrice ?? expert.fee;
    final athleteUid = review.userId;

    if (athleteUid != null) {
      final error = await _repository.chargeForReview(
        athleteUid: athleteUid,
        requestId: review.id,
        amount: amount,
        serviceType: review.isChatOnly ? 'chat' : 'review',
        serviceLabel: review.typeLabel,
        expertId: uid,
        expertName: expert.name,
        siblingRequestId: review.siblingId,
        onSuccessUpdate: {
          'status': ReviewStatus.inProgress,
          'acceptedAt': DateTime.now().toIso8601String(),
          'expertId': uid,
          'chatId': uid,
          'chatUnlocked': review.chatIncluded,
        },
      );
      if (error != null) return error;
      // The backend applied onSuccessUpdate; the snapshot will reflect it.
      return null;
    }

    // No athlete uid to charge (legacy request) — fall back to the direct
    // status update the website also uses when payment is unavailable.
    await _repository.acceptReview(
      review.id,
      expertId: uid,
      chatId: uid,
      chatUnlocked: review.chatIncluded,
    );
    return null;
  }

  Future<void> rejectReview(ReviewRequest review) {
    return _repository.rejectReview(review.id, siblingId: review.siblingId);
  }

  Future<void> completeReview(ReviewRequest review) {
    return _repository.completeReview(
      review.id,
      expertId: uid,
      expertName: profile?.name ?? 'Expert',
    );
  }

  Future<CoachingActionResult> respondToCoaching(CoachingRequest req, {required bool accept}) {
    return _repository.respondToCoachingRequest(
      requestId: req.requestId ?? req.id,
      accept: accept,
    );
  }

  Future<void> saveProfile(ExpertProfile updated) async {
    await _repository.saveProfile(uid, updated);
    profile = updated;
    _safeNotify();
  }

  Future<bool> deleteAccount() => _repository.deactivateAccount(uid);

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
