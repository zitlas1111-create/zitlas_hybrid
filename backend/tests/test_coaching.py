"""
ZITLAS — Personal Coaching escrow route tests (backend/tests/test_coaching.py)

Exercises the REAL routes/coaching.py and services/coaching_sweep.py
against fake_firestore.py's in-process fake (see that file's docstring for
what it does and doesn't reproduce). Builds a minimal FastAPI app with just
the coaching router — not the full main.py — so this suite doesn't pull in
RAG/KB loading or any other unrelated startup cost.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import coaching  # noqa: E402
from services import coaching_sweep, firestore_service  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402
import launch_config  # noqa: E402
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
    # Personal Coaching is FREE at launch (backend/launch_config.py), so the
    # server prices every plan at ₹0. The PAID escrow — reserve, debit, the
    # 80/20 split, idempotency — is kept whole for V2, and these tests are
    # what prove it still works. They opt into the paid model explicitly;
    # tests/test_launch_config.py pins the launch behaviour instead.
    monkeypatch.setattr(launch_config, "PERSONAL_COACHING_PAYMENT_REQUIRED", True)


ATHLETE_UID = "athlete_1"
EXPERT_UID = "expert_1"


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)

    # Force PAID pricing for the whole suite.
    #
    # routes/coaching.py zeroes every amount while CLIENT_TRIAL_MODE or
    # PLATFORM_CHARGES_FREE is on (the current promo policy), which made these
    # tests assert 499 against a runtime-configured 0 and fail — they were
    # silently coupled to a deployment flag rather than to the escrow they are
    # meant to cover. Pinning both here tests the MECHANISM: reserve, debit,
    # release, fee split. The free-platform path is a single documented branch
    # (`amount -> 0`) and is exercised by test_free_platform_mode_reserves_zero
    # below, which pins the flags the other way.
    monkeypatch.setattr(coaching, "CLIENT_TRIAL_MODE", False)
    monkeypatch.setattr(coaching, "PLATFORM_CHARGES_FREE", False)

    client.store["experts/expert_1"] = {
        "name": "Coach Test",
        "pricing": {"coachingDietPrice": 499, "coachingTrainingPrice": 699, "coachingCompletePrice": 999},
    }
    return client


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(coaching.router, prefix="/api/coaching")
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid):
    """Make subsequent requests through `app` authenticate as `uid`."""
    app.dependency_overrides[coaching.verify_firebase_token] = lambda: {"uid": uid, "email": None, "name": "Test"}


def _set_wallet(fake_db, uid, balance=0, reserved=0):
    fake_db.store[f"users/{uid}"] = {"wallet": {"balance": balance, "reserved": reserved,
                                                 "total_added": balance, "total_spent": 0, "transactions": []}}


def test_happy_path_reserve_accept_activates(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["amount"] == 499
    request_id = body["requestId"]

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 1000, "reserving must not touch balance"
    assert wallet["reserved"] == 499

    req_doc = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req_doc["status"] == "pending"
    assert req_doc["paymentStatus"] == "reserved"

    # Relationship must NOT exist before acceptance.
    assert fake_db.store.get(f"personal_coaching/{ATHLETE_UID}") is None

    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert r.status_code == 200, r.text

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 501, "balance - reserved amount"
    assert wallet["reserved"] == 0, "reservation fully released back on debit"

    req_doc = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req_doc["status"] == "active"
    assert req_doc["paymentStatus"] == "debited"

    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["status"] == "active"
    assert rel["coachId"] == EXPERT_UID

    txn = fake_db.store[f"wallet_transactions/{req_doc['walletTransactionId']}"]
    assert txn["grossAmount"] == 499
    assert txn["platformFee"] == round(499 * 0.20)
    assert txn["expertAmount"] == 499 - round(499 * 0.20)

    notifs = [d for p, d in fake_db.store.items() if p.startswith("notifications/")]
    assert any(n["userId"] == ATHLETE_UID and n["type"] == "coaching_accepted" for n in notifs)
    assert any(n["userId"] == EXPERT_UID and n["type"] == "coaching_started" for n in notifs)


def test_insufficient_balance_blocks_reservation(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=100)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 402
    detail = r.json()["detail"]
    assert detail["error"] == "insufficient_balance"
    assert detail["available"] == 100
    assert detail["required"] == 499

    created = [p for p in fake_db.store if p.startswith("personal_coach_requests/") and fake_db.store[p]]
    assert created == [], "no request doc should be created when the reservation is rejected"
    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 0, "a rejected reservation must never touch reserved"


def test_reject_releases_reservation(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]

    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/reject", json={"requestId": request_id})
    assert r.status_code == 200, r.text

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 1000, "balance untouched on reject"
    assert wallet["reserved"] == 0, "reservation released"

    req_doc = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req_doc["status"] == "declined"
    assert req_doc["paymentStatus"] == "released"
    assert fake_db.store.get(f"personal_coaching/{ATHLETE_UID}") is None

    notifs = [d for p, d in fake_db.store.items() if p.startswith("notifications/")]
    assert any(n["userId"] == ATHLETE_UID and n["type"] == "coaching_declined" for n in notifs)


def test_expiry_sweep_releases_reservation(fake_db, app, client, monkeypatch):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]

    # Backdate expiresAt so the sweep picks it up without waiting 48h.
    fake_db.store[f"personal_coach_requests/{request_id}"]["expiresAt"] = "2000-01-01T00:00:00+00:00"

    released = coaching_sweep.sweep_expired_requests()
    assert released == 1

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 0
    req_doc = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req_doc["status"] == "expired"
    assert req_doc["paymentStatus"] == "released_expired"

    # Running the sweep again must be a no-op (idempotent).
    assert coaching_sweep.sweep_expired_requests() == 0


def test_expiry_sweep_skips_already_accepted(fake_db, app, client):
    """A request the expert accepted in the same window the sweep is
    scanning must be left alone — no race between a human decision and the
    sweep (routes/coaching.py's docstring claims this; verify it)."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]

    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    fake_db.store[f"personal_coach_requests/{request_id}"]["expiresAt"] = "2000-01-01T00:00:00+00:00"
    released = coaching_sweep.sweep_expired_requests()
    assert released == 0

    req_doc = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req_doc["status"] == "active", "sweep must not clobber an already-active request"


def test_duplicate_request_blocked(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)

    r1 = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r1.status_code == 200

    r2 = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "training"})
    assert r2.status_code == 409
    assert r2.json()["detail"] == "open_request_exists"

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 499, "the second (rejected) attempt must not double-reserve"


