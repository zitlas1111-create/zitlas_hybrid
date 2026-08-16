"""
ZITLAS — Admin Portal Phase 1 (backend/tests/test_admin_portal.py)

Two things are pinned here, in order of importance.

1. THE AUTHORIZATION BOUNDARY. Every admin endpoint must reject an
   unauthenticated caller with 401 and any authenticated NON-admin — athlete
   or expert — with 403. The frontend claim check is UX only; this is the
   actual security boundary, so it is tested per-endpoint rather than once.

2. THE AUDIT TRAIL. Privileged mutations already existed behind
   `require_admin` (certificate approve/reject, expert approve, expert
   deactivate, admin grant) and recorded NOTHING — there was no way to answer
   "who revoked this expert" after the fact. Each one must now append exactly
   one audit record naming the acting admin, the target, and the change.

Run: python -m pytest tests/test_admin_portal.py -q
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from routes import admin  # noqa: E402
from services import admin_service, firestore_service, identity_service  # noqa: E402
from tests.fake_firestore import FakeClient  # noqa: E402

ADMIN_UID = "admin_1"
ATHLETE_UID = "athlete_1"
EXPERT_UID = "expert_1"


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore_service, "config_error", lambda: None, raising=False)
    # Custom-claim writes need the Auth Admin SDK, which no test has.
    monkeypatch.setattr(identity_service, "grant_expert", lambda uid: True)
    monkeypatch.setattr(identity_service, "revoke_expert", lambda uid: True)
    monkeypatch.setattr(identity_service, "grant_admin", lambda uid: True)
    monkeypatch.setattr(identity_service, "revoke_admin", lambda uid: True, raising=False)
    return client


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(admin.router, prefix="/api/admin")
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid, *, is_admin=False, is_expert=False):
    """Authenticate subsequent requests as `uid`.

    Overrides the token dependency itself — the real one cryptographically
    verifies a Firebase ID token, which cannot be minted in a unit test. The
    `admin` flag here stands in for a verified custom claim.
    """
    app.dependency_overrides[admin.verify_firebase_token] = lambda: {
        "uid": uid, "email": f"{uid}@x.com", "name": uid,
        "admin": is_admin, "expert": is_expert,
    }
    # require_admin depends on verify_firebase_token, so overriding the latter
    # is enough — require_admin still performs its own real check.


def _audit(fake_db):
    return [d for p, d in fake_db.store.items()
            if p.startswith(f"{admin_service.AUDIT_COLLECTION}/")]


# Every endpoint, with a minimal valid body. Kept as data so a newly added
# endpoint that forgets authorization shows up as a missing entry here.
ENDPOINTS = [
    ("GET", "/api/admin/dashboard", None),
    ("GET", "/api/admin/audit-logs", None),
    ("GET", "/api/admin/system/health", None),
    ("POST", "/api/admin/certificates/approve", {"certId": "c1"}),
    ("POST", "/api/admin/certificates/reject", {"certId": "c1", "reason": "blurry"}),
    ("POST", "/api/admin/experts/approve", {"expertId": EXPERT_UID, "approved": True}),
    ("POST", "/api/admin/experts/recompute-verification", {"expertId": EXPERT_UID}),
    ("POST", "/api/admin/grant-admin", {"expertId": "someone", "approved": True}),
]


def _call(client, method, path, body):
    return client.get(path) if method == "GET" else client.post(path, json=body)


class TestAuthorizationBoundary:
    @pytest.mark.parametrize("method,path,body", ENDPOINTS)
    def test_unauthenticated_is_rejected(self, app, client, fake_db, method, path, body):
        # No dependency override at all -> the real token check runs and finds
        # no Authorization header.
        app.dependency_overrides.clear()
        assert _call(client, method, path, body).status_code == 401

    @pytest.mark.parametrize("method,path,body", ENDPOINTS)
    def test_an_athlete_gets_403(self, app, client, fake_db, method, path, body):
        _as(app, ATHLETE_UID)
        assert _call(client, method, path, body).status_code == 403

    @pytest.mark.parametrize("method,path,body", ENDPOINTS)
    def test_an_expert_gets_403(self, app, client, fake_db, method, path, body):
        _as(app, EXPERT_UID, is_expert=True)
        assert _call(client, method, path, body).status_code == 403

    def test_the_admin_claim_is_what_grants_access(self, app, client, fake_db):
        _as(app, ATHLETE_UID)
        assert client.get("/api/admin/dashboard").status_code == 403
        # Same uid, same everything, only the verified claim differs.
        _as(app, ATHLETE_UID, is_admin=True)
        assert client.get("/api/admin/dashboard").status_code == 200

    def test_a_client_supplied_admin_flag_cannot_grant_access(self, app, client, fake_db):
        # Body/query/header "admin=true" must be inert: authorization comes
        # only from the verified token.
        _as(app, ATHLETE_UID)
        assert client.get("/api/admin/dashboard?admin=true").status_code == 403
        assert client.get("/api/admin/dashboard", headers={"X-Admin": "true"}).status_code == 403
        r = client.post("/api/admin/grant-admin",
                        json={"expertId": ATHLETE_UID, "approved": True, "admin": True})
        assert r.status_code == 403

    def test_expert_deactivate_allows_self_service_but_not_a_stranger(self, app, client, fake_db):
        """The one endpoint that is intentionally not admin-only: an expert may
        offboard THEMSELVES. It must still refuse to touch anyone else."""
        fake_db.store[f"experts/{EXPERT_UID}"] = {"name": "Coach"}
        _as(app, EXPERT_UID, is_expert=True)
        assert client.post("/api/admin/experts/deactivate",
                           json={"expertId": EXPERT_UID}).status_code == 200

        _as(app, ATHLETE_UID)
        assert client.post("/api/admin/experts/deactivate",
                           json={"expertId": EXPERT_UID}).status_code == 403


class TestAuditTrail:
    def test_expert_approval_is_audited(self, app, client, fake_db):
        _as(app, ADMIN_UID, is_admin=True)
        assert client.post("/api/admin/experts/approve",
                           json={"expertId": EXPERT_UID, "approved": True}).status_code == 200

        rows = _audit(fake_db)
        assert len(rows) == 1
        row = rows[0]
        assert row["action"] == admin_service.EXPERT_APPROVED
        assert row["adminUid"] == ADMIN_UID
        assert row["targetUid"] == EXPERT_UID
        assert row["newValue"] == {"approved": True}
        assert row["timestamp"]
        assert row["requestId"]

    def test_expert_rejection_records_the_opposite_action(self, app, client, fake_db):
        _as(app, ADMIN_UID, is_admin=True)
        client.post("/api/admin/experts/approve",
                    json={"expertId": EXPERT_UID, "approved": False})
        assert _audit(fake_db)[0]["action"] == admin_service.EXPERT_REJECTED

    def test_granting_and_revoking_admin_are_distinct_actions(self, app, client, fake_db):
        _as(app, ADMIN_UID, is_admin=True)
        client.post("/api/admin/grant-admin", json={"expertId": "newbie", "approved": True})
        client.post("/api/admin/grant-admin", json={"expertId": "newbie", "approved": False})

        actions = {r["action"] for r in _audit(fake_db)}
        assert actions == {admin_service.ADMIN_GRANTED, admin_service.ADMIN_REVOKED}

    def test_certificate_approval_is_audited_with_the_prior_status(self, app, client, fake_db):
        fake_db.store["expert_certificates/c1"] = {
            "expertId": EXPERT_UID, "verificationStatus": "pending_review",
        }
        _as(app, ADMIN_UID, is_admin=True)
        assert client.post("/api/admin/certificates/approve",
                           json={"certId": "c1"}).status_code == 200

        row = _audit(fake_db)[0]
        assert row["action"] == admin_service.CERT_APPROVED
        # The old value is what makes the trail reconstructible.
        assert row["oldValue"] == {"verificationStatus": "pending_review"}
        assert row["extra"]["certId"] == "c1"

    def test_certificate_rejection_records_the_reason(self, app, client, fake_db):
        fake_db.store["expert_certificates/c1"] = {
            "expertId": EXPERT_UID, "verificationStatus": "pending_review",
        }
        _as(app, ADMIN_UID, is_admin=True)
        client.post("/api/admin/certificates/reject",
                    json={"certId": "c1", "reason": "document is not a certificate"})

        row = _audit(fake_db)[0]
        assert row["action"] == admin_service.CERT_REJECTED
        assert row["reason"] == "document is not a certificate"

    def test_rejection_without_a_reason_is_refused_and_not_audited(self, app, client, fake_db):
        fake_db.store["expert_certificates/c1"] = {"expertId": EXPERT_UID}
        _as(app, ADMIN_UID, is_admin=True)
        assert client.post("/api/admin/certificates/reject",
                           json={"certId": "c1"}).status_code == 400
        assert _audit(fake_db) == []

    def test_expert_deactivation_is_audited_and_flags_self_service(self, app, client, fake_db):
        fake_db.store[f"experts/{EXPERT_UID}"] = {"name": "Coach"}
        fake_db.store[f"users/{EXPERT_UID}"] = {"roles": ["athlete", "expert"]}
        _as(app, ADMIN_UID, is_admin=True)
        client.post("/api/admin/experts/deactivate", json={"expertId": EXPERT_UID})

        row = _audit(fake_db)[0]
        assert row["action"] == admin_service.EXPERT_DEACTIVATED
        assert row["extra"]["selfService"] is False

    def test_a_failed_action_leaves_no_audit_row(self, app, client, fake_db):
        # A 404 is not an event worth recording; only real changes are.
        _as(app, ADMIN_UID, is_admin=True)
        assert client.post("/api/admin/certificates/approve",
                           json={"certId": "missing"}).status_code == 404
        assert _audit(fake_db) == []

    def test_a_rejected_non_admin_call_leaves_no_audit_row(self, app, client, fake_db):
        _as(app, ATHLETE_UID)
        client.post("/api/admin/experts/approve",
                    json={"expertId": EXPERT_UID, "approved": True})
        assert _audit(fake_db) == []

    def test_the_audit_endpoint_returns_what_was_written(self, app, client, fake_db):
        _as(app, ADMIN_UID, is_admin=True)
        client.post("/api/admin/experts/approve",
                    json={"expertId": EXPERT_UID, "approved": True})

        body = client.get("/api/admin/audit-logs").json()
        assert body["total"] == 1
        assert body["items"][0]["action"] == admin_service.EXPERT_APPROVED

    def test_the_audit_endpoint_has_no_write_counterpart(self):
        """Append-only by construction: no route may mutate the trail."""
        paths = [(r.path, sorted(r.methods)) for r in admin.router.routes]
        for path, methods in paths:
            if "audit" in path:
                assert methods == ["GET"], f"{path} exposes {methods}"


class TestDashboardAndHealth:
    def test_dashboard_reports_counts_and_the_environment(self, app, client, fake_db):
        fake_db.store["users/u1"] = {"role": "athlete"}
        fake_db.store["users/u2"] = {"role": "athlete"}
        fake_db.store[f"experts/{EXPERT_UID}"] = {"verified": True, "approved": True}
        _as(app, ADMIN_UID, is_admin=True)

        body = client.get("/api/admin/dashboard").json()
        assert body["users"]["total"] == 2
        assert body["experts"]["total"] == 1
        # Defaults to PRODUCTION so an unlabelled deployment is never mistaken
        # for a scratch environment.
        assert body["environment"] == "PRODUCTION"
        assert body["generatedAt"]

    def test_health_reports_provider_configuration_without_leaking_keys(
        self, app, client, fake_db, monkeypatch
    ):
        monkeypatch.setenv("GROQ_API_KEY", "sk-super-secret-value")
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        _as(app, ADMIN_UID, is_admin=True)

        raw = client.get("/api/admin/system/health").text
        body = client.get("/api/admin/system/health").json()

        assert body["components"]["aiProviders"]["configured"]["groq"] is True
        assert body["components"]["aiProviders"]["configured"]["gemini"] is False
        # The response says CONFIGURED, never what the key is — not the value,
        # not a prefix, not its length.
        assert "sk-super-secret" not in raw
        assert "super" not in raw

    def test_health_degrades_rather_than_500s(self, app, client, monkeypatch):
        monkeypatch.setattr(firestore_service, "get_client", lambda: None)
        monkeypatch.setattr(firestore_service, "config_error", lambda: "no credentials", raising=False)
        _as(app, ADMIN_UID, is_admin=True)

        body = client.get("/api/admin/system/health").json()
        assert body["components"]["firestore"]["status"] == "DOWN"
        # A short reason, never a stack trace.
        assert body["components"]["firestore"]["detail"] == "no credentials"


class TestPaginationHelpers:
    def test_page_size_is_clamped(self):
        assert admin_service.clamp_page_size(10_000) == admin_service.MAX_PAGE_SIZE
        assert admin_service.clamp_page_size(0) == 20
        assert admin_service.clamp_page_size(None) == 20
        assert admin_service.clamp_page_size("abc") == 20
        assert admin_service.clamp_page_size(50) == 50

    def test_paginate_reports_totals_and_slices(self):
        page = admin_service.paginate(list(range(45)), page=2, page_size=20)
        assert page["items"] == list(range(20, 40))
        assert (page["total"], page["totalPages"], page["page"]) == (45, 3, 2)

    def test_paginate_clamps_an_out_of_range_page(self):
        page = admin_service.paginate(list(range(5)), page=99, page_size=20)
        assert page["page"] == 1 and page["items"] == list(range(5))

    def test_paginate_handles_an_empty_collection(self):
        page = admin_service.paginate([], page=1, page_size=20)
        assert page["items"] == [] and page["total"] == 0 and page["totalPages"] == 1

    def test_redact_strips_credentials_but_keeps_admin_relevant_fields(self):
        out = admin_service.redact({
            "name": "Real User", "email": "a@b.com", "accountStatus": "active",
            "fcmToken": "tok", "passwordHash": "x", "razorpaySignature": "sig",
            "privateKey": "k",
        })
        assert out == {"name": "Real User", "email": "a@b.com", "accountStatus": "active"}

    def test_search_matches_across_fields_case_insensitively(self):
        assert admin_service.matches_search(("Atharva", "a@b.com"), "ATHAR")
        assert admin_service.matches_search(("Atharva", "a@b.com"), "b.com")
        assert not admin_service.matches_search(("Atharva", "a@b.com"), "zzz")
        # An empty query matches everything rather than nothing.
        assert admin_service.matches_search(("x",), None)
        assert admin_service.matches_search(("x",), "  ")
