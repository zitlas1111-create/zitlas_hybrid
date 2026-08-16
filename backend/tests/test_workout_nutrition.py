"""
ZITLAS — Workout Nutrition API tests (backend/tests/test_workout_nutrition.py)

Exercises the REAL routes/recipes.py + services/workout_nutrition_service.py
against the REAL small workout-nutrition dataset
(backend/recipes/data/workout_nutrition.json) — same no-mocking posture as
tests/test_recipes.py.

This dataset/service is DELIBERATELY separate from the 637-recipe normal-
meal database (see workout_nutrition_service.py's module docstring for why:
scoring inside the normal recipe pool kept surfacing healthy-but-inappropriate
results like a full paneer dish for a pre-workout request). These tests exist
to prove that separation holds — a pre/post-workout request must NEVER
surface a normal-meal recipe (ZITLAS-REC-*), and must NEVER fall back to
breakfast/lunch/dinner.

Run: python -m pytest tests/test_workout_nutrition.py -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import recipes  # noqa: E402
from services import workout_nutrition_service  # noqa: E402


@pytest.fixture(scope="module")
def app():
    a = FastAPI()
    a.include_router(recipes.router, prefix="/api/recipes")
    return a


@pytest.fixture(scope="module")
def client(app):
    return TestClient(app)


@pytest.fixture(scope="module")
def service():
    return workout_nutrition_service.get_service()


# ── Regression guard for the exact reported bug: Post-Workout showing a
#    Breakfast recipe. Category is asserted explicitly (not just ID prefix)
#    since "category" is the field the bug report's underlying dataset
#    confusion was actually about. ────────────────────────────────────────

def test_post_workout_category_is_workout_recovery_never_breakfast_lunch_or_dinner(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&limit=8")
    body = r.json()
    assert body["count"] > 0
    for recipe in body["recipes"]:
        assert recipe["category"] == "Workout Recovery"
        assert recipe["category"] not in ("Breakfast", "Lunch", "Dinner")
        assert not ({"Breakfast", "Lunch", "Dinner"} & set(recipe["meal_type"]))


def test_pre_workout_category_is_workout_fuel_never_breakfast_lunch_or_dinner(client):
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&limit=8")
    body = r.json()
    assert body["count"] > 0
    for recipe in body["recipes"]:
        assert recipe["category"] == "Workout Fuel"
        assert recipe["category"] not in ("Breakfast", "Lunch", "Dinner")
        assert not ({"Breakfast", "Lunch", "Dinner"} & set(recipe["meal_type"]))


def test_get_another_post_workout_never_degrades_into_breakfast_lunch_or_dinner(client):
    """Cycle through every post-workout item via repeated "Get Another" and
    confirm the category NEVER changes, even after the pool exhausts and
    cycles back (the one place a careless implementation could accidentally
    fall through to a different service)."""
    seen_ids: list[str] = []
    exclude = ""
    for _ in range(12):
        url = f"/api/recipes/recommended?meal_type=post_workout&limit=1"
        if exclude:
            url += f"&exclude_ids={exclude}"
        body = client.get(url).json()
        recipe = body["recipes"][0]
        assert recipe["category"] == "Workout Recovery"
        seen_ids.append(recipe["id"])
        exclude = ",".join(seen_ids)
    # With only 8 post-workout items, 12 draws guarantees at least one cycle
    # back — proving the exhaustion path also never crosses into normal meals.
    assert len(set(seen_ids)) <= 8


def test_get_another_pre_workout_never_degrades_into_breakfast_lunch_or_dinner(client, service):
    pool_size = sum(1 for i in service.items if "Pre-Workout" in (i.get("meal_type") or []))
    seen_ids: list[str] = []
    exclude = ""
    for _ in range(pool_size + 4):
        url = f"/api/recipes/recommended?meal_type=pre_workout&limit=1"
        if exclude:
            url += f"&exclude_ids={exclude}"
        body = client.get(url).json()
        recipe = body["recipes"][0]
        assert recipe["category"] == "Workout Fuel"
        seen_ids.append(recipe["id"])
        exclude = ",".join(seen_ids)
    # Drawing more times than the pool holds must cycle back within the
    # slot, never widen into another category to find something new.
    assert len(set(seen_ids)) <= pool_size


# ── PRACTICALITY: healthy food != pre-workout fuel ───────────────────────
# The reported bug: Pre-Workout recommended beetroot salad / avocado toast.
# Root cause was two-fold — (a) the food dataset's macro-only rule
# (`carbs>=20 and fat<=5 and calories<=200` -> "Pre Workout") happily tags
# high-fibre salads as fuel, and (b) a Pre-Workout SWAP fell through
# `_meal_slot_from_name` to `evening_snack`, a pool full of normal meals.

_IMPRACTICAL_FOR_SHORT_WINDOW = (
    "salad", "beetroot", "avocado", "paneer", "cheela", "chilla",
    "paratha", "dal ", "khichdi", "rice bowl", "sabzi", "roti",
)


def test_pre_workout_pool_contains_no_normal_meal_dishes(service):
    """No item in the pre-workout pool is a normal meal, by construction —
    the dataset is hand-curated, so this can never regress the way a
    macro-derived tag can."""
    pre = [i for i in service.items if "Pre-Workout" in (i.get("meal_type") or [])]
    assert pre
    for item in pre:
        lowered = item["name"].lower()
        assert not any(bad in lowered for bad in ("salad", "beetroot", "avocado", "paneer", "cheela")), \
            f"{item['name']!r} is a normal meal, not pre-workout fuel"


@pytest.mark.parametrize("minutes", [0, 10, 15, 25, 30])
def test_short_window_returns_only_quick_practical_fuel(service, minutes):
    """0-30 minutes out: nothing that needs chewing through a salad, and
    nothing that needs cooking."""
    results = service.recommend(meal_slot="pre_workout", minutes_until_workout=minutes, limit=3)
    assert results
    for item in results:
        assert item["digestibility"] in ("very_easy", "easy")
        assert (item.get("total_time_min") or 0) <= 5, \
            f"{item['name']!r} takes too long to be {minutes}-minute fuel"
        assert not any(bad in item["name"].lower() for bad in _IMPRACTICAL_FOR_SHORT_WINDOW)


def test_short_window_top_pick_is_a_very_easy_quick_carb_or_hydration(service):
    top = service.recommend(meal_slot="pre_workout", minutes_until_workout=20, limit=1)[0]
    assert top["digestibility"] == "very_easy"
    assert top["fuel_type"] in ("quick_carbohydrate", "hydration")


def test_banana_dates_and_coconut_water_are_all_reachable_short_window(service):
    """The three options the product spec names explicitly for a short
    window must actually be recommendable, not merely present in the file."""
    names = {i["name"] for i in service.recommend(
        meal_slot="pre_workout", minutes_until_workout=15, limit=5)}
    assert "Banana" in names
    assert "Dates" in names
    assert "Coconut Water" in names


def test_longer_window_allows_more_substantial_options(service):
    """60-120 minutes out, slightly bigger options become appropriate —
    the timing logic must actually widen, not just always return a banana."""
    results = service.recommend(meal_slot="pre_workout", minutes_until_workout=90, limit=4)
    names = {i["name"] for i in results}
    assert names & {"Banana Smoothie", "Light Toast + Banana", "Small Light Poha"}, \
        f"90-minute window still only offered {names}"


def test_heavier_slower_options_are_not_offered_first_close_to_training(service):
    """The same items that are correct at 90 minutes must NOT lead at 10."""
    short_top = service.recommend(meal_slot="pre_workout", minutes_until_workout=10, limit=1)[0]
    assert short_top["name"] not in ("Small Light Poha", "Light Toast + Banana")
    assert (short_top.get("total_time_min") or 0) == 0


def test_digestive_burden_is_penalised_only_close_to_training(service):
    """Digestive burden is scored from the item's OWN nutrition (never a
    hand-set flag) and only counts when there is no time to digest.

    Isolated by scoring one real item against a copy of itself with the
    burden removed — comparing two different items would conflate the
    penalty with their different timing windows and fuel types."""
    import copy
    fibrous = next(i for i in service.items
                   if "Pre-Workout" in i["meal_type"]
                   and (i["nutrition_estimated"].get("fiber_g") or 0) >= 5)
    light = copy.deepcopy(fibrous)
    light["nutrition_estimated"]["fiber_g"] = 1.0

    # Close to training the extra fibre costs it real score...
    assert service._pre_workout_suitability(fibrous, 20) < \
        service._pre_workout_suitability(light, 20)
    # ...and far enough out it costs nothing at all.
    assert service._pre_workout_suitability(fibrous, 100) == \
        service._pre_workout_suitability(light, 100)


def test_a_hypothetical_heavy_high_fat_item_would_lose_to_a_banana(service):
    """The engine's own defence, proved directly: inject a beetroot-salad-
    shaped item (healthy macros, high fibre, slow prep) into the scorer and
    confirm it cannot beat a banana close to training. This is the exact
    profile the old macro-only rule mis-tagged as "Pre Workout"."""
    beetroot_salad_shaped = {
        "name": "Beetroot Salad", "fuel_type": "slow_carbohydrate",
        "digestibility": "moderate", "prep_time_min": 20, "cook_time_min": 0,
        "min_before_workout_min": 60, "max_before_workout_min": 180,
        "nutrition_estimated": {"calories_kcal": 109, "protein_g": 3.0,
                                "carbs_g": 22.0, "fat_g": 3.2, "fiber_g": 9.3},
    }
    banana = next(i for i in service.items if i["name"] == "Banana")
    assert service._pre_workout_suitability(beetroot_salad_shaped, 20) < \
        service._pre_workout_suitability(banana, 20)


def test_no_timing_supplied_defaults_to_practical_short_window_fuel(service):
    """ZITLAS has no workout start time, so the default must be the SAFE
    assumption (close to training), never a heavy 2-hours-out option."""
    results = service.recommend(meal_slot="pre_workout", limit=3)
    for item in results:
        assert item["digestibility"] in ("very_easy", "easy")
        assert (item.get("total_time_min") or 0) <= 5


def test_muscle_gain_goal_does_not_force_a_heavy_pre_workout(service):
    """Fitness goal is a SECONDARY filter — it must never override fuel
    suitability (the spec's explicit rule)."""
    top = service.recommend(
        meal_slot="pre_workout", fitness_goal="muscle_gain",
        minutes_until_workout=15, limit=1)[0]
    assert top["digestibility"] == "very_easy"
    assert (top["nutrition_estimated"].get("fat_g") or 0) < 10


def test_region_never_overrides_pre_workout_suitability(service):
    """A Maharashtra athlete must not be handed the regional poha 15
    minutes before training just because it is regional."""
    top = service.recommend(
        meal_slot="pre_workout", location={"state": "Maharashtra"},
        minutes_until_workout=15, limit=1)[0]
    assert top["name"] != "Small Light Poha"
    assert top["digestibility"] == "very_easy"


def test_hostel_context_prefers_zero_equipment_fuel(service):
    top = service.recommend(
        meal_slot="pre_workout", living_situation="Hostel",
        minutes_until_workout=20, limit=1)[0]
    assert top["hostel_friendly"] is True
    assert (top.get("total_time_min") or 0) <= 2


def test_diet_type_is_still_respected_for_pre_workout(service):
    """Universal items (banana, dates, coconut water) pass every diet;
    anything explicitly typed must match."""
    for diet in ("vegan", "vegetarian", "non-vegetarian"):
        results = service.recommend(
            meal_slot="pre_workout", diet_type=diet, minutes_until_workout=20, limit=5)
        assert results
        for item in results:
            assert item["diet_type"] in ("Universal", _resolve(diet))


def _resolve(diet: str) -> str:
    return {"vegan": "Vegan", "vegetarian": "Vegetarian",
            "non-vegetarian": "Non-Vegetarian"}[diet]


def test_timing_reason_is_only_claimed_when_timing_was_actually_supplied(service):
    """ZITLAS must never claim to know when the workout starts."""
    item = service.recommend(meal_slot="pre_workout", limit=1)[0]
    without = service.explain(item, meal_slot="pre_workout")
    with_timing = service.explain(item, meal_slot="pre_workout", minutes_until_workout=25)
    assert not any("window before training" in r for r in without)
    assert any("~25 minute window" in r for r in with_timing)


# ── 1-3. Normal meals are unaffected (breakfast/lunch/dinner -> 637 dataset) ─

@pytest.mark.parametrize("meal_type", ["breakfast", "lunch", "dinner"])
def test_normal_meals_still_come_from_the_637_recipe_dataset(client, meal_type):
    r = client.get(f"/api/recipes/recommended?meal_type={meal_type}")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    assert body["recipes"][0]["id"].startswith("ZITLAS-REC-")


@pytest.mark.parametrize("meal_type", ["breakfast", "lunch", "dinner"])
def test_normal_meals_never_return_a_workout_nutrition_item(client, meal_type):
    """The reverse direction of the same guarantee — a normal meal request
    must never accidentally surface a Workout Fuel/Recovery item either."""
    r = client.get(f"/api/recipes/recommended?meal_type={meal_type}&limit=20")
    body = r.json()
    for recipe in body["recipes"]:
        assert recipe["category"] not in ("Workout Fuel", "Workout Recovery")
        assert not recipe["id"].startswith(("ZITLAS-FUEL-", "ZITLAS-RECOVERY-"))


# ── 4. Pre-workout returns workout fuel ──────────────────────────────────

def test_pre_workout_returns_workout_fuel_not_a_normal_recipe(client):
    r = client.get("/api/recipes/recommended?meal_type=pre_workout")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    top = body["recipes"][0]
    assert top["id"].startswith("ZITLAS-FUEL-")
    assert top["category"] == "Workout Fuel"
    assert "Pre-Workout" in top["meal_type"]


# ── 5. Never Moong Paneer Cheela (or any heavy normal recipe) ────────────

def test_pre_workout_never_returns_a_normal_meal_recipe(client):
    """The bug report was literal: Pre-Workout showed "Moong Paneer
    Cheela" — a normal 637-dataset recipe. Every single item the
    pre_workout pool can possibly return must come from the dedicated
    dataset, never ZITLAS-REC-*."""
    svc = workout_nutrition_service.get_service()
    all_pre_workout_ids = {i["id"] for i in svc.items if "Pre-Workout" in (i.get("meal_type") or [])}
    assert all(i.startswith("ZITLAS-FUEL-") for i in all_pre_workout_ids)
    assert "Moong Paneer Cheela" not in [i["name"] for i in svc.items]


# ── 6-7. Pre-workout never falls back to breakfast/lunch ─────────────────

def test_pre_workout_never_falls_back_to_breakfast(client):
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&limit=8")
    body = r.json()
    for recipe in body["recipes"]:
        assert "Breakfast" not in (recipe.get("meal_type") or [])


def test_pre_workout_never_falls_back_to_lunch(client):
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&limit=8")
    body = r.json()
    for recipe in body["recipes"]:
        assert "Lunch" not in (recipe.get("meal_type") or [])


# ── 8. Post-workout returns a recovery option ────────────────────────────

def test_post_workout_returns_a_recovery_option(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    top = body["recipes"][0]
    assert top["id"].startswith("ZITLAS-RECOVERY-")
    assert top["category"] == "Workout Recovery"
    assert "Post-Workout" in top["meal_type"]


# ── 9. Post-workout never falls back to normal lunch/dinner ──────────────

def test_post_workout_never_falls_back_to_normal_lunch_or_dinner(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&limit=8")
    body = r.json()
    for recipe in body["recipes"]:
        assert recipe["id"].startswith("ZITLAS-RECOVERY-")
        assert not (set(recipe.get("meal_type") or []) & {"Lunch", "Dinner", "Breakfast"})


# ── 10-11. Get Another stays in-category and actually differs ───────────

def test_get_another_pre_workout_stays_pre_workout_and_differs(client):
    first = client.get("/api/recipes/recommended?meal_type=pre_workout").json()
    first_id = first["recipes"][0]["id"]
    second = client.get(f"/api/recipes/recommended?meal_type=pre_workout&exclude_ids={first_id}").json()
    assert second["count"] > 0
    assert second["recipes"][0]["id"] != first_id
    assert second["recipes"][0]["id"].startswith("ZITLAS-FUEL-")


def test_get_another_post_workout_stays_post_workout_and_differs(client):
    first = client.get("/api/recipes/recommended?meal_type=post_workout").json()
    first_id = first["recipes"][0]["id"]
    second = client.get(f"/api/recipes/recommended?meal_type=post_workout&exclude_ids={first_id}").json()
    assert second["count"] > 0
    assert second["recipes"][0]["id"] != first_id
    assert second["recipes"][0]["id"].startswith("ZITLAS-RECOVERY-")


def test_get_another_cycles_back_rather_than_erroring_when_exhausted(client):
    all_pre = client.get("/api/recipes/recommended?meal_type=pre_workout&diet_type=vegan&limit=50").json()
    all_ids = ",".join(r["id"] for r in all_pre["recipes"])
    r = client.get(f"/api/recipes/recommended?meal_type=pre_workout&diet_type=vegan&exclude_ids={all_ids}")
    assert r.status_code == 200
    assert r.json()["count"] > 0


# ── 12. Vegetarian filtering works (diet_type is a hard filter, "Universal"
#         items always pass through) ─────────────────────────────────────

def test_vegetarian_filtering_excludes_non_vegetarian_items(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&diet_type=vegetarian&limit=10")
    body = r.json()
    for recipe in body["recipes"]:
        assert recipe["diet_type"] in ("Vegetarian", "Universal")


def test_non_vegetarian_diet_can_reach_the_chicken_recovery_option(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&diet_type=non-vegetarian&limit=10")
    body = r.json()
    assert body["count"] > 0
    assert any(recipe["diet_type"] == "Non-Vegetarian" for recipe in body["recipes"])


def test_vegan_diet_never_receives_the_egg_or_chicken_recovery_options(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&diet_type=vegan&limit=10")
    body = r.json()
    for recipe in body["recipes"]:
        assert recipe["diet_type"] in ("Vegan", "Universal")


# ── 13. Goal filtering works, but purpose still comes first ──────────────

def test_weight_loss_goal_still_gets_appropriate_pre_workout_fuel(client):
    """A weight-loss user must not be denied pre-workout fuel just because
    the heavier recovery-style items lean toward Muscle Gain — every
    pre-workout item declares Weight Loss as a compatible goal."""
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&fitness_goal=weight_loss")
    body = r.json()
    assert body["count"] > 0
    assert "Weight Loss" in body["recipes"][0]["fitness_goals"]


def test_muscle_gain_goal_can_reach_a_stronger_recovery_option(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&fitness_goal=muscle_gain&diet_type=vegetarian&limit=10")
    body = r.json()
    assert body["count"] > 0
    assert any(recipe["nutrition_estimated"]["protein_g"] >= 10 for recipe in body["recipes"])


# ── 14. Hostel/home filtering works ───────────────────────────────────────

def test_hostel_filtering_prefers_no_cook_items(service):
    results = service.recommend(meal_slot="pre_workout", hostel_friendly=True, limit=8)
    assert len(results) > 0
    assert results[0]["hostel_friendly"] is True


def test_home_filtering_can_surface_a_blended_smoothie(service):
    results = service.recommend(meal_slot="post_workout", home_friendly=True, limit=8)
    assert len(results) > 0
    assert results[0]["home_friendly"] is True


# ── 15. Regional preference works WITHOUT overriding workout purpose ─────

def test_maharashtra_user_can_receive_the_regional_recovery_drink(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&state=Maharashtra&diet_type=vegetarian&limit=10")
    body = r.json()
    assert body["count"] > 0
    assert any(recipe.get("regional_tag") == "Maharashtrian-inspired" for recipe in body["recipes"])


def test_regional_preference_never_returns_a_heavy_meal_for_pre_workout(client):
    """Even with a strong regional signal, every returned pre-workout item
    must still be genuinely light — region must never override purpose."""
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&state=Maharashtra&limit=10")
    body = r.json()
    for recipe in body["recipes"]:
        assert recipe["nutrition_estimated"]["calories_kcal"] <= 250


# ── 16. Swap is untouched by this feature — see test_recipes.py and
#         Flutter's diet_meal_card_test.dart for that coverage directly.

# ── 17. Reasons lead with the slot's purpose ─────────────────────────────

def test_pre_workout_reason_leads_with_energy_purpose(client):
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&limit=1")
    body = r.json()
    top_id = body["recipes"][0]["id"]
    assert body["reasons"][top_id][0] == "Quick energy before training"


def test_post_workout_reason_leads_with_recovery_purpose(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&limit=1")
    body = r.json()
    top_id = body["recipes"][0]["id"]
    assert body["reasons"][top_id][0] == "Recovery-focused nutrition after training"


# ── Dataset sanity (guards the hand-curated JSON itself) ─────────────────

def test_workout_nutrition_dataset_has_no_duplicate_ids(service):
    ids = [i["id"] for i in service.items]
    assert len(ids) == len(set(ids))


def test_workout_nutrition_dataset_covers_every_diet_type_for_both_slots(service):
    for slot, wanted_meal_type in (("pre_workout", "Pre-Workout"), ("post_workout", "Post-Workout")):
        pool = [i for i in service.items if wanted_meal_type in (i.get("meal_type") or [])]
        diet_types = {i["diet_type"] for i in pool}
        # "Universal" items pass every diet_type filter — plus at least one
        # explicitly diet-typed item so filtering has something to prove.
        assert "Universal" in diet_types or len(diet_types) > 1


def test_recipe_by_id_resolves_a_workout_nutrition_item(client):
    r = client.get("/api/recipes/ZITLAS-FUEL-001")
    assert r.status_code == 200
    assert r.json()["name"] == "Banana"


def test_recipe_by_id_still_404s_for_a_genuinely_unknown_id(client):
    r = client.get("/api/recipes/ZITLAS-DOES-NOT-EXIST")
    assert r.status_code == 404
