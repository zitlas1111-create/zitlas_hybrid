import '../../../core/util/json_coerce.dart';
import 'diet_day.dart';
import 'diet_plan_content.dart';
import 'expert_meal_modification.dart';

/// The `zitlas_diet_plan` / `users/{uid}.dietPlan` wrapper — the single
/// authoritative Diet persistence schema, traced field-for-field from
/// `frontend/pages/diet/diet.js` (`isNewDietSchema`, `buildEffectivePlan`,
/// `acceptExpertPlan`) and `frontend/pages/experts/modify-diet.js`
/// (`buildAppliedDietWrapper`). This is NOT a new schema — every field here
/// already exists in production Firestore documents.
///
/// `expertModifications` keys are STRING day indices (`"0"`, `"1"`, ...)
/// mapping to a meal-key-keyed map of [ExpertMealModification] — kept as
/// strings here rather than parsed to int, matching the wire format
/// exactly so round-tripping through Firestore never risks a key mismatch.
class DietStorage {
  const DietStorage({
    required this.originalDietPlan,
    required this.currentDietPlan,
    this.expertModifications = const {},
    this.isExpertPlan = false,
    this.expertName,
    this.expertId,
    this.expertNotes,
    this.reviewedAt,
    this.reviewStatus,
    this.planSource,
    this.reviewId,
    this.version,
    this.lastUpdated,
    this.planId,
    this.originalRaw,
    this.currentRaw,
  });

  final DietPlanContent originalDietPlan;
  final DietPlanContent currentDietPlan;
  final Map<String, Map<String, ExpertMealModification>> expertModifications;
  final bool isExpertPlan;
  final String? expertName;
  final String? expertId;
  final String? expertNotes;
  final String? reviewedAt;
  final String? reviewStatus;
  final String? planSource;
  final String? reviewId;
  final int? version;
  final String? lastUpdated;

  /// Goal-identity stamp. `DietController` fail-closed-validates this
  /// against the athlete's live `users/{uid}.planId` before ever rendering
  /// this wrapper — a stale plan (from before a goal reset/regeneration)
  /// must never be shown or silently kept.
  final String? planId;

  /// The plans EXACTLY as they were read (or are to be written). Kept so every
  /// round-trip is lossless: fields the models do not model — a meal's
  /// timing notes, an expert's custom day fields — are never dropped when this
  /// wrapper is saved again (a planId stamp, an accept, another device).
  final Map<String, dynamic>? originalRaw;
  final Map<String, dynamic>? currentRaw;

  static bool isNewSchema(Map<String, dynamic>? m) =>
      m != null && m['originalDietPlan'] != null && m['currentDietPlan'] != null;