def test_double_accept_is_idempotent_not_double_debit(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]

    _as(app, EXPERT_UID)
    r1 = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert r1.status_code == 200
    r2 = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert r2.status_code == 200
    assert r2.json()["already"] is True

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 501, "CRITICAL — must not be debited twice"


def test_expert_cannot_accept_someone_elses_request(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]

    _as(app, "some_other_expert")
    r = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert r.status_code == 403

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 499, "an unauthorized accept attempt must not touch money"


def test_unauthenticated_request_rejected(app, client):
    app.dependency_overrides.pop(coaching.verify_firebase_token, None)
    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 401


# ── Phase 2: 30-day subscription lifecycle ─────────────────────────────

def test_request_blocked_while_active_relationship_exists(fake_db, app, client):
    """An athlete already mid-subscription with one coach cannot reserve
    money for (and thus double-book) a second coach."""
    _set_wallet(fake_db, ATHLETE_UID, balance=2000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    fake_db.store["experts/expert_2"] = {"name": "Coach Two", "pricing": {"coachingDietPrice": 499}}
    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/request", json={"expertId": "expert_2", "planType": "diet"})
    assert r.status_code == 409
    assert r.json()["detail"] == "active_coaching_exists"

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 0, "the blocked second request must not reserve anything"


def test_request_allowed_once_relationship_past_enddate_even_before_sweep(fake_db, app, client):
    """Renewal must not require waiting on the 15-min sweep — if endDateTs
    has already passed, /request must not block even if status still says
    'active' (the sweep just hasn't caught up yet)."""
    _set_wallet(fake_db, ATHLETE_UID, balance=2000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    from datetime import datetime, timedelta, timezone
    fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(days=1)

    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 200, r.text


def test_relationship_sweep_expires_past_enddate(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=2000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    from datetime import datetime, timedelta, timezone
    fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(days=1)

    expired = coaching_sweep.sweep_expired_relationships()
    assert expired == 1

    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["status"] == "expired"

    notifs = [d for p, d in fake_db.store.items() if p.startswith("notifications/")]
    assert any(n["userId"] == ATHLETE_UID and n["type"] == "coaching_subscription_expired" for n in notifs)
    assert any(n["userId"] == EXPERT_UID and n["type"] == "coaching_subscription_expired" for n in notifs)

    # Idempotent — running again finds nothing left to expire.
    assert coaching_sweep.sweep_expired_relationships() == 0


def test_relationship_sweep_leaves_unexpired_relationships_alone(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=2000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    expired = coaching_sweep.sweep_expired_relationships()
    assert expired == 0
    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "active"


def test_relationship_sweep_syncs_request_status_paid(fake_db, app, client):
    """A PAID relationship that runs its full 30-day term must also close out
    its originating personal_coach_requests doc — otherwise the Expert
    Dashboard Inbox keeps showing an auto-expired client as still active,
    even though the live roster (personal_coaching) has already moved on."""
    _set_wallet(fake_db, ATHLETE_UID, balance=2000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    from datetime import datetime, timedelta, timezone
    fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(days=1)

    expired = coaching_sweep.sweep_expired_relationships()
    assert expired == 1
    assert fake_db.store[f"personal_coach_requests/{request_id}"]["status"] == "expired"


def test_relationship_sweep_syncs_request_status_free_trial(fake_db, app, client):
    """Same sync must hold for FREE_TRIAL relationships too — the fix needs
    no coachingType branch, mirroring /end's own type-agnostic pattern."""
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request",
        json={"expertId": EXPERT_UID, "planType": "diet", "requestType": "FREE_TRIAL"},
    ).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id, "durationDays": 5})

    from datetime import datetime, timedelta, timezone
    fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(days=1)

    expired = coaching_sweep.sweep_expired_relationships()
    assert expired == 1
    assert fake_db.store[f"personal_coach_requests/{request_id}"]["status"] == "expired"


def test_relationship_sweep_does_not_touch_a_foreign_request(fake_db, app, client):
    """If requestId on the relationship no longer belongs to this athlete
    (a stale/reused id), the sweep must not touch that foreign request."""
    _set_wallet(fake_db, ATHLETE_UID, balance=2000)
    _as(app, ATHLETE_UID)
    request_id = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    # Simulate the request doc having been re-pointed at a different athlete.
    fake_db.store[f"personal_coach_requests/{request_id}"]["athleteId"] = "someone_else"

    from datetime import datetime, timedelta, timezone
    fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(days=1)

    expired = coaching_sweep.sweep_expired_relationships()
    assert expired == 1
    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "expired"
    assert fake_db.store[f"personal_coach_requests/{request_id}"]["status"] != "expired"


# ══════════════════════════════════════════════════════════════════════
# Personal Coach assignment — the expert's side of the handshake
# ══════════════════════════════════════════════════════════════════════


def _notifications_for(fake_db, uid):
    """Every notifications/* doc addressed to `uid`."""
    return [d for k, d in fake_db.store.items()
            if k.startswith("notifications/") and d.get("userId") == uid]


def test_expert_is_notified_of_a_new_request(fake_db, app, client):
    """The expert is the one who has to act.

    Before this, only the athlete was told anything — an expert learned about a
    request solely by happening to have their dashboard open at the time.
    """
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    fake_db.store[f"users/{ATHLETE_UID}"]["name"] = "Rohit Sharma"
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 200, r.text

    to_expert = _notifications_for(fake_db, EXPERT_UID)
    assert len(to_expert) == 1, "the expert must be told exactly once"
    note = to_expert[0]
    assert note["title"] == "New Personal Coaching Request"
    assert "Rohit Sharma" in note["message"]
    assert note["type"] == "coaching_request_received"
    assert note["action"] == "expert_dashboard"
    assert note["isRead"] is False

    # The athlete still gets their own confirmation.
    assert len(_notifications_for(fake_db, ATHLETE_UID)) == 1


def test_request_carries_the_athlete_profile_the_expert_needs(fake_db, app, client):
    """Copied server-side because Security Rules (correctly) stop an expert
    reading users/{athleteId} until they are the ACTIVE coach."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    fake_db.store[f"users/{ATHLETE_UID}"].update({
        "name": "Rohit Sharma",
        "personalInfo": {
            "photo": "https://example.com/a.jpg",
            "gender": "male",
            "dob": "1998-04-12",
            "heightCm": 175,
            "weightKg": 72,
        },
        "goal": {"type": "muscle_gain"},
    })
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 200, r.text

    doc = fake_db.store[f"personal_coach_requests/{r.json()['requestId']}"]
    profile = doc["athleteProfile"]
    assert profile["photo"] == "https://example.com/a.jpg"
    assert profile["gender"] == "male"
    assert profile["heightCm"] == 175
    assert profile["weightKg"] == 72
    assert profile["goalType"] == "muscle_gain"
    # 72 / 1.75^2 = 23.5
    assert profile["bmi"] == 23.5
    assert profile["age"] and 20 < profile["age"] < 40


def test_profile_summary_omits_what_the_athlete_never_entered(fake_db, app, client):
    """A blank field stays blank. An expert acting on an invented weight is
    worse than one who can see the field is empty."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    profile = fake_db.store[f"personal_coach_requests/{r.json()['requestId']}"]["athleteProfile"]

    assert profile["heightCm"] is None
    assert profile["weightKg"] is None
    assert profile["bmi"] is None, "BMI must not be invented from a missing height"
    assert profile["age"] is None


def test_profile_summary_never_leaks_private_fields(fake_db, app, client):
    """The snapshot is a deliberate subset — not the user document."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    fake_db.store[f"users/{ATHLETE_UID}"].update({
        "personalInfo": {"email": "rohit@example.com", "mobile": "9999999999",
                         "city": "Pune", "gender": "male"},
        "membership": {"plan": "premium"},
    })
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    profile = fake_db.store[f"personal_coach_requests/{r.json()['requestId']}"]["athleteProfile"]

    assert set(profile.keys()) == {"photo", "gender", "age", "heightCm", "weightKg", "bmi", "goalType"}
    assert "email" not in profile
    assert "mobile" not in profile
    assert "wallet" not in profile


def test_request_identifies_the_expert_by_expertId(fake_db, app, client):
    """The field Security Rules and both dashboards query on.

    The rule used to check `coachId`, which these documents have never had, so
    no request was readable by the expert it was addressed to.
    """
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    doc = fake_db.store[f"personal_coach_requests/{r.json()['requestId']}"]

    assert doc["expertId"] == EXPERT_UID
    assert doc["athleteId"] == ATHLETE_UID
    assert "coachId" not in doc, "the requests collection identifies the expert as expertId"
    assert doc["status"] == "pending"
    assert doc["createdAt"] and doc["updatedAt"]


def test_accept_creates_the_assignment_and_stamps_updatedAt(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}
    ).json()["requestId"]

    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert r.status_code == 200, r.text

    # The assignment is ONE doc keyed by the athlete — it cannot duplicate.
    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["coachId"] == EXPERT_UID
    assert rel["athleteId"] == ATHLETE_UID
    assert rel["status"] == "active"
    assert rel["requestId"] == request_id

    req = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req["status"] == "active"
    assert req["updatedAt"]

    # And the athlete is told.
    titles = [n["title"] for n in _notifications_for(fake_db, ATHLETE_UID)]
    assert "Congratulations!" in titles


def test_reject_notifies_the_athlete_and_frees_them_to_choose_again(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}
    ).json()["requestId"]

    _as(app, EXPERT_UID)
    assert client.post("/api/coaching/reject", json={"requestId": request_id}).status_code == 200

    assert fake_db.store[f"personal_coach_requests/{request_id}"]["status"] == "declined"
    assert f"personal_coaching/{ATHLETE_UID}" not in fake_db.store

    titles = [n["title"] for n in _notifications_for(fake_db, ATHLETE_UID)]
    assert "Request declined" in titles

    # No open request remains, so another coach can be asked immediately.
    _as(app, ATHLETE_UID)
    again = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "training"})
    assert again.status_code == 200, again.text


# ══════════════════════════════════════════════════════════════════════
# END COACHING
# ══════════════════════════════════════════════════════════════════════


def _activate(fake_db, app, client):
    """Runs a real request+accept so an ACTIVE relationship exists."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    fake_db.store[f"users/{ATHLETE_UID}"]["name"] = "Rohit Sharma"
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}
    ).json()["requestId"]
    _as(app, EXPERT_UID)
    assert client.post("/api/coaching/accept", json={"requestId": request_id}).status_code == 200
    return request_id


