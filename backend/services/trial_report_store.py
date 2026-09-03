"""
ZITLAS — Trial Completion Report persistence (backend/services/trial_report_store.py)

Stores the immutable snapshot that `trial_report_service.compute_trial_report()`
produces. That module stays strictly read-only; every write in this feature
lives here, so "the calculator never writes" remains a property you can verify
by grepping one file.

WHY A SNAPSHOT AND NOT A LIVE COMPUTATION
------------------------------------------
Three independent facts make recompute-on-read wrong, not merely slower:

  1. `personal_coaching/{athleteId}` is keyed by ATHLETE and overwritten when
     a new coach is accepted (routes/expert_ratings.py documents the same
     fact). The moment the athlete starts their next engagement, the previous
     engagement's dates are gone and its report can never be recomputed.
  2. The AI-plan segment of the plan timeline is only usable while
     `users/{uid}.planId` still matches what the coach's versions were seeded
     from. A regeneration silently invalidates it — so a report that was
     computable at completion stops being computable later.
  3. `firestore.rules` gates the coach's read of meal_checkins on
     `isActiveCoachOf()`, which is false by definition once the engagement
     ends.

So the report is computed ONCE, at the lifecycle transition, and frozen.

IDENTITY IS `requestId`, NOT `athleteId`
-----------------------------------------
An athlete has many engagements over time. Keying by athlete would let a
second trial overwrite the first one's report. `requestId` is the stable
engagement identity — the same one `expert_ratings` uses as its document id
for exactly the same reason.

IMMUTABILITY IS STRUCTURAL
--------------------------
The document id IS the engagement id, and `create_report()` refuses to write
when a document already exists. Two concurrent sweeps therefore cannot
produce two reports, and a re-run cannot alter one. `firestore.rules` denies
all client writes to `trial_reports`, so only this module (Admin SDK) can
create one.
"""

from __future__ import annotations

import traceback
from datetime import datetime, timezone
from typing import Any

from services import firestore_service
from services.trial_report_service import (
    EngagementUnavailable,
    compute_trial_report,
)

COLLECTION = "trial_reports"

#: Report lifecycle. `generated` is terminal for the CONTENT — a report is
#: never regenerated once it exists. `failed` is not stored as a document at
#: all (see `generate_and_store`): a failure leaves NO document, so a retry
#: is simply the next call, and there is no half-written report for a client
#: to read. The status field exists so a consumer can distinguish "finished"
#: from a future state without re-deriving it.
STATUS_GENERATED = "generated"

#: Fields every stored report must carry for it to be considered well-formed.
#: A document missing any of these is treated as MALFORMED and is never
#: silently overwritten — see `create_report`.
_REQUIRED_FIELDS = (
    "requestId", "athleteId", "coachId", "reportVersion",
    "period", "metrics", "generatedAt", "status",
)


class ReportMalformed(Exception):
    """An existing `trial_reports/{requestId}` document is unusable.

    Raised instead of overwriting. A malformed report is a bug worth seeing:
    quietly replacing it would destroy whatever partial evidence explains how
    it got that way, and would also mean a retry loop could keep rewriting a
    document that a client is already reading.
    """


def report_ref(db, request_id: str):
    return db.collection(COLLECTION).document(request_id)


def validate(report: Any) -> list[str]:
    """Field names missing from a stored report. Empty means well-formed."""
    if not isinstance(report, dict):
        return list(_REQUIRED_FIELDS)
    return [field for field in _REQUIRED_FIELDS if field not in report]


def get_report(request_id: str, *, db: Any = None) -> dict | None:
    """The stored snapshot, or None. Never computes, never writes."""
    client = db if db is not None else firestore_service.get_client()
    if client is None or not request_id:
        return None
    snap = report_ref(client, request_id).get()
    return (snap.to_dict() or None) if snap.exists else None


#: The lightweight fields a history listing needs. All are top-level on the
#: stored envelope (see `_envelope`), so a summary is a projection — never a
#: second copy of the report body. The full snapshot stays behind
#: GET /api/trial-report/{requestId}.
SUMMARY_FIELDS = (
    "requestId", "athleteId", "coachId", "coachName", "coachingType",
    "startDate", "endDate", "trialDurationDays", "engagementStatus",
    "reportVersion", "generatedAt", "storedAt", "status",
)


def summarize(report: dict) -> dict:
    """One history row. Metrics are deliberately excluded."""
    return {field: report.get(field) for field in SUMMARY_FIELDS}


