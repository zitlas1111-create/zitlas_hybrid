import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../assessment/presentation/widgets/wheel_picker_field.dart';
import '../../models/rest_timer_state.dart';
import '../../rest_timer_controller.dart';
import '../rest_timer_colors.dart';
import '../widgets/rest_timer_watch_face.dart';

/// The dedicated Rest Timer screen (spec §4–§21) — pushed from
/// [RestTimerCard] on the Training Day screen via a plain
/// `Navigator.push(MaterialPageRoute(...))`, the SAME pattern
/// `WorkoutDayScreen` itself is pushed with (see `workout_screen.dart`).
/// Deliberately NOT a `go_router` route: this is a nested push off a screen
/// that is itself a nested push, not a new top-level destination, so
/// introducing a second navigation system for it would be the opposite of
/// "use the existing architecture".
///
/// Reads [RestTimerController.instance] directly — the SAME singleton the
/// Training card observes — via `ChangeNotifierProvider.value`, so nothing
/// here owns or disposes the timer; leaving this screen (back button, or
/// backgrounding the app) never stops the countdown.
class RestTimerScreen extends StatelessWidget {
  const RestTimerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<RestTimerController>.value(
      value: RestTimerController.instance,
      child: const _RestTimerBody(),
    );
  }
}

const _quickPresetsSeconds = [60, 120, 180, 300, 600, 900, 1200]; // 1,2,3,5,10,15,20 min

class _RestTimerBody extends StatelessWidget {
  const _RestTimerBody();

  String _fmt(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _statusLabel(RestTimerController c) {
    switch (c.status) {
      case RestTimerStatus.idle:
        return 'READY';
      case RestTimerStatus.running:
        return 'RUNNING';
      case RestTimerStatus.paused:
        return 'PAUSED';
      // Same label as completed, matching the spec's own mockup — the two
      // states are distinguished by the "Your rest period is over." line +
      // Stop Alarm button shown below the watch (see `_AlarmMessage`) and
      // by which control (Stop Alarm vs Start Again) is offered, not by
      // different big text.
      case RestTimerStatus.alarming:
      case RestTimerStatus.completed:
        return 'REST COMPLETE';
    }
  }

  Color _colorFor(RestTimerController c) {
    // Deep Green identity for both — alarming IS the completion moment,
    // just not yet acknowledged (spec §6: "Deep Green + Warm Yellow as the
    // completed identity" applies to alarming too).
    if (c.status == RestTimerStatus.completed || c.status == RestTimerStatus.alarming) {
      return RestTimerColors.completedPrimary;
    }
    if (c.status == RestTimerStatus.paused) return RestTimerColors.paused;
    return RestTimerColors.activeColor(c.progress);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<RestTimerController>();
    final canPickDuration =
        controller.status == RestTimerStatus.idle || controller.status == RestTimerStatus.completed;
    final isUrgent = controller.status == RestTimerStatus.running && controller.remainingSeconds <= 15;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: ZitlasTokens.bgStart,
        body: Stack(
          children: [
            const ZitlasPremiumBackground(),
            SafeArea(
              child: Column(
                children: [
                  _Header(canPickDuration: canPickDuration, controller: controller),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Column(
                        children: [
                          if (canPickDuration) ...[
                            const _DurationLabel(),
                            const SizedBox(height: 12),
                            _DurationSelector(controller: controller),
                            const SizedBox(height: 28),
                          ] else
                            const SizedBox(height: 16),
                          // Smooth ring/color interpolation (§7/§8: "must
                          // animate smoothly, do not jump between values" /
                          // "use animated color interpolation"). The
                          // CONTROLLER ticks once a second (source of truth,
                          // drift-free); this LOCAL tween is purely cosmetic
                          // easing between those once-a-second values.
                          TweenAnimationBuilder<double>(
                            key: ValueKey(controller.status),
                            tween: Tween(begin: controller.progress, end: controller.progress),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeOut,
                            builder: (context, animatedProgress, _) {
                              return _AnimatedColorSwap(
                                controller: controller,
                                animatedProgress: animatedProgress,
                                colorFor: _colorFor,
                                child: (color) => RestTimerWatchFace(
                                  size: MediaQuery.sizeOf(context).width.clamp(260, 340) - 20,
                                  progress: animatedProgress,
                                  remainingLabel: _fmt(controller.remainingSeconds),
                                  statusLabel: _statusLabel(controller),
                                  color: color,
                                  isPaused: controller.status == RestTimerStatus.paused,
                                  isCompleted: controller.status == RestTimerStatus.completed,
                                  isUrgent: isUrgent,
                                  isAlarming: controller.status == RestTimerStatus.alarming,
                                ),
                              );
                            },
                          ),
                          if (controller.status == RestTimerStatus.alarming) ...[
                            const SizedBox(height: 14),
                            const _AlarmMessage(),
                          ],
                          const SizedBox(height: 28),
                          _Controls(controller: controller),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Re-tweens the DISPLAY color to match [RestTimerWatchFace.progress]'s own
/// tween, so the ring's fill color eases at exactly the same pace as its
/// sweep angle rather than snapping — the two must never visibly disagree.
class _AnimatedColorSwap extends StatelessWidget {
  const _AnimatedColorSwap({
    required this.controller,
    required this.animatedProgress,
    required this.colorFor,
    required this.child,
  });

  final RestTimerController controller;
  final double animatedProgress;
  final Color Function(RestTimerController) colorFor;
  final Widget Function(Color color) child;

  @override
  Widget build(BuildContext context) {
    // Paused/completed are fixed colors regardless of progress (per §10/§17),
    // so only the RUNNING percentage-band color needs to be recomputed from
    // the animated (eased) progress rather than the controller's raw value.
    final color = controller.status == RestTimerStatus.running
        ? RestTimerColors.activeColor(animatedProgress)
        : colorFor(controller);
    return child(color);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.canPickDuration, required this.controller});

  final bool canPickDuration;
  final RestTimerController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary),
            tooltip: 'Back',
          ),
          const Expanded(
            child: Text(
              'REST TIMER',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: ZitlasTokens.textPrimary,
              ),
            ),
          ),
          IconButton(
            // Duration is only editable before a countdown exists (or after
            // one has finished) — mid-countdown there is no sensible
            // "resize a running timer" action, so the control is disabled
            // rather than silently doing nothing.
            onPressed: canPickDuration
                ? () => _showDurationSheet(context, controller)
                : null,
            icon: Icon(
              Icons.settings_rounded,
              color: canPickDuration ? ZitlasTokens.textSecondary : ZitlasTokens.textMuted.withValues(alpha: 0.4),
            ),
            tooltip: 'Choose duration',
          ),
        ],
      ),
    );
  }
}

void _showDurationSheet(BuildContext context, RestTimerController controller) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: ZitlasTokens.bgCard,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Custom Duration',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
              ),
              const SizedBox(height: 4),
              const Text(
                '1–20 minutes',
                style: TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary),
              ),
              const SizedBox(height: 14),
              WheelPickerField(
                min: 1,
                max: 20,
                unit: 'min',
                initialValue: controller.durationSeconds ~/ 60,
                onChanged: (v) => controller.setDuration(v.toInt() * 60),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ZitlasTokens.primary,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _DurationLabel extends StatelessWidget {
  const _DurationLabel();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Choose Duration',
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZitlasTokens.textSecondary),
    );
  }
}

