"""
ZITLAS — Firebase ID token verification (backend/services/auth_service.py)

FastAPI dependency for routes that must know WHO the caller actually is,
server-side — the coaching escrow endpoints (routes/coaching.py) are the
first routes in this backend that need this; every existing route is
unauthenticated compute (see main.py, no Authorization handling anywhere
else). A reservation/accept/reject call that trusted a client-supplied
userId could be spoofed to reserve or release someone else's money.

Uses google.oauth2.id_token.verify_firebase_token — stateless verification
against Firebase's public JWKs, no service-account credential needed for
this part (unlike firestore_service.py). Consistent with this codebase's
existing preference for google-auth over the heavier firebase-admin
package (see push_service.py).
"""

from __future__ import annotations

import time

import os

import google.auth.transport.requests
from fastapi import Depends, Header, HTTPException
from google.oauth2 import id_token

_PROJECT_ID = "zitlas-b8677"
_request = google.auth.transport.requests.Request()

# Bootstrap admins. Custom claims (request.auth.token.admin) are the primary
# admin signal once set via identity_service, but there's a chicken-and-egg at
# first setup — nobody can grant the first admin claim without already being
# admin. This env allowlist (comma-separated Firebase UIDs) breaks that cycle:
# any uid listed here is treated as admin server-side regardless of claims, so
# the very first certificate approval / claim grant can be performed. Leave it
# set for your ops accounts; it is checked ONLY server-side (never trusted from
# the client) and is independent of the client-writable users/{uid}.role field.
_ADMIN_UIDS = {
    u.strip() for u in (os.getenv("ZITLAS_ADMIN_UIDS") or "").split(",") if u.strip()
}

# Bootstrap EMAIL allowlist — comma-separated, case-normalised.
#
# Deliberately NOT an admin grant. Being on this list does not make anyone an
# admin and is never consulted by `is_admin()` / `require_admin`; it only makes
# an account ELIGIBLE to bootstrap itself once, via
# POST /api/admin/bootstrap, which then writes the real `admin` custom claim.
#
# Keeping the two separate matters: an email is a routable, guessable, and
# (via provider changes) mutable identifier, so treating it as a standing
# authorisation would mean every /api/admin request trusted whatever address
# the identity provider happened to attach to the token. The claim is the
# authorisation; this list is only a one-time door to obtaining it.
_ADMIN_EMAILS = {
    e.strip().lower() for e in (os.getenv("ZITLAS_ADMIN_EMAILS") or "").split(",") if e.strip()
}


