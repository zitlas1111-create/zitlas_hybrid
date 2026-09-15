"""
ZITLAS — Personal Coaching Programs, PHASE 2 (backend/tests/test_coaching_programs.py)

Exercises the REAL routes/coaching_programs.py against fake_firestore.py:

    expert prices programs -> athlete requests one -> expert accepts / declines

and pins that requesting, accepting and declining NEVER move money: no wallet
change, no reservation, no debit, no Razorpay, no personal_coaching
activation, no escrow request. Paying (Phase 3) is covered by
tests/test_coaching_programs_payment.py.
"""

from __future__ import annotations

import ast
import copy
import sys
from datetime import timedelta
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import coaching_programs as routes  # noqa: E402
from services import auth_service, firestore_service  # noqa: E402
from services import coaching_programs as cp  # noqa: E402
from services.coaching_service import now  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
OTHER_ATHLETE = "athlete_2"
EXPERT = "expert_1"
OTHER_EXPERT = "expert_2"
UNAPPROVED = "expert_x"

BASE = "/api/coaching-programs"
PRICES = {"10_day": 49900, "1_month": 129900, "3_month": 349900}
DAYS = {"10_day": 10, "1_month": 30, "3_month": 90}
REQ_PREFIX = "coaching_program_requests/"


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    client.store[f"experts/{EXPERT}"] = {"name": "Coach One", "approved": True}
    client.store[f"experts/{OTHER_EXPERT}"] = {"name": "Coach Two", "approved": True}
    client.store[f"experts/{UNAPPROVED}"] = {"name": "Pending Coach", "approved": False}
    client.store[f"users/{ATHLETE}"] = {
        "name": "Asha",
        "wallet": {"balance": 1000, "reserved": 0, "total_added": 1000,
                   "total_spent": 0, "transactions": []},
    }
    client.store[f"users/{OTHER_ATHLETE}"] = {"name": "Ravi"}
    return client


@pytest.fixture
def sent(monkeypatch):
    """Captures notify() calls — delivery itself is notification_service's job."""
    calls = []

    def fake_notify(_db, uid, title, message, **kw):
        calls.append({"uid": uid, "title": title, "message": message, **kw})

    monkeypatch.setattr(routes, "notify", fake_notify)
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
        "uid": uid, "email": None, "name": "Token Name", "admin": False, "expert": expert,
    }


def _set_prices(db, expert=EXPERT, prices=PRICES):
    db.store[f"experts/{expert}"]["programPricing"] = {
        k: {"pricePaise": v, "currency": "INR", "updatedAt": "2026-09-01T00:00:00+00:00"}
        for k, v in prices.items()
    }


def _request(app, client, program="10_day", expert=EXPERT, athlete=ATHLETE, **extra):
    _as(app, athlete)
    return client.post(f"{BASE}/requests",
                       json={"expertId": expert, "programId": program, **extra})


def _requests(db):
    return {k: v for k, v in db.store.items() if k.startswith(REQ_PREFIX)}


def _only_request(db):
    docs = list(_requests(db).values())
    assert len(docs) == 1, docs
    return docs[0]


def _everything_but_requests(db):
    """Every document except the program requests themselves and the in-app
    notifications that announce them (the only intended side effect)."""
    return copy.deepcopy({k: v for k, v in db.store.items()
                          if not k.startswith((REQ_PREFIX, "notifications/"))})


def _decide(app, client, request_id, decision, as_uid=EXPERT, expert=True):
    _as(app, as_uid, expert=expert)
    return client.post(f"{BASE}/requests/{request_id}/{decision}")


# ═════════════════════════════ Expert pricing ═══════════════════════════════

def test_pricing_screen_loads_all_three_programs_unpriced(db, app, client):
    _as(app, EXPERT, expert=True)
    r = client.get(f"{BASE}/pricing/me")
    assert r.status_code == 200, r.text
    body = r.json()
    assert [p["programId"] for p in body["programs"]] == ["10_day", "1_month", "3_month"]
    assert [p["durationDays"] for p in body["programs"]] == [10, 30, 90]
    assert all(p["pricePaise"] is None and p["available"] is False for p in body["programs"])
    assert body["limits"] == {"minPaise": 100, "maxPaise": 5_000_000}
    assert body["currency"] == "INR"


def test_expert_sets_10_30_and_90_day_prices(db, app, client):
    _as(app, EXPERT, expert=True)
    r = client.put(f"{BASE}/pricing", json={"prices": PRICES})
    assert r.status_code == 200, r.text
    stored = db.store[f"experts/{EXPERT}"]["programPricing"]
    assert {k: v["pricePaise"] for k, v in stored.items()} == PRICES
    assert all(v["currency"] == "INR" and v["updatedAt"] for v in stored.values())
    assert db.store[f"experts/{EXPERT}"]["name"] == "Coach One", "profile untouched"

    got = client.get(f"{BASE}/pricing/me").json()
    assert {p["programId"]: p["pricePaise"] for p in got["programs"]} == PRICES


