"""
ZITLAS — Auth Routes

Endpoints:
  GET  /api/auth/health        Liveness probe
  GET  /api/auth/role          The role this account lands on — the ONLY
                               authority for expert-vs-user routing.
  POST /api/auth/webview-token Mint a Firebase custom token for the embedded
                               Personal Coaching WebView (auth bridge).

Future endpoints:
  POST /api/auth/register    Register a new player
  POST /api/auth/login       Login and return JWT token
  POST /api/auth/logout      Invalidate session
  GET  /api/auth/me          Return current user profile
  POST /api/auth/refresh     Refresh access token
"""

from fastapi import APIRouter, Depends, HTTPException

from services import auth_service, identity_service
from services.auth_service import verify_firebase_token

router = APIRouter()


@router.get("/health")
async def auth_health():
    return {"module": "auth", "status": "ready"}


@router.get("/role")
async def my_role(caller: dict = Depends(verify_firebase_token)):
    """Where this account belongs: the expert dashboard, or the user one.

    THE CLIENT MUST NOT DECIDE THIS. Before this endpoint existed the website
    kept the answer in `localStorage.zitlas_user_role`, and
    expert-dashboard.js set that key to 'expert' itself — so anybody who
    could open devtools was an expert. The role is now derived from the
    verified token's claim AND `experts/{uid}.approved`, neither of which the
    browser can write.

    `expertOnboardingOpen` is reported so the UI never has to hard-code the
    freeze: when onboarding reopens, the entry points come back on their own.
    """
    uid = caller.get("uid") or ""
    claim = bool(caller.get("expert"))
    approved = auth_service.is_approved_expert(uid) if claim else None
    role = auth_service.resolve_role(caller)

    # Both halves, every time. When this answers "user" for somebody who
    # should be an expert, the log says WHICH half failed instead of leaving
    # it to be guessed — a missing claim means a stale ID token (the client
    # must call getIdToken(true)), while claim-true/approved-false means the
    # Firestore document is not approved.
    print(f"[AUTH] role uid={uid} email={caller.get('email')} "
          f"token_expert_claim={claim} "
          f"firestore_approved={approved if claim else '(not checked - no claim)'} "
          f"-> {role}")
    if role != "expert":
        reason = ("token carries no `expert` claim — the ID token predates the "
                  "claim being granted; the client must force-refresh it"
                  if not claim else
                  "claim present but experts/{uid}.approved is not true")
        print(f"[AUTH] not expert because: {reason}")

    return {
        "uid": caller.get("uid"),
        "role": role,
        "isExpert": role == "expert",
        "isAdmin": auth_service.is_admin(caller),
        # Frozen: exactly three approved experts, and the application offers
        # no path to create a fourth.
        "expertOnboardingOpen": False,
    }


@router.post("/webview-token")
async def webview_token(caller: dict = Depends(verify_firebase_token)):
    """Exchange the caller's verified Firebase ID token for a short-lived
    custom token, used ONLY to sign the Personal Coaching WebView into the same
    Firebase account the native app is already signed into (see
    identity_service.create_custom_token for the full rationale).

    The caller identity comes entirely from the verified Bearer token — the
    minted token is always for the CALLER's own uid, never a client-supplied
    one, so this cannot be used to impersonate another user."""
    uid = caller["uid"]
    token = identity_service.create_custom_token(uid)
    if not token:
        # Admin credentials unconfigured or minting failed — the WebView cannot
        # authenticate without this, so fail loudly rather than returning null.
        raise HTTPException(status_code=503, detail="custom_token_unavailable")
    return {"customToken": token, "uid": uid}
