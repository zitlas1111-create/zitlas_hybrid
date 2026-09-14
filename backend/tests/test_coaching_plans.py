"""
ZITLAS — Phase 4: the authoritative coaching diet + program completion
(backend/tests/test_coaching_plans.py)

  * POST /api/coaching-plans/{athleteId}/diet — the ONE place an expert's
    coaching diet is published: assigned coach, active relationship that
    covers diet, paid+active program when there is one, baseVersion checked
    (409 on a stale save), plan + version history in one commit, plan-updated
    notification only after the commit and never able to undo it;
  * the expiry sweep marks a Personal Coaching Program completed, keeps every
    piece of coaching history, and says how long the program actually was;
  * the Personal Coaching Report resolves a program by its programRequestId.
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

from routes import coaching_plans  # noqa: E402
from services import auth_service, coaching_sweep, firestore_service  # noqa: E402
from services import trial_report_service as trs  # noqa: E402
from services import trial_report_store  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
COACH = "coach_1"
OTHER = "coach_2"
BASE = "/api/coaching-plans"
PLAN = f"coaching_plans/{ATHLETE}"
REL = f"personal_coaching/{ATHLETE}"

DIET = {"days": [{"day": "Monday", "meals": [{
    "id": "breakfast", "name": "Breakfast", "time": "08:00",
    "options": [{"name": "Poha + buttermilk", "calories": 350, "protein": 12,
                 "notes": "keep it light"}]}]}]}


def _now():
    return datetime.now(timezone.utc)


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    client.store[f"users/{ATHLETE}"] = {"name": "Asha", "planId": "plan_A"}
    return client


@pytest.fixture
def pushes(monkeypatch, db):
    """Captures the post-commit notification, with the plan as it stood then."""
    calls = []

    def fake_send(_db, athlete_id, coach_uid, coach_name, kind):
        calls.append({"athlete": athlete_id, "coach": coach_uid, "name": coach_name,
                      "kind": kind, "planAtCall": copy.deepcopy(db.store.get(PLAN))})
        return {"sent": 1}

    monkeypatch.setattr(coaching_plans, "send_plan_updated", fake_send)
    return calls


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(coaching_plans.router, prefix=BASE)
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid):
    app.dependency_overrides[auth_service.verify_firebase_token] = lambda: {
        "uid": uid, "email": None, "name": "Coach", "admin": False, "expert": True}


def _rel(db, *, coach=COACH, status="active", plan_type="diet", end=None,
         program_request_id=None, source=None, end_iso=None):
    rel = {"athleteId": ATHLETE, "athleteName": "Asha", "coachId": coach,
           "coachName": "Coach One", "status": status, "planType": plan_type,
           "startDate": (_now() - timedelta(days=2)).isoformat()}
    if end is not False:
        end_dt = end or _now() + timedelta(days=5)
        rel["endDateTs"] = end_dt
        rel["endDate"] = end_dt.isoformat()
    if end_iso is not None:
        rel.pop("endDateTs", None)
        rel["endDate"] = end_iso
    if program_request_id:
        rel.update({"programRequestId": program_request_id, "programId": "10_day",
                    "source": source or "coaching_program", "requestId": None})
    elif source:
        rel["source"] = source
    db.store[REL] = rel
    return rel


def _program(db, *, status="active", payment="paid", expert=COACH, athlete=ATHLETE):
    db.store["coaching_program_requests/CPR_1"] = {
        "requestId": "CPR_1", "athleteId": athlete, "expertId": expert,
        "programId": "10_day", "durationDays": 10, "status": status,
        "paymentStatus": payment}


def _plan(db, version=3, **extra):
    db.store[PLAN] = {"athleteId": ATHLETE, "coachId": COACH, "coachName": "Coach One",
                      "diet": {"planId": "plan_A", "days": [{"day": "Monday", "meals": []}]},
                      "dietVersion": version, "dietUpdatedAt": "2026-09-01T00:00:00+00:00",
                      "dietSelections": {"Monday:breakfast": 1}, **extra}


def _save(app, client, base, *, diet=None, as_uid=COACH, **extra):
    _as(app, as_uid)
    return client.post(f"{BASE}/{ATHLETE}/diet",
                       json={"diet": diet if diet is not None else DIET,
                             "baseVersion": base, **extra})


def _versions(db):
    return {k: v for k, v in db.store.items() if k.startswith(PLAN + "/versions/")}


# ══════════════════════════════ Authorised saves ════════════════════════════

def test_the_assigned_coach_publishes_and_the_version_moves_on(db, app, client, pushes):
    _rel(db)
    _plan(db, version=3)
    r = _save(app, client, 3)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["success"] is True and body["dietVersion"] == 4 and body["notified"] is True
    doc = db.store[PLAN]
    assert doc["dietVersion"] == 4
    assert doc["diet"]["days"] == DIET["days"], "the complete plan is stored"
    assert doc["diet"]["planId"] == "plan_A", "stamped from the athlete's live record"
    assert doc["coachId"] == COACH and doc["dietUpdatedBy"] == COACH
    assert doc["dietUpdatedAt"] == body["dietUpdatedAt"]
    assert doc["dietSelections"] == {"Monday:breakfast": 1}, "the athlete's picks survive"
    [(_, version)] = _versions(db).items()
    assert version["type"] == "diet" and version["version"] == 4
    assert version["data"] == doc["diet"] and version["savedByUid"] == COACH


def test_the_first_save_creates_version_1(db, app, client, pushes):
    _rel(db)
    r = _save(app, client, 0)
    assert r.status_code == 200 and r.json()["dietVersion"] == 1
    assert db.store[PLAN]["dietVersion"] == 1


def test_consecutive_saves_count_up_and_keep_every_version(db, app, client, pushes):
    _rel(db)
    _plan(db, version=3)
    db.store[PLAN + "/versions/diet_1"] = {"type": "diet", "version": 3, "data": {"days": []}}
    assert _save(app, client, 3).json()["dietVersion"] == 4
    assert _save(app, client, 4).json()["dietVersion"] == 5
    versions = _versions(db)
    assert len(versions) == 3, "the older history snapshot is still there"
    assert sorted(v["version"] for v in versions.values()) == [3, 4, 5]


def test_a_version_stored_as_a_string_by_the_website_is_understood(db, app, client, pushes):
    _rel(db)
    _plan(db, version="7")
    assert _save(app, client, 7).json()["dietVersion"] == 8


def test_the_client_cannot_choose_the_coach_version_or_plan_id(db, app, client, pushes):
    _rel(db)
    _plan(db, version=2)
    forged = copy.deepcopy(DIET)
    forged["planId"] = "plan_FORGED"
    r = _save(app, client, 2, diet=forged, coachId=OTHER, dietVersion=99, expertId=OTHER)
    assert r.status_code == 200
    doc = db.store[PLAN]
    assert doc["coachId"] == COACH and doc["dietVersion"] == 3
    assert doc["diet"]["planId"] == "plan_A"


# ══════════════════════════ Stale editor protection ═════════════════════════

@pytest.mark.parametrize("base", [2, 4])
def test_a_stale_or_unknown_base_version_is_a_409_and_nothing_changes(db, app, client, pushes, base):
    _rel(db)
    _plan(db, version=3)
    before = copy.deepcopy(db.store)
    r = _save(app, client, base)
    assert r.status_code == 409
    assert r.json()["detail"] == {"error": "stale_version", "baseVersion": base,
                                  "currentVersion": 3,
                                  "dietUpdatedAt": "2026-09-01T00:00:00+00:00"}
    assert db.store == before, "the newer plan is never overwritten"
    assert pushes == [], "no notification for a save that did not happen"


def test_two_devices_from_the_same_version_only_one_publishes(db, app, client, pushes):
    _rel(db)
    _plan(db, version=10)
    device_a = _save(app, client, 10, diet={"days": [{"day": "Monday", "meals": [
        {"id": "a", "name": "A", "options": [{"name": "device A"}]}]}]})
    device_b = _save(app, client, 10)
    assert device_a.status_code == 200 and device_a.json()["dietVersion"] == 11
    assert device_b.status_code == 409
    assert db.store[PLAN]["diet"]["days"][0]["meals"][0]["name"] == "A"


# ══════════════════════════════ Who may publish ═════════════════════════════

def test_another_expert_is_refused(db, app, client, pushes):
    _rel(db)
    _plan(db, version=1)
    before = copy.deepcopy(db.store)
    r = _save(app, client, 1, as_uid=OTHER)
    assert r.status_code == 403 and r.json()["detail"] == "not_assigned_coach"
    assert db.store == before


def test_the_athlete_cannot_publish_their_own_coaching_diet(db, app, client, pushes):
    _rel(db)
    r = _save(app, client, 0, as_uid=ATHLETE)
    assert r.status_code == 403
    assert PLAN not in db.store


def test_no_relationship_is_refused(db, app, client, pushes):
    r = _save(app, client, 0)
    assert r.status_code == 403 and r.json()["detail"] == "no_coaching_relationship"


@pytest.mark.parametrize("status", ["ended", "expired", "reset", "pending"])
def test_an_inactive_relationship_is_refused(db, app, client, pushes, status):
    _rel(db, status=status)
    r = _save(app, client, 0)
    assert r.status_code == 403 and r.json()["detail"] == "coaching_not_active"
    assert PLAN not in db.store


def test_an_active_relationship_past_its_end_date_is_refused(db, app, client, pushes):
    _rel(db, end=_now() - timedelta(minutes=1))
    assert _save(app, client, 0).json()["detail"] == "coaching_not_active"
    _rel(db, end=False, end_iso=(_now() - timedelta(days=1)).isoformat())
    assert _save(app, client, 0).json()["detail"] == "coaching_not_active"


def test_a_legacy_relationship_without_any_end_date_still_works(db, app, client, pushes):
    _rel(db, end=False)
    assert _save(app, client, 0).status_code == 200


@pytest.mark.parametrize("plan_type, ok", [("diet", True), ("complete", True),
                                           (None, True), ("training", False)])
def test_the_relationship_must_cover_diet(db, app, client, pushes, plan_type, ok):
    _rel(db, plan_type=plan_type)
    r = _save(app, client, 0)
    if ok:
        assert r.status_code == 200, r.text
    else:
        assert r.status_code == 403 and r.json()["detail"] == "plan_does_not_cover_diet"


def test_a_paid_active_program_allows_its_expert_to_publish(db, app, client, pushes):
    _rel(db, program_request_id="CPR_1")
    _program(db)
    r = _save(app, client, 0)
    assert r.status_code == 200, r.text
    assert db.store[PLAN]["programRequestId"] == "CPR_1"
    assert db.store[PLAN]["programId"] == "10_day"


@pytest.mark.parametrize("status, payment, expert, detail", [
    ("completed", "paid", COACH, "program_not_active"),
    ("accepted", "payment_required", COACH, "program_not_active"),
    ("active", "unpaid", COACH, "program_not_active"),
    ("active", "paid", OTHER, "program_mismatch"),
])
def test_a_program_that_is_not_paid_and_active_is_refused(db, app, client, pushes,
                                                          status, payment, expert, detail):
    _rel(db, program_request_id="CPR_1")
    _program(db, status=status, payment=payment, expert=expert)
    r = _save(app, client, 0)
    assert r.status_code == 403 and r.json()["detail"] == detail
    assert PLAN not in db.store


def test_a_program_relationship_without_its_program_is_refused(db, app, client, pushes):
    _rel(db, program_request_id="CPR_1")
    assert _save(app, client, 0).json()["detail"] == "program_not_found"
    _rel(db, source="coaching_program")          # program source, no id at all
    assert _save(app, client, 0).json()["detail"] == "program_not_active"


def test_publishing_needs_sign_in(db, app, client, pushes):
    _rel(db)
    r = client.post(f"{BASE}/{ATHLETE}/diet", json={"diet": DIET, "baseVersion": 0})
    assert r.status_code == 401
    assert PLAN not in db.store


@pytest.mark.parametrize("diet", [
    {}, {"days": []}, {"days": "Monday"}, {"days": [1]},
    {"days": [{"day": "Mon", "meals": "x"}]},
    {"days": [{"day": "Mon", "meals": [{"options": "x"}]}]},
    {"days": [{"day": f"D{i}", "meals": []} for i in range(15)]},
    {"days": [{"day": "Mon", "meals": [{"name": "m"} for _ in range(21)]}]},
])
def test_malformed_diets_are_refused_and_nothing_is_written(db, app, client, pushes, diet):
    _rel(db)
    r = _save(app, client, 0, diet=diet)
    assert r.status_code == 400, r.text
    assert PLAN not in db.store


def test_a_negative_base_version_is_refused(db, app, client, pushes):
    _rel(db)
    assert _save(app, client, -1).status_code == 422


# ══════════════════════════ Notification after commit ══════════════════════

def test_the_athlete_is_notified_only_after_the_plan_is_committed(db, app, client, pushes):
    _rel(db)
    _plan(db, version=5)
    _save(app, client, 5)
    [call] = pushes
    assert call["kind"] == "diet" and call["athlete"] == ATHLETE and call["coach"] == COACH
    assert call["planAtCall"]["dietVersion"] == 6, "sent once the new version was stored"


def test_a_notification_failure_never_undoes_the_save(db, app, client, monkeypatch):
    _rel(db)
    _plan(db, version=1)

    def boom(*_a, **_k):
        raise RuntimeError("FCM unavailable")

    monkeypatch.setattr(coaching_plans, "send_plan_updated", boom)
    r = _save(app, client, 1)
    assert r.status_code == 200 and r.json()["notified"] is False
    assert db.store[PLAN]["dietVersion"] == 2


def test_the_real_plan_updated_notification_is_delivered(db, app, client):
    _rel(db)
    assert _save(app, client, 0).status_code == 200
    notes = [v for k, v in db.store.items() if k.startswith("notifications/")]
    assert any(n.get("userId") == ATHLETE and n.get("type") == "diet_updated" for n in notes)


# ══════════════════════════ Program completion (sweep) ══════════════════════

@pytest.fixture
def sweep(monkeypatch, db):
    sent, reports = [], []
    monkeypatch.setattr(coaching_sweep, "notify",
                        lambda _db, uid, title, message, **kw:
                        sent.append({"uid": uid, "title": title, "message": message, **kw}))
    monkeypatch.setattr(trial_report_store, "generate_and_store",
                        lambda athlete, request_id, **kw: reports.append((athlete, request_id))
                        or (None, False))
    return sent, reports


def _ended_program(db, days=10):
    start = _now() - timedelta(days=days, minutes=5)
    end = start + timedelta(days=days)
    db.store[REL] = {"athleteId": ATHLETE, "athleteName": "Asha", "coachId": COACH,
                     "coachName": "Coach One", "status": "active", "coachingType": "PAID",
                     "planType": "diet", "planLabel": f"{days}-Day Program",
                     "startDate": start.isoformat(), "endDate": end.isoformat(),
                     "endDateTs": end, "durationDays": days, "requestId": None,
                     "programRequestId": "CPR_1", "programId": "10_day",
                     "source": "coaching_program"}
    _program(db)
    db.store["coaching_program_requests/CPR_1"].update(
        {"durationDays": days, "pricePaise": 49900, "paidAt": start.isoformat()})


def test_an_expired_program_is_completed_and_every_history_record_is_kept(db, sweep):
    sent, reports = sweep
    _ended_program(db)
    _plan(db, version=6)
    db.store[PLAN + "/versions/diet_1"] = {"type": "diet", "version": 6, "data": {"days": []}}
    db.store["meal_checkins/MCI_1"] = {"athleteId": ATHLETE, "coachId": COACH, "status": "reviewed"}
    db.store["chat_rooms/chat_x"] = {"participants": [ATHLETE, COACH]}
    history = {k: copy.deepcopy(v) for k, v in db.store.items()
               if k.startswith((PLAN, "meal_checkins/", "chat_rooms/"))}

    assert coaching_sweep.sweep_expired_relationships() == 1

    assert db.store[REL]["status"] == "expired"
    program = db.store["coaching_program_requests/CPR_1"]
    assert program["status"] == "completed" and program["completedAt"]
    assert program["paymentStatus"] == "paid" and program["pricePaise"] == 49900
    for key, value in history.items():
        assert db.store[key] == value, f"{key} must survive the program ending"
    assert reports == [(ATHLETE, "CPR_1")], "the report is generated for the program"


@pytest.mark.parametrize("days", [10, 30, 90])
def test_the_completion_message_states_the_real_duration(db, sweep, days):
    sent, _ = sweep
    _ended_program(db, days=days)
    coaching_sweep.sweep_expired_relationships()
    athlete, coach = sent
    assert athlete["title"] == coach["title"] == "Program Completed"
    assert f"{days}-day Personal Coaching Program" in athlete["message"]
    assert f"{days}-day Personal Coaching Program" in coach["message"]
    if days != 30:
        assert "30-day" not in athlete["message"] + coach["message"]


def test_a_legacy_coaching_end_still_reads_its_real_length(db, sweep):
    sent, _ = sweep
    start = _now() - timedelta(days=30, minutes=5)
    end = start + timedelta(days=30)
    db.store[REL] = {"athleteId": ATHLETE, "coachId": COACH, "coachName": "Coach One",
                     "status": "active", "coachingType": "PAID", "requestId": "PCR_1",
                     "startDate": start.isoformat(), "endDate": end.isoformat(),
                     "endDateTs": end}
    coaching_sweep.sweep_expired_relationships()
    assert sent[0]["title"] == "Coaching Ended"
    assert "30-day Personal Coaching" in sent[0]["message"]


def test_a_program_already_closed_is_not_touched_again(db, sweep):
    _ended_program(db)
    db.store["coaching_program_requests/CPR_1"]["status"] = "completed"
    db.store["coaching_program_requests/CPR_1"]["completedAt"] = "2026-01-01T00:00:00+00:00"
    coaching_sweep.sweep_expired_relationships()
    assert db.store["coaching_program_requests/CPR_1"]["completedAt"] == "2026-01-01T00:00:00+00:00"


def test_a_running_program_is_left_alone(db, sweep):
    _ended_program(db)
    db.store[REL]["endDateTs"] = _now() + timedelta(days=1)
    assert coaching_sweep.sweep_expired_relationships() == 0
    assert db.store["coaching_program_requests/CPR_1"]["status"] == "active"


# ═════════════════════ Personal Coaching Report resolution ══════════════════

def _report_relationship(db, **overrides):
    start = datetime(2026, 3, 2, 9, 0, tzinfo=timezone.utc)
    end = start + timedelta(days=10)
    rel = {"athleteId": ATHLETE, "athleteName": "Asha", "coachId": COACH,
           "coachName": "Coach One", "coachingType": "PAID", "planType": "diet",
           "planLabel": "10-Day Program", "fee": 499.0, "paymentId": "prog_CPR_1",
           "subscriptionId": "prog_CPR_1", "status": "expired",
           "startDate": start.isoformat(), "endDate": end.isoformat(),
           "requestId": None, "programRequestId": "CPR_1", "durationDays": 10}
    rel.update(overrides)
    db.store[REL] = rel
    return end + timedelta(hours=1)


def test_the_report_resolves_a_program_by_its_program_request_id(db):
    moment = _report_relationship(db)
    report = trs.compute_trial_report(ATHLETE, "CPR_1", now=moment)
    assert report["engagementId"] == "CPR_1"
    assert report["coach"]["id"] == COACH


def test_the_legacy_request_id_still_resolves(db):
    moment = _report_relationship(db, requestId="PCR_9", programRequestId=None)
    assert trs.compute_trial_report(ATHLETE, "PCR_9", now=moment)["engagementId"] == "PCR_9"


def test_a_different_engagement_is_never_substituted(db):
    moment = _report_relationship(db)
    with pytest.raises(trs.EngagementUnavailable) as exc:
        trs.compute_trial_report(ATHLETE, "CPR_OTHER", now=moment)
    assert "Refusing to substitute" in str(exc.value)
    with pytest.raises(trs.EngagementUnavailable):
        trs.compute_trial_report(ATHLETE, None, now=moment)
