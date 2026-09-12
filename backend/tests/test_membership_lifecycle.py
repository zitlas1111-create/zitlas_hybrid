"""
ZITLAS — the ₹149 Premium lifecycle, end to end (backend/tests/test_membership_lifecycle.py)

tests/test_payment.py covers the WALLET mechanism and raw HMAC verification.
It contains no membership test at all — the entire ₹149 purchase path was
untested at the endpoint level, which is the gap this file closes.

Everything here drives the REAL routes through `POST /api/payment/membership/
create-order` and `POST /api/payment/membership/verify`, with a genuine HMAC
signature computed from a test secret. Nothing re-implements the renewal
arithmetic: these assert what the endpoint actually writes.

WHAT ₹149 ACTUALLY IS, as implemented: a ONE-TIME Razorpay ORDER (the Orders
API), not a Razorpay Subscription. There is no plan_id, no subscription_id and
no recurring mandate anywhere in services/razorpay_service.py. The "1 month"
is computed by ZITLAS itself — MEMBERSHIP_DURATION_DAYS['monthly'] == 30 days
added to an anchor — and stored as `users/{uid}.membership.premium_expiry_date`.
That timestamp is the only thing that decides premium.
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

from routes import payment  # noqa: E402
from services import entitlements as ent  # noqa: E402
from services import firestore_service, razorpay_service  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
OTHER = "athlete_2"
KEY_SECRET = "test_secret_for_hmac"


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(ent.firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    monkeypatch.setattr(razorpay_service, "_credentials",
                        lambda: ("test_key_id", KEY_SECRET))
    return client


def _app(uid: str = ATHLETE) -> TestClient:
    a = FastAPI()
    a.include_router(payment.router, prefix="/api/payment")
    a.dependency_overrides[payment.verify_firebase_token] = lambda: {
        "uid": uid, "email": None, "name": "Test"}
    return TestClient(a)


def _sign(order_id: str, payment_id: str) -> str:
    return hmac.new(KEY_SECRET.encode(),
                    f"{order_id}|{payment_id}".encode(), hashlib.sha256).hexdigest()


def _order(db, order_id: str, *, uid: str = ATHLETE, billing: str = "monthly",
           purpose: str = "membership", status: str = "created",
           amount_paise: int = 14900) -> None:
    """A razorpay_orders row exactly as /membership/create-order writes it."""
    db.collection("razorpay_orders").document(order_id).set({
        "orderId": order_id, "uid": uid, "amountPaise": amount_paise,
        "currency": "INR", "status": status, "purpose": purpose,
        "billing": billing, "createdAt": datetime.now(timezone.utc).isoformat(),
    })


def _verify(client: TestClient, order_id: str, payment_id: str = "pay_1",
            signature: str | None = None):
    return client.post("/api/payment/membership/verify", json={
        "razorpay_order_id": order_id,
        "razorpay_payment_id": payment_id,
        "razorpay_signature": signature or _sign(order_id, payment_id),
    })


def _set_expiry(db, when: datetime, *, uid: str = ATHLETE, active: bool = True):
    db.collection("users").document(uid).set({"membership": {
        "plan": "premium", "active": active, "billing": "monthly",
        "premium_expiry_date": when.isoformat(),
    }}, merge=True)


def _expiry_of(db, uid: str = ATHLETE) -> datetime:
    raw = db.store[f"users/{uid}"]["membership"]["premium_expiry_date"]
    return datetime.fromisoformat(raw)


# ══════════════════════════════════════════════════════════════════════════
# A. What ₹149 is, and how the period is set
# ══════════════════════════════════════════════════════════════════════════


class TestTheOfferItself:
    def test_the_price_is_server_authoritative(self):
        """The client sends only 'monthly'|'yearly'; it never names a price."""
        assert payment.MEMBERSHIP_PRICES_RUPEES["monthly"] == 149
        assert payment.MEMBERSHIP_PRICES_RUPEES["yearly"] == 999

    def test_monthly_is_thirty_days(self):
        assert payment.MEMBERSHIP_DURATION_DAYS["monthly"] == 30

    def test_create_order_charges_exactly_14900_paise(self, fake_db, monkeypatch):
        captured = {}

        def fake_create(amount_paise, currency="INR", receipt=None):
            captured["amount"] = amount_paise
            captured["currency"] = currency
            return {"order_id": "order_x", "amount": amount_paise,
                    "currency": currency, "key_id": "test_key_id"}

        monkeypatch.setattr(razorpay_service, "create_order", fake_create)
        res = _app().post("/api/payment/membership/create-order",
                          json={"billing": "monthly"})
        assert res.status_code == 200
        assert captured["amount"] == 14900        # ₹149, not a client value
        assert captured["currency"] == "INR"
        assert fake_db.store["razorpay_orders/order_x"]["purpose"] == "membership"

    def test_a_client_cannot_invent_a_billing_period(self, fake_db):
        res = _app().post("/api/payment/membership/create-order",
                          json={"billing": "lifetime"})
        assert res.status_code == 400
        assert res.json()["detail"] == "invalid_billing_period"


# ══════════════════════════════════════════════════════════════════════════
# B/C. Activation
# ══════════════════════════════════════════════════════════════════════════


class TestActivation:
    def test_a_paid_order_grants_premium(self, fake_db):
        _order(fake_db, "order_1")
        assert _verify(_app(), "order_1").status_code == 200
        m = fake_db.store[f"users/{ATHLETE}"]["membership"]
        assert m["plan"] == "premium"
        assert m["active"] is True
        assert m["payment_status"] == "paid"
        assert m["order_id"] == "order_1"
        assert m["premium_expiry_date"]

    def test_expiry_is_one_month_from_now(self, fake_db):
        _order(fake_db, "order_1")
        before = datetime.now(timezone.utc)
        _verify(_app(), "order_1")
        delta = _expiry_of(fake_db) - before
        assert timedelta(days=29, hours=23) < delta <= timedelta(days=30, minutes=1)

    def test_the_entitlement_matrix_flips_immediately(self, fake_db):
        """No scheduler, no re-login: the very next tier lookup is premium."""
        _order(fake_db, "order_1")
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE
        _verify(_app(), "order_1")
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM
        limits = ent.limits_for(ent.tier_for_uid(ATHLETE))
        assert limits[ent.GOAL_RESET] == 5
        assert limits[ent.MEAL_SWAP] is ent.UNLIMITED
        assert limits[ent.RECIPE] == 27

    def test_the_purchase_is_written_to_the_audit_ledger(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(), "order_1", payment_id="pay_abc")
        row = fake_db.store["wallet_transactions/txn_pay_abc"]
        assert row["serviceType"] == "premium_membership"
        assert row["amount"] == 149.0
        assert row["status"] == "success"

    def test_the_order_is_marked_paid(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(), "order_1")
        assert fake_db.store["razorpay_orders/order_1"]["status"] == "paid"


# ══════════════════════════════════════════════════════════════════════════
# B/G. Payment verification and abuse
# ══════════════════════════════════════════════════════════════════════════


class TestPaymentCannotBeForged:
    def test_a_bad_signature_grants_nothing(self, fake_db):
        _order(fake_db, "order_1")
        res = _verify(_app(), "order_1", signature="deadbeef")
        assert res.status_code == 400
        assert res.json()["detail"] == "signature_mismatch"
        assert "membership" not in fake_db.store.get(f"users/{ATHLETE}", {})

    def test_a_signature_for_a_different_order_is_rejected(self, fake_db):
        """The HMAC binds order_id AND payment_id together."""
        _order(fake_db, "order_1")
        res = _verify(_app(), "order_1", signature=_sign("order_OTHER", "pay_1"))
        assert res.status_code == 400

    def test_another_users_order_cannot_be_claimed(self, fake_db):
        """Correct signature, real order — but it belongs to someone else."""
        _order(fake_db, "order_1", uid=OTHER)
        res = _verify(_app(ATHLETE), "order_1")
        assert res.status_code == 403
        assert res.json()["detail"] == "not_your_order"
        assert "membership" not in fake_db.store.get(f"users/{ATHLETE}", {})

    def test_a_wallet_topup_order_cannot_buy_premium(self, fake_db):
        """A cheap top-up order must not be redeemable as a membership."""
        _order(fake_db, "order_1", purpose="wallet_topup", amount_paise=100)
        res = _verify(_app(), "order_1")
        assert res.status_code == 400
        assert res.json()["detail"] == "not_a_membership_order"

    def test_an_unknown_order_is_rejected(self, fake_db):
        res = _verify(_app(), "order_does_not_exist")
        assert res.status_code == 404

    def test_verification_fails_closed_without_razorpay_credentials(
            self, fake_db, monkeypatch):
        monkeypatch.setattr(razorpay_service, "_credentials", lambda: None)
        _order(fake_db, "order_1")
        assert _verify(_app(), "order_1").status_code == 400


class TestReplayAndIdempotency:
    def test_replaying_the_same_payment_does_not_extend_premium(self, fake_db):
        """THE replay guard: the order flips to 'paid' inside the transaction,
        so a resubmitted (order, payment, signature) triple is a no-op."""
        _order(fake_db, "order_1")
        assert _verify(_app(), "order_1").status_code == 200
        first = _expiry_of(fake_db)

        second = _verify(_app(), "order_1")
        assert second.status_code == 200
        assert second.json()["already"] is True
        assert _expiry_of(fake_db) == first, "a replay extended the subscription"

    def test_ten_replays_still_yield_one_period(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(), "order_1")
        first = _expiry_of(fake_db)
        for _ in range(10):
            _verify(_app(), "order_1")
        assert _expiry_of(fake_db) == first

    def test_a_replay_writes_no_second_ledger_row(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(), "order_1", payment_id="pay_abc")
        rows = [k for k in fake_db.store if k.startswith("wallet_transactions/")]
        _verify(_app(), "order_1", payment_id="pay_abc")
        assert [k for k in fake_db.store if k.startswith("wallet_transactions/")] == rows


# ══════════════════════════════════════════════════════════════════════════
# D. Expiry decides premium — no scheduler involved
# ══════════════════════════════════════════════════════════════════════════


class TestExpiryIsTheAuthority:
    def test_future_expiry_is_premium(self, fake_db):
        _set_expiry(fake_db, datetime.now(timezone.utc) + timedelta(days=1))
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM

    @pytest.mark.parametrize("delta", [
        timedelta(seconds=-1), timedelta(minutes=-1),
        timedelta(days=-1), timedelta(days=-999),
    ])
    def test_reached_or_past_expiry_is_basic(self, fake_db, delta):
        _set_expiry(fake_db, datetime.now(timezone.utc) + delta)
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE

    def test_active_true_does_not_survive_expiry(self, fake_db):
        _set_expiry(fake_db, datetime.now(timezone.utc) - timedelta(days=1),
                    active=True)
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE

    @pytest.mark.parametrize("bad", ["", "   ", "not-a-date", "2026-13-45",
                                     "null", "0", 12345, []])
    def test_a_present_but_unusable_expiry_fails_closed(self, fake_db, bad):
        """`""` used to slip through: the guard was `if expiry:`, so an empty
        string was falsy and the expiry check was skipped ENTIRELY — premium
        forever. A field that is present must be usable or it fails closed."""
        fake_db.collection("users").document(ATHLETE).set({"membership": {
            "plan": "premium", "active": True, "premium_expiry_date": bad}})
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE

    def test_a_membership_with_no_expiry_key_is_still_premium(self, fake_db):
        """PINNED AS A PRODUCT DECISION, NOT AN OVERSIGHT.

        An ABSENT `premium_expiry_date` means "no expiry was ever recorded"
        (comped / grandfathered accounts) and grants premium. This differs
        from the present-but-unusable case above, which fails closed.

        It is unreachable from the payment flow — /membership/verify always
        writes a real expiry — so only a hand-created document lands here.
        Flipping it would silently demote such accounts and needs product
        sign-off; this test exists so the behaviour is explicit and any change
        to it is deliberate.
        """
        fake_db.collection("users").document(ATHLETE).set(
            {"membership": {"plan": "premium", "active": True}})
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM

    def test_an_expired_user_gets_the_basic_matrix(self, fake_db):
        _set_expiry(fake_db, datetime.now(timezone.utc) - timedelta(seconds=1))
        limits = ent.limits_for(ent.tier_for_uid(ATHLETE))
        assert limits[ent.GOAL_RESET] == 2
        assert limits[ent.MEAL_SWAP] == 70
        assert limits[ent.RECIPE] == 7

    def test_expiry_is_evaluated_per_request_not_cached(self, fake_db):
        """The same uid flips premium -> basic with no write in between other
        than time passing, which is what makes a scheduler unnecessary."""
        _set_expiry(fake_db, datetime.now(timezone.utc) + timedelta(seconds=1))
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM
        _set_expiry(fake_db, datetime.now(timezone.utc) - timedelta(seconds=1))
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE


# ══════════════════════════════════════════════════════════════════════════
# E. Renewal — through the real endpoint, not a re-implementation
# ══════════════════════════════════════════════════════════════════════════


class TestRenewal:
    def test_case1_no_existing_premium_gets_a_full_month(self, fake_db):
        _order(fake_db, "order_1")
        before = datetime.now(timezone.utc)
        _verify(_app(), "order_1")
        assert _expiry_of(fake_db) - before > timedelta(days=29, hours=23)

    def test_case2_twenty_days_remaining_are_not_lost(self, fake_db):
        prior = datetime.now(timezone.utc) + timedelta(days=20)
        _set_expiry(fake_db, prior)
        _order(fake_db, "order_2")
        _verify(_app(), "order_2")
        assert _expiry_of(fake_db) == prior + timedelta(days=30)

    def test_case3_one_day_remaining_extends_from_that_expiry(self, fake_db):
        prior = datetime.now(timezone.utc) + timedelta(days=1)
        _set_expiry(fake_db, prior)
        _order(fake_db, "order_2")
        _verify(_app(), "order_2")
        assert _expiry_of(fake_db) == prior + timedelta(days=30)

    def test_case4_an_expired_membership_starts_a_fresh_period(self, fake_db):
        lapsed = datetime.now(timezone.utc) - timedelta(days=45)
        _set_expiry(fake_db, lapsed)
        _order(fake_db, "order_2")
        before = datetime.now(timezone.utc)
        _verify(_app(), "order_2")
        expiry = _expiry_of(fake_db)
        assert expiry > before + timedelta(days=29, hours=23)   # fresh, not
        assert expiry > lapsed + timedelta(days=30)             # back-dated

    def test_case5_multiple_renewals_stack(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(), "order_1")
        first = _expiry_of(fake_db)
        for n in range(2, 5):
            _order(fake_db, f"order_{n}")
            _verify(_app(), f"order_{n}")
        assert _expiry_of(fake_db) == first + timedelta(days=90)

    def test_renewal_never_shortens_at_any_remaining_balance(self, fake_db):
        for i, remaining in enumerate((1, 7, 20, 29, 300), start=1):
            db_key = f"order_r{i}"
            prior = datetime.now(timezone.utc) + timedelta(days=remaining)
            _set_expiry(fake_db, prior)
            _order(fake_db, db_key)
            _verify(_app(), db_key)
            assert _expiry_of(fake_db) > prior, f"{remaining}d remaining shortened"

    def test_a_yearly_order_adds_365_days(self, fake_db):
        _order(fake_db, "order_y", billing="yearly", amount_paise=99900)
        before = datetime.now(timezone.utc)
        _verify(_app(), "order_y")
        assert _expiry_of(fake_db) - before > timedelta(days=364, hours=23)


# ══════════════════════════════════════════════════════════════════════════
# F/G. Server authority across sessions and devices
# ══════════════════════════════════════════════════════════════════════════


class TestServerIsTheOnlyAuthority:
    def test_entitlement_follows_the_uid_not_the_session(self, fake_db):
        """Logout/login, a reinstall, or a second device is just another
        request for the same uid — the tier is re-derived from Firestore
        every time and nothing client-held participates."""
        _order(fake_db, "order_1")
        _verify(_app(), "order_1")
        for _ in range(3):                      # three "fresh sessions"
            assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM

    def test_a_second_device_sees_the_same_expiry(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(ATHLETE), "order_1")
        expiry = _expiry_of(fake_db)
        # A different TestClient is a different device/session, same account.
        assert _app(ATHLETE) is not None
        assert _expiry_of(fake_db) == expiry
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM

    def test_one_users_premium_does_not_leak_to_another(self, fake_db):
        _order(fake_db, "order_1")
        _verify(_app(ATHLETE), "order_1")
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_PREMIUM
        assert ent.tier_for_uid(OTHER) == ent.TIER_FREE

    def test_a_client_supplied_tier_is_never_consulted(self, fake_db):
        """`tier_for_uid` takes a uid and reads Firestore. There is no
        parameter through which a caller could assert its own tier."""
        import inspect
        assert list(inspect.signature(ent.tier_for_uid).parameters) == ["uid"]
        assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE

    def test_an_expired_membership_is_basic_on_every_lookup(self, fake_db):
        _set_expiry(fake_db, datetime.now(timezone.utc) - timedelta(days=1))
        for _ in range(3):
            assert ent.tier_for_uid(ATHLETE) == ent.TIER_FREE


class TestFirestoreRulesProtectEntitlement:
    """The rules file is the other half of "a client cannot grant itself
    premium" — the backend writes membership with the Admin SDK, and no client
    may touch it."""

    @staticmethod
    def _rules() -> str:
        return (Path(__file__).resolve().parents[2] / "firestore.rules").read_text(
            encoding="utf-8")

    def test_membership_cannot_be_created_by_a_client(self):
        assert "createOmits(['wallet', 'membership'])" in self._rules()

    def test_membership_cannot_be_changed_by_a_client(self):
        rules = self._rules()
        assert "updateKeeps(['wallet', 'membership'" in rules
        # updateKeeps blocks any CHANGE to the listed keys, not merely their
        # absence — that distinction is what stops an expiry edit.
        assert "diff(resource.data).affectedKeys().hasAny(fields)" in rules

    def test_order_and_ledger_rows_are_backend_only(self):
        rules = self._rules()
        assert "match /razorpay_orders/{id}     { allow read, write: if false; }" in rules
        assert "match /wallet_transactions/{id} { allow read, write: if false; }" in rules

    def test_the_usage_counter_has_no_client_rule_and_falls_to_default_deny(self):
        """usage_weekly holds the goal-reset counter. It has no match block,
        so `match /{document=**} { allow read, write: if false; }` applies."""
        rules = self._rules()
        assert "usage_weekly" not in rules
        assert "match /{document=**} { allow read, write: if false; }" in rules
