"""
ZITLAS — Workout Nutrition Service (backend/services/workout_nutrition_service.py)

Serves the PRE_WORKOUT/POST_WORKOUT slots from a SMALL, dedicated,
hand-curated dataset (backend/recipes/data/workout_nutrition.json) —
NEVER services/recipe_service.py's 637-recipe database.

Why this file exists at all: that dataset was built for normal MEALS
(Breakfast/Lunch/Dinner/Snack/Dessert/Beverage). A user's actual
pre-workout need ("what can I realistically eat/drink shortly before
training without feeling heavy") and post-workout need ("recovery —
protein + carbohydrate + hydration") are a different PURPOSE from "give me
a fitness-friendly recipe" — scoring inside the normal recipe pool kept
surfacing results that were healthy but wrong for the purpose (e.g. a full
paneer dish scoring well on fitness_goals/difficulty despite being far too
heavy to eat before training). This service is the fix: a small, separate,
purpose-built pool (16 items total) that routes/recipes.py routes to
INSTEAD of services/recipe_service.py for these two slots — never blended
with, or falling back to, the normal recommendation path.

Reuses services/recipe_service.py's existing diet/fitness-goal alias
tables and services/food_engine.py's living-situation resolver rather than
re-deriving them — the only genuinely new logic here is the workout-purpose
scoring itself (_score()).
"""

from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any

from services import food_engine
from services.recipe_service import (
    _LIVING_TAG_TO_RECIPE_PREFERENCE,
    _norm,
    _resolve_diet_type,
    _resolve_fitness_goal,
    region_keywords_for_location,
)

DATASET_PATH = Path(__file__).parent.parent / "recipes" / "data" / "workout_nutrition.json"

_SLOT_TO_DATASET_MEAL_TYPE = {"pre_workout": "Pre-Workout", "post_workout": "Post-Workout"}

# How readily an item clears the stomach — the single most important
# pre-workout property, and one macros CANNOT express. This is why the
# dataset carries it as a hand-assigned editorial field: the old
# enrich_food_dataset.py rule (`carbs>=20 and fat<=5 and calories<=200`
# -> "Pre Workout") happily tagged a 9 g-fibre beetroot salad and avocado
# toast as pre-workout fuel, because on macros alone they look fine.
_DIGESTIBILITY_SCORE = {"very_easy": 3.0, "easy": 2.0, "moderate": 1.0}

# What kind of fuel this is. Only meaningful close to training, where a fast
# sugar beats a slow-releasing one; an hour+ out the distinction fades.
_SHORT_WINDOW_FUEL_BONUS = {
    "hydration": 2.0,
    "quick_carbohydrate": 2.0,
    "carb_protein": 0.5,
    "slow_carbohydrate": 0.0,
    "protein_recovery": 0.0,
}

# Used when the caller supplies no workout time. ZITLAS has NO workout
# start-time field anywhere (checked: `WorkoutDay` carries only
# `duration_minutes`, and a diet meal's `time` is free text with no link to
# a training session), so this is an explicit stated assumption, never
# fabricated data presented as known. It leans SHORT on purpose: someone
# opening "Get Workout Fuel" is far more often minutes from training than
# two hours out, and the cost of being wrong is asymmetric — a banana 90
# minutes early is harmless, poha 10 minutes before training is not.
DEFAULT_ASSUMED_MINUTES_UNTIL_WORKOUT = 25

# Digestive-burden thresholds. DERIVED from each item's own
# `nutrition_estimated` rather than stored as `heavy`/`high_fat`/`high_fiber`
# booleans, so a flag can never drift out of sync with the numbers the
# athlete is shown on the same card.
_HIGH_FIBRE_G = 5.0
_HIGH_FAT_G = 10.0
_HEAVY_KCAL = 250.0


