"""
ZITLAS — the meal-review push says what the coach actually said
(backend/tests/test_meal_review_notification.py)

WHAT THIS PINS
--------------
Rating a meal produced "Coach Srujan rated Lunch 4.0⭐." and nothing else. The
expert's written comment — the entire reason the athlete cares — was saved on
the check-in and never left the server, so the notification delivered a score
with no explanation and the athlete had to open the app to find out why.

The comment now goes in the BODY, not only in `data`. A push that arrives
while the app is closed is drawn by Android from the `notification` block
alone; no Dart runs, so anything only in `data` is invisible until the app is
opened — which is precisely the trip the notification was supposed to save.
Android collapses a long body to one line in the tray and expands it on
pull-down, so this needs nothing from the client.

Also pinned here, because they are easy to regress and silent when they break:
  * the idempotency stamp (a retried submit must not re-notify)
  * the coach-only authorisation check
  * that a rating is still delivered when there is no comment

Run: python -m pytest tests/test_meal_review_notification.py -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import notifications                          # noqa: E402
from services import firestore_service, notification_service  # noqa: E402
from tests.fake_firestore import FakeClient               # noqa: E402

ATHLETE = "athlete_1"
COACH = "coach_1"
CHECKIN = "MCI_1"


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    return client


@pytest.fixture
def sent(monkeypatch):
    """Captures notification_service.send() instead of delivering."""
    calls: list[dict] = []

    def _send(db, user_id, title, body, **kw):
        calls.append({"uid": user_id, "title": title, "body": body, **kw})
        return {"sent": 1, "failed": 0, "tokens": 1}

    monkeypatch.setattr(notification_service, "send", _send)
    return calls


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(notifications.router, prefix="/api/notifications")
    return a


def _as(app, uid):
    app.dependency_overrides[notifications.verify_firebase_token] = lambda: {
        "uid": uid, "email": None, "name": "Test"
    }


def _checkin(fake_db, **over):
    doc = {
        "athleteId": ATHLETE,
        "coachId": COACH,
        "mealName": "Lunch",
        "reviewedBy": "Coach Srujan",
        "overallRating": 4,
    }
    doc.update(over)
    fake_db.store[f"meal_checkins/{CHECKIN}"] = doc
    return doc


def _post(app, fake_db):
    return TestClient(app).post("/api/notifications/meal-review",
                                json={"checkinId": CHECKIN})


class TestTheCommentReachesTheAthlete:
    def test_THE_GAP_the_body_carries_what_the_coach_wrote(
            self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="Great portion control, add more greens.")
        assert _post(app, fake_db).status_code == 200

        body = sent[0]["body"]
        assert "Great portion control, add more greens." in body, (
            "the comment was saved but never delivered — the athlete got a "
            "score with no reason for it")
        assert "Coach Srujan" in body and "Lunch" in body

    def test_the_rating_is_still_there_too(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="Nice work.")
        _post(app, fake_db)
        assert "4.0" in sent[0]["body"]

    def test_the_untruncated_comment_rides_along_in_data(
            self, app, fake_db, sent):
        _as(app, COACH)
        long = "word " * 80
        _checkin(fake_db, comment=long)
        _post(app, fake_db)
        assert sent[0]["data"]["comment"] == long.strip(), (
            "the in-app screen shows the whole comment; only the tray copy "
            "is shortened")

    def test_no_comment_still_notifies(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db)
        _post(app, fake_db)
        assert sent[0]["title"] == "Zino • Meal Review"
        assert sent[0]["body"] == "Coach Srujan reviewed your Lunch — 4.0⭐ 🍽️"
        assert "comment" not in sent[0]["data"], (
            "an empty string in the payload is not the same as absent, and "
            "the client would render empty quotes")

    def test_a_whitespace_only_comment_counts_as_none(
            self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="   \n  ")
        _post(app, fake_db)
        assert "“" not in sent[0]["body"], "empty quotes must not appear"
        assert "comment" not in sent[0]["data"]


class TestTheBodyStaysReadable:
    def test_a_long_comment_is_cut_on_a_word_boundary(
            self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment=("supercalifragilistic " * 30).strip())
        _post(app, fake_db)
        body = sent[0]["body"]
        assert "…" in body
        # No half-word before the ellipsis.
        preview = body.split("“")[1].split("…")[0]
        assert not preview.endswith("supercalifragilisti")
        assert preview.endswith("supercalifragilistic")

    def test_newlines_do_not_break_the_tray_line(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="Line one.\n\nLine two.\tTabbed.")
        _post(app, fake_db)
        body = sent[0]["body"]
        assert "\n" not in body and "\t" not in body
        assert "Line one. Line two. Tabbed." in body

    def test_a_short_comment_is_not_ellipsised(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="Good.")
        _post(app, fake_db)
        assert "…" not in sent[0]["body"]


class TestThingsThatMustNotRegress:
    def test_a_retry_does_not_notify_twice(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="Nice.")
        assert _post(app, fake_db).status_code == 200
        assert len(sent) == 1
        # Same submit again — a refresh, a retried request, the sheet reopened.
        second = _post(app, fake_db)
        assert second.status_code == 200
        assert second.json()["detail"] == "already_notified"
        assert len(sent) == 1, "the athlete must not be told twice"

    def test_only_the_named_coach_may_notify(self, app, fake_db, sent):
        _as(app, "someone_else")
        _checkin(fake_db, comment="Nice.")
        assert _post(app, fake_db).status_code == 403
        assert sent == []

    def test_the_deep_link_ids_are_still_carried(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, comment="Nice.")
        _post(app, fake_db)
        data = sent[0]["data"]
        # NotificationRouter builds /coach-profile/<coachId>?cwTab=checkins
        # out of these; losing them silently degrades the tap to /diet.
        assert data["coachId"] == COACH
        assert data["athleteId"] == ATHLETE
        assert data["mealId"] == CHECKIN
        assert data["type"] == "meal_review_completed"

    def test_it_goes_to_the_athlete_not_the_coach(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db)
        _post(app, fake_db)
        assert sent[0]["uid"] == ATHLETE


class TestTheTemplateContract:
    """The payload keys the client navigates on. Adding one is safe; RENAMING
    one silently breaks every installed app, because a backend deploy does not
    upgrade phones."""

    def test_the_deep_link_names_the_exact_meal(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db)
        _post(app, fake_db)
        assert sent[0]["data"]["deepLink"] == f"zitlas://meal-review/{CHECKIN}"

    def test_both_id_names_are_sent_during_the_rename(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db)
        _post(app, fake_db)
        data = sent[0]["data"]
        # mealId is what shipped builds read; mealCheckinId is the clearer
        # name. Dropping either before the old builds are gone breaks taps.
        assert data["mealId"] == data["mealCheckinId"] == CHECKIN
        assert data["coachId"] == data["expertId"] == COACH

    def test_the_event_id_is_stable_for_one_review(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db)
        _post(app, fake_db)
        assert sent[0]["data"]["eventId"] == f"meal_review_completed_{CHECKIN}"
        # Handed to FCM as the collapse key so a redelivery of the SAME event
        # replaces its own tray entry instead of stacking a second copy.
        assert sent[0]["collapse_key"] == sent[0]["data"]["eventId"]

    def test_every_data_value_is_a_string(self, app, fake_db, sent):
        # FCM rejects non-string data values with a 400 at send time, which
        # surfaces as "notifications stopped working", not as a type error.
        _as(app, COACH)
        _checkin(fake_db, comment="Nice.")
        _post(app, fake_db)
        for k, v in sent[0]["data"].items():
            assert isinstance(v, str), f"{k} is {type(v).__name__}, not str"

    def test_an_absent_rating_is_omitted_not_stringified(
            self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db, overallRating=None, score=None)
        _post(app, fake_db)
        data = sent[0]["data"]
        assert data.get("rating") != "None", (
            "the client tests these keys for presence, and 'None' is truthy")
        assert "rating" not in data
        # …and the body must not advertise a score it does not have.
        assert "⭐" not in sent[0]["body"]

    def test_it_is_sent_at_high_priority(self, app, fake_db, sent):
        _as(app, COACH)
        _checkin(fake_db)
        _post(app, fake_db)
        assert sent[0]["priority"] == "high", (
            "an athlete is waiting for this; normal priority lets Doze hold "
            "it until the phone is next unlocked")
