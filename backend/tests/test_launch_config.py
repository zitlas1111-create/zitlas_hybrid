"""
ZITLAS — the FINAL launch business model (backend/tests/test_launch_config.py)

    | Feature             | Launch State | Payment       |
    |---------------------|--------------|---------------|
    | Premium             | ACTIVE       | Razorpay ONLY |
    | Personal Coaching   | ACTIVE       | FREE          |
    | Expert Verification | FROZEN       | NO PAYMENT    |
    | Wallet              | FROZEN       | DISABLED      |
    | Expert Payouts      | FROZEN       | DISABLED      |

PREMIUM IS THE ONLY PAID FEATURE AT LAUNCH.

The payment engine underneath — Razorpay orders, HMAC verification, escrow,
the wallet ledger, idempotency, the platform-fee split — is deliberately kept
whole for future monetization. What these tests pin is POLICY: which of those
paths is allowed to run today, enforced on the SERVER so a client that ignores
the UI is refused just the same.

Run: python -m pytest tests/test_launch_config.py -q
"""

from __future__ import annotations

import inspect
import os
import sys

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import launch_config as lc                                # noqa: E402
import routes.coaching as coaching_routes                 # noqa: E402
import routes.payment as payment_routes                   # noqa: E402
import routes.system as system_routes                     # noqa: E402
from services import firestore_service                    # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
EXPERT = "expert_1"


# ── The matrix itself ────────────────────────────────────────────────────────

class TestTheMatrix:
    def test_premium_is_active_and_paid_through_razorpay(self):
        assert lc.PREMIUM_ENABLED is True
        assert lc.PREMIUM_PAYMENT_REQUIRED is True
        assert lc.PREMIUM_PROVIDER == "razorpay"

    def test_personal_coaching_is_active_and_free(self):
        assert lc.PERSONAL_COACHING_ENABLED is True
        assert lc.PERSONAL_COACHING_PAYMENT_REQUIRED is False
        assert lc.PERSONAL_COACHING_PRICE == 0

    def test_expert_services_are_free(self):
        assert lc.EXPERT_SERVICES_PAYMENT_REQUIRED is False

    def test_expert_verification_is_frozen_and_unpaid(self):
        assert lc.EXPERT_VERIFICATION_ENABLED is False
        assert lc.EXPERT_VERIFICATION_PAYMENT_REQUIRED is False

    def test_wallet_is_frozen(self):
        assert lc.WALLET_ENABLED is False

    def test_expert_payouts_are_frozen(self):
        assert lc.EXPERT_PAYOUTS_ENABLED is False

    def test_premium_is_the_only_paid_feature(self):
        """The whole launch model in one assertion."""
        paid = {
            "premium": lc.PREMIUM_PAYMENT_REQUIRED,
            "personalCoaching": lc.PERSONAL_COACHING_PAYMENT_REQUIRED,
            "expertServices": lc.EXPERT_SERVICES_PAYMENT_REQUIRED,
            "expertVerification": lc.EXPERT_VERIFICATION_PAYMENT_REQUIRED,
        }
        assert [k for k, v in paid.items() if v] == ["premium"]

    def test_the_matrix_is_served_to_the_clients(self):
        """So the website and the app cannot describe a different model than
        the one the server enforces."""
        app = FastAPI()
        app.include_router(system_routes.router, prefix="/api/system")
        body = TestClient(app).get("/api/system/launch-config").json()

        assert body["premium"]["paymentRequired"] is True
        assert body["premium"]["provider"] == "razorpay"
        assert body["personalCoaching"]["paymentRequired"] is False
        assert body["personalCoaching"]["price"] == 0
        assert body["wallet"]["enabled"] is False
        assert body["expertVerification"]["enabled"] is False
        assert body["expertPayouts"]["enabled"] is False


# ── 2-5. Personal Coaching is free, and touches no money ─────────────────────

@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    client.collection("users").document(ATHLETE).set({
        "personalInfo": {"name": "Athlete"},
        # Deliberately EMPTY: a free feature must work for somebody who has
        # never had a rupee in their wallet.
        "wallet": {"balance": 0.0, "reserved": 0.0},
    })
    client.collection("experts").document(EXPERT).set({
        "name": "Coach", "approved": True,
        "pricing": {"coachingDietPrice": 499, "coachingTrainingPrice": 699,
                    "coachingCompletePrice": 999},
    })
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    return client


