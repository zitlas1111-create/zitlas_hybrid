/// THE diet precedence rule — which diet is the athlete's current diet.
///
/// Line-for-line the website's `frontend/website/assets/js/diet-precedence.js`,
/// and pinned by ONE shared fixture, `tests/fixtures/diet_precedence_cases.json`,
/// run by both `test/diet_precedence_parity_test.dart` and the website's JS
/// test — so for identical Firestore state the two clients cannot disagree.
///
///  1. [DietSource.coach] — the active Personal Coaching diet, when ALL hold:
///     relationship status `active`; its end date absent or in the future;
///     it covers diet (planType `diet` / `complete`; a free trial's null
///     planType is full coverage); `coaching_plans/{uid}.diet` has at least
///     one meal; the plan belongs to the current coach; and NOT (plan planId
///     AND live planId both present AND different) — a null planId is fine.
///  2. [DietSource.expert] — `users/{uid}.dietPlan` is an accepted/applied
///     expert-reviewed wrapper stamped with a planId that does not contradict
///     the live one (an UNSTAMPED expert layer cannot prove its goal).
///  3. [DietSource.ai] — `users/{uid}.dietPlan` as the AI plan.
///  4. [DietSource.aiMaster] — `users/{uid}.dietPlanMaster`.
///  5. [DietSource.none].
///
/// Server data only — never a local cache. No timestamps are compared: the
/// relationship decides, which is deterministic across clients and clocks.
library;

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

enum DietSource { coach, expert, ai, aiMaster, none }

extension DietSourceWire on DietSource {
  /// The fixture's / website's spelling.
  String get wire => switch (this) {
        DietSource.coach => 'coach',
        DietSource.expert => 'expert',
        DietSource.ai => 'ai',
        DietSource.aiMaster => 'ai_master',
        DietSource.none => 'none',
      };
}

const _dietPlanTypes = {'diet', 'complete'};

String? _text(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

DateTime? _date(Object? v) {
  if (v is DateTime) return v;
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v);
  if (v is Map && v['seconds'] is num) {
    return DateTime.fromMillisecondsSinceEpoch(((v['seconds'] as num) * 1000).round(), isUtc: true);
  }
  return null;
}

List<Object?> _mealsOf(Object? day) {
  if (day is! Map) return const [];
  final m = day['meals'];
  if (m is List) return m;
  if (m is Map) return m.values.toList();
  return const [];
}

/// A meal counts when it has a name — the same test both clients' parsers
/// apply before rendering a coach meal at all.
int _countMeals(Object? plan) {
  if (plan is! Map || plan['days'] is! List) return 0;
  var n = 0;
  for (final day in plan['days'] as List) {
    for (final meal in _mealsOf(day)) {
      if (meal is Map && _text(meal['name'] ?? meal['meal_name']) != null) n++;
    }
  }
  return n;
}

bool _hasDays(Object? plan) => plan is Map && plan['days'] is List && (plan['days'] as List).isNotEmpty;

/// The plan-id safety rule: only two PRESENT ids that differ disagree.
bool _contradicts(String? a, String? b) => a != null && b != null && a != b;

/// The standing of a `users/{uid}.dietPlan` wrapper.
class WrapperFacts {
  const WrapperFacts({this.planId, this.expert = false, this.hasDays = false});

  final String? planId;
  final bool expert;
  final bool hasDays;
}

/// The handful of facts the rule reads.
class DietPrecedenceInput {
  const DietPrecedenceInput({
    required this.now,
    this.livePlanId,
    this.hasRelationship = false,
    this.relStatus,
    this.relCoachId,
    this.relPlanType,
    this.relEnd,
    this.hasCoachPlan = false,
    this.coachPlanCoachId,
    this.coachPlanPlanId,
    this.coachMealCount = 0,
    this.wrapper,
    this.legacyFlat = false,
    this.hasMaster = false,
    this.masterPlanId,
  });

