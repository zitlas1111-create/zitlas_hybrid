"""
ZITLAS — a notification is a RECORD first and a push second
(backend/tests/test_notification_reliability.py)

Phase 1 of the notification reliability work. What these pin:

  * the notification document exists BEFORE any push is attempted, and no
    delivery failure — not even a transport that raises — can remove it;
  * every document carries its delivery record (pushStatus / attempts /
    lastError / deliveredAt) and the status says what actually happened;
  * a TEMPORARY FCM failure is kept apart from a permanently invalid token:
    only the second removes a device, and INVALID_ARGUMENT counts only when
    FCM names the registration token (a payload bug must never prune);
  * one event is one notification and one push, however often it is raised;
  * the recipient comes from the server-side record, never from the request;
  * the athlete flows that already worked are unchanged.

Run: python -m pytest tests/test_notification_reliability.py -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from fastapi import FastAPI                                   # noqa: E402
from fastapi.testclient import TestClient                     # noqa: E402

from routes import notifications as notification_routes       # noqa: E402
from services import (firestore_service, notification_service,  # noqa: E402
                      push_service)
from services.coaching_service import notify as coaching_notify  # noqa: E402
from tests.fake_firestore import FakeClient                   # noqa: E402

ATHLETE = "athlete_1"
COACH = "coach_1"
STRANGER = "stranger_9"
CHECKIN = "MCI_1"

OK = {"ok": True, "status": 200}
UNREGISTERED = {
    "ok": False, "status": 404, "dead_token": True, "transient": False,
    "error_code": "UNREGISTERED",
    "detail": {"error": {"status": "NOT_FOUND",
                         "details": [{"errorCode": "UNREGISTERED"}]}},
}
UNAVAILABLE = {
    "ok": False, "status": 503, "dead_token": False, "transient": True,
    "error_code": "UNAVAILABLE", "detail": {"error": {"status": "UNAVAILABLE"}},
}
SENDER_MISMATCH = {
    "ok": False, "status": 403, "dead_token": False, "transient": False,
    "error_code": "SENDER_ID_MISMATCH",
    "detail": {"error": {"status": "PERMISSION_DENIED",
                         "details": [{"errorCode": "SENDER_ID_MISMATCH"}]}},
}


@pytest.fixture
def db():
    return FakeClient()


class Transport:
    """Fake FCM. `plan[token]` is FCM's answer for that token (default OK).

    Also records what the notification document looked like at the MOMENT
    each push was attempted — the only way to prove the save came first."""

    def __init__(self, db):
        self.db = db
        self.plan: dict[str, dict] = {}
        self.calls: list[tuple[str, dict]] = []
        self.doc_at_push: list[dict | None] = []

    def __call__(self, token, title, body, data=None, **kw):
        data = dict(data or {})
        self.calls.append((token, data))
        nid = data.get("notificationId")
        snapshot = self.db.store.get(f"notifications/{nid}") if nid else None
        self.doc_at_push.append(dict(snapshot) if snapshot else None)
        return self.plan.get(token, OK)


@pytest.fixture
def fcm(monkeypatch, db):
    t = Transport(db)
    monkeypatch.setattr(push_service, "send_to_token", t)
    return t


def device(db, uid, token, platform="android"):
    """A signed-in device, as FcmService._storeToken / storeToken write it."""
    db.collection("device_tokens").document(token).set({
        "fcmToken": token, "uid": uid, "platform": platform, "enabled": True,
        "loggedIn": True, "rendersOwnNotifications": platform == "android",
    })


def docs_for(db, uid):
    return [v for k, v in db.store.items()
            if k.startswith("notifications/") and v and v.get("userId") == uid]


def the_doc(db, uid):
    docs = docs_for(db, uid)
    assert len(docs) == 1, f"expected one notification for {uid}, found {len(docs)}"
    return docs[0]


def send(db, uid=ATHLETE, **kw):
    kw.setdefault("type", "coaching_accepted")
    return notification_service.send(db, uid, "Congratulations!", "You're in", **kw)


# ── The record comes first ──────────────────────────────────────────────────

class TestTheRecordComesFirst:
    def test_the_document_exists_before_the_push_is_attempted(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        send(db)
        assert len(fcm.doc_at_push) == 1
        at_push = fcm.doc_at_push[0]
        assert at_push is not None, "the push went out before the notification was saved"
        assert at_push["pushStatus"] == "pending"

    def test_a_failed_push_leaves_the_notification_in_place(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        fcm.plan["tok_phone"] = UNAVAILABLE
        send(db)
        doc = the_doc(db, ATHLETE)
        assert doc["title"] == "Congratulations!"
        assert doc["pushStatus"] == "failed"

    def test_an_exploding_transport_cannot_take_the_record_with_it(self, db, monkeypatch):
        device(db, ATHLETE, "tok_phone")

        def boom(*a, **k):
            raise RuntimeError("transport exploded")

        monkeypatch.setattr(push_service, "send_to_token", boom)
        res = send(db)                          # must not raise
        assert res["ok"] is True
        doc = the_doc(db, ATHLETE)
        assert doc["pushStatus"] == "failed"
        assert doc["retryable"] is True
        assert doc["lastError"] == "RuntimeError"

    def test_every_delivery_field_is_on_the_record(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        send(db, event_id="coaching_accepted_REQ1")
        doc = the_doc(db, ATHLETE)
        for field in ("notificationId", "createdAt", "eventId", "pushStatus",
                      "attempts", "lastError", "deliveredAt"):
            assert field in doc, f"{field} missing from the notification document"
        assert doc["eventId"] == "coaching_accepted_REQ1"


# ── pushStatus says what happened ───────────────────────────────────────────

class TestPushStatus:
    def test_sent(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        res = send(db)
        doc = the_doc(db, ATHLETE)
        assert res["pushStatus"] == doc["pushStatus"] == "sent"
        assert doc["attempts"] == 1
        assert doc["deliveredAt"]
        assert doc["retryable"] is False

    def test_no_device(self, db, fcm):
        res = send(db)
        doc = the_doc(db, ATHLETE)
        assert res["pushStatus"] == doc["pushStatus"] == "no_device"
        assert doc["lastError"] == "no_active_authenticated_session"
        assert doc["deliveredAt"] is None
        assert fcm.calls == []

    def test_a_temporary_failure_is_retryable_and_keeps_the_device(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        fcm.plan["tok_phone"] = UNAVAILABLE
        send(db)
        doc = the_doc(db, ATHLETE)
        assert doc["pushStatus"] == "failed"
        assert doc["retryable"] is True
        assert doc["lastError"] == "UNAVAILABLE"
        assert db.store.get("device_tokens/tok_phone") is not None, (
            "an FCM outage must never remove a real device")

    def test_a_permanent_non_token_failure_is_not_retryable_and_keeps_the_device(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        fcm.plan["tok_phone"] = SENDER_MISMATCH
        send(db)
        doc = the_doc(db, ATHLETE)
        assert doc["pushStatus"] == "failed"
        assert doc["retryable"] is False
        assert doc["lastError"] == "SENDER_ID_MISMATCH"
        assert db.store.get("device_tokens/tok_phone") is not None

    def test_only_dead_devices_is_no_device_and_they_are_removed(self, db, fcm):
        device(db, ATHLETE, "tok_uninstalled")
        fcm.plan["tok_uninstalled"] = UNREGISTERED
        send(db)
        doc = the_doc(db, ATHLETE)
        assert doc["pushStatus"] == "no_device"
        assert doc["lastError"] == "all_tokens_invalid"
        assert db.store.get("device_tokens/tok_uninstalled") is None

    def test_one_live_device_is_enough_for_sent(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        device(db, ATHLETE, "tok_old")
        fcm.plan["tok_old"] = UNREGISTERED
        send(db)
        assert the_doc(db, ATHLETE)["pushStatus"] == "sent"
        assert db.store.get("device_tokens/tok_old") is None
        assert db.store.get("device_tokens/tok_phone") is not None

    def test_attempts_accumulate_across_recorded_attempts(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        res = send(db)
        notification_service._record_delivery(db, res["notificationId"],
                                              {"pushStatus": "sent"})
        assert the_doc(db, ATHLETE)["attempts"] == 2


# ── Temporary vs dead — decided at the FCM boundary ─────────────────────────

class TestFailureClassification:
    """push_service.send_to_token against a fake HTTP layer: the one place
    that decides whether a failure is temporary or the token is dead."""

    def _send(self, monkeypatch, status=200, body=None, raises=None):
        class _Response:
            status_code = status
            headers = {"content-type": "application/json"}
            text = ""

            def json(self):
                return body or {}

        def _post(*a, **k):
            if raises is not None:
                raise raises
            return _Response()

        monkeypatch.setattr(push_service, "is_configured", lambda: True)
        monkeypatch.setattr(push_service, "_access_token", lambda: "t")
        import requests
        monkeypatch.setattr(requests, "post", _post)
        return push_service.send_to_token("tok", "T", "B", {"a": "b"})

    def test_unregistered_is_a_dead_token(self, monkeypatch):
        res = self._send(monkeypatch, 404, {"error": {
            "status": "NOT_FOUND", "details": [{"errorCode": "UNREGISTERED"}]}})
        assert res["ok"] is False
        assert res["dead_token"] is True and res["transient"] is False
        assert res["error_code"] == "UNREGISTERED"

    def test_an_invalid_registration_token_is_a_dead_token(self, monkeypatch):
        res = self._send(monkeypatch, 400, {"error": {
            "status": "INVALID_ARGUMENT",
            "message": "The registration token is not a valid FCM registration token",
            "details": [{"errorCode": "INVALID_ARGUMENT"}]}})
        assert res["dead_token"] is True

    def test_a_malformed_MESSAGE_is_not_a_dead_token(self, monkeypatch):
        """THE GUARD: INVALID_ARGUMENT is also FCM's answer to a payload bug.
        Pruning on it would wipe every recipient's devices."""
        res = self._send(monkeypatch, 400, {"error": {
            "status": "INVALID_ARGUMENT",
            "message": "Invalid value at 'message.data[0].value' (TYPE_STRING), 5",
            "details": [{"errorCode": "INVALID_ARGUMENT"}]}})
        assert res["dead_token"] is False
        assert res["transient"] is False

    @pytest.mark.parametrize("status", [429, 500, 502, 503, 504])
    def test_server_side_failures_are_temporary(self, monkeypatch, status):
        res = self._send(monkeypatch, status, {"error": {"status": "UNAVAILABLE"}})
        assert res["transient"] is True
        assert res["dead_token"] is False

    def test_quota_is_temporary(self, monkeypatch):
        res = self._send(monkeypatch, 429, {"error": {
            "status": "RESOURCE_EXHAUSTED", "details": [{"errorCode": "QUOTA_EXCEEDED"}]}})
        assert res["transient"] is True
        assert res["error_code"] == "QUOTA_EXCEEDED"

    def test_no_response_at_all_is_temporary(self, monkeypatch):
        import requests
        res = self._send(monkeypatch, raises=requests.exceptions.Timeout("timed out"))
        assert res["ok"] is False
        assert res["transient"] is True
        assert res["dead_token"] is False
        assert res["error_code"] == "Timeout"

    def test_missing_credentials_are_retryable_not_a_dead_device(self, monkeypatch):
        monkeypatch.setattr(push_service, "is_configured", lambda: False)
        res = push_service.send_to_token("tok", "T", "B", {})
        assert res["transient"] is True
        assert res["dead_token"] is False
        assert res["error_code"] == "FCM_NOT_CONFIGURED"


