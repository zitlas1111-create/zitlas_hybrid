"""
ZITLAS — an unreadable approval must not be reported as "not an expert"
(backend/tests/test_expert_lookup_unavailable.py)

THE BUG THIS PINS
-----------------
`is_approved_expert()` wrapped the Firestore read in a bare
`except Exception: return False`. Safe for authorization — but it made an
INFRASTRUCTURE FAULT indistinguishable from a verdict, so `/api/auth/role`
answered a confident `{"role":"user","isExpert":false}` for genuinely
approved experts.

That is exactly what production did. The deployed backend logged:

    [AUTH] expert lookup failed ... InvalidArgument: 400
           Invalid database id %28default%29
    [AUTH] role uid=... token_expert_claim=True firestore_approved=False -> user

The claim was present and correct; only the Firestore read failed. The
swallow turned that into "normal user", and all three approved experts were
landed in the athlete app. Verified against production: an ID token carrying
`expert: true` still received `isExpert: false`.

THE CONTRACT NOW
    True  -> approved            (verdict)
    False -> not approved / absent (verdict)
    None  -> could not ask        (NOT a verdict)

`/api/auth/role` returns 503 for None rather than inventing "user". Both
clients already treat a non-answer as "hold and retry" (assets/js/
role-service.js, RoleRepository.fetchRole), so nobody is mis-landed — and
`is_expert()` still fails CLOSED, so nobody is let in either.

Run: python -m pytest tests/test_expert_lookup_unavailable.py -q
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient              # noqa: E402
from services import auth_service                        # noqa: E402
from services.auth_service import verify_firebase_token  # noqa: E402
import routes.auth as auth_routes                        # noqa: E402

EXPERT_UIDS = ["expert_uid_1", "expert_uid_2", "expert_uid_3"]

NORMAL_USER = {"uid": "normal_user", "email": "user@example.com",
               "admin": False, "expert": False, "email_verified": True}


def expert_caller(uid: str, *, claim: bool = True) -> dict:
    return {"uid": uid, "email": f"{uid}@example.com", "admin": False,
            "expert": claim, "email_verified": True}


def make_app(caller: dict) -> TestClient:
    app = FastAPI()
    app.include_router(auth_routes.router, prefix="/api/auth")
    app.dependency_overrides[verify_firebase_token] = lambda: caller
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    """The lookup retries with backoff; tests must not pay for it."""
    monkeypatch.setattr("services.auth_service.time.sleep", lambda _s: None)


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    for uid in EXPERT_UIDS:
        client.collection("experts").document(uid).set(
            {"approved": True, "name": f"Expert {uid}"})
    monkeypatch.setattr("services.firestore_service.get_client", lambda: client)
    return client


class _ExplodingClient:
    """Firestore that raises the EXACT production error."""

    def __init__(self, exc=None, fail_times=None):
        self.calls = 0
        self._exc = exc or Exception(
            "400 Invalid database id %28default%29")
        self._fail_times = fail_times  # None = always fail

    def collection(self, _name):
        return self

    def document(self, _id):
        return self

    def get(self):
        self.calls += 1
        if self._fail_times is None or self.calls <= self._fail_times:
            raise self._exc
        class _Snap:
            exists = True
            @staticmethod
            def to_dict():
                return {"approved": True}
        return _Snap()


# ── The verdicts still work ──────────────────────────────────────────────────

class TestVerdictsAreUnchanged:
    @pytest.mark.parametrize("uid", EXPERT_UIDS)
    def test_each_approved_expert_still_resolves_to_expert(self, db, uid):
        assert auth_service.is_approved_expert(uid) is True
        assert auth_service.is_expert(expert_caller(uid)) is True
        body = make_app(expert_caller(uid)).get("/api/auth/role").json()
        assert body["role"] == "expert" and body["isExpert"] is True

    def test_an_unapproved_expert_document_is_a_verdict(self, db):
        db.collection("experts").document("pending_guy").set({"approved": False})
        assert auth_service.is_approved_expert("pending_guy") is False
        body = make_app(expert_caller("pending_guy")).get("/api/auth/role").json()
        assert body["role"] == "user"

    def test_a_missing_expert_document_is_a_verdict(self, db):
        assert auth_service.is_approved_expert("nobody") is False

    def test_a_normal_user_is_still_a_user(self, db):
        body = make_app(NORMAL_USER).get("/api/auth/role").json()
        assert body["role"] == "user" and body["isExpert"] is False

    def test_a_missing_claim_is_a_verdict_and_skips_the_lookup(self, db):
        # No claim -> no Firestore read at all, so a broken Firestore cannot
        # turn a normal user into a 503.
        body = make_app(expert_caller("expert_uid_1", claim=False)).get(
            "/api/auth/role").json()
        assert body["role"] == "user"


# ── THE REGRESSION ───────────────────────────────────────────────────────────

class TestAnUnreadableApprovalIsNotAVerdict:
    def test_the_production_error_yields_None_not_False(self, monkeypatch):
        monkeypatch.setattr("services.firestore_service.get_client",
                            lambda: _ExplodingClient())
        assert auth_service.is_approved_expert("expert_uid_1") is None, (
            "returning False here is the bug: it reports an outage as "
            "'this account is not an expert'")

    def test_a_missing_client_yields_None(self, monkeypatch):
        monkeypatch.setattr("services.firestore_service.get_client", lambda: None)
        assert auth_service.is_approved_expert("expert_uid_1") is None

    def test_the_endpoint_refuses_to_answer_user(self, monkeypatch):
        monkeypatch.setattr("services.firestore_service.get_client",
                            lambda: _ExplodingClient())
        res = make_app(expert_caller("expert_uid_1")).get("/api/auth/role")
        assert res.status_code == 503, (
            "answering 200 {'role':'user'} is what landed approved experts "
            "in the athlete app")
        assert res.json()["detail"] == "role_unavailable"

    @pytest.mark.parametrize("uid", EXPERT_UIDS)
    def test_none_of_the_three_is_ever_told_they_are_a_normal_user(
            self, monkeypatch, uid):
        monkeypatch.setattr("services.firestore_service.get_client",
                            lambda: _ExplodingClient())
        res = make_app(expert_caller(uid)).get("/api/auth/role")
        assert res.status_code != 200 or res.json()["role"] != "user"

    def test_a_transient_fault_is_retried_and_recovers(self, monkeypatch):
        client = _ExplodingClient(fail_times=1)
        monkeypatch.setattr("services.firestore_service.get_client", lambda: client)
        assert auth_service.is_approved_expert("expert_uid_1") is True, (
            "one blip must not cost an expert their dashboard")
        assert client.calls == 2

    def test_it_gives_up_rather_than_guessing(self, monkeypatch):
        client = _ExplodingClient()
        monkeypatch.setattr("services.firestore_service.get_client", lambda: client)
        assert auth_service.is_approved_expert("expert_uid_1") is None
        assert client.calls == auth_service._EXPERT_LOOKUP_ATTEMPTS


# ── ...but access is still denied ────────────────────────────────────────────

class TestAccessStillFailsClosed:
    def test_is_expert_denies_when_the_check_cannot_run(self, monkeypatch):
        monkeypatch.setattr("services.firestore_service.get_client",
                            lambda: _ExplodingClient())
        assert auth_service.is_expert(expert_caller("expert_uid_1")) is False, (
            "an unanswerable approval check must never GRANT access"
        )

    def test_resolve_role_denies_when_the_check_cannot_run(self, monkeypatch):
        monkeypatch.setattr("services.firestore_service.get_client",
                            lambda: _ExplodingClient())
        assert auth_service.resolve_role(expert_caller("expert_uid_1")) == "user"

    def test_a_client_supplied_role_never_helps(self, monkeypatch):
        monkeypatch.setattr("services.firestore_service.get_client",
                            lambda: _ExplodingClient())
        forged = {"uid": "attacker", "email": "a@b.c", "expert": False,
                  "role": "expert", "isExpert": True, "email_verified": True}
        assert auth_service.is_expert(forged) is False
        body = make_app(forged).get("/api/auth/role").json()
        assert body["role"] == "user"


# ── The lookup works for ANY uid, not a hardcoded list ───────────────────────

class TestItIsNotHardcoded:
    def test_a_brand_new_approved_expert_resolves_to_expert(self, db):
        db.collection("experts").document("future_expert_42").set(
            {"approved": True, "name": "Future"})
        assert auth_service.is_approved_expert("future_expert_42") is True
        body = make_app(expert_caller("future_expert_42")).get(
            "/api/auth/role").json()
        assert body["role"] == "expert"

    def test_no_expert_uid_is_baked_into_the_source(self):
        src = open(
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "services", "auth_service.py"),
            encoding="utf-8").read()
        for uid in ("pEL6QmJmohSsEpvmGTqHjrMse7b2",
                    "qEX2DhZVWXd2LcBb9rwnSXGVQkx1",
                    "r1idSpMOJaQM3R6Jny73XPWcnxq1"):
            assert uid not in src, "expert identity must live in data, not code"
