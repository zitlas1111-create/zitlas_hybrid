"""
ZITLAS — Recipe Routes (backend/routes/recipes.py)

Read-only, deterministic access to the canonical recipe dataset
(backend/recipes/data/zitlas_recipes.json, served via services/recipe_service.py).
No LLM, no writes — same posture as routes/swap.py's deterministic engine and
routes/diet.py's /foods/search.

  GET /api/recipes/health        readiness probe (same convention as every
                                  other router)
  GET /api/recipes                list/filter — meal_type, category,
                                  fitness_goal, diet_type, regional_tag,
                                  hostel_friendly, home_friendly,
                                  zitlas_original, max_calories, min_protein, q
  GET /api/recipes/recommended    meal_type + fitness_goal + diet_type (+diet
                                  ANDed as a hard filter, everything else
                                  progressively relaxed) -> best available match
  GET /api/recipes/discover       a random sample, same filters as the list
                                  endpoint
  GET /api/recipes/{recipe_id}    one full recipe by ID

IMPORTANT: the {recipe_id} route is registered LAST — FastAPI matches routes
in declaration order, so a literal /recommended or /discover path would
otherwise be swallowed by {recipe_id} and 200 with "recipe not found" instead
of ever reaching the real handler.
"""

from __future__ import annotations

import random

from fastapi import APIRouter, HTTPException

from services import recipe_service

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

    `meal_type` also accepts the two workout SLOTS — "pre_workout" and
    "post_workout" — which are never a literal dataset meal_type; see
    RecipeService.resolve_meal_slot()/recommend() for how each is served
    (recovery/energy purpose-scoring, not a "closest meal type" fallback).

    `exclude_ids` is a comma-separated list of recipe IDs already shown —
    powers "Get Another Recipe" without repeating (a single id works too,
    e.g. `exclude_ids=ZITLAS-REC-0521`)."""
    svc = recipe_service.get_service()
    limit = max(1, min(limit, 20))
    location = {"city": city, "state": state} if (city or state) else None
    exclude_set = {x.strip() for x in exclude_ids.split(",") if x.strip()} if exclude_ids else None
    results = svc.recommend(
        meal_type=meal_type, fitness_goal=fitness_goal, diet_type=diet_type,
        living_situation=living_situation, hostel_friendly=hostel_friendly,
        home_friendly=home_friendly, location=location, difficulty=difficulty,
        max_calories=max_calories, exclude_ids=exclude_set, limit=limit,
    )
    meal_slot = recipe_service.resolve_meal_slot(meal_type)
    reasons_by_id = {
        r["id"]: svc.explain_recommendation(
            r, fitness_goal=fitness_goal, living_situation=living_situation, location=location,
            meal_slot=meal_slot,
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
        raise HTTPException(status_code=404, detail="recipe_not_found")
    return recipe
