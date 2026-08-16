"""
ZITLAS — Recipe Routes (backend/routes/recipes.py)

Read-only, deterministic access to the canonical recipe dataset
(backend/recipes/data/zitlas_recipes.json, served via services/recipe_service.py)
for NORMAL MEALS, and to the small dedicated workout-nutrition dataset
(backend/recipes/data/workout_nutrition.json, served via
services/workout_nutrition_service.py) for the PRE_WORKOUT/POST_WORKOUT
slots. No LLM, no writes — same posture as routes/swap.py's deterministic
engine and routes/diet.py's /foods/search.

  GET /api/recipes/health        readiness probe (same convention as every
                                  other router)
  GET /api/recipes                list/filter — meal_type, category,
                                  fitness_goal, diet_type, regional_tag,
                                  hostel_friendly, home_friendly,
                                  zitlas_original, max_calories, min_protein, q
                                  — NORMAL MEALS ONLY (the 637-recipe dataset)
  GET /api/recipes/recommended    meal_type + fitness_goal + diet_type (+diet
                                  ANDed as a hard filter, everything else
                                  progressively relaxed) -> best available
                                  match. `meal_type=pre_workout`/`post_workout`
                                  is dispatched ENTIRELY to
                                  workout_nutrition_service instead — see
                                  recipe_service.resolve_meal_slot(). Normal
                                  meal recommendation NEVER touches the
                                  workout-nutrition dataset and vice versa.
  GET /api/recipes/discover       a random sample, same filters as the list
                                  endpoint — NORMAL MEALS ONLY
  GET /api/recipes/{recipe_id}    one full recipe by ID (checks the normal
                                  dataset first, then the workout-nutrition
                                  one)

IMPORTANT: the {recipe_id} route is registered LAST — FastAPI matches routes
in declaration order, so a literal /recommended or /discover path would
otherwise be swallowed by {recipe_id} and 200 with "recipe not found" instead
of ever reaching the real handler.
"""

from __future__ import annotations

import random

from fastapi import APIRouter, HTTPException

from services import recipe_service, workout_nutrition_service

router = APIRouter()


@router.get("/health")
async def recipes_health():
    svc = recipe_service.get_service()
    return {"module": "recipes", "status": "ready", "count": len(svc.recipes)}


@router.get("")
async def list_recipes(
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
    limit: int = 50,
    offset: int = 0,
) -> dict:
    """Every filter is optional and ANDed — e.g. `?meal_type=breakfast`,
    `?meal_type=lunch&diet_type=vegetarian`, `?fitness_goal=weight_loss`.
    An empty match is a normal 200 with `recipes: []`, never an error."""
    svc = recipe_service.get_service()
    results = svc.filter(
        meal_type=meal_type, category=category, fitness_goal=fitness_goal,
        diet_type=diet_type, regional_tag=regional_tag,
        hostel_friendly=hostel_friendly, home_friendly=home_friendly,
        zitlas_original=zitlas_original, difficulty=difficulty,
        max_calories=max_calories, min_protein=min_protein, q=q,
    )
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    page = results[offset:offset + limit]
    return {"total": len(results), "count": len(page), "offset": offset, "recipes": page}


