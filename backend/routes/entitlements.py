"""
ZITLAS — Entitlement routes (backend/routes/entitlements.py)

  GET  /api/entitlements          this athlete's tier, usage and both plans
  POST /api/entitlements/consume  spend one unit of a metered feature

WHY THIS EXISTS: services/entitlements.py already defined the whole matrix —
free 2/70/7, premium 5/unlimited/27 — and its snapshot() docstring even said
"backs GET /api/entitlements". Nothing imported it. The limits were real
configuration that no request path consulted, so every feature was effectively
unmetered.

GET is the ONE source of truth the UI renders from. The comparison table does
not keep its own copy of the numbers, so what a user is shown and what the
server enforces cannot drift apart.

POST exists for GOAL SET/RESET specifically. Meal swaps and recipes each have a
real backend endpoint to gate, but a goal change is written straight to
Firestore by both clients (dashboard_repository.saveGoal on Flutter,
localStorage + cloud-sync on the website) — there is no server call to hang the
check on. Rather than invent a second counter, the clients call this before
committing the change and honour a 429.

THE CLIENT IS NEVER TRUSTED. `uid` comes from the verified Firebase token, the
tier is read from `users/{uid}.membership` server-side, and the count is read
from `usage_weekly` — a request body cannot state its own tier or usage.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from services import entitlements
from services.auth_service import verify_firebase_token

router = APIRouter()

#: Only these may be spent through the generic endpoint. An allowlist, not a
#: free-text feature name: without it a client could invent a feature key and
#: quietly write counters nothing enforces.
CONSUMABLE = {entitlements.GOAL_RESET}


class ConsumeRequest(BaseModel):
    feature: str = Field(..., min_length=1, max_length=40)


@router.get("")
async def my_entitlements(caller: dict = Depends(verify_firebase_token)):
    """Tier, per-feature usage, and BOTH plans' limits and perks.

    Existing premium subscribers need no repurchase for a limit change: the
    tier is derived from `users/{uid}.membership` on every call and the limits
    are read from configuration, so a matrix edit reaches everyone already
    subscribed the moment it deploys.
    """
    return entitlements.snapshot(caller.get("uid") or "")


@router.post("/consume")
async def consume(body: ConsumeRequest,
                  caller: dict = Depends(verify_firebase_token)):
    """Reserve one unit of a metered feature, or 429.

    Records immediately because the "operation" here is the client's own
    Firestore write, which this process cannot observe. That is a deliberate
    trade: a goal change abandoned after a successful reserve costs the athlete
    one unit. Over-counting a goal reset is recoverable; letting an unmetered
    write through is what this endpoint exists to prevent.
    """
    uid = caller.get("uid") or ""
    feature = body.feature.strip()

    if feature not in CONSUMABLE:
        raise HTTPException(
            status_code=400,
            detail={"error": "unknown_feature", "feature": feature,
                    "consumable": sorted(CONSUMABLE)},
        )

    allowance = entitlements.require(uid, feature)   # raises 429 when spent
    entitlements.record(uid, feature)

    after = entitlements.check(uid, feature)
    return {"ok": True, "feature": feature, "allowance": after.as_dict()}
