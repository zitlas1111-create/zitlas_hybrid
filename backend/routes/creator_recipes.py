"""
ZITLAS — Creator Recipe routes (backend/routes/creator_recipes.py)

  GET /api/creator-recipes/recommended    ranked YouTube creator videos
  GET /api/creator-recipes/channel/{id}   one creator's public channel info

A SEPARATE content source from /api/recipes (ZITLAS's own 637 recipes) and
from /api/recipes?meal_type=pre_workout|post_workout (the curated workout
nutrition dataset). Nothing here touches either.

WORKOUT SLOTS ARE REFUSED OUTRIGHT. Pre-/post-workout nutrition is a
purpose-built, deterministic recommendation (services/workout_nutrition_service.py)
that exists precisely because generic "healthy food" content is the wrong
answer minutes before or after training. Routing those slots into an open
YouTube search would undo that, so this router rejects them with a specific
error rather than quietly returning something plausible.

The YouTube API key never leaves the backend: it is read from the
environment inside services/youtube_recipe_service.py and appears in no
response, no log line, and no exception message on this path.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from services import recipe_service, youtube_recipe_service
from services.youtube_recipe_service import YouTubeQuotaExceeded, YouTubeUnavailable

router = APIRouter()


@router.get("/health")
async def creator_recipes_health() -> dict:
    """Readiness only — reports WHETHER a key is configured, never any part
    of the key itself."""
    return {
        "module": "creator_recipes",
        "status": "ready" if youtube_recipe_service.is_configured() else "not_configured",
        "provider": "youtube",
    }


@router.get("/recommended")
async def recommended_creator_recipe(
    food: str,
    meal_type: str | None = None,
    fitness_goal: str | None = None,
    diet_type: str | None = None,
    living_situation: str | None = None,
    region: str | None = None,
    favorite_foods: str | None = None,
    exclude_ids: str | None = None,
    limit: int = 5,
) -> dict:
    """Creator videos for the food the athlete is about to eat.

    `food` is required and drives relevance — the athlete's saved
    `favorite_foods` personalise WHICH foods appear in their plan (via the
    existing food engine), they do not replace the meal in front of them.

    `exclude_ids` powers "See Another Recipe". Exclusion happens against the
    CACHED result list rather than by re-searching, so cycling through
    creators costs no additional YouTube quota.
    """
    slot = recipe_service.resolve_meal_slot(meal_type)
    if slot is not None:
        raise HTTPException(
            status_code=400,
            detail="workout_slot_not_supported",
        )

    if not (food or "").strip():
        raise HTTPException(status_code=400, detail="food_required")

    if not youtube_recipe_service.is_configured():
        raise HTTPException(status_code=503, detail="creator_recipes_not_configured")

    limit = max(1, min(limit, 10))
    excluded = {x.strip() for x in (exclude_ids or "").split(",") if x.strip()}

    try:
        results = youtube_recipe_service.find_creator_recipes(
            food=food,
            fitness_goal=fitness_goal,
            diet_type=diet_type,
            meal_type=meal_type,
            living_situation=living_situation,
            region=region,
            favorite_foods=[f.strip() for f in (favorite_foods or "").split(",") if f.strip()],
            limit=50,
        )
    except YouTubeQuotaExceeded:
        # 429 so the client can say "try later" and, critically, NOT retry.
        raise HTTPException(status_code=429, detail="creator_recipes_quota") from None
    except YouTubeUnavailable:
        raise HTTPException(status_code=502, detail="creator_recipes_unavailable") from None

    fresh = [v for v in results if v["video_id"] not in excluded]
    # Every result already seen — cycle rather than show nothing, matching
    # how "Get Another Recipe" behaves for ZITLAS recipes.
    cycled = not fresh and bool(results)
    if cycled:
        fresh = results

    return {
        "count": len(fresh[:limit]),
        "videos": fresh[:limit],
        "cycled": cycled,
        "platform": "youtube",
    }


@router.get("/channel/{channel_id}")
async def creator_channel(channel_id: str) -> dict:
    """Public channel info for the Creator Profile screen.

    Only fields YouTube actually returns. Subscriber counts, ratings and
    verified badges are deliberately absent — inventing them would be a
    fabricated endorsement of someone else's channel.
    """
    if not youtube_recipe_service.is_configured():
        raise HTTPException(status_code=503, detail="creator_recipes_not_configured")
    try:
        channel = youtube_recipe_service.fetch_channel(channel_id)
    except YouTubeQuotaExceeded:
        raise HTTPException(status_code=429, detail="creator_recipes_quota") from None
    except YouTubeUnavailable:
        raise HTTPException(status_code=502, detail="creator_recipes_unavailable") from None
    if channel is None:
        raise HTTPException(status_code=404, detail="channel_not_found")
    return channel
