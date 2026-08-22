"""
ZITLAS — System Routes

GET  /api/system/kb-status   — Knowledge base lazy-loading cache status
GET  /api/system/launch-config — The launch business model (see launch_config.py)
GET  /api/system/trial-mode  — Launch payment policy: CLIENT_TRIAL_MODE
                               (coach payments free) + WALLET_FROZEN
POST /api/system/test-push   — Send a test web-push notification to a token
                               (ADMIN ONLY)
"""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from services.auth_service import require_admin
from services.kb_manager import kb_manager
from services import push_service
import launch_config
import wallet_config
from trial_config import CLIENT_TRIAL_MODE, PLATFORM_CHARGES_FREE

router = APIRouter()


@router.get("/trial-mode")
async def trial_mode() -> dict[str, Any]:
    """
    Single source of truth for the launch payment policy
    (backend/trial_config.py + backend/wallet_config.py). The frontend
    payment layer (assets/js/payment-service.js) reads this at page load:
      - clientTrialMode:     temporary 10-day client trial flag
      - platformChargesFree: PERMANENT monetization policy — all expert
        services free for everyone; only the Premium subscription is paid
      - effectiveFree:       what the frontend actually gates on (either)
      - launchConfig:        the full launch matrix (also served on its own
        at GET /api/system/launch-config)
      - walletFrozen:        the Wallet moves no money this release. Served
        here so the UI and the server cannot disagree about it — the clients
        disable wallet actions from THIS value, never from a local constant,
        and the server refuses the operation regardless of what the client
        believes.
      - walletFrozenMessage: the exact copy both clients show.
    """
    return {
        "clientTrialMode": CLIENT_TRIAL_MODE,
        "platformChargesFree": PLATFORM_CHARGES_FREE,
        "effectiveFree": CLIENT_TRIAL_MODE or PLATFORM_CHARGES_FREE,
        "walletFrozen": wallet_config.WALLET_FROZEN,
        "walletFrozenMessage": wallet_config.WALLET_FROZEN_MESSAGE,
        "launchConfig": launch_config.as_dict(),
    }


@router.get("/launch-config")
async def launch_configuration() -> dict[str, Any]:
    """The ZITLAS launch business model, as the SERVER understands it.

    Premium is the only paid feature; Personal Coaching and expert services
    are free; wallet, expert verification and expert payouts are frozen.

    DISPLAY ONLY. The clients render "FREE" / "Coming Soon" / "Upgrade to
    Premium" from this so their copy cannot drift from what the server
    actually does — but every rule here is separately enforced inside the
    request handlers (backend/launch_config.py's guards). A client that
    ignores this response, or a curl that never reads it, is refused just
    the same.
    """
    return launch_config.as_dict()


@router.get("/kb-status")
async def kb_status() -> dict[str, Any]:
    """
    Knowledge base cache status.

    Shows which per-goal FAISS indexes are currently held in RAM,
    how many chunks each contains, and the LRU cache limit.

    Response shape:
        {
            "loaded_kbs":      ["weight_loss", "general_fitness"],
            "cache_size":      2,
            "memory_optimized": true
        }

    loaded_kbs is empty at startup; it grows as users trigger goal-specific
    requests.  Old entries are evicted (LRU) when cache_size would exceed
    the configured maximum.
    """
    stats = kb_manager.get_cache_stats()
    return {
        "loaded_kbs":      stats["loaded_kbs"],
        "cache_size":      stats["cache_size"],
        "memory_optimized": True,
    }


class TestPushRequest(BaseModel):
    token: str = Field(..., min_length=20, description="FCM device token (frontend: localStorage zitlas_push_token)")
    title: str = Field(default="ZITLAS test notification")
    body:  str = Field(default="If you can read this, web push works end to end. 🎉")


@router.post("/test-push")
async def test_push(
    req: TestPushRequest,
    _admin: dict = Depends(require_admin),
) -> dict[str, Any]:
    """ADMIN ONLY. This endpoint sends a real push with a caller-supplied
    title and body to any device token handed to it — i.e. an arbitrary
    notification that appears to come from ZITLAS. It was unauthenticated and
    live in production; a diagnostic tool is not a reason to leave that open.


    End-to-end push verification: sends one real FCM message to one device
    token. Requires FIREBASE_SERVICE_ACCOUNT_JSON (or _FILE) in the
    environment — returns 503 with setup instructions until it's configured,
    so the endpoint is safe to ship before the credential exists.
    """
    if not push_service.is_configured():
        raise HTTPException(
            status_code=503,
            detail="Push sending is not configured. Set FIREBASE_SERVICE_ACCOUNT_JSON "
                   "(Firebase console -> Project settings -> Service accounts -> "
                   "Generate new private key) in the backend environment.",
        )
    result = push_service.send_to_token(req.token, req.title, req.body,
                                        data={"category": "system", "type": "test"})
    if not result.get("ok"):
        raise HTTPException(status_code=502, detail=result.get("detail"))
    return {"success": True, "detail": result.get("detail")}
