import 'package:flutter/foundation.dart';

import '../../core/location/diet_region_repository.dart';
import '../../core/network/api_exception.dart';
import '../../core/util/json_coerce.dart';
import 'data/assessment_repository.dart';
import 'models/assessment_question.dart';

enum AssessmentScreen { welcome, goal, assess, processing, snapshot, swot, diet, workout, done }

/// `PROC_STEPS` — the fixed 8-step progress list shown on the Processing
/// screen while the real backend call runs in parallel.
const List<({String icon, String label})> kProcessingSteps = [
  (icon: '📋', label: 'Analyzing your profile…'),
  (icon: '⚖️', label: 'Calculating BMI & BMR…'),
  (icon: '🔥', label: 'Computing calorie targets…'),
  (icon: '🧠', label: 'Building SWOT profile…'),
  (icon: '📚', label: 'Searching research database…'),
  (icon: '🥗', label: 'Generating your diet plan…'),
  (icon: '💪', label: 'Creating workout program…'),
  (icon: '✨', label: 'Finalizing recommendations…'),
];

/// Drives the 9-screen Assessment wizard. Mirrors `ai-coach.js`'s `state` +
/// `showScreen()`/`advanceQuestion()`/`callGeneratePlan()`/
/// `saveToLocalStorage()` exactly:
/// - `getActiveQuestions()` → [activeQuestions] (branches on [selectedGoal]).
/// - Option/multiselect answers are stored RAW (no `parse()` call) — the
///   website only ever calls a question's `parse()` for `text`/`slider`
///   types; `buildPayload()` does its own `parseInt` at submit time for the
///   numeric option fields (`available_time`, `goal_duration_months`). This
///   class reproduces that exact division of responsibility.
/// - The plan is persisted to Firestore the MOMENT generation succeeds
///   (before the Snapshot screen even renders), not deferred to the final
///   "Done" button — matches `callGeneratePlan()`'s `saveToLocalStorage(apiData)`
///   call ordering.
class AssessmentController extends ChangeNotifier {
  AssessmentController({required this.uid, required this._repository, this.regionRepository}) {
    _loadPreferredRegion();
  }

  bool _disposed = false;

  // Guards dispose-during-notify: an async region/assessment callback can fire
  // after this controller is disposed (the athlete leaves the screen).
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  final String uid;
  final AssessmentRepository _repository;
  final DietRegionRepository? regionRepository;

  /// Geo-Aware Food Intelligence — the CONFIRMED `preferredDietRegion`
  /// (Phase: location permission + intelligent swap-meal UX), never a fresh
  /// silent GPS call here. The interactive consent/confirm/manual-picker
  /// flow lives at the screen layer (`runLocationSetupFlow()`); this
  /// controller only ever reads the persisted result, so a stale device
  /// location can never re-ask or silently change an established
  /// preference mid-assessment.
  Map<String, dynamic> _locationPayload = const {};
  String? preferredRegion;

  static Map<String, dynamic> _payloadFor(String? region) =>
      (region == null || region.isEmpty) ? const {} : {'state': region};

  Future<void> _loadPreferredRegion() async {
    final repo = regionRepository;
    if (repo == null) return;
    try {
      final region = await repo.fetchOnce(uid);
      preferredRegion = region;
      _locationPayload = _payloadFor(region);
      if (kDebugMode && region != null) debugPrint('[DIET] loaded preferredDietRegion = $region');
      notifyListeners();
    } catch (_) {
      // No-op — matches the website's "location is 100% optional" rule.
    }
  }

  /// Called by the Assessment screen once the (one-time) location consent
  /// flow resolves — whether the athlete allowed GPS, picked a state
  /// manually, or dismissed entirely (`region == null`, a clean no-op).
  void setPreferredRegion(String? region) {
    preferredRegion = region;
    _locationPayload = _payloadFor(region);
    notifyListeners();
  }

  AssessmentScreen screen = AssessmentScreen.welcome;
  String selectedGoal = 'lose_weight';
  final Map<String, dynamic> answers = {};
  int currentQuestionIndex = 0;

  bool submitting = false;

  /// Plan generation failed — nothing to show.
  Object? submitError;

  /// Generation SUCCEEDED but the Firestore write didn't. The plan is
  /// displayable but won't survive leaving the wizard until it's saved.
  Object? persistError;

