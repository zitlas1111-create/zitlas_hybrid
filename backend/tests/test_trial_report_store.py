"""
ZITLAS — Trial Completion Report persistence, lifecycle and API tests
(backend/tests/test_trial_report_store.py)

Covers what Step 3 added on top of the pure computation layer:
persistence, idempotency, failure safety, lifecycle integration, and the
read API's authorization. The calculation itself is covered by
tests/test_trial_report.py and is not re-tested here.

THE TWO PROPERTIES THESE TESTS EXIST TO PROTECT:

  IMMUTABILITY — once a report is stored, nothing changes it. Not a second
  sweep, not a coach editing the plan afterwards, not a new check-in. The
  snapshot test at the bottom mutates every input the report was built from
  and asserts the stored document is byte-identical.

  THE LIFECYCLE OUTRANKS THE REPORT — a report that cannot be built must
  never leave a coaching engagement stuck 'active'. Several tests below break
  report generation deliberately and assert the expiry still completes.
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

from routes import trial_report as trial_report_route  # noqa: E402
from services import firestore_service  # noqa: E402
from services import trial_report_service as trs  # noqa: E402
from services import trial_report_store as store  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
COACH = "coach_1"
OTHER = "athlete_2"
ENGAGEMENT = "req_trial_abc"

START = datetime(2026, 3, 2, 9, 0, tzinfo=timezone.utc)
END = START + timedelta(days=10)
NOW = END + timedelta(hours=1)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    return client


def _seed(db, *, status="expired", request_id=ENGAGEMENT, meals=3):
    db.store[f"personal_coaching/{ATHLETE}"] = {
        "athleteId": ATHLETE, "athleteName": "Test Athlete",
        "coachId": COACH, "coachName": "Coach Test",
        "coachingType": "FREE_TRIAL", "trialDurationDays": 10,
        "planType": None, "planLabel": "Personal Coaching Free Trial",
        "fee": 0, "paymentId": None, "subscriptionId": "sub_1",
        "requestId": request_id,
        "startDate": _iso(START), "endDate": _iso(END),
        "status": status, "endedAt": None, "expiredAt": _iso(END),
        "endDateTs": END,
    }
    db.store[f"users/{ATHLETE}"] = {
        "planId": "plan_A", "currentStreak": 4, "longestStreak": 9,
        "dietPlan": {"days": [{"meals": [{}] * meals} for _ in range(7)]},
    }
    for offset in range(3):
        ts = START + timedelta(days=offset, hours=2)
        db.store[f"meal_checkins/MCI_{offset}"] = {
            "checkinId": f"MCI_{offset}", "athleteId": ATHLETE,
            "coachId": COACH, "day": ts.strftime("%A"), "mealType": "breakfast",
            "mealName": "Breakfast", "timestamp": _iso(ts),
            "status": "reviewed", "overallRating": 4,
            "reviewedAt": _iso(ts + timedelta(hours=1)),
            "reviewedBy": "Coach Test",
        }
    return db


# ══════════════════════════════════════════════════════════════════════════
# Persistence
# ══════════════════════════════════════════════════════════════════════════


class TestPersistence:
    def test_report_is_created_with_the_right_identity(self, fake_db):
        _seed(fake_db)
        report, created = store.generate_and_store(
            ATHLETE, ENGAGEMENT, now=NOW)
        assert created is True
        assert report["requestId"] == ENGAGEMENT
        assert report["athleteId"] == ATHLETE
        assert report["coachId"] == COACH
        assert report["coachName"] == "Coach Test"
        assert report["coachingType"] == "FREE_TRIAL"
        assert report["status"] == store.STATUS_GENERATED
        assert report["generatedAt"]
        assert report["storedAt"]

    def test_stored_at_the_request_id_not_the_athlete_id(self, fake_db):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert f"trial_reports/{ENGAGEMENT}" in fake_db.store
        assert f"trial_reports/{ATHLETE}" not in fake_db.store

    def test_period_is_snapshotted(self, fake_db):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        period = report["period"]
        assert period["startDate"] == _iso(START)
        assert period["durationDays"] == 10
        assert period["elapsedDays"] == 10       # slots, not calendar dates
        assert period["trialDurationDays"] == 10

    def test_computed_metrics_are_embedded_whole(self, fake_db):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        metrics = report["metrics"]
        for key in ("mealFollowThrough", "mealQuality", "expertEngagement",
                    "workoutAdherence", "planAdherence", "planEvolution",
                    "followUp", "progress", "overall"):
            assert key in metrics
        assert metrics["mealFollowThrough"]["expected"] == 30
        assert metrics["mealQuality"]["reviewedMeals"] == 3

    def test_plan_evolution_is_persisted_with_its_segments(self, fake_db):
        _seed(fake_db)
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_1"] = {
            "type": "diet", "version": 1,
            "savedAt": _iso(START + timedelta(days=3)), "savedBy": "Coach Test",
            "data": {"planId": "plan_A", "days": [
                {"day": d, "meals": [{}, {}, {}, {}]}
                for d in ["Monday", "Tuesday", "Wednesday", "Thursday",
                          "Friday", "Saturday", "Sunday"]]},
        }
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        evolution = report["metrics"]["planEvolution"]
        assert evolution["startedFrom"] == trs.SOURCE_AI
        assert evolution["coachCustomizedPlanApplied"] is True
        assert evolution["wording"] == "coach_customized_ai_plan"
        assert len(evolution["segments"]) == 2
        # The segments must carry their own resolved meal counts, so the
        # report never needs the live planId again to be readable.
        assert evolution["segments"][0]["mealsByWeekday"]["monday"] == 3
        assert evolution["segments"][1]["mealsByWeekday"]["monday"] == 4

    def test_data_quality_is_persisted(self, fake_db):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["dataQuality"]["warnings"]
        assert report["dataQuality"]["dayModels"]["mealExpectations"] == (
            "elapsed_24h_engagement_slots")

    def test_get_report_returns_the_snapshot(self, fake_db):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert store.get_report(ENGAGEMENT)["requestId"] == ENGAGEMENT

    def test_get_report_is_none_when_absent(self, fake_db):
        assert store.get_report("nope") is None


# ══════════════════════════════════════════════════════════════════════════
# Idempotency
# ══════════════════════════════════════════════════════════════════════════


class TestIdempotency:
    def test_second_generation_does_not_overwrite(self, fake_db):
        _seed(fake_db)
        first, created_first = store.generate_and_store(
            ATHLETE, ENGAGEMENT, now=NOW)
        assert created_first is True
        snapshot = copy.deepcopy(fake_db.store[f"trial_reports/{ENGAGEMENT}"])

        second, created_second = store.generate_and_store(
            ATHLETE, ENGAGEMENT, now=NOW + timedelta(days=1))
        assert created_second is False
        assert second == first
        assert fake_db.store[f"trial_reports/{ENGAGEMENT}"] == snapshot

    def test_duplicate_sweep_runs_create_only_one_report(self, fake_db):
        _seed(fake_db)
        for _ in range(4):
            store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert len([k for k in fake_db.store
                    if k.startswith("trial_reports/")]) == 1

    def test_create_report_refuses_when_one_exists(self, fake_db):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        again, created = store.create_report(
            ENGAGEMENT, {**report, "metrics": {"tampered": True}}, now=NOW)
        assert created is False
        assert again["metrics"] != {"tampered": True}

    def test_a_second_engagement_gets_its_own_report(self, fake_db):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        # The athlete starts a NEW engagement; personal_coaching is
        # overwritten, which is exactly why identity is the requestId.
        _seed(fake_db, request_id="req_SECOND")
        store.generate_and_store(ATHLETE, "req_SECOND", now=NOW)
        assert f"trial_reports/{ENGAGEMENT}" in fake_db.store
        assert "trial_reports/req_SECOND" in fake_db.store


# ══════════════════════════════════════════════════════════════════════════
# Failure safety
# ══════════════════════════════════════════════════════════════════════════


class TestFailureSafety:
    def test_computation_failure_returns_none_and_writes_nothing(
            self, fake_db, monkeypatch):
        _seed(fake_db)

        def boom(*a, **k):
            raise RuntimeError("computation exploded")

        monkeypatch.setattr(store, "compute_trial_report", boom)
        report, created = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert report is None and created is False
        # No half-written document is left behind, so a retry is clean.
        assert not [k for k in fake_db.store if k.startswith("trial_reports/")]

    def test_a_failed_generation_can_be_retried_successfully(
            self, fake_db, monkeypatch):
        _seed(fake_db)
        calls = {"n": 0}
        real = store.compute_trial_report

        def flaky(*a, **k):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("transient")
            return real(*a, **k)

        monkeypatch.setattr(store, "compute_trial_report", flaky)
        assert store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)[0] is None
        report, created = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert created is True and report["requestId"] == ENGAGEMENT

    def test_superseded_engagement_fails_cleanly(self, fake_db):
        _seed(fake_db, request_id="req_NEWER")
        report, created = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert report is None and created is False
        assert not [k for k in fake_db.store if k.startswith("trial_reports/")]

    def test_malformed_existing_report_is_never_overwritten(self, fake_db):
        _seed(fake_db)
        junk = {"requestId": ENGAGEMENT, "oops": True}
        fake_db.store[f"trial_reports/{ENGAGEMENT}"] = junk
        report, created = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        assert report is None and created is False
        assert fake_db.store[f"trial_reports/{ENGAGEMENT}"] == junk

    def test_create_report_raises_reportmalformed_directly(self, fake_db):
        _seed(fake_db)
        fake_db.store[f"trial_reports/{ENGAGEMENT}"] = {"broken": True}
        with pytest.raises(store.ReportMalformed):
            store.create_report(ENGAGEMENT, {"any": "thing"}, now=NOW)

    def test_unconfigured_firestore_is_a_no_op(self, monkeypatch):
        monkeypatch.setattr(firestore_service, "get_client", lambda: None)
        report, created = store.generate_and_store(ATHLETE, ENGAGEMENT)
        assert report is None and created is False

    def test_validate_names_the_missing_fields(self):
        assert "metrics" in store.validate({"requestId": "x"})
        assert store.validate("not a dict")
        assert store.validate(None)


# ══════════════════════════════════════════════════════════════════════════
# Lifecycle integration — the report must never break trial expiry
# ══════════════════════════════════════════════════════════════════════════


class TestLifecycleIntegration:
    def _sweep(self, fake_db, monkeypatch):
        from services import coaching_sweep

        monkeypatch.setattr(coaching_sweep, "notify",
                            lambda *a, **k: None)
        monkeypatch.setattr(coaching_sweep, "now", lambda: NOW)
        return coaching_sweep

    def test_expiry_sweep_generates_the_report(self, fake_db, monkeypatch):
        _seed(fake_db, status="active")
        sweep = self._sweep(fake_db, monkeypatch)
        assert sweep.sweep_expired_relationships() == 1
        assert fake_db.store[f"personal_coaching/{ATHLETE}"]["status"] == "expired"
        assert f"trial_reports/{ENGAGEMENT}" in fake_db.store

    def test_expiry_still_completes_when_report_generation_explodes(
            self, fake_db, monkeypatch):
        _seed(fake_db, status="active")
        sweep = self._sweep(fake_db, monkeypatch)
        monkeypatch.setattr(
            store, "generate_and_store",
            lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")))

        # THE CRITICAL ASSERTION: the lifecycle transition survives.
        assert sweep.sweep_expired_relationships() == 1
        assert fake_db.store[f"personal_coaching/{ATHLETE}"]["status"] == "expired"
        assert not [k for k in fake_db.store if k.startswith("trial_reports/")]

    def test_running_the_sweep_twice_creates_one_report(
            self, fake_db, monkeypatch):
        _seed(fake_db, status="active")
        sweep = self._sweep(fake_db, monkeypatch)
        sweep.sweep_expired_relationships()
        snapshot = copy.deepcopy(fake_db.store[f"trial_reports/{ENGAGEMENT}"])
        sweep.sweep_expired_relationships()   # second pass: already expired
        assert fake_db.store[f"trial_reports/{ENGAGEMENT}"] == snapshot

    def test_relationship_without_a_request_id_is_skipped_safely(
            self, fake_db, monkeypatch):
        _seed(fake_db, status="active")
        fake_db.store[f"personal_coaching/{ATHLETE}"]["requestId"] = None
        sweep = self._sweep(fake_db, monkeypatch)
        assert sweep.sweep_expired_relationships() == 1
        assert fake_db.store[f"personal_coaching/{ATHLETE}"]["status"] == "expired"
        assert not [k for k in fake_db.store if k.startswith("trial_reports/")]


# ══════════════════════════════════════════════════════════════════════════
# Snapshot immutability — the whole reason this is stored, not computed
# ══════════════════════════════════════════════════════════════════════════


class TestSnapshotImmutability:
    def test_report_is_unchanged_by_every_later_mutation(self, fake_db):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        frozen = copy.deepcopy(report)

        # Everything the report was derived from now changes.
        fake_db.store[f"users/{ATHLETE}"]["planId"] = "plan_REGENERATED"
        fake_db.store[f"users/{ATHLETE}"]["dietPlan"] = {
            "days": [{"meals": [{}] * 9} for _ in range(7)]}
        fake_db.store[f"users/{ATHLETE}"]["currentStreak"] = 999
        fake_db.store[f"coaching_plans/{ATHLETE}"] = {"diet": {"days": []}}
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_new"] = {
            "type": "diet", "version": 7, "savedAt": _iso(NOW),
            "savedBy": "Someone Else", "data": {"days": []}}
        for offset in range(3):
            fake_db.store[f"meal_checkins/MCI_{offset}"]["overallRating"] = 1
        fake_db.store["meal_checkins/MCI_new"] = {
            "checkinId": "MCI_new", "athleteId": ATHLETE, "coachId": COACH,
            "timestamp": _iso(START + timedelta(days=5)), "status": "pending"}
        fake_db.store[f"users/{ATHLETE}/weight_log/2026-03-04"] = {
            "weightKg": 55.0}
        fake_db.store[f"users/{ATHLETE}/activity/2026-03-04"] = {
            "date": "2026-03-04", "steps": 99999, "workoutCompleted": True}
        # A whole new engagement replaces the relationship document.
        fake_db.store[f"personal_coaching/{ATHLETE}"]["requestId"] = "req_LATER"

        assert store.get_report(ENGAGEMENT) == frozen

    def test_a_regenerated_plan_cannot_invalidate_a_stored_report(self, fake_db):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        expected_before = report["metrics"]["mealFollowThrough"]["expected"]

        fake_db.store[f"users/{ATHLETE}"]["planId"] = "plan_B"
        stored = store.get_report(ENGAGEMENT)
        # Recomputing now would drop the AI segment entirely; the snapshot
        # is why the athlete's report does not change under them.
        assert stored["metrics"]["mealFollowThrough"]["expected"] == expected_before


# ══════════════════════════════════════════════════════════════════════════
# Read API
# ══════════════════════════════════════════════════════════════════════════


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(trial_report_route.router, prefix="/api/trial-report")
    a.include_router(trial_report_route.history_router,
                     prefix="/api/trial-reports")
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid):
    app.dependency_overrides[trial_report_route.verify_firebase_token] = \
        lambda: {"uid": uid, "email": None, "name": "Test"}


class TestReadApi:
    def test_athlete_can_read_their_own_report(self, fake_db, app, client):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        _as(app, ATHLETE)
        res = client.get(f"/api/trial-report/{ENGAGEMENT}")
        assert res.status_code == 200
        assert res.json()["requestId"] == ENGAGEMENT

    def test_the_engagements_coach_can_read_it(self, fake_db, app, client):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        _as(app, COACH)
        assert client.get(f"/api/trial-report/{ENGAGEMENT}").status_code == 200

    def test_another_athlete_cannot_read_it(self, fake_db, app, client):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        _as(app, OTHER)
        res = client.get(f"/api/trial-report/{ENGAGEMENT}")
        # 404 rather than 403 — a 403 would confirm the report exists.
        assert res.status_code == 404

    def test_absent_report_is_404(self, fake_db, app, client):
        _as(app, ATHLETE)
        res = client.get("/api/trial-report/req_never_generated")
        assert res.status_code == 404
        assert res.json()["detail"]["error"] == "report_not_found"

    def test_get_never_writes_and_never_recomputes(
            self, fake_db, app, client, monkeypatch):
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        before = copy.deepcopy(fake_db.store)

        def must_not_run(*a, **k):
            raise AssertionError("GET must not recompute the report")

        monkeypatch.setattr(trs, "compute_trial_report", must_not_run)
        _as(app, ATHLETE)
        assert client.get(f"/api/trial-report/{ENGAGEMENT}").status_code == 200
        assert fake_db.store == before

    def test_malformed_stored_report_is_a_500_not_a_silent_200(
            self, fake_db, app, client):
        fake_db.store[f"trial_reports/{ENGAGEMENT}"] = {
            "requestId": ENGAGEMENT, "athleteId": ATHLETE, "coachId": COACH}
        _as(app, ATHLETE)
        res = client.get(f"/api/trial-report/{ENGAGEMENT}")
        assert res.status_code == 500
        assert res.json()["detail"]["error"] == "report_malformed"

    def test_firestore_unavailable_is_503(self, app, client, monkeypatch):
        monkeypatch.setattr(firestore_service, "get_client", lambda: None)
        _as(app, ATHLETE)
        assert client.get(f"/api/trial-report/{ENGAGEMENT}").status_code == 503


# ══════════════════════════════════════════════════════════════════════════
# STEP 3.1 — report history listing
# ══════════════════════════════════════════════════════════════════════════


def _stored_report(db, *, request_id, athlete=ATHLETE, coach=COACH,
                   end=END, generated=None, coach_name="Coach Test"):
    """A well-formed stored report, written directly.

    Bypasses generation on purpose: history is about documents that already
    exist, including ones whose engagement is long gone from
    personal_coaching.
    """
    generated = generated or (end + timedelta(hours=1))
    db.store[f"trial_reports/{request_id}"] = {
        "requestId": request_id,
        "athleteId": athlete,
        "coachId": coach,
        "coachName": coach_name,
        "coachingType": "FREE_TRIAL",
        "trialDurationDays": 10,
        "startDate": _iso(end - timedelta(days=10)),
        "endDate": _iso(end),
        "engagementStatus": "expired",
        "reportVersion": "1.0",
        "generatedAt": _iso(generated),
        "storedAt": _iso(generated),
        "status": store.STATUS_GENERATED,
        "period": {"startDate": _iso(end - timedelta(days=10))},
        "metrics": {"overall": {"available": False}},
    }


class TestHistoryListing:
    def test_returns_only_the_callers_reports(self, fake_db):
        _stored_report(fake_db, request_id="req_mine_1")
        _stored_report(fake_db, request_id="req_mine_2")
        _stored_report(fake_db, request_id="req_theirs", athlete=OTHER)

        mine = store.list_reports_for_athlete(ATHLETE)
        assert {r["requestId"] for r in mine} == {"req_mine_1", "req_mine_2"}

    def test_another_athletes_history_is_separate(self, fake_db):
        _stored_report(fake_db, request_id="req_mine")
        _stored_report(fake_db, request_id="req_theirs", athlete=OTHER)
        theirs = store.list_reports_for_athlete(OTHER)
        assert [r["requestId"] for r in theirs] == ["req_theirs"]

    def test_sorted_newest_first_by_engagement_end(self, fake_db):
        _stored_report(fake_db, request_id="req_oldest",
                       end=END - timedelta(days=200))
        _stored_report(fake_db, request_id="req_newest", end=END)
        _stored_report(fake_db, request_id="req_middle",
                       end=END - timedelta(days=90))
        order = [r["requestId"] for r in store.list_reports_for_athlete(ATHLETE)]
        assert order == ["req_newest", "req_middle", "req_oldest"]

    def test_empty_history_is_an_empty_list_not_an_error(self, fake_db):
        assert store.list_reports_for_athlete(ATHLETE) == []

    def test_summaries_carry_the_history_fields_and_no_metrics(self, fake_db):
        _stored_report(fake_db, request_id="req_x")
        row = store.list_reports_for_athlete(ATHLETE)[0]
        for field in ("requestId", "coachId", "coachName", "coachingType",
                      "startDate", "endDate", "trialDurationDays",
                      "engagementStatus", "reportVersion", "generatedAt",
                      "storedAt"):
            assert field in row
        # The listing must not ship the report body.
        assert "metrics" not in row
        assert "dataQuality" not in row
        assert "period" not in row

    def test_malformed_reports_are_omitted_from_history(self, fake_db):
        _stored_report(fake_db, request_id="req_good")
        fake_db.store["trial_reports/req_broken"] = {
            "requestId": "req_broken", "athleteId": ATHLETE}
        rows = store.list_reports_for_athlete(ATHLETE)
        assert [r["requestId"] for r in rows] == ["req_good"]

    def test_listing_writes_nothing(self, fake_db):
        _stored_report(fake_db, request_id="req_x")
        before = copy.deepcopy(fake_db.store)
        store.list_reports_for_athlete(ATHLETE)
        assert fake_db.store == before

    def test_unconfigured_firestore_yields_an_empty_history(self, monkeypatch):
        monkeypatch.setattr(firestore_service, "get_client", lambda: None)
        assert store.list_reports_for_athlete(ATHLETE) == []

    def test_history_survives_a_newer_engagement_overwriting_the_relationship(
            self, fake_db):
        """THE WHOLE POINT OF STEP 3.1.

        personal_coaching/{athleteId} now describes a DIFFERENT, newer
        engagement — the old requestId is unreachable from client-readable
        data — yet the old report must still be listable and readable.
        """
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)

        # A new engagement begins; the relationship document is overwritten.
        _seed(fake_db, request_id="req_CURRENT", status="active")
        assert fake_db.store[f"personal_coaching/{ATHLETE}"]["requestId"] == \
            "req_CURRENT"

        rows = store.list_reports_for_athlete(ATHLETE)
        assert [r["requestId"] for r in rows] == [ENGAGEMENT]
        # And the full snapshot is still readable by that id.
        assert store.get_report(ENGAGEMENT)["requestId"] == ENGAGEMENT


class TestHistoryApi:
    def test_athlete_gets_their_own_history(self, fake_db, app, client):
        _stored_report(fake_db, request_id="req_1", end=END)
        _stored_report(fake_db, request_id="req_2",
                       end=END - timedelta(days=60))
        _as(app, ATHLETE)
        res = client.get("/api/trial-reports")
        assert res.status_code == 200
        body = res.json()
        assert body["count"] == 2
        assert [r["requestId"] for r in body["reports"]] == ["req_1", "req_2"]

    def test_history_never_includes_another_athletes_reports(
            self, fake_db, app, client):
        _stored_report(fake_db, request_id="req_mine")
        _stored_report(fake_db, request_id="req_theirs", athlete=OTHER)
        _as(app, ATHLETE)
        ids = [r["requestId"]
               for r in client.get("/api/trial-reports").json()["reports"]]
        assert ids == ["req_mine"]

    def test_empty_history_is_200_with_an_empty_list(self, fake_db, app, client):
        _as(app, ATHLETE)
        res = client.get("/api/trial-reports")
        assert res.status_code == 200
        assert res.json() == {"reports": [], "count": 0}

    def test_unauthenticated_is_rejected(self, fake_db, app):
        # No dependency override: the real verify_firebase_token runs and
        # rejects a request with no bearer token.
        with TestClient(app) as anonymous:
            assert anonymous.get("/api/trial-reports").status_code in (401, 403)

    def test_history_never_recomputes_a_report(
            self, fake_db, app, client, monkeypatch):
        _stored_report(fake_db, request_id="req_1")
        before = copy.deepcopy(fake_db.store)

        def must_not_run(*a, **k):
            raise AssertionError("history must not recompute reports")

        monkeypatch.setattr(trs, "compute_trial_report", must_not_run)
        monkeypatch.setattr(store, "compute_trial_report", must_not_run)
        _as(app, ATHLETE)
        assert client.get("/api/trial-reports").status_code == 200
        assert fake_db.store == before

    def test_stored_reports_stay_immutable_across_a_listing(
            self, fake_db, app, client):
        _seed(fake_db)
        report, _ = store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        frozen = copy.deepcopy(report)
        _as(app, ATHLETE)
        client.get("/api/trial-reports")
        assert store.get_report(ENGAGEMENT) == frozen

    def test_the_single_report_endpoint_is_unchanged(
            self, fake_db, app, client):
        """Step 3's route must still behave exactly as before."""
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        _as(app, ATHLETE)
        res = client.get(f"/api/trial-report/{ENGAGEMENT}")
        assert res.status_code == 200
        # Full snapshot, not a summary.
        assert "metrics" in res.json()
        assert "dataQuality" in res.json()

        _as(app, OTHER)
        assert client.get(
            f"/api/trial-report/{ENGAGEMENT}").status_code == 404

    def test_a_listed_report_can_be_opened_by_its_id(
            self, fake_db, app, client):
        """The history -> detail hop the app actually performs."""
        _seed(fake_db)
        store.generate_and_store(ATHLETE, ENGAGEMENT, now=NOW)
        _seed(fake_db, request_id="req_CURRENT", status="active")
        _as(app, ATHLETE)

        listed = client.get("/api/trial-reports").json()["reports"]
        assert listed, "the historical report must be listed"
        detail = client.get(f"/api/trial-report/{listed[0]['requestId']}")
        assert detail.status_code == 200
        assert detail.json()["requestId"] == ENGAGEMENT

    def test_firestore_unavailable_is_503(self, app, client, monkeypatch):
        monkeypatch.setattr(firestore_service, "get_client", lambda: None)
        _as(app, ATHLETE)
        assert client.get("/api/trial-reports").status_code == 503
