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

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from services.auth_service import verify_firebase_token

from services import (
    entitlements,
    food_engine,
    groq_service,
    location_food_engine,
    workout_nutrition_service,
)

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
    # Pre-workout only, and only when the athlete actually told us. ZITLAS
    # stores no workout start time, so this is never inferred — omitted
    # means "use the service's stated default assumption".
    minutes_until_workout: int | None = Field(default=None, ge=0, le=360)


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


def _workout_swap_options(
    *, slot: str, diet_tags: list[str], living_tag: str | None,
    user_state: str | None, exclude_names: list[str],
    minutes_until_workout: int | None, limit: int,
) -> list[dict[str, Any]]:
    """Swap alternatives for a Pre-/Post-Workout meal, drawn ONLY from the
    workout-nutrition dataset.

    Same response shape as the engine path below, built directly from the
    dataset rather than through `_combo_macros`/`format_food_line`/
    `describe_swap` — those read food-engine field names this dataset
    deliberately does not carry."""
    svc = workout_nutrition_service.get_service()
    # Swap history is by NAME; the service excludes by id. Map across so
    # "give me another" genuinely advances instead of repeating.
    seen = {n.strip().lower() for n in exclude_names if n}
    exclude_ids = {
        i["id"] for i in svc.items
        if i["name"].strip().lower() in seen
        or any(i["name"].strip().lower() in n for n in seen)
    }
    results = svc.recommend(
        meal_slot=slot,
        diet_type=diet_tags[0] if diet_tags else None,
        living_situation=living_tag,
        location={"state": user_state} if user_state else None,
        exclude_ids=exclude_ids or None,
        minutes_until_workout=minutes_until_workout,
        limit=limit,
    )

    options: list[dict[str, Any]] = []
    for item in results:
        n = item.get("nutrition_estimated") or {}
        options.append({
            "name": item["name"],
            "foods": list(item.get("ingredients") or []),
            "food_ids": [item["id"]],
            "calories": round(n.get("calories_kcal") or 0),
            "protein_g": round(n.get("protein_g") or 0, 1),
            "carbs_g": round(n.get("carbs_g") or 0, 1),
            "fat_g": round(n.get("fat_g") or 0, 1),
            "reason": ". ".join(
                svc.explain(item, meal_slot=slot, minutes_until_workout=minutes_until_workout)
            ) + ".",
            "availability": (
                f"Common in {user_state}"
                if user_state and item.get("regional_tag")
                else "Available across India"
            ),
            "budget_level": {"Budget": "Economy", "Moderate": "Standard"}.get(
                item.get("cost_level", "Budget"), "Standard"
            ),
            "high_protein": (n.get("protein_g") or 0) >= 15,
            "high_fiber": (n.get("fiber_g") or 0) >= 5,
            "quality_labels": [
                label for label in (
                    "Quick energy" if slot == "pre_workout" else "Recovery focused",
                    "Very easy to digest" if item.get("digestibility") == "very_easy" else None,
                    "No cooking" if (item.get("total_time_min") or 0) == 0 else None,
                ) if label
            ],
        })
    return options


@router.post("/swap")
async def deterministic_swap(
    body: SwapRequest,
    caller: dict = Depends(verify_firebase_token),
) -> dict[str, Any]:
    started = time.perf_counter()

    # ── Meal-swap allowance ──────────────────────────────────────────────
    # Checked BEFORE any work and recorded only after a successful response,
    # so a swap that errors never costs the athlete part of their week.
    #
    # Premium is unlimited: limits_for(premium)[meal_swap] is None, and
    # Allowance.allowed short-circuits on `unlimited` without ever comparing
    # a count. There is no premium number to exceed — not 70, not 500.
    #
    # AUTHENTICATION IS REQUIRED. This endpoint used to accept an optional
    # token and simply skip metering when none arrived — which meant an
    # unauthenticated POST got an unlimited, unmetered swap. Verified against
    # production: a tokenless request returned HTTP 200 and a real swap, so
    # the 70/week free limit was bypassable by anyone.
    swap_uid = caller.get("uid") or ""
    entitlements.require(swap_uid, entitlements.MEAL_SWAP)

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

    # ── WORKOUT SLOTS NEVER REACH THE FOOD ENGINE ──────────────────────
    # A Pre-/Post-Workout meal is not a normal meal and the engine has no
    # slot for one: `_meal_slot_from_name` falls through to
    # `evening_snack`, whose pool is full of normal meals — which is
    # exactly why swapping a Pre-Workout meal returned "Moong Dal Chilla"
    # and "Grilled Paneer Salad". Served from the dedicated
    # workout-nutrition dataset instead, matching what
    # GET /api/recipes/recommended already does for the same two slots.
    workout_slot = groq_service.workout_slot_from_name(body.meal_name)
    if workout_slot is not None:
        options = _workout_swap_options(
            slot=workout_slot,
            diet_tags=diet_tags,
            living_tag=ctx.get("living_tag"),
            user_state=ctx.get("user_state"),
            exclude_names=exclude_names,
            minutes_until_workout=body.minutes_until_workout,
            limit=body.options,
        )
        elapsed_ms = (time.perf_counter() - started) * 1000
        print(f"[SWAP] workout-nutrition ({workout_slot}): {len(options)} options "
              f"in {elapsed_ms:.1f}ms")
        if swap_uid:
            entitlements.record(swap_uid, entitlements.MEAL_SWAP)
        return {
            "module": "workout_nutrition_swap",
            "options": options,
            "current": None,
            "relaxed_match": False,
            "match_note": (
                "Quick energy before training" if workout_slot == "pre_workout"
                else "Recovery-focused nutrition after training"
            ),
            "elapsed_ms": round(elapsed_ms, 1),
            "llm_used": False,
        }

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

    # Recorded here, not at the gate: the athlete has now actually received
    # options. Premium still records (useful for analytics) but was never
    # blocked, because its limit is None.
    if swap_uid:
        entitlements.record(swap_uid, entitlements.MEAL_SWAP)

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
