"""
ZITLAS — Server-authoritative "apply reviewed plan" (backend/routes/review_apply.py)

POST /api/review/apply

When an expert completes a diet/workout review, the reviewed plan becomes the
athlete's ACTIVE plan by writing users/{athleteUid}.dietPlan / .workoutPlan.
That is a CROSS-USER write (expert's device → user's users doc), which
production Security Rules correctly deny (users writes are owner-only —
FIRESTORE_SECURITY_AUDIT.md). The old client code did it directly
(modify-diet.js / modify-workout.js) and would now fail closed.

This endpoint performs that one write via the Admin SDK after verifying, from
TRUSTED server-side data, that:
  * the caller is the expert ASSIGNED to the review (review_requests/{reviewId}
    .expertId == caller.uid),
  * the review belongs to this athlete (review.userId / .athleteId == athleteUid),
  * the review's planId matches the user's CURRENT planId (the exact
    "apply-gate" the client used, now enforced where it can't be bypassed) —
    so a stale/dead-goal review can never overwrite the athlete's live plan.

It writes ONLY the single plan field (never wallet/role/membership/etc.). The
wrapper object is expert-authored plan content the assigned expert is already
entitled to produce, so accepting it from the authenticated assigned expert is
safe; the endpoint constrains WHERE it lands, not its shape.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from google.cloud import firestore  # noqa: F401  (kept for parity/type intent)
from pydantic import BaseModel

from services import firestore_service
from services.auth_service import verify_firebase_token

router = APIRouter()

_PLAN_FIELD = {"diet": "dietPlan", "workout": "workoutPlan"}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _db():
    db = firestore_service.get_client()
    if db is None:
        reason = firestore_service.config_error() or "unknown"
        raise HTTPException(status_code=503, detail=f"review_apply_unavailable: {reason}")
    return db


class ApplyBody(BaseModel):
    reviewId: str
    athleteUid: str
    planType: str            # 'diet' | 'workout'
    wrapper: dict            # expert-authored applied-plan wrapper (client-built)


@router.post("/apply")
async def apply_reviewed_plan(body: ApplyBody, caller: dict = Depends(verify_firebase_token)):
    plan_type = (body.planType or "").lower()
    if plan_type not in _PLAN_FIELD:
        raise HTTPException(status_code=400, detail="invalid_planType")
    if not body.reviewId or not body.athleteUid or not isinstance(body.wrapper, dict):
        raise HTTPException(status_code=400, detail="missing_params")

    db = _db()

    # ── Authorization from the stored review, never the body ──
    review_snap = db.collection("review_requests").document(body.reviewId).get()
    if not review_snap.exists:
        raise HTTPException(status_code=404, detail="review_not_found")
    review = review_snap.to_dict() or {}

    if review.get("expertId") != caller["uid"]:
        raise HTTPException(status_code=403, detail="not_assigned_expert")

    review_athlete = review.get("userId") or review.get("athleteId")
    if review_athlete and review_athlete != body.athleteUid:
        raise HTTPException(status_code=403, detail="athlete_mismatch")

    # ── APPLY-GATE: review's planId must equal the user's live planId ──
    user_ref = db.collection("users").document(body.athleteUid)
    user_snap = user_ref.get()
    live_plan_id = (user_snap.to_dict() or {}).get("planId") if user_snap.exists else None
    review_plan_id = review.get("planId")
    if not review_plan_id or not live_plan_id or review_plan_id != live_plan_id:
        # Not an error — the master plan is deliberately left untouched; the
        # athlete-side accept flow (planId-gated) owns delivery in this case.
        print(f"[REVIEW APPLY] skipped (planId mismatch) reviewId={body.reviewId} "
              f"review.planId={review_plan_id} live.planId={live_plan_id}")
        return {"success": True, "applied": False, "reason": "planid_mismatch"}

    field = _PLAN_FIELD[plan_type]
    user_ref.set({field: body.wrapper, f"{field}UpdatedAt": _now_iso()}, merge=True)
    print(f"[REVIEW APPLY] applied {field} → users/{body.athleteUid} (reviewId={body.reviewId})")
    return {"success": True, "applied": True, "planType": plan_type}