def test_null_stops_offering_and_an_unchanged_price_keeps_its_timestamp(db, app, client):
    _set_prices(db)
    _as(app, EXPERT, expert=True)
    r = client.put(f"{BASE}/pricing",
                   json={"prices": {"10_day": 49900, "1_month": 139900, "3_month": None}})
    assert r.status_code == 200, r.text
    stored = db.store[f"experts/{EXPERT}"]["programPricing"]
    assert set(stored) == {"10_day", "1_month"}
    assert stored["10_day"]["updatedAt"] == "2026-09-01T00:00:00+00:00"
    assert stored["1_month"]["pricePaise"] == 139900
    assert stored["1_month"]["updatedAt"] != "2026-09-01T00:00:00+00:00"


def test_a_program_left_out_is_unchanged(db, app, client):
    _set_prices(db)
    _as(app, EXPERT, expert=True)
    assert client.put(f"{BASE}/pricing", json={"prices": {"10_day": 59900}}).status_code == 200
    stored = db.store[f"experts/{EXPERT}"]["programPricing"]
    assert stored["10_day"]["pricePaise"] == 59900
    assert stored["3_month"]["pricePaise"] == PRICES["3_month"]


@pytest.mark.parametrize("bad, code", [
    (-100, "price_must_be_positive"),
    (0, "price_must_be_positive"),
    (99, "price_below_minimum"),
    (5_000_001, "price_above_maximum"),
    (10 ** 15, "price_above_maximum"),
    (499.5, "price_not_integer_paise"),
    (49900.0, "price_not_integer_paise"),
    ("49900", "price_not_integer_paise"),
    ("abc", "price_not_integer_paise"),
    (True, "price_not_integer_paise"),
    ([49900], "price_not_integer_paise"),
    ({"pricePaise": 49900}, "price_not_integer_paise"),
])
def test_invalid_prices_are_rejected_and_nothing_is_written(db, app, client, bad, code):
    _set_prices(db)
    before = copy.deepcopy(db.store[f"experts/{EXPERT}"])
    _as(app, EXPERT, expert=True)
    r = client.put(f"{BASE}/pricing", json={"prices": {"10_day": 59900, "1_month": bad}})
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == {"error": code, "programId": "1_month"}
    assert db.store[f"experts/{EXPERT}"] == before, "a rejected update writes NOTHING"


@pytest.mark.parametrize("raw", [
    '{"prices": {"10_day": NaN}}',
    '{"prices": {"10_day": Infinity}}',
    '{"prices": {"10_day": -Infinity}}',
    '{"prices": {"10_day": 1e309}}',
    '{"prices": {"10_day": 1e5}}',
])
def test_nan_infinity_and_float_spellings_are_rejected(db, app, client, raw):
    _as(app, EXPERT, expert=True)
    r = client.put(f"{BASE}/pricing", content=raw, headers={"Content-Type": "application/json"})
    assert r.status_code in (400, 422), r.text
    assert "programPricing" not in db.store[f"experts/{EXPERT}"]


@pytest.mark.parametrize("payload, code", [
    ({}, "prices_required"),
    ({"prices": {}}, "prices_required"),
    ({"prices": [49900]}, "prices_required"),
    ([], "prices_required"),
    ({"prices": {"7_day": 49900}}, "unknown_program"),
    ({"prices": {"10_day": 49900, "__proto__": 1}}, "unknown_program"),
])
def test_malformed_pricing_payloads_are_rejected(db, app, client, payload, code):
    _as(app, EXPERT, expert=True)
    r = client.put(f"{BASE}/pricing", json=payload)
    assert r.status_code == 400, r.text
    assert r.json()["detail"]["error"] == code
    assert "programPricing" not in db.store[f"experts/{EXPERT}"]


def test_an_athlete_cannot_set_any_pricing(db, app, client):
    _as(app, ATHLETE, expert=False)
    r = client.put(f"{BASE}/pricing", json={"prices": PRICES})
    assert r.status_code == 403
    assert r.json()["detail"] == "expert_required"
    assert "programPricing" not in db.store[f"experts/{EXPERT}"]
    assert client.get(f"{BASE}/pricing/me").status_code == 403


