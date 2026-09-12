"""
ZITLAS — Player Routes (backend/routes/player.py)

  GET  /api/user/health        Liveness probe
  POST /api/user/goal-reset    Reset the athlete's goal — metered, server-side

Future endpoints:
  GET    /api/player/profile          Get player profile
  PUT    /api/player/profile          Update player profile
  GET    /api/player/dashboard        Dashboard stats and metrics
  GET    /api/player/training-plan    AI-generated training plan
  POST   /api/player/assessment       Submit 4-step onboarding assessment
  GET    /api/player/progress         Progress history
  GET    /api/player/habits           Habit tracker data
  POST   /api/player/swot             Generate AI SWOT analysis
"""

from __future__ import annotations

import traceback
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from services import entitlements, firestore_service
from services.auth_service import verify_firebase_token

router = APIRouter()


@router.get("/health")
async def player_health():
    return {"module": "player", "status": "ready"}


#: Everything a goal reset clears on `users/{uid}`.
#:
#: Field-for-field the set both clients already cleared themselves —
#: `_clearGoalScopedFields()` in mobile/lib/features/dashboard/data/
#: dashboard_repository.dart and `clearGoalData()`'s GOAL_SCOPED_FIELDS in
#: frontend/website/assets/js/cloud-sync.js. Nothing new is cleared here, and
#: nothing that was cleared before is left behind.
GOAL_SCOPED_FIELDS = (
    "goal",
    "assessment",
    "survey",
    "calculations",
    "swot",
    "dietPlan",
    "workoutPlan",
    "roadmap",
    "precautions",
    "planGeneratedAt",
    "planId",
    "dietPlanMaster",
    "workoutPlanMaster",
)


def _retire_coaching(db, uid: str, now_iso: str) -> str | None:
    """Retire `personal_coaching/{uid}` to 'reset'. Returns the prior status.

    Non-blocking by design, matching both clients: a coaching write that fails
    must never leave the athlete unable to reset their goal. Mirrors
    coaching-reset.js's `_retireCoachingRelationship()` field for field.
    """
    try:
        ref = db.collection("personal_coaching").document(uid)
        snap = ref.get()
        if not snap.exists:
            return None
        prior = (snap.to_dict() or {}).get("status")
        if prior == "reset":
            return prior
        ref.update({"status": "reset", "priorStatus": prior,
                    "resetAt": now_iso})
        return prior
    except Exception as e:  # noqa: BLE001 — see docstring
        print(f"[GOAL RESET] relationship retire failed (non-blocking) "
              f"uid={uid}: {type(e).__name__}: {e}")
        return None


def _clear_published_context(db, uid: str) -> None:
    """Drop the one-shot athlete context published into `coaching_plans/{uid}`.

    Same non-blocking contract as above — mirrors coaching-reset.js:125-127.
    """
    try:
        from google.cloud import firestore as gcf

        ref = db.collection("coaching_plans").document(uid)
        if not ref.get().exists:
            return
        ref.update({
            "athleteContext": gcf.DELETE_FIELD,
            "athleteContextUpdatedAt": gcf.DELETE_FIELD,
        })
    except Exception as e:  # noqa: BLE001 — see docstring
        print(f"[GOAL RESET] athleteContext clear failed (non-blocking) "
              f"uid={uid}: {type(e).__name__}: {e}")


@router.post("/goal-reset")
async def goal_reset(caller: dict = Depends(verify_firebase_token)):
    """Reset this athlete's goal, consuming one weekly goal-reset allowance.

    WHY THIS ENDPOINT EXISTS. The reset used to be performed by the CLIENT
    writing the cleared fields straight to Firestore, with
    `POST /api/entitlements/consume` called first as a courtesy. That made the
    limit advisory: a client that never called `/consume`, or that ignored the
    429, or whose network call simply failed (both clients fail OPEN on a
    transport error) reset as often as it liked. dashboard_controller.dart
    even documented it — "the limit would be advisory, since the reset is a
    client-side write the backend never sees."

    Here the allowance and the mutation are the SAME request. There is no
    ordering a client can exploit, because the client no longer performs the
    write at all: it is done here with the Admin SDK after the quota is
    claimed. Skipping this endpoint does not skip the limit; it skips the
    reset.

    The claim is atomic (`entitlements.reserve`), so two simultaneous taps
    cannot both pass a 1-remaining allowance.

    Premium is unmetered — `reserve()` returns immediately without touching
    the counter when the tier's limit is UNLIMITED.
    """
    uid = caller.get("uid") or ""
    if not uid:
        raise HTTPException(status_code=401, detail={"error": "unauthenticated"})

    db = firestore_service.get_client()
    if db is None:
        raise HTTPException(
            status_code=503,
            detail={"error": "firestore_unavailable",
                    "reason": firestore_service.config_error()})

    # Claim FIRST. 429 propagates untouched so the existing client copy — which
    # already reads detail.tier / detail.limit — keeps working unchanged.
    allowance = entitlements.reserve(uid, entitlements.GOAL_RESET)

    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        updates: dict = {field: None for field in GOAL_SCOPED_FIELDS}
        updates["goalResetAt"] = now_iso
        db.collection("users").document(uid).set(updates, merge=True)
    except Exception as e:  # noqa: BLE001
        # The athlete was charged for a reset that did not happen — give the
        # allowance back rather than silently pocketing it.
        entitlements.release(uid, entitlements.GOAL_RESET)
        print(f"[GOAL RESET] FAILED uid={uid}: {type(e).__name__}: {e}")
        print(traceback.format_exc())
        raise HTTPException(
            status_code=500,
            detail={"error": "goal_reset_failed"},
        ) from e

    prior_status = _retire_coaching(db, uid, now_iso)
    _clear_published_context(db, uid)

    print(f"[GOAL RESET] done uid={uid} tier={allowance.tier} "
          f"used={allowance.used}/{allowance.limit if not allowance.unlimited else 'unlimited'} "
          f"week={allowance.week} priorCoaching={prior_status}")

    return {
        "ok": True,
        "goalResetAt": now_iso,
        "allowance": allowance.as_dict(),
    }
