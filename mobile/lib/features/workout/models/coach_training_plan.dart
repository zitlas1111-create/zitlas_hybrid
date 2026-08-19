import '../../../core/util/json_coerce.dart';
import 'workout_day.dart';
import 'workout_exercise.dart';
import 'workout_plan_content.dart';

/// `personal_coaching/{uid}` — the athlete-coach relationship doc.
/// Field names confirmed from `weekly-plan.js`'s `initCoachTrainingMode()`
/// and `training/day.js`'s coaching-gate usage.
class PersonalCoachingRelationship {
  const PersonalCoachingRelationship({
    required this.status,
    this.planType,
    this.coachId,
    this.coachName,
    this.endDate,
  });

  /// 'active' | 'ended' | 'expired' | ...
  final String status;

  /// 'training' | 'diet' | 'complete' | ...
  final String? planType;
  final String? coachId;
  final String? coachName;
  final DateTime? endDate;

  /// `_pcShowsCoachPlan()` — a coach's training plan overrides the AI plan
  /// only while the relationship is ACTIVE, and only when that relationship
  /// actually covers training.
  ///
  /// 'ended' used to be accepted here too, matching the website, so a finished
  /// engagement kept prescribing the athlete's training indefinitely with no
  /// way back to their own AI/expert-reviewed plan. Historical data is
  /// untouched: the coaching_plans document still exists for audit, it simply
  /// stops being the ACTIVE plan the moment the relationship is not active.
  /// Kept byte-identical in meaning to the website's `_pcShowsCoachPlan()` so
  /// the two clients can never disagree about which plan an athlete is on.
  bool get showsCoachTrainingPlan =>
      status == 'active' &&
      (planType == 'training' || planType == 'complete');

  /// `ZitlasCoachingGate.evaluate(rel).active` — status is 'active' AND not
  /// past `endDate`. This is the separate, stricter gate used for "Send
  /// Workout to Coach" (a relationship that has merely ended still shows
  /// its last plan, per [showsCoachTrainingPlan], but must NOT accept new
  /// check-ins).
  bool get isActiveForCheckins {
    if (status != 'active') return false;
    if (endDate == null) return true;
    return endDate!.isAfter(DateTime.now());
  }

  factory PersonalCoachingRelationship.fromMap(Map<String, dynamic> m) {
    final raw = m['endDate'];
    return PersonalCoachingRelationship(
      status: (m['status'] as String?) ?? 'none',
      planType: m['planType'] as String?,
      coachId: m['coachId'] as String?,
      coachName: m['coachName'] as String?,
      endDate: raw is String ? DateTime.tryParse(raw) : null,
    );
  }
}

/// `coaching_plans/{uid}.training` — the coach-authored training override.
/// Converted into the same `WorkoutPlanContent`/`WorkoutDay` shape the AI
/// plan uses so every rendering widget is reused unchanged, mirroring
/// `applyCoachTraining()`'s `coachWp` conversion exactly.
class CoachTrainingPlan {
  const CoachTrainingPlan({required this.days, this.planId, this.updatedAt});

  final List<WorkoutDay> days;
  final String? planId;
  final String? updatedAt;

  bool get hasDays => days.isNotEmpty;

  /// `_pcCoachPlanIsCurrent()` — a coach plan only renders for the plan
  /// generation it was authored against.
  bool isCurrentFor(String? livePlanId) =>
      planId != null && livePlanId != null && planId == livePlanId;

  /// The `WorkoutPlanContent` the rest of the app renders, with the coach's
  /// plan name and `applyCoachTraining()`'s exact per-exercise transform:
  /// `reps`/`duration`/`rest` joined with ' · '.
  WorkoutPlanContent toPlanContent() {
    return WorkoutPlanContent(
      planName: '👨‍🏫 Coach Training Plan',
      days: days,
    );
  }

  /// Coach-authored values come from free-text form inputs in the coaching
  /// workspace, so `sets`/`duration`/`reps` arrive as strings at least as
  /// often as numbers — the same tolerance the LLM tree needs applies here
  /// for a different reason.
  factory CoachTrainingPlan.fromMap(Map<String, dynamic> m) {
    final days = asMapList(m['days']).map((d) {
      final isRest = d['rest'] == true;
      final focus = asText(d['focus']) ?? 'Training Session';
      return WorkoutDay(
        day: asText(d['day']) ?? '',
        focus: isRest ? 'Rest & Recovery' : focus,
        type: isRest ? 'Rest & Recovery' : focus,
        durationMinutes: asNum(d['duration']),
        exercises: isRest
            ? const []
            : asMapList(d['exercises']).map((ex) {
                // `applyCoachTraining()` joins reps/duration/rest into one
                // caption with ' · ' — reproduced exactly.
                final parts = <String>[
                  if (asText(ex['reps']) != null) asText(ex['reps'])!,
                  if (asText(ex['duration']) != null) asText(ex['duration'])!,
                  if (asText(ex['rest']) != null) 'rest ${asText(ex['rest'])}',
                ];
                return WorkoutExercise(
                  name: asText(ex['name']) ?? 'Exercise',
                  sets: asDisplayString(ex['sets']),
                  repsOrDuration: parts.isEmpty ? null : parts.join(' · '),
                  tip: asText(ex['notes']),
                );
              }).toList(),
      );
    }).toList();

    return CoachTrainingPlan(
      days: days,
      planId: asText(m['planId']),
      updatedAt: asText(m['trainingUpdatedAt']),
    );
  }
}