def test_an_unapproved_expert_cannot_set_pricing(db, app, client):
    _as(app, UNAPPROVED, expert=True)  # claim, but experts/{uid}.approved is False
    r = client.put(f"{BASE}/pricing", json={"prices": PRICES})
    assert r.status_code == 403
    assert "programPricing" not in db.store[f"experts/{UNAPPROVED}"]


def test_an_expert_can_only_ever_change_their_own_pricing(db, app, client):
    _set_prices(db)
    mine_before = copy.deepcopy(db.store[f"experts/{EXPERT}"])
    _as(app, OTHER_EXPERT, expert=True)
    # There is no expertId parameter; a smuggled one is ignored.
    r = client.put(f"{BASE}/pricing",
                   json={"prices": {"10_day": 100}, "expertId": EXPERT, "uid": EXPERT})
    assert r.status_code == 200, r.text
    assert db.store[f"experts/{EXPERT}"] == mine_before
    assert db.store[f"experts/{OTHER_EXPERT}"]["programPricing"]["10_day"]["pricePaise"] == 100


def test_pricing_requires_authentication(db, app, client):
    assert client.get(f"{BASE}/pricing/me").status_code == 401
    assert client.put(f"{BASE}/pricing", json={"prices": PRICES}).status_code == 401
    assert "programPricing" not in db.store[f"experts/{EXPERT}"]


def test_the_minimum_is_razorpays_own_minimum():
    from services import razorpay_service
    assert cp.MIN_PRICE_PAISE == razorpay_service._MIN_AMOUNT_PAISE


# ═════════════════════════ Athlete: prices on screen ════════════════════════

def test_athlete_sees_the_experts_server_side_prices(db, app, client):
    _set_prices(db)
    _as(app, ATHLETE)
    r = client.get(f"{BASE}/experts/{EXPERT}")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["expertName"] == "Coach One"
    assert {p["programId"]: p["pricePaise"] for p in body["programs"]} == PRICES
    assert all(p["available"] for p in body["programs"])
    assert body["request"] is None


def test_an_unconfigured_program_is_unavailable_never_free(db, app, client):
    _set_prices(db, prices={"10_day": 49900})
    _as(app, ATHLETE)
    programs = {p["programId"]: p for p in client.get(f"{BASE}/experts/{EXPERT}").json()["programs"]}
    assert programs["1_month"] == {**programs["1_month"], "pricePaise": None, "available": False}
    assert programs["3_month"]["pricePaise"] is None
    assert _request(app, client, "1_month").json()["detail"] == "program_unavailable"
    assert _requests(db) == {}


@pytest.mark.parametrize("stored", [0, -5, 99, "49900", 49900.0, True, 10 ** 12, None])
def test_a_tampered_stored_price_is_never_quoted_or_charged(db, app, client, stored):
    """The server re-validates on read: a value that reached Firestore some
    other way is 'not offered' — never ₹0, never a bargain."""
    db.store[f"experts/{EXPERT}"]["programPricing"] = {
        "10_day": {"pricePaise": stored, "currency": "INR"}}
    _as(app, ATHLETE)
    p = client.get(f"{BASE}/experts/{EXPERT}").json()["programs"][0]
    assert p["pricePaise"] is None and p["available"] is False
    r = _request(app, client, "10_day")
    assert r.status_code == 409 and r.json()["detail"] == "program_unavailable"


def test_a_non_inr_price_is_not_quoted(db, app, client):
    db.store[f"experts/{EXPERT}"]["programPricing"] = {
        "10_day": {"pricePaise": 49900, "currency": "USD"}}
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/experts/{EXPERT}").json()["programs"][0]["available"] is False


def test_an_unapproved_expert_offers_nothing(db, app, client):
    _set_prices(db, expert=UNAPPROVED)
    _as(app, ATHLETE)
    body = client.get(f"{BASE}/experts/{UNAPPROVED}").json()
    assert all(p["pricePaise"] is None for p in body["programs"])
    assert _request(app, client, "10_day", expert=UNAPPROVED).status_code == 404


def test_unknown_expert_is_404_and_viewing_needs_sign_in(db, app, client):
    assert client.get(f"{BASE}/experts/{EXPERT}").status_code == 401
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/experts/nobody").status_code == 404


# ═════════════════════════════ Athlete: requests ════════════════════════════

@pytest.mark.parametrize("program", ["10_day", "1_month", "3_month"])
def test_athlete_requests_a_program(db, app, client, sent, program):
    _set_prices(db)
    r = _request(app, client, program)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["success"] is True and body["alreadyRequested"] is False
    doc = _only_request(db)
    assert doc["requestId"] == body["request"]["requestId"]
    assert doc["requestId"].startswith("CPR_")
    assert doc["athleteId"] == ATHLETE and doc["athleteName"] == "Asha"
    assert doc["expertId"] == EXPERT and doc["expertName"] == "Coach One"
    assert doc["programId"] == program
    assert doc["programType"] == "diet"
    assert doc["durationDays"] == DAYS[program]
    assert doc["pricePaise"] == PRICES[program]
    assert doc["currency"] == "INR"
    assert doc["status"] == "pending_expert_acceptance"
    assert doc["paymentStatus"] == "unpaid"
    assert doc["requestedAt"]


