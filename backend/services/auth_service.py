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