class _DurationSelector extends StatelessWidget {
  const _DurationSelector({required this.controller});
  final RestTimerController controller;

  @override
  Widget build(BuildContext context) {
    final selected = controller.durationSeconds;
    final isCustom = !_quickPresetsSeconds.contains(selected);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        for (final secs in _quickPresetsSeconds)
          _DurationChip(
            label: '${secs ~/ 60}',
            selected: selected == secs,
            onTap: () => controller.setDuration(secs),
          ),
        _DurationChip(
          label: isCustom ? '${selected ~/ 60}' : 'More',
          selected: isCustom,
          onTap: () => _showDurationSheet(context, controller),
        ),
      ],
    );
  }
}

class _DurationChip extends StatelessWidget {
  const _DurationChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Set duration to $label minutes',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? ZitlasTokens.primary : ZitlasTokens.bgCardLight,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? ZitlasTokens.primary : ZitlasTokens.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : ZitlasTokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller});
  final RestTimerController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case RestTimerStatus.idle:
        return _PrimaryButton(
          label: 'START',
          icon: Icons.play_arrow_rounded,
          color: ZitlasTokens.primary,
          onTap: controller.start,
          semanticLabel: 'Start rest timer',
        );

      case RestTimerStatus.running:
        return Column(
          children: [
            _PrimaryButton(
              label: 'PAUSE',
              icon: Icons.pause_rounded,
              color: RestTimerColors.paused,
              onTap: controller.pause,
              semanticLabel: 'Pause rest timer',
            ),
            const SizedBox(height: 10),
            _SecondaryButton(
              label: 'Reset',
              onTap: controller.reset,
              semanticLabel: 'Reset rest timer',
            ),
          ],
        );

      case RestTimerStatus.paused:
        return Column(
          children: [
            _PrimaryButton(
              label: 'RESUME',
              icon: Icons.play_arrow_rounded,
              color: ZitlasTokens.primary,
              onTap: controller.resume,
              semanticLabel: 'Resume rest timer',
            ),
            const SizedBox(height: 10),
            _SecondaryButton(
              label: 'Reset',
              onTap: controller.reset,
              semanticLabel: 'Reset rest timer',
            ),
          ],
        );

      case RestTimerStatus.completed:
        return _PrimaryButton(
          label: 'START AGAIN',
          icon: Icons.replay_rounded,
          color: ZitlasTokens.primary,
          onTap: controller.start,
          semanticLabel: 'Start rest timer again',
        );

      // The ONLY control offered while ringing (spec §3: "the STOP ALARM
      // button must be extremely obvious") — no Reset, no Pause alongside
      // it, nothing else competing for the tap. Coral, not Deep Green: this
      // is the one moment on the whole screen where a louder, attention
      // color is appropriate, and Coral is already the locked palette's
      // "mood/attention" accent (spec §6 explicitly allows it here) rather
      // than a color invented for this button.
      case RestTimerStatus.alarming:
        return _PrimaryButton(
          label: 'STOP ALARM',
          icon: Icons.notifications_off_rounded,
          color: ZitlasTokens.wellnessCoral,
          onTap: controller.stopAlarm,
          semanticLabel: 'Stop alarm',
        );
    }
  }
}

/// "Your rest period is over." — the explanatory line from the spec's own
/// mockup, shown ONLY while [RestTimerStatus.alarming], between the watch
/// (which already carries the bell + "REST COMPLETE") and the Stop Alarm
/// button. This is the accessible, textual distinction between "ringing"
/// and "acknowledged" that accessibility (§34) asks for — a status this
/// consequential is never communicated by color/animation alone.
class _AlarmMessage extends StatelessWidget {
  const _AlarmMessage();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Your rest period is over.',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZitlasTokens.textSecondary),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    required this.semanticLabel,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Future<void> Function() onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 22),
          label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onTap, required this.semanticLabel});

  final String label;
  final Future<void> Function() onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: ZitlasTokens.textSecondary,
            side: const BorderSide(color: ZitlasTokens.border),
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