def test_the_client_cannot_set_price_duration_state_or_identity(db, app, client):
    _set_prices(db)
    r = _request(app, client, "10_day",
                 pricePaise=1, price=1, amount=1, durationDays=365, programType="complete",
                 status="accepted", paymentStatus="paid", athleteId=OTHER_ATHLETE,
                 currency="USD", requestId="CPR_forged")
    assert r.status_code == 200, r.text
    doc = _only_request(db)
    assert doc["pricePaise"] == PRICES["10_day"]
    assert doc["durationDays"] == 10 and doc["programType"] == "diet"
    assert doc["status"] == "pending_expert_acceptance" and doc["paymentStatus"] == "unpaid"
    assert doc["athleteId"] == ATHLETE and doc["currency"] == "INR"
    assert doc["requestId"] != "CPR_forged"


def test_the_price_is_snapshotted_when_the_request_is_made(db, app, client):
    _set_prices(db)
    request_id = _request(app, client).json()["request"]["requestId"]
    _as(app, EXPERT, expert=True)
    assert client.put(f"{BASE}/pricing", json={"prices": {"10_day": 99900}}).status_code == 200
    assert db.store[REQ_PREFIX + request_id]["pricePaise"] == PRICES["10_day"]
    accepted = _decide(app, client, request_id, "accept").json()["request"]
    assert accepted["pricePaise"] == PRICES["10_day"], "accepting keeps the snapshot"


def test_asking_again_returns_the_request_already_waiting(db, app, client, sent):
    _set_prices(db)
    first = _request(app, client).json()["request"]
    again = _request(app, client)
    assert again.status_code == 200
    assert again.json()["alreadyRequested"] is True
    assert again.json()["request"]["requestId"] == first["requestId"]
    assert len(_requests(db)) == 1
    assert len([s for s in sent if s["uid"] == EXPERT]) == 1, "the expert is told once"


def test_a_second_program_with_the_same_expert_waits_for_the_first(db, app, client):
    _set_prices(db)
    first = _request(app, client, "10_day").json()["request"]
    r = _request(app, client, "3_month")
    assert r.status_code == 409
    assert r.json()["detail"] == {"error": "program_request_exists",
                                  "programId": "10_day", "requestId": first["requestId"]}
    assert len(_requests(db)) == 1


def test_an_accepted_request_is_still_open(db, app, client):
    _set_prices(db)
    request_id = _request(app, client).json()["request"]["requestId"]
    _decide(app, client, request_id, "accept")
    again = _request(app, client)
    assert again.json()["alreadyRequested"] is True
    assert again.json()["request"]["status"] == "accepted"
    assert _request(app, client, "1_month").status_code == 409


def test_after_a_decline_the_athlete_can_request_again(db, app, client):
    _set_prices(db)
    request_id = _request(app, client).json()["request"]["requestId"]
    _decide(app, client, request_id, "decline")
    r = _request(app, client, "1_month")
    assert r.status_code == 200 and r.json()["alreadyRequested"] is False
    assert len(_requests(db)) == 2


def test_a_different_expert_is_a_separate_request(db, app, client):
    _set_prices(db)
    _set_prices(db, expert=OTHER_EXPERT)
    assert _request(app, client, expert=EXPERT).status_code == 200
    assert _request(app, client, expert=OTHER_EXPERT).status_code == 200
    assert len(_requests(db)) == 2


def test_different_athletes_never_share_a_request(db, app, client):
    _set_prices(db)
    a = _request(app, client, athlete=ATHLETE).json()
    b = _request(app, client, athlete=OTHER_ATHLETE).json()
    assert a["request"]["requestId"] != b["request"]["requestId"]
    assert b["alreadyRequested"] is False


@pytest.mark.parametrize("program", ["", "7_day", "10_DAY", "diet", "../x"])
def test_an_unknown_program_is_rejected(db, app, client, program):
    _set_prices(db)
    r = _request(app, client, program)
    assert r.status_code in (400, 422)
    assert _requests(db) == {}


def test_an_athlete_cannot_request_their_own_program(db, app, client):
    _set_prices(db)
    r = _request(app, client, athlete=EXPERT, expert=EXPERT)
    assert r.status_code == 400 and r.json()["detail"] == "cannot_request_self"


