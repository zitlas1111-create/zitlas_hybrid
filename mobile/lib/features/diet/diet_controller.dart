import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import 'models/diet_profile.dart';
import 'models/swap_result.dart';
import '../expert_dashboard/models/expert_models.dart' show CoachingRelationship, ExpertProfile;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../coaching/data/coaching_plan_repository.dart';
import '../coaching/data/meal_checkin_repository.dart';
import '../coaching/models/coach_diet_plan.dart';
import '../coaching/models/meal_checkin.dart';
import '../dashboard/data/health_status_store.dart';
import '../dashboard/models/health_status.dart';
import '../experts/data/experts_repository.dart';
import 'data/diet_repository.dart';
import 'models/diet_calculations.dart';
import 'models/diet_day.dart';
import 'models/diet_meal.dart';
import 'models/diet_plan_content.dart';
import 'models/diet_review_request.dart';
import 'models/diet_storage.dart';
import 'models/expert_meal_modification.dart';

const _weekdayNames = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// Aggregates the Diet feature's Firestore state and exposes the actions the
/// screen can take. Mirrors `diet.js`'s `init()`/`loadDietStorage()` load
/// chain and `DashboardController`'s subscription pattern — one live
/// listener on `users/{uid}` (which carries `dietPlan`, `planId`,
/// `calculations`, `dietPlanMaster`), one live listener on this athlete's
/// diet `review_requests`.
///
/// The `planId` fail-closed check (`_validateAndMaybeAdopt`) is the single
/// most important piece of behavior here: it is what stops a stale plan
/// (left over from before a goal reset) from ever being rendered or
/// silently kept, matching `validateDietStorage()` on the website exactly.
class DietController extends ChangeNotifier {
  DietController({
    required this.uid,
    required DietRepository repository,
    CoachingPlanRepository? coachingPlans,
    ExpertsRepository? experts,
    MealCheckinRepository? mealCheckins,
    HealthStatusStore? healthStore,
  }) : _repository = repository, // ignore: prefer_initializing_formals
       _coachingPlans = coachingPlans ?? CoachingPlanRepository(),
       _experts = experts ??
           ExpertsRepository(
             firestore: FirebaseFirestore.instance,
             auth: FirebaseAuth.instance,
           ),
       _mealCheckins = mealCheckins ?? MealCheckinRepository(),
       _healthStore = healthStore ?? HealthStatusStore() {
    _init();
  }

  final String uid;
  final DietRepository _repository;
  final CoachingPlanRepository _coachingPlans;
  final ExpertsRepository _experts;
  final MealCheckinRepository _mealCheckins;
  final HealthStatusStore _healthStore;

  /// Today's Health Status override, if the athlete checked in today via
  /// the Dashboard's "How are you feeling?" card — same
  /// `zitlas_health_today`-equivalent record `DashboardController` reads,
  /// loaded independently here since Diet and Dashboard are separate
  /// top-level tabs with their own controller instances (no shared state
  /// to plumb through, and `HealthStatusStore` is a stateless
  /// SharedPreferences wrapper, cheap to read twice).
  HealthAdjustment? healthToday;

  StreamSubscription<Map<String, dynamic>?>? _userDocSub;
  StreamSubscription<List<DietReviewRequest>>? _reviewsSub;
  StreamSubscription<CoachingPlanDoc>? _coachPlanSub;
  StreamSubscription<CoachingRelationship?>? _relSub;
  StreamSubscription<List<MealCheckin>>? _checkinSub;
  bool _disposed = false;
  bool _dayAutoSelected = false;
  Map<String, dynamic>? _lastUserDoc;

  /// The athlete's permanent food profile. Read from the same live user-doc
  /// snapshot as everything else, so it can never drift from what's stored.
  DietProfile dietProfile = const DietProfile();

  /// True when the intake has never been completed — the Diet screen uses
  /// this to offer it once, and only once.
  bool get needsDietProfile => !dietProfile.isComplete;

  bool loading = true;
  Object? error;

  DietStorage? dietStorage;
  DietCalculations calculations = const DietCalculations();
  String? livePlanId;
  List<DietReviewRequest> reviews = const [];

  int selectedDayIndex = 0;

  bool swapping = false;
  Object? swapError;

