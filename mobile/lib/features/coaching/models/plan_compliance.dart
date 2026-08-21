import 'package:flutter/foundation.dart';

import '../../diet/models/diet_profile.dart';
import 'coach_diet_plan.dart';

/// Does the coach's week respect what the athlete actually told us?
///
/// Checks the athlete's OWN recorded profile — diet type, allergies, foods
/// they never eat, disliked foods, budget tier — against the plan the coach
/// is writing. The coach is never blocked: a coach may have a clinical reason
/// to prescribe something the athlete dislikes, and a tool that refuses to
/// save is a tool that gets worked around. It warns, precisely, and saves.
///
/// ON BUDGET — THERE IS NO RUPEE COST IN ZITLAS. The 4,520-food dataset
/// carries `budgetCategory` (Low/Medium/High) and `budget_tier_detailed`, and
/// the athlete's intake records a TIER (Economy/Standard/Premium), not an
/// amount. So "₹212/day vs ₹250/day" cannot be computed from anything real,
/// and this deliberately does not invent it: a coach shown a fabricated ₹212
/// would trust it. What it reports instead is the genuine signal — how much of
/// the week sits above the tier the athlete said they could afford.

/// How a single food measures up against one athlete's profile.
enum ComplianceIssue {
  /// Names an allergen the athlete recorded. The most serious kind.
  allergen('🚨', 'Allergy'),

  /// Violates the athlete's diet type (meat in a vegetarian plan, etc).
  dietType('🥗', 'Diet type'),

  /// The athlete said they never eat this.
  neverEaten('🚫', 'Never eats'),

  /// The athlete said they dislike it. Worth knowing, not alarming.
  disliked('😕', 'Disliked'),

  /// Costs more than the tier the athlete said they could afford.
  overBudget('💰', 'Over budget');

  const ComplianceIssue(this.icon, this.label);

  final String icon, label;

  /// Allergens and diet-type breaks are safety/identity issues; the rest are
  /// preferences. Drives whether the UI shouts or mentions.
  bool get isSevere => this == allergen || this == dietType;
}

/// One flagged food, with the reason and the athlete's own words for it.
@immutable
class ComplianceFlag {
  const ComplianceFlag({
    required this.issue,
    required this.foodName,
    required this.detail,
    this.day,
    this.mealName,
  });

  final ComplianceIssue issue;
  final String foodName;

  /// What the athlete recorded that this collides with — quoted back so the
  /// coach can see the source, not just a verdict.
  final String detail;

  final String? day;
  final String? mealName;
}

/// Budget tier ordering. Higher costs more.
const _tierRank = {'low': 0, 'medium': 1, 'high': 2};

int _rankOfTier(String? tier) => _tierRank[(tier ?? 'medium').toLowerCase()] ?? 1;

/// The athlete's budget tier expressed on the dataset's own scale.
int _rankOfBudget(FoodBudget? budget) => switch (budget) {
      FoodBudget.economy => 0,
      FoodBudget.standard => 1,
      FoodBudget.premium => 2,
      null => 2, // No stated budget: nothing is "over".
    };

/// Which diet types permit which dataset tags.
///
/// A vegan plan excludes dairy and egg; a vegetarian one permits dairy but not
/// egg or meat; eggetarian adds egg; non-vegetarian permits everything. Read
/// against the dataset's `dietSuitable` list, which is what the generator
/// itself filters on, so the coach's editor and the engine agree.
bool _dietAllows(DietPreference? preference, List<String> dietSuitable) {
  if (preference == null || dietSuitable.isEmpty) return true;
  final tags = dietSuitable.map((t) => t.toLowerCase()).toSet();
  return switch (preference) {
    DietPreference.vegan => tags.contains('vegan'),
    DietPreference.vegetarian =>
      tags.contains('vegetarian') || tags.contains('vegan'),
    DietPreference.eggetarian => tags.contains('vegetarian') ||
        tags.contains('vegan') ||
        tags.contains('eggetarian'),
    DietPreference.nonVegetarian => true,
  };
}