def test_a_missing_expert_is_404(db, app, client):
    assert _request(app, client, expert="ghost").status_code == 404
    assert _request(app, client, expert="bad/id").status_code in (404, 405)
    assert _requests(db) == {}


def test_requesting_requires_authentication(db, app, client):
    _set_prices(db)
    r = client.post(f"{BASE}/requests", json={"expertId": EXPERT, "programId": "10_day"})
    assert r.status_code == 401
    assert _requests(db) == {}


def test_an_open_personal_coaching_request_still_blocks(db, app, client):
    _set_prices(db)
    db.store["personal_coach_requests/PCR_1"] = {
        "requestId": "PCR_1", "athleteId": ATHLETE, "expertId": OTHER_EXPERT, "status": "pending"}
    r = _request(app, client)
    assert r.status_code == 409 and r.json()["detail"] == "open_request_exists"
    assert db.store["personal_coach_requests/PCR_1"]["status"] == "pending", "left untouched"


def test_active_coaching_with_another_expert_blocks(db, app, client):
    _set_prices(db)
    db.store[f"personal_coaching/{ATHLETE}"] = {
        "athleteId": ATHLETE, "coachId": OTHER_EXPERT, "status": "active",
        "endDateTs": now() + timedelta(days=5)}
    r = _request(app, client)
    assert r.status_code == 409 and r.json()["detail"] == "active_coaching_exists"


def test_a_current_client_can_request_a_program_from_their_own_coach(db, app, client):
    _set_prices(db)
    rel = {"athleteId": ATHLETE, "coachId": EXPERT, "status": "active",
           "endDateTs": now() + timedelta(days=5)}
    db.store[f"personal_coaching/{ATHLETE}"] = copy.deepcopy(rel)
    assert _request(app, client).status_code == 200
    assert db.store[f"personal_coaching/{ATHLETE}"] == rel, "relationship untouched"


def test_an_ended_relationship_does_not_block(db, app, client):
    _set_prices(db)
    db.store[f"personal_coaching/{ATHLETE}"] = {
        "athleteId": ATHLETE, "coachId": OTHER_EXPERT, "status": "active",
        "endDateTs": now() - timedelta(days=1)}
    assert _request(app, client).status_code == 200


def test_the_expert_is_notified_of_a_new_request(db, app, client, sent):
    _set_prices(db)
    _request(app, client, "1_month")
    assert sent == [{
        "uid": EXPERT, "title": "New Program Request",
        "message": "Asha requested your 1-Month Program.",
        "category": "expert", "type": "coaching_program_request",
        "action": "expert_dashboard", "priority": "high",
    }]


def test_a_notification_failure_never_fails_the_request(db, app, client, monkeypatch):
    _set_prices(db)

    def boom(*_a, **_k):
        raise RuntimeError("fcm down")

    monkeypatch.setattr(routes, "notify", boom)
    r = _request(app, client)
    assert r.status_code == 200
    request_id = r.json()["request"]["requestId"]
    assert _decide(app, client, request_id, "accept").status_code == 200


def test_the_athlete_sees_their_request_status(db, app, client):
    _set_prices(db)
    request_id = _request(app, client).json()["request"]["requestId"]
    _as(app, ATHLETE)
    view = client.get(f"{BASE}/experts/{EXPERT}").json()["request"]
    assert view["status"] == "pending_expert_acceptance" and view["programId"] == "10_day"

    _decide(app, client, request_id, "accept")
    _as(app, ATHLETE)
    view = client.get(f"{BASE}/experts/{EXPERT}").json()["request"]
    assert view["status"] == "accepted" and view["paymentStatus"] == "payment_required"
    assert view["expertAccepted"] is True

    _as(app, OTHER_ATHLETE)
    assert client.get(f"{BASE}/experts/{EXPERT}").json()["request"] is None


# ══════════════════════════ Expert: accept / decline ════════════════════════

def _pending(db, app, client, program="10_day"):
    _set_prices(db)
    return _request(app, client, program).json()["request"]["requestId"]


def test_the_assigned_expert_sees_the_request_and_no_one_else_does(db, app, client):
    request_id = _pending(db, app, client)
    _as(app, EXPERT, expert=True)
    body = client.get(f"{BASE}/requests/expert").json()
    assert body["pendingCount"] == 1
    row = body["requests"][0]
    assert row["requestId"] == request_id
    assert (row["athleteName"], row["programTitle"], row["durationDays"], row["pricePaise"]) == \
        ("Asha", "10-Day Program", 10, PRICES["10_day"])
    assert row["requestedAt"]

    _as(app, OTHER_EXPERT, expert=True)
    assert client.get(f"{BASE}/requests/expert").json() == {"requests": [], "pendingCount": 0}


