"""
ZITLAS — Expert Rating / Transformation Review Routes
(backend/routes/expert_ratings.py)

The athlete's 1-5 star rating of a Personal Coaching engagement, plus the
optional written feedback and optional before/after transformation photos.

  GET  /api/expert-ratings/pending          does this athlete owe a rating?
  POST /api/expert-ratings/submit           submit one (validated)
  GET  /api/expert-ratings/expert/{id}      published ratings for a profile

DELIBERATELY NOT `expert_reviews`. That collection already exists and means
something completely different — it is the EXPERT's review OF A DIET PLAN
(`firestore.rules` gates creation on `expertId == request.auth.uid`, i.e.
the expert writes it). This is the opposite direction: the ATHLETE rating
the EXPERT. Reusing the name would have collided on both the rules and the
data shape, so athlete ratings live in `expert_ratings`.

WHY BACKEND-WRITTEN (never a direct client write): the guarantees this
feature needs are not expressible in Firestore rules —
  * "the engagement actually ended"  — a second document's status,
  * "this athlete was in THAT engagement"  — a cross-document join,
  * "no rating exists for this engagement yet"  — needs a transaction,
  * the expert's rating aggregate  — must be recomputed atomically.
So the client posts here, this module validates, and it writes with the
admin SDK. Same posture the wallet already takes (backend-written only —
see FIRESTORE_SECURITY_AUDIT.md V2).

ONE RATING PER ENGAGEMENT is structural, not merely checked: the rating
doc's ID *is* the engagement ID, so a duplicate cannot be created even if
two requests race — the transaction's existence check runs against the same
document both writers target.
"""

from __future__ import annotations

import traceback
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException
from google.cloud import firestore
from google.cloud.firestore_v1.base_query import FieldFilter
from pydantic import BaseModel, Field

from services import firestore_service
from services.auth_service import verify_firebase_token
from services.coaching_service import notify, now

router = APIRouter()

# A rating may only be left once the engagement is genuinely over. "expired"
# is the 48h/term sweep's terminal status (services/coaching_sweep.py),
# "ended" is either side ending it explicitly (routes/coaching.py /end and
# the expert-side equivalent) — the spec's rule is that the TRIGGER is the
# engagement finishing, never which side finished it.
_RATEABLE_STATUSES = {"ended", "expired", "completed"}

_MAX_TEXT = 1000


def _db() -> firestore.Client:
    """Same fail-closed posture as routes/coaching.py's `_db()` — a rating
    that silently no-ops would leave the athlete believing they rated their
    coach and the expert's average quietly wrong."""
    try:
        db = firestore_service.get_client()
    except Exception as e:
        raise HTTPException(status_code=503,
                            detail=f"rating_service_unavailable: {type(e).__name__}: {e}")
    if db is None:
        raise HTTPException(status_code=503,
                            detail=f"rating_service_unavailable: {firestore_service.config_error()}")
    return db


class RatingBody(BaseModel):
    # The engagement being rated. Validated against the athlete's OWN
    # relationship doc — a client cannot rate an engagement it wasn't in.
    engagementId: str
    expertId: str
    rating: int = Field(ge=1, le=5)
    reviewText: Optional[str] = None
    beforePhotoUrl: Optional[str] = None
    afterPhotoUrl: Optional[str] = None
    # Explicit, opt-in, defaults FALSE. Photos are stored either way (so the
    # athlete keeps their own record and the expert can see progress) but are
    # only ever eligible for public display when this is true.
    photoPublic: bool = False


