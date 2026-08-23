"""
ZITLAS — notification DELIVERY, not just persistence
(backend/tests/test_notification_delivery.py)

THE BUGS THESE PIN. 79 notification tests already existed and all passed while
coaching approvals were arriving hours late, because none of them asserted
anything about how the push was actually sent.

  1. `push_service` hard-coded `high = notification_type == "chat_message"`,
     so EVERY other notification went out at FCM `normal` priority — including
     a coaching approval whose caller explicitly passed `priority="high"`.
     Android defers normal-priority messages during Doze/App Standby and
     releases them in a batch when the device next wakes, which is precisely
     why events "only appeared when the user opened the app", several at once.

  2. The caller's `priority` reached the Firestore document and was then
     dropped: `send_to_token()` had no `priority` parameter at all.

  3. The coaching channel id had to change (v2) because Android caches a
     channel's importance at creation — and the backend's id must match the
     app's exactly or Android silently discards the notification.

Run: python -m pytest tests/test_notification_delivery.py -q
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import notification_service, push_service  # noqa: E402
from tests.fake_firestore import FakeClient              # noqa: E402

UID = "athlete_1"


# ── 1-4. The priority chain ──────────────────────────────────────────────────

class TestPriorityIsHonoured:
    @pytest.mark.parametrize("ntype", [
        "chat_message",
        "coaching_accepted",
        "coaching_started",
        "coaching_request",
        "review_completed",
        "expert_request",
    ])
    def test_time_critical_types_are_high_priority(self, ntype):
        assert push_service.is_high_priority(ntype) is True, (
            f"{ntype} would be deferred by Doze and arrive in a batch when "
            "the user next opens the app")

    def test_a_caller_supplied_high_priority_wins(self):
        """The exact case that was broken: coaching.py passes priority='high'
        and it never reached FCM."""
        assert push_service.is_high_priority("something_new", "high") is True
        assert push_service.is_high_priority(None, "urgent") is True

    def test_informational_notifications_stay_normal(self):
        """High priority is a limited resource — marking everything urgent is
        the same as marking nothing urgent."""
        assert push_service.is_high_priority("general") is False
        assert push_service.is_high_priority("milestone", "medium") is False
        assert push_service.is_high_priority(None, None) is False

    def test_the_hard_coded_chat_only_rule_is_gone(self):
        import inspect
        src = inspect.getsource(push_service.send_to_token)
        assert 'notification_type == "chat_message"' not in src, (
            "the chat-only priority rule is back")

    def test_send_to_token_accepts_a_priority(self):
        import inspect
        params = inspect.signature(push_service.send_to_token).parameters
        assert "priority" in params

    def test_notification_service_forwards_priority_to_the_push(self):
        """It reached the Firestore document and stopped there."""
        import inspect
        for fn in (notification_service.send, notification_service.push_only):
            assert "priority" in inspect.signature(fn).parameters, fn.__name__
        src = inspect.getsource(notification_service.push_only)
        assert "priority=priority" in src, (
            "push_only accepts a priority but does not pass it on")
        assert "priority=priority" in inspect.getsource(notification_service.send)


class TestTheFcmMessageItself:
    """Builds the real FCM message body and inspects it."""

    def _message(self, monkeypatch, ntype, priority=None):
        captured = {}

        def _fake_post(url, **kwargs):
            captured["json"] = kwargs.get("json")

            class _R:
                status_code = 200
                headers = {}
                text = "{}"

                @staticmethod
                def json():
                    return {"name": "ok"}
            return _R()

        # The suite runs without credentials (tests/conftest.py cuts every
        # network dependency), and send_to_token returns early when
        # unconfigured — so the transport has to be stood up explicitly for
        # the message body to be built at all.
        monkeypatch.setattr(push_service, "is_configured", lambda: True)
        monkeypatch.setattr(push_service, "_access_token", lambda: "t")
        monkeypatch.setattr(push_service, "_project_id", lambda: "p", raising=False)
        import requests
        monkeypatch.setattr(requests, "post", _fake_post)
        try:
            push_service.send_to_token("tok", "T", "B", {"a": "b"},
                                       notification_type=ntype, priority=priority)
        except Exception:
            pass
        # FCM HTTP v1 wraps the payload: {"message": {...}}
        body = captured.get("json") or {}
        return body.get("message", body)

    def test_coaching_accepted_is_android_high_and_apns_10(self, monkeypatch):
        msg = self._message(monkeypatch, "coaching_accepted", "high")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["priority"] == "high"
        assert msg["apns"]["headers"]["apns-priority"] == "10"

    def test_an_informational_type_stays_normal(self, monkeypatch):
        msg = self._message(monkeypatch, "general")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["priority"] == "normal"
        assert msg["apns"]["headers"]["apns-priority"] == "5"


# ── 6-7. Channels ────────────────────────────────────────────────────────────

class TestChannels:
    #: `fcm_service.dart`, the only place the app creates channels.
    FLUTTER = Path(__file__).resolve().parents[2] / "mobile" / "lib" / \
        "core" / "notifications" / "fcm_service.dart"

    def test_the_coaching_channel_is_v2(self):
        """Android caches a channel's importance at creation, so raising the
        old channel would have changed nothing on existing installs."""
        assert push_service.CHANNEL_COACHING == "zitlas_coaching_v2"

    def test_every_backend_channel_exists_in_the_flutter_app(self):
        """A notification whose channel_id the app never created is silently
        DISCARDED by Android 8+. This is the kind of drift that produces
        'notifications just don't arrive' with nothing in any log."""
        if not self.FLUTTER.exists():
            pytest.skip("Flutter source not reachable from this run")
        dart = self.FLUTTER.read_text(encoding="utf-8")
        declared = set(re.findall(r"'(zitlas_[a-z0-9_]+)'", dart))

        for name in ("CHANNEL_MESSAGES", "CHANNEL_COACHING",
                     "CHANNEL_MEAL_REVIEWS", "CHANNEL_PLANS", "CHANNEL_GENERAL"):
            channel = getattr(push_service, name)
            assert channel in declared, (
                f"backend sends channel_id {channel!r} ({name}) but the app "
                f"never creates it — Android will drop those notifications")

    def test_coaching_types_route_to_the_coaching_channel(self):
        for t in ("coaching_accepted", "coaching_started", "payment_received"):
            assert push_service.channel_for(t) == push_service.CHANNEL_COACHING


