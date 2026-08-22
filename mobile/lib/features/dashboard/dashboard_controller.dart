import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/steps/step_history.dart';
import '../../core/steps/step_tracking_service.dart';
import 'data/dashboard_repository.dart';
import 'data/health_status_store.dart';
import 'models/activity_day_model.dart';
import 'models/assigned_coach.dart';
import 'models/activity_week.dart';
import 'models/daily_score.dart';
import 'models/goal_model.dart';
import 'models/health_status.dart';
import 'models/weight_entry.dart';
import '../membership/data/entitlements_repository.dart';

/// Aggregates every Dashboard data source and exposes plain fields for the
/// presentation widgets. Each fetch is isolated in its own try/catch —
/// mirrors `dashboard.js`'s `safeRun(name, fn)` wrapper, which guarantees
/// one section throwing never blocks the others from rendering (see
/// docs' §11 "dashboard states" requirement). No fake data is ever
/// substituted on failure — sections simply keep their empty/loading value.
class DashboardController extends ChangeNotifier {
  // Kept as a `repository:` named param (not a `this._repository`
  // initializing formal) so the public constructor API doesn't expose the
  // private field name it assigns to.
  DashboardController({
    required this.uid,
    required DashboardRepository repository,
    HealthStatusStore? healthStore,
    StepTrackingService? stepService,
    EntitlementsRepository? entitlements,
  }) : _repository = repository, // ignore: prefer_initializing_formals
       _healthStore = healthStore ?? HealthStatusStore(),
       _entitlements = entitlements ?? EntitlementsRepository(),
       _stepService = stepService { // ignore: prefer_initializing_formals
    _init();
  }

  final String uid;
  final DashboardRepository _repository;
  final HealthStatusStore _healthStore;

  /// The server-side weekly allowance. Reset is the only metered action the
  /// dashboard owns; swaps and recipes are gated at their own endpoints.
  final EntitlementsRepository _entitlements;

  /// Constructed lazily so tests (and any non-Android surface) can run the
  /// Dashboard without LocalStorageService being initialized.
  StepTrackingService? _stepService;
  StepTrackingService get _steps => _stepService ??= StepTrackingService();

  StreamSubscription<Map<String, dynamic>?>? _userDocSub;
  StreamSubscription<int>? _unreadSub;

  bool _disposed = false;

  // -- Live, from users/{uid} (matches cloud-sync.js's attachRealtime scope) --
  bool userDocLoading = true;
  Object? userDocError;
  GoalModel? goal;
  bool hasSwot = false;
  bool hasWorkoutPlan = false;
  bool hasDietPlan = false;
  bool isExpertPlan = false;
  String? displayName;
  String? photoUrl;
  int currentStreak = 0;
  int longestStreak = 0;

  // -- One-time reads --
  bool activityLoading = true;
  Object? activityError;
  ActivityDayModel? todayActivity;

  /// Archived day docs (today excluded) backing the Mon–Sun strip and the
  /// adaptive-goal suggestion.
  Map<String, ActivityDayModel> activityHistory = const {};

  /// The athlete's BASE daily step goal (`users/{uid}.dailyStepGoal`).
  int dailyStepGoal = 10000;

  /// True when `users/{uid}.dailyStepGoal` was actually present — i.e. the
  /// athlete (or the adaptive-goal apply) set a goal explicitly. When it
  /// wasn't, the Assessment's own recommendation is the better default than
  /// a hardcoded 10,000; see [effectiveStepGoal].
  bool _hasExplicitStepGoal = false;

  /// The goal actually in force today, resolving the existing chain in
  /// priority order — no new field is introduced:
  ///
  ///   1. `activity/{date}.goalEffective` — Recovery Mode's reduced/paused
  ///      goal for today (0 = "Rest", a deliberately paused goal).
  ///   2. `users/{uid}.dailyStepGoal` — the athlete's own explicit goal.
  ///   3. `calculations.daily_steps_goal` — what the Assessment recommended.
  ///   4. 10,000 — last-resort default.
  int get effectiveStepGoal {
    final recovery = todayActivity?.goalEffective;
    if (recovery != null) return recovery;
    if (_hasExplicitStepGoal) return dailyStepGoal;
    if (healthBaseStepsGoal > 0) return healthBaseStepsGoal;
    return dailyStepGoal;
  }

  // -- Real step tracking (core/steps) --
  StepSnapshot? stepSnapshot;
  bool stepRefreshing = false;

