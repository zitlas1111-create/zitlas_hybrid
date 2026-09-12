"""
ZITLAS — the wallet as the internal payment balance
(backend/tests/test_wallet_premium.py)

Two payment flows, kept strictly apart:

    Razorpay -> Add Funds -> WALLET      POST /api/payment/create-order + /verify
    WALLET   -> ₹149      -> PREMIUM     POST /api/payment/membership/purchase-with-wallet

The second one never touches Razorpay. When the balance covers the price the
athlete must not see a checkout sheet — the money they already hold pays.

THE TWO INVARIANTS these tests exist to protect, both enforced inside ONE
Firestore transaction so neither can hold without the other:

    * Premium is never activated without the wallet actually being charged.
    * The wallet is never charged without Premium actually being activated.

MONEY REPRESENTATION, stated plainly: the stored balance is a FLOAT in rupees
(`users/{uid}.wallet.balance`) — a legacy schema shared with coaching escrow
and the recharge ledger, deliberately NOT migrated here. Every affordability
DECISION and the subtraction itself happen in integer paise; only the result is
written back to the existing float field, rounded to paise.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).parent.parent))

import routes.payment as payment_routes  # noqa: E402
from services import entitlements as ent  # noqa: E402
from services import firestore_service, razorpay_service  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

UID = "athlete_1"
OTHER = "athlete_2"
KEY_SECRET = "test_secret_for_hmac"
PRICE_PAISE = 14900


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(ent.firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    monkeypatch.setattr(razorpay_service, "_credentials",
                        lambda: ("test_key_id", KEY_SECRET))
    return client


def _app(uid: str = UID) -> TestClient:
    app = FastAPI()
    app.include_router(payment_routes.router, prefix="/api/payment")
    app.dependency_overrides[payment_routes.verify_firebase_token] = lambda: {
        "uid": uid, "email": None, "name": "Athlete"}
    return TestClient(app)


def _fund(db, rupees: float, *, uid: str = UID, reserved: float = 0.0,
          membership: dict | None = None):
    db.collection("users").document(uid).set({
        "wallet": {"balance": rupees, "reserved": reserved,
                   "total_added": rupees, "total_spent": 0.0},
        "membership": membership or {"plan": "free"},
    })


def _balance(db, uid: str = UID) -> float:
    return db.store[f"users/{uid}"]["wallet"]["balance"]


def _membership(db, uid: str = UID) -> dict:
    return db.store[f"users/{uid}"].get("membership") or {}


def _buy(client: TestClient, billing: str = "monthly", key: str | None = None):
    body: dict = {"billing": billing}
    if key is not None:
        body["idempotencyKey"] = key
    return client.post("/api/payment/membership/purchase-with-wallet", json=body)


def _sign(order_id: str, payment_id: str) -> str:
    return hmac.new(KEY_SECRET.encode(),
                    f"{order_id}|{payment_id}".encode(), hashlib.sha256).hexdigest()


def _ledger(db) -> list[dict]:
    return [v for k, v in db.store.items()
            if k.startswith("wallet_transactions/") and v]


# ══════════════════════════════════════════════════════════════════════════
# FLOW 1 — Razorpay tops the wallet up
# ══════════════════════════════════════════════════════════════════════════


class TestWalletTopUp:
    def _order(self, db, order_id="order_1", *, uid=UID, paise=50000,
               status="created", purpose="wallet_topup"):
        row = {"orderId": order_id, "uid": uid, "amountPaise": paise,
               "currency": "INR", "status": status,
               "createdAt": datetime.now(timezone.utc).isoformat()}
        if purpose is not None:
            row["purpose"] = purpose
        db.collection("razorpay_orders").document(order_id).set(row)

    def _verify(self, client, order_id="order_1", payment_id="pay_1",
                signature=None):
        return client.post("/api/payment/verify", json={
            "razorpay_order_id": order_id, "razorpay_payment_id": payment_id,
            "razorpay_signature": signature or _sign(order_id, payment_id)})

    def test_an_authenticated_user_can_create_a_topup_order(self, db, monkeypatch):
        captured = {}

        def fake_create(amount_paise, currency="INR", receipt=None):
            captured["paise"] = amount_paise
            return {"order_id": "order_x", "amount": amount_paise,
                    "currency": currency, "key_id": "k"}

        monkeypatch.setattr(razorpay_service, "create_order", fake_create)
        res = _app().post("/api/payment/create-order", json={"amount": 500})
        assert res.status_code == 200
        assert captured["paise"] == 50000              # server-computed paise
        row = db.store["razorpay_orders/order_x"]
        assert row["amountPaise"] == 50000
        assert row["purpose"] == "wallet_topup"        # now stamped
        assert row["uid"] == UID

    def test_a_verified_payment_credits_the_wallet(self, db):
        _fund(db, 0.0)
        self._order(db, paise=50000)
        res = self._verify(_app())
        assert res.status_code == 200
        assert _balance(db) == 500.0

    def test_the_amount_comes_from_the_stored_order_not_the_request(self, db):
        """The client sends no amount to /verify at all — it cannot inflate
        the credit."""
        _fund(db, 0.0)
        self._order(db, paise=10000)                   # ₹100 was actually paid
        self._verify(_app())
        assert _balance(db) == 100.0

    def test_repeated_verification_credits_only_once(self, db):
        _fund(db, 0.0)
        self._order(db, paise=50000)
        for _ in range(10):
            assert self._verify(_app()).status_code == 200
        assert _balance(db) == 500.0, "a replay credited the wallet twice"
        credits = [r for r in _ledger(db) if r.get("serviceType") == "wallet_recharge"]
        assert len(credits) == 1

    def test_an_invalid_signature_credits_nothing(self, db):
        _fund(db, 0.0)
        self._order(db)
        assert self._verify(_app(), signature="forged").status_code == 400
        assert _balance(db) == 0.0

    def test_another_users_order_cannot_be_redeemed(self, db):
        _fund(db, 0.0)
        _fund(db, 0.0, uid=OTHER)
        self._order(db, uid=OTHER)
        assert self._verify(_app(UID)).status_code == 403
        assert _balance(db, UID) == 0.0

    def test_an_uncompleted_order_credits_nothing(self, db):
        """No verification call ever arrives for a cancelled/failed payment,
        so the order simply stays 'created' and the balance never moves."""
        _fund(db, 0.0)
        self._order(db, status="created")
        assert _balance(db) == 0.0
        assert db.store["razorpay_orders/order_1"]["status"] == "created"

    def test_a_membership_order_can_never_credit_the_wallet(self, db):
        """THE CROSS-FLOW GUARD. A ₹149 membership order used to be redeemable
        here as ₹149 of wallet credit, because /verify never looked at
        `purpose`."""
        _fund(db, 0.0)
        self._order(db, paise=PRICE_PAISE, purpose="membership")
        res = self._verify(_app())
        assert res.status_code == 400
        assert res.json()["detail"] == "not_a_wallet_topup_order"
        assert _balance(db) == 0.0

    def test_a_legacy_order_without_a_purpose_still_works(self, db):
        """Orders created before `purpose` was stamped were wallet recharges
        by construction — this endpoint was the only thing that made them."""
        _fund(db, 0.0)
        self._order(db, paise=20000, purpose=None)
        assert self._verify(_app()).status_code == 200
        assert _balance(db) == 200.0


# ══════════════════════════════════════════════════════════════════════════
# FLOW 2 — the wallet buys Premium (no Razorpay)
# ══════════════════════════════════════════════════════════════════════════


class TestPremiumFromWallet:
    def test_a_funded_wallet_buys_premium(self, db):
        _fund(db, 500.0)
        res = _buy(_app())
        assert res.status_code == 200
        assert res.json()["success"] is True
        assert _membership(db)["plan"] == "premium"

    def test_exactly_149_is_deducted(self, db):
        _fund(db, 500.0)
        _buy(_app())
        assert _balance(db) == 351.0

    def test_an_exact_balance_is_enough(self, db):
        """₹149.00 buys a ₹149 plan — the boundary must not be off by a paise."""
        _fund(db, 149.0)
        assert _buy(_app()).status_code == 200
        assert _balance(db) == 0.0

    def test_premium_activates_immediately_with_the_premium_matrix(self, db):
        _fund(db, 500.0)
        assert ent.tier_for_uid(UID) == ent.TIER_FREE
        _buy(_app())
        assert ent.tier_for_uid(UID) == ent.TIER_PREMIUM
        limits = ent.limits_for(ent.tier_for_uid(UID))
        assert limits[ent.GOAL_RESET] == 5
        assert limits[ent.MEAL_SWAP] is ent.UNLIMITED
        assert limits[ent.RECIPE] == 27

    def test_the_period_is_thirty_days(self, db):
        _fund(db, 500.0)
        before = datetime.now(timezone.utc)
        _buy(_app())
        expiry = datetime.fromisoformat(_membership(db)["premium_expiry_date"])
        delta = expiry - before
        assert timedelta(days=29, hours=23) < delta <= timedelta(days=30, minutes=1)

    def test_it_records_that_the_wallet_paid(self, db):
        _fund(db, 500.0)
        _buy(_app())
        m = _membership(db)
        assert m["payment_method"] == "wallet"
        assert m["order_id"] is None            # no Razorpay order exists

    def test_no_razorpay_order_is_created(self, db, monkeypatch):
        """The whole point: a funded wallet must not open checkout."""
        def explode(*a, **k):
            raise AssertionError("Razorpay must not be involved")

        monkeypatch.setattr(razorpay_service, "create_order", explode)
        _fund(db, 500.0)
        assert _buy(_app()).status_code == 200
        assert not [k for k in db.store if k.startswith("razorpay_orders/")]

    def test_the_price_cannot_be_chosen_by_the_client(self, db):
        _fund(db, 500.0)
        res = _app().post("/api/payment/membership/purchase-with-wallet",
                          json={"billing": "monthly", "amount": 1, "price": 1})
        assert res.status_code == 200
        assert _balance(db) == 351.0            # ₹149, not ₹1

    def test_an_invented_billing_period_is_rejected(self, db):
        _fund(db, 500.0)
        res = _buy(_app(), billing="lifetime")
        assert res.status_code == 400
        assert _balance(db) == 500.0

    def test_a_yearly_purchase_charges_999(self, db):
        _fund(db, 2000.0)
        assert _buy(_app(), billing="yearly").status_code == 200
        assert _balance(db) == 1001.0


class TestInsufficientBalance:
    def test_it_returns_402_with_machine_readable_detail(self, db):
        _fund(db, 100.0)
        res = _buy(_app())
        assert res.status_code == 402
        detail = res.json()["detail"]
        assert detail["error"] == "insufficient_wallet_balance"
        assert detail["required"] == PRICE_PAISE
        assert detail["available"] == 10000

    def test_nothing_is_deducted(self, db):
        _fund(db, 100.0)
        _buy(_app())
        assert _balance(db) == 100.0

    def test_premium_is_not_activated(self, db):
        _fund(db, 100.0)
        _buy(_app())
        assert _membership(db).get("plan") != "premium"

    def test_no_ledger_row_is_written(self, db):
        _fund(db, 100.0)
        _buy(_app())
        assert _ledger(db) == []

    def test_an_existing_expiry_is_untouched(self, db):
        prior = datetime.now(timezone.utc) + timedelta(days=10)
        _fund(db, 10.0, membership={
            "plan": "premium", "active": True, "billing": "monthly",
            "premium_expiry_date": prior.isoformat()})
        assert _buy(_app()).status_code == 402
        assert _membership(db)["premium_expiry_date"] == prior.isoformat()

    def test_one_paise_short_is_still_refused(self, db):
        _fund(db, 148.99)
        assert _buy(_app()).status_code == 402
        assert _balance(db) == 148.99

    def test_reserved_money_cannot_be_spent_on_premium(self, db):
        """Coaching escrow parks funds in wallet.reserved. ₹200 held with
        ₹100 reserved leaves ₹100 spendable — not enough."""
        _fund(db, 200.0, reserved=100.0)
        res = _buy(_app())
        assert res.status_code == 402
        assert res.json()["detail"]["available"] == 10000
        assert _balance(db) == 200.0

    def test_an_empty_wallet_reports_zero_not_a_negative(self, db):
        db.collection("users").document(UID).set({"membership": {"plan": "free"}})
        res = _buy(_app())
        assert res.status_code == 402
        assert res.json()["detail"]["available"] == 0


class TestNoDoubleSpend:
    def test_the_balance_can_never_go_negative(self, db):
        """₹300 against a ₹149 plan: two purchases fit, a third must not."""
        _fund(db, 300.0)
        client = _app()
        assert _buy(client).status_code == 200
        assert _buy(client).status_code == 200
        assert _buy(client).status_code == 402
        assert _balance(db) == 2.0
        assert _balance(db) >= 0

    def test_repeated_submits_with_one_key_charge_once(self, db):
        """A double-tap or a retried request carries the SAME idempotency key
        and must be a no-op: ₹300 -> ₹151, one 30-day term."""
        _fund(db, 300.0)
        client = _app()
        first = _buy(client, key="tap-1")
        assert first.status_code == 200
        expiry = _membership(db)["premium_expiry_date"]

        for _ in range(5):
            again = _buy(client, key="tap-1")
            assert again.status_code == 200
            assert again.json()["already"] is True

        assert _balance(db) == 151.0, "a repeat submission charged twice"
        assert _membership(db)["premium_expiry_date"] == expiry
        assert len(_ledger(db)) == 1

    def test_different_keys_are_different_purchases(self, db):
        """Deliberately buying two months IS two purchases — renewals stack."""
        _fund(db, 400.0)
        client = _app()
        _buy(client, key="buy-1")
        first_expiry = datetime.fromisoformat(_membership(db)["premium_expiry_date"])
        _buy(client, key="buy-2")
        assert _balance(db) == 102.0
        assert datetime.fromisoformat(
            _membership(db)["premium_expiry_date"]) == first_expiry + timedelta(days=30)

    def test_the_ledger_and_the_balance_agree(self, db):
        _fund(db, 500.0)
        client = _app()
        _buy(client, key="a")
        _buy(client, key="b")
        debits = [r for r in _ledger(db) if r.get("direction") == "debit"]
        assert len(debits) == 2
        assert sum(r["amount"] for r in debits) == 298.0
        assert _balance(db) == 500.0 - 298.0
        # walletAfter on the last debit must match the stored balance.
        assert debits[-1]["walletAfter"] == _balance(db)


class TestWalletRenewal:
    def test_remaining_time_is_extended_not_replaced(self, db):
        prior = datetime.now(timezone.utc) + timedelta(days=20)
        _fund(db, 500.0, membership={
            "plan": "premium", "active": True, "billing": "monthly",
            "premium_expiry_date": prior.isoformat()})
        _buy(_app())
        assert datetime.fromisoformat(
            _membership(db)["premium_expiry_date"]) == prior + timedelta(days=30)
        assert _balance(db) == 351.0

    def test_an_expired_membership_starts_a_fresh_period(self, db):
        lapsed = datetime.now(timezone.utc) - timedelta(days=40)
        _fund(db, 500.0, membership={
            "plan": "premium", "active": True, "billing": "monthly",
            "premium_expiry_date": lapsed.isoformat()})
        before = datetime.now(timezone.utc)
        _buy(_app())
        expiry = datetime.fromisoformat(_membership(db)["premium_expiry_date"])
        assert expiry > before + timedelta(days=29, hours=23)
        assert expiry > lapsed + timedelta(days=30)

    def test_renewal_never_shortens_at_any_remaining_balance(self, db):
        for remaining in (1, 7, 29, 300):
            prior = datetime.now(timezone.utc) + timedelta(days=remaining)
            _fund(db, 500.0, membership={
                "plan": "premium", "active": True, "billing": "monthly",
                "premium_expiry_date": prior.isoformat()})
            _buy(_app(), key=f"r{remaining}")
            assert datetime.fromisoformat(
                _membership(db)["premium_expiry_date"]) > prior


class TestPaymentSeparation:
    def test_a_wallet_purchase_writes_no_razorpay_order(self, db):
        _fund(db, 500.0)
        _buy(_app())
        assert not [k for k in db.store if k.startswith("razorpay_orders/")]

    def test_the_razorpay_membership_verifier_still_never_reads_the_wallet(self):
        """Structural. The Razorpay path and the wallet path are separate
        endpoints; the Razorpay one must stay wallet-free so a Razorpay
        purchase can never also move wallet money."""
        import inspect
        src = inspect.getsource(payment_routes.verify_membership_payment)
        assert '"wallet"' not in src and "wallet[" not in src

    def test_the_wallet_purchase_never_calls_razorpay(self):
        import inspect
        src = inspect.getsource(payment_routes.purchase_membership_with_wallet)
        assert "razorpay_service" not in src
        assert "verify_signature" not in src


class TestSecurity:
    def test_an_unauthenticated_purchase_is_rejected(self, db):
        _fund(db, 500.0)
        app = FastAPI()
        app.include_router(payment_routes.router, prefix="/api/payment")
        res = TestClient(app).post(
            "/api/payment/membership/purchase-with-wallet",
            json={"billing": "monthly"})
        assert res.status_code in (401, 403)
        assert _balance(db) == 500.0

    def test_a_caller_spends_only_their_own_wallet(self, db):
        """The uid comes from the verified token; there is no field through
        which another athlete's wallet could be named."""
        _fund(db, 500.0, uid=UID)
        _fund(db, 500.0, uid=OTHER)
        _buy(_app(OTHER))
        assert _balance(db, UID) == 500.0      # untouched
        assert _balance(db, OTHER) == 351.0
        assert _membership(db, UID).get("plan") != "premium"

    def test_the_request_model_exposes_no_amount_or_uid(self):
        fields = set(payment_routes.WalletMembershipBody.model_fields)
        assert fields == {"billing", "idempotencyKey"}

    def test_firestore_rules_deny_client_writes_to_wallet_and_ledger(self):
        rules = (Path(__file__).resolve().parents[2] / "firestore.rules").read_text(
            encoding="utf-8")
        assert "createOmits(['wallet', 'membership'])" in rules
        assert "updateKeeps(['wallet', 'membership'" in rules
        assert "match /wallet_transactions/{id} { allow read, write: if false; }" in rules

    def test_the_freeze_switch_still_blocks_the_wallet_purchase(self, db, monkeypatch):
        import launch_config
        import wallet_config
        monkeypatch.setattr(wallet_config, "WALLET_FROZEN", True)
        monkeypatch.setattr(launch_config, "WALLET_ENABLED", False)
        _fund(db, 500.0)
        res = _buy(_app())
        assert res.status_code == 503
        assert _balance(db) == 500.0