  /// `NETWORK_ERROR | AUTH_ERROR | VALIDATION_ERROR | BACKEND_ERROR |
  /// AI_PROVIDER_ERROR | INVALID_RESPONSE` — debug-only classification of
  /// [swapError]; the UI stays the same friendly message regardless.
  String? swapErrorCategory;

  bool submittingReview = false;
  Object? reviewError;

  bool loadingExperts = false;
  List<ExpertProfile> approvedExperts = const [];

  /// `buildEffectivePlan()` applied on top of the validated wrapper — this,
  /// never `currentDietPlan` raw, is what the screen renders.
  DietPlanContent? get effectivePlan => dietStorage?.buildEffectivePlan();

  /// The most recent completed-but-not-yet-accepted review for THIS athlete
  /// whose `planId` doesn't contradict the live goal — matches the
  /// `planIdMismatch` guard from `getCompletedPlanReview()`: only excluded
  /// when both ids are present and differ, never on a missing id.
  DietReviewRequest? get pendingAcceptableReview {
    for (final r in reviews) {
      if (!r.isCompleted || r.athleteAccepted) continue;
      if (r.planId != null && livePlanId != null && r.planId != livePlanId) continue;
      return r;
    }
    return null;
  }

  void _init() {
    _userDocSub = _repository.watchUserDoc(uid).listen(
      _onUserDoc,
      onError: (Object e) {
        loading = false;
        error = e;
        _safeNotify();
      },
    );

    _reviewsSub = _repository.watchDietReviews(uid).listen(
      (list) {
        reviews = list;
        _safeNotify();
      },
      onError: (_) {
        // Review banner just stays hidden — non-critical for the core screen.
      },
    );

    // The relationship gate. Meal Snap and the coach's plan both hang off
    // this being active.
    _relSub = _experts.watchMyCoachingRelationship(uid).listen(
      (rel) {
        coachRelationship = rel;
        _safeNotify();
        _watchCheckins();
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('[DIET] coaching relationship unavailable: $e');
      },
    );

    // The coach-authored diet, live. This is what makes an edit published by
    // the coach — from the app or from the website's coaching workspace —
    // appear here without the athlete refreshing anything.
    _coachPlanSub = _coachingPlans.watch(uid).listen(
      (doc) {
        coachPlan = doc;
        _safeNotify();
      },
      onError: (Object e) {
        // A coach plan the athlete can't read (relationship lapsed, offline)
        // just isn't shown — the AI plan below it is unaffected.
        if (kDebugMode) debugPrint('[DIET] coach plan unavailable: $e');
      },
    );

    unawaited(_loadHealthToday());

    // Live wellness propagation. Both controllers are created inside
    // `StatefulShellRoute.indexedStack`, which keeps every tab alive, so a
    // "Sick Today" / "Injured Today" check-in made on the Dashboard tab
    // would otherwise never reach this already-constructed controller and
    // today's plan would keep rendering as if nothing had happened.
    HealthStatusStore.revision.addListener(_onHealthRevision);
  }

  /// One-shot read (not a stream — `HealthStatusStore` is SharedPreferences,
  /// not Firestore) of today's Health Status override, if any.
  Future<void> _loadHealthToday() async {
    try {
      healthToday = await _healthStore.loadToday();
      _safeNotify();
    } catch (_) {
      // Diet screen simply renders the normal plan — a health-status read
      // failure must never block the actual diet plan from showing.
    }
  }

  /// Re-reads today's Health Status override — called by the screen when it
  /// resumes/refreshes, since a check-in on the Dashboard tab while Diet's
  /// controller is already alive wouldn't otherwise be picked up (this is a
  /// one-shot local read, not a live stream).
  Future<void> refreshHealthToday() => _loadHealthToday();

  void _onHealthRevision() => unawaited(_loadHealthToday());


  /// Health Status recovery override — swaps ONLY today's meals with the
  /// deterministic recovery template chosen on the Dashboard's "How are you
  /// feeling today?" card (`computeHealthAdjustments`/`HealthStatusStore`).
  /// Mirrors `diet.js`'s exact gating (`_hsApplies`): today's date (already
  /// guaranteed by `HealthStatusStore.loadToday()`, which returns null for a
  /// stale record), this specific day's weekday, and never over an active
  /// coach-authored plan — the coach is alerted instead and adjusts the
  /// coach plan themselves, so an AI-plan override would be misleading.
  bool healthOverrideAppliesTo(DietDay day) {
    final adj = healthToday;
    if (adj?.diet == null || adj!.diet!.meals.isEmpty) return false;
    if (day.day.toLowerCase() != _weekdayName(DateTime.now()).toLowerCase()) return false;
    if (dietStorage?.isExpertPlan == true) return false;
    return true;
  }

