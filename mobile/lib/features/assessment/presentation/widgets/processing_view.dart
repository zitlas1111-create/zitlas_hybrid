import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../assessment_controller.dart';
import '../../models/plan_generation_progress.dart';

/// "Building Your Personalised Plan".
///
/// The version this replaces ticked eight checkmarks off a fixed 800ms
/// timer and then held the athlete for a further 7s even when the backend
/// had already answered. Nothing it showed was connected to anything.
///
/// Now: the checkmarks come from [AssessmentController.progress], which only
/// ever settles from real response data, and the screen leaves the moment
/// there is something to show. The one timer left drives the rotating
/// reassurance copy, which makes no claim about backend state.
class ProcessingView extends StatefulWidget {
  const ProcessingView({super.key});

  @override
  State<ProcessingView> createState() => _ProcessingViewState();
}

class _ProcessingViewState extends State<ProcessingView>
    with SingleTickerProviderStateMixin {
  int _message = 0;
  Timer? _rotation;
  late final AnimationController _breath;

  @override
  void initState() {
    super.initState();
    // A slow breath on Zino rather than a spinning ring — motion that reads
    // as "working", not as "stuck in a loop".
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);

    _rotation = Timer.periodic(kReassuranceInterval, (_) {
      if (!mounted) return;
      setState(() => _message = (_message + 1) % kPlanReassurance.length);
    });
  }

  @override
  void dispose() {
    _rotation?.cancel();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AssessmentController>();
    final progress = controller.progress;
    final copy = kPlanReassurance[_message];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ZinoBreath(animation: _breath),
            const SizedBox(height: 20),
            Text.rich(
              const TextSpan(
                children: [
                  TextSpan(text: 'Building Your\n'),
                  TextSpan(
                    text: 'Personalised Plan',
                    style: TextStyle(color: ZitlasTokens.primary),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: ZitlasTokens.textPrimary,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 14),

            // Rotating reassurance. Cross-faded and given a fixed height so
            // the stage list below never jumps as the copy changes length.
            SizedBox(
              height: 58,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                child: Column(
                  key: ValueKey(_message),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      copy.headline,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: ZitlasTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      copy.body,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: ZitlasTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),

            ...PlanStage.values.map(
              (stage) => _StageRow(stage: stage, status: progress.statusOf(stage)),
            ),

            if (progress.isSlow) ...[
              const SizedBox(height: 20),
              const _TakingLongerNotice(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Zino with a soft breathing halo. Replaces the bare
/// `CircularProgressIndicator` ring, which spun at a constant rate and so
/// carried no information at all.
class _ZinoBreath extends StatelessWidget {
  const _ZinoBreath({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 108,
      height: 108,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(animation.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 84 + 20 * t,
                height: 84 + 20 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ZitlasTokens.primary.withValues(alpha: 0.10 * (1 - t) + 0.04),
                ),
              ),
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ZitlasTokens.primary.withValues(alpha: 0.35 + 0.35 * t),
                    width: 2,
                  ),
                ),
              ),
              child!,
            ],
          );
        },
        child: ClipOval(
          child: Image.asset(
            'assets/images/zino.png',
            width: 64,
            height: 64,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}

/// One honest stage. The trailing widget is driven entirely by [status] —
/// there is no path that renders a checkmark without real data behind it.
class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage, required this.status});

  final PlanStage stage;
  final PlanStageStatus status;

  @override
  Widget build(BuildContext context) {
    final failed = status == PlanStageStatus.failed;

    return AnimatedOpacity(
      opacity: status == PlanStageStatus.pending ? 0.35 : 1,
      duration: const Duration(milliseconds: 300),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Text(stage.icon, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                failed ? stage.failureLabel : stage.label,
                style: TextStyle(
                  fontSize: 13,
                  color: failed ? ZitlasTokens.textMuted : ZitlasTokens.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: 20,
              height: 20,
              child: switch (status) {
                PlanStageStatus.completed =>
                  const Icon(Icons.check_circle, color: ZitlasTokens.success, size: 18),
                PlanStageStatus.failed =>
                  const Icon(Icons.remove_circle_outline, color: ZitlasTokens.textMuted, size: 18),
                PlanStageStatus.inProgress => const Padding(
                    padding: EdgeInsets.all(2),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ZitlasTokens.primary,
                    ),
                  ),
                PlanStageStatus.pending => const SizedBox.shrink(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown once the wait exceeds [kPlanGenerationSlowAfter].
///
/// Deliberately NOT an error and deliberately offers no "cancel": the
/// request is still in flight and usually still lands. Cancelling would
/// throw away a plan that is nearly ready and cost a second pair of LLM
/// calls to rebuild.
class _TakingLongerNotice extends StatelessWidget {
  const _TakingLongerNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: ZitlasTokens.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasTokens.primary.withValues(alpha: 0.20)),
      ),
      child: const Column(
        children: [
          Text(
            'Your plan is taking a little longer than usual.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: ZitlasTokens.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            "We're still working on it — your answers are safe.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