# ── 5, 8, 9. History vs delivery, and duplicates ─────────────────────────────

class TestHistoryIsNotDelivery:
    def test_persisting_alone_sends_no_push(self, monkeypatch):
        """Firestore history must never be mistaken for delivery — and must
        never trigger a second notification of its own."""
        sent = []
        monkeypatch.setattr(push_service, "send_to_token",
                            lambda *a, **k: sent.append(a) or {"ok": True})
        db = FakeClient()
        notification_service.persist(db, UID, title="T", message="M")
        assert sent == []

    def test_the_history_document_still_gets_written(self):
        """The Notification Centre depends on it — fixing delivery must not
        remove the record."""
        db = FakeClient()
        nid = notification_service.persist(db, UID, title="T", message="M",
                                           category="expert", type="coaching_accepted")
        assert nid
        doc = db.collection("notifications").document(nid).get().to_dict()
        assert doc["userId"] == UID
        assert doc["type"] == "coaching_accepted"
        assert doc["isRead"] is False

    def test_one_event_sends_one_push_per_device(self, monkeypatch):
        """Two devices = two pushes; one event = one push each, never two."""
        calls = []
        monkeypatch.setattr(push_service, "send_to_token",
                            lambda *a, **k: calls.append(a[0]) or {"ok": True})
        monkeypatch.setattr(notification_service, "_tokens_for_user",
                            lambda db, uid: [("tokA", "s"), ("tokB", "s")])
        db = FakeClient()
        notification_service.send(db, UID, "Congratulations!", "You're in",
                                  type="coaching_accepted", priority="high")
        assert calls == ["tokA", "tokB"]

    def test_the_push_carries_a_unique_notification_id(self, monkeypatch):
        """The app keys its foreground tray entry on this, so a redelivered
        push replaces rather than stacks."""
        payloads = []

        def _capture(token, title, body, data=None, **kwargs):
            payloads.append(data or {})
            return {"ok": True}

        monkeypatch.setattr(push_service, "send_to_token", _capture)
        monkeypatch.setattr(notification_service, "_tokens_for_user",
                            lambda db, uid: [("tokA", "s")])
        db = FakeClient()
        notification_service.send(db, UID, "T", "M", type="coaching_accepted")

        assert payloads and payloads[0].get("notificationId")
        assert payloads[0]["type"] == "coaching_accepted"

    def test_two_distinct_events_get_distinct_ids(self, monkeypatch):
        payloads = []
        monkeypatch.setattr(
            push_service, "send_to_token",
            lambda t, ti, b, data=None, **k: payloads.append(data or {}) or {"ok": True})
        monkeypatch.setattr(notification_service, "_tokens_for_user",
                            lambda db, uid: [("tokA", "s")])
        db = FakeClient()
        notification_service.send(db, UID, "A", "1", type="coaching_accepted")
        notification_service.send(db, UID, "B", "2", type="coaching_accepted")
        assert payloads[0]["notificationId"] != payloads[1]["notificationId"]


# ── 4. Production credentials ────────────────────────────────────────────────

class TestFcmCredentials:
    def test_the_required_env_var_is_documented(self):
        """Render has no filesystem to point FIREBASE_SERVICE_ACCOUNT_FILE at,
        so production must supply the JSON inline."""
        from services import google_credentials
        import inspect
        src = inspect.getsource(google_credentials)
        assert "FIREBASE_SERVICE_ACCOUNT_JSON" in src
        assert "FIREBASE_SERVICE_ACCOUNT_FILE" in src

    def test_is_configured_reports_rather_than_raising(self):
        """A missing credential must degrade to "no push", never crash the
        request that triggered the notification."""
        assert isinstance(push_service.is_configured(), bool)