@pytest.fixture
def coaching_client():
    app = FastAPI()
    app.include_router(coaching_routes.router, prefix="/api/coaching")
    app.dependency_overrides[coaching_routes.verify_firebase_token] = lambda: {
        "uid": ATHLETE, "email": None, "name": "Athlete",
    }
    return TestClient(app)


class TestPersonalCoachingIsFree:
    def test_the_server_prices_coaching_at_zero(self):
        """CASE 2. Whatever an expert's `pricing` map says, and whatever a
        client asks for, the launch price is ₹0."""
        assert lc.coaching_price(999) == 0.0
        assert lc.coaching_price(0) == 0.0
        assert lc.coaching_price(1_000_000) == 0.0

    def test_a_request_with_an_empty_wallet_succeeds(self, db, coaching_client):
        """CASE 2. The athlete has ₹0 and no reservation — and coaching works."""
        res = coaching_client.post("/api/coaching/request", json={
            "expertId": EXPERT, "planType": "complete",
        })
        assert res.status_code == 200, res.text
        assert res.json()["amount"] == 0

    def test_no_wallet_deduction_happens(self, db, coaching_client):
        """CASE 4."""
        coaching_client.post("/api/coaching/request", json={
            "expertId": EXPERT, "planType": "complete",
        })
        wallet = db.collection("users").document(ATHLETE).get().to_dict()["wallet"]
        assert wallet["balance"] == 0.0
        assert wallet.get("reserved", 0) == 0.0, (
            "a free request must not reserve anything")

    def test_no_payment_transaction_is_written(self, db, coaching_client):
        """CASE 5. A ₹0 ledger row for a payment that never happened is a
        false record, not a harmless one."""
        coaching_client.post("/api/coaching/request", json={
            "expertId": EXPERT, "planType": "complete",
        })
        rows = list(db.collection("wallet_transactions").stream())
        assert rows == []

    def test_no_insufficient_balance_path_can_be_reached(self, db, coaching_client):
        """CASE 10. The athlete holds ₹0; a 402 would mean a free feature sent
        them to a wallet they cannot even use."""
        res = coaching_client.post("/api/coaching/request", json={
            "expertId": EXPERT, "planType": "complete",
        })
        assert res.status_code != 402

    def test_charging_for_coaching_is_refused_outright(self):
        """CASE 3/4 belt-and-braces: if a future edit ever routes a non-zero
        coaching amount at the wallet, the server refuses instead of taking
        the athlete's money."""
        with pytest.raises(HTTPException) as excinfo:
            lc.assert_coaching_charge_allowed(499)
        assert excinfo.value.status_code == 503
        assert excinfo.value.detail["error"] == "coaching_is_free"

    def test_zero_is_never_refused(self):
        """CASE 10. Free services must pass straight through."""
        lc.assert_coaching_charge_allowed(0)
        lc.assert_expert_service_charge_allowed(0)

    def test_coaching_never_calls_the_charge_endpoint(self):
        """CASE 3 — the server-side equivalent of "does not call
        attemptCharge". `/api/payment/charge` is the charge path; the
        coaching router must not reach for it."""
        src = inspect.getsource(coaching_routes)
        assert "charge_service" not in src
        assert "/api/payment/charge" not in src


# ── 6-9. Frozen: verification, wallet, payouts ───────────────────────────────

