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
        zitlas_original=zitlas_original, max_calories=max_calories,
        min_protein=min_protein, q=q,
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
    hostel_friendly: bool | None = None,
    max_calories: float | None = None,
    limit: int = 1,
) -> dict:
    """Deterministic filtering/scoring (per spec: not an AI recommender).
    Matches meal_type + fitness_goal + diet_type where possible; diet_type
    is the one hard constraint that is never relaxed (never suggest a
    non-vegetarian recipe to a vegetarian just because nothing else
    matched). Falls back gracefully — see RecipeService.recommend's
    docstring for the exact relaxation order. Returns an empty list, never
    a 404/500, when even the diet-type-only pool is empty."""
    svc = recipe_service.get_service()
    limit = max(1, min(limit, 20))
    results = svc.recommend(
        meal_type=meal_type, fitness_goal=fitness_goal, diet_type=diet_type,
        hostel_friendly=hostel_friendly, max_calories=max_calories, limit=limit,
    )
    return {"count": len(results), "recipes": results}


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
