"""
ZITLAS — Personal Coaching Programs, PHASE 3: wallet payment + activation
(backend/tests/test_coaching_programs_payment.py)

    expert accepts -> payment_required -> POST /requests/{id}/pay
        -> enough in the wallet?  yes: debit + ledger + paid + active, atomically
                                  no:  402, nothing written, still payment_required

Exercises the REAL routes/coaching_programs.py against fake_firestore.py.
The wallet mechanics under test are the ones Premium-from-wallet uses
(routes/payment.py): integer paise, available = balance - reserved, one
transaction, the ledger in wallet_transactions.
"""

from __future__ import annotations

import copy
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).parent.parent))

import launch_config  # noqa: E402
import wallet_config  # noqa: E402
from routes import coaching_programs as routes  # noqa: E402
from services import auth_service, firestore_service, razorpay_service  # noqa: E402
from services import coaching_programs as cp  # noqa: E402
from tests.fake_firestore import FakeClient, FakeTransaction, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
OTHER_ATHLETE = "athlete_2"
EXPERT = "expert_1"
OTHER_EXPERT = "expert_2"

BASE = "/api/coaching-programs"
PRICES = {"10_day": 49900, "1_month": 129900, "3_month": 349900}
DAYS = {"10_day": 10, "1_month": 30, "3_month": 90}
REQ = "coaching_program_requests/"


@pytest.fixture(autouse=True)
def _policy(monkeypatch):
    # The launch defaults, pinned so another suite's monkeypatching cannot
    # leak in: the wallet is on, program payments are on.
    monkeypatch.setattr(wallet_config, "WALLET_FROZEN", False)
    monkeypatch.setattr(launch_config, "WALLET_ENABLED", True)
    monkeypatch.setattr(launch_config, "COACHING_PROGRAMS_PAYMENT_ENABLED", True)


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    for uid, name in ((EXPERT, "Coach One"), (OTHER_EXPERT, "Coach Two")):
        client.store[f"experts/{uid}"] = {
            "name": name, "approved": True,
            "programPricing": {k: {"pricePaise": v, "currency": "INR",
                                   "updatedAt": "2026-09-01T00:00:00+00:00"}
                               for k, v in PRICES.items()},
        }
    client.store[f"users/{OTHER_ATHLETE}"] = {"name": "Ravi"}
    return client


@pytest.fixture
def sent(monkeypatch):
    calls = []
    monkeypatch.setattr(routes, "notify",
                        lambda _db, uid, title, message, **kw:
                        calls.append({"uid": uid, "title": title, "message": message, **kw}))
    return calls


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(routes.router, prefix=BASE)
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid, *, expert=False):
    app.dependency_overrides[auth_service.verify_firebase_token] = lambda: {
        "uid": uid, "email": None, "name": "Token Name", "admin": False, "expert": expert}


def _fund(db, rupees, *, reserved=0.0, uid=ATHLETE, spent=0.0):
    db.store[f"users/{uid}"] = {
        "name": "Asha",
        "wallet": {"balance": rupees, "reserved": reserved, "total_added": rupees,
                   "total_spent": spent, "transactions": []},
    }


def _wallet(db, uid=ATHLETE):
    return db.store[f"users/{uid}"]["wallet"]


def _ledger(db):
    return {k: v for k, v in db.store.items() if k.startswith("wallet_transactions/")}


def _accepted(app, client, program="10_day", *, expert=EXPERT, athlete=ATHLETE):
    """The real Phase 2 path: athlete requests, expert accepts."""
    _as(app, athlete)
    r = client.post(f"{BASE}/requests", json={"expertId": expert, "programId": program})
    assert r.status_code == 200, r.text
    request_id = r.json()["request"]["requestId"]
    _as(app, expert, expert=True)
    assert client.post(f"{BASE}/requests/{request_id}/accept").status_code == 200
    return request_id


def _pay(app, client, request_id, *, athlete=ATHLETE, **body):
    _as(app, athlete)
    return client.post(f"{BASE}/requests/{request_id}/pay", json=body or None)


def _iso(value):
    return datetime.fromisoformat(value)


# ═══════════════════════════════ Accepting ══════════════════════════════════

def test_acceptance_makes_payment_due_and_charges_nothing(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    doc = db.store[REQ + request_id]
    assert doc["status"] == "accepted" and doc["expertAccepted"] is True
    assert doc["paymentStatus"] == "payment_required"
    assert "paidAt" not in doc and "startedAt" not in doc
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}
    assert f"personal_coaching/{ATHLETE}" not in db.store