def test_end_coaching_retires_the_relationship(fake_db, app, client):
    request_id = _activate(fake_db, app, client)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/end")
    assert r.status_code == 200, r.text

    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["status"] == "ended"
    assert rel["endedBy"] == "athlete"
    assert rel["endedAt"]

    # The originating request is closed too — a client cannot write this
    # collection at all, which is exactly why this lives server-side.
    assert fake_db.store[f"personal_coach_requests/{request_id}"]["status"] == "ended"


def test_end_coaching_deletes_nothing(fake_db, app, client):
    """Access ends; the athlete's record does not."""
    _activate(fake_db, app, client)
    fake_db.store[f"coaching_plans/{ATHLETE_UID}"] = {"diet": {"days": ["authored"]}}
    _as(app, ATHLETE_UID)

    assert client.post("/api/coaching/end").status_code == 200

    assert f"personal_coaching/{ATHLETE_UID}" in fake_db.store
    assert f"coaching_plans/{ATHLETE_UID}" in fake_db.store
    assert fake_db.store[f"coaching_plans/{ATHLETE_UID}"]["diet"]["days"] == ["authored"]
    # The wallet transaction from the accept is untouched — money that changed
    # hands is not unwound by ending a relationship.
    assert any(k.startswith("wallet_transactions/") for k in fake_db.store)


