"""NEW food dataset — diet generation and Meal Swap
(backend/tests/test_new_food_dataset.py)

Diet plans and meal swaps are built from the NEW, canonical food dataset
(food_dataset/zitlas_food_database_enriched_canonical.json). The OLD
production dataset (zitlas_food_database_enriched.json) stays on disk, frozen
and unmodified, and is never served.

Pinned here:
  1. diet generation and 2. Meal Swap read the NEW dataset;
  3. the OLD dataset is never silently used — a missing or invalid NEW
     dataset fails clearly (FoodDatasetError -> HTTP 503), offline fallbacks
     included, with no fallback file;
  4. the NEW dataset's size, schema and regional coverage;
  5. duplicate and invalid records are rejected;
  6. deep-fried / street / junk food (Vada Pav, Pav Bhaji, samosa, pakora…)
     stays in the catalogue but is never a normal recommendation;
  7. swap reasons and labels carry no calorie numbers;
  8. dietary restrictions and allergies still hold;
  9. transformation still works.

Run: python -m pytest tests/test_new_food_dataset.py -q
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from services import food_engine as fe
from services import groq_service as gs
from services import rag_service
from services.auth_service import verify_firebase_token

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "backend"
NEW_NAME = "zitlas_food_database_enriched_canonical.json"
OLD_NAME = "zitlas_food_database_enriched.json"

JUNK_NAMES = (
    "Vada Pav", "Pav Bhaji", "Samosa", "Pakora (Mixed)", "Onion Bhajiya", "Kachori",
    "Chole Bhature", "Kanda Bhaji", "Bread Pakora", "French Fries", "Jalebi",
)
JUNK_RE = re.compile(
    r"vada pav|pav bhaji|samosa|pakora|pakoda|bhajiya|bhature|kachori|french fries|"
    r"burger|pizza|jalebi|kurkure|bhujia", re.I)

GOALS = {
    "weight_loss": fe.goal_tags_from_profile({"fitness_goal": "weight_loss"}),
    "muscle_gain": fe.goal_tags_from_profile({"fitness_goal": "muscle_gain"}),
    "weight_gain": ["Lean Bulk", "Muscle Gain"],
    "transformation": fe.goal_tags_from_profile({"fitness_goal": "transformation"}),
    "six_pack": ["Fat Loss", "Muscle Gain"],
    "general_fitness": fe.goal_tags_from_profile({"fitness_goal": "general_fitness"}),
}
TEST_CALLER = {"uid": "new-food-dataset-test", "email": None, "name": "Dataset Test"}


@pytest.fixture(scope="module")
def engine():
    return fe.get_engine()


@pytest.fixture(scope="module")
def raw():
    return json.loads(fe._DATASET_PATH.read_text(encoding="utf-8"))


def _week(engine, goal_tags, diet="vegetarian", favorites=None, allergens=None):
    return engine.build_week_plan(
        goal_tags=list(goal_tags), diet_tags=fe.diet_tags_from_lifestyle(diet),
        living_situation="Home", budget_tier="Medium", disease_tags=[],
        allergens=allergens or set(), favorite_foods=favorites or [],
        daily_calorie_target=2000,
    )


def _served(week):
    """Every food a week shows — primary picks AND the listed alternatives."""
    return [f for d in week["days"] for m in d["meals"].values()
            for f in (m.get("primary") or []) + (m.get("alternatives") or [])]


def _by_name(engine, name):
    return next(f for f in engine.by_id.values() if f["name"] == name)


def _pool(engine, diet):
    ids: set[int] = set()
    for meal in ("Breakfast", "Lunch", "Dinner", "Snack", "Pre Workout", "Post Workout", "Late Night"):
        ids |= engine._pipeline_ids(
            disease_tags=[], allergens=set(), diet_tags=fe.diet_tags_from_lifestyle(diet),
            goal_tags=["Weight Loss"], subgoal_tag=None, profile=None, budget_tier=None,
            living_tag=None, meal_tag=meal, season_tag=None)
    return {engine.by_id[i]["name"] for i in ids}


@pytest.fixture(scope="module")
def swap_client():
    from routes import swap as swap_route
    app = FastAPI()
    app.include_router(swap_route.router, prefix="/api/diet")
    app.dependency_overrides[swap_route.verify_firebase_token] = lambda: TEST_CALLER
    return TestClient(app)


def _swap(client, **extra):
    body = {"meal_name": "Breakfast", "current_foods": ["Poha"], "user_profile": {},
            "fitness_goal": "transformation", "options": 4, **extra}
    return client.post("/api/diet/swap", json=body)


@pytest.fixture()
def main_client():
    import main
    main.app.dependency_overrides[verify_firebase_token] = lambda: TEST_CALLER
    # Not entered as a context manager: no lifespan, no schedulers.
    yield TestClient(main.app)
    main.app.dependency_overrides.pop(verify_firebase_token, None)


@pytest.fixture()
def dataset_unavailable(monkeypatch):
    """The NEW dataset cannot be loaded. The engine singleton is dropped so
    the next get_engine() really rebuilds — exactly what a server start with
    a missing file does."""
    def _missing(path=fe._DATASET_PATH):
        raise fe.FoodDatasetError(f"{Path(path).name} is missing (simulated)")
    monkeypatch.setattr(fe, "_engine", None)
    monkeypatch.setattr(fe, "load_food_dataset", _missing)


# ── 1-3. The NEW dataset, and only the NEW dataset ─────────────────────────

def test_engine_serves_the_new_dataset(engine, raw):
    assert fe._DATASET_PATH.name == NEW_NAME
    assert engine.dataset_path.name == NEW_NAME
    assert engine.dataset_path.resolve() != fe._FROZEN_OLD_DATASET.resolve()
    assert len(engine.by_id) == len(raw)


def test_diet_plan_foods_are_new_dataset_records(engine, raw):
    new = {r["id"]: r["name"] for r in raw}
    week = _week(engine, GOALS["transformation"], diet="non-vegetarian")
    served = _served(week)
    assert served
    for f in served:
        assert new.get(f["id"]) == f["name"], f"{f['id']} {f['name']!r} is not a NEW-dataset record"


def test_meal_swap_options_are_new_dataset_records(swap_client, raw):
    new = {r["id"]: r["name"] for r in raw}
    for meal in ("Breakfast", "Lunch", "Dinner", "Evening Snack"):
        body = _swap(swap_client, meal_name=meal).json()
        assert body["module"] == "deterministic_swap"
        assert body["options"], f"{meal} swap returned nothing"
        for opt in body["options"]:
            for fid in opt["food_ids"]:
                assert fid in new, f"{meal} swap served id {fid}, which is not in the NEW dataset"


def test_the_new_dataset_holds_foods_the_old_one_never_had(engine):
    old = json.loads(fe._FROZEN_OLD_DATASET.read_text(encoding="utf-8"))
    new_only = {f["name"] for f in engine.by_id.values()} - {r["name"] for r in old}
    assert len(new_only) > 500
    for name in ("Kochur Loti", "Arachuvitta Sambar", "Chakka Puzhukku", "Rajasthani Thali"):
        assert name in new_only


def test_the_frozen_old_dataset_is_refused():
    with pytest.raises(fe.FoodDatasetError):
        fe.load_food_dataset(fe._FROZEN_OLD_DATASET)


def test_a_missing_new_dataset_fails_instead_of_falling_back(tmp_path):
    with pytest.raises(fe.FoodDatasetError):
        fe.FoodRecommendationEngine(tmp_path / "missing.json")


def test_no_service_or_route_opens_another_food_dataset():
    """Only food_engine.py may name a food-dataset file — the NEW one it
    serves and the frozen OLD one it refuses."""
    offenders = []
    for folder in ("services", "routes"):
        for py in (BACKEND / folder).rglob("*.py"):
            for name in re.findall(r"zitlas_food_database[\w.]*\.json", py.read_text(encoding="utf-8")):
                if py.name != "food_engine.py" or name not in (NEW_NAME, OLD_NAME):
                    offenders.append(f"{py.relative_to(BACKEND)}: {name}")
    assert offenders == []


def test_the_frozen_old_dataset_is_unmodified():
    old = fe._FROZEN_OLD_DATASET
    assert len(json.loads(old.read_text(encoding="utf-8"))) == 4520
    git = shutil.which("git")
    if not git:
        pytest.skip("git not available")
    rel = old.relative_to(ROOT).as_posix()
    result = subprocess.run([git, "diff", "--quiet", "HEAD", "--", rel], cwd=ROOT)
    assert result.returncode == 0, f"{rel} differs from HEAD"


def test_swap_route_returns_503_when_the_dataset_is_unavailable(swap_client, dataset_unavailable):
    res = _swap(swap_client)
    assert res.status_code == 503
    assert "Food dataset unavailable" in res.json()["detail"]


def test_weekly_plan_offline_fallback_does_not_hide_a_missing_dataset(
        main_client, dataset_unavailable, monkeypatch):
    """The LLM path fails, the route falls back to offline_fallback — which
    reads the same dataset, so the athlete gets a clear 503, not a plan from
    anywhere else."""
    async def _llm_down(**_):
        raise RuntimeError("all providers failed (simulated)")
    monkeypatch.setattr(gs, "generate_nutrition_weekly_plan", _llm_down)
    res = main_client.post("/api/ai/nutrition-weekly-plan", json={
        "user_profile": {"primary_goal": "weight_loss"},
        "lifestyle_data": {"diet_type": "vegetarian", "living_situation": "Home"},
    })
    assert res.status_code == 503
    assert "Food dataset unavailable" in res.json()["detail"]


def test_swap_meal_offline_fallback_does_not_hide_a_missing_dataset(
        main_client, dataset_unavailable, monkeypatch):
    async def _llm_down(**_):
        raise RuntimeError("all providers failed (simulated)")
    monkeypatch.setattr(gs, "generate_meal_swap", _llm_down)
    monkeypatch.setattr(rag_service, "retrieve_context", lambda *a, **k: ("", []))
    res = main_client.post("/api/ai/swap-meal", json={
        "meal_name": "Breakfast", "current_foods": ["Poha"],
        "reason": "I don't like this food", "user_profile": {},
    })
    assert res.status_code == 503
    assert "Food dataset unavailable" in res.json()["detail"]


# ── 4. Size, schema, coverage ──────────────────────────────────────────────

def test_new_dataset_size_schema_and_coverage(raw):
    assert len(raw) >= 3200
    assert fe.validate_food_records(raw) == []
    assert {len(r) for r in raw} == {73}
    states = {s for r in raw for s in (r.get("state_of_origin") or [])}
    assert len(states) >= 31
    regions = {r.get("region") for r in raw}
    assert {"North", "South", "East", "West", "Northeast", "Central"} <= regions
    for meal in ("Breakfast", "Lunch", "Dinner", "Snack"):
        assert sum(meal in (r.get("mealSuitable") or []) for r in raw) >= 500, meal


def test_new_dataset_has_no_duplicate_ids_or_names(raw):
    ids = [r["id"] for r in raw]
    names = [r["name"].strip().lower() for r in raw]
    assert len(ids) == len(set(ids))
    assert len(names) == len(set(names))


# ── 5. Duplicate / invalid records are rejected ────────────────────────────

_GOOD = {"id": 1, "name": "Poha", "category": "Indian Breakfast", "type": "Vegetarian",
         "calories": 201, "protein": 5.3, "carbs": 36.8, "fat": 3.8}


def test_a_valid_record_passes():
    assert fe.validate_food_records([_GOOD]) == []


@pytest.mark.parametrize("records", [
    pytest.param([], id="empty"),
    pytest.param([_GOOD, dict(_GOOD, name="Upma")], id="duplicate-id"),
    pytest.param([_GOOD, dict(_GOOD, id=2, name="poha")], id="duplicate-name"),
    pytest.param([dict(_GOOD, name="")], id="missing-name"),
    pytest.param([dict(_GOOD, category="")], id="missing-category"),
    pytest.param([dict(_GOOD, type="Meat")], id="bad-type"),
    pytest.param([dict(_GOOD, calories=-5)], id="negative-calories"),
    pytest.param([dict(_GOOD, protein="lots")], id="non-numeric-protein"),
    pytest.param([dict(_GOOD, id=0)], id="non-positive-id"),
    pytest.param([dict(_GOOD, id="7")], id="string-id"),
])
def test_invalid_records_are_rejected(records):
    assert fe.validate_food_records(records)


def test_a_dataset_file_with_duplicates_is_refused(tmp_path):
    path = tmp_path / "foods.json"
    path.write_text(json.dumps([_GOOD, dict(_GOOD, id=2)]), encoding="utf-8")
    with pytest.raises(fe.FoodDatasetError):
        fe.load_food_dataset(path)


# ── 6. Junk food: kept in the catalogue, never recommended ─────────────────

def test_junk_foods_stay_in_the_catalogue_but_are_gated(engine):
    junk = engine._junk_ids()
    for name in JUNK_NAMES:
        food = _by_name(engine, name)
        assert fe.is_junk_for_recommendation(food), name
        assert food["id"] in junk, name


def test_healthy_regional_dishes_are_not_mistaken_for_junk(engine):
    for name in ("Patal Bhaji", "Aluchi Patal Bhaji", "Poha", "Thalipeeth", "Idli", "Dal Tadka with Rice"):
        assert not fe.is_junk_for_recommendation(_by_name(engine, name)), name


@pytest.mark.parametrize("goal", sorted(GOALS))
@pytest.mark.parametrize("diet", ["vegetarian", "non-vegetarian"])
def test_week_plans_never_recommend_junk(engine, goal, diet):
    served = _served(_week(engine, GOALS[goal], diet=diet))
    assert served
    junk = [f["name"] for f in served if fe.is_junk_for_recommendation(f) or JUNK_RE.search(f["name"])]
    assert junk == [], f"{goal}/{diet} week served {sorted(set(junk))}"


def test_junk_stays_out_even_when_named_as_a_favourite(engine):
    served = _served(_week(engine, GOALS["transformation"],
                           favorites=["Vada Pav", "Pav Bhaji", "Samosa", "Pakora"]))
    assert not [f["name"] for f in served if JUNK_RE.search(f["name"])]


@pytest.mark.parametrize("slot", ["breakfast", "lunch", "dinner", "evening_snack"])
def test_engine_swaps_never_offer_junk(engine, slot):
    combos = engine.find_swap_combos(
        meal_slot=slot, goal_tags=GOALS["transformation"],
        diet_tags=fe.diet_tags_from_lifestyle("vegetarian"),
        living_situation="Home", budget_tier="Medium", disease_tags=[], allergens=set(),
        exclude_names=["Vada Pav"], n_combos=5, favorite_foods=["Vada Pav", "Samosa"],
    )
    assert combos
    offered = [f["name"] for c in combos for f in c]
    assert not [n for n in offered if JUNK_RE.search(n)], offered
    assert not [f["name"] for c in combos for f in c if fe.is_junk_for_recommendation(f)]


def test_swapping_out_a_street_snack_offers_no_street_snack(swap_client):
    body = _swap(swap_client, meal_name="Evening Snack", current_foods=["Vada Pav"]).json()
    assert body["options"]
    names = [o["name"] for o in body["options"]]
    assert not [n for n in names if JUNK_RE.search(n)], names


# ── 7. No calorie numbers in the Meal Swap experience ─────────────────────

def test_swap_reasons_and_labels_carry_no_calorie_numbers(swap_client):
    for meal in ("Breakfast", "Lunch", "Dinner"):
        for opt in _swap(swap_client, meal_name=meal).json()["options"]:
            text = " ".join([opt["reason"], *opt.get("quality_labels", [])])
            assert not re.search(r"kcal|calorie", text, re.I), text
            assert opt["diet_type"] in ("Vegetarian", "Egg", "Non-Vegetarian")


def test_describe_swap_is_calorie_free(engine):
    lunch = [_by_name(engine, "Dal Tadka with Rice")]
    reason = fe.describe_swap(lunch, {"calories": 420, "protein": 10}, GOALS["transformation"],
                              goal_label="body transformation")
    assert reason.startswith("Dal Tadka with Rice")
    assert not re.search(r"kcal|calorie|\d+\s*g\b", reason, re.I), reason


# ── 8. Dietary restrictions and allergies still hold ──────────────────────

@pytest.mark.parametrize("diet", ["vegetarian", "vegan", "eggetarian", "jain"])
def test_week_plans_respect_the_diet(engine, diet):
    key = fe.canonical_diet_key(diet)
    served = _served(_week(engine, GOALS["transformation"], diet=diet))
    bad = [(f["name"], fe.food_violates_diet(f, key)) for f in served if fe.food_violates_diet(f, key)]
    assert bad == []


def test_vegan_pool_excludes_dishes_that_are_dairy_by_definition(engine):
    pool = _pool(engine, "vegan")
    for name in ("Khichdi with Kadhi", "Dal Makhani with Rice", "Masala Chai (Regular)",
                 "Banana Shake (Regular)", "Thandai (Regular)", "Vegetable Korma with Roti"):
        assert name not in pool, f"{name} offered to a vegan"


def test_an_allergen_rules_out_a_diet_even_when_the_name_does_not():
    food = {"name": "Kali", "dietSuitable": ["Vegan", "Vegetarian"], "allergens": ["Milk"]}
    assert fe.food_violates_diet(food, fe.DIET_VEGAN)
    assert fe.food_violates_diet(food, fe.DIET_PURE_VEGETARIAN) is None
    egg = {"name": "Kali", "dietSuitable": ["Vegetarian"], "allergens": ["Egg"]}
    assert fe.food_violates_diet(egg, fe.DIET_PURE_VEGETARIAN)


def test_new_non_veg_dishes_never_reach_a_vegetarian(engine):
    pool = _pool(engine, "vegetarian")
    for name in ("Kochur Loti", "Chingri Posto", "Motte Gassi", "Memoni Biryani", "Njandu Roast"):
        assert name not in pool, name


def test_peanut_allergy_is_respected(engine):
    ctx = gs._engine_query_context(
        {"primary_goal": "weight_loss"},
        {"diet_type": "vegetarian", "living_situation": "Home", "daily_budget": "Medium",
         "allergies": ["Peanut"]},
    )
    week = engine.build_week_plan(
        ctx["goal_tags"], ctx["diet_tags"], ctx["living_tag"], ctx["budget_tier"],
        ctx["disease_tags"], ctx["allergens"], favorite_foods=["Shakarkandi Ki Sabzi"],
        daily_calorie_target=1800, profile=ctx["profile"],
    )
    with_peanut = [f["name"] for f in _served(week)
                   if any("peanut" in str(a).lower() for a in f.get("allergens") or [])]
    assert with_peanut == []


# ── 9. Transformation still works ─────────────────────────────────────────

def test_transformation_goal_mapping():
    assert fe.goal_key_from_profile({"fitness_goal": "transformation"}) == "transformation"
    assert GOALS["transformation"] == ["General Fitness", "Fat Loss", "Muscle Gain"]


def test_transformation_week_fills_every_main_meal(engine):
    week = _week(engine, GOALS["transformation"], diet="non-vegetarian")
    assert len(week["days"]) == 7
    for day in week["days"]:
        for slot in ("breakfast", "lunch", "dinner"):
            assert day["meals"].get(slot, {}).get("primary"), f"{day['day']} {slot} is empty"


def test_transformation_swap_leads_with_a_quality_home_dish(swap_client, engine):
    body = _swap(swap_client, meal_name="Breakfast", current_foods=["Poha"]).json()
    assert body["options"]
    top = engine.by_id[body["options"][0]["food_ids"][0]]
    assert top.get("restaurant_food") is not True
    assert fe.nutrition_quality_score(top, goal_key="transformation") >= 0.60


# ── Favourites match whole words (the Assam "Khar" / "Tikhari" defect) ────

def test_favourite_keywords_match_whole_words():
    assert not fe._mentions("kathiyawadi dahi tikhari", "khar")
    assert fe._mentions("khar", "khar")
    assert fe._mentions("masor tenga with rice", "masor tenga")
    assert fe._mentions("steamed idlis", "idli")


def test_an_assam_week_is_not_filled_with_a_gujarati_side(engine):
    week = engine.build_week_plan(
        goal_tags=["General Fitness"], diet_tags=["Vegetarian"], living_situation="Home",
        budget_tier="Medium", disease_tags=[], allergens=set(),
        favorite_foods=["Masor Tenga", "Masor Tenga with Rice", "Khar", "Assamese Thali"],
        daily_calorie_target=1800,
    )
    primaries = [f["name"] for d in week["days"] for m in d["meals"].values() for f in m.get("primary") or []]
    assert "Kathiyawadi Dahi Tikhari" not in primaries
