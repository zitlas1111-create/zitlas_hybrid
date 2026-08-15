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
from services import food_engine, location_food_engine

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
#
# Deliberately NO "post_workout"/"pre_workout" entries here, even though 7
# recipes in the dataset carry a literal "Post-Workout" meal_type tag: this
# service must have ZERO path back to recommending from the normal-meal
# database for either workout slot (see resolve_meal_slot() and
# services/workout_nutrition_service.py). Those 7 tagged recipes are
# untouched data, still reachable via the exact-case `/api/recipes?
# meal_type=Post-Workout` raw browse, but never through this alias table or
# through recommend().
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
}

# PRE_WORKOUT/POST_WORKOUT are meal SLOTS, never literal dataset `meal_type`
# values, and — critically — this service NEVER serves them. Scoring a
# "fitness-friendly" recipe out of the 637-recipe normal-meal dataset kept
# surfacing results that were healthy but wrong for the purpose (a full
# paneer dish scored well on fitness_goals/difficulty despite being far too
# heavy to eat before training). Both workout slots are served exclusively
# by services/workout_nutrition_service.py's small, purpose-built dataset —
# resolve_meal_slot() exists only so routes/recipes.py can recognize a
# workout slot BEFORE ever reaching this module, and dispatch there instead.
_PRE_WORKOUT_SLOT_KEYS = {"pre_workout", "preworkout"}
_POST_WORKOUT_SLOT_KEYS = {"post_workout", "postworkout"}


def resolve_meal_slot(meal_type: str | None) -> str | None:
    """"pre_workout" / "post_workout" when `meal_type` names one of those
    special slots (any of pre_workout/pre-workout/preworkout and the post-
    equivalents), else None. The ONE place that recognizes a workout slot —
    routes/recipes.py calls this before deciding whether to route to this
    module's normal-meal recommend() or to
    workout_nutrition_service.recommend() instead."""
    if not meal_type:
        return None
    key = _norm(meal_type).replace("-", "_").replace(" ", "_")
    if key in _PRE_WORKOUT_SLOT_KEYS:
        return "pre_workout"
    if key in _POST_WORKOUT_SLOT_KEYS:
        return "post_workout"
    return None


# State (canonical spelling from location_food_engine.resolve_state, which
# this module reuses rather than re-parsing city/state itself) -> substrings
# to look for inside a recipe's `regional_tag`. Built from the RECIPE
# dataset's actual observed regional_tag vocabulary (every distinct value
# was enumerated before writing this table — nothing here is guessed), not
# from services/location_food_engine.py's own state->zone table, because the
# recipe dataset's tagging vocabulary ("Kolhapur-inspired", "Khandesh-
# inspired", "Malvani-inspired", ...) is finer-grained than that food-engine
# zone system and doesn't line up 1:1 with it.
#
# SOFT signal only — see RecipeService.recommend()'s scoring. A state with no
# entry here (or a recipe with regional_tag=None, ~39% of the dataset) never
# excludes anything; it just doesn't earn the regional bonus. This is what
# "gracefully fall back to broader Indian recipes" means in practice, and
# it's also why this table only needs to grow as regional coverage grows —
# it can never make a query return fewer results than before.
_STATE_REGIONAL_KEYWORDS: dict[str, list[str]] = {
    "Maharashtra": ["maharashtr", "kolhapur", "malvani", "khandesh", "marathwada",
                    "konkan", "vidarbha", "solapur", "nagpur", "mumbai", "nashik",
                    "ratnagiri", "sindhudurg", "parsi"],
    "Goa": ["konkan", "coastal indian"],
    "Karnataka": ["karnataka", "mangalorean", "south indian", "coastal indian"],
    "Kerala": ["kerala", "south indian", "coastal indian"],
    "Tamil Nadu": ["tamil nadu", "south indian"],
    "Telangana": ["hyderabadi", "south indian"],
    "Andhra Pradesh": ["south indian", "coastal indian"],
    "Gujarat": ["gujarati", "kutchi", "parsi"],
    "Punjab": ["punjabi"],
    "Haryana": ["punjabi", "north indian"],
    "Chandigarh": ["punjabi", "north indian"],
    "Delhi": ["north indian", "north indian street-food"],
    "Uttar Pradesh": ["north indian", "lucknowi", "north indian street-food"],
    "Rajasthan": ["rajasthani"],
    "Bihar": ["bihar", "bihar-jharkhand"],
    "Jharkhand": ["bihar-jharkhand"],
    "West Bengal": ["bengali", "kolkata"],
    "Jammu & Kashmir": ["kashmiri"],
    "Ladakh": ["kashmiri"],
    "Himachal Pradesh": ["himachali"],
    "Chhattisgarh": ["chhattisgarhi"],
    "Uttarakhand": ["uttarakhandi"],
    "Manipur": ["manipuri", "northeast indian", "north-east indian"],
    "Assam": ["assamese", "northeast indian", "north-east indian"],
    "Sikkim": ["sikkim-inspired", "northeast indian"],
    "Meghalaya": ["northeast indian", "north-east indian"],
    "Arunachal Pradesh": ["northeast indian", "north-east indian"],
    "Mizoram": ["northeast indian", "north-east indian"],
    "Nagaland": ["northeast indian", "north-east indian"],
    "Tripura": ["northeast indian", "north-east indian"],
    "Madhya Pradesh": ["north indian"],
    "Odisha": ["odia"],
}

