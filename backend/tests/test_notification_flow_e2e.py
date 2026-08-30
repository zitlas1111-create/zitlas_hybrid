"""
ZITLAS — expert rates a meal, only active devices hear about it
(backend/tests/test_notification_flow_e2e.py)

Walks the whole server-side pipeline for one meal review — template, device
selection, FCM payload, dead-token pruning, logging — against a fake Firestore
and a fake FCM transport. The scenarios are the ones in the spec:

    E  user logs out            -> that device gets nothing
    F  user logs back in        -> it works again
    G  an old token exists      -> it is not targeted
    H  the same event twice     -> one notification
    I  two active devices       -> both get it
    J  an invalid token         -> removed, not retried forever

What this canNOT prove, and what still needs a phone: that Android draws the
notification, that the channel plays the ZITLAS tone, that the lock screen
shows it, and that tapping it opens the meal. Those live past the FCM
boundary, which is exactly where this test stops.

Run: python -m pytest tests/test_notification_flow_e2e.py -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from services import notification_service, push_service  # noqa: E402
from services import notification_templates              # noqa: E402
from tests.fake_firestore import FakeClient              # noqa: E402

ATHLETE = "athlete_1"
COACH = "coach_1"
CHECKIN = "MCI_1"

PHONE = "tok_phone"
LAPTOP = "tok_laptop"
OLD = "tok_old_from_last_year"


@pytest.fixture
def db():
    return FakeClient()


@pytest.fixture
def fcm(monkeypatch):
    """Fake FCM. `dead` lists tokens it reports as permanently gone."""
    class Transport:
        def __init__(self):
            self.calls: list[tuple[str, dict]] = []
            self.dead: set[str] = set()

        def __call__(self, token, title, body, data, **kw):
            self.calls.append((token, {"title": title, "body": body,
                                       "data": data, **kw}))
            if token in self.dead:
                return {"ok": False, "status": 404, "dead_token": True,
                        "detail": {"error": {"status": "NOT_FOUND", "details": [
                            {"errorCode": "UNREGISTERED"}]}}}
            return {"ok": True, "status": 200}

    t = Transport()
    monkeypatch.setattr(push_service, "send_to_token", t)
    return t


def login(db, token, uid=ATHLETE, platform="android"):
    """What FcmService._storeToken / push-notifications.js storeToken write."""
    db.collection("device_tokens").document(token).set({
        "fcmToken": token, "uid": uid, "platform": platform,
        "deviceId": f"dev_{token}", "enabled": True, "loggedIn": True,
        "lastActiveAt": "2026-08-30T10:00:00Z",
    })
    _array_add(db, uid, token)


def logout(db, token, uid=ATHLETE):
    """The tombstone both clients now write BEFORE signing out."""
    doc = db.collection("device_tokens").document(token)
    existing = doc.get().to_dict() or {}
    existing.update({"fcmToken": token, "uid": uid,
                     "enabled": False, "loggedIn": False})
    doc.set(existing)
    _array_remove(db, uid, token)


def _array_add(db, uid, token):
    ref = db.collection("users").document(uid)
    cur = (ref.get().to_dict() or {}).get("pushTokens") or []
    ref.set({"pushTokens": cur + [t for t in [token] if t not in cur]})


def _array_remove(db, uid, token):
    ref = db.collection("users").document(uid)
    cur = (ref.get().to_dict() or {}).get("pushTokens") or []
    ref.set({"pushTokens": [t for t in cur if t != token]})


def review(db, **over):
    """Sends the meal-review notification exactly as the route does."""
    note = notification_templates.meal_review_completed(
        checkin_id=over.get("checkin_id", CHECKIN),
        meal_name="Lunch", coach_name="Coach Srujan",
        coach_id=COACH, athlete_id=ATHLETE,
        rating=over.get("rating", 4.0), comment=over.get("comment"),
    )
    return notification_service.send(
        db, ATHLETE, note.title, note.body,
        category=note.category, type=note.type, action=note.action,
        priority=note.priority, data=note.data,
        collapse_key=note.data.get("eventId"),
    )


def targeted(fcm) -> set[str]:
    return {tok for tok, _ in fcm.calls}


# ── E / F: the logout round trip ────────────────────────────────────────────

class TestLoggingOutStopsDelivery:
    def test_E_a_logged_out_device_receives_nothing(self, db, fcm):
        login(db, PHONE)
        logout(db, PHONE)

        res = review(db)

        assert fcm.calls == [], "a logged-out phone must not be a target"
        assert res["sent"] == 0
        assert res["reason"] == "no_active_authenticated_session"

    def test_F_logging_back_in_restores_delivery(self, db, fcm):
        login(db, PHONE)
        logout(db, PHONE)
        assert review(db)["sent"] == 0

        login(db, PHONE)                      # same phone, signs back in
        res = review(db, checkin_id="MCI_2")

        assert targeted(fcm) == {PHONE}
        assert res["sent"] == 1

    def test_the_array_alone_cannot_resurrect_a_logged_out_device(self, db, fcm):
        """The website's array is append-only and nothing else prunes it, so
        this is the shape that kept logged-out devices receiving."""
        login(db, PHONE)
        logout(db, PHONE)
        _array_add(db, ATHLETE, PHONE)        # array says yes, registry says no

        assert review(db)["sent"] == 0
        assert fcm.calls == []


# ── G: historical tokens ────────────────────────────────────────────────────

class TestOldTokensAreNotTargeted:
    def test_G_five_historical_tokens_one_real_device(self, db, fcm):
        """The exact production shape behind `tokens=3 sent=3` for a user with
        one phone."""
        for i in range(5):
            _array_add(db, ATHLETE, f"{OLD}_{i}")   # array only, no registry
        login(db, PHONE)                            # the one real device

        res = review(db)

        assert targeted(fcm) == {PHONE}, (
            "historical tokens are not devices anybody is signed in on")
        assert res["activeDevices"] == 1
        assert res["tokens"] == 1

    def test_they_come_back_when_that_device_is_used_again(self, db, fcm):
        _array_add(db, ATHLETE, OLD)
        assert review(db)["sent"] == 0

        login(db, OLD)                        # that browser opens ZITLAS
        assert review(db, checkin_id="MCI_2")["sent"] == 1


# ── H: idempotency ──────────────────────────────────────────────────────────

class TestOneEventOneNotification:
    def test_H_the_same_review_twice_collapses_on_the_device(self, db, fcm):
        login(db, PHONE)
        review(db)
        review(db)                            # the route's stamp is bypassed

        keys = [kw["collapse_key"] for _, kw in fcm.calls]
        assert keys == [f"meal_review_completed_{CHECKIN}"] * 2, (
            "a stable collapse key is what makes a redelivery REPLACE the "
            "tray entry instead of stacking a second copy")

    def test_two_different_reviews_stay_separate(self, db, fcm):
        login(db, PHONE)
        review(db, checkin_id="MCI_1")
        review(db, checkin_id="MCI_2")
        keys = {kw["collapse_key"] for _, kw in fcm.calls}
        assert len(keys) == 2, "distinct meals must not collapse into one"


# ── I: several legitimate devices ───────────────────────────────────────────

class TestMultipleActiveDevices:
    def test_I_both_signed_in_devices_receive_it(self, db, fcm):
        login(db, PHONE, platform="android")
        login(db, LAPTOP, platform="web")

        res = review(db)

        assert targeted(fcm) == {PHONE, LAPTOP}
        assert res["activeDevices"] == 2

    def test_signing_out_one_leaves_the_other(self, db, fcm):
        login(db, PHONE)
        login(db, LAPTOP)
        logout(db, LAPTOP)

        review(db)

        assert targeted(fcm) == {PHONE}


# ── J: dead tokens ──────────────────────────────────────────────────────────

class TestInvalidTokensAreRemoved:
    def test_J_a_dead_token_is_pruned_and_not_retried(self, db, fcm):
        login(db, PHONE)
        login(db, LAPTOP)
        fcm.dead.add(LAPTOP)                  # app uninstalled

        first = review(db)
        assert first["sent"] == 1 and first["failed"] == 1
        assert first["staleTokensRemoved"] == 1

        fcm.calls.clear()
        second = review(db, checkin_id="MCI_2")

        assert targeted(fcm) == {PHONE}, (
            "a token FCM called UNREGISTERED must not be retried forever")
        assert second["failed"] == 0

    def test_a_transient_failure_does_NOT_prune(self, db, fcm, monkeypatch):
        """Quota and outage errors are temporary. Pruning on those would wipe
        every user's devices during an FCM incident."""
        login(db, PHONE)
        monkeypatch.setattr(push_service, "send_to_token",
                            lambda *a, **k: {"ok": False, "status": 503,
                                             "dead_token": False, "detail": {}})
        res = review(db)
        assert res["failed"] == 1 and res["staleTokensRemoved"] == 0

        monkeypatch.setattr(push_service, "send_to_token", fcm)
        assert review(db, checkin_id="MCI_2")["sent"] == 1, (
            "the device must survive a transient failure")


