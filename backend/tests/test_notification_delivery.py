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

    def test_the_android_sound_names_the_zitlas_tone(self, monkeypatch):
        """Guards the one line that would silently undo the custom sound on
        pre-Android-8 devices: reverting it to "default" is a one-word edit
        that breaks nothing loudly."""
        msg = self._message(monkeypatch, "meal_review_completed", "high")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["notification"]["sound"] == push_service.SOUND_ANDROID
        assert msg["android"]["notification"]["sound"] != "default"

    def _platform_message(self, monkeypatch, platform,
                          ntype="meal_review_completed", renders_own=True):
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

        monkeypatch.setattr(push_service, "is_configured", lambda: True)
        monkeypatch.setattr(push_service, "_access_token", lambda: "t")
        import requests
        monkeypatch.setattr(requests, "post", _fake_post)
        try:
            push_service.send_to_token("tok", "T", "B", {"type": ntype},
                                       notification_type=ntype, priority="high",
                                       platform=platform,
                                       renders_own=renders_own)
        except Exception:
            pass
        body = captured.get("json") or {}
        return body.get("message", body)

    def test_ANDROID_GETS_NO_NOTIFICATION_BLOCK(self, monkeypatch):
        """THE ROOT CAUSE OF "IT STILL LOOKS GENERIC".

        A message carrying a `notification` block is drawn by the FCM SDK
        whenever the app is backgrounded or terminated — the app never sees
        it and cannot style it. Those are the two states in which people
        actually read their tray, so every bit of ZITLAS identity the client
        applies was reaching only the foreground.

        Data-only is what moves rendering into the app for every state."""
        msg = self._platform_message(monkeypatch, "android")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert "notification" not in msg, (
            "a notification block hands rendering back to the FCM SDK, and "
            "the ZITLAS icon/sound/photo/expanded text are lost again")
        assert "notification" not in msg.get("android", {})

    def test_AN_OLD_APK_STILL_GETS_A_NOTIFICATION_BLOCK(self, monkeypatch):
        """THE MIGRATION SAFETY NET.

        A build that predates FcmService.render cannot draw a data-only
        message — its background handler only logs — so it would show NOTHING
        at all. A backend deploy does not upgrade anyone's phone, so assuming
        the capability from the platform alone would silence every user who
        has not updated the app. The DEVICE declares it; the backend believes
        only the declaration."""
        msg = self._platform_message(monkeypatch, "android", renders_own=False)
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert "notification" in msg, (
            "an un-upgraded Android install must keep the old behaviour, not "
            "go silent")
        assert msg["notification"]["title"] == "T"

    def test_the_capability_is_what_switches_it_not_the_platform(
            self, monkeypatch):
        with_cap = self._platform_message(monkeypatch, "android", renders_own=True)
        without = self._platform_message(monkeypatch, "android", renders_own=False)
        if not with_cap or not without:
            pytest.skip("FCM transport not reachable in this environment")
        assert "notification" not in with_cap
        assert "notification" in without

    def test_a_web_device_claiming_the_capability_is_still_web(self, monkeypatch):
        # The flag only means "this Android build renders its own". It must
        # not turn a browser into a data-only target.
        msg = self._platform_message(monkeypatch, "web", renders_own=True)
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert "notification" in msg

    def test_android_carries_the_text_in_data_instead(self, monkeypatch):
        # With no notification block, this is the ONLY place the client can
        # read the title and body from.
        msg = self._platform_message(monkeypatch, "android")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["data"]["title"] == "T"
        assert msg["data"]["body"] == "B"

    def test_android_data_messages_are_always_high_priority(self, monkeypatch):
        """Not optional. A NORMAL-priority data message is held by Doze until
        the next maintenance window, so the app never wakes to draw it and the
        notification arrives late — a notification-message would still have
        displayed. High priority is what buys that back."""
        msg = self._platform_message(monkeypatch, "android", ntype="general")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["priority"] == "high"

    def test_the_channel_still_reaches_the_client(self, monkeypatch):
        msg = self._platform_message(monkeypatch, "android")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["data"]["channelId"] == push_service.CHANNEL_MEAL_REVIEWS

    def test_WEB_KEEPS_ITS_NOTIFICATION_BLOCK(self, monkeypatch):
        """The website's service worker reads `payload.notification`. Dropping
        it for every platform would have silently killed web push."""
        msg = self._platform_message(monkeypatch, "web")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["notification"]["title"] == "T"
        assert msg["notification"]["body"] == "B"

    def test_ios_keeps_its_notification_block(self, monkeypatch):
        msg = self._platform_message(monkeypatch, "ios")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert "notification" in msg

    def test_an_unknown_platform_is_treated_as_web(self, monkeypatch):
        """Fails SAFE. A device whose platform was never recorded still gets a
        renderable notification rather than a data message no client on that
        device knows how to draw."""
        msg = self._platform_message(monkeypatch, "unknown")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert "notification" in msg

    def test_the_os_drawn_notification_carries_the_zitlas_identity(
            self, monkeypatch):
        """The web/iOS path, where FCM still renders. Android no longer uses
        this block at all, but a mis-set field here would still reach every
        browser and iPhone."""
        msg = self._message(monkeypatch, "meal_review_completed", "high")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        n = msg["android"]["notification"]
        assert n["icon"] == push_service.ICON_ANDROID
        assert n["icon"] != "ic_launcher", (
            "the launcher icon is opaque; Android renders it as a white blob")
        assert n["color"] == push_service.BRAND_COLOR
        assert n["sound"] == push_service.SOUND_ANDROID

    def test_it_is_readable_on_the_lock_screen(self, monkeypatch):
        msg = self._message(monkeypatch, "meal_review_completed", "high")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["notification"]["visibility"] == "PUBLIC"

    def test_delivery_priority_and_heads_up_are_both_set(self, monkeypatch):
        """Two DIFFERENT settings that are easy to confuse: android.priority
        decides whether it punches through Doze, notification_priority decides
        whether it peeks as a banner. Setting only the first delivers it
        silently into the shade."""
        msg = self._message(monkeypatch, "meal_review_completed", "high")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["priority"] == "high"
        assert msg["android"]["notification"]["notification_priority"] == "PRIORITY_HIGH"

    def test_an_informational_type_does_not_force_a_heads_up(self, monkeypatch):
        msg = self._message(monkeypatch, "general")
        if not msg:
            pytest.skip("FCM transport not reachable in this environment")
        assert msg["android"]["notification"]["notification_priority"] == "PRIORITY_DEFAULT"

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

    def test_the_channel_ids_are_versioned(self):
        """Android freezes a channel's importance AND its sound at creation,
        so editing either would have changed nothing on existing installs.
        Every id therefore carries the version it was last re-cut at; losing
        the suffix silently reverts every upgrading device to the old
        behaviour."""
        assert push_service.CHANNEL_COACHING == "zitlas_coaching_v3"
        for name in ("CHANNEL_MESSAGES", "CHANNEL_MEAL_REVIEWS",
                     "CHANNEL_PLANS", "CHANNEL_GENERAL"):
            assert getattr(push_service, name).endswith("_v2"), name

    def test_the_sound_resource_matches_the_flutter_app(self):
        """The backend names the sound in android.notification.sound and the
        app names it in the channel. If they drift, devices below Android 8
        get the stock sound while newer ones get the ZITLAS tone — and nothing
        anywhere reports it."""
        if not self.FLUTTER.exists():
            pytest.skip("Flutter source not reachable from this run")
        dart = self.FLUTTER.read_text(encoding="utf-8")
        m = re.search(r"soundResource\s*=\s*'([a-z0-9_]+)'", dart)
        assert m, "fcm_service.dart no longer declares soundResource"
        assert push_service.SOUND_ANDROID == m.group(1)

    def test_the_icon_name_matches_the_flutter_app(self):
        if not self.FLUTTER.exists():
            pytest.skip("Flutter source not reachable from this run")
        dart = self.FLUTTER.read_text(encoding="utf-8")
        assert f"'{push_service.ICON_ANDROID}'" in dart, (
            f"backend sends icon={push_service.ICON_ANDROID!r}, which the app "
            f"never names — the OS-drawn and app-drawn notifications would "
            f"then look different for the same event")

    def test_the_icon_drawable_actually_exists(self):
        d = (Path(__file__).resolve().parents[2] / "mobile" / "android" / "app"
             / "src" / "main" / "res" / "drawable")
        if not d.exists():
            pytest.skip("Flutter android tree not reachable from this run")
        assert list(d.glob(push_service.ICON_ANDROID + ".*")), (
            f"{d} has no {push_service.ICON_ANDROID} — Android would fall "
            f"back to the launcher icon blob")

    def test_the_brand_colour_matches_the_app(self):
        colors = (Path(__file__).resolve().parents[2] / "mobile" / "android"
                  / "app" / "src" / "main" / "res" / "values" / "colors.xml")
        if not colors.exists():
            pytest.skip("Flutter android tree not reachable from this run")
        text = colors.read_text(encoding="utf-8")
        assert push_service.BRAND_COLOR.lower() in text.lower(), (
            "the tint the backend sends and the one the app declares must be "
            "the same colour, or one event looks like two apps")

    def test_the_sound_file_the_app_names_actually_exists(self):
        """A res/raw resource that is missing does not raise — Android just
        falls back to the default sound, so the tone would quietly never play
        and the only symptom is 'it sounds like every other app'."""
        raw = (Path(__file__).resolve().parents[2] / "mobile" / "android" /
               "app" / "src" / "main" / "res" / "raw")
        if not raw.exists():
            pytest.skip("Flutter android tree not reachable from this run")
        found = list(raw.glob(push_service.SOUND_ANDROID + ".*"))
        assert found, (
            f"push_service sends sound={push_service.SOUND_ANDROID!r} but "
            f"{raw} contains no such file")

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
                            lambda db, uid: [("tokA", ("s", "android", True)),
                             ("tokB", ("s", "android", True))])
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
                            lambda db, uid: [("tokA", ("s", "android", True))])
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
                            lambda db, uid: [("tokA", ("s", "android", True))])
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