# Cooking-situation -> which recipe boolean it should boost. Derived from
# food_engine.living_tag_from_lifestyle()'s existing 6-value vocabulary
# (Hostel/PG/Home/College/Office/Travel) — reused as-is, not reinvented (see
# services/food_engine.py's _LIVING_STRING_TO_TAG). The recipe dataset only
# carries two booleans (hostel_friendly/home_friendly), so several living
# tags legitimately map to the same recipe signal.
_LIVING_TAG_TO_RECIPE_PREFERENCE: dict[str, str] = {
    "Hostel": "hostel_friendly", "PG": "hostel_friendly",
    "College": "hostel_friendly", "Travel": "hostel_friendly",
    "Home": "home_friendly", "Office": "home_friendly",
}

# Minimal-equipment tokens that matter specifically for a hostel/PG/limited-
# kitchen cooking situation (item 6/15's "Quick / Minimal Equipment").
_MINIMAL_EQUIPMENT_TOKENS = ("no-cook", "kettle", "microwave", "rice cooker")

_DIFFICULTY_SCORE = {"Easy": 3.0, "Moderate": 1.0, "Hard": 0.0}


def _norm(s: str | None) -> str:
    return (s or "").strip().lower()


def _resolve_fitness_goal(raw: str) -> str:
    key = _norm(raw).replace(" ", "_")
    return _FITNESS_GOAL_DISPLAY.get(key, raw)


def _resolve_diet_type(raw: str) -> str:
    return _DIET_TYPE_ALIASES.get(_norm(raw), raw)


def _resolve_meal_type(raw: str) -> str:
    return _MEAL_TYPE_ALIASES.get(_norm(raw), raw)