  /// What the screen should actually render for this day — the normal plan
  /// unless [healthOverrideAppliesTo] says today's recovery template applies.
  List<DietMeal> effectiveMealsFor(DietDay day) {
    if (!healthOverrideAppliesTo(day)) return day.meals;
    return healthToday!.diet!.meals.map(DietMeal.fromMap).toList();
  }

  /// The coach-authored plan document, or null until the first snapshot.
  CoachingPlanDoc? coachPlan;

  /// The athlete-coach relationship. Meal Snap exists ONLY while this is
  /// active — an athlete without a coach has nobody to send a photo to, so the
  /// button is absent rather than disabled.
  CoachingRelationship? coachRelationship;

  /// This athlete's photographed meals, live, so a coach's review lands on
  /// the meal card without a refresh.
  List<MealCheckin> mealCheckins = const [];

  /// True only for an athlete with a live, unexpired Personal Coach.
  bool get hasActiveCoach => coachRelationship?.isActive == true;

  String? get activeCoachId => hasActiveCoach ? coachRelationship?.coachId : null;

  /// The most recent check-in for a meal on the CURRENT day, or null.
  ///
  /// Matched on the meal name the athlete photographed, lower-cased — the same
  /// key `diet.js` writes, so a meal snapped on the website shows here too.
  MealCheckin? checkinFor(String mealName) {
    final wanted = mealName.toLowerCase();
    final now = DateTime.now();
    for (final c in mealCheckins) {
      if (c.mealType != wanted) continue;
      final t = c.timestamp;
      if (t == null) continue;
      if (t.year == now.year && t.month == now.month && t.day == now.day) return c;
    }
    return null;
  }

  /// Subscribes to this athlete's meal check-ins once a coach exists.
  ///
  /// Only attached when there IS a coach — an athlete without one has no
  /// check-ins to read, and opening a listener for them is a query that can
  /// only ever return nothing.
  void _watchCheckins() {
    if (!hasActiveCoach) {
      _checkinSub?.cancel();
      _checkinSub = null;
      if (mealCheckins.isNotEmpty) {
        mealCheckins = const [];
        _safeNotify();
      }
      return;
    }
    if (_checkinSub != null) return;
    _checkinSub = _mealCheckins.watchForAthlete(uid).listen(
      (list) {
        mealCheckins = list;
        _safeNotify();
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('[DIET] meal check-ins unavailable: $e');
      },
    );
  }

  bool snappingMeal = false;

  /// Submits a photographed meal to the assigned coach.
  ///
  /// Returns null on success, or a message to show. Guarded on an ACTIVE
  /// relationship at the moment of sending, not just when the button was
  /// drawn — a relationship can lapse while the camera is open.
  Future<String?> submitMealPhoto({
    required File photo,
    required String mealName,
    required String athleteName,
  }) async {
    final coachId = activeCoachId;
    if (coachId == null) {
      return 'Your coaching has ended, so there is nobody to review this meal.';
    }
    if (snappingMeal) return null;
    snappingMeal = true;
    _safeNotify();
    try {
      await _mealCheckins.submit(
        photo: photo,
        athleteId: uid,
        athleteName: athleteName,
        coachId: coachId,
        mealName: mealName,
        day: _weekdayName(DateTime.now()),
      );
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[DIET] meal submit failed: $e');
      final raw = e.toString().replaceFirst('Exception: ', '');
      return raw.length < 160 ? raw : 'Could not send that photo. Please try again.';
    } finally {
      snappingMeal = false;
      _safeNotify();
    }
  }

  static String _weekdayName(DateTime d) => const [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
      ][d.weekday - 1];

  /// Whether a coach-authored plan may own this athlete's diet AT ALL.
  ///
  /// Byte-for-byte the website's `_pcShowsCoachPlan()` in diet.js: the
  /// relationship must be ACTIVE and must actually cover diet. Kept identical
  /// so the two clients can never disagree about which plan an athlete is on.
  bool get _coachDietRelationshipActive {
    final rel = coachRelationship;
    if (rel == null || !rel.isActive) return false;
    final type = rel.planType;
    return type == 'diet' || type == 'complete';
  }

