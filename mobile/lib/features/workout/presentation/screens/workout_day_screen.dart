import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../../auth/auth_state.dart';
import '../../../rest_timer/presentation/widgets/rest_timer_card.dart';
import '../../models/workout_day.dart';
import '../../workout_controller.dart';

/// Native rebuild of `frontend/pages/dashboard/training/day.html` +
/// `day.js`'s `renderFitnessDay()` — the single-day detail screen, pushed
/// from a day card on the Weekly Plan screen. Renders the SAME
/// `WorkoutController` instance (no re-subscription), so live updates
/// (a coach editing the plan, a check-in being reviewed) reflect
/// immediately without navigating back.
///
/// The website's 10-section sport-specific template (`renderDay()` —
/// Warmup/Activation/Primary-Secondary Skill/Match Simulation/Mental
/// Conditioning/Stretching/Hydration/Weekly Review) is NOT reproduced here:
/// it only renders for the `zitlas_roadmap` sport schema, which is
/// confirmed dead code — nothing in the current frontend or backend ever
/// writes `zitlas_roadmap` (verified by grepping every `.js` file and
/// `backend/routes/*.py`). Every athlete's real plan takes the
/// `renderFitnessDay()` path reproduced here.
class WorkoutDayScreen extends StatelessWidget {
  const WorkoutDayScreen({super.key, required this.controller, required this.dayIndex});

  final WorkoutController controller;
  final int dayIndex;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<WorkoutController>.value(
      value: controller,
      child: _WorkoutDayBody(dayIndex: dayIndex),
    );
  }
}

class _WorkoutDayBody extends StatelessWidget {
  const _WorkoutDayBody({required this.dayIndex});

  final int dayIndex;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<WorkoutController>();
    final plan = controller.effectivePlan;
    final day = (plan != null && dayIndex < plan.days.length) ? plan.days[dayIndex] : null;

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
                  _Header(day: day, dayIndex: dayIndex),
                  Expanded(
                    child: day == null
                        ? const _DayNotFound()
                        : _DayContent(controller: controller, day: day),
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

class _Header extends StatelessWidget {
  const _Header({required this.day, required this.dayIndex});
  final WorkoutDay? day;
  final int dayIndex;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back, color: ZitlasTokens.textPrimary),
          ),
          Expanded(
            child: Text(
              day?.day ?? 'Day ${dayIndex + 1}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _DayNotFound extends StatelessWidget {
  const _DayNotFound();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No training plan found.\nComplete the assessment to generate your plan.',
        textAlign: TextAlign.center,
        style: TextStyle(color: ZitlasTokens.textSecondary, fontSize: 14),
      ),
    );
  }
}

class _DayContent extends StatelessWidget {
  const _DayContent({required this.controller, required this.day});

  final WorkoutController controller;
  final WorkoutDay day;

