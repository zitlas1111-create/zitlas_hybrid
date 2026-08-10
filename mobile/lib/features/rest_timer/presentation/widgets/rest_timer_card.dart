import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../models/rest_timer_state.dart';
import '../../rest_timer_controller.dart';
import '../rest_timer_colors.dart';
import '../screens/rest_timer_screen.dart';

/// The Training Day screen's Rest Timer entry point (spec §3/§22) — placed
/// directly below the existing Duration/Est. Calories/Exercises stats row in
/// `workout_day_screen.dart`, using the SAME `ZitlasCard`/spacing/typography
/// every other card on that screen already uses, not a bespoke look.
///
/// Self-contained on purpose: wraps its own body in
/// `ChangeNotifierProvider.value(value: RestTimerController.instance, ...)`
/// so `WorkoutDayScreen` needs only ONE extra line to integrate this
/// (inserting the widget itself) rather than restructuring its own provider
/// tree for an unrelated feature.
class RestTimerCard extends StatelessWidget {
  const RestTimerCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<RestTimerController>.value(
      value: RestTimerController.instance,
      child: const _RestTimerCardBody(),
    );
  }
}

class _RestTimerCardBody extends StatelessWidget {
  const _RestTimerCardBody();

  String _fmt(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RestTimerController>();
    final status = controller.status;
    final completed = status == RestTimerStatus.completed;
    final alarming = status == RestTimerStatus.alarming;

    final (String subtitle, Color accent) = switch (status) {
      RestTimerStatus.idle => ('Tap to set', ZitlasTokens.textMuted),
      RestTimerStatus.running => ('Running', RestTimerColors.activeColor(controller.progress)),
      RestTimerStatus.paused => ('Paused', RestTimerColors.paused),
      // "REST COMPLETE" here, with "ALARM RINGING" rendered as its own line
      // below (see the `alarming` branch in the layout) — spec §14's mockup
      // shows both as separate lines, not one combined subtitle.
      RestTimerStatus.alarming => ('REST COMPLETE', RestTimerColors.completedPrimary),
      RestTimerStatus.completed => ('Start again', RestTimerColors.completedPrimary),
    };

    return Semantics(
      button: true,
      label: completed
          ? 'Rest complete. Tap to start again.'
          : alarming
              ? 'Rest timer alarm ringing. Tap to open and stop it.'
              : 'Rest timer, ${_fmt(controller.remainingSeconds)} remaining, $subtitle. Tap to open.',
      child: Material(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(kZitlasRadiusMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(kZitlasRadiusMd),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const RestTimerScreen()),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kZitlasRadiusMd),
              border: Border.all(color: ZitlasTokens.borderSub),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    completed
                        ? Icons.check_circle_rounded
                        : alarming
                            ? Icons.notifications_active_rounded
                            : Icons.watch_rounded,
                    size: 19,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // "Rest Timer" while alarming (not "Rest Complete") —
                      // matches spec §14's mockup, and keeps the bell icon
                      // as the visual cue rather than pre-empting the
                      // checkmark that only appears once actually stopped.
                      Text(
                        completed ? 'Rest Complete' : 'Rest Timer',
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 11.5, color: accent, fontWeight: FontWeight.w600),
                      ),
                      if (alarming) ...[
                        const SizedBox(height: 1),
                        // The urgency line — Coral, the locked palette's
                        // "attention" accent, distinct from the Deep Green
                        // "REST COMPLETE" line above it (spec §14's mockup
                        // shows these as two separate lines).
                        const Text(
                          'ALARM RINGING',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: ZitlasTokens.wellnessCoral,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Nothing to count down while completed OR alarming — both
                // sit at 0 seconds; showing a static "00:00" next to the
                // chevron would read as broken, not as "finished".
                if (!completed && !alarming) ...[
                  Text(
                    _fmt(controller.remainingSeconds),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: ZitlasTokens.textPrimary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Icon(Icons.chevron_right_rounded, size: 20, color: ZitlasTokens.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
