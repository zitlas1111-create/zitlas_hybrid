"""
ZITLAS — Recipe Service (backend/services/recipe_service.py)

Loads backend/recipes/data/zitlas_recipes.json ONCE (lazy singleton, same
pattern as services/food_engine.py's get_engine()) and serves every recipe
lookup/filter/recommendation from that in-memory list — the API never
touches the backend/recipes/files (N)/ batch archives or re-parses JSON per
request.

The canonical dataset is built by backend/recipes/build_master_dataset.py
and checked by backend/recipes/validate_dataset.py — see those modules for
how the 637-recipe dataset was consolidated from the raw batch files and
what "valid" means. This service re-validates on load and logs loudly on any
problem, but does not crash the whole backend over a data issue in an
add-on feature — the same fail-soft posture routes/diet.py's food search
and the swap engine already take toward their own datasets.
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Any

from recipes import validate_dataset

DATASET_PATH = validate_dataset.DATASET_PATH

# Canonical values stored in the dataset's `fitness_goals` arrays — the
# snake_case keys are what the rest of ZITLAS's API/clients already use
# (see services/food_engine.py's goal_key_from_profile) so `?fitness_goal=`
# accepts either form rather than forcing callers to know the dataset's
# exact display strings.
_FITNESS_GOAL_DISPLAY: dict[str, str] = {
    "weight_loss": "Weight Loss",
    "muscle_gain": "Muscle Gain",
    "general_fitness": "General Fitness",
    "transformation": "Body Transformation",
    "body_transformation": "Body Transformation",
}

# `?diet_type=` aliases — the dataset itself only ever uses the four Title
# Case values on the right.
_DIET_TYPE_ALIASES: dict[str, str] = {
    "veg": "Vegetarian",
    "vegetarian": "Vegetarian",
    "vegan": "Vegan",
    "eggetarian": "Eggetarian",
    "egg": "Eggetarian",
    "non-veg": "Non-Vegetarian",
    "non_veg": "Non-Vegetarian",
    "nonveg": "Non-Vegetarian",
    "non-vegetarian": "Non-Vegetarian",
}

# `?meal_type=` aliases — the dataset's own values are on the right.
_MEAL_TYPE_ALIASES: dict[str, str] = {
    "breakfast": "Breakfast",
    "lunch": "Lunch",
    "dinner": "Dinner",
    "snack": "Evening Snack",
    "snacks": "Evening Snack",
    "evening_snack": "Evening Snack",
    "dessert": "Dessert",
    "desserts": "Dessert",
    "beverage": "Beverage",
    "drink": "Beverage",
    "drinks": "Beverage",
    "post_workout": "Post-Workout",
    "post-workout": "Post-Workout",
}


def _norm(s: str | None) -> str:
    return (s or "").strip().lower()


def _resolve_fitness_goal(raw: str) -> str:
    key = _norm(raw).replace(" ", "_")
    return _FITNESS_GOAL_DISPLAY.get(key, raw)


def _resolve_diet_type(raw: str) -> str:
    return _DIET_TYPE_ALIASES.get(_norm(raw), raw)


def _resolve_meal_type(raw: str) -> str:
    return _MEAL_TYPE_ALIASES.get(_norm(raw), raw)


class RecipeService:
    def __init__(self, path: Path = DATASET_PATH) -> None:
        recipes, result = validate_dataset.load_and_validate(path)
        if not result.ok:
            print(f"[RECIPE SERVICE] dataset validation FAILED on load "
                  f"({len(result.errors)} error(s)) — serving it anyway, "
                  f"but this needs fixing:\n{result.report()}")
        elif result.warnings:
            print(f"[RECIPE SERVICE] dataset loaded with warnings:\n{result.report()}")
        else:
            print(f"[RECIPE SERVICE] loaded {len(recipes)} recipes from {path}, validated clean")

        self.recipes: list[dict[str, Any]] = recipes
        self.by_id: dict[str, dict[str, Any]] = {r["id"]: r for r in recipes if r.get("id")}

    def get_by_id(self, recipe_id: str) -> dict[str, Any] | None:
        return self.by_id.get(recipe_id)

    def filter(
        self,
        meal_type: str | None = None,
        category: str | None = None,
        fitness_goal: str | None = None,
        diet_type: str | None = None,
        regional_tag: str | None = None,
        hostel_friendly: bool | None = None,
        home_friendly: bool | None = None,
        zitlas_original: bool | None = None,
        max_calories: float | None = None,
        min_protein: float | None = None,
        q: str | None = None,
    ) -> list[dict[str, Any]]:
        """Every filter is optional and ANDed — same convention as
        routes/diet.py's /foods/search. Returns [] rather than raising when
        nothing matches; an empty result is a normal, valid answer to a
        filter query, never an error."""
        results = self.recipes

        if meal_type:
            wanted = _resolve_meal_type(meal_type)
            results = [r for r in results if wanted in (r.get("meal_type") or [])]
        if category:
            wanted_cat = _norm(category)
            results = [r for r in results if _norm(r.get("category")) == wanted_cat]
        if fitness_goal:
            wanted_goal = _resolve_fitness_goal(fitness_goal)
            results = [r for r in results if wanted_goal in (r.get("fitness_goals") or [])]
        if diet_type:
            wanted_diet = _resolve_diet_type(diet_type)
            results = [r for r in results if _norm(r.get("diet_type")) == _norm(wanted_diet)]
        if regional_tag:
            wanted_region = _norm(regional_tag)
            results = [r for r in results if wanted_region in _norm(r.get("regional_tag"))]
        if hostel_friendly is not None:
            results = [r for r in results if r.get("hostel_friendly") == hostel_friendly]
        if home_friendly is not None:
            results = [r for r in results if r.get("home_friendly") == home_friendly]
        if zitlas_original is not None:
            results = [r for r in results if r.get("zitlas_original") == zitlas_original]
        if max_calories is not None:
            results = [r for r in results
                       if (r.get("nutrition_estimated") or {}).get("calories_kcal", 0) <= max_calories]
        if min_protein is not None:
            results = [r for r in results
                       if (r.get("nutrition_estimated") or {}).get("protein_g", 0) >= min_protein]
        if q:
            needle = _norm(q)
            results = [r for r in results if needle in _norm(r.get("name"))]

        return results

    def recommend(
        self,
        meal_type: str | None = None,
        fitness_goal: str | None = None,
        diet_type: str | None = None,
        hostel_friendly: bool | None = None,
        max_calories: float | None = None,
        limit: int = 1,
    ) -> list[dict[str, Any]]:
        """Deterministic filtering/scoring, not an AI recommender (per spec:
        "Do NOT invent a complex AI recommendation system"). Tries the full
        match first (meal type + diet type + fitness goal, the combination
        the spec calls out explicitly), then relaxes ONE constraint at a
        time — fitness goal first (a recipe can still suit a goal it isn't
        explicitly tagged for), then hostel-friendly, then calorie cap —
        never diet_type: a diet-type mismatch is a hard preference, the
        same way food_engine.py never relaxes diet type for the food
        engine. Never raises for "no perfect match" — degrades gracefully
        and returns the closest available result, or [] only if the
        dataset genuinely has nothing matching even the diet-type filter
        alone.
        """
        # Hard filter, never relaxed.
        pool = self.filter(diet_type=diet_type) if diet_type else self.recipes

        def _apply(p: list[dict], **kw) -> list[dict]:
            out = p
            if kw.get("meal_type"):
                wanted = _resolve_meal_type(kw["meal_type"])
                out = [r for r in out if wanted in (r.get("meal_type") or [])]
            if kw.get("fitness_goal"):
                wanted_goal = _resolve_fitness_goal(kw["fitness_goal"])
                out = [r for r in out if wanted_goal in (r.get("fitness_goals") or [])]
            if kw.get("hostel_friendly") is not None:
                out = [r for r in out if r.get("hostel_friendly") == kw["hostel_friendly"]]
            if kw.get("max_calories") is not None:
                out = [r for r in out
                       if (r.get("nutrition_estimated") or {}).get("calories_kcal", 0) <= kw["max_calories"]]
            return out

        # Progressive relaxation — same philosophy as food_engine.py's swap
        # tolerance widening: never fail outright when a full match doesn't
        # exist, degrade one constraint at a time instead.
        attempts = [
            dict(meal_type=meal_type, fitness_goal=fitness_goal, hostel_friendly=hostel_friendly, max_calories=max_calories),
            dict(meal_type=meal_type, hostel_friendly=hostel_friendly, max_calories=max_calories),
            dict(meal_type=meal_type, hostel_friendly=hostel_friendly),
            dict(meal_type=meal_type),
            dict(),
        ]
        for kwargs in attempts:
            matched = _apply(pool, **kwargs)
            if matched:
                return matched[:limit]
        return []


# ── Lazy singleton — loaded once, shared by every request (mirrors
#    services/food_engine.py's get_engine()) ─────────────────────────────
_service: RecipeService | None = None
_service_lock = threading.Lock()


def get_service() -> RecipeService:
    global _service
    if _service is None:
        with _service_lock:
            if _service is None:
                _service = RecipeService()
    return _service