  final DateTime now;
  final String? livePlanId;
  final bool hasRelationship;
  final String? relStatus;
  final String? relCoachId;
  final String? relPlanType;
  final DateTime? relEnd;
  final bool hasCoachPlan;
  final String? coachPlanCoachId;
  final String? coachPlanPlanId;
  final int coachMealCount;
  final WrapperFacts? wrapper;
  final bool legacyFlat;
  final bool hasMaster;
  final String? masterPlanId;

  /// Raw Firestore-shaped state — exactly what the shared fixture holds and
  /// what the website's `normalize()` reads.
  factory DietPrecedenceInput.fromRaw({
    Map<String, dynamic>? relationship,
    Map<String, dynamic>? coachingPlan,
    Object? dietPlan,
    Object? dietPlanMaster,
    Object? livePlanId,
    Object? now,
  }) {
    final rel = relationship;
    final cp = coachingPlan;
    final diet = cp?['diet'];
    final dp = dietPlan is Map ? dietPlan.cast<String, dynamic>() : null;
    final master = dietPlanMaster is Map ? dietPlanMaster.cast<String, dynamic>() : null;
    final masterPlan = master == null
        ? null
        : (master['plan'] is Map && (master['plan'] as Map)['days'] is List ? master['plan'] : master);
    final isWrapper = dp != null && dp['originalDietPlan'] != null && dp['currentDietPlan'] != null;
    WrapperFacts? wrapper;
    if (isWrapper) {
      final mods = dp['expertModifications'];
      final expert = dp['isExpertPlan'] == true ||
          (mods is Map && mods.values.any((v) => v is Map && v.isNotEmpty));
      wrapper = WrapperFacts(
        planId: _text(dp['planId']),
        expert: expert,
        hasDays: _hasDays(dp['currentDietPlan']) || _hasDays(dp['originalDietPlan']),
      );
    }
    return DietPrecedenceInput(
      now: _date(now) ?? DateTime.now(),
      livePlanId: _text(livePlanId),
      hasRelationship: rel != null,
      relStatus: rel?['status'] as String?,
      relCoachId: _text(rel?['coachId']),
      relPlanType: _text(rel?['planType']),
      relEnd: _date(rel?['endDateTs']) ?? _date(rel?['endDate']),
      hasCoachPlan: cp != null,
      coachPlanCoachId: _text(cp?['coachId']),
      coachPlanPlanId: diet is Map ? _text(diet['planId']) : null,
      coachMealCount: _countMeals(diet),
      wrapper: wrapper,
      legacyFlat: !isWrapper && _hasDays(dp),
      hasMaster: _hasDays(masterPlan),
      masterPlanId: _text(master?['planId']),
    );
  }
}

bool coachDietActive(DietPrecedenceInput n) {
  if (!n.hasRelationship || n.relStatus != 'active') return false;
  final end = n.relEnd;
  if (end != null && !end.isAfter(n.now)) return false;
  if (!_dietPlanTypes.contains(n.relPlanType ?? 'complete')) return false;
  if (!n.hasCoachPlan || n.coachMealCount < 1) return false;
  if (n.coachPlanCoachId != null && n.relCoachId != null && n.coachPlanCoachId != n.relCoachId) {
    return false;
  }
  if (_contradicts(n.coachPlanPlanId, n.livePlanId)) return false;
  return true;
}

/// [DietSource.expert] / [DietSource.ai] / null — the wrapper's standing.
DietSource? wrapperVerdict(DietPrecedenceInput n) {
  final w = n.wrapper;
  if (w == null || !w.hasDays) return null;
  if (_contradicts(w.planId, n.livePlanId)) return null;
  if (w.expert) return w.planId != null ? DietSource.expert : null;
  return DietSource.ai;
}

DietSource selectDietSource(DietPrecedenceInput n) {
  if (coachDietActive(n)) return DietSource.coach;
  final verdict = wrapperVerdict(n);
  if (verdict != null) return verdict;
  if (n.legacyFlat) return DietSource.ai;
  if (n.hasMaster && !_contradicts(n.masterPlanId, n.livePlanId)) return DietSource.aiMaster;
  return DietSource.none;
}