  /// The coach's diet, but ONLY when it should actually be shown.
  ///
  /// Fails closed on three independent conditions:
  ///  * the coaching relationship is not ACTIVE — see below;
  ///  * a plan authored against a DIFFERENT `planId` — the athlete reset their
  ///    goal, so that prescription is for a goal nobody has any more;
  ///  * a plan with no meals in it — a coach who has opened the editor but not
  ///    published anything must not blank out the athlete's AI plan.
  ///
  /// THE RELATIONSHIP CHECK IS THE BUG FIX. This getter previously consulted
  /// only the plan document, never the relationship, so once coaching ended the
  /// coach's diet kept rendering forever — the athlete had no route back to
  /// their own AI/expert-reviewed plan. The `coachPlan` listener is attached
  /// unconditionally and the athlete can always read their OWN
  /// `coaching_plans/{uid}` document, so nothing upstream ever stops supplying
  /// it; this is the only place that can decide it is no longer active.
  ///
  /// The training side already gated on the relationship
  /// (`_coachOverrideActive` → `showsCoachTrainingPlan`), which is exactly why
  /// Training behaved correctly after coaching ended while Diet did not.
  ///
  /// Deactivation is a VISIBILITY decision only: the `coaching_plans` document
  /// is never written or deleted here, so history stays intact for audit and a
  /// renewed engagement can publish over it.
  ///
  /// When this is null the existing AI/expert-reviewed plan renders exactly as
  /// before — that plan is never touched by this code path.
  CoachDietPlan? get activeCoachDiet {
    final doc = coachPlan;
    if (doc == null || !doc.exists) return null;
    if (!doc.diet.hasDays) return null;

    if (!_coachDietRelationshipActive) {
      if (kDebugMode) {
        final rel = coachRelationship;
        debugPrint('[DIET PLAN SELECT] REJECTED COACH PLAN — COACHING ENDED '
            '(status=${rel?.status}, planType=${rel?.planType}, '
            'isActive=${rel?.isActive})');
        debugPrint('[DIET PLAN SELECT] FALLBACK TO AI/EXPERT PLAN');
      }
      return null;
    }

    if (doc.isStaleFor(livePlanId)) {
      if (kDebugMode) {
        debugPrint('[DIET] coach plan retired — authored for ${doc.diet.planId}, '
            'live plan is $livePlanId');
      }
      return null;
    }

    if (kDebugMode) {
      debugPrint('[DIET PLAN SELECT] coach plan ACTIVE '
          '(planId=${doc.diet.planId}, coachId=${coachRelationship?.coachId})');
    }
    return doc.diet;
  }

  bool get hasCoachDiet => activeCoachDiet != null;

  /// Records which option the athlete picked for a coach-authored meal.
  ///
  /// The athlete's ONLY write to the coach's document — Security Rules now
  /// permit them `dietSelections` and nothing else, so this cannot become a
  /// way to edit the prescription itself. Optimistically applied so the radio
  /// moves immediately; the live listener confirms it a moment later.
  Future<void> selectCoachMealOption(String day, String mealId, int optionIndex) async {
    final doc = coachPlan;
    if (doc == null) return;
    final next = {...doc.selections, '$day:$mealId': optionIndex};
    coachPlan = CoachingPlanDoc(
      diet: doc.diet,
      training: doc.training,
      selections: next,
      coachId: doc.coachId,
      coachName: doc.coachName,
      planType: doc.planType,
      dietVersion: doc.dietVersion,
      trainingVersion: doc.trainingVersion,
      dietUpdatedAt: doc.dietUpdatedAt,
      trainingUpdatedAt: doc.trainingUpdatedAt,
      exists: doc.exists,
    );
    _safeNotify();
    try {
      await _coachingPlans.saveSelections(uid, next);
    } catch (e) {
      // The listener will restore the stored value on its next snapshot, so a
      // failed write self-corrects rather than leaving a lie on screen.
      if (kDebugMode) debugPrint('[DIET] selection save failed: $e');
    }
  }