  AssessmentResult? apiResult;
  String? planId;

  /// Honest, specific failure text — never a generic "check your connection"
  /// for what was actually a validation or server error. Distinguishes
  /// transport failure / timeout / unauthorized / server error / malformed
  /// response, so a real outage is never mistaken for a data problem.
  String? get submitErrorMessage {
    final e = submitError;
    if (e == null) return null;
    if (e is ApiException) {
      if (e.isNetworkError) {
        return "Couldn't reach the ZITLAS server. Check your internet connection and try again.";
      }
      if (e.isUnauthorized) {
        return 'Your session has expired. Sign out and sign back in, then try again.';
      }
      if (e.isServerError) {
        return 'The server had a problem generating your plan (error ${e.statusCode}). '
            'Please try again in a moment.';
      }
      if (e.statusCode == 422) {
        return "Some of your answers weren't accepted by the server: ${e.message}";
      }
      return 'Could not generate your plan (error ${e.statusCode}). Please try again.';
    }
    if (e is FormatException) {
      return 'The server sent back an unexpected response. Please try again.';
    }
    return 'Something went wrong generating your plan. Please try again.';
  }

  String? get persistErrorMessage =>
      persistError == null ? null : "Your plan was generated but couldn't be saved to your account.";

  List<AssessmentQuestion> get activeQuestions => questionsForGoal(selectedGoal);
  AssessmentQuestion? get currentQuestion {
    final qs = activeQuestions;
    return currentQuestionIndex < qs.length ? qs[currentQuestionIndex] : null;
  }

  int get totalQuestions => activeQuestions.length;

  void _go(AssessmentScreen s) {
    screen = s;
    notifyListeners();
  }

  // ── S1 → S2 ──
  void startFromWelcome() => _go(AssessmentScreen.goal);

  // ── S2 ──
  void selectGoal(String goal) {
    selectedGoal = goal;
    notifyListeners();
  }

  /// `btnGoalNext` — resets the question cursor/answers exactly like the
  /// website (`state.currentQ = 0; state.answers = {};`), so re-entering the
  /// goal screen and picking a different goal always starts a clean run.
  void startAssessment() {
    currentQuestionIndex = 0;
    answers.clear();
    _go(AssessmentScreen.assess);
  }

  // ── S3 ──
  /// `assessBackBtn` — first question goes back to Goal Selection, not exit.
  void backFromQuestion() {
    if (currentQuestionIndex == 0) {
      _go(AssessmentScreen.goal);
    } else {
      currentQuestionIndex--;
      notifyListeners();
    }
  }

  /// Records an answer WITHOUT advancing — used for multiselect toggles
  /// where the athlete can change their mind before tapping Continue.
  void setAnswer(String field, dynamic value) {
    answers[field] = value;
    notifyListeners();
  }

  /// Options/slider/wheel/unit-toggle question types: store then advance in
  /// one step, matching the website's per-type click handlers.
  Future<void> answerAndAdvance(String field, dynamic value) async {
    answers[field] = value;
    await _advance();
  }

  /// Text question types: validates first (`q.validate`), returns an error
  /// message to show inline on failure instead of advancing — mirrors
  /// `submit()`'s `if (!valid) { show errEl; return; }`.
  Future<String?> submitTextAnswer(AssessmentQuestion q, String raw) async {
    final trimmed = raw.trim();
    if (q.validate != null && !q.validate!(trimmed)) {
      return q.errMsg ?? 'Please enter a valid value';
    }
    answers[q.field] = q.parse != null ? q.parse!(trimmed) : trimmed;
    await _advance();
    return null;
  }

  /// Multiselect Continue button — `if (selected.length === 0) show error`.
  Future<String?> submitMultiselectAnswer(String field) async {
    // Type-checked (same reason as QuestionView.initState): a stored answer
    // that isn't a list must surface the normal validation message, never a
    // failed cast that takes the whole wizard down.
    final sel = asStringList(answers[field]);
    if (sel.isEmpty) return 'Please select at least one option';
    await _advance();
    return null;
  }

  Future<void> _advance() async {
    currentQuestionIndex++;
    if (currentQuestionIndex >= totalQuestions) {
      await _startProcessing();
    } else {
      notifyListeners();
    }
  }

