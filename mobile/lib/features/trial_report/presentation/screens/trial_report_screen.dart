import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../data/trial_report_repository.dart';
import '../../models/trial_report.dart';

/// "Your ZITLAS Journey" — the Trial Completion Report.
///
/// THIS SCREEN CALCULATES NOTHING. Every figure is read from the immutable
/// snapshot the backend froze when the engagement ended. Recomputing here
/// would give the athlete a number that disagrees with their own report on
/// the web and that drifts as their plan changes afterwards.
///
/// TWO RULES THE LAYOUT ENFORCES:
///
///   1. An unavailable metric is never a zero. `followUp` and `overall` are
///      always unavailable today, and a "0%" beside them would read as the
///      athlete having failed at something that was never measured. They get
///      an explanation instead.
///
///   2. The plan story is AI-first. ZITLAS generates the diet plan and the
///      coach customises it — the coach's editor is literally preloaded with
///      the AI plan. So the wording is driven by
///      `metrics.planEvolution.wording`, and no branch of it says the coach
///      created the plan.
class TrialReportScreen extends StatefulWidget {
  const TrialReportScreen({
    super.key,
    required this.requestId,
    this.repository,
  });

  final String requestId;

  /// Injectable for tests only. Production builds the default, which fetches
  /// the immutable snapshot from the API — the screen has no other source.
  final TrialReportRepository? repository;

  @override
  State<TrialReportScreen> createState() => _TrialReportScreenState();
}

class _TrialReportScreenState extends State<TrialReportScreen> {
  late final TrialReportRepository _repository =
      widget.repository ?? TrialReportRepository();
  late Future<TrialReport?> _future;

  @override
  void initState() {
    super.initState();
    _future = _repository.fetch(widget.requestId);
  }

  void _reload() {
    // Block body, NOT `setState(() => _future = ...)`. An arrow body returns
    // the assigned Future, and setState asserts its callback returned nothing
    // — so the arrow form fired the request but threw before rebuilding,
    // leaving Retry visibly dead in debug builds.
    setState(() {
      _future = _repository.fetch(widget.requestId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZitlasTokens.bgPrimary,
      appBar: AppBar(
        title: const Text('Your ZITLAS Journey'),
        backgroundColor: ZitlasTokens.bgPrimary,
        foregroundColor: ZitlasTokens.textPrimary,
        elevation: 0,
      ),
      body: FutureBuilder<TrialReport?>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Message(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load your report',
              body: 'Check your connection and try again.',
              onRetry: _reload,
            );
          }
          final report = snapshot.data;
          if (report == null) {
            // Not an error: a report may not have been generated for this
            // engagement, and saying "failed" would be wrong.
            return const _Message(
              icon: Icons.hourglass_empty_rounded,
              title: 'Report not ready',
              body: 'Your coaching summary will appear here once it has been '
                  'prepared. This usually happens shortly after a trial ends.',
            );
          }
          return _ReportBody(report: report);
        },
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report});

  final TrialReport report;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        _Header(report: report),
        const SizedBox(height: 20),
        _PlanJourney(evolution: report.planEvolution),
        const SizedBox(height: 20),
        _Nutrition(report: report),
        const SizedBox(height: 20),
        _CoachCustomization(evolution: report.planEvolution),
        const SizedBox(height: 20),
        _Training(metric: report.workoutAdherence),
        const SizedBox(height: 20),
        _Progress(metric: report.progress),
        const SizedBox(height: 20),
        _Unavailable(
          title: 'Follow-up',
          metric: report.followUp,
          explanation: 'We only report what we can measure. ZITLAS does not '
              'yet record whether you acted on each individual coach '
              'recommendation, so there is no follow-up figure to show.',
        ),
        const SizedBox(height: 12),
        _Unavailable(
          title: 'Overall ZITLAS Score',
          metric: report.overall,
          explanation: 'The overall scoring model is still being finalised. '
              'Rather than show you a number that might change meaning later, '
              'we are leaving it out until it is right.',
        ),
        const SizedBox(height: 24),
        _Notes(warnings: report.warnings),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.report});

  final TrialReport report;

  @override
  Widget build(BuildContext context) {
    final days = report.elapsedDays ?? report.durationDays;
    final label = report.isFreeTrial
        ? 'Personal Coaching Trial'
        : 'Personal Coaching';
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .4,
                  color: ZitlasTokens.textSecondary)),
          const SizedBox(height: 6),
          Text(days == null ? 'Your coaching engagement' : '$days Days',
              style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: ZitlasTokens.textPrimary)),
          if (report.coachName != null) ...[
            const SizedBox(height: 8),
            Text('with ${report.coachName}',
                style: const TextStyle(
                    fontSize: 15, color: ZitlasTokens.textSecondary)),
          ],
        ],
      ),
    );
  }
}

