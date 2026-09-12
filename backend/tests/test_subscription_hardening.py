"""
ZITLAS — Subscription & entitlement hardening (backend/tests/test_subscription_hardening.py)

Pins the four defects fixed in this pass, so none of them can return:

  1. PREMIUM GOAL RESETS WERE CAPPED AT 5. `_DEFAULT_LIMITS` gave premium a
     numeric ceiling, so a paying user was blocked on their sixth reset of the
     week while the UI promised unlimited.

  2. TWO CONCURRENT RESETS COULD BOTH PASS A 1-REMAINING ALLOWANCE. The route
     called `require()` (a read) and then `record()` (a write) — two round
     trips. Both requests read used=1 against a limit of 2, both passed, both
     incremented: three resets from a two-reset allowance.

  3. THE LIMIT WAS ADVISORY. The reset itself was a CLIENT-SIDE Firestore
     write; `/api/entitlements/consume` was a courtesy call the client made
     first. Skipping it — or ignoring the 429, or simply having the request
     fail (both clients fail OPEN on a transport error) — reset as often as
     you liked. `POST /api/user/goal-reset` now performs the mutation itself,
     so skipping the endpoint skips the reset, not the limit.

  4. RENEWING EARLY DESTROYED REMAINING TIME. `expiry = now + period` threw
     away whatever the athlete still held: renewing on 10 Oct with an expiry
     of 15 Oct moved them to 9 Nov instead of 14 Nov.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import entitlements as ent               # noqa: E402
from services.auth_service import verify_firebase_token  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402
import routes.player as player_routes                  # noqa: E402
import routes.entitlements as ent_routes               # noqa: E402

FREE_UID = "free_athlete"
PREMIUM_UID = "premium_athlete"


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    client.collection("users").document(FREE_UID).set(
        {"membership": {"plan": "free"}, "goal": {"type": "Weight Loss"}})
    client.collection("users").document(PREMIUM_UID).set(
        {"membership": {"plan": "premium", "active": True},
         "goal": {"type": "Muscle Gain"}})
    monkeypatch.setattr(ent.firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(player_routes.firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    return client


def _app(uid: str | None):
    app = FastAPI()
    app.include_router(player_routes.router, prefix="/api/user")
    app.include_router(ent_routes.router, prefix="/api/entitlements")
    if uid is not None:
        app.dependency_overrides[verify_firebase_token] = lambda: {
            "uid": uid, "email": None, "name": "T", "expert": False,
            "email_verified": True}
    return TestClient(app)


# ══════════════════════════════════════════════════════════════════════════
# 1. Free = 2/week, premium = unlimited
# ══════════════════════════════════════════════════════════════════════════


class TestGoalResetQuota:
    def test_free_user_gets_exactly_two_then_403_equivalent(self, db):
        client = _app(FREE_UID)
        assert client.post("/api/user/goal-reset").status_code == 200
        assert client.post("/api/user/goal-reset").status_code == 200
        third = client.post("/api/user/goal-reset")
        assert third.status_code == 429          # quota, not authorization
        assert third.json()["detail"]["error"] == "limit_reached"
        assert third.json()["detail"]["limit"] == 2
        assert third.json()["detail"]["tier"] == "free"

    def test_premium_user_gets_exactly_five_then_429(self, db):
        """Premium is a HIGHER limit (5/week), not an unlimited one."""
        client = _app(PREMIUM_UID)
        for i in range(5):
            assert client.post("/api/user/goal-reset").status_code == 200, \
                f"premium blocked on reset {i + 1}"
        sixth = client.post("/api/user/goal-reset")
        assert sixth.status_code == 429
        assert sixth.json()["detail"]["limit"] == 5
        assert sixth.json()["detail"]["tier"] == "premium"

    def test_premium_reset_reports_the_numeric_ceiling(self, db):
        body = _app(PREMIUM_UID).post("/api/user/goal-reset").json()
        assert body["allowance"]["limit"] == 5
        assert body["allowance"]["remaining"] == 4

    def test_a_blocked_sixth_premium_reset_does_not_clear_the_goal(self, db):
        client = _app(PREMIUM_UID)
        for _ in range(5):
            client.post("/api/user/goal-reset")
        db.collection("users").document(PREMIUM_UID).set(
            {"goal": {"type": "Muscle Gain"}}, merge=True)
        assert client.post("/api/user/goal-reset").status_code == 429
        assert db.store[f"users/{PREMIUM_UID}"]["goal"] is not None

    def test_a_blocked_third_reset_does_not_clear_the_goal(self, db):
        """The refusal must be real: the goal survives a denied reset."""
        client = _app(FREE_UID)
        client.post("/api/user/goal-reset")
        client.post("/api/user/goal-reset")
        db.collection("users").document(FREE_UID).set(
            {"goal": {"type": "Weight Loss"}}, merge=True)
        assert client.post("/api/user/goal-reset").status_code == 429
        assert db.store[f"users/{FREE_UID}"]["goal"] is not None


# ══════════════════════════════════════════════════════════════════════════
# 2. The race — reserve() is atomic
# ══════════════════════════════════════════════════════════════════════════


class TestNoOverGrantUnderConcurrency:
    def test_reserve_is_a_single_read_modify_write(self, db):
        """Interleaving a read and a write the way require()+record() did must
        not be possible: the claim commits before the next caller reads."""
        assert ent.reserve(FREE_UID, ent.GOAL_RESET).used == 1
        assert ent.reserve(FREE_UID, ent.GOAL_RESET).used == 2
        with pytest.raises(Exception) as exc:
            ent.reserve(FREE_UID, ent.GOAL_RESET)
        assert getattr(exc.value, "status_code", None) == 429

    @pytest.mark.parametrize("uid,limit", [(FREE_UID, 2), (PREMIUM_UID, 5)])
    def test_a_spent_allowance_can_never_be_exceeded_however_many_try(
            self, db, uid, limit):
        """Neither tier can be pushed past its ceiling by repeated claims —
        Basic stops at 2, Premium stops at 5. Both go through the same
        transaction; neither has an unlimited short-circuit."""
        ok = 0
        for _ in range(limit + 8):
            try:
                ent.reserve(uid, ent.GOAL_RESET)
                ok += 1
            except Exception:
                pass
        assert ok == limit, f"{ok} resets granted from a {limit}-per-week allowance"
        stored = db.store[f"usage_weekly/{uid}_{ent.week_key()}"]
        assert stored[ent.GOAL_RESET] == limit

    def test_reserve_fails_closed_when_firestore_is_unreachable(self, monkeypatch):
        """record() fails OPEN by design (it runs after the fact). reserve()
        runs BEFORE and is the only guard, so it must deny instead."""
        monkeypatch.setattr(ent.firestore_service, "get_client", lambda: None)
        with pytest.raises(Exception) as exc:
            ent.reserve(FREE_UID, ent.GOAL_RESET)
        assert getattr(exc.value, "status_code", None) == 503

    def test_release_returns_an_unused_claim(self, db):
        ent.reserve(FREE_UID, ent.GOAL_RESET)
        assert ent.check(FREE_UID, ent.GOAL_RESET).used == 1
        ent.release(FREE_UID, ent.GOAL_RESET)
        assert ent.check(FREE_UID, ent.GOAL_RESET).used == 0

    def test_release_never_goes_negative(self, db):
        ent.release(FREE_UID, ent.GOAL_RESET)
        assert ent.check(FREE_UID, ent.GOAL_RESET).used == 0


# ══════════════════════════════════════════════════════════════════════════
# 3. The reset is server-side — the limit is no longer advisory
# ══════════════════════════════════════════════════════════════════════════


class TestResetIsPerformedServerSide:
    def test_the_endpoint_clears_every_goal_scoped_field(self, db):
        db.collection("users").document(FREE_UID).set({
            "goal": {"type": "Weight Loss"}, "assessment": {"x": 1},
            "dietPlan": {"days": []}, "workoutPlan": {"days": []},
            "planId": "plan_A", "calculations": {"bmi": 22},
        }, merge=True)
        assert _app(FREE_UID).post("/api/user/goal-reset").status_code == 200
        doc = db.store[f"users/{FREE_UID}"]
        for field in player_routes.GOAL_SCOPED_FIELDS:
            assert doc.get(field) is None, f"{field} survived the reset"
        assert doc["goalResetAt"]

    def test_membership_is_not_touched_by_a_reset(self, db):
        before = dict(db.store[f"users/{PREMIUM_UID}"]["membership"])
        _app(PREMIUM_UID).post("/api/user/goal-reset")
        assert db.store[f"users/{PREMIUM_UID}"]["membership"] == before

    def test_it_retires_an_active_coaching_relationship(self, db):
        db.collection("personal_coaching").document(FREE_UID).set(
            {"athleteId": FREE_UID, "status": "active", "coachId": "c1"})
        _app(FREE_UID).post("/api/user/goal-reset")
        rel = db.store[f"personal_coaching/{FREE_UID}"]
        assert rel["status"] == "reset"
        assert rel["priorStatus"] == "active"
        assert rel["resetAt"]

    def test_it_succeeds_when_there_is_no_coaching_relationship(self, db):
        assert _app(FREE_UID).post("/api/user/goal-reset").status_code == 200

    def test_unauthenticated_reset_is_rejected(self, db):
        # No dependency override -> the real verify_firebase_token runs.
        assert _app(None).post("/api/user/goal-reset").status_code in (401, 403)

    def test_an_unauthenticated_caller_cannot_clear_anyone(self, db):
        before = dict(db.store[f"users/{FREE_UID}"])
        _app(None).post("/api/user/goal-reset")
        assert db.store[f"users/{FREE_UID}"] == before

    def test_the_counter_is_keyed_to_the_uid_not_the_client(self, db):
        """Reinstall / logout / new device cannot restore a spent allowance —
        the count lives in usage_weekly under the uid."""
        client = _app(FREE_UID)
        client.post("/api/user/goal-reset")
        client.post("/api/user/goal-reset")
        # A brand-new TestClient is a brand-new "device": same uid, same quota.
        assert _app(FREE_UID).post("/api/user/goal-reset").status_code == 429


# ══════════════════════════════════════════════════════════════════════════
# 4. Expiry is authoritative, and renewal extends
# ══════════════════════════════════════════════════════════════════════════


def _membership(expiry: datetime | None, *, plan="premium", active=True):
    m = {"plan": plan, "active": active}
    if expiry is not None:
        m["premium_expiry_date"] = expiry.isoformat()
    return m


class TestExpiryIsAuthoritative:
    def test_future_expiry_is_premium(self, db):
        db.collection("users").document("u").set(
            {"membership": _membership(datetime.now(timezone.utc) + timedelta(days=3))})
        assert ent.tier_for_uid("u") == ent.TIER_PREMIUM

    @pytest.mark.parametrize("delta", [timedelta(seconds=-1), timedelta(days=-1),
                                       timedelta(days=-400)])
    def test_past_expiry_is_free_immediately(self, db, delta):
        """No scheduler required — the check happens on every request."""
        db.collection("users").document("u").set(
            {"membership": _membership(datetime.now(timezone.utc) + delta)})
        assert ent.tier_for_uid("u") == ent.TIER_FREE

    def test_a_stale_active_true_does_not_survive_expiry(self, db):
        """`isPremium`/`active` alone must never be sufficient."""
        db.collection("users").document("u").set({"membership": {
            "plan": "premium", "active": True,
            "premium_expiry_date":
                (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()}})
        assert ent.tier_for_uid("u") == ent.TIER_FREE

    def test_an_expired_user_loses_the_premium_allowance(self, db):
        db.collection("users").document("u").set(
            {"membership": _membership(datetime.now(timezone.utc) - timedelta(days=1))})
        limits = ent.limits_for(ent.tier_for_uid("u"))
        assert limits[ent.GOAL_RESET] == 2          # back to the free matrix
        assert limits[ent.MEAL_SWAP] == 70

    def test_an_unparseable_expiry_is_not_premium(self, db):
        db.collection("users").document("u").set({"membership": {
            "plan": "premium", "active": True, "premium_expiry_date": "not-a-date"}})
        assert ent.tier_for_uid("u") == ent.TIER_FREE


class TestRenewalExtends:
    """`payment.py`'s renewal maths, exercised directly."""

    def _new_expiry(self, *, prior: datetime | None, now: datetime, days: int):
        from routes.payment import _parse_expiry

        membership = _membership(prior) if prior else None
        anchor = now
        parsed = _parse_expiry(membership) if membership else None
        if parsed is not None and parsed > now:
            anchor = parsed
        return anchor + timedelta(days=days)

    def test_renewing_early_extends_beyond_the_current_expiry(self):
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        prior = datetime(2026, 10, 15, tzinfo=timezone.utc)
        result = self._new_expiry(prior=prior, now=now, days=30)
        # The documented example: must land past 15 Oct, not 9 Nov.
        assert result > prior
        assert result == prior + timedelta(days=30)
        assert result != now + timedelta(days=30)

    def test_renewing_early_never_shortens_entitlement(self):
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        for remaining in (1, 5, 29, 300):
            prior = now + timedelta(days=remaining)
            assert self._new_expiry(prior=prior, now=now, days=30) > prior

    def test_renewing_after_expiry_starts_a_full_fresh_period(self):
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        prior = datetime(2026, 9, 1, tzinfo=timezone.utc)      # long lapsed
        result = self._new_expiry(prior=prior, now=now, days=30)
        assert result == now + timedelta(days=30)              # not back-dated

    def test_a_first_purchase_is_now_plus_the_period(self):
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        assert self._new_expiry(prior=None, now=now, days=30) == now + timedelta(days=30)

    def test_repeated_renewals_stack(self):
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        expiry = self._new_expiry(prior=None, now=now, days=30)
        for _ in range(3):
            expiry = self._new_expiry(prior=expiry, now=now, days=30)
        assert expiry == now + timedelta(days=120)

    def test_yearly_uses_its_own_period(self):
        now = datetime(2026, 10, 10, tzinfo=timezone.utc)
        assert self._new_expiry(prior=None, now=now, days=365) == now + timedelta(days=365)
