"""
ZITLAS — Expert approval must never half-succeed
(backend/tests/test_expert_approval_atomicity.py)

Expert access requires BOTH `experts/{uid}.approved` AND the Firebase `expert`
custom claim. `identity_service.set_claims()` NEVER RAISES — it returns False
when the firebase-admin app is unavailable — so POST /api/admin/experts/approve
used to answer:

    {"success": true, "approved": true, "claimSet": false}

Firestore said approved, the claim was silently absent, and the account still
resolved to "user". That is exactly how all three ZITLAS experts ended up
unauthorised with nobody noticing: a Firebase Auth export later showed NO
account in the project carried any custom claim at all.

A response that says `success` must mean the account is genuinely authorised.
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient          # noqa: E402
from services import auth_service, firestore_service, identity_service  # noqa: E402
import routes.admin as admin                         # noqa: E402


ADMIN_UID = "admin_1"
EXPERT_UID = "qEX2DhZVWXd2LcBb9rwnSXGVQkx1"   # the real pratik UID


@pytest.fixture
def db(monkeypatch):
    client = FakeClient()
    # An existing expert profile with the fields that must survive untouched.
    client.collection("experts").document(EXPERT_UID).set({
        "uid": EXPERT_UID,
        "name": "pratik",
        "email": "rbicka111@gmail.com",
        "approved": False,
        "rating": 4.8,
        "reviews": 27,
        "dietReviewPrice": 499,
    })
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(admin.firestore_service, "get_client", lambda: client,
                        raising=False)
    return client


@pytest.fixture
def client(db, monkeypatch):
    app = FastAPI()
    app.include_router(admin.router, prefix="/api/admin")
    app.dependency_overrides[admin.verify_firebase_token] = lambda: {
        "uid": ADMIN_UID, "email": "admin@zitlas.com", "name": "Admin",
        "admin": True, "expert": False, "email_verified": True,
    }
    monkeypatch.setattr(auth_service, "_ADMIN_UIDS", {ADMIN_UID}, raising=False)
    return TestClient(app)


def _approve(client, approved=True):
    return client.post("/api/admin/experts/approve",
                       json={"expertId": EXPERT_UID, "approved": approved})


class TestClaimFailureIsNotSuccess:
    def test_a_failed_claim_returns_an_error_not_success(
            self, client, monkeypatch):
        """The exact regression: set_claims returns False, silently."""
        monkeypatch.setattr(identity_service, "grant_expert", lambda uid: False)

        res = _approve(client)

        assert res.status_code == 502, res.text
        body = res.json()["detail"]
        assert body["error"] == "claim_not_set"
        assert body["claimSet"] is False
        assert body["expertId"] == EXPERT_UID

    def test_the_error_names_the_actual_remedy(self, client, monkeypatch):
        monkeypatch.setattr(identity_service, "grant_expert", lambda uid: False)
        detail = _approve(client).json()["detail"]
        assert "FIREBASE_SERVICE_ACCOUNT_JSON" in detail["message"]
        assert "NOT authorised" in detail["message"]

    def test_success_is_never_reported_alongside_claimset_false(
            self, client, monkeypatch):
        """Belt and braces: no 2xx body may ever carry claimSet false."""
        monkeypatch.setattr(identity_service, "grant_expert", lambda uid: False)
        res = _approve(client)
        if 200 <= res.status_code < 300:
            pytest.fail(f"2xx returned for a failed claim: {res.text}")


class TestSuccessPath:
    def test_a_granted_claim_reports_success(self, client, monkeypatch):
        monkeypatch.setattr(identity_service, "grant_expert", lambda uid: True)

        res = _approve(client)

        assert res.status_code == 200
        body = res.json()
        assert body["success"] is True
        assert body["approved"] is True
        assert body["claimSet"] is True

    def test_approval_is_a_merge_that_preserves_the_profile(
            self, client, db, monkeypatch):
        """Ratings, reviews and pricing must survive being approved."""
        monkeypatch.setattr(identity_service, "grant_expert", lambda uid: True)

        _approve(client)

        doc = db.collection("experts").document(EXPERT_UID).get().to_dict()
        assert doc["approved"] is True
        assert doc["rating"] == 4.8
        assert doc["reviews"] == 27
        assert doc["dietReviewPrice"] == 499
        assert doc["name"] == "pratik"
        assert doc["uid"] == EXPERT_UID


class TestRevocation:
    def test_a_failed_revoke_also_refuses_to_report_success(
            self, client, monkeypatch):
        """Revocation has the same trap: reporting success while the claim
        survives would leave a revoked expert still holding access."""
        monkeypatch.setattr(identity_service, "revoke_expert", lambda uid: False)

        res = _approve(client, approved=False)

        assert res.status_code == 502
        assert res.json()["detail"]["error"] == "claim_not_set"

    def test_a_successful_revoke_reports_success(self, client, monkeypatch):
        monkeypatch.setattr(identity_service, "revoke_expert", lambda uid: True)
        res = _approve(client, approved=False)
        assert res.status_code == 200
        assert res.json()["approved"] is False


class TestTheBootstrapScriptTargetsOnlyTheThreeExperts:
    def test_it_carries_exactly_three_uids_each_with_a_cross_check_email(self):
        """A mistyped UID must not be able to authorise the wrong account, so
        every entry pairs the UID with the email it must match."""
        import importlib.util
        import pathlib

        path = (pathlib.Path(__file__).parent.parent / "authorize_experts.py")
        spec = importlib.util.spec_from_file_location("_authz", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        assert len(module.EXPERTS) == 3

        seen = set()
        for spec in module.EXPERTS:
            name, email = spec["name"], spec["email"]
            candidates = spec["uid_candidates"]

            assert name and email
            # Identity is resolved BY EMAIL, so the address is the one thing
            # that must be exact.
            assert "@" in email, f"{name} has no lookup email"
            assert candidates, f"{name} has no UID candidates"

            for uid in candidates:
                # Firebase UIDs are 28 chars; a truncated or mistyped one is
                # how the wrong account gets authorised.
                assert len(uid) == 28, f"{name}: suspicious UID {uid!r}"
                assert uid not in seen, f"UID {uid!r} claimed by two experts"
                seen.add(uid)

    def test_pavan_carries_both_reported_uid_spellings(self):
        """The reported UID differs from Firebase Auth's by ONE character —
        `r1idSpM0Ja` (digit zero) vs `r1idSpMOJa` (capital O), identical in
        most console fonts. Both are probed so a Firestore document stored
        under either spelling is FOUND rather than duplicated."""
        import importlib.util
        import pathlib

        path = (pathlib.Path(__file__).parent.parent / "authorize_experts.py")
        spec_ = importlib.util.spec_from_file_location("_authz2", path)
        module = importlib.util.module_from_spec(spec_)
        spec_.loader.exec_module(module)

        pavan = next(e for e in module.EXPERTS if e["name"] == "Pavan Kumar")
        assert "r1idSpMOJaQM3R6Jny73XPWcnxq1" in pavan["uid_candidates"],             "the Firebase Auth spelling (letter O) must be present"
        assert "r1idSpM0JaQM3R6Jny73XPWcnxq1" in pavan["uid_candidates"],             "the reported spelling (digit 0) must also be probed"
        # Auth's spelling is tried first — it is the authoritative one.
        assert pavan["uid_candidates"][0] == "r1idSpMOJaQM3R6Jny73XPWcnxq1"

    def test_it_never_creates_an_expert_document(self):
        """A missing profile is a data problem to look at, not to fill in."""
        import pathlib
        source = (pathlib.Path(__file__).parent.parent
                  / "authorize_experts.py").read_text(encoding="utf-8")
        assert "will NOT create one" in source
        # The only write to `experts` is a merge onto an existing document.
        assert 'merge=True' in source
        assert source.count('.set({') == 1, "unexpected extra write path"

    def test_it_does_not_apply_by_default(self):
        """The script must be a dry run unless --apply is passed."""
        import pathlib
        source = (pathlib.Path(__file__).parent.parent
                  / "authorize_experts.py").read_text(encoding="utf-8")
        assert 'APPLY = "--apply" in sys.argv' in source
        assert "if not APPLY:" in source