  @override
  Widget build(BuildContext context) {
    // Health Status recovery override (`controller.healthOverrideAppliesTo`)
    // — swaps ONLY today's exercises for the deterministic recovery
    // template chosen on the Dashboard's "How are you feeling today?" card,
    // mirroring DietController's identical mechanism. The underlying stored
    // plan is never modified.
    final overrideApplies = controller.healthOverrideAppliesTo(day);
    final overrideWorkout = overrideApplies ? controller.healthToday!.workout : null;
    final exercises = controller.effectiveExercisesFor(day);
    final isRest = overrideWorkout != null
        ? (overrideWorkout.mode == 'rest' || overrideWorkout.mode == 'none')
        : day.isRest;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        // ── Hero ──
        ZitlasCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isRest ? '😴' : '💪', style: const TextStyle(fontSize: 28)),
              const SizedBox(height: 8),
              Text(
                day.theme,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: ZitlasTokens.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                day.dailyTip ??
                    (isRest ? 'Rest and recover today.' : 'Complete all exercises with proper form.'),
                style: const TextStyle(fontSize: 13, color: ZitlasTokens.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  _Chip('⏱ ${day.durationMinutes != null ? '${day.durationMinutes} min' : '—'}'),
                  _Chip(day.day),
                ],
              ),
            ],
          ),
        ),

        // ── Expert banner ──
        if (day.modified) ...[
          const SizedBox(height: 14),
          ZitlasCard(
            color: const Color(0x1F3A8F8B),
            child: Text(
              '✏️ Modified by ${day.modifiedBy ?? 'Expert'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: ZitlasTokens.hydrationTeal),
            ),
          ),
        ],

        // ── Health Status recovery banner — `#hsDietBanner`'s Training
        // equivalent. Tells the athlete why today's session looks different
        // and that it's temporary.
        if (overrideWorkout != null) ...[
          const SizedBox(height: 14),
          ZitlasCard(
            color: ZitlasTokens.primary.withValues(alpha: 0.08),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '🛟 ', style: TextStyle(fontSize: 13)),
                  TextSpan(text: overrideWorkout.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const TextSpan(text: ' — adjusted for how you\'re feeling. Your normal plan resumes tomorrow.'),
                ],
                style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textPrimary, height: 1.4),
              ),
            ),
          ),
        ],

        const SizedBox(height: 14),

        // ── Time breakdown chips ──
        Row(
          children: [
            if (day.durationMinutes != null)
              Expanded(child: _TimeStat(value: '${day.durationMinutes} min', label: 'Duration')),
            if (day.caloriesBurnedEst != null)
              Expanded(child: _TimeStat(value: '${day.caloriesBurnedEst} kcal', label: 'Est. Calories')),
            if (!isRest && exercises.isNotEmpty)
              Expanded(child: _TimeStat(value: '${exercises.length}', label: 'Exercises')),
          ],
        ),

        // Rest Timer — directly below the stats row per spec. Available on
        // every day (including rest days: an athlete stretching/mobility-
        // working on a rest day can still want a rest-between-sets timer),
        // not gated on `isRest`/`exercises.isNotEmpty` like the chips above.
        const SizedBox(height: 14),
        const RestTimerCard(),

        const SizedBox(height: 14),

        if (isRest) ...[
          ZitlasCard(
            child: Column(
              children: const [
                Text('😴', style: TextStyle(fontSize: 32)),
                SizedBox(height: 8),
                Text(
                  'Rest Day — recover well, stay hydrated, and sleep early.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: ZitlasTokens.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ] else ...[
          // ── Fitness Session ──
          ZitlasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  day.theme,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary),
                ),
                const SizedBox(height: 10),
                if (exercises.isEmpty)
                  const Text(
                    'No exercises listed for this session.',
                    style: TextStyle(fontSize: 13, color: ZitlasTokens.textMuted),
                  )
                else
                  ...List.generate(exercises.length, (i) {
                    final ex = exercises[i];
                    return Padding(
                      padding: EdgeInsets.only(top: i > 0 ? 14 : 0, bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (i > 0) const Divider(height: 1, color: ZitlasTokens.borderSub),
                          if (i > 0) const SizedBox(height: 14),
                          Text(
                            ex.name,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (ex.sets != null) _Chip('${ex.sets} sets'),
                              if (ex.repsOrDuration != null) _Chip(ex.repsOrDuration!),
                              if (ex.restSeconds != null) _Chip('Rest ${ex.restSeconds}s'),
                            ],
                          ),
                          if ((ex.tip ?? '').isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0x140E9BB5),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                ex.tip!,
                                style: const TextStyle(fontSize: 12, color: ZitlasTokens.aiAccent, height: 1.35),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ],

        // ── Coach's Tip ──
        if (day.dailyTip != null) ...[
          const SizedBox(height: 14),
          ZitlasCard(
            color: ZitlasTokens.bgCardLight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('🧢 ', style: TextStyle(fontSize: 14)),
                Expanded(
                  child: Text(
                    day.dailyTip!,
                    style: const TextStyle(fontSize: 12.5, color: ZitlasTokens.textSecondary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 14),
        _WorkoutActions(controller: controller, day: day),
      ],
    );
  }
}

class _TimeStat extends StatelessWidget {
  const _TimeStat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ZitlasTokens.textPrimary)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 10.5, color: ZitlasTokens.textMuted, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: ZitlasTokens.bgCardLight, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: const TextStyle(fontSize: 11, color: ZitlasTokens.textSecondary, fontWeight: FontWeight.w600)),
    );
  }
}

/// `_dtBuildActionsHtml(day)` — Complete Workout / Send to Coach, with the
/// exact status copy for each state.
class _WorkoutActions extends StatefulWidget {
  const _WorkoutActions({required this.controller, required this.day});

  final WorkoutController controller;
  final WorkoutDay day;

  @override
  State<_WorkoutActions> createState() => _WorkoutActionsState();
}

class _WorkoutActionsState extends State<_WorkoutActions> {
  bool _completing = false;
  bool _sending = false;

  Future<void> _complete() async {
    setState(() => _completing = true);
    try {
      await widget.controller.completeWorkout();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Workout marked complete!')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save — try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final athleteName = context.read<AuthState>().profile?.name ?? 'Athlete';
    await widget.controller.sendWorkoutToCoach(day: widget.day, athleteName: athleteName);
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.controller.sendError == null
              ? '✅ Sent to your coach for review.'
              : 'Could not send — try again.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final completed = controller.todayWorkoutCompleted;
    final checkin = controller.workoutCheckins[widget.day.day];

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: completed
              ? Container(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0x1F3A8F8B),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    '✅ Workout Complete',
                    style: TextStyle(fontWeight: FontWeight.w700, color: ZitlasTokens.hydrationTeal),
                  ),
                )
              : ElevatedButton(
                  onPressed: _completing ? null : _complete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ZitlasTokens.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _completing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('✅ Complete Workout', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
        ),
        if (controller.canSendToCoach) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: checkin != null
                ? Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ZitlasTokens.bgCardLight,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          checkin['status'] == 'reviewed'
                              ? '✓ Reviewed by coach${checkin['score'] != null ? ' · ${checkin['score']}/10' : ''}'
                              : '🔒 Sent — awaiting coach review',
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZitlasTokens.textPrimary),
                        ),
                        if ((checkin['comment'] as String?)?.isNotEmpty == true) ...[
                          const SizedBox(height: 6),
                          Text(
                            checkin['comment'] as String,
                            style: const TextStyle(fontSize: 12, color: ZitlasTokens.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  )
                : OutlinedButton(
                    onPressed: _sending ? null : _send,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ZitlasTokens.primaryDark,
                      side: const BorderSide(color: ZitlasTokens.primary),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('📤 Send Workout to Coach', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
          ),
        ],
      ],
    );
  }
}
