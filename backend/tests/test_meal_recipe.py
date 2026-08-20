"""
ZITLAS — Meal-specific recipe + video (backend/tests/test_meal_recipe.py)

THE BUG: the Diet page's recipe button carried `meal.meal_name`, which in the
plan schema is the SLOT ("Breakfast"), not the dish. The dish (`meal.foods[]`)
was dropped at the first hop, so the recipe page asked
`/recommended?meal_type=breakfast` — "give me *a* breakfast recipe". With
respect to the dish that is a random draw.

A catalogue lookup cannot fix it either: zitlas_recipes.json is 637
ZITLAS-ORIGINAL recipes while plans are built from 4,520 foods, and the
measured exact-name overlap is 13/4520 (0.3%).

So these tests pin the contract that replaced it: the dish is the primary key,
the result is always named after it, repeat clicks are deterministic, and a
video is shown ONLY when it is demonstrably about that dish.

No network and no LLM: generation and YouTube are stubbed throughout.
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import meal_recipe_service as mrs   # noqa: E402
import routes.recipes as recipes_route            # noqa: E402


DISH = "Masala Oats with Vegetables"


def _recipe(name: str) -> dict:
    return mrs.coerce_recipe(
        {
            "ingredients": ["50 g rolled oats", "1 cup mixed vegetables"],
            "instructions": ["Boil the oats.", "Add the vegetables."],
            "servings": 1, "prep_time_min": 5, "cook_time_min": 10,
            "description": "A quick savoury oats bowl.",
        },
        name, "Breakfast",
    )


@pytest.fixture
def app_client(monkeypatch):
    """Endpoint wired to stubbed generation + no Firestore cache."""
    monkeypatch.setattr(mrs, "cache_get", lambda dish: None)
    monkeypatch.setattr(mrs, "cache_put", lambda dish, recipe: None)

    async def _gen(dish, **kwargs):
        return _recipe(dish)

    monkeypatch.setattr(mrs, "generate_recipe", _gen)
    monkeypatch.setattr(mrs, "find_meal_video", lambda dish, **kw: None)

    app = FastAPI()
    app.include_router(recipes_route.router, prefix="/api/recipes")
    return TestClient(app)


# ── Dish identity — the thing that was being lost ────────────────────────────

class TestDishIdentity:
    def test_the_dish_comes_from_foods_not_the_slot(self):
        """`meal.foods.join(', ')` is what the Diet page renders and what the
        athlete tapped. `meal_name` is only the slot."""
        assert mrs.dish_from_meal("Breakfast", [DISH]) == DISH
        assert mrs.dish_from_meal("Breakfast", ["Poha", "Curd"]) == "Poha, Curd"

    def test_the_slot_is_only_a_fallback_when_no_foods_exist(self):
        assert mrs.dish_from_meal("Breakfast", []) == "Breakfast"
        assert mrs.dish_from_meal("Breakfast", None) == "Breakfast"

    def test_portion_hints_and_case_collapse_to_one_key(self):
        """Otherwise the same meal would generate twice and could return two
        different recipes — the exact non-determinism being fixed."""
        variants = [
            DISH,
            "masala oats with vegetables",
            "Masala Oats with Vegetables (1 bowl)",
            "  Masala  Oats  with  Vegetables  ",
        ]
        keys = {mrs.cache_key(v) for v in variants}
        assert len(keys) == 1, keys

    def test_different_dishes_never_collide(self):
        assert mrs.cache_key(DISH) != mrs.cache_key("Chicken Rice Bowl")
        assert mrs.cache_key("Paneer Bhurji with Roti") != mrs.cache_key("Paneer Bhurji")


# ── The endpoint answers about the dish, never about the slot ────────────────

class TestEndpoint:
    def test_breakfast_meal_returns_that_dish(self, app_client):
        res = app_client.get("/api/recipes/for-meal", params={
            "meal_name": DISH, "meal_type": "Breakfast", "foods": DISH})
        assert res.status_code == 200
        body = res.json()
        assert body["meal_name"] == DISH
        assert body["recipe"]["name"] == DISH

    @pytest.mark.parametrize("dish,slot", [
        ("Masala Oats with Vegetables", "Breakfast"),
        ("Chicken Rice Bowl", "Lunch"),
        ("Paneer Bhurji with Roti", "Dinner"),
    ])
    def test_each_slot_returns_its_own_dish(self, app_client, dish, slot):
        """Breakfast/Lunch/Dinner must each answer for the dish clicked."""
        res = app_client.get("/api/recipes/for-meal",
                             params={"meal_name": dish, "meal_type": slot})
        assert res.status_code == 200
        assert res.json()["recipe"]["name"] == dish

    def test_consecutive_different_meals_do_not_bleed(self, app_client):
        first = app_client.get("/api/recipes/for-meal", params={
            "meal_name": "Chicken Rice Bowl", "meal_type": "Lunch"}).json()
        second = app_client.get("/api/recipes/for-meal", params={
            "meal_name": "Paneer Bhurji with Roti", "meal_type": "Dinner"}).json()
        assert first["recipe"]["name"] == "Chicken Rice Bowl"
        assert second["recipe"]["name"] == "Paneer Bhurji with Roti"

    def test_a_renaming_model_cannot_substitute_a_different_dish(self):
        """coerce_recipe FORCES the name back to the dish the athlete clicked."""
        drifted = mrs.coerce_recipe(
            {"name": "Healthy Breakfast Bowl",
             "ingredients": ["oats"], "instructions": ["cook"]},
            DISH, "Breakfast")
        assert drifted["name"] == DISH

    def test_a_missing_meal_name_is_rejected(self, app_client):
        assert app_client.get("/api/recipes/for-meal").status_code == 422

    def test_generation_failure_reports_rather_than_substituting(
            self, app_client, monkeypatch):
        async def _fail(dish, **kwargs):
            return None
        monkeypatch.setattr(mrs, "generate_recipe", _fail)

        res = app_client.get("/api/recipes/for-meal",
                             params={"meal_name": DISH})
        assert res.status_code == 503
        assert res.json()["detail"]["code"] == "recipe_generation_failed"


# ── Determinism: same meal, same recipe ──────────────────────────────────────

class TestDeterminism:
    def test_the_same_meal_twice_returns_the_cached_recipe(self, monkeypatch):
        store: dict = {}
        calls = {"n": 0}

        monkeypatch.setattr(mrs, "cache_get",
                            lambda dish: store.get(mrs.cache_key(dish)))
        monkeypatch.setattr(mrs, "cache_put",
                            lambda dish, r: store.__setitem__(mrs.cache_key(dish), r))

        async def _gen(dish, **kwargs):
            calls["n"] += 1
            return _recipe(dish)
        monkeypatch.setattr(mrs, "generate_recipe", _gen)
        monkeypatch.setattr(mrs, "find_meal_video", lambda dish, **kw: None)

        app = FastAPI()
        app.include_router(recipes_route.router, prefix="/api/recipes")
        client = TestClient(app)

        a = client.get("/api/recipes/for-meal", params={"meal_name": DISH}).json()
        b = client.get("/api/recipes/for-meal", params={"meal_name": DISH}).json()

        assert a["recipe"] == b["recipe"], "the same meal switched recipes"
        assert a["cached"] is False and b["cached"] is True
        assert calls["n"] == 1, "a repeat click regenerated instead of caching"


# ── Video relevance validation ───────────────────────────────────────────────

class TestVideoRelevance:
    def _video(self, title, desc=""):
        return {"title": title, "description": desc, "video_id": "abc123"}

    def test_an_on_topic_title_scores_high(self):
        score = mrs.video_relevance(
            self._video("Masala Oats with Vegetables Recipe | Healthy Breakfast"),
            DISH)
        assert score >= mrs.MIN_VIDEO_RELEVANCE

    def test_a_generic_healthy_food_video_is_rejected(self):
        for title in ("10 Healthy Indian Breakfast Ideas",
                      "Best Weight Loss Foods 2026",
                      "My Full Day Of Eating Vlog"):
            score = mrs.video_relevance(self._video(title), DISH)
            assert score < mrs.MIN_VIDEO_RELEVANCE, f"{title!r} scored {score}"

    def test_a_different_dish_is_rejected_even_if_it_is_a_recipe(self):
        score = mrs.video_relevance(
            self._video("Paneer Butter Masala Recipe | Restaurant Style"), DISH)
        assert score < mrs.MIN_VIDEO_RELEVANCE

    def test_a_partial_match_does_not_pass_on_one_shared_word(self):
        """'oats' alone must not qualify a video for this specific dish."""
        score = mrs.video_relevance(self._video("Overnight Oats Recipe"), DISH)
        assert score < mrs.MIN_VIDEO_RELEVANCE

    def test_no_relevant_video_yields_an_explicit_note_not_a_substitute(
            self, app_client):
        res = app_client.get("/api/recipes/for-meal",
                             params={"meal_name": DISH}).json()
        assert res["video"] is None
        assert res["video_note"] == "No exact cooking video found for this meal."

    def test_a_relevant_video_is_returned_with_its_score(self, monkeypatch):
        monkeypatch.setattr(mrs, "cache_get", lambda dish: None)
        monkeypatch.setattr(mrs, "cache_put", lambda dish, r: None)

        async def _gen(dish, **kwargs):
            return _recipe(dish)
        monkeypatch.setattr(mrs, "generate_recipe", _gen)
        monkeypatch.setattr(mrs, "find_meal_video", lambda dish, **kw: {
            "video_id": "xyz", "title": f"{dish} Recipe",
            "channel_name": "ZITLAS Kitchen", "relevance": 0.92,
        })

        app = FastAPI()
        app.include_router(recipes_route.router, prefix="/api/recipes")
        body = TestClient(app).get("/api/recipes/for-meal",
                                   params={"meal_name": DISH}).json()
        assert body["video"]["video_id"] == "xyz"
        assert body["video_note"] is None

    def test_the_youtube_query_is_built_from_the_dish(self):
        from services import youtube_recipe_service as yt
        queries = yt.build_queries(food=DISH, meal_type="Breakfast")
        assert queries, "no query produced"
        joined = " ".join(queries).lower()
        assert "oats" in joined
        # Never the generic phrasings the spec called out.
        assert not any(q.strip().lower() in
                       ("healthy recipe", "breakfast recipe", "indian healthy food")
                       for q in queries)


# ── Nothing else moved ───────────────────────────────────────────────────────

class TestNoCollateralChange:
    def test_recipe_entitlement_limits_are_untouched(self):
        from services import entitlements
        assert entitlements.limits_for(entitlements.TIER_FREE)[entitlements.RECIPE] == 7
        assert entitlements.limits_for(entitlements.TIER_PREMIUM)[entitlements.RECIPE] == 27

    def test_creator_recipes_still_gets_short_form_only(self):
        """_hydrate's max_seconds default must stay at the Shorts ceiling —
        the meal-recipe path opts into a longer one explicitly."""
        import inspect
        from services import youtube_recipe_service as yt

        sig = inspect.signature(yt._hydrate)
        assert sig.parameters["max_seconds"].default == yt._MAX_SHORT_SECONDS
        assert yt._MAX_SHORT_SECONDS == 180

    def test_the_slot_recommender_still_exists_for_direct_visits(self):
        """/for-meal is additive: opening recipe.html without a dish must
        still work through the original endpoint."""
        paths = {r.path for r in recipes_route.router.routes}
        assert "/recommended" in paths
        assert "/for-meal" in paths
        assert "/discover" in paths