  void _onUserDoc(Map<String, dynamic>? data) {
    _lastUserDoc = data;
    dietProfile = DietProfile.fromMap(
      (data?['dietProfile'] as Map?)?.cast<String, dynamic>(),
    );
    calculations = _repository.parseCalculations(data);
    livePlanId = data?['planId'] as String?;

    final rawPlan = (data?['dietPlan'] as Map?)?.cast<String, dynamic>();
    DietStorage? candidate;
    if (rawPlan != null) {
      if (DietStorage.isNewSchema(rawPlan)) {
        candidate = DietStorage.fromMap(rawPlan);
      } else if (rawPlan['days'] != null) {
        candidate = DietStorage.fromLegacyFlatPlan(
          DietPlanContent.fromMap(rawPlan),
          planId: livePlanId,
        );
      }
    }

    dietStorage = _validateAndMaybeAdopt(candidate);
    loading = false;
    error = null;
    _maybeAutoSelectDay();
    _safeNotify();

    if (dietStorage == null) {
      unawaited(_recoverFromMaster(data));
    }
  }

  /// `validateDietStorage()` on the website — fail-closed against the live
  /// `planId` goal-identity stamp:
  /// - stamped + matches live id (or live id not yet set) -> valid
  /// - stamped + contradicts live id -> stale, discard
  /// - unstamped + carries an expert layer -> untrustworthy, discard
  /// - unstamped + no expert layer + live id known -> adopt (stamp + persist)
  /// - unstamped + no expert layer + live id unknown -> keep as-is for now
  DietStorage? _validateAndMaybeAdopt(DietStorage? storage) {
    if (storage == null) return null;

    final storedId = storage.planId;
    final hasExpertLayer =
        storage.isExpertPlan || storage.expertModifications.values.any((m) => m.isNotEmpty);

    if (storedId != null) {
      if (livePlanId != null && storedId != livePlanId) {
        unawaited(_repository.discardDietStorage(uid).catchError((_) {}));
        return null;
      }
      return storage;
    }

    if (hasExpertLayer) {
      unawaited(_repository.discardDietStorage(uid).catchError((_) {}));
      return null;
    }

    if (livePlanId == null) return storage;

    final adopted = storage.copyWith(planId: livePlanId);
    unawaited(_repository.saveDietStorage(uid, adopted).catchError((_) {}));
    return adopted;
  }

  /// `_recoverFromMaster()` — one-time fallback to the immutable
  /// `dietPlanMaster` snapshot when no valid `dietPlan` wrapper survives
  /// validation. Only accepted when the master's own `planId` doesn't
  /// contradict the live goal (a master predating the `planId` feature has
  /// no such field and is accepted).
  Future<void> _recoverFromMaster(Map<String, dynamic>? data) async {
    try {
      final master = (data?['dietPlanMaster'] as Map?)?.cast<String, dynamic>();
      if (master == null) return;
      final masterPlanId = master['planId'] as String?;
      if (masterPlanId != null && livePlanId != null && masterPlanId != livePlanId) return;

      final plan = DietPlanContent.fromMap(master);
      if (!plan.hasDays) return;

      final recovered = DietStorage.fromLegacyFlatPlan(plan, planId: livePlanId ?? masterPlanId);
      await _repository.saveDietStorage(uid, recovered);
      if (_disposed) return;
      dietStorage = recovered;
      _maybeAutoSelectDay();
      _safeNotify();
    } catch (_) {
      // Recovery is best-effort; the empty state is the safe fallback.
    }
  }

  /// Defaults the day selector to today's weekday, matching the website's
  /// auto-select — but only the first time a plan becomes available, so it
  /// never yanks the athlete back to "today" after they've picked a day.
  void _maybeAutoSelectDay() {
    if (_dayAutoSelected) return;
    final days = effectivePlan?.days;
    if (days == null || days.isEmpty) return;
    _dayAutoSelected = true;
    final todayName = _weekdayNames[(DateTime.now().weekday - 1) % 7];
    final idx = days.indexWhere((d) => d.day.toLowerCase() == todayName);
    selectedDayIndex = idx >= 0 ? idx : 0;
  }

  void selectDay(int index) {
    selectedDayIndex = index;
    notifyListeners();
  }

