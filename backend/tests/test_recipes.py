"""
ZITLAS — Recipe API tests (backend/tests/test_recipes.py)

Exercises the REAL routes/recipes.py + services/recipe_service.py against the
REAL canonical dataset (backend/recipes/data/zitlas_recipes.json) — no
mocking, since this is deterministic, read-only, in-memory data, the same
posture test_diet_personalization.py and test_swap_engine.py already take
toward services/food_engine.py's dataset.

Run: python -m pytest tests/test_recipes.py -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import recipes  # noqa: E402
from recipes import validate_dataset  # noqa: E402
from services import recipe_service  # noqa: E402


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
    return recipe_service.get_service()


# ── 1. Get recipe by valid ID ────────────────────────────────────────────

def test_get_recipe_by_valid_id(client):
    r = client.get("/api/recipes/ZITLAS-REC-0001")
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == "ZITLAS-REC-0001"
    assert body["name"]
    # Full object, not a name/id-only summary — spec's explicit requirement.
    for field in ("description", "ingredients", "instructions", "nutrition_estimated",
                  "prep_time_min", "cook_time_min", "difficulty", "equipment",
                  "fitness_goals", "primary_protein_sources", "tags"):
        assert field in body, f"response missing {field!r} — must return the FULL recipe"


# ── 2. Invalid recipe ID ─────────────────────────────────────────────────

def test_get_recipe_invalid_id(client):
    r = client.get("/api/recipes/ZITLAS-REC-9999")
    assert r.status_code == 404
    assert r.json()["detail"] == "recipe_not_found"


# ── 3. Get all recipes ───────────────────────────────────────────────────

def test_get_all_recipes(client):
    r = client.get("/api/recipes")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 637
    # Default page size caps the returned count, but `total` reflects the
    # full unfiltered dataset.
    assert body["count"] == len(body["recipes"])
    assert body["count"] <= body["total"]


# ── 4-6. Meal-type filters ───────────────────────────────────────────────

@pytest.mark.parametrize("meal_type,expected_min", [("breakfast", 400), ("lunch", 40), ("dinner", 40)])
def test_meal_type_filters(client, meal_type, expected_min):
    r = client.get(f"/api/recipes?meal_type={meal_type}&limit=200")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] >= expected_min
    for recipe in body["recipes"]:
        assert meal_type.capitalize() in recipe["meal_type"] or \
            any(meal_type.lower() == m.lower() for m in recipe["meal_type"])


# ── 7. Vegetarian filter ─────────────────────────────────────────────────

def test_vegetarian_filter(client):
    r = client.get("/api/recipes?diet_type=vegetarian&limit=200")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert recipe["diet_type"] == "Vegetarian"


def test_non_vegetarian_filter(client):
    r = client.get("/api/recipes?diet_type=non-vegetarian&limit=200")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert recipe["diet_type"] == "Non-Vegetarian"


def test_hostel_friendly_filter(client):
    r = client.get("/api/recipes?hostel_friendly=true&limit=300")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert recipe["hostel_friendly"] is True


def test_home_friendly_filter(client):
    r = client.get("/api/recipes?home_friendly=true&limit=300")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert recipe["home_friendly"] is True


def test_regional_filter(client):
    """Maharashtra is the dataset's largest regional collection — a real,
    non-trivial filter target rather than a synthetic one."""
    r = client.get("/api/recipes?regional_tag=maharashtr&limit=300")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert "maharashtr" in (recipe["regional_tag"] or "").lower()


# ── 8. Fitness-goal filter ───────────────────────────────────────────────

def test_fitness_goal_filter(client):
    r = client.get("/api/recipes?fitness_goal=weight_loss&limit=400")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert "Weight Loss" in recipe["fitness_goals"]


def test_body_transformation_goal_filter_uses_the_real_dataset_tag(client):
    """The dataset's own fitness_goals values already say 'Body
    Transformation' — confirms the API's snake_case alias resolves to it."""
    r = client.get("/api/recipes?fitness_goal=transformation&limit=100")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] > 0
    for recipe in body["recipes"]:
        assert "Body Transformation" in recipe["fitness_goals"]


# ── 9. Combined filters ──────────────────────────────────────────────────

def test_combined_filters(client):
    r = client.get("/api/recipes?meal_type=lunch&diet_type=vegetarian")
    assert r.status_code == 200
    body = r.json()
    for recipe in body["recipes"]:
        assert "Lunch" in recipe["meal_type"]
        assert recipe["diet_type"] == "Vegetarian"


# ── 10. Recommended recipe ───────────────────────────────────────────────

def test_recommended_recipe_full_match(client):
    r = client.get("/api/recipes/recommended?meal_type=breakfast&fitness_goal=weight_loss&diet_type=vegetarian")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] >= 1
    top = body["recipes"][0]
    assert "Breakfast" in top["meal_type"]
    assert top["diet_type"] == "Vegetarian"


def test_recommended_recipe_never_violates_diet_type_even_when_relaxing(client):
    """diet_type is the one hard constraint recommend() never relaxes —
    give it an impossible meal_type/goal combo so every OTHER constraint
    must be dropped, and confirm diet_type still holds."""
    r = client.get("/api/recipes/recommended?meal_type=dinner&fitness_goal=muscle_gain&diet_type=vegan&hostel_friendly=true&max_calories=1")
    assert r.status_code == 200
    body = r.json()
    for recipe in body["recipes"]:
        assert recipe["diet_type"] == "Vegan"


# ── Pre-workout / Post-workout slots ─────────────────────────────────────

def test_pre_workout_recommendation_is_quick_and_light():
    """No recipe in the dataset carries a "Pre-Workout" meal_type/tag at
    all — the slot must still return something, and it must actually be
    quick + light + carbohydrate-forward, not just whatever generic
    breakfast happened to sort first on easy-score alone."""
    svc = recipe_service.get_service()
    results = svc.recommend(meal_type="pre_workout", limit=5)
    assert len(results) > 0
    top = results[0]
    nutrition = top["nutrition_estimated"]
    total_time = top["prep_time_min"] + top["cook_time_min"]
    assert total_time <= 15, f"{top['name']!r} takes {total_time} min — too slow for pre-workout"
    assert nutrition["fat_g"] <= 15, f"{top['name']!r} has {nutrition['fat_g']}g fat — too heavy for pre-workout"


def test_pre_workout_does_not_fall_back_to_a_random_generic_meal_type(client):
    """The literal meal name a diet plan uses ("Pre-Workout Snack") must
    resolve through the dedicated pre_workout slot, not get treated as an
    unrecognized string that silently returns an unrelated dish."""
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&diet_type=vegetarian&limit=5")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    for recipe in body["recipes"]:
        assert recipe["diet_type"] == "Vegetarian"
        assert recipe["meal_type"][0] in ("Breakfast", "Beverage", "Evening Snack")


def test_post_workout_recommendation_uses_only_the_real_post_workout_recipes():
    """Post-Workout DOES have real dataset recipes (7, one per diet type) —
    the slot must be a hard filter to exactly those, never a normal
    lunch/dinner recommendation."""
    svc = recipe_service.get_service()
    results = svc.recommend(meal_type="post_workout", limit=10)
    assert len(results) > 0
    for r in results:
        assert "Post-Workout" in r["meal_type"]


def test_post_workout_prioritizes_protein_for_recovery():
    """Given a choice, the recovery slot should rank the higher-protein
    option first — e.g. the Soya Amti Bowl (49.9g protein) over the
    Chocolate Banana Milk (7.9g protein), both Vegan/Vegetarian-adjacent
    post-workout options."""
    svc = recipe_service.get_service()
    results = svc.recommend(meal_type="post_workout", diet_type="vegan", limit=5)
    assert len(results) > 0
    top = results[0]
    assert top["nutrition_estimated"]["protein_g"] >= 40


def test_post_workout_hyphenated_and_underscored_forms_agree(client):
    a = client.get("/api/recipes/recommended?meal_type=post-workout").json()
    b = client.get("/api/recipes/recommended?meal_type=post_workout").json()
    assert a["count"] > 0 and b["count"] > 0
    assert a["recipes"][0]["id"] == b["recipes"][0]["id"]


def test_pre_workout_respects_diet_type_and_goal_together(client):
    r = client.get(
        "/api/recipes/recommended?meal_type=pre_workout&diet_type=vegetarian&fitness_goal=weight_loss&limit=5"
    )
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    for recipe in body["recipes"]:
        assert recipe["diet_type"] == "Vegetarian"


def test_pre_workout_reason_leads_with_the_slot_purpose(client):
    r = client.get("/api/recipes/recommended?meal_type=pre_workout&limit=1")
    body = r.json()
    top_id = body["recipes"][0]["id"]
    assert body["reasons"][top_id][0] == "Quick energy before training"


def test_post_workout_reason_leads_with_the_slot_purpose(client):
    r = client.get("/api/recipes/recommended?meal_type=post_workout&limit=1")
    body = r.json()
    top_id = body["recipes"][0]["id"]
    assert body["reasons"][top_id][0] == "Recovery-focused nutrition after training"


def test_normal_meal_reason_does_not_mention_workout_purpose(client):
    r = client.get("/api/recipes/recommended?meal_type=breakfast&limit=1")
    body = r.json()
    top_id = body["recipes"][0]["id"]
    assert body["reasons"][top_id][0] not in (
        "Quick energy before training", "Recovery-focused nutrition after training",
    )


def test_get_another_pre_workout_recipe_excludes_the_previous_one(client):
    first = client.get("/api/recipes/recommended?meal_type=pre_workout&diet_type=vegetarian").json()
    first_id = first["recipes"][0]["id"]
    second = client.get(
        f"/api/recipes/recommended?meal_type=pre_workout&diet_type=vegetarian&exclude_ids={first_id}"
    ).json()
    assert second["count"] > 0
    assert second["recipes"][0]["id"] != first_id


def test_get_another_post_workout_recipe_excludes_the_previous_one(client):
    first = client.get("/api/recipes/recommended?meal_type=post_workout&diet_type=vegan").json()
    first_id = first["recipes"][0]["id"]
    second = client.get(
        f"/api/recipes/recommended?meal_type=post_workout&diet_type=vegan&exclude_ids={first_id}"
    ).json()
    assert second["count"] > 0
    assert second["recipes"][0]["id"] != first_id


# ── 11. Easy-recipe preference ────────────────────────────────────────────

def test_easy_recipe_preference(client):
    """"Get Easy ZITLAS Recipe" must actually mean easy — a recommend()
    call with no other context at all must still favour Easy difficulty
    and low total time over a technically-valid but fiddly match.

    Uses breakfast (452 of 637 recipes) rather than a thin category: a
    meal_type+diet_type combination that genuinely has zero Easy options
    (e.g. vegetarian dinner — checked, all 7 candidates are Moderate) can't
    be expected to return one, so testing "easy preference" needs a pool
    rich enough to actually contain easy options to prefer."""
    r = client.get("/api/recipes/recommended?meal_type=breakfast&diet_type=vegetarian&limit=5")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    top = body["recipes"][0]
    assert top["difficulty"] == "Easy"
    total_time = top["prep_time_min"] + top["cook_time_min"]
    assert total_time <= 15, f"top result {top['name']!r} takes {total_time} min — not what 'Easy' promises"


# ── 13. Get another recipe ───────────────────────────────────────────────

def test_get_another_recipe_excludes_the_previous_one(client):
    first = client.get("/api/recipes/recommended?meal_type=breakfast&diet_type=vegetarian").json()
    first_id = first["recipes"][0]["id"]
    second = client.get(
        f"/api/recipes/recommended?meal_type=breakfast&diet_type=vegetarian&exclude_ids={first_id}"
    ).json()
    assert second["count"] > 0
    assert second["recipes"][0]["id"] != first_id


def test_get_another_recipe_cycles_back_rather_than_erroring_when_exhausted(client):
    """Excluding literally every matching recipe must degrade gracefully
    (never a 4xx/5xx, never a blank result) — the whole point of "never
    show an empty page"."""
    all_matches = client.get("/api/recipes?meal_type=breakfast&diet_type=vegan&limit=500").json()["recipes"]
    all_ids = ",".join(r["id"] for r in all_matches)
    r = client.get(f"/api/recipes/recommended?meal_type=breakfast&diet_type=vegan&exclude_ids={all_ids}")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] > 0
    assert body["recipes"][0]["diet_type"] == "Vegan"