  /// Whether the athlete has opted into step tracking.
  bool get stepTrackingEnabled => _steps.isEnabled;

  bool weightLoading = true;
  List<WeightEntry> weightHistory = const [];

  double? mealScoreAvg;
  bool hasActiveCoaching = false;

  /// The athlete's assigned Personal Coach — null when unassigned. Fed by a
  /// live listener so an acceptance lands without a refresh.
  AssignedCoach? assignedCoach;
  StreamSubscription<AssignedCoach?>? _coachSub;

  // -- Health Status / Recovery Mode (health-status.js) --
  HealthAdjustment? healthToday;
  bool healthTodayGreat = false;
  List<HealthHistoryEntry> healthHistory = const [];

  /// `baseStepsGoal()` — `zitlas_calculations.daily_steps_goal`, default 7000.
  int healthBaseStepsGoal = 7000;

  /// From `zitlas_precautions` — gate inputs for the safety rules.
  bool hasCriticalCondition = false;
  bool hasAsthma = false;

  // -- Live notification bell --
  int unreadNotifications = 0;

  /// `available(getWallet())` in wallet.js — spendable balance
  /// (`balance - reserved`) from `users/{uid}.wallet`. Backend-written only;
  /// the client never writes it (FIRESTORE_SECURITY_AUDIT.md V2).
  num walletAvailable = 0;

  DailyScoreResult? get dailyScore {
    final activity = todayActivity;
    if (activity == null) return null;
    return DailyScoreResult.compute(
      DailyScoreInputs(
        steps: activity.steps,
        stepsGoal: activity.goal,
        waterMl: activity.waterMl,
        waterGoalMl: activity.waterGoalMl,
        sleepHours: activity.sleepHours,
        mealScoreAvg: mealScoreAvg,
        workoutCompleted: activity.workoutCompleted,
      ),
    );
  }

  /// `ZitlasActivity.getWeeklySummary()` — the Mon–Sun strip.
  List<WeekDaySummary> get weeklySummary =>
      buildWeeklySummary(history: activityHistory, today: todayActivity);

  /// `getAdaptiveGoalSuggestion()` — suppressed during Recovery Mode, exactly
  /// like `renderStepCounterCard()` (`if (!d.recovery_mode && …)`).
  AdaptiveGoalSuggestion? get adaptiveGoalSuggestion {
    if (todayActivity?.recoveryMode ?? false) return null;
    return computeAdaptiveGoalSuggestion(history: activityHistory, goal: dailyStepGoal);
  }

  /// `getStatusMessage()` — all four branches.
  String get activityStatus => activityStatusMessage(todayActivity);

  /// Matches `expert-review-promo.js`'s `baseEligible()` +
  /// `refineWithCoachingStatus()`.
  bool get expertPromoEligible =>
      (hasDietPlan || hasWorkoutPlan) && !isExpertPlan && !hasActiveCoaching;

  void _init() {
    _userDocSub = _repository.watchUserDoc(uid).listen(
      (data) {
        userDocLoading = false;
        userDocError = null;
        _applyUserDoc(data);
        _safeNotify();
      },
      onError: (Object e) {
        userDocLoading = false;
        userDocError = e;
        _safeNotify();
      },
    );

    _unreadSub = _repository.watchUnreadNotificationCount(uid).listen(
      (unread) {
        unreadNotifications = unread;
        _safeNotify();
      },
      onError: (_) {
        // Bell badge just stays at its last known value — non-critical.
      },
    );

    unawaited(_loadOneTimeSections());
    _watchAssignedCoach();
  }

