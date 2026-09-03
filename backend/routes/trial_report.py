"""
ZITLAS — Trial Completion Report route (backend/routes/trial_report.py)

  GET /api/trial-report/{request_id}   the stored snapshot for one engagement
  GET /api/trial-reports               this athlete's report history (summaries)

TWO ENDPOINTS, TWO RESOURCES. The singular route serves ONE report and stays
the only source of truth for a report's contents. The plural route is a
LISTING: it returns lightweight summaries so the app can find historical
engagements at all, and deliberately carries no metrics — a client that wants
a report's numbers fetches the report.

WHY THE LISTING IS NEEDED. `personal_coaching/{athleteId}` is keyed by athlete
and overwritten when a new engagement starts, so once an athlete begins their
next coaching engagement the previous `requestId` is no longer discoverable
from client-readable data — even though `trial_reports/{oldRequestId}` is
still safely stored. The listing is the only way to reach those.

READ-ONLY BY CONSTRUCTION. This never calls compute_trial_report() and never
writes. The snapshot was frozen at the lifecycle transition
(services/coaching_sweep.py and POST /api/coaching/end); recomputing on GET
would defeat the entire point of snapshotting — see trial_report_store's
module docstring for the three reasons a live recomputation is wrong.

AUTHORIZATION is checked here against the STORED report's own athleteId /
coachId, never against a request parameter. `firestore.rules` enforces the
same pair for direct client reads, so the two paths agree.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from services import firestore_service, trial_report_store
from services.auth_service import verify_firebase_token

router = APIRouter()

#: Mounted separately at /api/trial-reports (plural). A second router rather
#: than a path on the one above, because "/{request_id}" would otherwise
#: swallow any sibling path on the singular prefix.
history_router = APIRouter()


@history_router.get("")
async def list_trial_reports(caller: dict = Depends(verify_firebase_token)):
    """This athlete's completed Trial Reports, newest first.

    THE ATHLETE IS THE TOKEN, NEVER A PARAMETER. There is no athleteId query
    argument by design — the uid comes from the verified Firebase token, so
    there is nothing a caller could supply to list somebody else's history.

    Summaries only, and never a recomputation: this reads stored documents
    and projects a handful of their top-level fields.
    """
    uid = caller.get("uid") or ""
    db = firestore_service.get_client()
    if db is None:
        raise HTTPException(
            status_code=503,
            detail={"error": "firestore_unavailable",
                    "reason": firestore_service.config_error()})

    reports = trial_report_store.list_reports_for_athlete(uid, db=db)
    # An athlete with no completed engagements is a normal, successful,
    # empty result — not a 404. The app renders an empty state from it.
    return {"reports": reports, "count": len(reports)}


@router.get("/{request_id}")
async def get_trial_report(request_id: str,
                           caller: dict = Depends(verify_firebase_token)):
    """The immutable report for one coaching engagement.

    404 when no report exists — which covers both "this engagement never had
    one" and "it has not been generated yet". The two are deliberately not
    distinguished in the response: telling an arbitrary caller that a given
    requestId exists but is unreadable would leak engagement ids.
    """
    uid = caller.get("uid") or ""
    db = firestore_service.get_client()
    if db is None:
        raise HTTPException(
            status_code=503,
            detail={"error": "firestore_unavailable",
                    "reason": firestore_service.config_error()})

    report = trial_report_store.get_report(request_id, db=db)
    if report is None:
        raise HTTPException(
            status_code=404,
            detail={"error": "report_not_found", "requestId": request_id,
                    "status": "pending_or_absent"})

    # Authorization from the STORED document, never from the caller's claim.
    if uid not in (report.get("athleteId"), report.get("coachId")):
        # 404, not 403: a 403 would confirm the report exists to someone with
        # no right to know that. Same reasoning the id is not echoed back.
        print(f"[TRIAL REPORT] denied — uid={uid} is not a party to "
              f"request={request_id}")
        raise HTTPException(
            status_code=404,
            detail={"error": "report_not_found", "requestId": request_id})

    # A stored-but-malformed report is a server-side problem, not a 404: the
    # caller is entitled to it and it exists, but it cannot be trusted.
    missing = trial_report_store.validate(report)
    if missing:
        print(f"[TRIAL REPORT] stored report is malformed — request={request_id} "
              f"missing={missing}")
        raise HTTPException(
            status_code=500,
            detail={"error": "report_malformed", "requestId": request_id})

    return report