# ═══════════════════════════════ Paying ═════════════════════════════════════

def test_a_funded_wallet_pays_and_starts_the_program(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    r = _pay(app, client, request_id)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["success"] is True and body["already"] is False
    assert body["requestId"] == request_id and body["programId"] == "10_day"
    assert body["paymentStatus"] == "paid" and body["programStatus"] == "active"
    assert body["amountPaid"] == 499.0 and body["amountPaidPaise"] == 49900
    assert body["startedAt"] and body["endsAt"]
    assert body["balance"] == 501.0


def test_exactly_the_snapshot_price_is_debited_to_the_paise(db, app, client, sent):
    # Float-rupee balances (the legacy schema) are decided in integer paise:
    # ₹1500.10 with ₹0.10 reserved covers ₹1299 exactly, and leaves no dust.
    _fund(db, 1500.10, reserved=0.10, spent=20.0)
    request_id = _accepted(app, client, "1_month")
    assert _pay(app, client, request_id).status_code == 200
    wallet = _wallet(db)
    assert wallet["balance"] == 201.1
    assert wallet["total_spent"] == 1319.0
    row = _ledger(db)[f"wallet_transactions/prog_{request_id}"]
    assert (row["walletBefore"], row["walletAfter"], row["amountPaise"]) == (1500.1, 201.1, 129900)


def test_the_debit_and_wallet_totals_follow_the_existing_wallet(db, app, client, sent):
    _fund(db, 2000, reserved=100, spent=50)
    request_id = _accepted(app, client, "1_month")
    assert _pay(app, client, request_id).status_code == 200
    wallet = _wallet(db)
    assert wallet["balance"] == 701.0          # 2000 - 1299
    assert wallet["reserved"] == 100            # escrow untouched
    assert wallet["total_added"] == 2000        # nothing was added
    assert wallet["total_spent"] == 1349.0      # 50 + 1299
    assert wallet["transactions"] == [{
        "id": f"prog_{request_id}", "type": "debit", "amount": 1299.0,
        "description": "1-Month Program — Coach One",
        "date": db.store[REQ + request_id]["paidAt"],
    }]


def test_one_ledger_row_in_the_existing_ledger_shape(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    _pay(app, client, request_id)
    ledger = _ledger(db)
    assert list(ledger) == [f"wallet_transactions/prog_{request_id}"]
    row = ledger[f"wallet_transactions/prog_{request_id}"]
    assert row == {
        "transactionId": f"prog_{request_id}",
        "serviceType": "personal_coaching_program",
        "userId": ATHLETE, "athleteId": ATHLETE, "expertId": EXPERT,
        "amount": 499.0, "amountPaise": 49900,
        "direction": "debit", "method": "wallet",
        "walletBefore": 1000.0, "walletAfter": 501.0,
        "programRequestId": request_id, "programId": "10_day",
        "programType": "diet", "durationDays": 10,
        "status": "success", "createdAt": row["createdAt"],
    }


def test_the_request_becomes_a_paid_active_program(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    _pay(app, client, request_id)
    doc = db.store[REQ + request_id]
    assert doc["status"] == "active" and doc["paymentStatus"] == "paid"
    assert doc["paidAt"] == doc["activatedAt"] == doc["startedAt"]
    assert doc["amountPaidPaise"] == 49900
    assert doc["walletTransactionId"] == f"prog_{request_id}"
    assert doc["pricePaise"] == 49900 and doc["durationDays"] == 10, "snapshot untouched"


def test_coaching_starts_in_the_existing_relationship_shape(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    _pay(app, client, request_id)
    doc = db.store[REQ + request_id]
    rel = db.store[f"personal_coaching/{ATHLETE}"]
    assert rel["coachId"] == EXPERT and rel["coachName"] == "Coach One"
    assert rel["athleteId"] == ATHLETE and rel["athleteName"] == "Asha"
    assert rel["status"] == "active" and rel["coachingType"] == "PAID"
    assert rel["planType"] == "diet" and rel["planLabel"] == "10-Day Program"
    assert rel["startDate"] == doc["startedAt"] and rel["endDate"] == doc["endsAt"]
    assert isinstance(rel["endDateTs"], datetime) and rel["endDateTs"] == _iso(doc["endsAt"])
    assert rel["programRequestId"] == request_id and rel["requestId"] is None
    assert rel["paymentId"] == f"prog_{request_id}" and rel["fee"] == 499.0


@pytest.mark.parametrize("program", ["10_day", "1_month", "3_month"])
def test_the_program_runs_exactly_its_duration_from_payment(db, app, client, sent, program):
    _fund(db, 5000)
    request_id = _accepted(app, client, program)
    before = datetime.now(timezone.utc)
    body = _pay(app, client, request_id).json()
    after = datetime.now(timezone.utc)
    start, end = _iso(body["startedAt"]), _iso(body["endsAt"])
    assert before <= start <= after, "startedAt is the moment of payment"
    assert end - start == timedelta(days=DAYS[program]), "exact days — never calendar months"
    assert start.tzinfo is not None and end.utcoffset() == timedelta(0)


def test_the_start_is_payment_time_not_request_or_acceptance_time(db, app, client, sent,
                                                                  monkeypatch):
    clock = {"t": datetime(2026, 9, 1, 8, 0, tzinfo=timezone.utc)}
    monkeypatch.setattr(routes, "now", lambda: clock["t"])
    _fund(db, 1000)
    request_id = _accepted(app, client)            # requested + accepted on 1 Sep
    clock["t"] = datetime(2026, 9, 5, 18, 30, tzinfo=timezone.utc)
    body = _pay(app, client, request_id).json()   # paid on 5 Sep
    assert body["startedAt"] == "2026-09-05T18:30:00+00:00"
    assert body["endsAt"] == "2026-09-15T18:30:00+00:00"


def test_athlete_and_expert_are_told_the_program_started(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    sent.clear()
    _pay(app, client, request_id)
    assert [(s["uid"], s["title"]) for s in sent] == [(ATHLETE, "Program Started"),
                                                      (EXPERT, "Program Started")]
    assert "₹499 was paid from your ZITLAS Wallet" in sent[0]["message"]
    assert sent[0]["action"] == "coaching_workspace" and sent[0]["action_id"] == EXPERT


# ═══════════════════════════ Not enough in the wallet ═══════════════════════

def test_a_short_wallet_gets_a_structured_402(db, app, client, sent):
    _fund(db, 100)
    request_id = _accepted(app, client)
    r = _pay(app, client, request_id)
    assert r.status_code == 402
    assert r.json()["detail"] == {
        "error": "insufficient_wallet_balance", "required": 49900, "available": 10000,
        "currency": "INR", "requiredRupees": 499.0, "availableRupees": 100.0,
    }


def test_a_short_wallet_changes_nothing_at_all(db, app, client, sent):
    _fund(db, 100)
    request_id = _accepted(app, client)
    before = copy.deepcopy(db.store)
    assert _pay(app, client, request_id).status_code == 402
    assert db.store == before, "no debit, no ledger, no activation, no state change"
    doc = db.store[REQ + request_id]
    assert doc["status"] == "accepted" and doc["paymentStatus"] == "payment_required"


def test_reserved_money_cannot_pay_for_a_program(db, app, client, sent):
    _fund(db, 1000, reserved=600)
    request_id = _accepted(app, client)
    r = _pay(app, client, request_id)
    assert r.status_code == 402 and r.json()["detail"]["available"] == 40000
    assert _wallet(db)["balance"] == 1000


def test_one_paise_short_is_still_refused_and_an_exact_balance_is_enough(db, app, client, sent):
    _fund(db, 498.99)
    request_id = _accepted(app, client)
    assert _pay(app, client, request_id).status_code == 402
    _fund(db, 499.00)
    assert _pay(app, client, request_id).status_code == 200
    assert _wallet(db)["balance"] == 0.0


def test_an_empty_or_over_reserved_wallet_reports_zero_available(db, app, client, sent):
    db.store[f"users/{ATHLETE}"] = {"name": "Asha"}            # no wallet yet
    request_id = _accepted(app, client)
    assert _pay(app, client, request_id).json()["detail"]["available"] == 0
    _fund(db, 100, reserved=300)
    assert _pay(app, client, request_id).json()["detail"]["available"] == 0


def test_after_adding_funds_the_same_request_can_be_paid(db, app, client, sent):
    _fund(db, 100)
    request_id = _accepted(app, client)
    assert _pay(app, client, request_id).status_code == 402
    # Add Funds is the existing flow (POST /api/payment/verify credits the
    # wallet server-side); here, its effect on the stored wallet.
    _wallet(db)["balance"] = 600.0
    _wallet(db)["total_added"] = 600.0
    r = _pay(app, client, request_id)
    assert r.status_code == 200 and r.json()["balance"] == 101.0
    assert len(_ledger(db)) == 1


# ═══════════════════════════════ Security ═══════════════════════════════════

def test_another_athlete_cannot_pay_for_this_program(db, app, client, sent):
    _fund(db, 1000)
    _fund(db, 1000, uid=OTHER_ATHLETE)
    request_id = _accepted(app, client)
    before = copy.deepcopy(db.store)
    r = _pay(app, client, request_id, athlete=OTHER_ATHLETE)
    assert r.status_code == 403 and r.json()["detail"] == "not_your_request"
    assert db.store == before


def test_the_expert_cannot_pay_on_the_athletes_behalf(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    assert _pay(app, client, request_id, athlete=EXPERT).status_code == 403
    assert _ledger(db) == {}


def test_client_supplied_price_duration_expert_and_program_are_ignored(db, app, client, sent):
    _fund(db, 5000)
    request_id = _accepted(app, client, "10_day")
    r = _pay(app, client, request_id, pricePaise=1, amount=1, price=1, durationDays=365,
             expertId=OTHER_EXPERT, programId="3_month", programType="complete",
             athleteId=OTHER_ATHLETE, idempotencyKey="forged")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["amountPaidPaise"] == 49900 and body["programId"] == "10_day"
    assert _iso(body["endsAt"]) - _iso(body["startedAt"]) == timedelta(days=10)
    assert db.store[f"personal_coaching/{ATHLETE}"]["coachId"] == EXPERT
    assert _wallet(db)["balance"] == 4501.0
    assert f"personal_coaching/{OTHER_ATHLETE}" not in db.store


def test_payment_before_the_expert_accepts_is_refused(db, app, client, sent):
    _fund(db, 1000)
    _as(app, ATHLETE)
    request_id = client.post(f"{BASE}/requests",
                             json={"expertId": EXPERT, "programId": "10_day"}).json()["request"]["requestId"]
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"]["error"] == "not_accepted"
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


def test_a_declined_request_cannot_be_paid(db, app, client, sent):
    _fund(db, 1000)
    _as(app, ATHLETE)
    request_id = client.post(f"{BASE}/requests",
                             json={"expertId": EXPERT, "programId": "10_day"}).json()["request"]["requestId"]
    _as(app, EXPERT, expert=True)
    client.post(f"{BASE}/requests/{request_id}/decline")
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"] == {"error": "not_payable", "status": "declined"}
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


@pytest.mark.parametrize("status", ["cancelled", "expired", "withdrawn", "completed"])
def test_a_cancelled_or_expired_request_cannot_be_paid(db, app, client, sent, status):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    db.store[REQ + request_id]["status"] = status
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"]["error"] == "not_payable"
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


@pytest.mark.parametrize("field, value", [
    ("pricePaise", 0), ("pricePaise", -49900), ("pricePaise", "49900"), ("pricePaise", 499.0),
    ("durationDays", 365), ("durationDays", "10"), ("programId", "7_day"),
    ("expertId", None), ("expertId", ATHLETE),
])
def test_a_request_that_does_not_match_the_catalog_is_never_charged(db, app, client, sent,
                                                                     field, value):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    db.store[REQ + request_id][field] = value
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"] == "request_invalid"
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


def test_paying_needs_sign_in_and_a_real_request(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    app.dependency_overrides.clear()
    assert client.post(f"{BASE}/requests/{request_id}/pay").status_code == 401
    assert _pay(app, client, "CPR_missing").status_code == 404
    assert _wallet(db)["balance"] == 1000


# ═════════════════════════ Once only: idempotency ═══════════════════════════

def test_paying_twice_charges_once(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    first = _pay(app, client, request_id).json()
    state = copy.deepcopy(db.store)
    again = _pay(app, client, request_id)
    assert again.status_code == 200 and again.json()["already"] is True
    assert again.json()["startedAt"] == first["startedAt"]
    assert again.json()["endsAt"] == first["endsAt"], "never extended twice"
    assert db.store == state, "the repeat writes nothing"
    assert len(_ledger(db)) == 1 and _wallet(db)["balance"] == 501.0


def test_a_retry_after_a_lost_response_returns_the_same_payment(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    _pay(app, client, request_id)          # committed — the response never arrived
    retry = _pay(app, client, request_id).json()
    assert retry["already"] is True and retry["paymentStatus"] == "paid"
    assert retry["amountPaidPaise"] == 49900 and retry["balance"] == 501.0


def test_a_failed_commit_leaves_no_trace_and_a_retry_charges_once(db, app, client, sent,
                                                                  monkeypatch):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    before = copy.deepcopy(db.store)
    real_commit = FakeTransaction._commit
    failures = {"left": 1}

    def flaky_commit(self):
        if failures["left"]:
            failures["left"] -= 1
            self._rollback()
            raise RuntimeError("DEADLINE_EXCEEDED")
        real_commit(self)

    monkeypatch.setattr(FakeTransaction, "_commit", flaky_commit)
    r = _pay(app, client, request_id)
    assert r.status_code == 500 and r.json()["detail"].startswith("program_payment_failed")
    assert db.store == before, "no debit, no ledger row, no activation"
    assert _pay(app, client, request_id).status_code == 200
    assert len(_ledger(db)) == 1 and _wallet(db)["balance"] == 501.0


def test_a_ledger_row_without_a_paid_request_is_never_charged_again(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    db.store[f"wallet_transactions/prog_{request_id}"] = {"status": "success"}
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"] == "payment_already_recorded"
    assert _wallet(db)["balance"] == 1000


def _racing(monkeypatch, db, race):
    """fake_transactional plus Firestore's conflict rule: if another writer
    committed while this attempt ran, the attempt is discarded and re-run
    against the new state. `race` runs once, between an attempt's reads and
    its commit — exactly where a second device's payment would land."""
    fired = {"done": False}

    def transactional(func):
        def wrapper(transaction, *args, **kwargs):
            for _ in range(5):
                snapshot = copy.deepcopy(db.store)
                try:
                    result = func(transaction, *args, **kwargs)
                except Exception:
                    transaction._rollback()
                    raise
                if not fired["done"]:
                    fired["done"] = True
                    race()
                if db.store != snapshot:
                    transaction._rollback()     # conflict: re-run on the new state
                    continue
                transaction._commit()
                return result
            raise RuntimeError("ABORTED: too much contention")
        return wrapper

    monkeypatch.setattr(firestore, "transactional", transactional)


def test_two_simultaneous_payments_charge_once(db, app, client, sent, monkeypatch):
    """Wallet ₹1000, program ₹499: a second device pays while the first
    attempt is mid-flight. Exactly one ₹499 debit and one ledger row."""
    _fund(db, 1000)
    request_id = _accepted(app, client)
    second = {}

    def other_device():
        second["response"] = TestClient(app).post(f"{BASE}/requests/{request_id}/pay")

    _racing(monkeypatch, db, other_device)
    first = _pay(app, client, request_id)
    assert first.status_code == 200 and second["response"].status_code == 200
    assert sorted([first.json()["already"], second["response"].json()["already"]]) == [False, True]
    assert len(_ledger(db)) == 1
    assert _wallet(db)["balance"] == 501.0 and _wallet(db)["total_spent"] == 499.0
    assert len(_wallet(db)["transactions"]) == 1


def test_a_balance_that_drops_mid_payment_is_re_checked(db, app, client, sent, monkeypatch):
    """Wallet ₹500, program ₹499 — and ₹300 is spent elsewhere while the
    payment is in flight. The re-run sees ₹200 and refuses: no overdraft."""
    _fund(db, 500)
    request_id = _accepted(app, client)

    def spend_elsewhere():
        _wallet(db)["balance"] = 200.0

    _racing(monkeypatch, db, spend_elsewhere)
    r = _pay(app, client, request_id)
    assert r.status_code == 402 and r.json()["detail"]["available"] == 20000
    assert _ledger(db) == {} and _wallet(db)["balance"] == 200.0
    assert db.store[REQ + request_id]["paymentStatus"] == "payment_required"


def test_a_new_purchase_is_a_new_request_with_its_own_payment(db, app, client, sent):
    _fund(db, 5000)
    first = _accepted(app, client, "10_day")
    assert _pay(app, client, first).status_code == 200
    second = _accepted(app, client, "1_month")          # a renewal, requested while active
    assert _pay(app, client, second).json()["detail"] == "active_coaching_exists"
    db.store[f"personal_coaching/{ATHLETE}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(minutes=1)
    assert _pay(app, client, second).status_code == 200
    assert sorted(_ledger(db)) == sorted([f"wallet_transactions/prog_{first}",
                                          f"wallet_transactions/prog_{second}"])
    assert _wallet(db)["balance"] == 5000 - 499 - 1299


# ════════════════════════ Existing coaching rules hold ══════════════════════

@pytest.mark.parametrize("coach", [EXPERT, OTHER_EXPERT])
def test_running_coaching_is_never_replaced_or_doubled(db, app, client, sent, coach):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    rel = {"athleteId": ATHLETE, "coachId": coach, "status": "active", "coachingType": "FREE_TRIAL",
           "endDateTs": datetime.now(timezone.utc) + timedelta(days=3)}
    db.store[f"personal_coaching/{ATHLETE}"] = copy.deepcopy(rel)
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"] == "active_coaching_exists"
    assert db.store[f"personal_coaching/{ATHLETE}"] == rel
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


def test_an_ended_relationship_is_succeeded_by_the_program(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    db.store[f"personal_coaching/{ATHLETE}"] = {
        "athleteId": ATHLETE, "coachId": OTHER_EXPERT, "status": "expired",
        "endDateTs": datetime.now(timezone.utc) - timedelta(days=1)}
    assert _pay(app, client, request_id).status_code == 200
    assert db.store[f"personal_coaching/{ATHLETE}"]["coachId"] == EXPERT


def test_an_open_personal_coaching_request_blocks_payment(db, app, client, sent):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    db.store["personal_coach_requests/PCR_1"] = {
        "requestId": "PCR_1", "athleteId": ATHLETE, "expertId": OTHER_EXPERT, "status": "pending"}
    r = _pay(app, client, request_id)
    assert r.status_code == 409 and r.json()["detail"] == "open_request_exists"
    assert _ledger(db) == {}


# ═══════════════════ Policy switches, Razorpay, the rest of the wallet ══════

def test_the_wallet_freeze_refuses_program_payments(db, app, client, sent, monkeypatch):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    monkeypatch.setattr(wallet_config, "WALLET_FROZEN", True)
    monkeypatch.setattr(launch_config, "WALLET_ENABLED", False)
    r = _pay(app, client, request_id)
    assert r.status_code == 503 and r.json()["detail"]["error"] == "wallet_frozen"
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


def test_program_payments_have_their_own_off_switch(db, app, client, sent, monkeypatch):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    monkeypatch.setattr(launch_config, "COACHING_PROGRAMS_PAYMENT_ENABLED", False)
    r = _pay(app, client, request_id)
    assert r.status_code == 503 and r.json()["detail"]["error"] == "program_payments_disabled"
    assert _wallet(db)["balance"] == 1000 and _ledger(db) == {}


def test_an_already_paid_program_still_answers_while_payments_are_off(db, app, client, sent,
                                                                      monkeypatch):
    _fund(db, 1000)
    request_id = _accepted(app, client)
    _pay(app, client, request_id)
    monkeypatch.setattr(launch_config, "COACHING_PROGRAMS_PAYMENT_ENABLED", False)
    assert _pay(app, client, request_id).json()["already"] is True


def test_the_existing_monthly_coaching_stays_free():
    # Programs have their own switch; the legacy plans' policy is unchanged.
    assert launch_config.PERSONAL_COACHING_PAYMENT_REQUIRED is False
    assert launch_config.coaching_price(499) == 0


def test_razorpay_is_never_involved(db, app, client, sent, monkeypatch):
    def boom(*_a, **_k):
        raise AssertionError("Razorpay must not be called")

    monkeypatch.setattr(razorpay_service, "create_order", boom)
    _fund(db, 100)
    request_id = _accepted(app, client)
    assert _pay(app, client, request_id).status_code == 402      # short: no checkout
    _fund(db, 1000)
    assert _pay(app, client, request_id).status_code == 200      # funded: no checkout
    assert not any(k.startswith("razorpay_orders/") for k in db.store)


def test_the_payment_takes_no_body_fields():
    import inspect
    params = inspect.signature(routes.pay_for_program).parameters
    assert set(params) == {"request_id", "caller"}, "no amount, duration or expert from the client"