def region_keywords_for_location(location: dict | None) -> tuple[str | None, list[str]]:
    """(resolved state, regional_tag keyword list) — reuses
    location_food_engine.resolve_state() (the SAME resolver
    groq_service._engine_query_context/_generate_diet_plan already use for
    the diet engine) rather than re-parsing city/state here. Returns
    (None, []) for an unresolvable or uncovered location — always a safe
    no-op for the caller."""
    state = location_food_engine.resolve_state(location)
    if not state:
        return None, []
    return state, _STATE_REGIONAL_KEYWORDS.get(state, [])


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
        difficulty: str | None = None,
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
        if difficulty:
            wanted_diff = _norm(difficulty)
            results = [r for r in results if _norm(r.get("difficulty")) == wanted_diff]
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

    def _easy_score(self, r: dict[str, Any]) -> float:
        """0..~5 — how well this recipe honours the feature's own name.
        "Get EASY ZITLAS Recipe" must not default to a technically-correct
        but fiddly 90-minute dish just because it scored well on goal/diet.
        """
        score = _DIFFICULTY_SCORE.get(r.get("difficulty"), 0.5)
        total_time = (r.get("prep_time_min") or 0) + (r.get("cook_time_min") or 0)
        # Full bonus at 0 min, none left by 30+ min — same 30-minute "quick
        # meal" cutoff the dataset's own tagging already uses elsewhere.
        score += max(0.0, (30 - total_time) / 30) * 2.0
        if r.get("cost_level") == "Budget":
            score += 0.5
        return score

    def _context_score(
        self, r: dict[str, Any], *,
        fitness_goal_display: str | None,
        recipe_preference: str | None,
        region_keywords: list[str],
    ) -> float:
        """Items 3, 4/6, 5, 7 of the recommendation priority list — every
        term is additive and optional, so a recipe with NO context signals
        at all (anonymous user, nothing resolved) still scores purely on
        _easy_score and never on an artificially deflated baseline."""
        score = 0.0
        if fitness_goal_display and fitness_goal_display in (r.get("fitness_goals") or []):
            score += 3.0
        if recipe_preference and r.get(recipe_preference):
            score += 2.0
            equipment = [_norm(e) for e in (r.get("equipment") or [])]
            if recipe_preference == "hostel_friendly" and any(
                any(tok in e for tok in _MINIMAL_EQUIPMENT_TOKENS) for e in equipment
            ):
                score += 1.0
        if region_keywords:
            tag = _norm(r.get("regional_tag"))
            if tag and any(kw in tag for kw in region_keywords):
                score += 2.5
        return score

    def recommend(
        self,
        meal_type: str | None = None,
        fitness_goal: str | None = None,
        diet_type: str | None = None,
        living_situation: str | None = None,
        hostel_friendly: bool | None = None,
        home_friendly: bool | None = None,
        location: dict | None = None,
        difficulty: str | None = None,
        max_calories: float | None = None,
        exclude_ids: "set[str] | None" = None,
        limit: int = 1,
    ) -> list[dict[str, Any]]:
        """Deterministic filtering + scoring (per spec: "Do NOT invent a
        complex AI recommendation system"), reused for both the initial
        recommendation and "Get Another Recipe".

        HARD filters, never relaxed — a wrong meal type or a diet-type
        violation is not "a worse match", it's a wrong answer:
          - meal_type  (item 2: never show a different meal's recipe)
          - diet_type  (item 9: never recommend an incompatible diet)

        Everything else is a SCORE, combined from:
          - fitness goal match           (+3.0)
          - cooking-situation match      (+2.0, plus +1.0 more for a
            hostel/PG/travel situation when the recipe also uses genuinely
            minimal equipment — no-cook/kettle/microwave/rice cooker)
          - region match                 (+2.5, via regional_tag)
          - "easy" score                 (up to ~5.5: difficulty + total
            time + budget cost — see _easy_score) — always applied, so
            "Get Easy ZITLAS Recipe" is easy by default even for a user
            with zero profile context at all.

        `hostel_friendly`/`home_friendly` passed explicitly (e.g. from an
        athlete's own filter choice on the recipe page) take priority over
        `living_situation`-derived preference; `living_situation` is the
        athlete's EXISTING assessment field (see food_engine.
        living_tag_from_lifestyle) reused as-is, not a new profile field.

        `exclude_ids` powers "Get Another Recipe" — dropped automatically
        (never silently returns the dataset's least-relevant recipe) if
        excluding would empty the meal_type+diet_type pool, e.g. a user who
        has cycled through every match for a narrow combination.

        This method serves NORMAL MEALS ONLY (breakfast/lunch/dinner/snack/
        dessert/beverage). PRE_WORKOUT/POST_WORKOUT are never routed here —
        see resolve_meal_slot() and services/workout_nutrition_service.py.
        """
        pool = self.filter(meal_type=meal_type, diet_type=diet_type, difficulty=difficulty)
        if not pool and difficulty:
            # "Easy" is a preference, not a promise the dataset can always
            # keep for every meal_type+diet_type combination — relax it
            # before ever relaxing meal_type or diet_type.
            pool = self.filter(meal_type=meal_type, diet_type=diet_type)
        if not pool:
            return []

        if exclude_ids:
            narrowed = [r for r in pool if r["id"] not in exclude_ids]
            if narrowed:
                pool = narrowed
            # else: every match has already been shown — cycle back rather
            # than return nothing (never a blank "Get Another Recipe").

        recipe_preference = None
        if hostel_friendly is True:
            recipe_preference = "hostel_friendly"
        elif home_friendly is True:
            recipe_preference = "home_friendly"
        elif living_situation:
            living_tag = food_engine.living_tag_from_lifestyle(living_situation)
            recipe_preference = _LIVING_TAG_TO_RECIPE_PREFERENCE.get(living_tag or "")
        if hostel_friendly is not None or home_friendly is not None:
            if hostel_friendly is not None:
                pool = [r for r in pool if r.get("hostel_friendly") == hostel_friendly] or pool
            if home_friendly is not None:
                pool = [r for r in pool if r.get("home_friendly") == home_friendly] or pool

        fitness_goal_display = _resolve_fitness_goal(fitness_goal) if fitness_goal else None
        _state, region_keywords = region_keywords_for_location(location) if location else (None, [])

        def _final_score(r: dict[str, Any]) -> float:
            return self._easy_score(r) + self._context_score(
                r, fitness_goal_display=fitness_goal_display,
                recipe_preference=recipe_preference, region_keywords=region_keywords,
            )

        ranked = sorted(pool, key=lambda r: (-_final_score(r), r["id"]))
        return ranked[:limit]

    def explain_recommendation(
        self, recipe: dict[str, Any], *,
        fitness_goal: str | None = None, living_situation: str | None = None,
        location: dict | None = None,
    ) -> list[str]:
        """Short, honest, data-backed reasons — the same signals recommend()
        actually scored on, never a fabricated claim. Powers the recipe
        page's "why this was recommended" section (item 4/13)."""
        reasons: list[str] = []
        if recipe.get("difficulty") == "Easy":
            reasons.append("Easy difficulty")
        total_time = (recipe.get("prep_time_min") or 0) + (recipe.get("cook_time_min") or 0)
        if total_time and total_time <= 20:
            reasons.append(f"Ready in {total_time} min")
        if fitness_goal:
            wanted_goal = _resolve_fitness_goal(fitness_goal)
            if wanted_goal in (recipe.get("fitness_goals") or []):
                reasons.append(f"Fits your {wanted_goal} goal")
        if living_situation:
            living_tag = food_engine.living_tag_from_lifestyle(living_situation)
            pref = _LIVING_TAG_TO_RECIPE_PREFERENCE.get(living_tag or "")
            if pref and recipe.get(pref):
                reasons.append("Hostel/PG friendly" if pref == "hostel_friendly" else "Easy to cook at home")
        if location:
            _state, keywords = region_keywords_for_location(location)
            tag = _norm(recipe.get("regional_tag"))
            if keywords and tag and any(kw in tag for kw in keywords):
                reasons.append(f"Popular in {_state}")
        if recipe.get("cost_level") == "Budget":
            reasons.append("Budget friendly")
        if not reasons:
            reasons.append("A well-rounded ZITLAS recipe for this meal")
        return reasons


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