def _sort_key(report: dict) -> tuple:
    """Newest engagement first.

    Ordered by when the engagement ENDED — what an athlete thinks of as
    "when that coaching was" — falling back to when the report was generated
    and then stored, since `endDate` is lifted from the period block and a
    very old report could predate that lift. `requestId` breaks ties so the
    order is deterministic rather than dependent on Firestore's scan order.

    Sorted here rather than in the query on purpose: `where(athleteId ==)`
    plus `order_by` is a COMPOSITE query and would need an index deployed
    before it worked at all (a missing one 400s in production — exactly the
    failure tests/test_firestore_indexes.py exists to prevent). An
    equality-only query is served from Firestore's automatic single-field
    indexes, and one athlete's completed engagements are a handful of rows,
    so ordering them in Python costs nothing and cannot fail.
    """
    from services.trial_report_service import parse_iso

    for field in ("endDate", "generatedAt", "storedAt"):
        moment = parse_iso(report.get(field))
        if moment is not None:
            return (0, -moment.timestamp(), str(report.get("requestId") or ""))
    # Undateable rows sort last, still deterministically.
    return (1, 0.0, str(report.get("requestId") or ""))


def list_reports_for_athlete(athlete_uid: str, *, db: Any = None,
                             limit: int | None = None) -> list[dict]:
    """Every stored report belonging to `athlete_uid`, newest first.

    READ-ONLY. Never computes, never writes. Returns SUMMARIES, not full
    snapshots — the history list does not need the metrics, and shipping them
    would make the response grow without bound as reports accumulate.

    The athlete id is the CALLER'S verified uid, passed in by the route. It is
    never taken from a request body or query string, so one athlete can never
    list another's reports.
    """
    client = db if db is not None else firestore_service.get_client()
    if client is None or not athlete_uid:
        return []

    try:
        query = client.collection(COLLECTION).where(
            "athleteId", "==", athlete_uid)
        rows = [doc.to_dict() or {} for doc in query.stream()]
    except Exception as exc:  # noqa: BLE001 — an unreadable listing must not
        # crash a screen; the athlete sees an empty history and the log says why.
        print(f"[TRIAL REPORT] history query failed for {athlete_uid}: "
              f"{type(exc).__name__}: {exc}")
        return []

    # Belt-and-braces: the query already filters, but a listing is the one
    # place a stray document would leak across athletes, so it is re-checked
    # in memory before anything is returned.
    mine = [r for r in rows if r.get("athleteId") == athlete_uid]
    # A malformed report has no trustworthy summary, so it is omitted from
    # history rather than rendered as a half-row. It is still readable
    # directly by id, where the API reports it as malformed explicitly.
    usable = [r for r in mine if not validate(r)]
    usable.sort(key=_sort_key)
    if limit is not None and limit > 0:
        usable = usable[:limit]
    return [summarize(r) for r in usable]


def _envelope(report: dict, *, request_id: str, now: datetime) -> dict:
    """The computed report plus the identity/lifecycle fields storage needs.

    The computation output is embedded WHOLE rather than re-shaped. Copying
    metrics into a second schema is how two representations of one number
    start disagreeing; here there is exactly one `metrics` block and it is
    the one Step 2/2.5's tests already cover.

    WHAT IS LIFTED, AND WHY. `coachId`, `coachName`, `coachingType`,
    `trialDurationDays`, `startDate` and `endDate` are copied to the top
    level from the nested `coach`/`period` blocks. These are identity, not
    metrics, and two consumers need them without walking into the body:

      * `firestore.rules` can only compare `resource.data.<field>` at the top
        level — the read rule for this collection is written against
        `athleteId` and `coachId`;
      * a listing query orders and filters on flat fields.

    The nested `coach` and `period` blocks are kept intact rather than
    replaced, so there is still exactly one authoritative structure and the
    lifted copies are a projection of it, written once at creation and
    frozen with everything else.
    """
    coach = report.get("coach") or {}
    period = report.get("period") or {}
    return {
        **report,
        "requestId": request_id,
        "coachId": coach.get("id"),
        "coachName": coach.get("name"),
        "coachingType": period.get("coachingType"),
        "trialDurationDays": period.get("trialDurationDays"),
        "startDate": period.get("startDate"),
        "endDate": period.get("endDate"),
        # The coaching engagement's own end state (expired / ended), kept
        # under a distinct name because `status` below means the REPORT's
        # lifecycle. Conflating them would make "generated" look like a
        # coaching status.
        "engagementStatus": period.get("status"),
        "status": STATUS_GENERATED,
        "storedAt": now.isoformat(),
    }