  /// `callSwapMealApi()` — asks the backend for a replacement suggestion.
  /// Returns the raw `{foods, calories?, protein_g?}` swap so the caller can
  /// show a preview before committing via [acceptSwap]; never writes
  /// anything itself.
  Future<SwapResult?> requestMealSwap({
    required int dayIndex,
    required int mealIndex,
    required String reason,
    List<String> rejectedFoods = const [],
    List<Map<String, dynamic>> previousSuggestions = const [],
  }) async {
    final plan = effectivePlan;
    if (plan == null || dayIndex >= plan.days.length) return null;
    final day = plan.days[dayIndex];
    if (mealIndex >= day.meals.length) return null;
    final meal = day.meals[mealIndex];

    final assessment = (_lastUserDoc?['assessment'] as Map?)?.cast<String, dynamic>() ?? const {};
    final goal = (_lastUserDoc?['goal'] as Map?)?.cast<String, dynamic>();
    // The CONFIRMED `preferredDietRegion` (never live GPS) — the same field
    // Assessment generation reads, so a swap and a fresh plan always agree
    // on region. `assessment['location']` was a dead reference (Assessment
    // persists location under its own top-level `location` field, not
    // inside `assessment`) — this is the actual fix for "Swap Meal doesn't
    // receive region".
    final preferredRegion = _lastUserDoc?['preferredDietRegion'] as String?;
    final locationPayload = (preferredRegion == null || preferredRegion.isEmpty) ? null : {'state': preferredRegion};
    if (kDebugMode) debugPrint('[SWAP] requesting alternatives with region = ${preferredRegion ?? '(none)'}');

    swapping = true;
    swapError = null;
    swapErrorCategory = null;
    _safeNotify();
    try {
      final result = await _repository.swapMeal(
        mealName: meal.mealName,
        // Backend `meal_time: str = Field(default="")` is NOT optional —
        // sending JSON `null` here fails Pydantic validation with a 422
        // ("Could not get a suggestion" with zero detail visible to the
        // athlete). `meal.time` legitimately IS null for some plan entries,
        // so this must never be passed through raw.
        mealTime: meal.time ?? '',
        currentFoods: meal.foods,
        reason: reason,
        userProfile: {
          'fitness_goal': goal?['type'] ?? assessment['fitness_goal'],
          'uses_supplements': assessment['uses_supplements'],
          'location': locationPayload,
        },
        // The athlete's permanent food profile takes precedence over the
        // one-off assessment answers: it is the deliberate, editable record
        // of who cooks, what they can afford, and what they actually like,
        // and it is what makes the engine's kitchen-first ranking work.
        // Assessment values remain the fallback for athletes who predate it.
        lifestyleData: {
          'diet_preference': assessment['diet_preference'],
          'living_situation': assessment['living_situation'],
          'daily_budget': assessment['budget'],
          'disliked_foods': assessment['disliked_foods'],
          // The Assessment's food preferences — the fallback the comment
          // above describes. `toLifestyleData()` overrides this only when
          // the permanent profile actually has its own answer.
          'favorite_foods': assessment['favorite_foods'],
          ...dietProfile.toLifestyleData(),
        },
        rejectedFoods: rejectedFoods,
        previousSuggestions: previousSuggestions,
        fitnessGoal: (goal?['type'] as String?) ?? (assessment['fitness_goal'] as String?) ?? 'general_fitness',
      );
      if (kDebugMode) {
        // Logged verbatim from the response so backend output and UI can be
        // compared line-for-line — the whole point of removing the LLM was
        // that what the engine ranked is what the athlete sees.
        debugPrint('[SWAP] current   = ${meal.foods.join(", ")}');
        debugPrint('[SWAP] returned  = ${result.options.length} options '
            'in ${result.elapsedMs}ms (llm=${result.llmUsed})');
        for (var i = 0; i < result.options.length; i++) {
          final o = result.options[i];
          debugPrint('[SWAP]   ${i + 1}. ${o.name} — ${o.calories}kcal '
              '${o.proteinG}P ${o.carbsG}C ${o.fatG}F | ${o.budgetLevel}');
          debugPrint('[SWAP]      reason: ${o.reason}');
        }
        debugPrint('[SWAP] match     = ${result.matchNote}');
      }
      return result;
    } catch (e) {
      swapError = e;
      swapErrorCategory = _classifySwapError(e);
      if (kDebugMode) {
        debugPrint('[SWAP] FAILED — category=$swapErrorCategory');
        if (e is ApiException) {
          debugPrint('[SWAP] status = ${e.statusCode ?? '(no response — transport failure)'}');
          debugPrint('[SWAP] message = ${e.message}');
          if (e.body != null) debugPrint('[SWAP] body = ${e.body}');
        } else {
          debugPrint('[SWAP] error = ${e.runtimeType}: $e');
        }
      }
      return null;
    } finally {
      swapping = false;
      _safeNotify();
    }
  }

