"""
ZITLAS — Wallet freeze + Razorpay-only Premium (backend/tests/test_wallet_freeze.py)

TWO BUSINESS RULES, PINNED AT THE ONLY LAYER THAT CAN ENFORCE THEM.

1. THE WALLET MOVES NO MONEY THIS RELEASE. No deposit, no withdrawal, no
   transfer, no spending, no earning. Frozen is not deleted and not hidden:
   balances, `users/{uid}.wallet` and `wallet_transactions` all stay readable,
   because an athlete must still be able to see their own money and records.

2. PREMIUM IS BOUGHT FROM RAZORPAY, AND ONLY FROM RAZORPAY. Not from a wallet
   balance, not from a client saying `premium = true`, not from a tampered
   amount, and not twice from one payment.

Every test here calls the real route function, so the guard is proven where a
request actually lands rather than in the config module that declares it.

Run: python -m pytest tests/test_wallet_freeze.py -q
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import wallet_config                                     # noqa: E402
import routes.payment as payment_routes                  # noqa: E402
from services import firestore_service                    # noqa: E402
from google.cloud import firestore                       # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

UID = "athlete1"
OTHER_UID = "athlete2"


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    client.collection("users").document(UID).set({
        "wallet": {"balance": 5000.0, "reserved": 0.0,
                   "total_added": 5000.0, "total_spent": 0.0},
        "membership": {"plan": "free"},
    })
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    # Same transaction shim tests/test_payment.py uses — the real decorator
    # expects a live client's internals.
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    return client


@pytest.fixture
def client():
    app = FastAPI()
    app.include_router(payment_routes.router, prefix="/api/payment")
    app.dependency_overrides[payment_routes.verify_firebase_token] = lambda: {
        "uid": UID, "email": "a@b.c", "name": "Athlete",
    }
    return TestClient(app)


# ── 1. The wallet is frozen ────────────────────────────────────────────────

class TestWalletFrozen:
    def test_the_switch_is_on_for_launch(self):
        assert wallet_config.WALLET_FROZEN is True

    def test_adding_money_is_refused(self, db, client):
        res = client.post("/api/payment/create-order", json={"amount": 500})
        assert res.status_code == 503
        assert res.json()["detail"]["error"] == "wallet_frozen"

    def test_crediting_the_wallet_is_refused(self, db, client):
        """The other half of a recharge. Refused even with a perfectly good
        signature — there is no path that puts money in."""
        res = client.post("/api/payment/verify", json={
            "razorpay_order_id": "order_x",
            "razorpay_payment_id": "pay_x",
            "razorpay_signature": "sig_x",
        })
        assert res.status_code == 503
        assert res.json()["detail"]["error"] == "wallet_frozen"

    def test_a_refused_recharge_leaves_the_balance_untouched(self, db, client):
        client.post("/api/payment/create-order", json={"amount": 500})
        client.post("/api/payment/verify", json={
            "razorpay_order_id": "o", "razorpay_payment_id": "p",
            "razorpay_signature": "s",
        })
        wallet = db.collection("users").document(UID).get().to_dict()["wallet"]
        assert wallet["balance"] == 5000.0
        assert wallet["total_added"] == 5000.0

    def test_the_refusal_says_why_and_is_retryable(self, db, client):
        """503, not 403: the athlete is entitled to their wallet, the feature
        is simply unavailable — and it is coming back."""
        detail = client.post("/api/payment/create-order",
                             json={"amount": 500}).json()["detail"]
        assert "message" in detail and detail["message"]
        assert "operation" in detail

    def test_existing_wallet_data_is_never_deleted(self, db, client):
        """Freezing must preserve every balance and record for V2."""
        client.post("/api/payment/create-order", json={"amount": 500})
        user = db.collection("users").document(UID).get().to_dict()
        assert user["wallet"]["balance"] == 5000.0
        assert user["wallet"]["total_added"] == 5000.0


class TestZeroRupeePathsStillWork:
    """The guards fire on MONEY, not on the feature.

    With CLIENT_TRIAL_MODE / PLATFORM_CHARGES_FREE on, expert services and
    coaching already cost ₹0 and write no wallet field at all. Freezing the
    wallet must not take those working, free features offline with it.
    """

    def test_a_zero_charge_is_allowed(self):
        wallet_config.assert_wallet_unfrozen("t", 0.0)  # must not raise

    def test_a_negative_charge_is_allowed(self):
        wallet_config.assert_wallet_unfrozen("t", -1.0)

    def test_any_positive_charge_is_refused(self):
        with pytest.raises(HTTPException) as excinfo:
            wallet_config.assert_wallet_unfrozen("t", 0.01)
        assert excinfo.value.status_code == 503

    def test_an_amountless_operation_is_always_refused(self):
        """A recharge exists only to move money — there is no ₹0 version."""
        with pytest.raises(HTTPException):
            wallet_config.assert_wallet_unfrozen("wallet_recharge")

    def test_unfreezing_restores_every_path(self, monkeypatch):
        monkeypatch.setattr(wallet_config, "WALLET_FROZEN", False)
        wallet_config.assert_wallet_unfrozen("recharge")
        wallet_config.assert_wallet_unfrozen("debit", 999.0)


# ── 2. Premium: Razorpay only ──────────────────────────────────────────────

class TestPremiumIsRazorpayOnly:
    def test_a_wallet_balance_cannot_buy_premium(self, db, client, monkeypatch):
        """CASE 13/14. The athlete holds ₹5000 — more than the ₹149 plan —
        and it buys nothing, because no membership path reads the wallet."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: False)
        res = client.post("/api/payment/membership/verify", json={
            "razorpay_order_id": "o", "razorpay_payment_id": "p",
            "razorpay_signature": "forged",
        })
        assert res.status_code == 400
        user = db.collection("users").document(UID).get().to_dict()
        assert user["membership"]["plan"] == "free"
        assert user["wallet"]["balance"] == 5000.0, "the wallet was not touched"

    def test_membership_verify_never_reads_the_wallet(self):
        """Structural, not behavioural: the handler's source must contain no
        wallet mutation at all, so no future edit can quietly add one."""
        import inspect
        src = inspect.getsource(payment_routes.verify_membership_payment)
        assert '"wallet"' not in src and "wallet[" not in src

    def test_an_invalid_signature_does_not_activate_premium(self, db, client, monkeypatch):
        """CASE 9."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: False)
        res = client.post("/api/payment/membership/verify", json={
            "razorpay_order_id": "o", "razorpay_payment_id": "p",
            "razorpay_signature": "wrong",
        })
        assert res.status_code == 400
        assert res.json()["detail"] == "signature_mismatch"
        assert db.collection("users").document(UID).get().to_dict()[
            "membership"]["plan"] == "free"

    def test_a_payment_for_someone_elses_order_is_rejected(self, db, client, monkeypatch):
        """CASE 12 — a modified user id. The order records the uid that
        created it; the token decides who is asking."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: True)
        db.collection("razorpay_orders").document("order_other").set({
            "orderId": "order_other", "uid": OTHER_UID, "amountPaise": 14900,
            "currency": "INR", "status": "created", "purpose": "membership",
            "billing": "monthly",
        })
        res = client.post("/api/payment/membership/verify", json={
            "razorpay_order_id": "order_other", "razorpay_payment_id": "p",
            "razorpay_signature": "ok",
        })
        assert res.status_code == 403
        assert db.collection("users").document(UID).get().to_dict()[
            "membership"]["plan"] == "free"

    def test_a_wallet_recharge_order_cannot_be_redeemed_as_premium(self, db, client, monkeypatch):
        """The purpose is stamped at creation and re-checked here, so a
        ₹1 wallet order cannot be swapped in for a ₹149 subscription."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: True)
        db.collection("razorpay_orders").document("order_w").set({
            "orderId": "order_w", "uid": UID, "amountPaise": 100,
            "currency": "INR", "status": "created", "purpose": "wallet",
        })
        res = client.post("/api/payment/membership/verify", json={
            "razorpay_order_id": "order_w", "razorpay_payment_id": "p",
            "razorpay_signature": "ok",
        })
        assert res.status_code == 400
        assert res.json()["detail"] == "not_a_membership_order"

    def test_an_unknown_order_cannot_activate_premium(self, db, client, monkeypatch):
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: True)
        res = client.post("/api/payment/membership/verify", json={
            "razorpay_order_id": "never_created", "razorpay_payment_id": "p",
            "razorpay_signature": "ok",
        })
        assert res.status_code == 404

    def test_the_price_comes_from_the_server_not_the_request(self):
        """CASE 11 — a modified amount. The order body carries only a billing
        period; the rupee figure is looked up server-side."""
        import inspect
        fields = payment_routes.MembershipOrderBody.model_fields
        assert set(fields) <= {"billing"}, (
            "a membership order must not accept an amount from the client")
        src = inspect.getsource(payment_routes.create_membership_order)
        assert "MEMBERSHIP_PRICES_RUPEES[billing]" in src

    def test_a_successful_payment_activates_premium(self, db, client, monkeypatch):
        """CASES 1-6 — the whole happy path, at the step that decides."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: True)
        db.collection("razorpay_orders").document("order_ok").set({
            "orderId": "order_ok", "uid": UID, "amountPaise": 14900,
            "currency": "INR", "status": "created", "purpose": "membership",
            "billing": "monthly",
        })
        res = client.post("/api/payment/membership/verify", json={
            "razorpay_order_id": "order_ok", "razorpay_payment_id": "pay_ok",
            "razorpay_signature": "ok",
        })
        assert res.status_code == 200

        membership = db.collection("users").document(UID).get().to_dict()["membership"]
        assert membership["plan"] == "premium"
        assert membership["active"] is True
        assert membership["payment_id"] == "pay_ok"
        assert membership["premium_expiry_date"]

    def test_activation_is_idempotent(self, db, client, monkeypatch):
        """CASE 10 — a duplicate callback or a retried request must not grant
        a second term."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: True)
        db.collection("razorpay_orders").document("order_dup").set({
            "orderId": "order_dup", "uid": UID, "amountPaise": 14900,
            "currency": "INR", "status": "created", "purpose": "membership",
            "billing": "monthly",
        })
        body = {"razorpay_order_id": "order_dup",
                "razorpay_payment_id": "pay_dup", "razorpay_signature": "ok"}

        first = client.post("/api/payment/membership/verify", json=body)
        assert first.status_code == 200
        expiry = db.collection("users").document(UID).get().to_dict()[
            "membership"]["premium_expiry_date"]

        for _ in range(3):
            again = client.post("/api/payment/membership/verify", json=body)
            assert again.status_code == 200
            assert again.json()["already"] is True

        assert db.collection("users").document(UID).get().to_dict()[
            "membership"]["premium_expiry_date"] == expiry, (
            "a repeated callback extended the subscription")

    def test_one_audit_record_per_payment(self, db, client, monkeypatch):
        """The ledger id is derived from the Razorpay payment id, so a retry
        overwrites its own row instead of adding another."""
        monkeypatch.setattr(payment_routes.razorpay_service,
                            "verify_signature", lambda o, p, s: True)
        db.collection("razorpay_orders").document("order_led").set({
            "orderId": "order_led", "uid": UID, "amountPaise": 14900,
            "currency": "INR", "status": "created", "purpose": "membership",
            "billing": "monthly",
        })
        body = {"razorpay_order_id": "order_led",
                "razorpay_payment_id": "pay_led", "razorpay_signature": "ok"}
        client.post("/api/payment/membership/verify", json=body)
        client.post("/api/payment/membership/verify", json=body)

        rows = [d for d in db.collection("wallet_transactions").stream()
                if (d.to_dict() or {}).get("razorpayPaymentId") == "pay_led"]
        assert len(rows) == 1
        assert rows[0].to_dict()["method"] == "razorpay"