  // ── S4: Processing + real API call ──
  Future<void> _startProcessing() async {
    _go(AssessmentScreen.processing);
    submitting = true;
    submitError = null;
    persistError = null;

    // `_locationPayload` was already populated from the persisted
    // `preferredDietRegion` by `_loadPreferredRegion()`/`setPreferredRegion()`
    // — no fresh GPS call here. GPS only ever runs once, during the
    // interactive consent flow the Assessment screen drives.
    if (kDebugMode) debugPrint('[DIET] generating with region = ${preferredRegion ?? '(none)'}');

    final minWait = Future<void>.delayed(Duration(milliseconds: kProcessingSteps.length * 800 + 600));

    // Generation and persistence are settled SEPARATELY on purpose. A
    // Firestore write failure must not discard a plan the backend already
    // generated — the athlete should still see it (and be able to retry the
    // save) rather than be told "could not load data" and lose 15 answers.
    AssessmentResult? result;
    try {
      result = await _repository.generatePlan(_buildPayload());
    } catch (e, st) {
      _logFailure('generate-plan', e, st);
      submitError = e;
    }

    if (result != null) {
      apiResult = result;
      try {
        planId = await _repository.saveAssessmentResult(
          uid: uid,
          answers: Map<String, dynamic>.from(answers),
          goal: _buildGoalMap(),
          result: result,
          location: _locationPayload,
        );
      } catch (e, st) {
        _logFailure('saveAssessmentResult', e, st);
        persistError = e;
      }
    }

    await minWait;
    submitting = false;
    _go(AssessmentScreen.snapshot);
  }

  /// Re-runs generation with the answers already collected — the athlete
  /// never has to retake the questionnaire because of a transient failure.
  Future<void> retryGeneration() => _startProcessing();

  /// Retries ONLY the Firestore write, for the case where generation
  /// succeeded but persistence didn't.
  Future<void> retryPersist() async {
    final result = apiResult;
    if (result == null) return;
    persistError = null;
    notifyListeners();
    try {
      planId = await _repository.saveAssessmentResult(
        uid: uid,
        answers: Map<String, dynamic>.from(answers),
        goal: _buildGoalMap(),
        result: result,
      );
    } catch (e, st) {
      _logFailure('saveAssessmentResult(retry)', e, st);
      persistError = e;
    }
    notifyListeners();
  }

  /// Debug-only. Never logs tokens, credentials, or the request body (which
  /// contains the athlete's biometrics) — only the failure classification.
  void _logFailure(String op, Object e, StackTrace st) {
    if (!kDebugMode) return;
    final detail = e is ApiException
        ? 'ApiException status=${e.statusCode ?? 'none (transport)'} message=${e.message}'
        : '${e.runtimeType}: $e';
    debugPrint('[ASSESSMENT] $op FAILED — $detail');
    debugPrintStack(stackTrace: st, maxFrames: 6);
  }

  // ── S5 → S6 → S7 → S8 → S11 ──
  void goToSwot() => _go(AssessmentScreen.swot);
  void goToDiet() => _go(AssessmentScreen.diet);
  void goToWorkout() => _go(AssessmentScreen.workout);
  void goToDone() => _go(AssessmentScreen.done);

  bool get isGeneralFitness => selectedGoal == 'general_fitness';
  bool get isMuscleGain => selectedGoal == 'muscle_gain';
  bool get isTransformation => selectedGoal == 'transformation';

