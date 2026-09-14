import 'dart:async';
import 'dart:convert';
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
import '../coaching/models/meal_context.dart';
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
import 'diet_precedence.dart';

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
        _maybeAutoSelectDay();
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
        _maybeAutoSelectDay();
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

    /* THE COACH GUARD — and the bug it replaces.
    
       This used to read `dietStorage?.isExpertPlan == true`, which conflated
       two completely different things:
    
         * an EXPERT-REVIEWED plan — still the athlete's OWN AI plan, verified
           or tweaked by an expert (`planSource: 'expert_reviewed'`, set when a
           review is accepted at line ~866). Recovery mode SHOULD apply to it.
         * an active PERSONAL COACH plan — a live prescription from a coach who
           is being paid to make exactly this call. Recovery mode must NOT
           silently override it; the coach is alerted instead.
    
       Because `isExpertPlan` is true for the FIRST case, any athlete who had
       ever accepted an expert review could never get a recovery-day diet
       again — with or without a coach. The Home card said "your plan has been
       adjusted" and Diet quietly ignored it.
    
       `activeCoachDiet` is the correct signal and is already
       relationship-gated, so an ENDED engagement no longer blocks recovery
       either. This now matches the website's `planSource !== 'coach'` exactly,
       and mirrors the training side, which always used the coach gate
       (`_coachOverrideActive`) rather than this proxy. */
    if (activeCoachDiet != null) return false;
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
    MealContext? mealContext,
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
        mealContext: mealContext,
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

  static String? _nonEmpty(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();

  /// The coach's diet, but ONLY when it is the athlete's CURRENT diet under THE
  /// shared precedence rule (`diet_precedence.dart` — identical to the
  /// website's `assets/js/diet-precedence.js`, pinned by the same fixture):
  /// relationship active and not past its end date, covering diet (a free
  /// trial's null planType is full coverage), at least one meal, written by
  /// the current coach, and not stamped for a DIFFERENT plan generation.
  /// A null planId — or no AI plan at all — does not hide it.
  ///
  /// Deactivation is a VISIBILITY decision only: the `coaching_plans` document
  /// is never written or deleted here, so history stays intact for audit and a
  /// renewed engagement can publish over it.
  CoachDietPlan? get activeCoachDiet {
    final doc = coachPlan;
    if (doc == null || !doc.exists) return null;
    final rel = coachRelationship;
    final input = DietPrecedenceInput(
      now: DateTime.now(),
      livePlanId: _nonEmpty(livePlanId),
      hasRelationship: rel != null,
      relStatus: rel?.status,
      relCoachId: _nonEmpty(rel?.coachId),
      relPlanType: _nonEmpty(rel?.planType),
      relEnd: rel?.endDate,
      hasCoachPlan: true,
      coachPlanCoachId: _nonEmpty(doc.coachId),
      coachPlanPlanId: _nonEmpty(doc.diet.planId),
      coachMealCount: doc.diet.days.fold<int>(0, (n, d) => n + d.meals.length),
    );
    if (!coachDietActive(input)) {
      if (kDebugMode) {
        debugPrint('[DIET PLAN SELECT] coach plan not current '
            '(status=${rel?.status}, planType=${rel?.planType}, '
            'coach=${doc.coachId}/${rel?.coachId}, planId=${doc.diet.planId}/$livePlanId)');
      }
      return null;
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

      // Written as {planId, plan: {days}} (ai-coach.js); a flat copy is read too.
      final planMap = master['plan'] is Map ? (master['plan'] as Map).cast<String, dynamic>() : master;
      final plan = DietPlanContent.fromMap(planMap);
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
    final aiDays = effectivePlan?.days;
    // An athlete coached WITHOUT an AI plan still lands on today.
    final names = (aiDays != null && aiDays.isNotEmpty)
        ? [for (final d in aiDays) d.day]
        : [for (final d in activeCoachDiet?.days ?? const <CoachDietDay>[]) d.day];
    if (names.isEmpty) return;
    _dayAutoSelected = true;
    final todayName = _weekdayNames[(DateTime.now().weekday - 1) % 7];
    final idx = names.indexWhere((d) => d.toLowerCase() == todayName);
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

  /// Accept an expert-reviewed plan — LOSSLESS.
  ///
  /// The COMPLETE reviewed plan is stored as `currentDietPlan`, exactly as the
  /// expert saved it (`reviewedDietPlanRaw`), so renamed / added / deleted
  /// meals, carbs, fats, timing, notes and day fields all survive — nothing is
  /// rebuilt by matching meal names. `expertModifications` only drives the
  /// "Modified by Expert" badges: each entry's newMeal IS the reviewed meal, so
  /// [DietStorage.buildEffectivePlan] changes nothing. The website's
  /// `buildAcceptedStorage()` (assets/js/diet-review.js) builds the same
  /// wrapper, and both write `users/{uid}.dietPlan` — the document both read.
  Future<void> acceptExpertReview(DietReviewRequest review) async {
    final reviewedRaw = review.reviewedDietPlanRaw;
    final reviewed = review.reviewedDietPlan;
    if (reviewedRaw == null || reviewed == null || !reviewed.hasDays) {
      throw const DietAcceptException('This review has no plan to apply.');
    }
    if (review.planId != null && livePlanId != null && review.planId != livePlanId) {
      throw const DietAcceptException(
          'This review was for a previous plan — ask your expert to review your current plan.');
    }
    if (review.planId == null && livePlanId == null) {
      // Nothing to stamp the plan with. Both clients discard an expert plan
      // that cannot prove which goal it belongs to (the shared precedence
      // rule), so writing it would look applied and then vanish.
      throw const DietAcceptException(
          "This review can't be matched to your current plan, so it wasn't applied — "
          'ask your expert to review your latest plan.');
    }
    final existing = dietStorage;
    final keepExisting = existing != null && existing.originalDietPlan.hasDays;
    final DietPlanContent? knownOriginal = keepExisting ? existing.originalDietPlan : review.originalPlanData;
    final currentRaw = _planMapWithMealLists(reviewedRaw);
    final current = DietPlanContent.fromMap(currentRaw);
    final when = review.reviewedAt?.toIso8601String() ?? DateTime.now().toIso8601String();

    final newStorage = DietStorage(
      originalDietPlan: knownOriginal ?? current,
      currentDietPlan: current,
      originalRaw: keepExisting ? existing.originalRaw : (knownOriginal != null ? review.originalPlanDataRaw : currentRaw),
      currentRaw: currentRaw,
      expertModifications: _badgeModifications(current, knownOriginal, review.expertName, when),
      isExpertPlan: true,
      expertName: review.expertName,
      expertId: review.expertId,
      expertNotes: review.expertNotes,
      reviewedAt: when,
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

  /// A deep copy of a stored plan with every day's `meals` as a list (older
  /// reviews stored an object keyed by meal name) — the shape both clients read.
  static Map<String, dynamic> _planMapWithMealLists(Map<String, dynamic> raw) {
    Object? copy(Object? v) {
      if (v is Map) return {for (final e in v.entries) e.key.toString(): copy(e.value)};
      if (v is List) return [for (final x in v) copy(x)];
      return v;
    }

    final out = (copy(raw) as Map).cast<String, dynamic>();
    final days = out['days'];
    if (days is List) {
      out['days'] = [
        for (final d in days)
          if (d is Map)
            {
              ...d.cast<String, dynamic>(),
              'meals': d['meals'] is Map ? (d['meals'] as Map).values.toList() : (d['meals'] ?? const []),
            }
          else
            d,
      ];
    }
    return out;
  }

  /// Badges only — see [acceptExpertReview]. A meal is marked when the
  /// expert's editor flagged it, or when it differs from (or is absent in) a
  /// known original.
  static Map<String, Map<String, ExpertMealModification>> _badgeModifications(
    DietPlanContent reviewed,
    DietPlanContent? original,
    String? expertName,
    String when,
  ) {
    final mods = <String, Map<String, ExpertMealModification>>{};
    for (var d = 0; d < reviewed.days.length; d++) {
      final origMeals =
          (original != null && d < original.days.length) ? original.days[d].meals : const <DietMeal>[];
      for (final meal in reviewed.days[d].meals) {
        DietMeal? orig;
        for (final m in origMeals) {
          if (m.mealKey == meal.mealKey) {
            orig = m;
            break;
          }
        }
        final snap = meal.toModificationSnapshot();
        final changed = meal.edited ||
            (original != null &&
                (orig == null || jsonEncode(orig.toModificationSnapshot()) != jsonEncode(snap)));
        if (!changed) continue;
        mods.putIfAbsent('$d', () => {})[meal.mealKey] = ExpertMealModification(
          modified: true,
          modifiedBy: meal.modifiedBy ?? expertName,
          modifiedAt: meal.modifiedAt ?? when,
          oldMeal: orig?.toModificationSnapshot() ?? const {'foods': <String>[]},
          newMeal: snap,
        );
      }
    }
    return mods;
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

/// An expert review that cannot be accepted. Nothing was written.
class DietAcceptException implements Exception {
  const DietAcceptException(this.message);

  final String message;

  @override
  String toString() => message;
}