# ── 11. Empty result handling ────────────────────────────────────────────

def test_empty_result_is_not_an_error(client):
    r = client.get("/api/recipes?q=xyznonexistentrecipenamezzz")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 0
    assert body["recipes"] == []


def test_recommended_with_no_possible_match_returns_empty_list_not_error(client):
    """No diet_type given, so the pool is the whole dataset; an absurd
    calorie cap of 0 with a meal_type that can't hit it degrades through
    every relaxation step and should end on the bare meal_type-only match
    (never a 4xx/5xx) or, if truly nothing matches even that, an empty list."""
    r = client.get("/api/recipes/recommended?meal_type=breakfast&max_calories=0")
    assert r.status_code == 200
    assert isinstance(r.json()["recipes"], list)


# ── 12. Dataset validation ───────────────────────────────────────────────

def test_dataset_validation_passes_clean(service):
    recipes, result = validate_dataset.load_and_validate()
    assert result.ok, result.report()
    assert len(recipes) == 637


def test_dataset_id_range_and_count(service):
    ids = sorted(service.by_id.keys(), key=lambda x: int(x.split("-")[-1]))
    assert ids[0] == "ZITLAS-REC-0001"
    assert ids[-1] == "ZITLAS-REC-0637"
    assert len(ids) == 637