  void _applyUserDoc(Map<String, dynamic>? data) {
    if (data == null) {
      goal = null;
      hasSwot = false;
      hasWorkoutPlan = false;
      hasDietPlan = false;
      isExpertPlan = false;
      displayName = null;
      photoUrl = null;
      currentStreak = 0;
      longestStreak = 0;
      dailyStepGoal = 10000;
      walletAvailable = 0;
      return;
    }
    goal = GoalModel.fromMap(data['goal'] as Map<String, dynamic>?);
    hasSwot = data['swot'] != null;
    final workoutPlan = data['workoutPlan'] as Map<String, dynamic>?;
    final dietPlan = data['dietPlan'] as Map<String, dynamic>?;
    hasWorkoutPlan = workoutPlan != null;
    hasDietPlan = dietPlan != null;
    isExpertPlan = (dietPlan?['isExpertPlan'] == true) || (workoutPlan?['isExpertPlan'] == true);
    final personalInfo = data['personalInfo'] as Map<String, dynamic>?;
    displayName = personalInfo?['fullName'] as String? ?? data['name'] as String?;
    photoUrl = personalInfo?['photo'] as String? ?? data['photo'] as String?;
    currentStreak = (data['currentStreak'] as num?)?.toInt() ?? 0;
    longestStreak = (data['longestStreak'] as num?)?.toInt() ?? 0;
    final explicitGoal = (data['dailyStepGoal'] as num?)?.toInt();
    _hasExplicitStepGoal = explicitGoal != null && explicitGoal > 0;
    dailyStepGoal = explicitGoal ?? 10000;

    // health-status.js reads these from `zitlas_calculations` /
    // `zitlas_precautions`, which cloud-sync mirrors onto the user doc.
    final calculations = data['calculations'] as Map<String, dynamic>?;
    healthBaseStepsGoal = (calculations?['daily_steps_goal'] as num?)?.toInt() ?? 7000;
    final precautions = data['precautions'] as Map<String, dynamic>?;
    hasCriticalCondition =
        (precautions?['directives'] as Map?)?['overall_severity'] == 'critical';
    final conditions = (precautions?['conditions'] as List?) ?? const [];
    hasAsthma = conditions.any((c) => c.toString().toLowerCase().contains('asthma'));

    final wallet = data['wallet'] as Map<String, dynamic>?;
    final balance = (wallet?['balance'] as num?) ?? 0;
    final reserved = (wallet?['reserved'] as num?) ?? 0;
    walletAvailable = balance - reserved < 0 ? 0 : balance - reserved;
  }

  Future<void> _loadOneTimeSections() async {
    await Future.wait([
      _loadActivity(),
      _loadActivityHistory(),
      _loadHealthStatus(),
      _loadWeightHistory(),
      _loadMealScore(),
      _loadCoachingStatus(),
    ]);
  }

  Future<void> _loadActivity() async {
    try {
      todayActivity = await _repository.fetchTodayActivity(uid);
      activityError = null;
    } catch (e) {
      activityError = e;
    } finally {
      activityLoading = false;
      _safeNotify();
    }
  }

  Future<void> _loadActivityHistory() async {
    try {
      activityHistory = await _repository.fetchActivityHistory(uid);
      // Seed the local record from the synced day docs. Local storage is
      // wiped by a reinstall and doesn't exist at all on a second device, so
      // without this an athlete's history would appear to start over every
      // time — even though every day of it is sitting in Firestore.
      await _steps.hydrateHistory({
        for (final e in activityHistory.entries)
          e.key: (steps: e.value.steps, goal: e.value.effectiveGoal),
      });
      _safeNotify();
    } catch (_) {
      // Weekly strip falls back to "missed" for unreadable days and the
      // adaptive suggestion simply doesn't appear — neither is critical.
    }
  }

  /// One-tap apply for the adaptive goal suggestion — mirrors `#sacApplyGoal`
  /// (`setDailyGoal` + re-render + toast). Never applied silently.
  Future<void> applyAdaptiveGoal(int goal) async {
    await _repository.setDailyStepGoal(uid, goal);
    dailyStepGoal = goal;
    _safeNotify();
    await _loadActivity();
  }

  Future<void> _loadWeightHistory() async {
    try {
      weightHistory = await _repository.fetchWeightHistory(uid);
    } catch (_) {
      weightHistory = const [];
    } finally {
      weightLoading = false;
      _safeNotify();
    }
  }

  Future<void> _loadMealScore() async {
    try {
      mealScoreAvg = await _repository.fetchTodayMealScoreAvg(uid);
      _safeNotify();
    } catch (_) {
      // Daily score simply omits the meal-quality input.
    }
  }

  Future<void> _loadCoachingStatus() async {
    try {
      hasActiveCoaching = await _repository.hasActiveCoaching(uid);
      _safeNotify();
    } catch (_) {
      // Defaults to false — expert promo may show when it shouldn't in the
      // rare case this read fails, which is the safer failure direction.
    }
  }