# ── One event, one notification ─────────────────────────────────────────────

class TestOneEventOneNotification:
    def test_the_same_event_twice_is_one_notification_and_one_push(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        first = send(db, event_id="coaching_accepted_REQ1")
        second = send(db, event_id="coaching_accepted_REQ1")
        assert len(docs_for(db, ATHLETE)) == 1
        assert len(fcm.calls) == 1, "the repeat pushed again"
        assert second["duplicate"] is True
        assert second["notificationId"] == first["notificationId"]

    def test_the_id_is_derived_from_the_event_and_the_recipient(self, db, fcm):
        res = send(db, event_id="E1")
        assert res["notificationId"] == notification_service.event_notification_id("E1", ATHLETE)

    def test_one_event_for_two_people_is_two_notifications(self, db, fcm):
        send(db, ATHLETE, event_id="coaching_started_REQ1")
        send(db, COACH, event_id="coaching_started_REQ1")
        assert len(docs_for(db, ATHLETE)) == 1
        assert len(docs_for(db, COACH)) == 1

    def test_different_events_are_different_notifications(self, db, fcm):
        send(db, event_id="E1")
        send(db, event_id="E2")
        assert len(docs_for(db, ATHLETE)) == 2

    def test_without_an_event_id_nothing_is_merged(self, db, fcm):
        """Callers with no event identity keep today's behaviour exactly."""
        send(db)
        send(db)
        assert len(docs_for(db, ATHLETE)) == 2

    def test_a_writer_that_got_there_first_wins(self, db, fcm):
        """The create() race: another request already wrote this event."""
        device(db, ATHLETE, "tok_phone")
        nid = notification_service.event_notification_id("E1", ATHLETE)
        db.store[f"notifications/{nid}"] = {"notificationId": nid, "userId": ATHLETE,
                                            "title": "first", "pushStatus": "sent"}
        res = send(db, event_id="E1")
        assert res["duplicate"] is True
        assert fcm.calls == []
        assert db.store[f"notifications/{nid}"]["title"] == "first", (
            "the original notification was overwritten")

    def test_persist_alone_is_idempotent_too(self, db):
        a = notification_service.persist(db, ATHLETE, title="T", message="M", event_id="E1")
        b = notification_service.persist(db, ATHLETE, title="T", message="M", event_id="E1")
        assert a == b
        assert len(docs_for(db, ATHLETE)) == 1

    def test_the_event_id_rides_along_in_the_push(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        send(db, event_id="E1")
        assert fcm.calls[0][1]["eventId"] == "E1"


# ── The recipient comes from the record, never the request ─────────────────

@pytest.fixture
def app(db, monkeypatch):
    monkeypatch.setattr(firestore_service, "get_client", lambda: db)
    a = FastAPI()
    a.include_router(notification_routes.router, prefix="/api/notifications")
    return a


def as_user(app, uid):
    app.dependency_overrides[notification_routes.verify_firebase_token] = (
        lambda: {"uid": uid, "email": None, "name": "Test"})
    return TestClient(app)


def checkin(db, **over):
    doc = {"athleteId": ATHLETE, "coachId": COACH, "mealName": "Lunch",
           "athleteName": "Asha", "reviewedBy": "Coach Srujan", "overallRating": 4}
    doc.update(over)
    db.store[f"meal_checkins/{CHECKIN}"] = doc


class TestRecipientsComeFromTheRecord:
    def test_a_client_cannot_name_the_recipient(self, app, db, fcm):
        checkin(db)
        device(db, COACH, "tok_coach")
        device(db, STRANGER, "tok_stranger")
        r = as_user(app, ATHLETE).post("/api/notifications/meal-checkin", json={
            "checkinId": CHECKIN,
            # A client trying to choose who is notified. Every one is ignored.
            "coachId": STRANGER, "userId": STRANGER, "recipientId": STRANGER,
        })
        assert r.status_code == 200
        assert len(docs_for(db, COACH)) == 1
        assert docs_for(db, STRANGER) == []
        assert [t for t, _ in fcm.calls] == ["tok_coach"]

    def test_only_the_athlete_on_the_checkin_can_raise_it(self, app, db, fcm):
        checkin(db)
        r = as_user(app, STRANGER).post("/api/notifications/meal-checkin",
                                        json={"checkinId": CHECKIN})
        assert r.status_code == 403
        assert docs_for(db, COACH) == []
        assert fcm.calls == []

    def test_a_retried_meal_checkin_is_one_notification(self, app, db, fcm):
        checkin(db)
        device(db, COACH, "tok_coach")
        client = as_user(app, ATHLETE)
        first = client.post("/api/notifications/meal-checkin", json={"checkinId": CHECKIN}).json()
        second = client.post("/api/notifications/meal-checkin", json={"checkinId": CHECKIN}).json()
        assert len(docs_for(db, COACH)) == 1
        assert len(fcm.calls) == 1
        assert first["pushStatus"] == "sent"
        assert second["duplicate"] is True

    def test_the_athlete_cannot_raise_the_coachs_review_notification(self, app, db, fcm):
        checkin(db)
        r = as_user(app, ATHLETE).post("/api/notifications/meal-review",
                                       json={"checkinId": CHECKIN})
        assert r.status_code == 403

    def test_a_plan_update_needs_the_athletes_active_coach(self, app, db, fcm):
        db.store[f"personal_coaching/{ATHLETE}"] = {"coachId": COACH, "status": "active"}
        r = as_user(app, STRANGER).post("/api/notifications/plan-updated",
                                        json={"athleteId": ATHLETE, "kind": "diet"})
        assert r.status_code == 403
        assert docs_for(db, ATHLETE) == []

    def test_a_coach_cannot_aim_a_plan_update_at_someone_elses_athlete(self, app, db, fcm):
        db.store["personal_coaching/other_athlete"] = {"coachId": "other_coach",
                                                       "status": "active"}
        r = as_user(app, COACH).post("/api/notifications/plan-updated",
                                     json={"athleteId": "other_athlete", "kind": "diet"})
        assert r.status_code == 403
        assert docs_for(db, "other_athlete") == []

    def test_chat_is_only_for_people_in_the_room(self, app, db, fcm):
        db.store["chat_rooms/room_1"] = {"participants": [ATHLETE, COACH],
                                         "athleteId": ATHLETE, "expertId": COACH}
        r = as_user(app, STRANGER).post("/api/notifications/chat",
                                        json={"chatId": "room_1", "text": "hi"})
        assert r.status_code == 403
        assert fcm.calls == []


# ── What already worked still works ─────────────────────────────────────────

class TestTheAthleteFlowIsUnchanged:
    def test_a_coaching_notification_still_reaches_the_athlete(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        coaching_notify(db, ATHLETE, "Congratulations!", "Your coaching starts now.",
                        type="coaching_accepted", action="coaching_workspace",
                        action_id=COACH, priority="high")
        doc = the_doc(db, ATHLETE)
        assert [t for t, _ in fcm.calls] == ["tok_phone"]
        assert doc["pushStatus"] == "sent"

    def test_the_fields_both_notification_centres_read_are_unchanged(self, db, fcm):
        send(db, category="expert", action="coaching_workspace", action_id=COACH)
        doc = the_doc(db, ATHLETE)
        assert doc["userId"] == ATHLETE
        assert doc["title"] == "Congratulations!"
        assert doc["message"] == "You're in"
        assert doc["category"] == "expert"
        assert doc["type"] == "coaching_accepted"
        assert doc["action"] == "coaching_workspace"
        assert doc["actionId"] == COACH
        assert doc["isRead"] is False
        assert doc["priority"] == "medium"
        assert doc["createdAt"]
        assert doc["notificationId"].startswith("notif_")

    def test_chat_stays_push_only(self, db, fcm):
        device(db, ATHLETE, "tok_phone")
        notification_service.push_only(db, ATHLETE, title="Coach", body="hi",
                                       type="chat_message", data={"chatId": "room_1"})
        assert docs_for(db, ATHLETE) == []
        assert len(fcm.calls) == 1


# ── Browser notifications no longer stack or overwrite each other ──────────

class TestWebNotificationTags:
    def _message(self, monkeypatch, data):
        captured = {}

        class _Response:
            status_code = 200
            headers = {"content-type": "application/json"}
            text = "{}"

            def json(self):
                return {"name": "ok"}

        def _post(url, headers=None, json=None, timeout=None):
            captured["json"] = json
            return _Response()

        monkeypatch.setattr(push_service, "is_configured", lambda: True)
        monkeypatch.setattr(push_service, "_access_token", lambda: "t")
        import requests
        monkeypatch.setattr(requests, "post", _post)
        push_service.send_to_token("tok_web", "T", "B", data,
                                   notification_type="coaching_accepted", platform="web")
        return captured["json"]["message"]

    def test_each_event_gets_its_own_tag(self, monkeypatch):
        a = self._message(monkeypatch, {"notificationId": "n1"})
        b = self._message(monkeypatch, {"notificationId": "n2"})
        assert a["webpush"]["notification"]["tag"] == "zitlas-n1"
        assert b["webpush"]["notification"]["tag"] == "zitlas-n2"

    def test_the_event_id_wins_over_the_notification_id(self, monkeypatch):
        m = self._message(monkeypatch, {"eventId": "E1", "notificationId": "n1"})
        assert m["webpush"]["notification"]["tag"] == "zitlas-E1"

    def test_chat_groups_by_conversation_and_re_alerts(self, monkeypatch):
        m = self._message(monkeypatch, {"chatId": "room_1"})
        assert m["webpush"]["notification"]["tag"] == "zitlas-chat-room_1"
        assert m["webpush"]["notification"]["renotify"] is True

    def test_the_web_keeps_its_notification_block_and_gains_the_icon(self, monkeypatch):
        m = self._message(monkeypatch, {"notificationId": "n1"})
        assert m["notification"] == {"title": "T", "body": "B"}
        assert m["webpush"]["notification"]["icon"] == push_service.WEB_ICON
        assert m["webpush"]["notification"]["renotify"] is False

    def test_the_service_worker_uses_the_same_rule(self):
        sw = (Path(__file__).parents[2] / "frontend" / "website"
              / "firebase-messaging-sw.js").read_text(encoding="utf-8")
        assert "'zitlas-chat-' + data.chatId" in sw
        assert "data.eventId || data.notificationId" in sw
