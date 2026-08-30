"""
ZITLAS — a push goes only to devices this account is signed in on
(backend/tests/test_notification_targeting.py)

THE BUG THIS PINS
-----------------
Tokens came from two places and only one of them knew about sessions:

  device_tokens/{fcmToken}   keyed BY TOKEN, carries uid + enabled. Signing in
                             re-registers the same document under the new uid,
                             so a device belongs to exactly one account.
  users/{uid}.pushTokens     a plain array, written by the website. Append-only
                             in practice: it keeps a token after that device
                             signs out, and the SAME device can sit in two
                             different accounts' arrays at once.

The array was trusted on its own, so a token in it was treated as a live
session. Found in production: users/qEX2DhZVWXd2… (an approved EXPERT) still
listed a token that device_tokens showed was by then owned by a different
athlete — so that athlete's phone was a delivery target for the expert's
private notifications.

device_tokens is now the OWNER OF RECORD. When it has an entry for a token it
decides; a mismatch drops the token. Tokens with no entry at all are still
sent to, because that is every website-only device, and dropping them would
silently end push for them — they are logged as unverified instead.

Run: python -m pytest tests/test_notification_targeting.py -q
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient          # noqa: E402
from services import notification_service            # noqa: E402

ATHLETE = "athlete_uid"
OTHER = "other_uid"


@pytest.fixture
def db():
    return FakeClient()


def register(db, token: str, uid: str, *, enabled: bool = True):
    db.collection("device_tokens").document(token).set({
        "fcmToken": token, "uid": uid, "enabled": enabled,
        "platform": "android", "deviceId": "dev_1",
    })


def legacy(db, uid: str, tokens: list[str]):
    db.collection("users").document(uid).set({"pushTokens": tokens})


def tokens_for(db, uid: str) -> dict[str, str]:
    return dict(notification_service._tokens_for_user(db, uid))


class TestTheRegistryDecides:
    def test_a_signed_in_device_is_targeted(self, db):
        register(db, "tok_a", ATHLETE)
        assert tokens_for(db, ATHLETE) == {"tok_a": "registry"}

    def test_a_signed_out_device_is_not(self, db):
        register(db, "tok_a", ATHLETE, enabled=False)
        assert tokens_for(db, ATHLETE) == {}

    def test_another_accounts_device_is_never_targeted(self, db):
        # The registry says this device now belongs to OTHER.
        register(db, "tok_shared", OTHER)
        assert tokens_for(db, ATHLETE) == {}


class TestTheLegacyArrayIsNotProofOfASession:
    def test_THE_LEAK_a_token_owned_by_another_account_is_dropped(self, db):
        """The exact production shape: the array still lists a token that the
        registry says belongs to somebody else."""
        register(db, "tok_shared", OTHER)
        legacy(db, ATHLETE, ["tok_shared"])
        assert tokens_for(db, ATHLETE) == {}, (
            "this delivered one account's private notification to another "
            "account's phone")

    def test_a_token_the_owner_signed_out_of_is_dropped(self, db):
        register(db, "tok_a", ATHLETE, enabled=False)
        legacy(db, ATHLETE, ["tok_a"])
        assert tokens_for(db, ATHLETE) == {}, (
            "logging out must stop delivery even though the array still "
            "lists the token")

    def test_an_unregistered_device_is_NOT_reached(self, db):
        """A token in the array with no registry row is not evidence of a
        session. It used to be delivered to, on the grounds that website
        devices only ever wrote the array — but the website now registers in
        `device_tokens` as well, so "no row" means a device that has not
        opened ZITLAS since that shipped. Those are exactly the historical
        tokens that made one phone look like three."""
        legacy(db, ATHLETE, ["tok_old"])
        assert tokens_for(db, ATHLETE) == {}

    def test_it_self_heals_when_that_device_opens_the_app(self, db):
        legacy(db, ATHLETE, ["tok_web"])
        assert tokens_for(db, ATHLETE) == {}
        register(db, "tok_web", ATHLETE)          # the browser opens ZITLAS
        assert tokens_for(db, ATHLETE) == {"tok_web": "registry"}

    def test_the_registry_wins_over_the_array_for_the_same_device(self, db):
        register(db, "tok_a", ATHLETE)
        legacy(db, ATHLETE, ["tok_a"])
        # Counted once, and as the registry entry so pruning removes it there.
        assert tokens_for(db, ATHLETE) == {"tok_a": "registry"}


class TestAccountSwitchingOnOneDevice:
    def test_after_B_signs_in_A_no_longer_reaches_that_device(self, db):
        # A was signed in, and the website array recorded it.
        register(db, "tok_phone", ATHLETE)
        legacy(db, ATHLETE, ["tok_phone"])
        assert tokens_for(db, ATHLETE) == {"tok_phone": "registry"}

        # B signs in on the SAME phone — same token, re-registered.
        register(db, "tok_phone", OTHER)

        assert tokens_for(db, ATHLETE) == {}, (
            "A must stop reaching a phone that is now signed in as B")
        assert tokens_for(db, OTHER) == {"tok_phone": "registry"}

    def test_B_never_inherits_As_array_entry(self, db):
        register(db, "tok_phone", OTHER)
        legacy(db, ATHLETE, ["tok_phone"])
        assert "tok_phone" not in tokens_for(db, ATHLETE)


class TestFailureModes:
    def test_an_unreachable_registry_does_not_silence_everything(self, db, monkeypatch):
        """"Could not find out" must never be treated as "signed out".

        Absence and unavailability were once the same return value. That was
        harmless while an unknown token was delivered to anyway — and became
        a silent, total outage the moment absence started skipping tokens."""
        legacy(db, ATHLETE, ["tok_web"])
        monkeypatch.setattr(
            notification_service, "_registry_owner",
            lambda _db, _t: (None, None, notification_service.REGISTRY_UNAVAILABLE))
        assert tokens_for(db, ATHLETE) == {"tok_web": "legacy"}, (
            "a Firestore blip must not read as every user signing out at once")

    def test_but_a_confirmed_absence_still_skips(self, db, monkeypatch):
        legacy(db, ATHLETE, ["tok_web"])
        monkeypatch.setattr(
            notification_service, "_registry_owner",
            lambda _db, _t: (None, None, notification_service.REGISTRY_ABSENT))
        assert tokens_for(db, ATHLETE) == {}

    def test_no_devices_reports_why(self, db):
        """Nobody is signed in. That is a different outcome from "FCM refused
        it", and the caller must be able to tell them apart."""
        result = notification_service.push_only(
            db, ATHLETE, title="t", body="b", type="meal_review_completed",
        )
        assert result["sent"] == 0
        assert result.get("reason") == "no_active_authenticated_session", (
            "'nobody is signed in' must not look like 'the push failed'")

    def test_an_empty_uid_is_not_a_broadcast(self, db):
        assert tokens_for(db, "") == {}