async def verify_firebase_token(authorization: str | None = Header(default=None)) -> dict:
    """Raises 401 on a missing/invalid/expired token. On success returns
    {"uid", "email", "name", "admin", "expert"} — the last two read from
    custom claims baked into the verified token (never client-forgeable)."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing_token")

    token = authorization[len("Bearer "):].strip()
    if not token:
        raise HTTPException(status_code=401, detail="missing_token")

    try:
        claims = id_token.verify_firebase_token(token, _request, audience=_PROJECT_ID)
    except Exception as e:
        print(f"[AUTH] token verification failed: {type(e).__name__}: {e}")
        raise HTTPException(status_code=401, detail="invalid_token")

    if not claims or not claims.get("sub"):
        print(f"[AUTH] token verified but missing 'sub' claim — claims keys={list((claims or {}).keys())}")
        raise HTTPException(status_code=401, detail="invalid_token")

    uid = claims["sub"]
    print(f"[AUTH] token verified OK — uid={uid}")
    return {
        "uid": uid,
        "email": claims.get("email"),
        # Straight from the verified token, never from a client-sent profile.
        "email_verified": bool(claims.get("email_verified")),
        "name": claims.get("name"),
        # Custom claims (may be absent → default False). Admin is also granted
        # via the bootstrap env allowlist above.
        "admin": bool(claims.get("admin")) or (uid in _ADMIN_UIDS),
        "expert": bool(claims.get("expert")),
    }


def is_admin(caller: dict) -> bool:
    """The ONLY authorisation signal. Reads the verified `admin` custom claim
    (or the ZITLAS_ADMIN_UIDS bootstrap allowlist). Deliberately does NOT
    consult ZITLAS_ADMIN_EMAILS — see that constant."""
    return bool(caller.get("admin"))


def is_bootstrap_email(caller: dict) -> bool:
    """Whether this VERIFIED caller may bootstrap themselves to admin.

    Requires all three of:
      * a non-empty email on the verified ID token,
      * an exact case-normalised match against ZITLAS_ADMIN_EMAILS,
      * Firebase having verified that email.

    The email comes from the cryptographically verified token, never from a
    request body, header, query parameter or browser profile field. An empty
    allowlist means nobody is eligible — the feature is off by default rather
    than open by default.
    """
    if not _ADMIN_EMAILS:
        return False
    email = (caller.get("email") or "").strip().lower()
    if not email or email not in _ADMIN_EMAILS:
        return False
    # A Google-federated sign-in always carries email_verified=true; requiring
    # it stops an unverified password account registered at the same address
    # from qualifying.
    return bool(caller.get("email_verified"))


async def require_admin(caller: dict = Depends(verify_firebase_token)) -> dict:
    """FastAPI dependency: 401 if unauthenticated, 403 if the caller is not an
    admin (by custom claim or ZITLAS_ADMIN_UIDS allowlist). Use on privileged
    routes (certificate/expert approval)."""
    if not is_admin(caller):
        print(f"[AUTH] admin-only route denied for uid={caller.get('uid')}")
        raise HTTPException(status_code=403, detail="admin_required")
    return caller


# ── Expert authorisation ─────────────────────────────────────────────────────
#
# EXPERT ONBOARDING IS FROZEN. There are exactly three approved expert
# accounts and the application offers no path to create a fourth: the only
# code that can grant the claim is identity_service.grant_expert(), reachable
# only from routes/admin.py behind require_admin.
#
# Two independent signals must BOTH hold, so neither alone can be forged:
#   1. the `expert` custom claim on the verified Firebase ID token, and
#   2. `experts/{uid}.approved == true` in Firestore.
# A stale claim on a revoked account fails (2); a hand-written Firestore row
# without a claim fails (1). The client is asked for neither — both are read
# server-side from the authenticated uid.

_EXPERT_LOOKUP_ATTEMPTS = 3
_EXPERT_LOOKUP_BACKOFF = [0.25, 0.75]


def is_approved_expert(uid: str) -> bool | None:
    """Whether `experts/{uid}` exists and is approved.

    THREE OUTCOMES, and the third one matters:
        True  — the document says approved.
        False — the document says otherwise, or does not exist. A VERDICT.
        None  — the question could not be ASKED (Firestore unreachable, a
                misconfigured client, a transport fault). NOT a verdict.

    This used to return False for all three. That is safe for authorization —
    and `is_expert()` still treats None as "no access" — but it made an
    INFRASTRUCTURE FAULT indistinguishable from "this person is not an
    expert", so `/api/auth/role` answered a confident "user" for genuinely
    approved experts and the apps landed them in the athlete experience.
    That is exactly the reported failure: the deployed backend logged
    `InvalidArgument: 400 Invalid database id %28default%29` from this very
    lookup, swallowed it here, and reported
    `token_expert_claim=True firestore_approved=False -> user`.

    Callers that decide a LANDING SCREEN must treat None as "cannot answer"
    and say so, rather than guessing. Callers that gate ACCESS keep failing
    closed.
    """
    if not uid:
        return False
    from services import firestore_service

    db = firestore_service.get_client()
    if db is None:
        print("[AUTH] expert check: Firestore client unavailable — CANNOT DETERMINE")
        return None

    # A transient read fault should not cost an expert their dashboard.
    last: Exception | None = None
    for attempt in range(_EXPERT_LOOKUP_ATTEMPTS):
        try:
            snap = db.collection("experts").document(uid).get()
            if not snap or not getattr(snap, "exists", False):
                return False
            return bool((snap.to_dict() or {}).get("approved"))
        except Exception as e:  # noqa: BLE001 — see docstring
            last = e
            print(f"[AUTH] expert lookup attempt {attempt + 1}/"
                  f"{_EXPERT_LOOKUP_ATTEMPTS} failed for {uid}: "
                  f"{type(e).__name__}: {e}")
            if attempt + 1 < _EXPERT_LOOKUP_ATTEMPTS:
                time.sleep(_EXPERT_LOOKUP_BACKOFF[attempt])

    print(f"[AUTH] expert lookup UNAVAILABLE for {uid} after "
          f"{_EXPERT_LOOKUP_ATTEMPTS} attempts — reporting 'cannot determine', "
          f"NOT 'not an expert'. Last error: {type(last).__name__}: {last}")
    return None


def is_expert(caller: dict) -> bool:
    """Claim AND approval row. Never a client-supplied role.

    FAILS CLOSED on None: an unanswerable approval check grants nothing.
    Routing callers should use [expert_status] instead so they can tell
    "not an expert" from "could not check".
    """
    if not bool(caller.get("expert")):
        return False
    return is_approved_expert(caller.get("uid") or "") is True


def expert_status(caller: dict) -> bool | None:
    """Tri-state for callers that pick a LANDING SCREEN.

    True = expert, False = not an expert, None = could not determine.
    """
    if not bool(caller.get("expert")):
        return False
    return is_approved_expert(caller.get("uid") or "")


def resolve_role(caller: dict) -> str:
    """The role the app should land this account on: 'expert' or 'user'.

    Admin is deliberately NOT a landing role — an admin who is not also an
    approved expert is a normal user in the app and reaches the admin portal
    by its own route.
    """
    return "expert" if is_expert(caller) else "user"


async def require_expert(caller: dict = Depends(verify_firebase_token)) -> dict:
    """FastAPI dependency for expert-only routes. 401 unauthenticated,
    403 for everybody who is not one of the approved experts."""
    if not is_expert(caller):
        print(f"[AUTH] expert-only route denied for uid={caller.get('uid')}")
        raise HTTPException(status_code=403, detail="expert_required")
    return caller


def assert_owns_expert_id(caller: dict, expert_id: str | None) -> str:
    """A client-supplied expertId must be the caller's own.

    Expert endpoints take an expertId in the body or path; without this an
    approved expert could pass a COLLEAGUE's id and act as them. Returns the
    verified uid so callers can use it instead of the supplied value.
    """
    uid = caller.get("uid") or ""
    if expert_id and expert_id != uid:
        print(f"[AUTH] expertId mismatch: caller={uid} claimed={expert_id}")
        raise HTTPException(status_code=403, detail="expert_id_mismatch")
    return uid