  /// `NETWORK_ERROR | AUTH_ERROR | VALIDATION_ERROR | BACKEND_ERROR |
  /// AI_PROVIDER_ERROR | INVALID_RESPONSE` — surfaced to debug logs only;
  /// the athlete-facing message stays the same friendly copy regardless.
  static String _classifySwapError(Object e) {
    if (e is ApiException) {
      if (e.isNetworkError) return 'NETWORK_ERROR';
      if (e.isUnauthorized) return 'AUTH_ERROR';
      if (e.statusCode == 422 || e.statusCode == 400) return 'VALIDATION_ERROR';
      if (e.statusCode == 503) return 'AI_PROVIDER_ERROR';
      if (e.isServerError) return 'BACKEND_ERROR';
      return 'BACKEND_ERROR';
    }
    if (e is FormatException) return 'INVALID_RESPONSE';
    return 'NETWORK_ERROR';
  }

  /// `applySwappedMeal()` — commits a swap the athlete accepted. Always
  /// clears any prior `expertModifications` entry for THIS meal (a swap
  /// supersedes an expert edit on that meal, exactly like the website),
  /// then persists both `currentDietPlan` and the pruned modifications map.
  Future<void> acceptSwap({
    required int dayIndex,
    required int mealIndex,
    required Map<String, dynamic> swap,
  }) async {
    final storage = dietStorage;
    if (storage == null) return;
    final base = storage.currentDietPlan.hasDays ? storage.currentDietPlan : storage.originalDietPlan;
    if (dayIndex >= base.days.length) return;
    final day = base.days[dayIndex];
    if (mealIndex >= day.meals.length) return;
    final meal = day.meals[mealIndex];

    final newFoods = swap['foods'] is List
        ? (swap['foods'] as List).map((e) => e.toString()).toList()
        : meal.foods;

    final updatedMeal = meal.copyWith(
      foods: newFoods,
      calories: (swap['calories'] as num?) ?? meal.calories,
      proteinG: (swap['protein_g'] as num?) ?? meal.proteinG,
    );
    final newMeals = List<DietMeal>.from(day.meals)..[mealIndex] = updatedMeal;
    final newDay = day.copyWithMeals(newMeals);
    final newDays = List<DietDay>.from(base.days)..[dayIndex] = newDay;
    final newCurrentPlan = base.copyWithDays(newDays);

    final newMods = <String, Map<String, ExpertMealModification>>{
      for (final e in storage.expertModifications.entries) e.key: Map.of(e.value),
    };
    final dayKey = dayIndex.toString();
    newMods[dayKey]?.remove(meal.mealKey);
    if (newMods[dayKey]?.isEmpty == true) newMods.remove(dayKey);

    final newStorage = storage.copyWith(currentDietPlan: newCurrentPlan, expertModifications: newMods);
    await _repository.saveDietStorage(uid, newStorage);
  }

  Future<void> loadApprovedExperts() async {
    loadingExperts = true;
    _safeNotify();
    try {
      approvedExperts = await _repository.fetchApprovedExperts();
    } catch (_) {
      approvedExperts = const [];
    } finally {
      loadingExperts = false;
      _safeNotify();
    }
  }

  /// `submitVerifyRequest()` — sends the current effective plan (plus
  /// assessment/goal context already live from `users/{uid}`) to an expert
  /// for review. Writes to the SAME `review_requests` collection the
  /// Expert Dashboard's Reviews Inbox reads.
  Future<void> requestReview({
    required String expertId,
    required String expertName,
    required String expertRole,
    required String userName,
    num totalPrice = 0,
    bool isPremium = false,
  }) async {
    final plan = effectivePlan;
    if (plan == null) return;

    submittingReview = true;
    reviewError = null;
    _safeNotify();
    try {
      final assessment = (_lastUserDoc?['assessment'] as Map?)?.cast<String, dynamic>() ?? const {};
      final goal = (_lastUserDoc?['goal'] as Map?)?.cast<String, dynamic>();

      await _repository.submitReviewRequest(
        reviewId: _repository.newReviewRequestId(),
        userId: uid,
        userName: userName,
        expertId: expertId,
        expertName: expertName,
        expertRole: expertRole,
        planData: plan,
        assessmentData: assessment,
        profileBasics: {
          'goal_type': goal?['type'],
          'diet_preference': assessment['diet_preference'],
        },
        goal: goal,
        planId: livePlanId,
        totalPrice: totalPrice,
        isPremium: isPremium,
      );
    } catch (e) {
      reviewError = e;
    } finally {
      submittingReview = false;
      _safeNotify();
    }
  }

