"""
ZITLAS — Expert access is frozen (backend/tests/test_expert_freeze.py)

BUSINESS RULE: exactly three approved expert accounts exist, they keep their
normal ZITLAS logins, and the application offers no path to create a fourth.

WHAT WAS WRONG — three separate client-side holes, all now closed:
  1. login.js `_addToExpertsStorage()` wrote {role:'expert', approved:true}
     into localStorage at sign-up.
  2. `resolveRole()` read `users/{uid}` — a client-writable document — and
     counted 'expert_pending'/'pending' as EXPERT, so merely applying landed
     you on the expert dashboard.
  3. expert-dashboard.js rendered the whole dashboard with NO Firebase session
     at all when `zitlas_token` and `zitlas_user_role==='expert'` were present
     — two keys any visitor can set from devtools.

Authorisation now requires BOTH the verified `expert` custom claim AND
`experts/{uid}.approved`. Neither is writable from a browser, and the only
code that can grant the claim is identity_service.grant_expert(), reachable
only from routes/admin.py behind require_admin.
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import Depends, FastAPI, HTTPException
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient              # noqa: E402
from services import auth_service                        # noqa: E402
from services.auth_service import verify_firebase_token  # noqa: E402
import routes.auth as auth_routes                        # noqa: E402


#: The three approved accounts, as the data models them.
EXPERT_UIDS = ["expert_uid_1", "expert_uid_2", "expert_uid_3"]

NORMAL_USER = {"uid": "normal_user", "email": "user@example.com",
               "name": "Normal User", "admin": False, "expert": False,
               "email_verified": True}


def expert_caller(uid: str, *, claim: bool = True) -> dict:
    return {"uid": uid, "email": f"{uid}@example.com", "name": "Expert",
            "admin": False, "expert": claim, "email_verified": True}


@pytest.fixture
def db(monkeypatch):
    """Firestore with exactly three approved experts on file."""
    client = FakeClient()
    for uid in EXPERT_UIDS:
        client.collection("experts").document(uid).set(
            {"approved": True, "name": f"Expert {uid}"})
    monkeypatch.setattr(
        "services.firestore_service.get_client", lambda: client)
    return client


def make_app(caller: dict):
    app = FastAPI()
    app.include_router(auth_routes.router, prefix="/api/auth")
    app.dependency_overrides[verify_firebase_token] = lambda: caller
    return TestClient(app)


# ── The three approved experts ───────────────────────────────────────────────

class TestApprovedExperts:
    @pytest.mark.parametrize("uid", EXPERT_UIDS)
    def test_each_approved_expert_resolves_to_expert(self, db, uid):
        assert auth_service.is_expert(expert_caller(uid)) is True
        assert auth_service.resolve_role(expert_caller(uid)) == "expert"

    @pytest.mark.parametrize("uid", EXPERT_UIDS)
    def test_each_approved_expert_lands_on_the_expert_dashboard(self, db, uid):
        body = make_app(expert_caller(uid)).get("/api/auth/role").json()
        assert body["role"] == "expert"
        assert body["isExpert"] is True
        assert body["uid"] == uid


class TestNormalUsers:
    def test_a_normal_user_resolves_to_user(self, db):
        assert auth_service.is_expert(NORMAL_USER) is False
        assert auth_service.resolve_role(NORMAL_USER) == "user"

    def test_a_normal_user_lands_on_the_user_dashboard(self, db):
        body = make_app(NORMAL_USER).get("/api/auth/role").json()
        assert body["role"] == "user"
        assert body["isExpert"] is False

    def test_the_role_endpoint_requires_authentication(self):
        app = FastAPI()
        app.include_router(auth_routes.router, prefix="/api/auth")
        assert TestClient(app).get("/api/auth/role").status_code == 401


# ── Both signals are required ────────────────────────────────────────────────

class TestBothSignalsRequired:
    def test_a_claim_without_an_approval_row_is_refused(self, db):
        """A stale claim on an account with no `experts` row must not pass."""
        assert auth_service.is_expert(expert_caller("no_such_expert")) is False

    def test_an_approval_row_without_the_claim_is_refused(self, db):
        """A hand-written Firestore row cannot mint an expert on its own."""
        caller = expert_caller(EXPERT_UIDS[0], claim=False)
        assert auth_service.is_expert(caller) is False

    def test_an_unapproved_experts_row_is_refused(self, db):
        db.collection("experts").document("applicant").set({"approved": False})
        assert auth_service.is_expert(expert_caller("applicant")) is False

    def test_a_pending_application_is_not_an_expert(self, db):
        """The old client logic accepted 'pending'. Nothing here does."""
        db.collection("experts").document("pending_guy").set(
            {"approved": False, "expert_status": "pending"})
        assert auth_service.is_expert(expert_caller("pending_guy")) is False

    def test_expert_check_fails_closed_when_firestore_is_down(self, monkeypatch):
        monkeypatch.setattr(
            "services.firestore_service.get_client", lambda: None)
        assert auth_service.is_expert(expert_caller(EXPERT_UIDS[0])) is False


# ── The client cannot assert its own role ────────────────────────────────────

class TestClientCannotSelfPromote:
    def test_a_body_supplied_role_is_never_consulted(self, db):
        """resolve_role reads the token and Firestore only."""
        forged = dict(NORMAL_USER)
        forged["role"] = "expert"          # as a client might send
        forged["roles"] = ["expert"]
        forged["expert_status"] = "approved"
        assert auth_service.resolve_role(forged) == "user"

    def test_require_expert_rejects_a_normal_user(self, db):
        app = FastAPI()

        @app.get("/expert-only")
        async def _handler(caller: dict = Depends(auth_service.require_expert)):
            return {"ok": True}

        app.dependency_overrides[verify_firebase_token] = lambda: NORMAL_USER
        res = TestClient(app).get("/expert-only")
        assert res.status_code == 403
        assert res.json()["detail"] == "expert_required"

    def test_require_expert_admits_an_approved_expert(self, db):
        app = FastAPI()

        @app.get("/expert-only")
        async def _handler(caller: dict = Depends(auth_service.require_expert)):
            return {"ok": True, "uid": caller["uid"]}

        app.dependency_overrides[verify_firebase_token] = \
            lambda: expert_caller(EXPERT_UIDS[1])
        res = TestClient(app).get("/expert-only")
        assert res.status_code == 200
        assert res.json()["uid"] == EXPERT_UIDS[1]

    def test_an_expert_cannot_act_as_another_expert(self, db):
        """A supplied expertId must be the caller's own."""
        caller = expert_caller(EXPERT_UIDS[0])
        with pytest.raises(HTTPException) as exc:
            auth_service.assert_owns_expert_id(caller, EXPERT_UIDS[1])
        assert exc.value.status_code == 403
        assert exc.value.detail == "expert_id_mismatch"

    def test_an_expert_may_pass_their_own_id(self, db):
        caller = expert_caller(EXPERT_UIDS[0])
        assert auth_service.assert_owns_expert_id(
            caller, EXPERT_UIDS[0]) == EXPERT_UIDS[0]

    def test_an_omitted_expert_id_falls_back_to_the_verified_uid(self, db):
        caller = expert_caller(EXPERT_UIDS[2])
        assert auth_service.assert_owns_expert_id(caller, None) == EXPERT_UIDS[2]