@router.get("/recommended")
async def recommended_recipe(
    meal_type: str | None = None,
    fitness_goal: str | None = None,
    diet_type: str | None = None,
    living_situation: str | None = None,
    hostel_friendly: bool | None = None,
    home_friendly: bool | None = None,
    city: str | None = None,
    state: str | None = None,
    difficulty: str | None = None,
    max_calories: float | None = None,
    exclude_ids: str | None = None,
    minutes_until_workout: int | None = None,
    limit: int = 1,
) -> dict:
    """"Get Easy ZITLAS Recipe" — deterministic filtering/scoring (per spec:
    not an AI recommender). meal_type + diet_type are hard filters (never
    relaxed — item 2/9); fitness_goal, living_situation (the athlete's
    EXISTING assessment field, see food_engine.living_tag_from_lifestyle —
    not a new profile field), city/state (resolved via the SAME
    location_food_engine.resolve_state the diet engine already uses) and
    "easy"-ness (difficulty/time/cost) are scored. See RecipeService.
    recommend()'s docstring for the exact weighting. Returns an empty list,
    never a 404/500, when even the meal_type+diet_type pool is empty.

    `meal_type=pre_workout`/`post_workout` are SLOTS, never a literal
    dataset meal_type — see recipe_service.resolve_meal_slot(). They are
    dispatched to workout_nutrition_service.recommend() ENTIRELY instead of
    this module's recipe_service.recommend(): the 637-recipe normal-meal
    database is never searched for these two slots, and there is no
    "closest meal type" fallback to breakfast/lunch/dinner if the workout
    dataset can't fully satisfy every filter.

    `exclude_ids` is a comma-separated list of recipe IDs already shown —
    powers "Get Another Recipe" without repeating (a single id works too,
    e.g. `exclude_ids=ZITLAS-REC-0521`)."""
    limit = max(1, min(limit, 20))
    location = {"city": city, "state": state} if (city or state) else None
    exclude_set = {x.strip() for x in exclude_ids.split(",") if x.strip()} if exclude_ids else None
    meal_slot = recipe_service.resolve_meal_slot(meal_type)

    if meal_slot is not None:
        wsvc = workout_nutrition_service.get_service()
        results = wsvc.recommend(
            meal_slot=meal_slot, fitness_goal=fitness_goal, diet_type=diet_type,
            living_situation=living_situation, hostel_friendly=hostel_friendly,
            home_friendly=home_friendly, location=location, exclude_ids=exclude_set,
            minutes_until_workout=minutes_until_workout, limit=limit,
        )
        reasons_by_id = {
            r["id"]: wsvc.explain(
                r, meal_slot=meal_slot, minutes_until_workout=minutes_until_workout,
            )
            for r in results
        }
        return {"count": len(results), "recipes": results, "reasons": reasons_by_id}

    svc = recipe_service.get_service()
    results = svc.recommend(
        meal_type=meal_type, fitness_goal=fitness_goal, diet_type=diet_type,
        living_situation=living_situation, hostel_friendly=hostel_friendly,
        home_friendly=home_friendly, location=location, difficulty=difficulty,
        max_calories=max_calories, exclude_ids=exclude_set, limit=limit,
    )
    reasons_by_id = {
        r["id"]: svc.explain_recommendation(
            r, fitness_goal=fitness_goal, living_situation=living_situation, location=location,
        )
        for r in results
    }
    return {"count": len(results), "recipes": results, "reasons": reasons_by_id}


@router.get("/discover")
async def discover_recipes(
    meal_type: str | None = None,
    category: str | None = None,
    fitness_goal: str | None = None,
    diet_type: str | None = None,
    hostel_friendly: bool | None = None,
    limit: int = 5,
) -> dict:
    """A random sample from the filtered pool — simple discovery, no
    scoring. Same optional/ANDed filters as the list endpoint."""
    svc = recipe_service.get_service()
    pool = svc.filter(
        meal_type=meal_type, category=category, fitness_goal=fitness_goal,
        diet_type=diet_type, hostel_friendly=hostel_friendly,
    )
    limit = max(1, min(limit, 50))
    sample = random.sample(pool, k=min(limit, len(pool))) if pool else []
    return {"count": len(sample), "recipes": sample}


@router.get("/{recipe_id}")
async def get_recipe(recipe_id: str) -> dict:
    svc = recipe_service.get_service()
    recipe = svc.get_by_id(recipe_id)
    if recipe is None:
        # Not in the normal 637-recipe dataset — try the small workout-
        # nutrition one before giving up (its IDs use a distinct
        # ZITLAS-FUEL-*/ZITLAS-RECOVERY-* prefix, so there's no collision).
        recipe = workout_nutrition_service.get_service().get_by_id(recipe_id)
    if recipe is None:
        raise HTTPException(status_code=404, detail="recipe_not_found")
    return recipe