class TestFrozenFeatures:
    def test_there_is_no_expert_verification_payment_endpoint(self):
        """CASE 6. Not "it is guarded" — it does not exist. This fails the day
        somebody adds one without revisiting the launch model."""
        import pathlib
        import re
        hits = []
        for f in pathlib.Path("routes").glob("*.py"):
            src = f.read_text(encoding="utf-8")
            for m in re.finditer(r'@router\.\w+\("([^"]*)"', src):
                path = m.group(1).lower()
                if "verif" in path and any(
                        w in path for w in ("pay", "fee", "order", "charge")):
                    hits.append(f"{f.name}{m.group(1)}")
        assert hits == []

    def test_a_verification_fee_is_refused(self, ):
        """CASE 6. And if one is ever wired up, the guard is already there."""
        with pytest.raises(HTTPException) as excinfo:
            lc.assert_expert_verification_payment_allowed()
        assert excinfo.value.detail["error"] == "expert_verification_is_free"

    def test_public_expert_applications_are_closed(self):
        with pytest.raises(HTTPException) as excinfo:
            lc.assert_expert_verification_open()
        assert excinfo.value.detail["error"] == "expert_verification_frozen"

    def test_wallet_deposit_is_unavailable(self):
        """CASE 7."""
        with pytest.raises(HTTPException) as excinfo:
            lc.assert_wallet_enabled("wallet_recharge")
        assert excinfo.value.status_code == 503
        assert excinfo.value.detail["error"] == "wallet_frozen"

    def test_wallet_withdrawal_is_unavailable(self):
        """CASE 8. Withdrawal has no endpoint either — the guard covers the
        operation by name so one cannot be added silently."""
        with pytest.raises(HTTPException):
            lc.assert_wallet_enabled("wallet_withdraw", 100.0)

    def test_expert_payouts_are_unavailable(self):
        """CASE 9."""
        with pytest.raises(HTTPException) as excinfo:
            lc.assert_payouts_enabled()
        assert excinfo.value.detail["error"] == "expert_payouts_frozen"

    def test_no_payout_or_withdrawal_endpoint_exists(self):
        """CASE 9. `/api/coaching/withdraw` withdraws a coaching REQUEST, not
        money — it must stay the only 'withdraw' in the API surface."""
        import pathlib
        import re
        money_words = ("payout", "withdraw-funds", "withdrawal", "cash-out",
                       "transfer")
        hits = []
        for f in pathlib.Path("routes").glob("*.py"):
            src = f.read_text(encoding="utf-8")
            for m in re.finditer(r'@router\.\w+\("([^"]*)"', src):
                if any(w in m.group(1).lower() for w in money_words):
                    hits.append(f"{f.name}{m.group(1)}")
        assert hits == []


# ── 11-12. Nothing that already worked was broken ────────────────────────────

class TestNoCollateralDamage:
    def test_the_payment_engine_is_still_present(self):
        """CASE 11. Frozen, not deleted — the whole point of the launch
        config. These are what V2 turns back on."""
        assert hasattr(payment_routes, "create_order")
        assert hasattr(payment_routes, "verify_payment")
        assert hasattr(payment_routes, "charge_service")
        assert hasattr(payment_routes, "create_membership_order")
        assert hasattr(payment_routes, "verify_membership_payment")

    def test_the_commission_split_is_kept_for_v2(self):
        from services import coaching_service
        assert coaching_service.PLATFORM_FEE_PERCENT == 0.20

    def test_premium_pricing_is_untouched(self):
        assert payment_routes.MEMBERSHIP_PRICES_RUPEES["monthly"] == 149

    def test_the_entitlement_matrix_is_untouched(self):
        """CASE 12's neighbour: free 2/70/7, premium 5/unlimited/27."""
        from services import entitlements as ent
        free = ent.limits_for(ent.TIER_FREE)
        premium = ent.limits_for(ent.TIER_PREMIUM)
        assert (free[ent.GOAL_RESET], free[ent.MEAL_SWAP], free[ent.RECIPE]) == (2, 70, 7)
        assert (premium[ent.GOAL_RESET], premium[ent.RECIPE]) == (5, 27)
        assert premium[ent.MEAL_SWAP] is None

    def test_expert_authorization_is_untouched(self):
        """CASE 12. Role resolution still requires the custom claim AND the
        approved flag, and still fails closed."""
        from services import auth_service
        assert hasattr(auth_service, "is_approved_expert")
        assert hasattr(auth_service, "require_expert")
        src = inspect.getsource(auth_service.is_expert)
        assert "approved" in src

    def test_flipping_the_config_restores_paid_coaching(self, monkeypatch):
        """The engine is intact: one flag turns monetization back on."""
        monkeypatch.setattr(lc, "PERSONAL_COACHING_PAYMENT_REQUIRED", True)
        assert lc.coaching_price(499) == 499.0
        lc.assert_coaching_charge_allowed(499)  # must not raise
