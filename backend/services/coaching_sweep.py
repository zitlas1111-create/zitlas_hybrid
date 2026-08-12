"""
ZITLAS — Personal Coaching expiry sweeps (backend/services/coaching_sweep.py)

Two INDEPENDENT sweeps, both in-process APScheduler jobs wired in main.py's
lifespan. Neither is an HTTP route, so neither must ever raise on a routine
"not configured" condition (mirrors push_service's no-op-when-unconfigured
pattern, unlike routes/coaching.py's HTTP routes, which fail closed with a
503 since a client is actively waiting on those):

  sweep_expired_requests()      — 48h PENDING REQUEST expiry. Releases a
                                   reservation the expert never responded to.
  sweep_expired_relationships() — 30-day ACTIVE SUBSCRIPTION expiry. Flips
                                   an active personal_coaching relationship
                                   to 'expired' once its endDateTs passes.

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

from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter

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


def _expire_one_relationship(db, rel_ref):
    @firestore.transactional
    def _txn(tx):
        rel_snap = rel_ref.get(transaction=tx)
        if not rel_snap.exists:
            return None
        rel = rel_snap.to_dict()
        if rel.get("status") != "active":
            return None  # already expired/ended by something else
        rel_end = rel.get("endDateTs")
        if rel_end is None or rel_end > now():
            return None  # query race (endDateTs moved) — skip, not actually due
        tx.update(rel_ref, {"status": "expired", "expiredAt": now().isoformat()})
        return rel

    rel = _txn(db.transaction())
    if rel is None:
        return
    athlete_uid = rel.get("athleteId")
    coach_id = rel.get("coachId")
    coach_name = rel.get("coachName") or "your coach"
    athlete_name = rel.get("athleteName") or "An athlete"
    if rel.get("coachingType") == "FREE_TRIAL":
        duration = rel.get("trialDurationDays") or "your"
        notify(db, athlete_uid, "Free Trial Ended",
               f"Your {duration}-day Free Trial with {coach_name} has ended. "
               "Continue with full Personal Coaching to keep working with them.",
               category="expert", type="coaching_subscription_expired", action="coaches")
        notify(db, coach_id, "Free Trial Ended",
               f"{athlete_name}'s free trial has ended.",
               category="expert", type="coaching_subscription_expired", action="expert_dashboard")
    else:
        notify(db, athlete_uid, "Coaching Ended",
               "Your 30-day Personal Coaching with " + coach_name +
               " has ended. You're back on the AI-only plan — renew anytime to continue.",
               category="expert", type="coaching_subscription_expired", action="coaches")
        notify(db, coach_id, "Coaching Ended",
               athlete_name + "'s 30-day coaching subscription has ended.",
               category="expert", type="coaching_subscription_expired", action="expert_dashboard")


def sweep_expired_relationships() -> int:
    """Returns the number of ACTIVE relationships flipped to 'expired'
    because their 30-day endDateTs has passed. See module docstring for how
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
        print(f"[COACHING SWEEP] expired {expired} coaching relationship(s) past their 30-day term")
    return expired
