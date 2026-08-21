"""
ZITLAS — Review Request Routes

POST   /api/review/submit               — User submits diet plan for expert review
GET    /api/review/{request_id}         — Get review request by ID (either party)
GET    /api/review/expert/{expert_id}   — All requests for an expert (expert only)
PATCH  /api/review/{request_id}/status  — Expert updates status (expert only)
POST   /api/review/{request_id}/approve — Expert approves plan (expert only)

AUTHORISATION. Every endpoint here was previously UNAUTHENTICATED — no
`Depends`, no identity check — and each one trusted a client-supplied
`expertId`. `PATCH /status` would even reassign a request's `expertId` to
whatever the body said, so any caller could take over somebody else's review.

Now:
  * the two user-facing endpoints require a signed-in caller and bind the
    record to the VERIFIED uid;
  * the three expert-only endpoints require `require_expert` — i.e. the
    verified `expert` custom claim AND `experts/{uid}.approved` — and ignore
    any expertId in the request in favour of the authenticated one.

NOTE ON SCOPE: `_store` is in-memory. The live Expert Review flow writes
Firestore `review_requests` directly from the clients, so this module is a
parallel/legacy surface. It is secured anyway — an unauthenticated write path
is worth closing whether or not the product currently drives it.
"""

from datetime import datetime, timezone
from typing import Any, Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from services import auth_service
from services.auth_service import require_expert, verify_firebase_token

router = APIRouter()

# In-memory store (matches localStorage-first architecture)
_store: dict[str, dict] = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


# ── Pydantic models ──────────────────────────────────────────────────────────

class ReviewSubmitRequest(BaseModel):
    id:           str
    athleteId:    Optional[str] = None
    # Field NAME retained (existing data contract); only the human-readable
    # default changes — ZITLAS says "User" now, never "User".
    athlete_name: Optional[str] = "User"
    expertId:     str
    status:       Optional[str] = "pending"
    submittedAt:  Optional[str] = None
    context:      Optional[Any] = None   # {assessment, calculations, swot, diet_plan, workout_plan}
    goal:         Optional[Any] = None
    planId:       Optional[str] = None
    fee:          Optional[int] = None
    note:         Optional[str] = None


class StatusUpdate(BaseModel):
    status:    str
    expertId:  Optional[str] = None


class ApproveRequest(BaseModel):
    expertId:        str
    expertName:      str
    status:          str = "approved"   # "approved" | "revised_plan_published"
    expertNotes:     Optional[str] = None
    updatedDietPlan: Optional[Any] = None
    approvedAt:      Optional[str] = None


# ── Routes ───────────────────────────────────────────────────────────────────

@router.post("/submit")
async def submit_review(body: ReviewSubmitRequest,
                        caller: dict = Depends(verify_firebase_token)):
    """A user submits their AI diet plan for expert review.

    USER-FACING BY DESIGN — normal users are exactly who submits here, so
    `require_expert` would be wrong. It does require a signed-in caller, and
    the record is bound to the verified uid rather than to whatever
    `athleteId` the body claimed.
    """
    req = body.dict()
    # Field name kept for the existing data contract; the VALUE is now the
    # authenticated uid, so a request cannot be filed under someone else.
    req["athleteId"]   = caller.get("uid")
    req["submittedAt"] = req.get("submittedAt") or _now()
    req["status"]      = "pending"
    _store[body.id]    = req
    return {
        "success":   True,
        "requestId": body.id,
        "status":    "pending",
    }


@router.get("/expert/{expert_id}")
async def get_expert_reviews(expert_id: str,
                             caller: dict = Depends(require_expert)):
    """Every review request assigned to an expert. EXPERT ONLY.

    The path `expert_id` must be the caller's own — otherwise one approved
    expert could read a colleague's entire queue, including the plans and
    assessments of users who never engaged them.
    """
    expert_id = auth_service.assert_owns_expert_id(caller, expert_id)
    requests = [
        r for r in _store.values()
        if r.get("expertId") == expert_id
    ]
    requests.sort(key=lambda r: r.get("submittedAt", ""), reverse=True)
    return {"success": True, "expertId": expert_id, "requests": requests, "count": len(requests)}


@router.get("/{request_id}")
async def get_review(request_id: str,
                     caller: dict = Depends(verify_firebase_token)):
    """One review request. Readable by EITHER party to it.

    Deliberately not expert-only: the user who submitted the plan needs to
    read their own request. Anyone else gets 404 rather than 403, so the
    endpoint cannot be used to discover which request ids exist.
    """
    req = _store.get(request_id)
    if not req:
        raise HTTPException(status_code=404, detail="Review request not found.")

    uid = caller.get("uid")
    if uid not in (req.get("athleteId"), req.get("expertId")):
        raise HTTPException(status_code=404, detail="Review request not found.")
    return req


@router.patch("/{request_id}/status")
async def update_status(request_id: str, body: StatusUpdate,
                        caller: dict = Depends(require_expert)):
    """Expert moves a review along (pending -> expert_reviewing). EXPERT ONLY.

    The body's `expertId` is IGNORED. It used to be written straight onto the
    record, which let any caller reassign somebody else's review to
    themselves — a takeover, not an update. Only the expert the request is
    already assigned to may change it.
    """
    req = _store.get(request_id)
    if not req:
        raise HTTPException(status_code=404, detail="Review request not found.")

    uid = caller.get("uid")
    if req.get("expertId") and req["expertId"] != uid:
        raise HTTPException(status_code=403, detail="not_your_review")

    req["status"]    = body.status
    req["updatedAt"] = _now()
    req["expertId"]  = uid          # the verified expert, never the body's
    return {"success": True, "requestId": request_id, "status": body.status}


@router.post("/{request_id}/approve")
async def approve_review(request_id: str, body: ApproveRequest,
                         caller: dict = Depends(require_expert)):
    """Expert approves the plan, optionally with edits. EXPERT ONLY.

    Publishing a revised plan changes what the user eats, so it is gated on
    the verified expert identity and on the request actually being theirs.
    """
    req = _store.get(request_id)
    if not req:
        raise HTTPException(status_code=404, detail="Review request not found.")

    uid = auth_service.assert_owns_expert_id(caller, body.expertId)
    if req.get("expertId") and req["expertId"] != uid:
        raise HTTPException(status_code=403, detail="not_your_review")

    req["status"]      = body.status
    req["expertId"]    = uid
    req["expertName"]  = body.expertName
    req["expertNotes"] = body.expertNotes
    req["approvedAt"]  = body.approvedAt or _now()
    req["updatedAt"]   = _now()
    if body.updatedDietPlan:
        req["updatedDietPlan"] = body.updatedDietPlan

    return {
        "success":   True,
        "requestId": request_id,
        "status":    body.status,
        "message":   f"Plan {body.status} by {body.expertName}",
    }
