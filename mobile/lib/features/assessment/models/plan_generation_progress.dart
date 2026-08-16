/// Honest progress for the "Building Your Personalised Plan" screen.
///
/// The screen this replaces ticked eight checkmarks off a fixed 800ms timer
/// while a single backend call ran in the background. Every tick was a
/// fabrication: "Generating your diet plan ✓" appeared at 4.8s whether the
/// diet plan had been generated, had failed, or was still ten seconds away.
///
/// Nothing here advances on a timer. A stage becomes [PlanStageStatus.completed]
/// only when the corresponding data has actually arrived, and
/// [PlanStageStatus.failed] when it demonstrably did not — the backend returns
/// `diet_plan` and `workout_plan` independently and either can be null, so the
/// two are reported separately rather than as one lie.
library;

enum PlanStageStatus { pending, inProgress, completed, failed }

/// What the client can HONESTLY distinguish.
///
/// Deliberately not the old eight steps: BMI, BMR, calorie targets and SWOT
/// all arrive in the same `calculations`/`swot` payload, so presenting them
/// as four independently-completing operations would be theatre with extra
/// steps. They are one stage because they resolve as one.
enum PlanStage {
  /// `run_assessment()` — calculations + SWOT. Always present in a 200.
  profile,

  /// `diet_plan`, which the backend may legitimately return as null.
  nutrition,

  /// `workout_plan`, likewise independently nullable.
  training,

  /// The Firestore write. Settled separately from generation on purpose: a
  /// save failure must not discard a plan that was successfully generated.
  saving,
}

extension PlanStageDisplay on PlanStage {
  String get icon => switch (this) {
        PlanStage.profile => '📋',
        PlanStage.nutrition => '🥗',
        PlanStage.training => '💪',
        PlanStage.saving => '✨',
      };

  String get label => switch (this) {
        PlanStage.profile => 'Understanding your profile',
        PlanStage.nutrition => 'Building your nutrition plan',
        PlanStage.training => 'Designing your training plan',
        PlanStage.saving => 'Saving your plan',
      };

  /// Shown when the stage genuinely could not be produced. Never alarming —
  /// the athlete still gets everything that DID succeed.
  String get failureLabel => switch (this) {
        PlanStage.profile => "We couldn't finish your profile",
        PlanStage.nutrition => "We couldn't build your nutrition plan",
        PlanStage.training => "We couldn't build your training plan",
        PlanStage.saving => "We couldn't save your plan",
      };
}

/// Reassurance shown while the athlete waits.
///
/// Rotating copy is the ONLY part of this screen that runs on a timer, and
/// that is legitimate: it makes no claim about backend state. The wording
/// explains WHY there is a wait — the plan is being made for this person —
/// without ever naming a model, a provider, or "AI thinking".
const List<({String headline, String body})> kPlanReassurance = [
  (
    headline: 'You deserve a plan made just for you.',
    body: 'Give us a moment to get it right.',
  ),
  (
    headline: "We're studying your goals and lifestyle…",
    body: "We're making sure your plan actually fits YOU.",
  ),
  (
    headline: 'Your nutrition and training are being matched.',
    body: "We're building the pieces together.",
  ),
  (
    headline: 'Every meal is checked against your preferences.',
    body: 'No generic templates — this one is yours.',
  ),
  (
    headline: 'Almost there…',
    body: 'Your personalised ZITLAS plan is coming together.',
  ),
];

/// How long each reassurance message stays up.
const Duration kReassuranceInterval = Duration(seconds: 4);

/// When the wait stops being normal and the athlete deserves an explanation
/// plus a way out. Generous — a cold backend with two LLM round trips can
/// legitimately take a while, and bailing out early would strand a plan that
/// was nearly ready.
const Duration kPlanGenerationSlowAfter = Duration(seconds: 45);

class PlanGenerationProgress {
  const PlanGenerationProgress({
    this.profile = PlanStageStatus.pending,
    this.nutrition = PlanStageStatus.pending,
    this.training = PlanStageStatus.pending,
    this.saving = PlanStageStatus.pending,
    this.isSlow = false,
  });

  final PlanStageStatus profile;
  final PlanStageStatus nutrition;
  final PlanStageStatus training;
  final PlanStageStatus saving;

  /// True once generation has passed [kPlanGenerationSlowAfter] without
  /// settling. Drives the "taking a little longer than usual" message —
  /// never an error, because nothing has actually failed yet.
  final bool isSlow;

  static const idle = PlanGenerationProgress();

  /// Everything the single in-flight request covers is genuinely underway;
  /// the save cannot start until it returns.
  static const generating = PlanGenerationProgress(
    profile: PlanStageStatus.inProgress,
    nutrition: PlanStageStatus.inProgress,
    training: PlanStageStatus.inProgress,
    saving: PlanStageStatus.pending,
  );

  PlanStageStatus statusOf(PlanStage stage) => switch (stage) {
        PlanStage.profile => profile,
        PlanStage.nutrition => nutrition,
        PlanStage.training => training,
        PlanStage.saving => saving,
      };

  PlanGenerationProgress copyWith({
    PlanStageStatus? profile,
    PlanStageStatus? nutrition,
    PlanStageStatus? training,
    PlanStageStatus? saving,
    bool? isSlow,
  }) {
    return PlanGenerationProgress(
      profile: profile ?? this.profile,
      nutrition: nutrition ?? this.nutrition,
      training: training ?? this.training,
      saving: saving ?? this.saving,
      isSlow: isSlow ?? this.isSlow,
    );
  }

  /// Marks the three server-side stages from what the response ACTUALLY
  /// contained. A null plan is reported as failed, not quietly ticked.
  PlanGenerationProgress settledFrom({
    required bool hasProfile,
    required bool hasDiet,
    required bool hasWorkout,
  }) {
    return copyWith(
      profile: hasProfile ? PlanStageStatus.completed : PlanStageStatus.failed,
      nutrition: hasDiet ? PlanStageStatus.completed : PlanStageStatus.failed,
      training: hasWorkout ? PlanStageStatus.completed : PlanStageStatus.failed,
      isSlow: false,
    );
  }

  /// The whole request failed — nothing came back, so nothing is claimed.
  PlanGenerationProgress get allFailed => copyWith(
        profile: PlanStageStatus.failed,
        nutrition: PlanStageStatus.failed,
        training: PlanStageStatus.failed,
        saving: PlanStageStatus.pending,
        isSlow: false,
      );

  bool get isRunning =>
      profile == PlanStageStatus.inProgress ||
      nutrition == PlanStageStatus.inProgress ||
      training == PlanStageStatus.inProgress ||
      saving == PlanStageStatus.inProgress;
}