class TestTheLogsAreUsableAndSafe:
    """A push that fails on a real phone is diagnosed from these lines alone."""

    def test_a_full_token_never_reaches_a_log(self):
        token = "f" * 163  # a realistic FCM token length
        out = notification_service._short(token)
        assert token not in out
        assert len(out) < 20
        assert out.startswith("ffff"), "a prefix must still correlate two lines"

    def test_a_short_token_is_not_mangled(self):
        assert notification_service._short("abc") == "abc"

    def test_a_dead_device_is_distinguishable_from_an_outage(self):
        dead = {"error": {"status": "NOT_FOUND", "details": [
            {"errorCode": "UNREGISTERED"}]}}
        auth = {"error": {"status": "UNAUTHENTICATED", "details": [
            {"errorCode": "THIRD_PARTY_AUTH_ERROR"}]}}
        assert notification_service._fcm_error_code(dead) == "UNREGISTERED"
        assert notification_service._fcm_error_code(auth) == "THIRD_PARTY_AUTH_ERROR"

    def test_it_falls_back_to_the_status_when_there_is_no_detail(self):
        assert notification_service._fcm_error_code(
            {"error": {"status": "INTERNAL"}}) == "INTERNAL"

    def test_a_junk_body_does_not_break_the_send_loop(self):
        # FCM returns plain text on some failures. Logging must not raise
        # inside the loop over a user's devices.
        for junk in (None, "502 Bad Gateway", {}, {"error": "nope"}, []):
            assert notification_service._fcm_error_code(junk) == "unknown"