def create_report(request_id: str, report: dict, *, db: Any = None,
                  now: datetime | None = None) -> tuple[dict, bool]:
    """Store `report` at `trial_reports/{request_id}` exactly once.

    Returns `(stored_report, created)` — `created` is False when a report
    already existed, in which case the EXISTING one is returned untouched.

    Raises:
        ReportMalformed: a document exists but is missing required fields.
            Never overwritten; surfaced so it can be investigated.
    """
    client = db if db is not None else firestore_service.get_client()
    if client is None:
        raise EngagementUnavailable(
            "Firestore is not configured — "
            f"{firestore_service.config_error() or 'no client available'}")

    moment = now or datetime.now(timezone.utc)
    ref = report_ref(client, request_id)
    envelope = _envelope(report, request_id=request_id, now=moment)

    from google.cloud import firestore as gcf

    @gcf.transactional
    def _txn(tx):
        # Read-then-write inside one transaction: two sweeps racing the same
        # engagement both read "absent", but only one commit can win, and the
        # loser retries and then sees the winner's document.
        snap = ref.get(transaction=tx)
        if snap.exists:
            existing = snap.to_dict() or {}
            missing = validate(existing)
            if missing:
                raise ReportMalformed(
                    f"trial_reports/{request_id} exists but is missing "
                    f"{missing} — refusing to overwrite it. Inspect and delete "
                    f"it deliberately if it should be regenerated.")
            return existing, False
        tx.set(ref, envelope)
        return envelope, True

    return _txn(client.transaction())


def generate_and_store(athlete_uid: str, request_id: str, *, db: Any = None,
                       now: datetime | None = None) -> tuple[dict | None, bool]:
    """Compute and persist one engagement's report. Idempotent.

    Returns `(report, created)`; `created` is False when one already existed.

    NEVER RAISES ON A COMPUTATION FAILURE. This is called from the coaching
    expiry sweep and from `POST /api/coaching/end`, and a report is strictly
    additive to those: an athlete whose report cannot be built must still have
    their trial end correctly. A failure logs with the ids needed to find it
    and returns `(None, False)`, which leaves NO document behind — so the next
    sweep pass, or a manual re-run, simply retries.

    The one exception is `ReportMalformed`, which also returns `(None, False)`
    but logs distinctly: that state needs a human, not a retry.
    """
    client = db if db is not None else firestore_service.get_client()
    if client is None:
        print(f"[TRIAL REPORT] skipped — Firestore not configured "
              f"(athlete={athlete_uid} request={request_id})")
        return None, False

    # Cheap pre-check before doing the computation work at all. The
    # transaction in create_report() is what actually guarantees uniqueness;
    # this just avoids recomputing a report that already exists.
    try:
        existing = get_report(request_id, db=client)
        if existing is not None:
            if validate(existing):
                print(f"[TRIAL REPORT] existing report is MALFORMED — leaving "
                      f"it untouched (request={request_id} athlete={athlete_uid})")
                return None, False
            print(f"[TRIAL REPORT] already generated — request={request_id}")
            return existing, False
    except Exception as exc:  # noqa: BLE001 — a failed pre-check must not
        # block generation; the transaction re-checks authoritatively.
        print(f"[TRIAL REPORT] existence pre-check failed "
              f"({type(exc).__name__}: {exc}) — continuing to generation")

    try:
        report = compute_trial_report(athlete_uid, request_id, db=client,
                                      now=now)
    except EngagementUnavailable as exc:
        # Expected and informative: the engagement was superseded, or its
        # dates are unusable. Not a crash, and not retryable by itself.
        print(f"[TRIAL REPORT] cannot compute — athlete={athlete_uid} "
              f"request={request_id}: {exc}")
        return None, False
    except Exception as exc:  # noqa: BLE001 — see docstring
        print(f"[TRIAL REPORT] computation FAILED — athlete={athlete_uid} "
              f"request={request_id}: {type(exc).__name__}: {exc}")
        print(traceback.format_exc())
        return None, False

    try:
        stored, created = create_report(request_id, report, db=client, now=now)
    except ReportMalformed as exc:
        print(f"[TRIAL REPORT] {exc}")
        return None, False
    except Exception as exc:  # noqa: BLE001 — see docstring
        print(f"[TRIAL REPORT] store FAILED — athlete={athlete_uid} "
              f"request={request_id}: {type(exc).__name__}: {exc}")
        print(traceback.format_exc())
        return None, False

    print(f"[TRIAL REPORT] {'stored' if created else 'already existed'} — "
          f"request={request_id} athlete={athlete_uid} "
          f"version={report.get('reportVersion')}")
    return stored, created