def test_athletes_cannot_list_expert_requests(db, app, client):
    _pending(db, app, client)
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/requests/expert").status_code == 403


def test_accept(db, app, client, sent):
    request_id = _pending(db, app, client)
    before = copy.deepcopy(db.store[REQ_PREFIX + request_id])
    r = _decide(app, client, request_id, "accept")
    assert r.status_code == 200, r.text
    assert r.json()["message"] == "Program request accepted. Payment is pending."
    doc = db.store[REQ_PREFIX + request_id]
    assert doc["status"] == "accepted" and doc["acceptedAt"]
    assert doc["expertAccepted"] is True
    assert doc["paymentStatus"] == "payment_required", "accepting charges nothing — payment is now due"
    changed = {k for k in set(doc) | set(before) if doc.get(k) != before.get(k)}
    decision = {"status", "acceptedAt", "expertAccepted", "paymentStatus"}
    # updatedAt may equal the request's own stamp on a coarse (Windows) clock.
    assert decision <= changed <= decision | {"updatedAt"}, "only the decision is written"
    assert sent[-1]["uid"] == ATHLETE and sent[-1]["title"] == "Program Request Accepted"
    assert "Pay from your ZITLAS Wallet to start." in sent[-1]["message"]


def test_a_repeated_accept_is_idempotent(db, app, client, sent):
    request_id = _pending(db, app, client)
    _decide(app, client, request_id, "accept")
    first = copy.deepcopy(db.store[REQ_PREFIX + request_id])
    notified = len(sent)
    again = _decide(app, client, request_id, "accept")
    assert again.status_code == 200 and again.json()["already"] is True
    assert db.store[REQ_PREFIX + request_id] == first
    assert len(sent) == notified, "no second notification"


def test_decline(db, app, client, sent):
    request_id = _pending(db, app, client)
    r = _decide(app, client, request_id, "decline")
    assert r.status_code == 200, r.text
    assert r.json()["message"] == "Program request declined."
    doc = db.store[REQ_PREFIX + request_id]
    assert doc["status"] == "declined" and doc["declinedAt"]
    assert doc["paymentStatus"] == "unpaid"
    assert "acceptedAt" not in doc
    assert sent[-1]["uid"] == ATHLETE and sent[-1]["title"] == "Program Request Declined"
    assert _decide(app, client, request_id, "decline").json()["already"] is True


@pytest.mark.parametrize("first, then", [("accept", "decline"), ("decline", "accept")])
def test_a_decided_request_cannot_be_flipped(db, app, client, first, then):
    request_id = _pending(db, app, client)
    _decide(app, client, request_id, first)
    settled = copy.deepcopy(db.store[REQ_PREFIX + request_id])
    r = _decide(app, client, request_id, then)
    assert r.status_code == 409 and r.json()["detail"]["error"] == "not_pending"
    assert db.store[REQ_PREFIX + request_id] == settled


@pytest.mark.parametrize("decision", ["accept", "decline"])
def test_an_unrelated_expert_cannot_decide(db, app, client, decision):
    request_id = _pending(db, app, client)
    before = copy.deepcopy(db.store[REQ_PREFIX + request_id])
    r = _decide(app, client, request_id, decision, as_uid=OTHER_EXPERT)
    assert r.status_code == 403 and r.json()["detail"] == "not_your_request"
    assert db.store[REQ_PREFIX + request_id] == before


@pytest.mark.parametrize("decision", ["accept", "decline"])
def test_the_athlete_cannot_decide_their_own_request(db, app, client, decision):
    request_id = _pending(db, app, client)
    r = _decide(app, client, request_id, decision, as_uid=ATHLETE, expert=False)
    assert r.status_code == 403 and r.json()["detail"] == "expert_required"
    # Even an athlete holding a (stale) expert claim is not the request's expert.
    r = _decide(app, client, request_id, decision, as_uid=ATHLETE, expert=True)
    assert r.status_code == 403
    assert db.store[REQ_PREFIX + request_id]["status"] == "pending_expert_acceptance"


def test_deciding_needs_sign_in_and_a_real_request(db, app, client):
    request_id = _pending(db, app, client)
    app.dependency_overrides.clear()
    assert client.post(f"{BASE}/requests/{request_id}/accept").status_code == 401
    assert _decide(app, client, "CPR_missing", "accept").status_code == 404


# ═══════════════════════ Phase 2 moves no money, starts nothing ═════════════