  factory DietStorage.fromMap(Map<String, dynamic> m) {
    final rawMods = (m['expertModifications'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mods = <String, Map<String, ExpertMealModification>>{};
    rawMods.forEach((dayIdx, mealsRaw) {
      if (mealsRaw is! Map) return;
      final perMeal = <String, ExpertMealModification>{};
      mealsRaw.forEach((mealKey, modRaw) {
        if (modRaw is Map) {
          perMeal[mealKey as String] = ExpertMealModification.fromMap(modRaw.cast<String, dynamic>());
        }
      });
      mods[dayIdx] = perMeal;
    });

    final originalRaw = (m['originalDietPlan'] as Map?)?.cast<String, dynamic>();
    final currentRaw = (m['currentDietPlan'] as Map?)?.cast<String, dynamic>();
    return DietStorage(
      originalDietPlan: DietPlanContent.fromMap(originalRaw),
      currentDietPlan: DietPlanContent.fromMap(currentRaw),
      originalRaw: originalRaw,
      currentRaw: currentRaw,
      expertModifications: mods,
      isExpertPlan: m['isExpertPlan'] == true,
      expertName: m['expertName'] as String?,
      expertId: m['expertId'] as String?,
      expertNotes: m['expertNotes'] as String?,
      reviewedAt: m['reviewedAt'] as String?,
      reviewStatus: m['reviewStatus'] as String?,
      planSource: m['planSource'] as String?,
      reviewId: m['reviewId'] as String?,
      version: (m['version'] as num?)?.toInt(),
      lastUpdated: m['lastUpdated'] as String?,
      planId: m['planId'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    final modsMap = <String, dynamic>{};
    expertModifications.forEach((dayIdx, meals) {
      modsMap[dayIdx] = meals.map((mealKey, mod) => MapEntry(mealKey, mod.toMap()));
    });

    return {
      'originalDietPlan': originalRaw ?? originalDietPlan.toMap(),
      'currentDietPlan': currentRaw ?? currentDietPlan.toMap(),
      'expertModifications': modsMap,
      'isExpertPlan': isExpertPlan,
      'expertName': expertName,
      'expertId': expertId,
      'expertNotes': expertNotes,
      'reviewedAt': reviewedAt,
      'reviewStatus': reviewStatus,
      'planSource': planSource,
      'reviewId': reviewId,
      'version': version,
      'lastUpdated': lastUpdated,
      'planId': planId,
    };
  }

  /// `buildEffectivePlan()` on the website (diet.js:337-372) — deep-clones
  /// `currentDietPlan` (falling back to `originalDietPlan`), then applies
  /// `expertModifications` on top per day/meal, stamping the
  /// `expertModified`/`modifiedBy`/`modifiedAt` render flags. This is what
  /// the Diet screen actually renders — never `currentDietPlan` raw.
  DietPlanContent buildEffectivePlan() {
    final base = currentDietPlan.hasDays ? currentDietPlan : originalDietPlan;
    if (!base.hasDays) return base;

    final newDays = <DietDay>[];
    for (var dayIdx = 0; dayIdx < base.days.length; dayIdx++) {
      final day = base.days[dayIdx];
      final dayMods = expertModifications[dayIdx.toString()];
      if (dayMods == null || dayMods.isEmpty) {
        newDays.add(day);
        continue;
      }

      final newMeals = day.meals.map((meal) {
        final mod = dayMods[meal.mealKey];
        if (mod == null || !mod.modified) return meal;

        final newMealSnapshot = mod.newMeal;
        return meal.copyWith(
          foods: newMealSnapshot?['foods'] is List
              ? (newMealSnapshot!['foods'] as List).map((e) => e.toString()).toList()
              : null,
          // Expert-editor-written snapshot — same string/number variance as
          // the LLM tree (see DietMeal.fromMap's doc comment).
          calories: asNum(newMealSnapshot?['calories']),
          proteinG: asNum(newMealSnapshot?['protein_g']),
          expertModified: true,
          modifiedBy: mod.modifiedBy ?? 'Expert',
          modifiedAt: mod.modifiedAt,
        );
      }).toList();

      newDays.add(day.copyWithMeals(newMeals));
    }

    return base.copyWithDays(newDays);
  }

  /// `_migrated` construction in `loadDietStorage()` (diet.js:296-306) —
  /// wraps a legacy flat `{days:[...]}` plan (pre-dating the expert
  /// modification schema) into the current wrapper shape.
  factory DietStorage.fromLegacyFlatPlan(DietPlanContent plan, {String? planId}) {
    return DietStorage(
      originalDietPlan: plan,
      currentDietPlan: plan,
      planId: planId,
    );
  }

  /// Fresh wrapper for a newly-generated AI plan (`saveToLocalStorage()` in
  /// ai-coach.js:2124-2131) — not exercised by this phase since AI
  /// generation isn't built in Flutter yet, but kept for schema parity and
  /// for when that phase lands.
  factory DietStorage.fromAiPlan(DietPlanContent plan, {String? planId}) {
    return DietStorage(
      originalDietPlan: plan,
      currentDietPlan: plan,
      isExpertPlan: false,
      planId: planId,
    );
  }

  DietStorage copyWith({
    DietPlanContent? currentDietPlan,
    Map<String, Map<String, ExpertMealModification>>? expertModifications,
    bool? isExpertPlan,
    String? planSource,
    String? planId,
  }) {
    return DietStorage(
      originalDietPlan: originalDietPlan,
      currentDietPlan: currentDietPlan ?? this.currentDietPlan,
      expertModifications: expertModifications ?? this.expertModifications,
      isExpertPlan: isExpertPlan ?? this.isExpertPlan,
      expertName: expertName,
      expertId: expertId,
      expertNotes: expertNotes,
      reviewedAt: reviewedAt,
      reviewStatus: reviewStatus,
      planSource: planSource ?? this.planSource,
      reviewId: reviewId,
      version: version,
      lastUpdated: DateTime.now().toIso8601String(),
      planId: planId ?? this.planId,
      originalRaw: originalRaw,
      // A replaced current plan is authoritative as modelled; an unchanged
      // one keeps its exact stored map.
      currentRaw: currentDietPlan == null ? currentRaw : null,
    );
  }
}

// Re-exported so callers only need one import for the common meal snapshot
// shape used when building `oldMeal`/`newMeal` — see DietMeal.toModificationSnapshot().
typedef MealSnapshot = Map<String, dynamic>;
