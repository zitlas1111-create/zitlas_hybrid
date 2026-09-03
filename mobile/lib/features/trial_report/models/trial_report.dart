import 'package:flutter/foundation.dart';

import '../../../core/util/json_coerce.dart';

/// `trial_reports/{requestId}` — the immutable Trial Completion Report the
/// backend froze when a coaching engagement ended.
///
/// THIS MODEL CALCULATES NOTHING. Every number here was computed once by
/// `backend/services/trial_report_service.py` and stored; re-deriving any of
/// it on the phone would produce a second answer that could disagree with
/// the athlete's own report on the web, and would silently change as their
/// plan changed afterwards. The whole point of the snapshot is that it does
/// not move. So this is a reader: it parses, and where a value is absent it
/// stays absent rather than becoming a zero.
///
/// THE METRIC CONTRACT. Every metric block carries `available`, which is
/// `true`, the string `"partial"`, or `false` — plus a `reason` when false.
/// A UI must render "not available yet, because …" for those, never 0%.
@immutable
class TrialMetric {
  const TrialMetric(this.raw);

  final Map<String, dynamic> raw;

  /// `true` | `"partial"` | `false`, exactly as the backend stated it.
  Object? get availability => raw['available'];

  bool get isAvailable => availability == true;
  bool get isPartial => availability == 'partial';

  /// Why the metric is unavailable — a machine-readable key such as
  /// `follow_up_completion_not_tracked`. Never shown raw to an athlete.
  String? get reason => raw['reason'] as String?;

  /// A percentage the backend actually computed, or null. Null means "not
  /// computed" and must never be rendered as 0.
  double? get percent => asNum(raw['percent'])?.toDouble();

  T? field<T>(String key) => raw[key] is T ? raw[key] as T : null;
  num? number(String key) => asNum(raw[key]);
  int? integer(String key) => asNum(raw[key])?.toInt();

  static const empty = TrialMetric({});
}

/// One stretch of the engagement during which one plan applied.
@immutable
class TrialPlanSegment {
  const TrialPlanSegment({
    required this.source,
    this.version,
    this.savedAt,
    this.savedBy,
    this.expectationAvailable = false,
  });

  /// `ai_generated` | `coach_customized` | `coach_authored_from_template`.
  final String source;
  final int? version;
  final String? savedAt;
  final String? savedBy;
  final bool expectationAvailable;

  bool get isAi => source == 'ai_generated';
  bool get isCoachCustomized => source == 'coach_customized';

  static TrialPlanSegment? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final source = m['source'] as String?;
    if (source == null) return null;
    return TrialPlanSegment(
      source: source,
      version: asNum(m['version'])?.toInt(),
      savedAt: m['savedAt'] as String?,
      savedBy: m['savedBy'] as String?,
      expectationAvailable: m['expectationAvailable'] == true,
    );
  }
}

/// The AI-plan → coach-customization story, as the backend resolved it.
///
/// ZITLAS does not have coaches authoring diet plans from scratch: the
/// coach's editor is preloaded with the athlete's AI-generated plan. So this
/// block exists to keep the UI's wording truthful — it exposes exactly what
/// the data supports and nothing more.
@immutable
class TrialPlanEvolution {
  const TrialPlanEvolution(this.raw, this.segments);

  final Map<String, dynamic> raw;
  final List<TrialPlanSegment> segments;

  /// `ai_plan_only` | `coach_customized_ai_plan` | `coach_authored_from_template`
  String get wording => (raw['wording'] as String?) ?? 'ai_plan_only';

  bool get aiPlanApplied => raw['aiPlanApplied'] == true;
  bool get coachCustomizedPlanApplied =>
      raw['coachCustomizedPlanApplied'] == true;

  /// True only when a coach save inside the engagement genuinely CHANGED the
  /// plan. A redundant autosave does not make this true.
  bool get customizationConfirmed => raw['customizationConfirmed'] == true;

  int get planSaves => asNum(raw['planSaves'])?.toInt() ?? 0;
  int get modifications => asNum(raw['modifications'])?.toInt() ?? 0;
  String? get firstModifiedAt => raw['firstModifiedAt'] as String?;
  String? get lastModifiedAt => raw['lastModifiedAt'] as String?;

  static TrialPlanEvolution fromMap(Object? raw) {
    if (raw is! Map) return const TrialPlanEvolution({}, []);
    final m = raw.cast<String, dynamic>();
    final rawSegments = m['segments'];
    return TrialPlanEvolution(m, [
      if (rawSegments is List)
        for (final s in rawSegments) ?TrialPlanSegment.fromMap(s),
    ]);
  }
}

/// One row of `GET /api/trial-reports` — a stored report's identity and
/// dates, with no metrics.
///
/// Deliberately NOT a partially-filled [TrialReport]: a summary genuinely has
/// no metrics, and modelling it as a report with empty ones would let a screen
/// render "0 meals" for data that was simply never requested. Opening a row
/// fetches the full snapshot by `requestId`.
@immutable
class TrialReportSummary {
  const TrialReportSummary({
    required this.requestId,
    this.coachId,
    this.coachName,
    this.coachingType,
    this.startDate,
    this.endDate,
    this.trialDurationDays,
    this.engagementStatus,
    this.reportVersion,
    this.generatedAt,
    this.storedAt,
  });