def test_request_accept_and_decline_touch_nothing_but_the_request(db, app, client):
    _set_prices(db)
    _set_prices(db, expert=OTHER_EXPERT)
    baseline = _everything_but_requests(db)

    accepted_id = _request(app, client, expert=EXPERT).json()["request"]["requestId"]
    declined_id = _request(app, client, expert=OTHER_EXPERT).json()["request"]["requestId"]
    assert _decide(app, client, accepted_id, "accept").status_code == 200
    assert _decide(app, client, declined_id, "decline", as_uid=OTHER_EXPERT).status_code == 200

    assert _everything_but_requests(db) == baseline, \
        "wallet, users, experts, personal_coaching, escrow — all unchanged"
    assert db.store[f"users/{ATHLETE}"]["wallet"] == {
        "balance": 1000, "reserved": 0, "total_added": 1000, "total_spent": 0, "transactions": []}
    for prefix in ("personal_coaching/", "personal_coach_requests/", "wallet_transactions/",
                   "razorpay_orders/", "payments/"):
        assert not any(k.startswith(prefix) for k in db.store), prefix
    assert {d["paymentStatus"] for d in _requests(db).values()} == {"payment_required", "unpaid"}
    assert not any(d.get("paidAt") for d in _requests(db).values())


def test_the_program_modules_never_reach_razorpay_premium_or_the_escrow():
    # Phase 3 legitimately uses the wallet freeze and launch policy guards
    # (wallet_config, launch_config). What stays out: Razorpay, the payment
    # routes (Premium / top-ups), entitlements, and the coaching escrow.
    here = Path(__file__).parent.parent
    forbidden = {"razorpay_service", "payment", "coaching", "entitlements", "membership"}
    for rel in ("routes/coaching_programs.py", "services/coaching_programs.py"):
        tree = ast.parse((here / rel).read_text(encoding="utf-8"))
        names = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                names.add((node.module or "").rsplit(".", 1)[-1])
                names.update(a.name for a in node.names)
            elif isinstance(node, ast.Import):
                names.update(a.name.rsplit(".", 1)[-1] for a in node.names)
        assert not (names & forbidden), f"{rel} imports {names & forbidden}"


# ═══════════════ Athlete: Get Started — choose an expert for a program ══════════

def test_the_expert_list_offers_only_approved_experts_who_price_the_program(db, app, client):
    _set_prices(db, expert=EXPERT)
    _set_prices(db, expert=OTHER_EXPERT, prices={"10_day": 39900})
    _set_prices(db, expert=UNAPPROVED)
    _as(app, ATHLETE)
    r = client.get(f"{BASE}/programs/10_day/experts")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["programId"] == "10_day"
    assert [(e["expertId"], e["expertName"], e["pricePaise"]) for e in body["experts"]] == [
        (EXPERT, "Coach One", 49900), (OTHER_EXPERT, "Coach Two", 39900)]
    three = client.get(f"{BASE}/programs/3_month/experts").json()
    assert [e["expertId"] for e in three["experts"]] == [EXPERT], "only experts who price it"


@pytest.mark.parametrize("program,days", [("10_day", 10), ("1_month", 30), ("3_month", 90)])
def test_the_expert_list_carries_the_servers_price_and_duration(db, app, client, program, days):
    _set_prices(db)
    _as(app, ATHLETE)
    body = client.get(f"{BASE}/programs/{program}/experts").json()
    assert body["durationDays"] == days
    assert body["experts"][0]["pricePaise"] == PRICES[program]


@pytest.mark.parametrize("stored", [0, -5, 99, "49900", 49900.0, True, None])
def test_a_tampered_price_keeps_an_expert_off_the_list(db, app, client, stored):
    db.store[f"experts/{EXPERT}"]["programPricing"] = {
        "10_day": {"pricePaise": stored, "currency": "INR"}}
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/programs/10_day/experts").json()["experts"] == []


def test_an_expert_is_never_offered_their_own_program(db, app, client):
    _set_prices(db)
    _as(app, EXPERT, expert=True)
    assert client.get(f"{BASE}/programs/10_day/experts").json()["experts"] == []


def test_the_expert_list_needs_sign_in_and_a_real_program(db, app, client):
    assert client.get(f"{BASE}/programs/10_day/experts").status_code == 401
    _as(app, ATHLETE)
    r = client.get(f"{BASE}/programs/7_day/experts")
    assert r.status_code == 400 and r.json()["detail"] == "invalid_program"


def test_listing_experts_writes_nothing_and_moves_no_money(db, app, client):
    _set_prices(db)
    before = copy.deepcopy(db.store)
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/programs/1_month/experts").status_code == 200
    assert db.store == before


