"""
ZITLAS — Push notification trigger routes (backend/routes/notifications.py)

The events these cover (a chat message, a meal check-in, a coach's review, a
published plan) are all written to Firestore DIRECTLY by the client — there is
no server-side write to hook, and no Cloud Function in this project. So the
client tells the backend "this happened", and the backend decides whether it
really did and who is allowed to be notified.

SECURITY — the whole point of these routes. The caller NEVER supplies the
recipient. Every endpoint:
  1. authenticates the caller (verify_firebase_token),
  2. re-reads the underlying document with the Admin SDK,
  3. verifies the CALLER is the party entitled to trigger this notification,
  4. derives the RECIPIENT from that document.
So an athlete cannot push to an arbitrary user, and an expert cannot push into
another expert's client relationship — the worst a malicious caller can do is
re-trigger a notification for a conversation/check-in they already belong to
(which is also why every send here is idempotent-safe and rate-bounded by the
underlying document already existing).

Delivery + persistence both live in services/notification_service.py; nothing
here talks to FCM directly.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from services import firestore_service, notification_service
from services.auth_service import verify_firebase_token

router = APIRouter()


def _db():
    """Same fail-closed pattern as routes/coaching.py's _db(), and the response
    always carries the real reason rather than a bare 503."""
    try:
        db = firestore_service.get_client()
    except Exception as e:
        print(f"[NOTIFY ROUTE] get_client() raised: {type(e).__name__}: {e}")
        raise HTTPException(status_code=503,
                            detail=f"notifications_unavailable: {type(e).__name__}: {e}")
    if db is None:
        reason = firestore_service.config_error() or "get_client() returned None"
        print(f"[NOTIFY ROUTE] Firestore unavailable — {reason}")
        raise HTTPException(status_code=503, detail=f"notifications_unavailable: {reason}")
    return db


def _short(text: str | None, limit: int = 120) -> str:
    t = (text or "").strip().replace("\n", " ")
    if len(t) <= limit:
        return t
    return t[: limit - 1] + "…"


def _name_of(db, uid: str, fallback: str = "Someone") -> str:
    try:
        snap = db.collection("users").document(uid).get()
        data = snap.to_dict() or {}
        return (data.get("name") or data.get("displayName") or fallback).strip() or fallback
    except Exception:
        return fallback


# ── Chat ────────────────────────────────────────────────────────────────────

class ChatBody(BaseModel):
    chatId: str
    text: str | None = None


@router.post("/chat")
async def notify_chat(body: ChatBody, caller: dict = Depends(verify_firebase_token)):
    """A chat message was just written. Push it to the OTHER participant.

    Recipient = the participant of this room who is not the caller — read from
    the room document, never from the request. push-only (no notification-centre
    document): the conversation itself is the durable record, and persisting
    every message would flood the notification list.
    """
    db = _db()
    sender_uid = caller["uid"]

    snap = db.collection("chat_rooms").document(body.chatId).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="chat_room_not_found")
    room = snap.to_dict() or {}

    participants = [p for p in (room.get("participants") or []) if p]
    if sender_uid not in participants:
        raise HTTPException(status_code=403, detail="not_a_participant")

    recipients = [p for p in participants if p != sender_uid]
    if not recipients:
        return {"success": True, "sent": 0, "detail": "no_other_participant"}

    sender_name = _name_of(db, sender_uid, "New message")
    preview = _short(body.text) or "Sent you a message."

    # The room names both sides, so the SERVER can tell each recipient which
    # side of the relationship they are on. The app must not have to guess:
    # an athlete's chat opens the coach's profile workspace, a coach's chat
    # opens their dashboard, and those are different destinations for the very
    # same message. Derived per-recipient, never taken from the request.
    room_athlete = room.get("athleteId")
    room_expert = room.get("expertId")

    total = 0
    for uid in recipients:
        if uid == room_expert:
            recipient_role, counterpart = "coach", room_athlete
        elif uid == room_athlete:
            recipient_role, counterpart = "athlete", room_expert
        else:
            recipient_role, counterpart = "unknown", None

        res = notification_service.push_only(
            db, uid,
            title=sender_name,
            body=preview,
            type="chat_message",
            data={
                "type": "chat_message",
                "chatId": body.chatId,
                "senderId": sender_uid,
                "senderName": sender_name,
                "recipientRole": recipient_role,
                # For an athlete this is their coach's uid (what the coach
                # profile WebView needs); for a coach it is the athlete's.
                "counterpartId": counterpart or sender_uid,
            },
            # Groups repeated messages from the SAME conversation into one
            # notification instead of stacking them (messaging-app behaviour).
            collapse_key="chat_" + body.chatId,
        )
        total += res.get("sent", 0)
    return {"success": True, "sent": total}


# ── Meal check-in / review ──────────────────────────────────────────────────

class CheckinBody(BaseModel):
    checkinId: str


@router.post("/meal-checkin")
async def notify_meal_checkin(body: CheckinBody, caller: dict = Depends(verify_firebase_token)):
    """Athlete submitted a meal photo — notify THEIR coach.

    Caller must be the athlete named on the check-in; the coach is read off the
    same document, so this cannot be used to notify anyone else.
    """
    db = _db()
    snap = db.collection("meal_checkins").document(body.checkinId).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="checkin_not_found")
    c = snap.to_dict() or {}

    if c.get("athleteId") != caller["uid"]:
        raise HTTPException(status_code=403, detail="not_your_checkin")
    coach_id = c.get("coachId")
    if not coach_id:
        return {"success": True, "sent": 0, "detail": "no_coach_on_checkin"}

    athlete_name = c.get("athleteName") or _name_of(db, caller["uid"], "Your athlete")
    meal = c.get("mealName") or c.get("mealType") or "a meal"

    res = notification_service.send(
        db, coach_id,
        f"📸 {athlete_name} submitted a meal",
        f"{meal} — tap to review.",
        category="meal_snap", type="meal_review_pending",
        action="expert_dashboard", priority="high",
        data={
            "type": "meal_review_pending",
            "mealId": body.checkinId,
            "athleteId": caller["uid"],
            "coachingId": caller["uid"],
        },
    )
    return {"success": True, **res}


@router.post("/meal-review")
async def notify_meal_review(body: CheckinBody, caller: dict = Depends(verify_firebase_token)):
    """Coach reviewed a meal — notify the athlete.

    Caller must be the coach named on the check-in; the athlete is read off the
    same document.
    """
    db = _db()
    snap = db.collection("meal_checkins").document(body.checkinId).get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="checkin_not_found")
    c = snap.to_dict() or {}

    if c.get("coachId") != caller["uid"]:
        raise HTTPException(status_code=403, detail="not_your_user")
    athlete_id = c.get("athleteId")
    if not athlete_id:
        return {"success": True, "sent": 0, "detail": "no_athlete_on_checkin"}

    coach_name = c.get("reviewedBy") or _name_of(db, caller["uid"], "Your coach")
    meal = c.get("mealName") or c.get("mealType") or "your meal"
    score = c.get("score")
    detail = f"{coach_name} reviewed {meal}" + (f" — {score}/10." if score is not None else ".")

    res = notification_service.send(
        db, athlete_id,
        "⭐ Meal reviewed",
        detail,
        category="meal_snap", type="meal_review_completed",
        action="diet", priority="high",
        data={
            "type": "meal_review_completed",
            "mealId": body.checkinId,
            "coachingId": athlete_id,
            "coachId": caller["uid"],
        },
    )
    return {"success": True, **res}


# ── Coach published a plan ──────────────────────────────────────────────────

class PlanBody(BaseModel):
    athleteId: str
    kind: str  # 'diet' | 'workout'


@router.post("/plan-updated")
async def notify_plan_updated(body: PlanBody, caller: dict = Depends(verify_firebase_token)):
    """Coach published/modified this athlete's diet or training plan.

    Caller must be the athlete's CURRENT ACTIVE coach — verified against
    personal_coaching/{athleteId}, the same record the Security Rules gate
    coach access on. An ex-coach or unrelated expert is rejected.
    """
    db = _db()
    kind = (body.kind or "").lower()
    if kind not in ("diet", "workout"):
        raise HTTPException(status_code=400, detail="kind_must_be_diet_or_workout")

    rel_snap = db.collection("personal_coaching").document(body.athleteId).get()
    rel = rel_snap.to_dict() if rel_snap.exists else None
    if not rel or rel.get("coachId") != caller["uid"] or rel.get("status") != "active":
        raise HTTPException(status_code=403, detail="not_active_coach_of_user")

    coach_name = rel.get("coachName") or _name_of(db, caller["uid"], "Your coach")
    is_diet = kind == "diet"

    res = notification_service.send(
        db, body.athleteId,
        "🥗 Diet plan updated" if is_diet else "💪 Workout plan updated",
        f"{coach_name} updated your {'diet' if is_diet else 'training'} plan.",
        category="diet" if is_diet else "training",
        type="diet_updated" if is_diet else "workout_updated",
        action="diet" if is_diet else "training",
        priority="high",
        data={
            "type": "diet_updated" if is_diet else "workout_updated",
            "coachingId": body.athleteId,
            "coachId": caller["uid"],
        },
        # One logical update = one notification, even if the coach's save path
        # writes several documents (plan + version snapshot + selections).
        collapse_key=f"plan_{kind}_{body.athleteId}",
    )
    return {"success": True, **res}
