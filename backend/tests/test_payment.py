"""
ZITLAS — Razorpay payment route tests (backend/tests/test_payment.py)

Exercises the REAL routes/payment.py against fake_firestore.py's in-process
fake (see that file's docstring for what it does/doesn't reproduce), with
services.razorpay_service's network-calling functions mocked out (no real
Razorpay API calls) EXCEPT verify_signature, which is a pure HMAC
computation tested for real — a mocked "always true" would defeat the
entire point of testing signature verification.
"""

from __future__ import annotations

import hashlib
import hmac
import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import payment  # noqa: E402
from services import firestore_service, razorpay_service  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402
import wallet_config  # noqa: E402


# ── The Wallet is FROZEN for launch (backend/wallet_config.py) ──────────────
# These tests exercise the wallet MECHANISM, which is deliberately kept intact
# for V2 — balances, escrow, debits, the audit ledger. The freeze is a business
# POLICY layered on top of it, and it has its own suite in
# tests/test_wallet_freeze.py. Unfreezing here keeps the mechanism covered
# instead of deleting the tests that prove it works; it does not, and cannot,
# affect what production does.
@pytest.fixture(autouse=True)
def _wallet_unfrozen_for_mechanism_tests(monkeypatch):
    monkeypatch.setattr(wallet_config, "WALLET_FROZEN", False)


ATHLETE_UID = "athlete_1"
KEY_SECRET = "test_secret_for_hmac"


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    return client


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(payment.router, prefix="/api/payment")
    a.dependency_overrides[payment.verify_firebase_token] = lambda: {"uid": ATHLETE_UID, "email": None, "name": "Test"}
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _real_signature(order_id, payment_id):
    return hmac.new(KEY_SECRET.encode(), f"{order_id}|{payment_id}".encode(), hashlib.sha256).hexdigest()


# ── Pure signature-verification logic (no mocks — real HMAC) ──────────

def test_verify_signature_accepts_correctly_signed_pair(monkeypatch):
    monkeypatch.setenv("RAZORPAY_KEY_ID", "rzp_test_x")
    monkeypatch.setenv("RAZORPAY_KEY_SECRET", KEY_SECRET)
    sig = _real_signature("order_abc", "pay_xyz")
    assert razorpay_service.verify_signature("order_abc", "pay_xyz", sig) is True


def test_verify_signature_rejects_tampered_signature(monkeypatch):
    monkeypatch.setenv("RAZORPAY_KEY_ID", "rzp_test_x")
    monkeypatch.setenv("RAZORPAY_KEY_SECRET", KEY_SECRET)
    assert razorpay_service.verify_signature("order_abc", "pay_xyz", "0" * 64) is False


def test_verify_signature_rejects_wrong_order_id(monkeypatch):
    monkeypatch.setenv("RAZORPAY_KEY_ID", "rzp_test_x")
    monkeypatch.setenv("RAZORPAY_KEY_SECRET", KEY_SECRET)
    sig = _real_signature("order_abc", "pay_xyz")
    # Same signature, but claiming a DIFFERENT order — must not verify.
    assert razorpay_service.verify_signature("order_different", "pay_xyz", sig) is False


def test_verify_signature_fails_closed_when_unconfigured(monkeypatch):
    monkeypatch.delenv("RAZORPAY_KEY_ID", raising=False)
    monkeypatch.delenv("RAZORPAY_KEY_SECRET", raising=False)
    assert razorpay_service.verify_signature("order_abc", "pay_xyz", "anything") is False


# ── /create-order ──────────────────────────────────────────────────────

def test_create_order_happy_path(fake_db, app, client, monkeypatch):
    def fake_create_order(amount_paise, currency="INR", receipt=None):
        return {"order_id": "order_test123", "amount": amount_paise, "currency": currency, "key_id": "rzp_test_x"}
    monkeypatch.setattr(razorpay_service, "create_order", fake_create_order)

    r = client.post("/api/payment/create-order", json={"amount": 500})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["order_id"] == "order_test123"
    assert body["amount"] == 50000  # paise
    assert body["key_id"] == "rzp_test_x"

    order_doc = fake_db.store["razorpay_orders/order_test123"]
    assert order_doc["uid"] == ATHLETE_UID
    assert order_doc["status"] == "created"
    assert order_doc["amountPaise"] == 50000


def test_create_order_rejects_zero_amount(fake_db, app, client):
    r = client.post("/api/payment/create-order", json={"amount": 0})
    assert r.status_code == 400