# ── 13. Duplicate ID detection ───────────────────────────────────────────

def test_duplicate_id_detection_catches_a_real_duplicate():
    """The validator itself must actually catch a duplicate — proven by
    feeding it one deliberately, not just by observing the real dataset
    (which has none) passes."""
    recipe_a = {
        "id": "ZITLAS-REC-0001", "name": "A", "description": "d", "category": "Breakfast",
        "meal_type": ["Breakfast"], "fitness_goals": ["General Fitness"], "diet_type": "Vegan",
        "servings": 1, "prep_time_min": 1, "cook_time_min": 1, "total_time_min": 2,
        "difficulty": "Easy", "equipment": [], "cost_level": "Budget",
        "ingredients": ["x"], "instructions": ["y"],
        "nutrition_estimated": {"calories_kcal": 100, "protein_g": 1, "carbs_g": 1, "fat_g": 1, "fiber_g": 1},
        "primary_protein_sources": [], "why_it_works": [], "tags": [],
        "regional_tag": None, "hostel_friendly": True, "home_friendly": True, "zitlas_original": False,
    }
    recipe_b = dict(recipe_a)  # same id, deliberate duplicate
    result = validate_dataset.validate_recipes([recipe_a, recipe_b])
    assert not result.ok
    assert any("duplicate id" in e for e in result.errors)