  final String requestId;
  final String? coachId;
  final String? coachName;
  final String? coachingType;
  final String? startDate;
  final String? endDate;
  final int? trialDurationDays;

  /// The COACHING engagement's end state — `expired` | `ended`.
  final String? engagementStatus;
  final String? reportVersion;
  final String? generatedAt;
  final String? storedAt;

  bool get isFreeTrial => coachingType == 'FREE_TRIAL';

  static TrialReportSummary? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final requestId = m['requestId'] as String?;
    if (requestId == null || requestId.isEmpty) return null;
    return TrialReportSummary(
      requestId: requestId,
      coachId: m['coachId'] as String?,
      coachName: m['coachName'] as String?,
      coachingType: m['coachingType'] as String?,
      startDate: m['startDate'] as String?,
      endDate: m['endDate'] as String?,
      trialDurationDays: asNum(m['trialDurationDays'])?.toInt(),
      engagementStatus: m['engagementStatus'] as String?,
      reportVersion: m['reportVersion'] as String?,
      generatedAt: m['generatedAt'] as String?,
      storedAt: m['storedAt'] as String?,
    );
  }
}

/// The whole stored report.
@immutable
class TrialReport {
  const TrialReport({
    required this.raw,
    required this.requestId,
    required this.athleteId,
    this.coachId,
    this.coachName,
    this.coachingType,
    this.trialDurationDays,
    this.startDate,
    this.endDate,
    this.engagementStatus,
    this.generatedAt,
    this.reportVersion,
    required this.period,
    required this.plan,
    required this.metrics,
    required this.activity,
    required this.dataQuality,
    required this.planEvolution,
  });

  final Map<String, dynamic> raw;

  final String requestId;
  final String athleteId;
  final String? coachId;
  final String? coachName;

  /// `FREE_TRIAL` | `PAID`.
  final String? coachingType;
  final int? trialDurationDays;
  final String? startDate;
  final String? endDate;

  /// The COACHING engagement's end state (`expired` / `ended`) — not the
  /// report's own lifecycle status.
  final String? engagementStatus;

  final String? generatedAt;
  final String? reportVersion;

  final Map<String, dynamic> period;
  final Map<String, dynamic> plan;
  final Map<String, dynamic> activity;
  final Map<String, dynamic> dataQuality;
  final Map<String, TrialMetric> metrics;
  final TrialPlanEvolution planEvolution;

  bool get isFreeTrial => coachingType == 'FREE_TRIAL';

  /// Elapsed 24-hour engagement days — the model meal expectations use. Not
  /// the number of calendar dates the engagement touched.
  int? get elapsedDays => asNum(period['elapsedDays'])?.toInt();
  int? get durationDays => asNum(period['durationDays'])?.toInt();

  TrialMetric metric(String key) => metrics[key] ?? TrialMetric.empty;

  TrialMetric get mealFollowThrough => metric('mealFollowThrough');
  TrialMetric get mealQuality => metric('mealQuality');
  TrialMetric get expertEngagement => metric('expertEngagement');
  TrialMetric get workoutAdherence => metric('workoutAdherence');
  TrialMetric get progress => metric('progress');
  TrialMetric get followUp => metric('followUp');
  TrialMetric get overall => metric('overall');

  List<String> get warnings {
    final raw = dataQuality['warnings'];
    return [
      if (raw is List)
        for (final w in raw)
          if (w is String && w.trim().isNotEmpty) w,
    ];
  }

  static Map<String, dynamic> _map(Object? raw) =>
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};

  static TrialReport? fromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    final requestId = m['requestId'] as String?;
    final athleteId = m['athleteId'] as String?;
    if (requestId == null || athleteId == null) return null;

    final rawMetrics = _map(m['metrics']);
    return TrialReport(
      raw: m,
      requestId: requestId,
      athleteId: athleteId,
      coachId: m['coachId'] as String?,
      coachName: m['coachName'] as String?,
      coachingType: m['coachingType'] as String?,
      trialDurationDays: asNum(m['trialDurationDays'])?.toInt(),
      startDate: m['startDate'] as String?,
      endDate: m['endDate'] as String?,
      engagementStatus: m['engagementStatus'] as String?,
      generatedAt: m['generatedAt'] as String?,
      reportVersion: m['reportVersion'] as String?,
      period: _map(m['period']),
      plan: _map(m['plan']),
      activity: _map(m['activity']),
      dataQuality: _map(m['dataQuality']),
      metrics: {
        for (final entry in rawMetrics.entries)
          if (entry.value is Map)
            entry.key: TrialMetric((entry.value as Map).cast<String, dynamic>()),
      },
      planEvolution: TrialPlanEvolution.fromMap(rawMetrics['planEvolution']),
    );
  }
}
