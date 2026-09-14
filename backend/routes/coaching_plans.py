"""
ZITLAS — Authoritative coaching-diet save (backend/routes/coaching_plans.py)
Mounted at /api/coaching-plans.

    POST /api/coaching-plans/{athleteId}/diet   {"diet": {...}, "baseVersion": N}

THE ONE PLACE an expert's coaching diet is published. It used to be a client
Firestore transaction in coaching-workspace.js that bumped `dietVersion` from
whatever was stored — so a second tab or device holding an older draft
silently overwrote newer work, and a save could look successful in the UI
without anything checking who the caller really was.

Every save here, inside ONE Firestore transaction:
  * the caller is the athlete's CURRENT coach (personal_coaching/{athlete}
    .coachId — never a client-supplied expertId);
  * the relationship is active and not past its end date;
  * the relationship covers diet coaching (planType diet / complete; a free
    trial's null planType means full coverage, exactly as both clients read it);
  * a relationship created by a Personal Coaching Program is backed by that
    program being paid and active;
  * `baseVersion` equals the stored `dietVersion` — otherwise 409, nothing is
    written, and the newer plan stays exactly as it is;
  * the plan, its version, and a history snapshot are written together.

Only after the commit is the athlete notified (the existing plan-updated
notification) — best effort: a failed push can never undo or fail a save.

Firestore rules are unchanged: the active coach may still write the document
directly (older clients); this endpoint is what current clients use.
"""

from __future__ import annotations

import json
import re
import time
import traceback
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from google.cloud import firestore
from pydantic import BaseModel, Field

from routes.notifications import send_plan_updated
from services import coaching_programs as cp
from services import firestore_service
from services.auth_service import verify_firebase_token
from services.coaching_service import now

router = APIRouter()

_ID_RE = re.compile(r"[A-Za-z0-9_\-]{1,128}")

#: planType values whose coaching includes the diet. None (a free trial) is
#: full coverage — the same reading as diet.js `_pcShowsCoachPlan()` and the
#: app's `_coachDietRelationshipActive`.
DIET_PLAN_TYPES = frozenset({"diet", "complete"})

# Sanity bounds — generous for any real week, small enough that one save can
# never push coaching_plans/{uid} (which also holds training) near 1 MiB.
MAX_DIET_BYTES = 256_000
MAX_DAYS = 14
MAX_MEALS_PER_DAY = 20
MAX_OPTIONS_PER_MEAL = 10


class DietSaveBody(BaseModel):
    diet: dict
    #: The dietVersion the expert's editor was working from.
    baseVersion: int = Field(..., ge=0)


def _db():
    db = firestore_service.get_client()
    if db is None:
        raise HTTPException(status_code=503, detail="firestore_unavailable")
    return db


def _as_version(raw: Any) -> int:
    """Stored versions can be strings (the website writes JS values)."""
    try:
        return max(0, int(float(raw)))
    except (TypeError, ValueError):
        return 0


def _as_datetime(raw: Any) -> datetime | None:
    if isinstance(raw, datetime):
        return raw if raw.tzinfo else raw.replace(tzinfo=timezone.utc)
    if isinstance(raw, str) and raw:
        try:
            parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    return None


def relationship_problem(rel: dict | None, caller_uid: str,
                         moment: datetime) -> tuple[int, str] | None:
    """Why `caller_uid` may NOT edit this athlete's coaching diet, or None.

    Status + end date + coverage, in the same terms both athlete clients use
    to decide whether a coaching diet is active at all.
    """
    if not rel:
        return 403, "no_coaching_relationship"
    if rel.get("coachId") != caller_uid:
        return 403, "not_assigned_coach"
    if rel.get("status") != "active":
        return 403, "coaching_not_active"
    end = _as_datetime(rel.get("endDateTs")) or _as_datetime(rel.get("endDate"))
    if end is not None and end <= moment:
        return 403, "coaching_not_active"
    if (rel.get("planType") or "complete") not in DIET_PLAN_TYPES:
        return 403, "plan_does_not_cover_diet"
    return None


def validate_diet(diet: Any) -> dict:
    """The coach-diet shape the website and the app both read:
    {days: [{day, meals: [{id, name, time, options: [...]}]}]}."""
    if not isinstance(diet, dict):
        raise HTTPException(status_code=400, detail="invalid_diet")
    days = diet.get("days")
    if not isinstance(days, list) or not days or len(days) > MAX_DAYS:
        raise HTTPException(status_code=400, detail="invalid_diet_days")
    for day in days:
        if not isinstance(day, dict):
            raise HTTPException(status_code=400, detail="invalid_diet_days")
        meals = day.get("meals", [])
        if not isinstance(meals, list) or len(meals) > MAX_MEALS_PER_DAY:
            raise HTTPException(status_code=400, detail="invalid_diet_meals")
        for meal in meals:
            if not isinstance(meal, dict):
                raise HTTPException(status_code=400, detail="invalid_diet_meals")
            options = meal.get("options", [])
            if not isinstance(options, list) or len(options) > MAX_OPTIONS_PER_MEAL:
                raise HTTPException(status_code=400, detail="invalid_diet_options")
    try:
        size = len(json.dumps(diet, default=str))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="invalid_diet") from None
    if size > MAX_DIET_BYTES:
        raise HTTPException(status_code=413, detail="diet_too_large")
    return dict(diet)