def test_end_coaching_notifies_both_sides(fake_db, app, client):
    _activate(fake_db, app, client)
    _as(app, ATHLETE_UID)
    before_coach = len(_notifications_for(fake_db, EXPERT_UID))

    assert client.post("/api/coaching/end").status_code == 200

    coach_notes = _notifications_for(fake_db, EXPERT_UID)
    assert len(coach_notes) == before_coach + 1
    assert "Rohit Sharma" in coach_notes[-1]["message"]
    assert coach_notes[-1]["type"] == "coaching_ended"

    athlete_notes = [n for n in _notifications_for(fake_db, ATHLETE_UID)
                     if n["type"] == "coaching_ended"]
    assert len(athlete_notes) == 1
    # The athlete is told their data survives — that is what they worry about.
    assert "still here" in athlete_notes[0]["message"]


def test_end_coaching_is_idempotent(fake_db, app, client):
    """A double-tap must not notify the coach twice."""
    _activate(fake_db, app, client)
    _as(app, ATHLETE_UID)

    assert client.post("/api/coaching/end").status_code == 200
    after_first = len(_notifications_for(fake_db, EXPERT_UID))

    r2 = client.post("/api/coaching/end")
    assert r2.status_code == 200
    assert r2.json()["already"] is True
    assert len(_notifications_for(fake_db, EXPERT_UID)) == after_first