def test_create_order_surfaces_razorpay_auth_failure_as_401(fake_db, app, client, monkeypatch):
    def fake_create_order(amount_paise, currency="INR", receipt=None):
        raise PermissionError("razorpay_auth_failed: bad credentials")
    monkeypatch.setattr(razorpay_service, "create_order", fake_create_order)

    r = client.post("/api/payment/create-order", json={"amount": 100})
    assert r.status_code == 401
    assert "razorpay_auth_failed" in r.json()["detail"]


def test_create_order_surfaces_razorpay_api_error_as_500(fake_db, app, client, monkeypatch):
    def fake_create_order(amount_paise, currency="INR", receipt=None):
        raise RuntimeError("razorpay_api_error (500): upstream down")
    monkeypatch.setattr(razorpay_service, "create_order", fake_create_order)

    r = client.post("/api/payment/create-order", json={"amount": 100})
    assert r.status_code == 500


def test_create_order_unauthenticated_rejected(app, client):
    app.dependency_overrides.pop(payment.verify_firebase_token, None)
    r = client.post("/api/payment/create-order", json={"amount": 100})
    assert r.status_code == 401


# ── /verify ─────────────────────────────────────────────────────────────

def _seed_order(fake_db, order_id="order_1", uid=ATHLETE_UID, amount_paise=50000, status="created"):
    fake_db.store[f"razorpay_orders/{order_id}"] = {
        "orderId": order_id, "uid": uid, "amountPaise": amount_paise,
        "currency": "INR", "status": status, "createdAt": "2026-01-01T00:00:00+00:00",
    }


def test_verify_happy_path_credits_wallet(fake_db, app, client, monkeypatch):
    _seed_order(fake_db, amount_paise=50000)
    monkeypatch.setattr(razorpay_service, "verify_signature", lambda o, p, s: True)

    r = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_1", "razorpay_payment_id": "pay_1", "razorpay_signature": "sig",
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["success"] is True
    assert body["amount"] == 500.0
    assert body["balance"] == 500.0

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 500.0
    assert wallet["total_added"] == 500.0

    order = fake_db.store["razorpay_orders/order_1"]
    assert order["status"] == "paid"

    txn = fake_db.store["wallet_transactions/txn_pay_1"]
    assert txn["method"] == "razorpay"
    assert txn["amount"] == 500.0


def test_verify_signature_mismatch_does_not_credit_wallet(fake_db, app, client, monkeypatch):
    _seed_order(fake_db)
    monkeypatch.setattr(razorpay_service, "verify_signature", lambda o, p, s: False)

    r = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_1", "razorpay_payment_id": "pay_1", "razorpay_signature": "bad_sig",
    })
    assert r.status_code == 400
    assert r.json()["detail"] == "signature_mismatch"
    assert f"users/{ATHLETE_UID}" not in fake_db.store or not fake_db.store[f"users/{ATHLETE_UID}"]
    assert fake_db.store["razorpay_orders/order_1"]["status"] == "created", "order must stay unpaid on mismatch"


def test_verify_order_not_found(fake_db, app, client, monkeypatch):
    monkeypatch.setattr(razorpay_service, "verify_signature", lambda o, p, s: True)
    r = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_nonexistent", "razorpay_payment_id": "pay_1", "razorpay_signature": "sig",
    })
    assert r.status_code == 404


def test_verify_blocks_crediting_someone_elses_order(fake_db, app, client, monkeypatch):
    _seed_order(fake_db, uid="a_different_user")
    monkeypatch.setattr(razorpay_service, "verify_signature", lambda o, p, s: True)

    r = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_1", "razorpay_payment_id": "pay_1", "razorpay_signature": "sig",
    })
    assert r.status_code == 403
    assert fake_db.store.get(f"users/{ATHLETE_UID}") is None, "must not credit the caller's wallet for someone else's order"


def test_verify_is_idempotent_not_double_credited(fake_db, app, client, monkeypatch):
    _seed_order(fake_db, amount_paise=50000)
    monkeypatch.setattr(razorpay_service, "verify_signature", lambda o, p, s: True)

    r1 = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_1", "razorpay_payment_id": "pay_1", "razorpay_signature": "sig",
    })
    assert r1.status_code == 200
    r2 = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_1", "razorpay_payment_id": "pay_1", "razorpay_signature": "sig",
    })
    assert r2.status_code == 200
    assert r2.json()["already"] is True
    assert r2.json()["balance"] == 500.0

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 500.0, "CRITICAL — must not be credited twice"
    assert len(wallet["transactions"]) == 1


def test_verify_unauthenticated_rejected(app, client):
    app.dependency_overrides.pop(payment.verify_firebase_token, None)
    r = client.post("/api/payment/verify", json={
        "razorpay_order_id": "order_1", "razorpay_payment_id": "pay_1", "razorpay_signature": "sig",
    })
    assert r.status_code == 401