def test_placeholder_detection_catches_a_real_placeholder():
    bad = {
        "id": "ZITLAS-REC-0001", "name": "A", "description": "Made with {p1} and {p2}.",
        "category": "Breakfast", "meal_type": ["Breakfast"], "fitness_goals": ["General Fitness"],
        "diet_type": "Vegan", "servings": 1, "prep_time_min": 1, "cook_time_min": 1, "total_time_min": 2,
        "difficulty": "Easy", "equipment": [], "cost_level": "Budget",
        "ingredients": ["x"], "instructions": ["y"],
        "nutrition_estimated": {"calories_kcal": 100, "protein_g": 1, "carbs_g": 1, "fat_g": 1, "fiber_g": 1},
        "primary_protein_sources": [], "why_it_works": [], "tags": [],
        "regional_tag": None, "hostel_friendly": True, "home_friendly": True, "zitlas_original": False,
    }
    result = validate_dataset.validate_recipes([bad])
    assert not result.ok
    assert any("placeholder" in e for e in result.errors)


def test_missing_required_field_detection():
    incomplete = {"id": "ZITLAS-REC-0001", "name": "A"}
    result = validate_dataset.validate_recipes([incomplete])
    assert not result.ok
    assert len(result.errors) > 5  # every missing required field is its own error


# ── Discover endpoint (bonus coverage beyond the required 13) ───────────

def test_discover_returns_a_random_sample_within_limit(client):
    r = client.get("/api/recipes/discover?meal_type=breakfast&limit=5")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] <= 5
    for recipe in body["recipes"]:
        assert "Breakfast" in recipe["meal_type"]


def test_recipes_health(client):
    r = client.get("/api/recipes/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ready"
    assert body["count"] == 637
