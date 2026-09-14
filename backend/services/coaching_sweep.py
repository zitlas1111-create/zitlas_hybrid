"""
ZITLAS — Personal Coaching expiry sweeps (backend/services/coaching_sweep.py)

Two INDEPENDENT sweeps, both in-process APScheduler jobs wired in main.py's
lifespan. Neither is an HTTP route, so neither must ever raise on a routine
"not configured" condition (mirrors push_service's no-op-when-unconfigured
pattern, unlike routes/coaching.py's HTTP routes, which fail closed with a
503 since a client is actively waiting on those):

  sweep_expired_requests()      — 48h PENDING REQUEST expiry. Releases a
                                   reservation the expert never responded to.
  sweep_expired_relationships() — ACTIVE RELATIONSHIP expiry. Flips an
                                   active personal_coaching relationship to
                                   'expired' once its endDateTs passes, and
                                   marks the Personal Coaching Program it
                                   belongs to (if any) 'completed'. Nothing
                                   else is touched: coaching_plans, its
                                   versions, meal check-ins and chat stay.

These are different lifecycle stages of the same feature and must not be
confused: a request can expire before any coach ever accepts it (this is
the FIRST sweep); a relationship expires 30 days AFTER a coach already
accepted and payment was captured (this is the SECOND sweep).

Each item is processed in its OWN transaction that re-checks the relevant
status fresh — if a human (accept/reject/end) or another sweep pass acted
on the same doc in the window being scanned, it's simply skipped as a
no-op, so there's no race between a human decision and the sweep.
"""

from __future__ import annotations

from datetime import datetime, timezone

from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter

from services import coaching_programs as cp
from services import firestore_service
from services.coaching_service import notify, now, release_reservation_txn


def _release_one(db, request_ref):
    @firestore.transactional
    def _txn(tx):
        req_snap = request_ref.get(transaction=tx)
        if not req_snap.exists:
            return None
        req = req_snap.to_dict()
        if req.get("status") != "pending":
            return None  # already accepted/rejected/expired by something else
        return release_reservation_txn(tx, db, request_ref, req, "expired",
                                        "released_expired", "expiredAt"), req

    result = _txn(db.transaction())
    if result is None:
        return
    athlete_uid, req = result
    is_trial = req.get("requestType") == "FREE_TRIAL"
    _msg = (
        (req.get("expertName") or "The expert") + " didn't respond to your free trial request in time."
        if is_trial else
        (req.get("expertName") or "The expert") + " didn't respond in time. "
        "Your reserved amount has been released."
    )
    notify(db, athlete_uid, "Request expired", _msg,
           category="expert", type="coaching_expired", action="coaches")


def sweep_expired_requests() -> int:
    """Returns the number of requests released. Safe to call even when
    Firestore isn't configured (logs and returns 0, same as push's no-op)."""
    db = firestore_service.get_client()
    if db is None:
        print("[COACHING SWEEP] skipped — Firestore not configured")
        return 0

    now_iso = now().isoformat()
    query = db.collection("personal_coach_requests") \
              .where(filter=FieldFilter("status", "==", "pending")) \
              .where(filter=FieldFilter("expiresAt", "<=", now_iso))

    released = 0
    for doc in query.stream():
        try:
            _release_one(db, doc.reference)
            released += 1
        except Exception as e:
            print(f"[COACHING SWEEP] failed to release {doc.id}: {type(e).__name__}: {e}")

    if released:
        print(f"[COACHING SWEEP] released {released} expired reservation(s)")
    return released


def _as_dt(raw):
    if isinstance(raw, datetime):
        return raw if raw.tzinfo else raw.replace(tzinfo=timezone.utc)
    if isinstance(raw, str) and raw:
        try:
            parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    return None


def _duration_days(rel: dict) -> int | None:
    """How long this engagement actually ran for — the program's own
    `durationDays` (10 / 30 / 90), else computed from its dates. Never a
    hard-coded 30: a 10-day program must not be told it had 30 days."""
    try:
        days = int(rel.get("durationDays"))
        if days > 0:
            return days
    except (TypeError, ValueError):
        pass
    start = _as_dt(rel.get("startDate"))
    end = _as_dt(rel.get("endDateTs")) or _as_dt(rel.get("endDate"))
    if start and end and end > start:
        return max(1, round((end - start).total_seconds() / 86400))
    return None


def _is_program(rel: dict) -> bool:
    return bool(rel.get("programRequestId")) or rel.get("source") == "coaching_program"


def _generate_trial_report(rel: dict) -> None:
    """Best-effort Trial Completion Report for a just-ended engagement.

    CANNOT BREAK THE LIFECYCLE. Called only after the status transition has
    committed, imports lazily so a broken import cannot stop the sweep from
    loading, and swallows everything — `generate_and_store` already declines
    to raise, and this is the second belt on top of that. A report is a
    summary of something that already happened; failing to build one must
    never leave an engagement stuck 'active'.

    Idempotent by construction: `trial_reports/{requestId}` is created inside
    a transaction that refuses to overwrite, so a second sweep pass over the
    same engagement is a no-op.
    """
    # A Personal Coaching Program is identified by its programRequestId; a
    # legacy engagement by its escrow requestId.
    request_id = rel.get("programRequestId") or rel.get("requestId")
    athlete_uid = rel.get("athleteId")
    if not request_id or not athlete_uid:
        print(f"[COACHING SWEEP] no trial report — missing "
              f"requestId={request_id!r} athleteId={athlete_uid!r}")
        return
    try:
        from services import trial_report_store

        trial_report_store.generate_and_store(athlete_uid, request_id)
    except Exception as exc:  # noqa: BLE001 — see docstring
        print(f"[COACHING SWEEP] trial report generation raised "
              f"(non-fatal, lifecycle already committed) — "
              f"athlete={athlete_uid} request={request_id}: "
              f"{type(exc).__name__}: {exc}")