def test_end_coaching_without_a_coach_is_a_404(fake_db, app, client):
    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/end")
    assert r.status_code == 404
    assert r.json()["detail"] == "no_coaching_relationship"


def test_ending_frees_the_athlete_to_request_again(fake_db, app, client):
    """No manual cleanup between one coach and the next."""
    _activate(fake_db, app, client)
    _as(app, ATHLETE_UID)
    assert client.post("/api/coaching/end").status_code == 200

    # Same plan, so this asserts the RELATIONSHIP guard released — not the
    # wallet. (The first coaching already spent 499 of the 1000, so a pricier
    # plan would fail on balance and prove nothing about ending.)
    again = client.post("/api/coaching/request",
                        json={"expertId": EXPERT_UID, "planType": "diet"})
    assert again.status_code == 200, again.text


def test_an_athlete_can_only_end_their_own_coaching(fake_db, app, client):
    """The route derives the athlete from the token, never from the body."""
    _activate(fake_db, app, client)

    # The EXPERT calling /end acts only on their own (nonexistent) relationship.
    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/end")
    assert r.status_code == 404

    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "active"


def test_free_platform_mode_reserves_zero(fake_db, app, client, monkeypatch):
    """The other side of the flag the fixture pins.

    With the free-platform policy on, the entire escrow still runs — a zero is
    reserved, the balance check cannot fail, and /accept debits zero — so the
    flag flips pricing without changing a single code path.
    """
    monkeypatch.setattr(coaching, "PLATFORM_CHARGES_FREE", True)
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 200, r.text
    assert r.json()["amount"] == 0

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 0

    _as(app, EXPERT_UID)
    accept = client.post("/api/coaching/accept", json={"requestId": r.json()["requestId"]})
    assert accept.status_code == 200, accept.text
    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "active"
    assert fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]["balance"] == 0