def test_the_listed_price_is_the_price_the_request_records(db, app, client):
    _set_prices(db)
    _as(app, ATHLETE)
    listed = client.get(f"{BASE}/programs/1_month/experts").json()["experts"][0]
    r = _request(app, client, "1_month", expert=listed["expertId"])
    assert r.status_code == 200, r.text
    assert r.json()["request"]["pricePaise"] == listed["pricePaise"]
    assert r.json()["request"]["durationDays"] == 30


# ═════════ Athlete: my current program — restored after a restart or refresh ═════════

def test_my_requests_are_empty_before_asking(db, app, client):
    _as(app, ATHLETE)
    r = client.get(f"{BASE}/requests/me")
    assert r.status_code == 200, r.text
    assert r.json() == {"requests": [], "current": None}


def test_my_open_request_is_the_current_one(db, app, client):
    _set_prices(db)
    rid = _request(app, client, "1_month").json()["request"]["requestId"]
    _as(app, ATHLETE)
    body = client.get(f"{BASE}/requests/me").json()
    assert body["current"]["requestId"] == rid
    assert body["current"]["status"] == cp.STATUS_PENDING
    assert body["current"]["durationDays"] == 30
    assert body["current"]["pricePaise"] == PRICES["1_month"]
    assert [r["requestId"] for r in body["requests"]] == [rid]


def test_an_accepted_request_is_still_current(db, app, client):
    _set_prices(db)
    rid = _request(app, client).json()["request"]["requestId"]
    assert _decide(app, client, rid, "accept").status_code == 200
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/requests/me").json()["current"]["status"] == cp.STATUS_ACCEPTED


def test_a_declined_request_is_history_not_current(db, app, client):
    _set_prices(db)
    rid = _request(app, client).json()["request"]["requestId"]
    _decide(app, client, rid, "decline")
    _as(app, ATHLETE)
    body = client.get(f"{BASE}/requests/me").json()
    assert body["current"] is None
    assert body["requests"][0]["status"] == cp.STATUS_DECLINED


@pytest.mark.parametrize("ends_in_days,is_current", [(5, True), (-1, False)])
def test_a_paid_program_is_current_only_while_it_runs(db, app, client, ends_in_days, is_current):
    _set_prices(db)
    rid = _request(app, client).json()["request"]["requestId"]
    end = now() + timedelta(days=ends_in_days)
    db.store[f"{REQ_PREFIX}{rid}"].update({
        "status": cp.STATUS_ACTIVE, "paymentStatus": cp.PAYMENT_PAID, "endsAt": end.isoformat()})
    _as(app, ATHLETE)
    current = client.get(f"{BASE}/requests/me").json()["current"]
    assert (current is not None) == is_current


def test_a_completed_program_is_history_not_current(db, app, client):
    _set_prices(db)
    rid = _request(app, client).json()["request"]["requestId"]
    db.store[f"{REQ_PREFIX}{rid}"].update({"status": cp.STATUS_COMPLETED, "paymentStatus": cp.PAYMENT_PAID})
    _as(app, ATHLETE)
    body = client.get(f"{BASE}/requests/me").json()
    assert body["current"] is None
    assert body["requests"][0]["status"] == cp.STATUS_COMPLETED


def test_my_requests_are_mine_only_and_need_sign_in(db, app, client):
    assert client.get(f"{BASE}/requests/me").status_code == 401
    _set_prices(db)
    _request(app, client, athlete=OTHER_ATHLETE)
    _as(app, ATHLETE)
    assert client.get(f"{BASE}/requests/me").json() == {"requests": [], "current": None}


def test_the_expert_list_shows_photo_and_expertise_when_the_profile_has_them(db, app, client):
    _set_prices(db)
    db.store[f"experts/{EXPERT}"].update({
        "specialization": "Sports Nutritionist",
        "profilePhoto": "https://cdn.example/coach-one.jpg",
        "specialties": ["Fat loss", "Muscle gain", " ", 7, "PCOS", "Diabetes", "Athletes"],
    })
    _set_prices(db, expert=OTHER_EXPERT)
    db.store[f"experts/{OTHER_EXPERT}"]["photo"] = "data:image/png;base64,AAAA"
    _as(app, ATHLETE)
    by_id = {e["expertId"]: e for e in client.get(f"{BASE}/programs/10_day/experts").json()["experts"]}
    assert by_id[EXPERT]["specialization"] == "Sports Nutritionist"
    assert by_id[EXPERT]["photoUrl"] == "https://cdn.example/coach-one.jpg"
    assert by_id[EXPERT]["expertise"] == ["Fat loss", "Muscle gain", "PCOS", "Diabetes"]
    assert by_id[OTHER_EXPERT]["photoUrl"] is None, "only an http(s) URL is a photo"
    assert by_id[OTHER_EXPERT]["expertise"] == []
