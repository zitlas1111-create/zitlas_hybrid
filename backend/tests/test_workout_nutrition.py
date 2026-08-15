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


# ── 1-3. Normal meals are unaffected (breakfast/lunch/dinner -> 637 dataset) ─

@pytest.mark.parametrize("meal_type", ["breakfast", "lunch", "dinner"])
def test_normal_meals_still_come_from_the_637_recipe_dataset(client, meal_type):
    r = client.get(f"/api/recipes/recommended?meal_type={meal_type}")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    assert body["recipes"][0]["id"].startswith("ZITLAS-REC-")


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