/// AI generated → coach customised → athlete followed.
class _PlanJourney extends StatelessWidget {
  const _PlanJourney({required this.evolution});

  final TrialPlanEvolution evolution;

  @override
  Widget build(BuildContext context) {
    // Wording comes from the backend's resolved interpretation. NONE of
    // these branches claims the coach created the plan, because in ZITLAS
    // they never do — they customise the AI-generated one.
    final customized = evolution.wording == 'coach_customized_ai_plan';
    final fromTemplate = evolution.wording == 'coach_authored_from_template';

    final steps = <_JourneyStep>[
      const _JourneyStep(
        icon: Icons.auto_awesome_rounded,
        title: 'AI-generated plan',
        body: 'ZITLAS built your personalised plan from your assessment.',
        active: true,
      ),
      if (customized)
        _JourneyStep(
          icon: Icons.edit_note_rounded,
          title: 'Coach-customized plan',
          body: 'Your coach reviewed that plan and made '
              '${evolution.modifications} '
              '${evolution.modifications == 1 ? "change" : "changes"} to it.',
          active: true,
        )
      else if (fromTemplate)
        const _JourneyStep(
          icon: Icons.edit_note_rounded,
          title: 'Coach-built plan',
          body: 'Your coach built your plan directly, as no AI plan was '
              'available to start from.',
          active: true,
        )
      else
        const _JourneyStep(
          icon: Icons.edit_note_rounded,
          title: 'Coach review',
          body: 'Your coach reviewed your AI-generated plan and did not need '
              'to change it during this period.',
          active: false,
        ),
      const _JourneyStep(
        icon: Icons.restaurant_rounded,
        title: 'Your follow-through',
        body: 'The meals you submitted against the plan that applied each day.',
        active: true,
      ),
    ];

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Plan journey'),
          const SizedBox(height: 4),
          for (var i = 0; i < steps.length; i++) ...[
            steps[i],
            if (i < steps.length - 1)
              const Padding(
                padding: EdgeInsets.only(left: 15, top: 2, bottom: 2),
                child: SizedBox(
                    height: 16,
                    child: VerticalDivider(
                        width: 2, thickness: 2, color: ZitlasTokens.border)),
              ),
          ],
        ],
      ),
    );
  }
}

class _JourneyStep extends StatelessWidget {
  const _JourneyStep({
    required this.icon,
    required this.title,
    required this.body,
    required this.active,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colour = active ? ZitlasTokens.primary : ZitlasTokens.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colour),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: active
                            ? ZitlasTokens.textPrimary
                            : ZitlasTokens.textSecondary)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: ZitlasTokens.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Nutrition extends StatelessWidget {
  const _Nutrition({required this.report});

  final TrialReport report;

  @override
  Widget build(BuildContext context) {
    final follow = report.mealFollowThrough;
    final quality = report.mealQuality;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Nutrition'),
          const SizedBox(height: 12),
          if (follow.isAvailable) ...[
            _Stat(
                label: 'Meals submitted',
                value: '${follow.integer("submitted") ?? 0}'),
            _Stat(
                label: 'Meals expected',
                value: '${follow.integer("expected") ?? 0}'),
            _Stat(
                label: 'Follow-through',
                value: '${follow.percent?.toStringAsFixed(0) ?? "—"}%',
                emphasis: true),
          ] else ...[
            _Stat(
                label: 'Meals submitted',
                value: '${follow.integer("submitted") ?? 0}'),
            const _Explainer(
              'We could not work out how many meals your plan expected during '
              'this period, so there is no follow-through percentage. Your '
              'submitted meals are still shown above.',
            ),
          ],
          const SizedBox(height: 4),
          if (quality.isAvailable) ...[
            _Stat(
                label: 'Meals reviewed by your coach',
                value: '${quality.integer("reviewedMeals") ?? 0}'),
            _Stat(
                label: 'Coach meal rating',
                value:
                    '${quality.number("averageRating")?.toStringAsFixed(1) ?? "—"} / 5',
                emphasis: true),
            // n=1 must never read as a strong result.
            if (quality.field<bool>('lowConfidence') == true)
              _Explainer(
                'Based on ${quality.integer("reviewedMeals")} reviewed '
                '${quality.integer("reviewedMeals") == 1 ? "meal" : "meals"} — '
                'too few to be a firm average.',
              ),
          ] else
            const _Explainer(
              'None of your meals were rated by your coach during this period, '
              'so there is no meal-quality average to show.',
            ),
        ],
      ),
    );
  }
}

class _CoachCustomization extends StatelessWidget {
  const _CoachCustomization({required this.evolution});

  final TrialPlanEvolution evolution;