  /// The assigned coach, live.
  ///
  /// A listener rather than a one-shot read: the moment the expert accepts,
  /// the backend writes the relationship and this card appears on the
  /// athlete's dashboard without them touching anything.
  void _watchAssignedCoach() {
    _coachSub?.cancel();
    _coachSub = _repository.watchAssignedCoach(uid).listen(
      (coach) {
        assignedCoach = coach;
        // The live listener is now the sole owner of this flag: it flips
        // true the instant an assignment lands and false the instant End
        // Coaching (on the Coach Profile screen) commits — neither edge
        // waits for the one-shot read in `_loadCoachingStatus`.
        hasActiveCoaching = coach != null;
        _safeNotify();
      },
      onError: (Object e) {
        if (kDebugMode) debugPrint('[COACH] assignment stream error: $e');
      },
    );
  }

  Future<void> _loadHealthStatus() async {
    try {
      healthToday = await _healthStore.loadToday();
      healthTodayGreat = healthToday == null && await _healthStore.isTodayGreat();
      healthHistory = await _healthStore.loadHistory();
      _safeNotify();
    } catch (_) {
      // Card simply renders its neutral "how are you feeling?" state.
    }
  }

  /// `submitReport()` — computes the deterministic adjustment, persists it,
  /// mirrors the effective step goal onto today's activity doc, and fires the
  /// coach alert + self-notification. "Feeling great" clears any override
  /// instead of storing one.
  Future<void> submitHealthReport(HealthReport report) async {
    final adj = computeHealthAdjustments(
      report,
      baseStepsGoal: healthBaseStepsGoal,
      hasCriticalCondition: hasCriticalCondition,
      hasAsthma: hasAsthma,
    );

    if (adj.status == 'great') {
      await _healthStore.recordGreat();
      await _repository.applyRecoveryGoalToToday(
        uid,
        baseGoal: healthBaseStepsGoal,
        effectiveGoal: healthBaseStepsGoal,
        recoveryMode: false,
      );
    } else {
      await _healthStore.saveToday(adj);
      await _repository.applyRecoveryGoalToToday(
        uid,
        baseGoal: adj.oldStepsGoal,
        effectiveGoal: adj.effectiveStepsGoal,
        recoveryMode: true,
      );
      unawaited(_alertCoach(adj));
      unawaited(_notifySelf(adj));
    }

    await _loadHealthStatus();
    await _loadActivity();
  }

  /// `hsClearStatusChip` — clears ONLY today's override, restoring the
  /// original workout/diet/step goal.
  Future<void> clearHealthStatus() async {
    await _healthStore.clearToday();
    await _repository.applyRecoveryGoalToToday(
      uid,
      baseGoal: healthBaseStepsGoal,
      effectiveGoal: healthBaseStepsGoal,
      recoveryMode: false,
    );
    await _loadHealthStatus();
    await _loadActivity();
  }

  String _healthSummary(HealthAdjustment adj) {
    final buf = StringBuffer(healthStatusLabel(adj.status));
    if (adj.symptoms.isNotEmpty) buf.write(' — ${adj.symptoms.join(', ')}');
    if (adj.bodyParts.isNotEmpty) buf.write(' — ${adj.bodyParts.join(', ')}');
    if (adj.severity != null) buf.write(' (${adj.severity})');
    if (adj.painLevel != null && adj.painLevel != 0) {
      buf.write(' (pain ${adj.painLevel}/10)');
    }
    return buf.toString();
  }