class WorkoutNutritionService:
    def __init__(self, path: Path = DATASET_PATH) -> None:
        with open(path, encoding="utf-8") as f:
            self.items: list[dict[str, Any]] = json.load(f)
        self.by_id: dict[str, dict[str, Any]] = {i["id"]: i for i in self.items}

    def get_by_id(self, item_id: str) -> dict[str, Any] | None:
        return self.by_id.get(item_id)

    def _pool(self, meal_slot: str, diet_type: str | None) -> list[dict[str, Any]]:
        """meal_slot is a HARD filter, same as meal_type is for normal
        recipes — a pre-workout request can never surface a post-workout
        item or vice versa. `diet_type: "Universal"` (banana, coconut
        water, ...) matches every diet_type; every other value here uses
        exactly the four Title Case strings the normal dataset does, so
        this stays a single equality check."""
        wanted_meal_type = _SLOT_TO_DATASET_MEAL_TYPE[meal_slot]
        pool = [i for i in self.items if wanted_meal_type in (i.get("meal_type") or [])]
        if diet_type:
            wanted_diet = _resolve_diet_type(diet_type)
            pool = [
                i for i in pool
                if i.get("diet_type") == "Universal" or _norm(i.get("diet_type")) == _norm(wanted_diet)
            ]
        return pool

    def _pre_workout_suitability(self, item: dict[str, Any], minutes: int) -> float:
        """How well this item suits eating `minutes` before training —
        the DOMINANT term for the pre-workout slot.

        Deliberately built from timing window + digestibility + preparation
        + digestive burden, NOT from "is this food healthy". A beetroot
        salad and a banana can look equally good on a macro screen; only
        these properties separate "practical fuel" from "a nutritious meal
        that will sit in your stomach during squats"."""
        score = 0.0

        lo = item.get("min_before_workout_min")
        hi = item.get("max_before_workout_min")
        if lo is not None and hi is not None:
            if lo <= minutes <= hi:
                score += 5.0
            else:
                # Outside its window — penalised by HOW far outside, so a
                # near-miss still beats a wildly inappropriate option
                # rather than both collapsing to the same rejection.
                distance = (lo - minutes) if minutes < lo else (minutes - hi)
                score -= min(distance / 10.0, 6.0)

        score += _DIGESTIBILITY_SCORE.get(item.get("digestibility"), 0.0)

        # Close to training, fast fuel and zero prep matter enormously;
        # an hour+ out they barely matter at all.
        if minutes <= 30:
            score += _SHORT_WINDOW_FUEL_BONUS.get(item.get("fuel_type"), 0.0)
            prep = (item.get("prep_time_min") or 0) + (item.get("cook_time_min") or 0)
            score += max(0.0, (10 - prep) / 10.0) * 2.0

        # Digestive burden — only penalised when it actually matters, i.e.
        # when there isn't time to digest before training starts.
        if minutes <= 45:
            nutrition = item.get("nutrition_estimated") or {}
            if (nutrition.get("fiber_g") or 0) >= _HIGH_FIBRE_G:
                score -= 1.5
            if (nutrition.get("fat_g") or 0) >= _HIGH_FAT_G:
                score -= 2.0
            if (nutrition.get("calories_kcal") or 0) >= _HEAVY_KCAL:
                score -= 1.5
        return score

    def _score(
        self, item: dict[str, Any], *, meal_slot: str,
        fitness_goal_display: str | None, recipe_preference: str | None,
        region_keywords: list[str], minutes_until_workout: int,
    ) -> float:
        """WORKOUT PURPOSE > GOAL > REGION, always — the spec's core rule
        for this feature. Goal/cooking-situation/region are real but
        intentionally weighted LOWER (1.0 each) than the purpose terms
        (up to ~12), so a Maharashtra athlete can never be handed a heavy
        regional dish before training just because it is regional, and a
        muscle-gain athlete is never handed a paneer meal 15 minutes out
        just because it is high protein."""
        score = 0.0
        if fitness_goal_display and fitness_goal_display in (item.get("fitness_goals") or []):
            score += 1.0
        if recipe_preference and item.get(recipe_preference):
            score += 1.0
        if region_keywords:
            tag = _norm(item.get("regional_tag"))
            if tag and any(kw in tag for kw in region_keywords):
                score += 1.0

        if meal_slot == "pre_workout":
            score += self._pre_workout_suitability(item, minutes_until_workout)
        else:
            # Recovery dominates: protein first, useful carbs second.
            nutrition = item.get("nutrition_estimated") or {}
            protein = nutrition.get("protein_g") or 0
            carbs = nutrition.get("carbs_g") or 0
            score += min(protein / 8.0, 4.0)
            score += min(carbs / 25.0, 1.5)
        return score

    def recommend(
        self,
        *,
        meal_slot: str,
        fitness_goal: str | None = None,
        diet_type: str | None = None,
        living_situation: str | None = None,
        hostel_friendly: bool | None = None,
        home_friendly: bool | None = None,
        location: dict | None = None,
        exclude_ids: "set[str] | None" = None,
        minutes_until_workout: int | None = None,
        limit: int = 1,
    ) -> list[dict[str, Any]]:
        """Deterministic — same posture as RecipeService.recommend()
        (filter, then score, never an AI call). `meal_slot` must already be
        "pre_workout" or "post_workout" (see recipe_service.resolve_meal_slot());
        this method has no "closest meal type" fallback at all — an empty
        pool (should never happen with 9 items per slot covering every diet
        type) returns [], never a normal-meal substitute.

        `minutes_until_workout` drives the pre-workout timing window. It is
        OPTIONAL and defaults to DEFAULT_ASSUMED_MINUTES_UNTIL_WORKOUT —
        ZITLAS stores no workout start time anywhere, so this is a stated
        assumption rather than invented data (see that constant's comment).
        Callers that DO know the gap (currently: the athlete picking one on
        the recipe screen) pass it explicitly."""
        pool = self._pool(meal_slot, diet_type)
        if not pool:
            return []

        if exclude_ids:
            narrowed = [i for i in pool if i["id"] not in exclude_ids]
            if narrowed:
                pool = narrowed
            # else: every match already shown — cycle back, never blank.

        recipe_preference = None
        if hostel_friendly is True:
            recipe_preference = "hostel_friendly"
        elif home_friendly is True:
            recipe_preference = "home_friendly"
        elif living_situation:
            living_tag = food_engine.living_tag_from_lifestyle(living_situation)
            recipe_preference = _LIVING_TAG_TO_RECIPE_PREFERENCE.get(living_tag or "")
        if hostel_friendly is not None:
            pool = [i for i in pool if i.get("hostel_friendly") == hostel_friendly] or pool
        if home_friendly is not None:
            pool = [i for i in pool if i.get("home_friendly") == home_friendly] or pool

        fitness_goal_display = _resolve_fitness_goal(fitness_goal) if fitness_goal else None
        _state, region_keywords = region_keywords_for_location(location) if location else (None, [])

        minutes = (
            DEFAULT_ASSUMED_MINUTES_UNTIL_WORKOUT
            if minutes_until_workout is None
            else max(0, minutes_until_workout)
        )

        def _final_score(i: dict[str, Any]) -> float:
            return self._score(
                i, meal_slot=meal_slot, fitness_goal_display=fitness_goal_display,
                recipe_preference=recipe_preference, region_keywords=region_keywords,
                minutes_until_workout=minutes,
            )

        ranked = sorted(pool, key=lambda i: (-_final_score(i), i["id"]))
        return ranked[:limit]

    def explain(
        self, item: dict[str, Any], *, meal_slot: str,
        minutes_until_workout: int | None = None,
    ) -> list[str]:
        """Leads with the slot's purpose (never a generic "easy recipe"
        reason) — everything after is honest, data-backed, same posture as
        RecipeService.explain_recommendation(). The timing reason is only
        stated when the caller actually supplied a gap; with no timing
        known ZITLAS never claims to know when the workout starts."""
        reasons: list[str] = []
        reasons.append(
            "Quick energy before training" if meal_slot == "pre_workout"
            else "Recovery-focused nutrition after training"
        )
        if meal_slot == "pre_workout" and minutes_until_workout is not None:
            reasons.append(f"Suits a ~{minutes_until_workout} minute window before training")
        total_time = (item.get("prep_time_min") or 0) + (item.get("cook_time_min") or 0)
        if total_time == 0:
            reasons.append("Ready to eat immediately")
        elif total_time <= 5:
            reasons.append(f"Ready in {total_time} min")
        if meal_slot == "pre_workout" and item.get("digestibility") == "very_easy":
            reasons.append("Very easy to digest")
        nutrition = item.get("nutrition_estimated") or {}
        if meal_slot == "post_workout" and (nutrition.get("protein_g") or 0) >= 15:
            reasons.append("High protein for recovery")
        if item.get("regional_tag"):
            reasons.append(f"{item['regional_tag']}")
        return reasons


# ── Lazy singleton — same pattern as recipe_service.get_service() ────────
_service: WorkoutNutritionService | None = None
_service_lock = threading.Lock()


def get_service() -> WorkoutNutritionService:
    global _service
    if _service is None:
        with _service_lock:
            if _service is None:
                _service = WorkoutNutritionService()
    return _service
