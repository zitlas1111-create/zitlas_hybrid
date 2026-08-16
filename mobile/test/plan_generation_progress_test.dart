import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/assessment/models/plan_generation_progress.dart';

/// Progress must never claim a backend operation finished unless it did.
///
/// The screen this replaces ticked eight checkmarks off a fixed 800ms timer:
/// "Generating your diet plan ✓" appeared at 4.8s whether the plan had been
/// generated, had failed, or was still ten seconds away. These tests pin the
/// property that made that possible — a stage advancing without evidence.
void main() {
  group('reassurance copy', () {
    test('there are at least four distinct messages', () {
      expect(kPlanReassurance.length, greaterThanOrEqualTo(4));
      expect(
        kPlanReassurance.map((m) => m.headline).toSet().length,
        kPlanReassurance.length,
        reason: 'a repeated headline reads as a stuck screen',
      );
    });

    test('every message has both a headline and a body', () {
      for (final m in kPlanReassurance) {
        expect(m.headline.trim(), isNotEmpty);
        expect(m.body.trim(), isNotEmpty);
      }
    });

    test('no message leaks provider, model or latency detail', () {
      // The athlete should never read "Groq", "LLM" or "retrying request".
      const banned = [
        'groq', 'gemini', 'openrouter', 'llm', 'gpt', 'qwen', 'model',
        'api', 'token', 'latency', 'endpoint', 'server',
      ];
      for (final m in kPlanReassurance) {
        final text = '${m.headline} ${m.body}'.toLowerCase();
        for (final word in banned) {
          expect(text.contains(word), isFalse, reason: '"$word" leaked in: $text');
        }
      }
    });
  });

  group('stages settle from real data, never from a timer', () {
    test('generation starts with the server stages in progress, saving pending', () {
      const p = PlanGenerationProgress.generating;
      expect(p.statusOf(PlanStage.profile), PlanStageStatus.inProgress);
      expect(p.statusOf(PlanStage.nutrition), PlanStageStatus.inProgress);
      expect(p.statusOf(PlanStage.training), PlanStageStatus.inProgress);
      // Saving cannot have begun — the response hasn't arrived.
      expect(p.statusOf(PlanStage.saving), PlanStageStatus.pending);
    });

    test('a full response completes all three server stages', () {
      final p = PlanGenerationProgress.generating
          .settledFrom(hasProfile: true, hasDiet: true, hasWorkout: true);
      expect(p.statusOf(PlanStage.nutrition), PlanStageStatus.completed);
      expect(p.statusOf(PlanStage.training), PlanStageStatus.completed);
    });

    test('a null diet plan is reported FAILED, not ticked', () {
      // The backend returns diet_plan and workout_plan independently and
      // either can be null; the old screen ticked both regardless.
      final p = PlanGenerationProgress.generating
          .settledFrom(hasProfile: true, hasDiet: false, hasWorkout: true);
      expect(p.statusOf(PlanStage.nutrition), PlanStageStatus.failed);
      expect(p.statusOf(PlanStage.training), PlanStageStatus.completed);
    });

    test('a null workout plan is reported FAILED independently', () {
      final p = PlanGenerationProgress.generating
          .settledFrom(hasProfile: true, hasDiet: true, hasWorkout: false);
      expect(p.statusOf(PlanStage.training), PlanStageStatus.failed);
      expect(p.statusOf(PlanStage.nutrition), PlanStageStatus.completed);
    });

    test('a total failure claims nothing at all', () {
      final p = PlanGenerationProgress.generating.allFailed;
      for (final stage in [PlanStage.profile, PlanStage.nutrition, PlanStage.training]) {
        expect(p.statusOf(stage), PlanStageStatus.failed);
      }
      // Saving never started, so it is pending — not failed.
      expect(p.statusOf(PlanStage.saving), PlanStageStatus.pending);
    });

    test('settling clears the slow flag', () {
      final slow = PlanGenerationProgress.generating.copyWith(isSlow: true);
      expect(slow.isSlow, isTrue);
      final settled = slow.settledFrom(hasProfile: true, hasDiet: true, hasWorkout: true);
      expect(settled.isSlow, isFalse);
    });

    test('a save failure does not retract the generated plans', () {
      // Generation and persistence settle separately on purpose: a Firestore
      // write failure must not discard a plan the backend already produced.
      final p = PlanGenerationProgress.generating
          .settledFrom(hasProfile: true, hasDiet: true, hasWorkout: true)
          .copyWith(saving: PlanStageStatus.failed);
      expect(p.statusOf(PlanStage.nutrition), PlanStageStatus.completed);
      expect(p.statusOf(PlanStage.training), PlanStageStatus.completed);
      expect(p.statusOf(PlanStage.saving), PlanStageStatus.failed);
    });
  });

  group('running state', () {
    test('idle is not running', () {
      expect(PlanGenerationProgress.idle.isRunning, isFalse);
    });

    test('generating is running', () {
      expect(PlanGenerationProgress.generating.isRunning, isTrue);
    });

    test('a settled-and-saved plan is not running', () {
      final p = PlanGenerationProgress.generating
          .settledFrom(hasProfile: true, hasDiet: true, hasWorkout: true)
          .copyWith(saving: PlanStageStatus.completed);
      expect(p.isRunning, isFalse);
    });
  });

  group('timing constants', () {
    test('the slow notice waits long enough for two real LLM round trips', () {
      // Firing early would strand a plan that was nearly ready.
      expect(kPlanGenerationSlowAfter, greaterThanOrEqualTo(const Duration(seconds: 30)));
    });

    test('messages rotate often enough to read as alive, slowly enough to read', () {
      expect(kReassuranceInterval, greaterThanOrEqualTo(const Duration(seconds: 3)));
      expect(kReassuranceInterval, lessThanOrEqualTo(const Duration(seconds: 8)));
    });

    test('all messages are seen before the slow notice appears', () {
      // Otherwise the athlete watches the same line repeat while waiting.
      final cycle = kReassuranceInterval * kPlanReassurance.length;
      expect(cycle, lessThanOrEqualTo(kPlanGenerationSlowAfter));
    });
  });
}