def _resolve_engagement(db: firestore.Client, athlete_uid: str) -> dict[str, Any] | None:
    """The athlete's current relationship doc, IF it represents a finished
    engagement that can be rated. Returns None otherwise.

    `personal_coaching/{athleteUid}` is keyed by athlete and overwritten when
    a new coach is accepted, so it always describes the most recent
    engagement — which is exactly the one worth prompting about.
    """
    snap = db.collection("personal_coaching").document(athlete_uid).get()
    if not snap.exists:
        return None
    rel = snap.to_dict() or {}
    if rel.get("status") not in _RATEABLE_STATUSES:
        return None
    if not rel.get("coachId"):
        return None
    # `requestId` is written unconditionally at accept time
    # (routes/coaching.py), for both PAID and FREE_TRIAL. A relationship
    # without one predates that and cannot be uniquely identified as an
    # engagement, so it is not rateable rather than being given a synthetic
    # id that could collide with a real one later.
    if not rel.get("requestId"):
        return None
    return rel


@router.get("/pending")
async def pending_rating(caller: dict = Depends(verify_firebase_token)) -> dict:
    """Does this athlete have a finished engagement they haven't rated?

    The client polls this rather than deciding for itself, so "already
    rated" is answered by the same authority that stores the rating — a
    reinstalled app or a second device can never re-prompt for something
    already submitted.
    """
    uid = caller["uid"]
    db = _db()
    rel = _resolve_engagement(db, uid)
    if rel is None:
        return {"pending": False}

    engagement_id = rel["requestId"]
    if db.collection("expert_ratings").document(engagement_id).get().exists:
        return {"pending": False, "alreadyRated": True}

    return {
        "pending": True,
        "engagementId": engagement_id,
        "expertId": rel.get("coachId"),
        "expertName": rel.get("coachName") or "your coach",
        "planLabel": rel.get("planLabel"),
        "endedAt": rel.get("endedAt") or rel.get("expiredAt"),
    }


@router.post("/submit")
async def submit_rating(body: RatingBody, caller: dict = Depends(verify_firebase_token)) -> dict:
    uid = caller["uid"]
    db = _db()

    rel = _resolve_engagement(db, uid)
    if rel is None:
        # Covers: no relationship, still active, or missing requestId. The
        # athlete is never told which — all of them mean the same thing to
        # the client, and the distinction is not theirs to probe.
        raise HTTPException(status_code=400, detail="no_rateable_engagement")

    # The client's claimed engagement/expert must match the athlete's OWN
    # relationship. This is what stops a crafted request rating a different
    # expert, or attaching a rating to someone else's engagement.
    if body.engagementId != rel["requestId"]:
        raise HTTPException(status_code=403, detail="engagement_mismatch")
    if body.expertId != rel.get("coachId"):
        raise HTTPException(status_code=403, detail="expert_mismatch")

    expert_id = body.expertId
    text = (body.reviewText or "").strip()[:_MAX_TEXT] or None
    ts = now().isoformat()
    rating_ref = db.collection("expert_ratings").document(body.engagementId)
    expert_ref = db.collection("experts").document(expert_id)

    @firestore.transactional
    def _txn(tx) -> dict:
        # ── READS FIRST (Firestore transaction rule) ──
        existing = rating_ref.get(transaction=tx)
        if existing.exists:
            raise HTTPException(status_code=409, detail="already_rated")
        expert_snap = expert_ref.get(transaction=tx)
        expert = expert_snap.to_dict() if expert_snap.exists else {}

        # EXACT running aggregate — never an arbitrary nudge.
        #
        # `ratingSum`/`ratingCount` are the authoritative pair. When they are
        # absent the expert may still carry a pre-existing `rating` /
        # `reviewCount` (seeded before this feature existed); those are
        # back-filled into the aggregate so the first real rating extends the
        # published history rather than silently discarding it.
        prior_count = _as_int(expert.get("ratingCount"))
        if prior_count is None:
            prior_count = _as_int(expert.get("reviewCount")) or _as_int(expert.get("reviews")) or 0
            prior_sum = round(float(_as_float(expert.get("rating")) or 0.0) * prior_count, 4)
        else:
            prior_sum = float(_as_float(expert.get("ratingSum")) or 0.0)

        new_count = prior_count + 1
        new_sum = prior_sum + body.rating
        new_avg = round(new_sum / new_count, 1)

        # ── WRITES ──
        tx.set(rating_ref, {
            "reviewId": body.engagementId,
            "engagementId": body.engagementId,
            "expertId": expert_id,
            "athleteId": uid,
            "athleteName": rel.get("athleteName") or "ZITLAS Athlete",
            "rating": body.rating,
            "reviewText": text,
            "beforePhotoUrl": body.beforePhotoUrl or None,
            "afterPhotoUrl": body.afterPhotoUrl or None,
            "photoPublic": bool(body.photoPublic),
            # Always true here BY CONSTRUCTION — this endpoint is the only
            # writer and it has just proven the athlete completed a real
            # coaching engagement with this expert. It is stored explicitly
            # so a reader never has to re-derive it.
            "verifiedCoaching": True,
            "planLabel": rel.get("planLabel"),
            "status": "published",
            "createdAt": ts,
        })
        tx.set(expert_ref, {
            "ratingSum": new_sum,
            "ratingCount": new_count,
            "rating": new_avg,
            "reviewCount": new_count,
        }, merge=True)
        return {"average": new_avg, "count": new_count}

    try:
        agg = _txn(db.transaction())
    except HTTPException:
        raise
    except Exception as e:
        print(f"[EXPERT RATING] transaction failed — athlete={uid} expert={expert_id}: "
              f"{type(e).__name__}: {e}")
        print(traceback.format_exc())
        raise HTTPException(status_code=500, detail=f"rating_failed: {type(e).__name__}")

    # Additive — a failed notification never fails the rating.
    try:
        stars = "⭐" * body.rating
        notify(
            db, expert_id, "New review received",
            f"{stars} {body.rating}-star review from a client"
            + (f" — “{text[:80]}”" if text else "."),
            category="expert", type="expert_rating_received",
            action="expert_dashboard", action_id=body.engagementId,
        )
    except Exception:
        print(f"[EXPERT RATING] notify failed (non-fatal) — expert={expert_id}")
        print(traceback.format_exc())

    print(f"[EXPERT RATING] stored {body.rating}★ athlete={uid} expert={expert_id} "
          f"engagement={body.engagementId} -> avg={agg['average']} n={agg['count']}")
    return {"success": True, "rating": body.rating, **agg}


