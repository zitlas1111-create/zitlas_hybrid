"""
ZITLAS — Deterministic Swap Engine (backend/routes/swap.py)

POST /api/diet/swap  →  5 ranked alternatives, no LLM, sub-10ms.

WHY THIS EXISTS: the previous swap path routed through `groq_service`, which
cost 10-12 seconds per request and let a language model author the
explanation — producing claims the data didn't support (a deep-fried bhajiya
described as "good protein and healthy carbs"). The ranking engine already
knew the right answer in ~4ms; the model was pure latency and risk on top.

Here the engine IS the source of truth. Every returned food, every number, and
every sentence is derived from the food database. Nothing is generated.
"""

from __future__ import annotations

import time
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field

from services import food_engine, groq_service, location_food_engine

router = APIRouter()


class SwapRequest(BaseModel):
    meal_name: str
    meal_time: str = Field(default="")
    current_foods: list[str] = Field(default_factory=list)
    reason: str = Field(default="")
    user_profile: dict = Field(default_factory=dict)
    lifestyle_data: dict | None = Field(default=None)
    rejected_foods: list[str] = Field(default_factory=list)
    previous_suggestions: list[list[str]] = Field(default_factory=list)
    fitness_goal: str = Field(default="general_fitness")
    # Foods already eaten today — never offered again in the same day.
    todays_foods: list[str] = Field(default_factory=list)
    options: int = Field(default=5, ge=1, le=10)


def _budget_label(food: dict) -> str:
    return {"Low": "Economy", "Medium": "Standard", "High": "Premium"}.get(
        food.get("budgetCategory", "Medium"), "Standard"
    )


def _availability_label(food: dict, user_state: str | None) -> str:
    """What the athlete actually wants to know: can I get this near me?

    Derived from the dataset's own state/region fields, never guessed.
    """
    states = food.get("available_states") or []
    if user_state and (user_state in states):
        return f"Commonly available in {user_state}"
    if food.get("pan_india") or "All" in states:
        return "Available across India"
    region = food.get("region")
    return f"Common in {region} India" if region else "Availability varies"


@router.post("/swap")
async def deterministic_swap(body: SwapRequest) -> dict[str, Any]:
    started = time.perf_counter()

    engine = food_engine.get_engine()
    ld = body.lifestyle_data or {}
    ctx = groq_service._engine_query_context(body.user_profile, ld)

    # An explicit reason ("I am vegetarian") overrides the stored diet type,
    # same rule the previous path used.
    reason_diet = groq_service._diet_type_from_reason(body.reason)
    diet_tags = (
        food_engine.diet_tags_from_lifestyle(reason_diet)
        if reason_diet
        else ctx["diet_tags"]
    )

    previous_flat = [f for opts in (body.previous_suggestions or []) for f in opts]

    # HISTORY — everything the athlete has already seen, said no to, or eaten
    # today. Excluded outright.
    exclude_names = list(
        dict.fromkeys(
            body.current_foods
            + (body.rejected_foods or [])
            + previous_flat
            + list(body.todays_foods or [])
        )
    )

    # FAMILY-level history. Exclusion by name alone never stopped khichdi
    # following khichdi, because each variant is a different name.
    recent_families: dict[str, int] = {}
    for line in exclude_names:
        if not line:
            continue
        fam = food_engine.dish_family(line)
        recent_families[fam] = recent_families.get(fam, 0) + (
            2 if line in body.current_foods else 1
        )

    target = groq_service._swap_nutrition_target(body.current_foods, engine)

    combos = engine.find_swap_combos(
        meal_slot=groq_service._meal_slot_from_name(body.meal_name, body.meal_time),
        goal_tags=ctx["goal_tags"],
        diet_tags=diet_tags,
        living_situation=ctx["living_tag"],
        budget_tier=ctx["budget_tier"],
        disease_tags=ctx["disease_tags"],
        allergens=ctx["allergens"],
        exclude_names=exclude_names,
        n_combos=body.options,
        profile=ctx["profile"],
        subgoal_tag=ctx["subgoal_tag"],
        season_tag=ctx["season_tag"],
        user_state=ctx.get("user_state"),
        compatible_regions=ctx.get("compatible_regions"),
        favorite_foods=ctx.get("favorite_foods"),
        recent_families=recent_families,
        target_calories=(target or {}).get("calories"),
        meal_preparer=ctx.get("meal_preparer"),
        disliked_foods=ctx.get("disliked_foods"),
        nutrition_target=target,
        goal_key=ctx.get("goal_key"),
    )

    tolerance = getattr(engine, "last_swap_tolerance", 1.0)
    relaxed = tolerance > 1.0

    goal_key = ctx.get("goal_key")
    options = []
    for combo in combos:
        macros = food_engine._combo_macros(combo)
        anchor = combo[0]
        # Subtle, DATA-BACKED labels only — never a health claim the numbers
        # don't support. "High fiber" is deliberately NOT repeated here —
        # it's already the dedicated `high_fiber` boolean below, same
        # contract as the pre-existing `high_protein`. "Better protein
        # match" reuses describe_swap's own >=2g threshold for "worth
        # naming"; "Similar calories" reuses its <5% threshold — both the
        # same real macros already shown, framed as a reason rather than
        # restated.
        quality_labels: list[str] = []
        if target and target.get("protein") and macros["protein"] - target["protein"] >= 2:
            quality_labels.append("Better protein match")
        if target and target.get("calories") and abs(macros["calories"] - target["calories"]) <= target["calories"] * 0.05:
            quality_labels.append("Similar calories")
        if goal_key == "transformation" and food_engine.nutrition_quality_score(anchor, goal_key="transformation") >= 0.60:
            quality_labels.append("Transformation friendly")

        options.append(
            {
                "name": " + ".join(f["name"] for f in combo),
                "foods": [food_engine.format_food_line(f) for f in combo],
                "food_ids": [f["id"] for f in combo],
                "calories": round(macros["calories"]),
                "protein_g": round(macros["protein"], 1),
                "carbs_g": round(macros["carbs"], 1),
                "fat_g": round(macros["fat"], 1),
                # Written from the numbers, not by a model.
                "reason": food_engine.describe_swap(
                    combo, target, ctx["goal_tags"], goal_label=food_engine.goal_key_label(goal_key),
                ),
                "availability": _availability_label(anchor, ctx.get("user_state")),
                "budget_level": _budget_label(anchor),
                "high_protein": bool(anchor.get("high_protein")),
                "high_fiber": bool(anchor.get("high_fiber")),
                "quality_labels": quality_labels,
            }
        )

    elapsed_ms = (time.perf_counter() - started) * 1000
    print(f"[SWAP] deterministic: {len(options)} options in {elapsed_ms:.1f}ms "
          f"(tolerance x{tolerance})")

    return {
        "module": "deterministic_swap",
        "options": options,
        "current": target,
        # HONESTY FLAG — surfaced so the app can label a widened result
        # instead of implying the standard band was met.
        "relaxed_match": relaxed,
        "match_note": (
            # "Best available match" rather than "Closest available
            # NUTRITIONAL match" — the old wording implied macro-closeness
            # was the reason it was offered even when the pool's top-ranked
            # candidate cleared the health-quality gate easily and was
            # offered mainly because nothing else passed the calorie band.
            # This still only fires when the band genuinely had to widen
            # (`relaxed`) — never a claim the ranking itself doesn't back.
            "Best available match"
            if relaxed
            else "Within your usual nutrition range"
        ),
        "elapsed_ms": round(elapsed_ms, 1),
        "llm_used": False,
    }
