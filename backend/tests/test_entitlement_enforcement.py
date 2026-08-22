"""
ZITLAS — entitlement ENFORCEMENT at the endpoints (backend/tests/test_entitlement_enforcement.py)

tests/test_entitlements.py proves the MATRIX is right — free 2/70/7, premium
5/unlimited/27. This file proves the endpoints actually apply it, which is a
different claim entirely and was the one that failed in production:

    POST https://www.zitlas.com/api/diet/swap   (no Authorization header)
    -> HTTP 200 {"module":"deterministic_swap","options":[...]}

The matrix was correct, the gate existed, and neither client sent a token —
so `uid_from_authorization()` returned None and every swap skipped metering.
Premium's headline benefit ("Unlimited Meal Swaps") was identical to free
because free was unlimited too.

The rule these tests pin down: a metered endpoint REQUIRES a verified token.
Not "meters when one happens to be present" — requires. An unauthenticated
caller is refused rather than waved through unmetered.

Run: python -m pytest tests/test_entitlement_enforcement.py -q
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient              # noqa: E402
from services import entitlements as ent                 # noqa: E402
import routes.ai as ai_routes                            # noqa: E402
import routes.entitlements as ent_routes                 # noqa: E402
import routes.chat as chat_routes                        # noqa: E402
import routes.recipes as recipe_routes                   # noqa: E402
import routes.swap as swap_routes                        # noqa: E402
import routes.system as system_routes                    # noqa: E402

#: The 8-byte PNG signature — enough for the endpoint's type check,
#: and never written to disk because auth refuses the request first.
PNG_MAGIC = bytes([137, 80, 78, 71, 13, 10, 26, 10])

FREE_UID = "free_athlete"
PREMIUM_UID = "premium_athlete"

SWAP_BODY = {
    "meal_name": "Breakfast",
    "current_foods": ["Poha (Home Style)"],
    "user_profile": {},
    "fitness_goal": "transformation",
    "options": 3,
}


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    client.collection("users").document(FREE_UID).set({"membership": {"plan": "free"}})
    client.collection("users").document(PREMIUM_UID).set(
        {"membership": {"plan": "premium", "active": True}})
    monkeypatch.setattr(ent.firestore_service, "get_client", lambda: client)
    return client


def _app(uid: str | None) -> TestClient:
    """The metered routers, signed in as `uid` — or genuinely signed out.

    `uid=None` installs NO dependency override, so the real
    `verify_firebase_token` runs and rejects the tokenless request. That is
    the exact production path this file exists to pin.
    """
    app = FastAPI()
    app.include_router(swap_routes.router, prefix="/api/diet")
    app.include_router(ai_routes.router, prefix="/api/ai")
    app.include_router(ent_routes.router, prefix="/api/entitlements")
    app.include_router(system_routes.router, prefix="/api/system")
    app.include_router(recipe_routes.router, prefix="/api/recipes")
    app.include_router(chat_routes.router, prefix="/api/chat")
    if uid is not None:
        caller = {"uid": uid, "email": None, "name": "Test"}
        app.dependency_overrides[swap_routes.verify_firebase_token] = lambda: caller
        app.dependency_overrides[ai_routes.verify_firebase_token] = lambda: caller
        app.dependency_overrides[ent_routes.verify_firebase_token] = lambda: caller
        app.dependency_overrides[recipe_routes.verify_firebase_token] = lambda: caller
        app.dependency_overrides[chat_routes.verify_firebase_token] = lambda: caller
    return TestClient(app)


def spend(uid: str, feature: str, times: int) -> None:
    for _ in range(times):
        ent.record(uid, feature)


# ── 1. Unauthenticated callers are refused, not silently unmetered ──────────

class TestUnauthenticated:
    """Each of these reproduces a request that succeeded in production."""

    def test_meal_swap_without_a_token_is_rejected(self, db):
        res = _app(None).post("/api/diet/swap", json=SWAP_BODY)
        assert res.status_code == 401, (
            "an unauthenticated swap must be refused — a 200 here is the "
            "production bypass: unlimited, uncounted swaps for anyone"
        )

    def test_legacy_swap_meal_without_a_token_is_rejected(self, db):
        """/api/ai/swap-meal is the Flutter fallback path. Leaving it open
        would move the bypass rather than close it."""
        res = _app(None).post("/api/ai/swap-meal", json={**SWAP_BODY, "reason": "x"})
        assert res.status_code == 401

    def test_goal_reset_consumption_without_a_token_is_rejected(self, db):
        res = _app(None).post("/api/entitlements/consume",
                              json={"feature": "goal_reset"})
        assert res.status_code == 401

    def test_get_recipe_without_a_token_is_rejected(self, db):
        """/api/recipes/for-meal is the METERED "Get Recipe" action (free 7,
        premium 27). It used to meter only when a token happened to arrive,
        so a direct request got an unlimited, uncounted recipe."""
        res = _app(None).get("/api/recipes/for-meal", params={"meal_name": "Poha"})
        assert res.status_code == 401

    @pytest.mark.parametrize("path", ["", "/recommended", "/discover"])
    def test_the_recipe_BROWSE_endpoints_stay_open(self, db, path):
        """Only the metered action was closed. Browsing is not metered and
        must keep working exactly as before."""
        res = _app(None).get(f"/api/recipes{path}", params={"limit": 1})
        assert res.status_code == 200

    def test_chat_upload_without_a_token_is_rejected(self, db):
        """It writes a caller-supplied file to disk and returns a public URL
        on the ZITLAS domain — anonymous disk-fill and free image hosting."""
        res = _app(None).post(
            "/api/chat/upload",
            files={"file": ("x.png", PNG_MAGIC, "image/png")},
        )
        assert res.status_code == 401

    def test_test_push_without_a_token_is_rejected(self, db):
        """It sends a real push with a caller-supplied title and body to any
        device token — i.e. an arbitrary notification that looks like ZITLAS.
        It was unauthenticated and live in production."""
        res = _app(None).post("/api/system/test-push",
                              json={"token": "d" * 40, "title": "hi", "body": "there"})
        assert res.status_code == 401
        assert res.status_code != 422, "422 would mean it validated and reached the handler"


# ── 2. Meal swaps: free is capped at 70/week, premium has no cap ────────────

class TestMealSwapLimit:
    def test_free_is_allowed_at_69_used(self, db):
        spend(FREE_UID, ent.MEAL_SWAP, 69)
        res = _app(FREE_UID).post("/api/diet/swap", json=SWAP_BODY)
        assert res.status_code == 200

    def test_free_is_refused_at_70_used(self, db):
        spend(FREE_UID, ent.MEAL_SWAP, 70)
        res = _app(FREE_UID).post("/api/diet/swap", json=SWAP_BODY)
        assert res.status_code == 429
        detail = res.json()["detail"]
        assert detail["error"] == "limit_reached"
        assert detail["tier"] == "free"
        assert detail["limit"] == 70

    def test_premium_is_allowed_far_past_the_free_ceiling(self, db):
        """Not "a bigger number" — NO number. 500 is chosen because it would
        expose any large-int ceiling standing in for unlimited."""
        spend(PREMIUM_UID, ent.MEAL_SWAP, 500)
        res = _app(PREMIUM_UID).post("/api/diet/swap", json=SWAP_BODY)
        assert res.status_code == 200

    def test_a_refused_swap_does_not_cost_the_athlete_a_swap(self, db):
        spend(FREE_UID, ent.MEAL_SWAP, 70)
        _app(FREE_UID).post("/api/diet/swap", json=SWAP_BODY)
        assert ent.check(FREE_UID, ent.MEAL_SWAP).used == 70

    def test_the_uid_comes_from_the_token_not_the_body(self, db):
        """A free athlete cannot spend from someone else's allowance, or
        claim premium, by putting it in the request body."""
        spend(FREE_UID, ent.MEAL_SWAP, 70)
        res = _app(FREE_UID).post("/api/diet/swap", json={
            **SWAP_BODY, "uid": PREMIUM_UID, "tier": "premium",
        })
        assert res.status_code == 429


# ── 3. Goal resets: free 2/week, premium 5/week ─────────────────────────────

class TestGoalResetLimit:
    def test_free_gets_exactly_two(self, db):
        client = _app(FREE_UID)
        assert client.post("/api/entitlements/consume",
                           json={"feature": "goal_reset"}).status_code == 200
        assert client.post("/api/entitlements/consume",
                           json={"feature": "goal_reset"}).status_code == 200
        third = client.post("/api/entitlements/consume", json={"feature": "goal_reset"})
        assert third.status_code == 429
        assert third.json()["detail"]["limit"] == 2

    def test_premium_gets_exactly_five(self, db):
        client = _app(PREMIUM_UID)
        for _ in range(5):
            assert client.post("/api/entitlements/consume",
                               json={"feature": "goal_reset"}).status_code == 200
        sixth = client.post("/api/entitlements/consume", json={"feature": "goal_reset"})
        assert sixth.status_code == 429
        assert sixth.json()["detail"]["limit"] == 5

    def test_the_count_survives_a_client_that_forgets_everything(self, db):
        """The website clearing localStorage, or the app being reinstalled,
        must not restore a spent allowance — the counter lives in Firestore
        under the uid, and nothing the client holds is consulted."""
        spend(FREE_UID, ent.GOAL_RESET, 2)
        res = _app(FREE_UID).post("/api/entitlements/consume",
                                  json={"feature": "goal_reset"})
        assert res.status_code == 429

    def test_only_allowlisted_features_are_consumable(self, db):
        """Without the allowlist a client could invent a feature name and
        write counters nothing enforces."""
        for feature in ("meal_swap", "recipe", "made_up_feature"):
            res = _app(FREE_UID).post("/api/entitlements/consume",
                                      json={"feature": feature})
            assert res.status_code == 400, feature