  /// Notifies the active Personal Coach that their client reported a wellness
  /// event — WITHOUT having touched the coach's plan.
  ///
  /// A coach-authored plan is never auto-overridden: `DietController`'s
  /// `isExpertPlan` guard and `WorkoutController`'s `_coachOverrideActive`
  /// guard both refuse the wellness override, deliberately, because deciding
  /// whether a sick client should still train is the coach's judgement call,
  /// not the app's.
  ///
  /// The wording below has to say so explicitly. It previously read
  /// "Today's workout: <title>. Diet: <title>." — which described the
  /// adjustment the app COMPUTED, not what it applied, and so told a coach
  /// their plan had been changed when it demonstrably had not.
  ///
  /// This runs independently of those two rendering guards: the coach is
  /// notified whether or not any override was applied, which is the whole
  /// point for a coached athlete.
  Future<void> _alertCoach(HealthAdjustment adj) async {
    try {
      final summary = _healthSummary(adj);
      final name = displayName ?? 'User';
      final label = healthStatusLabel(adj.status);

      // Sick affects both plans; an injury is a training concern.
      final untouched = adj.status == 'injured'
          ? 'Their current training plan has NOT been automatically changed.'
          : 'Their current diet and training plan have NOT been automatically '
              'changed.';
      final body = '$name marked today as $label. $untouched '
          'Please review if any adjustment is required.';
      final safetyLine = adj.safety
          ? '\n⚠ Advised to seek medical attention before exercising.'
          : '';
      final chatText = '🩺 Wellness update — $summary.\n$body$safetyLine'
          '${adj.note.isEmpty ? '' : '\nNote: ${adj.note}'}';

      await _repository.sendHealthAlert(
        uid: uid,
        athleteName: name,
        summary: summary,
        title: 'Client Wellness Update',
        message: body,
        chatText: chatText,
        eventId: wellnessEventId(uid: uid, date: adj.date, status: adj.status),
        alert: {
          'status': adj.status,
          'date': adj.date,
          'symptoms': adj.symptoms,
          'severity': adj.severity,
          'bodyParts': adj.bodyParts,
          'painLevel': adj.painLevel,
          'sleepHours': adj.sleepHours,
          'stressLevel': adj.stressLevel,
          'notes': adj.note,
          'safety': adj.safety,
          // Records that the coach's plan was left alone, so nothing reading
          // this document can mistake the advisory block below for an
          // applied change.
          'planModified': false,
          // Kept under the website's own field names (health-status.js:315)
          // for schema parity. ADVISORY only for a coached athlete — what
          // the deterministic rules would have suggested, never applied.
          'newWorkout': adj.workout?.toMap(),
          'newDiet': adj.diet == null
              ? null
              : {'focus': adj.diet!.title, 'items': adj.diet!.items},
          'oldStepsGoal': adj.oldStepsGoal,
          'newStepsGoal': adj.stepsGoal ?? 'Rest',
        },
      );
    } catch (_) {
      // No coach, or the write failed — the local adjustment still stands.
    }
  }

  /// The athlete's own confirmation.
  ///
  /// Says something DIFFERENT depending on whether a coach owns the plan,
  /// because only one of the two outcomes actually happened. Telling a
  /// coached athlete "today's plan adjusted" would be a straight
  /// contradiction of the `isExpertPlan`/`_coachOverrideActive` guards, which
  /// deliberately leave a coach-authored plan exactly as the coach wrote it.
  Future<void> _notifySelf(HealthAdjustment adj) async {
    try {
      final coached = hasActiveCoaching;
      final parts = [
        if (adj.workout != null) 'Workout: ${adj.workout!.title}',
        if (adj.diet != null) 'Diet: ${adj.diet!.title}',
      ];
      final title = adj.safety
          ? '⚠ Seek medical attention before exercising'
          : coached
              ? '${healthStatusLabel(adj.status)} — your coach has been notified'
              : "${healthStatusLabel(adj.status)} — today's plan adjusted";
      final message = coached
          ? 'Your coach will review whether your plan needs any change. '
              'Until then it stays exactly as they set it.'
          : parts.join(' · ');

      await _repository.sendSelfNotification(
        uid: uid,
        title: title,
        message: message,
        type: 'health_status_${adj.status}',
        priority: adj.safety ? 'critical' : 'medium',
      );
    } catch (_) {
      // Non-critical.
    }
  }

  /// Pull-to-refresh: re-runs every one-time read. The live streams
  /// (user doc, unread count) don't need re-subscribing.
  Future<void> refresh() async {
    activityLoading = true;
    weightLoading = true;
    _safeNotify();
    await _loadOneTimeSections();
    await refreshSteps();
  }