  /// `acceptExpertPlan()`/`_buildDietStorageFromReview()` — rebuilds the
  /// wrapper from a completed review: `expertModifications` come primarily
  /// from `mealChangeHistory`, then a scan over `reviewedDietPlan` for any
  /// `_edited` meal missed by history (or whose `newFoods` came back empty)
  /// fills the gap. `currentDietPlan` is reset to `originalDietPlan` — the
  /// expert layer is applied on top at render time by `buildEffectivePlan()`,
  /// never baked directly into `currentDietPlan`.
  Future<void> acceptExpertReview(DietReviewRequest review) async {
    final existing = dietStorage;
    final DietPlanContent original;
    if (existing != null && existing.originalDietPlan.hasDays) {
      original = existing.originalDietPlan;
    } else if (review.originalPlanData != null && review.originalPlanData!.hasDays) {
      original = review.originalPlanData!;
    } else {
      original = review.reviewedDietPlan ?? const DietPlanContent();
    }

    final mods = <String, Map<String, ExpertMealModification>>{};
    for (final entry in review.mealChangeHistory) {
      final dayKey = entry.dayIndex.toString();
      mods.putIfAbsent(dayKey, () => {});
      mods[dayKey]![entry.mealKey] = ExpertMealModification(
        modified: true,
        modifiedBy: entry.modifiedBy ?? review.expertName,
        modifiedAt: entry.modifiedAt ?? review.reviewedAt?.toIso8601String(),
        oldMeal: {
          'foods': entry.oldFoods,
          'calories': entry.oldCalories,
          'protein_g': entry.oldProtein,
        },
        newMeal: {
          'foods': entry.newFoods,
          'calories': entry.newCalories,
          'protein_g': entry.newProtein,
        },
      );
    }

    final reviewedPlan = review.reviewedDietPlan;
    if (reviewedPlan != null) {
      for (var dayIdx = 0; dayIdx < reviewedPlan.days.length; dayIdx++) {
        final day = reviewedPlan.days[dayIdx];
        for (final meal in day.meals) {
          if (!meal.edited) continue;

          final dayKey = dayIdx.toString();
          final existingMod = mods[dayKey]?[meal.mealKey];
          final existingNewFoods = existingMod?.newMeal?['foods'];
          final hasUsableNewFoods = existingNewFoods is List && existingNewFoods.isNotEmpty;
          if (hasUsableNewFoods) continue;

          DietMeal? originalMeal;
          if (dayIdx < original.days.length) {
            for (final m in original.days[dayIdx].meals) {
              if (m.mealKey == meal.mealKey) {
                originalMeal = m;
                break;
              }
            }
          }

          mods.putIfAbsent(dayKey, () => {});
          mods[dayKey]![meal.mealKey] = ExpertMealModification(
            modified: true,
            modifiedBy: review.expertName,
            modifiedAt: review.reviewedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
            oldMeal: originalMeal?.toModificationSnapshot(),
            newMeal: meal.toModificationSnapshot(),
          );
        }
      }
    }

    final newStorage = DietStorage(
      originalDietPlan: original,
      currentDietPlan: original,
      expertModifications: mods,
      isExpertPlan: true,
      expertName: review.expertName,
      expertId: review.expertId,
      expertNotes: review.expertNotes,
      reviewedAt: review.reviewedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      reviewStatus: 'completed',
      planSource: 'expert_reviewed',
      reviewId: review.id,
      version: (existing?.version ?? 0) + 1,
      lastUpdated: DateTime.now().toIso8601String(),
      planId: review.planId ?? livePlanId,
    );

    await _repository.saveDietStorage(uid, newStorage);
    await _repository.markReviewAccepted(review.id);
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    HealthStatusStore.revision.removeListener(_onHealthRevision);
    _userDocSub?.cancel();
    _reviewsSub?.cancel();
    _coachPlanSub?.cancel();
    _relSub?.cancel();
    _checkinSub?.cancel();
    super.dispose();
  }
}