# ── POST /api/coaching/end — athlete-initiated end of an active relationship ──

def _reserve_accept_active(fake_db, app, client):
    """Drive a request -> accept so an ACTIVE relationship exists. Returns
    the request_id."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    rid = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}).json()["requestId"]
    _as(app, EXPERT_UID)
    assert client.post("/api/coaching/accept", json={"requestId": rid}).status_code == 200
    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "active"
    return rid


def test_end_coaching_flips_active_to_ended(fake_db, app, client):
    rid = _reserve_accept_active(fake_db, app, client)

    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/end")
    assert r.status_code == 200, r.text
    assert r.json()["success"] is True
    assert r.json()["already"] is False

    # (5,6,7) relationship flipped active -> ended, attributed to the athlete.
    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["status"] == "ended"
    assert rel["endedBy"] == "athlete"
    assert "endedAt" in rel

    # The originating request is closed so it leaves the expert's live queue.
    assert fake_db.store[f"personal_coach_requests/{rid}"]["status"] == "ended"

    # Both parties notified.
    notifs = [d for p, d in fake_db.store.items() if p.startswith("notifications/")]
    assert any(n["userId"] == ATHLETE_UID and n["type"] == "coaching_ended" for n in notifs)
    assert any(n["userId"] == EXPERT_UID and n["type"] == "coaching_ended" for n in notifs)


def test_end_coaching_without_relationship_returns_404(fake_db, app, client):
    _as(app, ATHLETE_UID)  # no relationship ever created
    r = client.post("/api/coaching/end")
    assert r.status_code == 404
    assert r.json()["detail"] == "no_coaching_relationship"


def test_end_coaching_is_idempotent(fake_db, app, client):
    _reserve_accept_active(fake_db, app, client)
    _as(app, ATHLETE_UID)

    first = client.post("/api/coaching/end")
    assert first.status_code == 200 and first.json()["already"] is False

    # Second end is a no-op success — must not error and must not re-notify.
    before = sum(1 for p in fake_db.store if p.startswith("notifications/"))
    second = client.post("/api/coaching/end")
    assert second.status_code == 200, second.text
    assert second.json()["already"] is True
    after = sum(1 for p in fake_db.store if p.startswith("notifications/"))
    assert after == before, "a repeated end must not send duplicate notifications"
    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "ended"


def test_end_coaching_requires_auth(app, client):
    # No dependency override -> real verify_firebase_token -> 401 (no token).
    r = client.post("/api/coaching/end")
    assert r.status_code == 401


# ══════════════════════════════════════════════════════════════════════
# FREE TRIAL — 5/10/15-day no-payment Personal Coaching
# ══════════════════════════════════════════════════════════════════════


def test_trial_request_created_with_zero_amount_and_no_plan_type(fake_db, app, client):
    """A trial request needs no wallet at all — balance=0 must still work,
    and planType/reservationAmount must reflect "nothing was reserved"."""
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request",
                     json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"})
    assert r.status_code == 200, r.text
    assert r.json()["amount"] == 0

    req_doc = fake_db.store[f"personal_coach_requests/{r.json()['requestId']}"]
    assert req_doc["requestType"] == "FREE_TRIAL"
    assert req_doc["planType"] is None
    assert req_doc["planLabel"] == "Personal Coaching Free Trial"
    assert req_doc["price"] == 0
    assert req_doc["reservationAmount"] == 0
    assert req_doc["status"] == "pending"

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["reserved"] == 0, "a trial must never touch the wallet"


def test_trial_amount_is_zero_even_with_pricing_flags_off(fake_db, app, client):
    """The key differentiator: fake_db already pins CLIENT_TRIAL_MODE=False,
    PLATFORM_CHARGES_FREE=False for this whole suite — a FREE_TRIAL request
    must still be ₹0, proving trial pricing is independent of that global,
    temporary "everything is free" switch."""
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)

    r = client.post("/api/coaching/request",
                     json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"})
    assert r.status_code == 200, r.text
    assert r.json()["amount"] == 0


def test_trial_accept_requires_valid_duration(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]

    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/accept", json={"requestId": request_id, "durationDays": 7})
    assert r.status_code == 400
    assert r.json()["detail"] == "invalid_trial_duration"

    r2 = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert r2.status_code == 400
    assert r2.json()["detail"] == "invalid_trial_duration"

    assert fake_db.store[f"personal_coach_requests/{request_id}"]["status"] == "pending", \
        "a rejected accept attempt must not activate anything"


@pytest.mark.parametrize("days", [5, 10, 15])
def test_trial_accept_with_5_10_15_sets_correct_end_date(fake_db, app, client, days):
    from datetime import datetime, timedelta, timezone

    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]

    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/accept", json={"requestId": request_id, "durationDays": days})
    assert r.status_code == 200, r.text

    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["coachingType"] == "FREE_TRIAL"
    assert rel["trialDurationDays"] == days
    assert rel["status"] == "active"

    expected_end = datetime.now(timezone.utc) + timedelta(days=days)
    actual_end = rel["endDateTs"]
    if actual_end.tzinfo is None:
        actual_end = actual_end.replace(tzinfo=timezone.utc)
    assert abs((actual_end - expected_end).total_seconds()) < 5


def test_trial_accept_does_not_create_wallet_transaction(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]

    _as(app, EXPERT_UID)
    r = client.post("/api/coaching/accept", json={"requestId": request_id, "durationDays": 5})
    assert r.status_code == 200, r.text

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 0
    assert wallet["reserved"] == 0
    assert not any(k.startswith("wallet_transactions/") for k in fake_db.store), \
        "a trial accept must never create a wallet_transactions doc"

    req_doc = fake_db.store[f"personal_coach_requests/{request_id}"]
    assert req_doc["walletTransactionId"] is None
    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["paymentId"] is None


def test_second_trial_request_after_accepted_is_blocked(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]
    _as(app, EXPERT_UID)
    assert client.post(
        "/api/coaching/accept", json={"requestId": request_id, "durationDays": 5}
    ).status_code == 200

    # End the trial so a NEW request isn't also blocked by the (unrelated)
    # active-relationship guard — isolates the trial-history guard itself.
    _as(app, ATHLETE_UID)
    assert client.post("/api/coaching/end").status_code == 200

    r = client.post("/api/coaching/request",
                     json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"})
    assert r.status_code == 409
    assert r.json()["detail"] == "trial_already_used"


def test_second_trial_request_after_decline_or_withdraw_is_allowed(fake_db, app, client):
    """A request that never reached 'active' didn't consume the athlete's
    one free trial with this expert."""
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]

    _as(app, EXPERT_UID)
    assert client.post("/api/coaching/reject", json={"requestId": request_id}).status_code == 200

    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/request",
                     json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"})
    assert r.status_code == 200, r.text


def test_athlete_with_active_paid_coach_cannot_start_trial_elsewhere(fake_db, app, client):
    """Reuses the existing active_coaching_exists guard unmodified — must
    fire identically for a FREE_TRIAL request."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"}
    ).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id})

    fake_db.store["experts/expert_2"] = {"name": "Coach Two", "pricing": {}}
    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/request",
                     json={"expertId": "expert_2", "requestType": "FREE_TRIAL"})
    assert r.status_code == 409
    assert r.json()["detail"] == "active_coaching_exists"