def _program_problem(prog: dict | None, athlete_id: str, caller_uid: str) -> str | None:
    if not prog:
        return "program_not_found"
    if prog.get("athleteId") != athlete_id or prog.get("expertId") != caller_uid:
        return "program_mismatch"
    if prog.get("status") != cp.STATUS_ACTIVE or prog.get("paymentStatus") != cp.PAYMENT_PAID:
        return "program_not_active"
    return None


@router.post("/{athlete_id}/diet")
async def save_coaching_diet(athlete_id: str, body: DietSaveBody,
                             caller: dict = Depends(verify_firebase_token)):
    caller_uid = caller.get("uid") or ""
    if not _ID_RE.fullmatch(athlete_id or ""):
        raise HTTPException(status_code=404, detail="athlete_not_found")
    if athlete_id == caller_uid:
        raise HTTPException(status_code=403, detail="not_assigned_coach")
    diet = validate_diet(body.diet)

    db = _db()
    rel_ref = db.collection("personal_coaching").document(athlete_id)
    plan_ref = db.collection("coaching_plans").document(athlete_id)
    user_ref = db.collection("users").document(athlete_id)

    @firestore.transactional
    def _txn(tx):
        # ── ALL READS FIRST ──────────────────────────────────────────────
        rel_snap = rel_ref.get(transaction=tx)
        rel = rel_snap.to_dict() if rel_snap.exists else None
        problem = relationship_problem(rel, caller_uid, now())
        if problem:
            raise HTTPException(status_code=problem[0], detail=problem[1])

        program_request_id = rel.get("programRequestId")
        if program_request_id or rel.get("source") == "coaching_program":
            if not program_request_id:
                raise HTTPException(status_code=403, detail="program_not_active")
            prog_ref = db.collection(cp.REQUESTS_COLLECTION).document(program_request_id)
            prog_snap = prog_ref.get(transaction=tx)
            why = _program_problem(prog_snap.to_dict() if prog_snap.exists else None,
                                   athlete_id, caller_uid)
            if why:
                raise HTTPException(status_code=403, detail=why)

        plan_snap = plan_ref.get(transaction=tx)
        plan = (plan_snap.to_dict() if plan_snap.exists else None) or {}
        user_snap = user_ref.get(transaction=tx)
        live_plan_id = ((user_snap.to_dict() if user_snap.exists else None) or {}).get("planId")

        # ── OPTIMISTIC CONCURRENCY ───────────────────────────────────────
        current = _as_version(plan.get("dietVersion"))
        if body.baseVersion != current:
            raise HTTPException(status_code=409, detail={
                "error": "stale_version",
                "baseVersion": body.baseVersion,
                "currentVersion": current,
                "dietUpdatedAt": plan.get("dietUpdatedAt"),
            })

        # ── WRITES — plan + history snapshot, one commit ─────────────────
        version = current + 1
        stamp = now().isoformat()
        coach_name = rel.get("coachName") or plan.get("coachName") or "Coach"
        saved = dict(diet)
        # Goal-identity stamp from the athlete's LIVE record, not the client.
        saved["planId"] = live_plan_id or None
        doc = {
            "athleteId": athlete_id,
            "athleteName": rel.get("athleteName") or plan.get("athleteName") or "Athlete",
            "coachId": caller_uid,
            "coachName": coach_name,
            "planType": rel.get("planType") or "complete",
            "diet": saved,
            "dietVersion": version,
            "dietUpdatedAt": stamp,
            "dietUpdatedBy": caller_uid,
            "updatedAt": stamp,
        }
        if program_request_id:
            doc["programRequestId"] = program_request_id
            doc["programId"] = rel.get("programId")
        if plan_snap.exists:
            tx.update(plan_ref, doc)          # replaces `diet` whole — no stale keys
        else:
            tx.set(plan_ref, doc)
        # The version is part of the id: two saves in the same millisecond
        # must never share (and overwrite) one history snapshot.
        tx.set(plan_ref.collection("versions").document(
                f"diet_{int(time.time() * 1000)}_v{version}"), {
            "type": "diet", "data": saved, "version": version,
            "savedAt": stamp, "savedBy": coach_name, "savedByUid": caller_uid,
        })
        return {"version": version, "stamp": stamp, "coachName": coach_name,
                "planId": saved["planId"]}

    try:
        result = _txn(db.transaction())
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        print(f"[COACH DIET SAVE] failed athlete={athlete_id} coach={caller_uid}: "
              f"{type(e).__name__}: {e}")
        print(traceback.format_exc())
        raise HTTPException(status_code=500,
                            detail=f"coaching_diet_save_failed: {type(e).__name__}") from None

    print(f"[COACH DIET SAVE] v{result['version']} athlete={athlete_id} coach={caller_uid}")

    # After the commit only, and never able to fail the save.
    notified = False
    try:
        send_plan_updated(db, athlete_id, caller_uid, result["coachName"], "diet")
        notified = True
    except Exception as e:  # noqa: BLE001
        print(f"[COACH DIET SAVE] plan-updated notification failed (save kept) — "
              f"athlete={athlete_id}: {type(e).__name__}: {e}")

    return {"success": True, "dietVersion": result["version"],
            "dietUpdatedAt": result["stamp"], "planId": result["planId"],
            "notified": notified}
