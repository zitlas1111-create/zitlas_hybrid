import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/util/json_coerce.dart';
import 'diet_plan_content.dart';

DateTime? _asDate(dynamic v) {
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v);
  return null;
}

Map<String, dynamic>? _asMapOrNull(dynamic v) => v is Map ? v.cast<String, dynamic>() : null;

/// One entry in a review's `mealChangeHistory` — the diff record an expert
/// leaves behind when editing a meal. Used to show a "what changed" summary
/// to the athlete.
///
/// TWO HISTORICAL SHAPES, read identically (the website's
/// `normalizeHistoryEntry()` in `assets/js/diet-review.js` does the same):
///  * the canonical flat record — `oldFoods/newFoods/oldCalories/…` — written
///    by expert-dashboard.js, the app's editor and, now, modify-diet.js;
///  * older modify-diet.js records — `oldMeal`/`newMeal` objects.
class MealChangeEntry {
  const MealChangeEntry({
    required this.dayIndex,
    required this.mealName,
    this.dayLabel,
    this.oldFoods = const [],
    this.newFoods = const [],
    this.oldCalories,
    this.newCalories,
    this.oldProtein,
    this.newProtein,
    this.reason,
    this.modifiedBy,
    this.modifiedAt,
  });

  final int dayIndex;
  final String mealName;
  final String? dayLabel;
  final List<String> oldFoods;
  final List<String> newFoods;
  final num? oldCalories;
  final num? newCalories;
  final num? oldProtein;
  final num? newProtein;
  final String? reason;
  final String? modifiedBy;
  final String? modifiedAt;

  String get mealKey => mealName.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  factory MealChangeEntry.fromMap(Map<String, dynamic> m) {
    final om = _asMapOrNull(m['oldMeal']);
    final nm = _asMapOrNull(m['newMeal']);
    // A present flat list wins (even empty), exactly like `h.oldFoods || …`.
    List<String> foods(String flat, String snake, Map<String, dynamic>? meal) {
      if (m[flat] != null) return asStringList(m[flat]);
      if (m[snake] != null) return asStringList(m[snake]);
      return meal == null ? const [] : asStringList(meal['foods']);
    }

    num? pick(String flat, String snake, Map<String, dynamic>? meal, String field) =>
        asNum(m[flat]) ?? asNum(m[snake]) ?? (meal == null ? null : asNum(meal[field]));

    return MealChangeEntry(
      dayIndex: asInt(m['dayIndex']) ?? asInt(m['day_index']) ?? 0,
      mealName: asText(m['mealName']) ??
          asText(m['meal_name']) ??
          asText(nm?['meal_name']) ??
          asText(nm?['name']) ??
          asText(om?['meal_name']) ??
          'Meal',
      dayLabel: asText(m['dayLabel']) ?? asText(m['dayName']),
      oldFoods: foods('oldFoods', 'old_foods', om),
      newFoods: foods('newFoods', 'new_foods', nm),
      oldCalories: pick('oldCalories', 'old_calories', om, 'calories'),
      newCalories: pick('newCalories', 'new_calories', nm, 'calories'),
      oldProtein: pick('oldProtein', 'old_protein', om, 'protein_g'),
      newProtein: pick('newProtein', 'new_protein', nm, 'protein_g'),
      reason: asText(m['reason']) ?? asText(nm?['notes']),
      modifiedBy: asText(m['modifiedBy']) ?? asText(m['modified_by']),
      modifiedAt: asText(m['modifiedAt']) ?? asText(m['modified_at']),
    );
  }
}

/// A `review_requests` doc where `reviewType == 'diet'`. Same collection,
/// same fields the Expert Dashboard's Reviews Inbox already reads/writes
/// (`lib/features/expert_dashboard/models/expert_models.dart`'s
/// `ReviewRequest`) — this is a diet-specific view over the identical
/// Firestore records, not a parallel schema.
class DietReviewRequest {
  const DietReviewRequest({
    required this.id,
    required this.status,
    this.userId,
    this.expertId,
    this.expertName,
    this.planId,
    this.isPremium = false,
    this.totalPrice,
    this.createdAt,
    this.reviewedAt,
    this.expertNotes,
    this.athleteAccepted = false,
    this.mealChangeHistory = const [],
    this.reviewedDietPlan,
    this.originalPlanData,
    this.reviewedDietPlanRaw,
    this.originalPlanDataRaw,
  });

  final String id;

  /// `pending | in_progress|expert_reviewing | review_completed|completed | rejected`
  final String status;
  final String? userId;
  final String? expertId;
  final String? expertName;
  final String? planId;
  final bool isPremium;
  final num? totalPrice;
  final DateTime? createdAt;
  final DateTime? reviewedAt;
  final String? expertNotes;
  final bool athleteAccepted;
  final List<MealChangeEntry> mealChangeHistory;

  /// The expert-edited plan, present once the review is complete — parsed for
  /// display.
  final DietPlanContent? reviewedDietPlan;

  /// `planData` on the raw doc — the plan snapshot as it was when the
  /// review was requested.
  final DietPlanContent? originalPlanData;

  /// The reviewed plan EXACTLY as stored. Accept persists this map, not the
  /// parsed model, so nothing the model does not know about is dropped.
  final Map<String, dynamic>? reviewedDietPlanRaw;
  final Map<String, dynamic>? originalPlanDataRaw;

  bool get isCompleted => status == 'review_completed' || status == 'completed';
  bool get isPending => status == 'pending';
  bool get isInProgress => status == 'in_progress' || status == 'expert_reviewing';
  bool get isRejected => status == 'rejected';

  factory DietReviewRequest.fromMap(String id, Map<String, dynamic> m) {
    final rawHistory = m['mealChangeHistory'] as List?;

    // `planData` may itself be wrapper-shaped (originalDietPlan/currentDietPlan)
    // per cprofile.js's unwrap logic — handle both.
    Map<String, dynamic>? planData = _asMapOrNull(m['planData']);
    if (planData != null &&
        (planData['originalDietPlan'] != null || planData['currentDietPlan'] != null)) {
      planData = _asMapOrNull(planData['currentDietPlan']) ?? _asMapOrNull(planData['originalDietPlan']);
    }
    final reviewedRaw = _asMapOrNull(m['reviewedDietPlan']);

    return DietReviewRequest(
      id: id,
      status: (m['status'] as String?) ?? 'pending',
      userId: m['userId'] as String?,
      expertId: m['expertId'] as String?,
      expertName: m['expertName'] as String?,
      planId: m['planId'] as String?,
      isPremium: m['isPremium'] == true,
      totalPrice: asNum(m['totalPrice']),
      createdAt: _asDate(m['createdAt']) ?? _asDate(m['submittedAt']),
      reviewedAt: _asDate(m['reviewedAt']),
      expertNotes: m['expertNotes'] as String?,
      athleteAccepted: m['athleteAccepted'] == true,
      mealChangeHistory: rawHistory
              ?.whereType<Map>()
              .map((e) => MealChangeEntry.fromMap(e.cast<String, dynamic>()))
              .toList() ??
          const [],
      reviewedDietPlan: DietPlanContent.fromMap(reviewedRaw),
      originalPlanData: planData != null ? DietPlanContent.fromMap(planData) : null,
      reviewedDietPlanRaw: reviewedRaw,
      originalPlanDataRaw: planData,
    );
  }
}