  /// `buildPayload()` — exact field-for-field port, including the same
  /// defaults for every unanswered field (unreachable in practice since
  /// every question is required to advance, but kept for parity/safety).
  Map<String, dynamic> _buildPayload() {
    final a = answers;
    final fitnessGoal = isMuscleGain
        ? 'muscle_gain'
        : isGeneralFitness
            ? 'general_fitness'
            : isTransformation
                ? 'transformation'
                : 'weight_loss';

    // General fitness has no target-weight question (maintenance). TRANSFORMATION
    // now asks for one and must forward it — it previously overwrote the answer
    // with the current weight, leaving the transformation plan with no
    // current -> target trajectory. Falls back to current weight so an older
    // payload without the answer behaves exactly as before.
    final goalWeight = isGeneralFitness
        ? (a['weight_kg'] as num? ?? 70)
        : isTransformation
            ? (a['goal_weight_kg'] as num? ?? a['weight_kg'] as num? ?? 70)
            : (a['goal_weight_kg'] as num? ?? 65);

    final supplements = _supplementsUsed(a);

    return {
      'age': a['age'] ?? 22,
      'gender': a['gender'] ?? 'other',
      'height_cm': a['height_cm'] ?? 170,
      'weight_kg': a['weight_kg'] ?? 75,
      'goal_weight_kg': goalWeight,
      'activity_level': a['activity_level'] ?? 'sedentary',
      'occupation': a['occupation'] ?? 'other',
      'living_situation': a['living_situation'] ?? 'home',
      'diet_preference': a['diet_preference'] ?? 'mixed',
      'workout_preference': a['workout_preference'] ?? 'home',
      'sleep_hours': a['sleep_hours'] ?? 7,
      'stress_level': a['stress_level'] ?? 5,
      'available_time': int.tryParse('${a['available_time'] ?? 30}') ?? 30,
      'budget': a['budget'] ?? '',
      'medical_conditions': a['medical_conditions'] ?? 'none',
      'fitness_goal': fitnessGoal,
      'health_goals': a['health_goals'] is List ? a['health_goals'] : <String>[],
      'fitness_level': a['fitness_level'] ?? 'beginner',
      'goal_duration_months': a['goal_duration_months'] != null
          ? int.tryParse('${a['goal_duration_months']}')
          : null,
      'transformation_goal': a['transformation_goal'],
      'uses_supplements': supplements.$1,
      'supplement_types': supplements.$2,
      // Preference memory isn't built yet on the mobile app (matches the
      // website's own "nothing writes these keys yet" -> backend behaves as
      // before). Location IS real — resolved by `_resolveLocation()` right
      // before this payload is built.
      'disliked_exercises': const <String>[],
      'disliked_foods': const <String>[],
      // Stable food ids from `foodPreferencesQuestion` (never the emoji
      // labels). A PREFERENCE: the backend feeds these to the food engine's
      // existing `favorite_foods` ranking bonus and to Creator Recipe
      // search — neither of which filters the plan down to only these foods.
      // An empty list is a valid answer and behaves exactly as before.
      'favorite_foods': a['favorite_foods'] is List
          ? (a['favorite_foods'] as List).map((e) => '$e').toList()
          : <String>[],
      'location': _locationPayload,
    };
  }

  (String, List<String>) _supplementsUsed(Map<String, dynamic> a) {
    final sel = (a['supplements_used'] as List?)?.cast<String>() ?? const [];
    if (sel.isEmpty) return ('', const <String>[]);
    if (sel.contains('none')) return ('no', const <String>[]);
    return ('yes', sel);
  }

  /// `saveToLocalStorage()`'s goal-object construction — same field shape
  /// `GoalModel` already reads (`type, currentVal, targetVal, unit,
  /// startDate, endDate`). `type` is intentionally one of the 4 raw strings
  /// the website itself writes ('Weight Loss'/'Muscle Gain'/'Transformation'/
  /// 'General Fitness') — `GoalModel`'s `goalNames`/`goalUnits` maps don't
  /// have entries for the latter 3 (neither does the website's own
  /// `dashboard.js`), so the Dashboard Goal card falls back to the raw type
  /// string and a generic 'Value' unit for those 3 goals. This is a
  /// pre-existing website quirk, reproduced exactly, not fixed here.
  Map<String, dynamic> _buildGoalMap() {
    final a = answers;
    final goalType = isGeneralFitness
        ? 'General Fitness'
        : isMuscleGain
            ? 'Muscle Gain'
            : isTransformation
                ? 'Transformation'
                : 'Weight Loss';
    final goalTarget = (isGeneralFitness || isTransformation)
        ? (a['weight_kg'] as num? ?? 75)
        : (a['goal_weight_kg'] as num? ?? 65);
    final now = DateTime.now();
    final end = now.add(const Duration(days: 90));
    String dateStr(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return {
      'type': goalType,
      'currentVal': a['weight_kg'] as num? ?? 75,
      'targetVal': goalTarget,
      'unit': 'kg',
      'startDate': dateStr(now),
      'endDate': dateStr(end),
    };
  }
}
