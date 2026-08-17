"""
ZITLAS — Admin Google login + first-admin bootstrap
(backend/tests/test_admin_bootstrap.py)

The Admin Portal signs in with Google and restricts access to a server-side
configured address. The security model these tests pin:

  * ZITLAS_ADMIN_EMAILS grants ELIGIBILITY TO BOOTSTRAP, never authorisation.
    `is_admin()` / `require_admin` must not consult it, so an email alone can
    never open a privileged endpoint.
  * The bootstrap grants the claim to the CALLER'S OWN uid, taken from the
    cryptographically verified token. There is no request body, so there is no
    uid or email field for a client to tamper with.
  * The frontend email check is UX. Every privileged endpoint stays behind
    require_admin.

Run: python -m pytest tests/test_admin_bootstrap.py -q
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from routes import admin  # noqa: E402
from services import admin_service, auth_service, firestore_service, identity_service  # noqa: E402
from tests.fake_firestore import FakeClient  # noqa: E402

OWNER_EMAIL = "zitlas111@gmail.com"
OWNER_UID = "owner_uid_1"
ATHLETE_UID = "athlete_1"
EXPERT_UID = "expert_1"


@pytest.fixture
def granted():
    """Records every uid handed to identity_service.grant_admin."""
    return []


@pytest.fixture
def fake_db(monkeypatch, granted):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore_service, "config_error", lambda: None, raising=False)

    def _grant(uid):
        granted.append(uid)
        return True

    monkeypatch.setattr(identity_service, "grant_admin", _grant)
    monkeypatch.setattr(identity_service, "revoke_admin", lambda uid: True, raising=False)
    monkeypatch.setattr(identity_service, "grant_expert", lambda uid: True)
    monkeypatch.setattr(identity_service, "revoke_expert", lambda uid: True)
    return client


@pytest.fixture
def allowlist(monkeypatch):
    """The configured admin email, as the deployment would set it."""
    monkeypatch.setattr(auth_service, "_ADMIN_EMAILS", {OWNER_EMAIL})


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(admin.router, prefix="/api/admin")
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid, *, email=None, email_verified=True, is_admin=False, is_expert=False):
    """Authenticate as a caller whose facts come from a VERIFIED token.

    Overriding the token dependency is the only way to test this: the real one
    verifies a Firebase signature that cannot be minted in a unit test. Every
    field here stands in for a verified claim, not a client-supplied value.
    """
    app.dependency_overrides[admin.verify_firebase_token] = lambda: {
        "uid": uid, "email": email, "name": uid,
        "email_verified": email_verified, "admin": is_admin, "expert": is_expert,
    }


def _audit(fake_db):
    return [d for p, d in fake_db.store.items()
            if p.startswith(f"{admin_service.AUDIT_COLLECTION}/")]


class TestEmailIsNotAuthorization:
    """The single most important property: being the configured email does NOT
    make you an admin. Only the claim does."""

    def test_the_owner_email_alone_does_NOT_open_privileged_endpoints(
        self, app, client, fake_db, allowlist
    ):
        _as(app, OWNER_UID, email=OWNER_EMAIL)   # eligible, but no claim yet
        for path in ["/api/admin/dashboard", "/api/admin/audit-logs", "/api/admin/system/health"]:
            assert client.get(path).status_code == 403, path

    def test_is_admin_never_consults_the_email_allowlist(self, allowlist):
        caller = {"uid": OWNER_UID, "email": OWNER_EMAIL, "email_verified": True, "admin": False}
        assert auth_service.is_admin(caller) is False
        # Eligible to bootstrap, but not an admin.
        assert auth_service.is_bootstrap_email(caller) is True

    def test_the_claim_is_what_opens_the_door(self, app, client, fake_db, allowlist):
        _as(app, OWNER_UID, email=OWNER_EMAIL, is_admin=True)
        assert client.get("/api/admin/dashboard").status_code == 200


class TestEligibility:
    def test_the_configured_email_is_eligible(self, allowlist):
        assert auth_service.is_bootstrap_email(
            {"email": OWNER_EMAIL, "email_verified": True}) is True

    def test_matching_is_case_normalised(self, allowlist):
        for variant in ["ZITLAS111@GMAIL.COM", "Zitlas111@Gmail.com", "  zitlas111@gmail.com  "]:
            assert auth_service.is_bootstrap_email(
                {"email": variant, "email_verified": True}) is True, variant

    def test_a_different_email_is_not_eligible(self, allowlist):
        for other in ["someone@gmail.com", "zitlas112@gmail.com", "zitlas111@gmail.co",
                      "zitlas111@gmail.com.evil.com", "azitlas111@gmail.com"]:
            assert auth_service.is_bootstrap_email(
                {"email": other, "email_verified": True}) is False, other

    def test_an_unverified_email_is_not_eligible(self, allowlist):
        # Stops an unverified password account registered at the same address
        # from qualifying.
        assert auth_service.is_bootstrap_email(
            {"email": OWNER_EMAIL, "email_verified": False}) is False

    def test_a_missing_email_is_not_eligible(self, allowlist):
        assert auth_service.is_bootstrap_email({"email": None, "email_verified": True}) is False
        assert auth_service.is_bootstrap_email({"email": "", "email_verified": True}) is False

    def test_an_UNSET_allowlist_makes_NOBODY_eligible(self, monkeypatch):
        # Off by default, not open by default.
        monkeypatch.setattr(auth_service, "_ADMIN_EMAILS", set())
        assert auth_service.is_bootstrap_email(
            {"email": OWNER_EMAIL, "email_verified": True}) is False


class TestSessionEndpoint:
    def test_unauthenticated_is_401(self, app, client, fake_db, allowlist):
        app.dependency_overrides.clear()
        assert client.get("/api/admin/session").status_code == 401

    def test_an_athlete_gets_a_session_saying_NO(self, app, client, fake_db, allowlist):
        # /session is readable by any signed-in user by design — it reports only
        # about the caller and is what drives the login screen's states.
        _as(app, ATHLETE_UID, email="athlete@x.com")
        body = client.get("/api/admin/session").json()
        assert body["isAdmin"] is False
        assert body["bootstrapEligible"] is False

    def test_the_owner_before_bootstrap_reports_eligible_but_not_admin(
        self, app, client, fake_db, allowlist
    ):
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        body = client.get("/api/admin/session").json()
        assert (body["isAdmin"], body["bootstrapEligible"]) == (False, True)
        assert body["uid"] == OWNER_UID and body["email"] == OWNER_EMAIL

    def test_the_owner_after_bootstrap_reports_admin(self, app, client, fake_db, allowlist):
        _as(app, OWNER_UID, email=OWNER_EMAIL, is_admin=True)
        assert client.get("/api/admin/session").json()["isAdmin"] is True

    def test_session_cannot_be_used_to_probe_another_address(
        self, app, client, fake_db, allowlist
    ):
        # A client-supplied email must be ignored entirely: the answer describes
        # the TOKEN's identity, so this cannot enumerate the allowlist.
        _as(app, ATHLETE_UID, email="athlete@x.com")
        body = client.get(f"/api/admin/session?email={OWNER_EMAIL}").json()
        assert body["email"] == "athlete@x.com"
        assert body["bootstrapEligible"] is False


class TestBootstrap:
    def test_unauthenticated_cannot_bootstrap(self, app, client, fake_db, allowlist):
        app.dependency_overrides.clear()
        assert client.post("/api/admin/bootstrap").status_code == 401

    def test_an_athlete_cannot_bootstrap(self, app, client, fake_db, allowlist, granted):
        _as(app, ATHLETE_UID, email="athlete@x.com")
        assert client.post("/api/admin/bootstrap").status_code == 403
        assert granted == []

    def test_an_expert_cannot_bootstrap(self, app, client, fake_db, allowlist, granted):
        _as(app, EXPERT_UID, email="expert@x.com", is_expert=True)
        assert client.post("/api/admin/bootstrap").status_code == 403
        assert granted == []

    def test_an_unverified_owner_email_cannot_bootstrap(
        self, app, client, fake_db, allowlist, granted
    ):
        _as(app, OWNER_UID, email=OWNER_EMAIL, email_verified=False)
        assert client.post("/api/admin/bootstrap").status_code == 403
        assert granted == []

    def test_the_owner_CAN_bootstrap_and_gets_the_claim(
        self, app, client, fake_db, allowlist, granted
    ):
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        body = client.post("/api/admin/bootstrap").json()
        assert body["claimSet"] is True
        assert body["alreadyAdmin"] is False
        # Granted to the TOKEN's uid.
        assert granted == [OWNER_UID]

    def test_the_grant_target_is_the_TOKEN_uid_not_anything_client_sent(
        self, app, client, fake_db, allowlist, granted
    ):
        """The core anti-tamper property. Even a body full of hostile fields
        cannot redirect the grant — the endpoint reads none of it."""
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        r = client.post("/api/admin/bootstrap", json={
            "uid": "attacker_uid", "expertId": "attacker_uid",
            "email": "attacker@evil.com", "admin": True, "targetUid": "attacker_uid",
        })
        assert r.status_code == 200
        assert granted == [OWNER_UID], "the grant followed a client-supplied uid"

    def test_an_athlete_cannot_bootstrap_by_claiming_the_owner_email(
        self, app, client, fake_db, allowlist, granted
    ):
        _as(app, ATHLETE_UID, email="athlete@x.com")
        r = client.post("/api/admin/bootstrap", json={"email": OWNER_EMAIL, "admin": True})
        assert r.status_code == 403
        assert granted == []

    def test_forged_admin_query_and_header_are_inert(
        self, app, client, fake_db, allowlist, granted
    ):
        _as(app, ATHLETE_UID, email="athlete@x.com")
        assert client.post("/api/admin/bootstrap?admin=true",
                           headers={"X-Admin": "true"}).status_code == 403
        assert granted == []

    def test_bootstrap_is_idempotent_for_an_existing_admin(
        self, app, client, fake_db, allowlist, granted
    ):
        # A double-click must not read as a failure.
        _as(app, OWNER_UID, email=OWNER_EMAIL, is_admin=True)
        body = client.post("/api/admin/bootstrap").json()
        assert body["alreadyAdmin"] is True and body["claimSet"] is True
        # No redundant claim write.
        assert granted == []

    def test_bootstrap_with_an_unset_allowlist_is_refused(
        self, app, client, fake_db, monkeypatch, granted
    ):
        monkeypatch.setattr(auth_service, "_ADMIN_EMAILS", set())
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        assert client.post("/api/admin/bootstrap").status_code == 403
        assert granted == []

    def test_a_failed_claim_write_returns_503_NOT_a_false_success(
        self, app, client, fake_db, allowlist, monkeypatch
    ):
        """set_claims() returns False when the Admin SDK is unconfigured. The
        older /grant-admin reported that as success:true, which would leave the
        owner signing in and out forever wondering why nothing changed."""
        monkeypatch.setattr(identity_service, "grant_admin", lambda uid: False)
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        r = client.post("/api/admin/bootstrap")
        assert r.status_code == 503
        assert "claim_write_failed" in r.json()["detail"]


class TestBootstrapIsAudited:
    def test_a_successful_bootstrap_writes_one_audit_record(
        self, app, client, fake_db, allowlist
    ):
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        client.post("/api/admin/bootstrap")

        rows = _audit(fake_db)
        assert len(rows) == 1
        row = rows[0]
        assert row["action"] == admin_service.ADMIN_GRANTED
        assert row["adminUid"] == OWNER_UID and row["targetUid"] == OWNER_UID
        assert row["newValue"] == {"admin": True}
        assert row["extra"]["selfBootstrap"] is True
        assert row["reason"]

    def test_a_REFUSED_bootstrap_writes_nothing(self, app, client, fake_db, allowlist):
        _as(app, ATHLETE_UID, email="athlete@x.com")
        client.post("/api/admin/bootstrap")
        assert _audit(fake_db) == []

    def test_an_idempotent_repeat_does_not_add_a_second_record(
        self, app, client, fake_db, allowlist
    ):
        _as(app, OWNER_UID, email=OWNER_EMAIL, is_admin=True)
        client.post("/api/admin/bootstrap")
        assert _audit(fake_db) == []


class TestExistingProtectionUnchanged:
    """require_admin must be exactly as strict as before this feature."""

    PRIVILEGED = [
        ("GET", "/api/admin/dashboard", None),
        ("GET", "/api/admin/audit-logs", None),
        ("GET", "/api/admin/system/health", None),
        ("POST", "/api/admin/certificates/approve", {"certId": "c1"}),
        ("POST", "/api/admin/experts/approve", {"expertId": EXPERT_UID, "approved": True}),
        ("POST", "/api/admin/grant-admin", {"expertId": "x", "approved": True}),
    ]

    @pytest.mark.parametrize("method,path,body", PRIVILEGED)
    def test_unauthenticated_still_401(self, app, client, fake_db, allowlist, method, path, body):
        app.dependency_overrides.clear()
        r = client.get(path) if method == "GET" else client.post(path, json=body)
        assert r.status_code == 401

    @pytest.mark.parametrize("method,path,body", PRIVILEGED)
    def test_an_athlete_still_403(self, app, client, fake_db, allowlist, method, path, body):
        _as(app, ATHLETE_UID, email="athlete@x.com")
        r = client.get(path) if method == "GET" else client.post(path, json=body)
        assert r.status_code == 403

    @pytest.mark.parametrize("method,path,body", PRIVILEGED)
    def test_the_eligible_owner_without_the_claim_still_403(
        self, app, client, fake_db, allowlist, method, path, body
    ):
        # Eligibility is not authorisation, on every single privileged route.
        _as(app, OWNER_UID, email=OWNER_EMAIL)
        r = client.get(path) if method == "GET" else client.post(path, json=body)
        assert r.status_code == 403

    def test_an_existing_admin_by_claim_still_works(self, app, client, fake_db, allowlist):
        _as(app, "some_other_admin", email="ops@zitlas.com", is_admin=True)
        assert client.get("/api/admin/dashboard").status_code == 200