class TestMoneyArithmetic:
    @pytest.mark.parametrize("rupees,paise", [
        (149, 14900), (149.0, 14900), (0.1, 10), (0.29, 29),
        (148.99, 14899), (1000.01, 100001), (99999.99, 9999999), (0, 0),
    ])
    def test_paise_conversion_is_exact(self, rupees, paise):
        assert payment_routes._paise(rupees) == paise

    def test_sub_paise_input_is_documented_not_guaranteed(self):
        """A HALF-paise value has no exact float representation, so its
        rounding direction is whatever the binary expansion gives —
        1000.005 * 100 is 100000.4999… and rounds DOWN.

        This is a limitation of the legacy float-rupee schema, not of the
        conversion. It cannot affect a real balance: every amount that enters
        the wallet is a whole number of paise (Razorpay credits integer paise,
        and prices are whole rupees), so no sub-paise value is reachable.
        Pinned so the behaviour is known rather than discovered.
        """
        assert payment_routes._paise(1000.005) == 100000

    def test_a_float_dusty_balance_still_buys(self, db):
        """0.1 + 0.2 == 0.30000000000000004. A balance built from float
        addition must not be refused by a float comparison."""
        _fund(db, 149.0 + 0.1 + 0.2)
        assert _buy(_app()).status_code == 200

    def test_the_stored_balance_stays_clean_to_two_decimals(self, db):
        _fund(db, 300.10)
        _buy(_app())
        assert _balance(db) == 151.10
        assert round(_balance(db), 2) == _balance(db)