def _expire_one_relationship(db, rel_ref):
    @firestore.transactional
    def _txn(tx):
        # ── ALL READS FIRST (both docs), THEN ALL WRITES — mirrors /end's
        # dual-document transaction shape in routes/coaching.py so the
        # relationship and its originating request never drift out of sync.
        rel_snap = rel_ref.get(transaction=tx)
        if not rel_snap.exists:
            return None
        rel = rel_snap.to_dict()
        if rel.get("status") != "active":
            return None  # already expired/ended by something else
        rel_end = rel.get("endDateTs")
        if rel_end is None or rel_end > now():
            return None  # query race (endDateTs moved) — skip, not actually due

        request_id = rel.get("requestId")
        req_ref = None
        close_request = False
        if request_id:
            req_ref = db.collection("personal_coach_requests").document(request_id)
            req_snap = req_ref.get(transaction=tx)
            close_request = (
                req_snap.exists
                and (req_snap.to_dict() or {}).get("athleteId") == rel.get("athleteId")
            )

        # The Personal Coaching Program this relationship belongs to, if any —
        # read here, with the other reads, and completed in the same commit.
        program_ref = None
        complete_program = False
        program_request_id = rel.get("programRequestId")
        if program_request_id:
            program_ref = db.collection(cp.REQUESTS_COLLECTION).document(program_request_id)
            program_snap = program_ref.get(transaction=tx)
            program = (program_snap.to_dict() if program_snap.exists else None) or {}
            complete_program = (
                program_snap.exists
                and program.get("athleteId") == rel.get("athleteId")
                and program.get("status") == cp.STATUS_ACTIVE
            )

        _now = now()
        tx.update(rel_ref, {"status": "expired", "expiredAt": _now.isoformat()})
        if close_request and req_ref is not None:
            tx.update(req_ref, {"status": "expired", "updatedAt": _now.isoformat()})
        if complete_program and program_ref is not None:
            # Only the lifecycle fields: price, payment and dates stay as paid.
            tx.update(program_ref, {"status": cp.STATUS_COMPLETED,
                                    "completedAt": _now.isoformat(),
                                    "updatedAt": _now.isoformat()})
        return rel

    rel = _txn(db.transaction())
    if rel is None:
        return
    athlete_uid = rel.get("athleteId")
    coach_id = rel.get("coachId")
    coach_name = rel.get("coachName") or "your coach"
    athlete_name = rel.get("athleteName") or "An athlete"

    # TRIAL COMPLETION REPORT — strictly after the status transition above
    # has already committed, and strictly additive to it. The relationship is
    # 'expired' by now whatever happens here; generate_and_store() never
    # raises, so a report that cannot be built leaves the lifecycle correct
    # and simply logs. No document is written on failure, so the next sweep
    # pass retries on its own.
    _generate_trial_report(rel)

    if rel.get("coachingType") == "FREE_TRIAL":
        duration = rel.get("trialDurationDays") or "your"
        notify(db, athlete_uid, "Free Trial Ended",
               f"Your {duration}-day Free Trial with {coach_name} has ended. "
               "Continue with full Personal Coaching to keep working with them.",
               category="expert", type="coaching_subscription_expired", action="coaches")
        notify(db, coach_id, "Free Trial Ended",
               f"{athlete_name}'s free trial has ended.",
               category="expert", type="coaching_subscription_expired", action="expert_dashboard")
    elif _is_program(rel):
        days = _duration_days(rel)
        length = f"{days}-day " if days else ""
        notify(db, athlete_uid, "Program Completed",
               f"Your {length}Personal Coaching Program with {coach_name} is complete. "
               "Your plan and coaching history stay in your account — start a new "
               "program anytime to continue.",
               category="expert", type="coaching_program_completed", action="coaches")
        notify(db, coach_id, "Program Completed",
               f"{athlete_name}'s {length}Personal Coaching Program is complete.",
               category="expert", type="coaching_program_completed", action="expert_dashboard")
    else:
        days = _duration_days(rel) or 30
        notify(db, athlete_uid, "Coaching Ended",
               f"Your {days}-day Personal Coaching with {coach_name}"
               " has ended. You're back on the AI-only plan — renew anytime to continue.",
               category="expert", type="coaching_subscription_expired", action="coaches")
        notify(db, coach_id, "Coaching Ended",
               f"{athlete_name}'s {days}-day coaching subscription has ended.",
               category="expert", type="coaching_subscription_expired", action="expert_dashboard")


def sweep_expired_relationships() -> int:
    """Returns the number of ACTIVE relationships flipped to 'expired'
    because their endDateTs has passed. See module docstring for how
    this differs from sweep_expired_requests(). Safe to call when Firestore
    isn't configured."""
    db = firestore_service.get_client()
    if db is None:
        print("[COACHING SWEEP] relationship sweep skipped — Firestore not configured")
        return 0

    query = db.collection("personal_coaching") \
              .where(filter=FieldFilter("status", "==", "active")) \
              .where(filter=FieldFilter("endDateTs", "<=", now()))

    expired = 0
    for doc in query.stream():
        try:
            _expire_one_relationship(db, doc.reference)
            expired += 1
        except Exception as e:
            print(f"[COACHING SWEEP] failed to expire relationship {doc.id}: {type(e).__name__}: {e}")

    if expired:
        print(f"[COACHING SWEEP] expired {expired} coaching relationship(s) past their end date")
    return expired