# ── Onboarding is frozen ─────────────────────────────────────────────────────

class TestOnboardingFrozen:
    def test_the_role_endpoint_reports_onboarding_as_closed(self, db):
        body = make_app(NORMAL_USER).get("/api/auth/role").json()
        assert body["expertOnboardingOpen"] is False

    def test_it_reports_closed_to_experts_too(self, db):
        body = make_app(expert_caller(EXPERT_UIDS[0])).get("/api/auth/role").json()
        assert body["expertOnboardingOpen"] is False

    def test_a_brand_new_account_cannot_become_an_expert(self, db):
        """No `experts` row, no claim — and nothing in the app can create
        either. Only routes/admin.py behind require_admin can."""
        newcomer = {"uid": "brand_new", "email": "new@example.com",
                    "name": "New", "admin": False, "expert": False,
                    "email_verified": True}
        assert auth_service.resolve_role(newcomer) == "user"
        assert auth_service.is_approved_expert("brand_new") is False

    def test_granting_the_claim_is_admin_only(self):
        """The single code path that can mint an expert is reachable only
        from admin routes — asserted structurally so a future endpoint that
        calls it without require_admin shows up here."""
        import inspect

        import routes.admin as admin_routes

        source = inspect.getsource(admin_routes)
        assert "identity_service.grant_expert" in source

        # No other route module may call it.
        import pathlib
        routes_dir = pathlib.Path(admin_routes.__file__).parent
        offenders = []
        for path in routes_dir.glob("*.py"):
            if path.name == "admin.py":
                continue
            if "grant_expert" in path.read_text(encoding="utf-8"):
                offenders.append(path.name)
        assert offenders == [], f"grant_expert called outside admin.py: {offenders}"


# ── Account switching leaves no stale role ───────────────────────────────────

class TestAccountSwitching:
    def test_each_lookup_is_independent_of_the_previous_caller(self, db):
        """Role is derived per request from the token — there is no cached
        role that could survive a logout into the next session."""
        assert auth_service.resolve_role(expert_caller(EXPERT_UIDS[0])) == "expert"
        assert auth_service.resolve_role(NORMAL_USER) == "user"
        assert auth_service.resolve_role(expert_caller(EXPERT_UIDS[1])) == "expert"
        assert auth_service.resolve_role(NORMAL_USER) == "user"

    def test_a_revoked_expert_immediately_resolves_to_user(self, db):
        uid = EXPERT_UIDS[0]
        assert auth_service.is_expert(expert_caller(uid)) is True
        db.collection("experts").document(uid).set({"approved": False})
        assert auth_service.is_expert(expert_caller(uid)) is False