  /// Re-reads today's REAL step total and syncs it.
  ///
  /// Called on Dashboard open, on app resume, after permission is granted,
  /// and on pull-to-refresh. Each call is a single aggregate/sensor read —
  /// cheap enough to run on resume, deliberately not polled on a timer.
  Future<void> refreshSteps() async {
    // Permissions live in the OS, not in ZITLAS. If Android still says the
    // grant is held, tracking resumes silently — this is what stops the
    // "Enable" prompt reappearing after a sign-out, a cleared cache, or a
    // reinstall on a phone that already granted it once.
    if (!_steps.isEnabled) {
      await _steps.ensureTrackingActive();
    }

    if (!_steps.isEnabled) {
      // Still surface the reason so the card can offer "Enable" rather than
      // rendering a misleading 0.
      stepSnapshot = await _steps.refresh(goal: effectiveStepGoal);
      _safeNotify();
      return;
    }

    // Re-arm the native midnight capture. Cheap, idempotent, and necessary:
    // Android clears an app's alarms on force-stop, so this is the only thing
    // that repairs daily rollover afterwards.
    unawaited(_steps.scheduleDayBoundary());
    stepRefreshing = true;
    _safeNotify();
    try {
      final snapshot = await _steps.refresh(goal: effectiveStepGoal);
      stepSnapshot = snapshot;

      if (snapshot.isAvailable) {
        // Local storage already has it (StepTrackingService writes there
        // first), so this sync is best-effort: an offline device keeps every
        // step and simply syncs on the next successful refresh.
        try {
          await _repository.saveDailySteps(
            uid,
            date: snapshot.dayKey,
            steps: snapshot.steps,
            goal: snapshot.goal,
            goalCompleted: snapshot.goalReached,
          );
        } catch (e) {
          if (kDebugMode) debugPrint('[STEPS] Firestore sync deferred: $e');
        }
        await _loadActivity();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[STEPS] refresh failed: $e');
    } finally {
      stepRefreshing = false;
      _safeNotify();
    }

    // Once per launch: rebuild past days from Health Connect's own timestamped
    // records. This is the only thing that can recover a day ZITLAS wasn't
    // open for, and it's what makes "Yesterday" real rather than blank.
    if (!_backfilled) {
      _backfilled = true;
      try {
        if (await _steps.backfillFromHealthConnect() > 0) await _loadActivity();
      } catch (e) {
        if (kDebugMode) debugPrint('[STEPS] backfill skipped: $e');
      }
    }

    await _refreshStreaks();
  }

  bool _backfilled = false;

  /// Recomputes both streaks from the REAL recorded days and persists them.
  ///
  /// They used to be read from the user doc and never written by the app, so
  /// on a phone-only account they sat at whatever the website last wrote —
  /// usually 0, no matter how many goals were actually hit.
  Future<void> _refreshStreaks() async {
    final history = stepHistory;
    if (history.isEmpty) return;
    final now = DateTime.now();
    final current = history.currentStreak(today: now);
    final longest = history.longestStreak();
    // The record can only ever grow — a 90-day local window must not shorten a
    // longest streak that was set before the window began.
    final best = longest > longestStreak ? longest : longestStreak;
    if (current == currentStreak && best == longestStreak) return;

    currentStreak = current;
    longestStreak = best;
    _safeNotify();
    try {
      await _repository.saveStreaks(uid, current: current, longest: best);
    } catch (e) {
      if (kDebugMode) debugPrint('[STEPS] streak sync deferred: $e');
    }
  }

  /// Every locally recorded day, for the Dashboard stats and History screen.
  StepHistory get stepHistory => StepHistory(_steps.readHistory());

  /// Runs the real consent + OS permission flow, then reads immediately so
  /// the ring fills in without another interaction.
  Future<bool> enableStepTracking({
    required Future<bool> Function() runConsentFlow,
  }) async {
    final enabled = await runConsentFlow();
    if (enabled) await refreshSteps();
    _safeNotify();
    return enabled;
  }

  Future<void> setGoal(GoalModel newGoal) async {
    await _repository.saveGoal(uid, newGoal);
  }

  /// Reset the goal, if the weekly allowance permits it.
  ///
  /// METERED: free 2/week, premium 5/week. The unit is reserved BEFORE the
  /// Firestore write, and a refusal aborts the reset entirely — otherwise
  /// the limit would be advisory, since the reset is a client-side write the
  /// backend never sees.
  ///
  /// Returns the outcome so the caller can show the real reason; a denied
  /// reset must never look like a silent no-op.
  Future<ConsumeOutcome> resetGoal() async {
    final outcome = await _entitlements.consume('goal_reset');
    if (!outcome.allowed) return outcome;
    await _repository.resetGoal(uid);
    return outcome;
  }

  Future<void> logWater(int deltaMl) async {
    await _repository.logWater(uid, deltaMl);
    await _loadActivity();
  }

  Future<void> logSleep(double hours) async {
    await _repository.logSleep(uid, hours);
    await _loadActivity();
  }

  Future<void> logWeight(double kg) async {
    await _repository.logWeight(uid, kg);
    await _loadWeightHistory();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _userDocSub?.cancel();
    _unreadSub?.cancel();
    _coachSub?.cancel();
    super.dispose();
  }
}