# ── The log line the on-call reads ──────────────────────────────────────────

class TestTheLogProvesTheTargeting:
    def test_it_reports_active_devices_not_stored_tokens(self, db, fcm, capsys):
        for i in range(4):
            _array_add(db, ATHLETE, f"{OLD}_{i}")
        login(db, PHONE)

        review(db)

        line = [l for l in capsys.readouterr().out.splitlines()
                if l.startswith("[NOTIFY] type=")][-1]
        assert "activeDevices=1" in line
        assert "tokensTargeted=1" in line
        assert "sent=1" in line
        assert "failed=0" in line
        assert "staleTokensRemoved=0" in line
        assert "fcmPriority=high" in line

    def test_every_skipped_token_says_why(self, db, fcm, capsys):
        login(db, PHONE)
        login(db, LAPTOP)
        logout(db, LAPTOP)
        _array_add(db, ATHLETE, LAPTOP)
        _array_add(db, ATHLETE, OLD)

        review(db)

        out = capsys.readouterr().out
        assert "reason=signed_out" in out
        assert "reason=unregistered_device" in out
        # …and never the token itself.
        assert OLD not in out, "a full FCM token is a credential"

    def test_nobody_signed_in_is_not_reported_as_a_failure(self, db, fcm, capsys):
        review(db)
        out = capsys.readouterr().out
        assert "reason=no_active_authenticated_session" in out
        assert "failed=0" in out
