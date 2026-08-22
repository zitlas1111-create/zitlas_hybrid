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
  GET /api/recipes/for-meal       THE recipe for one SPECIFIC dish out of the
                                  athlete's diet plan, plus a video that is
                                  verified to be about that dish. Unlike
                                  /recommended (which answers "give me *a*
                                  breakfast recipe"), the dish name is the
                                  primary key here and the response is always
                                  about it or explicitly empty.
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

from fastapi import APIRouter, Depends, HTTPException, Query

from services.auth_service import verify_firebase_token

from services import (
    entitlements,
    meal_recipe_service,
    recipe_service,
    workout_nutrition_service,
)

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


@router.get("/for-meal")
async def recipe_for_meal(
    meal_name: str = Query(..., min_length=1, max_length=200,
                           description="The DISH shown on the Diet page."),
    meal_type: str | None = Query(None, description="Slot: Breakfast/Lunch/..."),
    foods: str | None = Query(None, description="Pipe-separated plan components."),
    description: str | None = Query(None, max_length=500),
    diet_type: str | None = Query(None),
    fitness_goal: str | None = Query(None),
    caller: dict = Depends(verify_firebase_token),
):
    """The recipe for the dish the athlete actually clicked.

    /recommended answers "give me a breakfast recipe" — with respect to the
    dish that is a random draw, which is the bug this endpoint exists to fix.
    Here `meal_name` is the primary key: it drives generation, the cache and
    the video query, and the returned recipe is always named after it.

    Determinism: the result is cached under the normalised dish name, so
    clicking the same meal again returns the identical recipe rather than a
    different one.
    """
    food_list = [f.strip() for f in (foods or "").split("|") if f.strip()]
    dish = meal_recipe_service.dish_from_meal(meal_name, food_list)

    print(f"[RECIPE] selected meal: {dish!r}")
    print(f"[RECIPE] meal type: {meal_type!r}")

    if not dish:
        raise HTTPException(status_code=422, detail="meal_name is required")

    # Allowance BEFORE any generation: free 7/week, premium 27/week. Checked
    # here and recorded only after a recipe actually came back, so a failed
    # generation never costs the athlete part of their week.
    #
    # AUTHENTICATION IS REQUIRED, for the same reason the swap endpoints
    # require it: this used to meter only when a token happened to arrive,
    # so a direct tokenless request got an unlimited, uncounted recipe and
    # the 7/27 limit was advisory. The browse endpoints (/recipes,
    # /recommended, /discover) stay open — they are not metered. This one is
    # the metered "Get Recipe" action, and a request with no uid cannot be
    # counted against anything.
    recipe_uid = caller.get("uid") or ""
    entitlements.require(recipe_uid, entitlements.RECIPE)

    print(f"[RECIPE] recipe query: exact-dish lookup key="
          f"{meal_recipe_service.cache_key(dish)}")

    recipe, from_cache = await meal_recipe_service.get_recipe_for_dish(
        dish, meal_type=meal_type, foods=food_list, description=description,
        diet_type=diet_type, fitness_goal=fitness_goal,
    )

    if recipe is None:
        # Nothing is metered: a request that produced no recipe must not cost
        # the athlete part of their week (entitlements.record's contract).
        raise HTTPException(
            status_code=503,
            detail={
                "message": "Could not build a recipe for this meal right now.",
                "code": "recipe_generation_failed",
                "meal_name": dish,
            },
        )

    video = meal_recipe_service.find_meal_video(
        dish, meal_type=meal_type, diet_type=diet_type,
        fitness_goal=fitness_goal,
    )

    # Metered AFTER success, and independently of whether a video was found —
    # the athlete received the recipe either way.
    uid = recipe_uid
    usage = None
    if uid:
        try:
            entitlements.record(uid, entitlements.RECIPE)
            usage = entitlements.snapshot(uid)
        except Exception as e:  # noqa: BLE001 — metering must never fail the request
            print(f"[RECIPE] usage metering skipped: {type(e).__name__}: {e}")
    print(f"[RECIPE] recipe entitlement: uid={uid or '(anonymous)'} "
          f"counted={bool(uid)} usage={usage}")

    return {
        "meal_name": dish,
        "meal_type": meal_type,
        "recipe": recipe,
        "video": video,
        # No video is a FIRST-CLASS outcome, not a failure. A clip that only
        # shows the finished dish being poured or served is worse than none —
        # it misleads about what the athlete is supposed to do.
        "video_note": None if video else "Recipe video coming soon.",
        "cached": from_cache,
        "usage": usage,
    }


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