  @override
  Widget build(BuildContext context) {
    if (!evolution.coachCustomizedPlanApplied &&
        evolution.modifications == 0) {
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _SectionTitle('Coach customization'),
            SizedBox(height: 8),
            _Explainer(
              'Your coach did not change your AI-generated plan during this '
              'period.',
            ),
          ],
        ),
      );
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Coach customization'),
          const SizedBox(height: 12),
          _Stat(
              label: 'Coach modifications',
              value: '${evolution.modifications}',
              emphasis: true),
          _Stat(label: 'Plan versions saved', value: '${evolution.planSaves}'),
          if (evolution.firstModifiedAt != null)
            _Stat(
                label: 'First modification',
                value: _shortDate(evolution.firstModifiedAt!)),
          if (evolution.lastModifiedAt != null)
            _Stat(
                label: 'Latest modification',
                value: _shortDate(evolution.lastModifiedAt!)),
        ],
      ),
    );
  }
}

class _Training extends StatelessWidget {
  const _Training({required this.metric});

  final TrialMetric metric;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Training'),
          const SizedBox(height: 12),
          _Stat(
              label: 'Days you marked a workout complete',
              value: '${metric.integer("completedWorkoutDays") ?? 0}'),
          _Stat(
              label: 'Workouts sent to your coach',
              value: '${metric.integer("workoutCheckins") ?? 0}'),
          _Stat(
              label: 'Workouts reviewed',
              value: '${metric.integer("reviewedWorkoutCheckins") ?? 0}'),
          // The honest caveat: this is activity, not prescribed-vs-completed.
          const _Explainer(
            'These are the workouts you logged. ZITLAS does not schedule '
            'workouts to specific dates, so this is not a prescribed-versus-'
            'completed adherence figure.',
          ),
        ],
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.metric});

  final TrialMetric metric;

  @override
  Widget build(BuildContext context) {
    final change = metric.number('weightChangeKg');
    final steps = metric.raw['steps'];
    final sleep = metric.raw['sleep'];
    final water = metric.raw['water'];
    final streak = metric.raw['streak'];

    num? nested(Object? block, String key) =>
        block is Map ? (block[key] as num?) : null;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Progress'),
          const SizedBox(height: 12),
          if (change != null)
            // Signed and unjudged: whether -2kg is good depends on the
            // athlete's goal, which this report does not read.
            _Stat(
                label: 'Weight change',
                value: '${change > 0 ? "+" : ""}'
                    '${change.toStringAsFixed(1)} kg',
                emphasis: true)
          else
            const _Explainer(
              'You logged fewer than two weights during this period, so there '
              'is no change to report.',
            ),
          if (nested(steps, 'dailyAverage') != null)
            _Stat(
                label: 'Average daily steps',
                value: '${nested(steps, "dailyAverage")!.round()}'),
          if (nested(sleep, 'dailyAverageHours') != null)
            _Stat(
                label: 'Average sleep',
                value:
                    '${nested(sleep, "dailyAverageHours")!.toStringAsFixed(1)} h'),
          if (nested(water, 'dailyAverageMl') != null)
            _Stat(
                label: 'Average hydration',
                value: '${nested(water, "dailyAverageMl")!.round()} ml'),
          if (nested(streak, 'longest') != null)
            _Stat(
                label: 'Longest streak',
                value: '${nested(streak, "longest")!.round()} days'),
        ],
      ),
    );
  }
}

/// A metric the data cannot support — shown as an explanation, never a zero.
class _Unavailable extends StatelessWidget {
  const _Unavailable({
    required this.title,
    required this.metric,
    required this.explanation,
  });

  final String title;
  final TrialMetric metric;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _SectionTitle(title)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: ZitlasTokens.bgCardLight,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text('Not available yet',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ZitlasTokens.textSecondary)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Explainer(explanation),
        ],
      ),
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: const Text('How these numbers were measured',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: ZitlasTokens.textSecondary)),
      iconColor: ZitlasTokens.textSecondary,
      collapsedIconColor: ZitlasTokens.textSecondary,
      children: [
        for (final warning in warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  ',
                    style: TextStyle(color: ZitlasTokens.textMuted)),
                Expanded(
                  child: Text(warning,
                      style: const TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: ZitlasTokens.textMuted)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── small shared pieces ─────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ZitlasTokens.bgCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: ZitlasTokens.border),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: ZitlasTokens.textPrimary));
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 14, color: ZitlasTokens.textSecondary)),
          ),
          const SizedBox(width: 12),
          Text(value,
              style: TextStyle(
                  fontSize: emphasis ? 18 : 15,
                  fontWeight: emphasis ? FontWeight.w800 : FontWeight.w600,
                  color: emphasis
                      ? ZitlasTokens.primary
                      : ZitlasTokens.textPrimary)),
        ],
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13, height: 1.45, color: ZitlasTokens.textSecondary)),
      );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: ZitlasTokens.textMuted),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: ZitlasTokens.textPrimary)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: ZitlasTokens.textSecondary)),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

String _shortDate(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = parsed.toLocal();
  return '${local.day} ${months[local.month - 1]}';
}
