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

    def _score(
        self, item: dict[str, Any], *, meal_slot: str,
        fitness_goal_display: str | None, recipe_preference: str | None,
        region_keywords: list[str],
    ) -> float:
        """WORKOUT PURPOSE > GOAL > REGION, always — the spec's core rule
        for this feature. Goal/cooking-situation/region are real but
        intentionally weighted LOWER than the equivalent terms in
        RecipeService._context_score(), so they can never outrank an
        item's fitness for the slot's actual purpose the way they could
        when this used to search the normal recipe pool."""
        score = 0.0
        if fitness_goal_display and fitness_goal_display in (item.get("fitness_goals") or []):
            score += 1.0
        if recipe_preference and item.get(recipe_preference):
            score += 1.0
        if region_keywords:
            tag = _norm(item.get("regional_tag"))
            if tag and any(kw in tag for kw in region_keywords):
                score += 1.0

        nutrition = item.get("nutrition_estimated") or {}
        total_time = (item.get("prep_time_min") or 0) + (item.get("cook_time_min") or 0)
        if meal_slot == "pre_workout":
            # Quick + light + low-fat dominates — this is the whole point
            # of the slot, so it outweighs every context term above.
            score += max(0.0, (30 - total_time) / 30) * 3.0
            fat = nutrition.get("fat_g") or 0
            if fat <= 2:
                score += 2.0
            elif fat <= 5:
                score += 1.0
            calories = nutrition.get("calories_kcal") or 0
            if calories <= 120:
                score += 1.0
        else:
            # Recovery dominates: protein first, useful carbs second.
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
        limit: int = 1,
    ) -> list[dict[str, Any]]:
        """Deterministic — same posture as RecipeService.recommend()
        (filter, then score, never an AI call). `meal_slot` must already be
        "pre_workout" or "post_workout" (see recipe_service.resolve_meal_slot());
        this method has no "closest meal type" fallback at all — an empty
        pool (should never happen with 8 items per slot covering every diet
        type) returns [], never a normal-meal substitute."""
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

        def _final_score(i: dict[str, Any]) -> float:
            return self._score(
                i, meal_slot=meal_slot, fitness_goal_display=fitness_goal_display,
                recipe_preference=recipe_preference, region_keywords=region_keywords,
            )

        ranked = sorted(pool, key=lambda i: (-_final_score(i), i["id"]))
        return ranked[:limit]

    def explain(self, item: dict[str, Any], *, meal_slot: str) -> list[str]:
        """Leads with the slot's purpose (never a generic "easy recipe"
        reason) — everything after is honest, data-backed, same posture as
        RecipeService.explain_recommendation()."""
        reasons: list[str] = []
        reasons.append(
            "Quick energy before training" if meal_slot == "pre_workout"
            else "Recovery-focused nutrition after training"
        )
        total_time = (item.get("prep_time_min") or 0) + (item.get("cook_time_min") or 0)
        if total_time == 0:
            reasons.append("Ready to eat immediately")
        elif total_time <= 5:
            reasons.append(f"Ready in {total_time} min")
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