@router.get("/expert/{expert_id}")
async def expert_ratings(expert_id: str, limit: int = 20) -> dict:
    """Published ratings for an expert's public profile.

    PRIVACY: photo URLs are returned ONLY when the athlete explicitly
    consented to public display. A stored-but-private photo is never
    included in this response at all — it is not merely hidden client-side,
    where any client could choose to render it anyway.
    """
    db = _db()
    limit = max(1, min(limit, 50))
    docs = (
        db.collection("expert_ratings")
        .where(filter=FieldFilter("expertId", "==", expert_id))
        .where(filter=FieldFilter("status", "==", "published"))
        .limit(limit)
        .stream()
    )
    out = []
    for d in docs:
        r = d.to_dict() or {}
        public_photos = bool(r.get("photoPublic"))
        out.append({
            "reviewId": r.get("reviewId"),
            "rating": r.get("rating"),
            "reviewText": r.get("reviewText"),
            "verifiedCoaching": bool(r.get("verifiedCoaching")),
            "createdAt": r.get("createdAt"),
            # Display name policy matches the existing profile UI, which
            # never shows an athlete's full identity on a public review.
            "athleteName": "Verified ZITLAS Client",
            "beforePhotoUrl": r.get("beforePhotoUrl") if public_photos else None,
            "afterPhotoUrl": r.get("afterPhotoUrl") if public_photos else None,
        })
    out.sort(key=lambda x: x.get("createdAt") or "", reverse=True)
    return {"count": len(out), "reviews": out}


def _as_int(v: Any) -> int | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    try:
        return int(str(v).strip())
    except (ValueError, TypeError):
        return None


def _as_float(v: Any) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).strip())
    except (ValueError, TypeError):
        return None