def test_trial_relationship_sweep_uses_trial_copy_not_30_day_text(fake_db, app, client):
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]
    _as(app, EXPERT_UID)
    client.post("/api/coaching/accept", json={"requestId": request_id, "durationDays": 5})

    from datetime import datetime, timedelta, timezone
    fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["endDateTs"] = datetime.now(timezone.utc) - timedelta(days=1)

    expired = coaching_sweep.sweep_expired_relationships()
    assert expired == 1
    assert fake_db.store[f"personal_coaching/{ATHLETE_UID}"]["status"] == "expired"

    athlete_notes = _notifications_for(fake_db, ATHLETE_UID)
    trial_note = next(n for n in athlete_notes if n["type"] == "coaching_subscription_expired")
    assert "5-day" in trial_note["message"]
    assert "30-day" not in trial_note["message"], "must never show the wrong (paid) duration"

    coach_notes = _notifications_for(fake_db, EXPERT_UID)
    coach_note = next(n for n in coach_notes if n["type"] == "coaching_subscription_expired")
    assert "30-day" not in coach_note["message"]


def test_trial_reject_and_expired_request_sweep_do_not_mention_reservation(fake_db, app, client):
    # Reject path.
    _set_wallet(fake_db, ATHLETE_UID, balance=0)
    _as(app, ATHLETE_UID)
    request_id = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]
    _as(app, EXPERT_UID)
    assert client.post("/api/coaching/reject", json={"requestId": request_id}).status_code == 200

    reject_note = next(n for n in _notifications_for(fake_db, ATHLETE_UID)
                        if n["type"] == "coaching_declined")
    assert "reserved" not in reject_note["message"].lower()

    # 48h pending-request expiry sweep path.
    _as(app, ATHLETE_UID)
    request_id_2 = client.post(
        "/api/coaching/request", json={"expertId": EXPERT_UID, "requestType": "FREE_TRIAL"}
    ).json()["requestId"]
    fake_db.store[f"personal_coach_requests/{request_id_2}"]["expiresAt"] = "2000-01-01T00:00:00+00:00"
    assert coaching_sweep.sweep_expired_requests() == 1

    expire_note = next(n for n in _notifications_for(fake_db, ATHLETE_UID)
                        if n["type"] == "coaching_expired")
    assert "reserved" not in expire_note["message"].lower()


def test_paid_coaching_still_debits_wallet_unchanged(fake_db, app, client):
    """Regression guard: the PAID path must remain byte-identical after the
    trial branches were added — same happy-path assertions as
    test_happy_path_reserve_accept_activates, re-asserted here as an
    explicit "trial didn't break paid" checkpoint."""
    _set_wallet(fake_db, ATHLETE_UID, balance=1000)
    _as(app, ATHLETE_UID)
    r = client.post("/api/coaching/request", json={"expertId": EXPERT_UID, "planType": "diet"})
    assert r.status_code == 200, r.text
    assert r.json()["amount"] == 499
    request_id = r.json()["requestId"]

    _as(app, EXPERT_UID)
    accept = client.post("/api/coaching/accept", json={"requestId": request_id})
    assert accept.status_code == 200, accept.text

    wallet = fake_db.store[f"users/{ATHLETE_UID}"]["wallet"]
    assert wallet["balance"] == 501
    rel = fake_db.store[f"personal_coaching/{ATHLETE_UID}"]
    assert rel["coachingType"] == "PAID"
    assert rel["trialDurationDays"] is None
    assert any(k.startswith("wallet_transactions/") for k in fake_db.store)
