"""
ZITLAS — Premium entitlement matrix (backend/tests/test_entitlements.py)

    FEATURE          FREE       PREMIUM (Rs 149)
    Goal set/reset   2/week     5/week
    Meal swaps       70/week    UNLIMITED
    Get Recipe       7/week     27/week

services/entitlements.py already held these numbers, but NOTHING imported it —
the limits were configuration no request path consulted, so every feature was
unmetered. These tests pin both the matrix and the enforcement that now uses it.

They also pin the two properties that make the limits mean anything: the tier
is derived server-side from `users/{uid}.membership`, and usage is read from
`usage_weekly`. Neither can be supplied by a client.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient            # noqa: E402
from services import entitlements as ent               # noqa: E402
from services.auth_service import verify_firebase_token  # noqa: E402
import routes.entitlements as ent_routes               # noqa: E402


FREE_UID = "free_athlete"
PREMIUM_UID = "premium_athlete"


@pytest.fixture
def db(monkeypatch):
    """Firestore fake wired into the entitlement service, with one free and
    one premium athlete already on file."""
    client = FakeClient()
    client.collection("users").document(FREE_UID).set({"membership": {"plan": "free"}})
    client.collection("users").document(PREMIUM_UID).set(
        {"membership": {"plan": "premium", "active": True}})
    monkeypatch.setattr(ent.firestore_service, "get_client", lambda: client)
    return client


def spend(uid: str, feature: str, times: int) -> None:
    for _ in range(times):
        ent.record(uid, feature)


# ── The matrix itself ────────────────────────────────────────────────────────

class TestMatrix:
    def test_free_limits(self):
        limits = ent.limits_for(ent.TIER_FREE)
        assert limits[ent.GOAL_RESET] == 2
        assert limits[ent.MEAL_SWAP] == 70
        assert limits[ent.RECIPE] == 7

    def test_premium_limits(self):
        limits = ent.limits_for(ent.TIER_PREMIUM)
        assert limits[ent.GOAL_RESET] == 5
        assert limits[ent.RECIPE] == 27
        assert limits[ent.MEAL_SWAP] is ent.UNLIMITED

    def test_premium_meal_swap_is_a_sentinel_not_a_big_number(self):
        """The spec is explicit: not 500, not 1000 — no numeric quota at all.
        A large int would still be a ceiling something could compare against."""
        limit = ent.limits_for(ent.TIER_PREMIUM)[ent.MEAL_SWAP]
        assert limit is None
        assert not isinstance(limit, int)

    def test_premium_price_is_149(self):
        assert ent.PREMIUM_PRICE_INR == 149

    @pytest.mark.parametrize("perk", [
        ent.EXPERT_ACCESS_PRIORITY,
        ent.PERSONAL_COACHING_PRIORITY,
        ent.FREE_COACHING_TRIAL_PRIORITY,
        ent.EXPERT_REVIEW_PRIORITY,
        ent.NEW_EXPERT_AVAILABILITY_PRIORITY,
    ])
    def test_premium_holds_every_priority_perk(self, perk):
        assert ent.perks_for(ent.TIER_PREMIUM)[perk] is True
        assert ent.perks_for(ent.TIER_FREE)[perk] is False

    def test_zino_access_levels(self):
        assert ent.perks_for(ent.TIER_FREE)[ent.ZINO_AI] == "standard"
        assert ent.perks_for(ent.TIER_PREMIUM)[ent.ZINO_AI] == "priority"


# ── Enforcement ──────────────────────────────────────────────────────────────

class TestGoalResets:
    def test_free_gets_two_then_is_blocked(self, db):
        assert ent.check(FREE_UID, ent.GOAL_RESET).allowed
        spend(FREE_UID, ent.GOAL_RESET, 1)
        assert ent.check(FREE_UID, ent.GOAL_RESET).allowed      # 2nd
        spend(FREE_UID, ent.GOAL_RESET, 1)
        assert not ent.check(FREE_UID, ent.GOAL_RESET).allowed  # 3rd rejected

    def test_premium_gets_five_then_is_blocked(self, db):
        for i in range(5):
            assert ent.check(PREMIUM_UID, ent.GOAL_RESET).allowed, f"change {i+1}"
            spend(PREMIUM_UID, ent.GOAL_RESET, 1)
        assert not ent.check(PREMIUM_UID, ent.GOAL_RESET).allowed  # 6th


class TestMealSwaps:
    def test_free_gets_seventy_then_is_blocked(self, db):
        spend(FREE_UID, ent.MEAL_SWAP, 69)
        assert ent.check(FREE_UID, ent.MEAL_SWAP).allowed          # 70th
        spend(FREE_UID, ent.MEAL_SWAP, 1)
        assert not ent.check(FREE_UID, ent.MEAL_SWAP).allowed      # 71st

    @pytest.mark.parametrize("already_used", [70, 500, 1000, 100000])
    def test_premium_is_never_blocked_at_any_count(self, db, already_used):
        spend(PREMIUM_UID, ent.MEAL_SWAP, already_used)
        allowance = ent.check(PREMIUM_UID, ent.MEAL_SWAP)
        assert allowance.allowed, f"blocked after {already_used}"
        assert allowance.unlimited
        assert allowance.remaining is None

    def test_premium_usage_is_still_tracked_for_analytics(self, db):
        spend(PREMIUM_UID, ent.MEAL_SWAP, 12)
        allowance = ent.check(PREMIUM_UID, ent.MEAL_SWAP)
        assert allowance.used == 12      # counted...
        assert allowance.allowed         # ...but never blocking

    def test_require_does_not_raise_for_premium(self, db):
        spend(PREMIUM_UID, ent.MEAL_SWAP, 5000)
        ent.require(PREMIUM_UID, ent.MEAL_SWAP)   # must not raise

    def test_require_raises_429_for_a_spent_free_user(self, db):
        spend(FREE_UID, ent.MEAL_SWAP, 70)
        with pytest.raises(HTTPException) as exc:
            ent.require(FREE_UID, ent.MEAL_SWAP)
        assert exc.value.status_code == 429
        assert exc.value.detail["error"] == "limit_reached"
        # The tier travels so the client shows "upgrade" vs "resets next week".
        assert exc.value.detail["tier"] == ent.TIER_FREE


class TestRecipes:
    def test_free_gets_seven_then_is_blocked(self, db):
        spend(FREE_UID, ent.RECIPE, 6)
        assert ent.check(FREE_UID, ent.RECIPE).allowed        # 7th
        spend(FREE_UID, ent.RECIPE, 1)
        assert not ent.check(FREE_UID, ent.RECIPE).allowed    # 8th

    def test_premium_gets_twenty_seven_then_is_blocked(self, db):
        spend(PREMIUM_UID, ent.RECIPE, 26)
        assert ent.check(PREMIUM_UID, ent.RECIPE).allowed     # 27th
        spend(PREMIUM_UID, ent.RECIPE, 1)
        assert not ent.check(PREMIUM_UID, ent.RECIPE).allowed # 28th

    def test_a_premium_user_who_is_out_gets_no_upgrade_prompt_signal(self, db):
        spend(PREMIUM_UID, ent.RECIPE, 27)
        with pytest.raises(HTTPException) as exc:
            ent.require(PREMIUM_UID, ent.RECIPE)
        assert exc.value.detail["tier"] == ent.TIER_PREMIUM


# ── Trust boundaries ─────────────────────────────────────────────────────────

class TestClientCannotCheat:
    def test_tier_comes_from_firestore_not_the_request(self, db):
        """A free athlete stays free no matter what a client might claim."""
        assert ent.tier_for_uid(FREE_UID) == ent.TIER_FREE
        assert ent.tier_for_uid(PREMIUM_UID) == ent.TIER_PREMIUM

    def test_an_expired_premium_membership_is_treated_as_free(self, db):
        past = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        db.collection("users").document("expired").set(
            {"membership": {"plan": "premium", "active": True,
                            "premium_expiry_date": past}})
        assert ent.tier_for_uid("expired") == ent.TIER_FREE

    def test_an_unparseable_expiry_does_not_grant_premium_forever(self, db):
        db.collection("users").document("broken").set(
            {"membership": {"plan": "premium", "premium_expiry_date": "soon"}})
        assert ent.tier_for_uid("broken") == ent.TIER_FREE

    def test_tier_lookup_fails_closed_when_firestore_is_down(self, monkeypatch):
        monkeypatch.setattr(ent.firestore_service, "get_client", lambda: None)
        assert ent.tier_for_uid(PREMIUM_UID) == ent.TIER_FREE

    def test_usage_is_read_from_the_server_not_supplied(self, db):
        """The count comes from usage_weekly; there is no parameter to spoof."""
        spend(FREE_UID, ent.RECIPE, 3)
        assert ent.check(FREE_UID, ent.RECIPE).used == 3

    def test_the_week_key_is_server_time_not_a_client_clock(self):
        """A device set to next week must not mint a fresh allowance."""
        now = datetime(2026, 8, 18, 12, 0, tzinfo=timezone.utc)
        assert ent.week_key(now) == ent.week_key(now + timedelta(hours=5))
        assert ent.week_key(now) != ent.week_key(now + timedelta(days=8))


class TestWeeklyReset:
    def test_a_spent_allowance_returns_the_following_week(self, db):
        this_week = datetime(2026, 8, 18, tzinfo=timezone.utc)
        for _ in range(7):
            ent.record(FREE_UID, ent.RECIPE, now=this_week)
        assert not ent.check(FREE_UID, ent.RECIPE, now=this_week).allowed

        next_week = this_week + timedelta(days=8)
        assert ent.check(FREE_UID, ent.RECIPE, now=next_week).allowed
        assert ent.check(FREE_UID, ent.RECIPE, now=next_week).used == 0

    def test_usage_is_keyed_per_week_and_does_not_leak_backwards(self, db):
        week_a = datetime(2026, 8, 18, tzinfo=timezone.utc)
        week_b = week_a + timedelta(days=8)
        ent.record(FREE_UID, ent.RECIPE, now=week_b)
        assert ent.check(FREE_UID, ent.RECIPE, now=week_a).used == 0


class TestFailedOperationsCostNothing:
    def test_record_is_never_called_by_check_or_require(self, db):
        """Metering is explicit. A read must not consume."""
        for _ in range(50):
            ent.check(FREE_UID, ent.MEAL_SWAP)
            ent.require(FREE_UID, ent.MEAL_SWAP)
        assert ent.check(FREE_UID, ent.MEAL_SWAP).used == 0

    def test_record_never_raises_when_firestore_is_unavailable(self, monkeypatch):
        """Losing a count is a metering inaccuracy; failing the athlete's
        operation after they already received it would be a visible bug."""
        monkeypatch.setattr(ent.firestore_service, "get_client", lambda: None)
        ent.record(FREE_UID, ent.RECIPE)   # must not raise


# ── The API both clients read from ───────────────────────────────────────────

def make_app(uid: str):
    app = FastAPI()
    app.include_router(ent_routes.router, prefix="/api/entitlements")
    app.dependency_overrides[verify_firebase_token] = lambda: {
        "uid": uid, "email": f"{uid}@example.com", "admin": False,
        "expert": False, "email_verified": True,
    }
    return TestClient(app)


class TestEntitlementsApi:
    def test_snapshot_reports_the_free_matrix(self, db):
        body = make_app(FREE_UID).get("/api/entitlements").json()
        assert body["tier"] == "free"
        assert body["features"]["meal_swap"]["limit"] == 70
        assert body["features"]["recipe"]["limit"] == 7
        assert body["features"]["goal_reset"]["limit"] == 2

    def test_snapshot_reports_premium_as_unlimited_not_a_number(self, db):
        body = make_app(PREMIUM_UID).get("/api/entitlements").json()
        assert body["tier"] == "premium"
        assert body["features"]["meal_swap"]["limit"] == "unlimited"
        assert body["features"]["recipe"]["limit"] == 27
        assert body["features"]["goal_reset"]["limit"] == 5

    def test_snapshot_carries_both_plans_so_the_ui_needs_no_copy(self, db):
        """The comparison table renders from this — it must not hard-code."""
        plans = make_app(FREE_UID).get("/api/entitlements").json()["plans"]
        assert plans["free"]["limits"] == {
            "goal_reset": 2, "meal_swap": 70, "recipe": 7}
        assert plans["premium"]["limits"] == {
            "goal_reset": 5, "meal_swap": "unlimited", "recipe": 27}
        assert plans["premium"]["priceInr"] == 149
        assert plans["premium"]["perks"]["expert_review_priority"] is True
        assert plans["free"]["perks"]["expert_review_priority"] is False

    def test_both_clients_receive_the_identical_payload(self, db):
        """Flutter and the website call the same endpoint; nothing about the
        response depends on which client asked."""
        web = make_app(PREMIUM_UID).get("/api/entitlements").json()
        flutter = make_app(PREMIUM_UID).get(
            "/api/entitlements", headers={"User-Agent": "Dart/3.0 (dart:io)"}).json()
        assert web == flutter

    def test_the_endpoint_requires_authentication(self):
        app = FastAPI()
        app.include_router(ent_routes.router, prefix="/api/entitlements")
        assert TestClient(app).get("/api/entitlements").status_code == 401

    def test_consume_spends_a_goal_reset_and_then_429s(self, db):
        client = make_app(FREE_UID)
        for i in range(2):
            res = client.post("/api/entitlements/consume",
                              json={"feature": "goal_reset"})
            assert res.status_code == 200, f"change {i+1}"
        res = client.post("/api/entitlements/consume",
                          json={"feature": "goal_reset"})
        assert res.status_code == 429
        assert res.json()["detail"]["error"] == "limit_reached"

    def test_consume_rejects_a_feature_the_client_invents(self, db):
        res = make_app(FREE_UID).post("/api/entitlements/consume",
                                      json={"feature": "unlimited_everything"})
        assert res.status_code == 400
        assert res.json()["detail"]["error"] == "unknown_feature"

    def test_consume_will_not_spend_metered_features_with_real_endpoints(self, db):
        """meal_swap and recipe are gated at their own endpoints; letting a
        client spend them here would let it drain — or fake — its own quota."""
        for feature in ("meal_swap", "recipe"):
            res = make_app(FREE_UID).post("/api/entitlements/consume",
                                          json={"feature": feature})
            assert res.status_code == 400, feature


# ── Existing subscribers ─────────────────────────────────────────────────────

class TestExistingPremiumSubscribers:
    def test_an_already_subscribed_user_gets_the_new_matrix_without_repurchase(
            self, db):
        """Tier is derived per-request from `membership`, and limits come from
        configuration — so a matrix change reaches existing subscribers on
        deploy. Nothing is copied onto the user document at purchase time."""
        db.collection("users").document("old_subscriber").set({
            "membership": {"plan": "premium", "active": True},
            # Deliberately no entitlement fields: an older signup predating
            # this change.
        })
        assert ent.tier_for_uid("old_subscriber") == ent.TIER_PREMIUM
        limits = ent.limits_for(ent.tier_for_uid("old_subscriber"))
        assert limits[ent.MEAL_SWAP] is ent.UNLIMITED
        assert limits[ent.RECIPE] == 27
        assert limits[ent.GOAL_RESET] == 5

    def test_a_legacy_premium_row_without_active_flag_still_counts(self, db):
        db.collection("users").document("legacy").set(
            {"membership": {"plan": "premium"}})
        assert ent.tier_for_uid("legacy") == ent.TIER_PREMIUM