/// Checks ONE food the coach is about to add.
///
/// Used by the editor at the moment of choosing, so a problem is caught before
/// it reaches the athlete's plan rather than in a summary afterwards.
List<ComplianceFlag> checkFood({
  required String foodName,
  required DietProfile profile,
  List<String> dietSuitable = const [],
  List<String> allergens = const [],
  String? budgetCategory,
  String? day,
  String? mealName,
}) {
  final flags = <ComplianceFlag>[];
  final lower = foodName.toLowerCase();

  ComplianceFlag flag(ComplianceIssue issue, String detail) => ComplianceFlag(
        issue: issue,
        foodName: foodName,
        detail: detail,
        day: day,
        mealName: mealName,
      );

  // Allergies first — matched against BOTH the dataset's allergen tags and the
  // food's own name. The athlete types free text ("peanut"), and a dish called
  // "Peanut Chikki" must be caught even if the dataset never tagged it.
  for (final allergy in profile.allergies) {
    final needle = allergy.trim().toLowerCase();
    if (needle.isEmpty) continue;
    final taggedAllergen = allergens.any((a) => a.toLowerCase().contains(needle));
    if (taggedAllergen || lower.contains(needle)) {
      flags.add(flag(ComplianceIssue.allergen, 'Allergic to $allergy'));
    }
  }

  if (!_dietAllows(profile.dietPreference, dietSuitable)) {
    flags.add(flag(
      ComplianceIssue.dietType,
      'User is ${profile.dietPreference!.label}',
    ));
  }

  for (final never in profile.neverEaten) {
    final needle = never.trim().toLowerCase();
    if (needle.isNotEmpty && lower.contains(needle)) {
      flags.add(flag(ComplianceIssue.neverEaten, 'Never eats $never'));
    }
  }

  for (final disliked in profile.dislikedFoods) {
    final needle = disliked.trim().toLowerCase();
    if (needle.isNotEmpty && lower.contains(needle)) {
      flags.add(flag(ComplianceIssue.disliked, 'Dislikes $disliked'));
    }
  }

  if (budgetCategory != null &&
      _rankOfTier(budgetCategory) > _rankOfBudget(profile.budget)) {
    flags.add(flag(
      ComplianceIssue.overBudget,
      '$budgetCategory-cost food · user\'s budget is '
      '${profile.budget?.label ?? "not set"}',
    ));
  }

  return flags;
}

/// The whole week, checked.
@immutable
class PlanComplianceReport {
  const PlanComplianceReport({
    required this.flags,
    required this.totalFoods,
    required this.overBudgetFoods,
    required this.lovedFoodsUsed,
  });

  final List<ComplianceFlag> flags;
  final int totalFoods;
  final int overBudgetFoods;

  /// Foods from the athlete's own "loved" list that the coach did include —
  /// worth surfacing, because a plan an athlete enjoys is one they follow.
  final int lovedFoodsUsed;

  List<ComplianceFlag> get severe => [
        for (final f in flags)
          if (f.issue.isSevere) f,
      ];

  bool get hasSevere => severe.isNotEmpty;
  bool get isClean => flags.isEmpty;

  /// Share of the week's foods that sit above the user's budget tier.
  double get overBudgetShare => totalFoods == 0 ? 0 : overBudgetFoods / totalFoods;

  /// The budget line for the coach — in tiers, because tiers are what exist.
  String? get budgetWarning {
    if (overBudgetFoods == 0) return null;
    final pct = (overBudgetShare * 100).round();
    return '$overBudgetFoods of $totalFoods foods ($pct%) cost more than this '
        "athlete's stated budget. You can still save — this is a heads-up, not a block.";
  }

  static const empty = PlanComplianceReport(
    flags: [],
    totalFoods: 0,
    overBudgetFoods: 0,
    lovedFoodsUsed: 0,
  );
}

/// Checks an entire coach-authored week against the athlete's profile.
///
/// Every option in every meal is checked — an athlete allergic to peanuts is
/// not safe just because the FIRST option avoids them.
PlanComplianceReport checkPlan({
  required CoachDietPlan plan,
  required DietProfile profile,
  Map<String, String> budgetByFood = const {},
  Map<String, List<String>> dietSuitableByFood = const {},
  Map<String, List<String>> allergensByFood = const {},
}) {
  final flags = <ComplianceFlag>[];
  var total = 0;
  var overBudget = 0;
  var loved = 0;

  final lovedNeedles = [
    for (final f in profile.lovedFoods)
      if (f.trim().isNotEmpty) f.trim().toLowerCase(),
  ];

  for (final day in plan.days) {
    for (final meal in day.meals) {
      for (final option in meal.options) {
        total++;
        final key = option.name.toLowerCase();
        final found = checkFood(
          foodName: option.name,
          profile: profile,
          dietSuitable: dietSuitableByFood[key] ?? const [],
          allergens: allergensByFood[key] ?? const [],
          budgetCategory: budgetByFood[key],
          day: day.day,
          mealName: meal.name,
        );
        flags.addAll(found);
        if (found.any((f) => f.issue == ComplianceIssue.overBudget)) overBudget++;
        if (lovedNeedles.any(key.contains)) loved++;
      }
    }
  }

  return PlanComplianceReport(
    flags: flags,
    totalFoods: total,
    overBudgetFoods: overBudget,
    lovedFoodsUsed: loved,
  );
}
