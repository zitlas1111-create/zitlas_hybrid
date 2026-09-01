"""
ZITLAS — what every notification says, in one place
(backend/services/notification_templates.py)

WHY THIS EXISTS
---------------
Notification copy was written inline at each call site, so the wording, the
emoji, the deep-link fields and the priority for a given event were decided in
whichever route happened to raise it. Changing how a meal review reads meant
finding the f-string inside routes/notifications.py; nothing guaranteed two
places that raise the "same" event agreed on anything, and the data payload —
the part the app navigates on — was assembled by hand each time and easy to
get subtly wrong.

A template here owns ONE event end to end: title, body, channel, priority, and
the data keys the client needs to open the right screen. Call sites pass the
facts (who, which meal, what score); the wording lives here.

HOUSE STYLE
-----------
* Title carries the brand and the category: "Zino • Meal Review".
* Body is one sentence in the second person, present tense, and names the
  specific thing — "your Lunch", not "your meal".
* At most one emoji, at the end, as punctuation rather than decoration.
* Never put a raw id in text a person reads.

DATA PAYLOAD
------------
Every FCM data value must be a string — FCM rejects anything else, and the
failure is a 400 on send, not a type error here. `build()` stringifies and
drops empties so a caller cannot accidentally ship `"None"`.

`deepLink` is included as a self-describing route for the client to prefer,
with the individual ids alongside it so an older build (which knows only the
ids) keeps working. Adding a field is safe; RENAMING one silently breaks every
installed app that reads the old name, because old apps are not upgraded by a
backend deploy.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from services import push_service


@dataclass(frozen=True)
class Notification:
    """A fully-resolved notification, ready to hand to notification_service."""

    title: str
    body: str
    type: str
    category: str
    action: str | None = None
    priority: str = "medium"
    data: dict[str, str] = field(default_factory=dict)

    @property
    def channel(self) -> str:
        """The Android channel, derived from `type` — never passed in, so a
        template cannot name a channel the app does not create."""
        return push_service.channel_for(self.type)


def _clean(data: dict[str, Any]) -> dict[str, str]:
    """Stringifies, and drops keys whose value is absent.

    An absent id must be ABSENT, not the string "None": the client tests these
    for presence to decide whether it can deep-link, and "None" is truthy.
    """
    out: dict[str, str] = {}
    for k, v in data.items():
        if v is None:
            continue
        s = str(v).strip()
        if not s or s == "None":
            continue
        out[k] = s
    return out


# ── Meal review ─────────────────────────────────────────────────────────────

#: How much of an expert's comment fits in a notification body before it stops
#: being a preview and starts being the whole message.
COMMENT_PREVIEW_CHARS = 160


def _preview(comment: str) -> str:
    """One-line, length-capped version of an expert's comment.

    Collapsed to a single line because a tray entry has one; cut on a word
    boundary because a preview that ends mid-word reads as corrupted text.
    """
    comment = " ".join((comment or "").split())
    if len(comment) <= COMMENT_PREVIEW_CHARS:
        return comment
    return comment[:COMMENT_PREVIEW_CHARS].rsplit(" ", 1)[0] + "…"


def meal_review_completed(
    *,
    checkin_id: str,
    meal_name: str,
    coach_name: str,
    coach_id: str,
    athlete_id: str,
    rating: float | None = None,
    comment: str | None = None,
    image_url: str | None = None,
) -> Notification:
    """An expert finished reviewing an athlete's meal photo.

    The body leads with the coach and the meal, then the score, then what they
    actually wrote. The comment is included because it is the whole point of
    the notification: a score with no reason for it sends the athlete into the
    app to find out why, which is the trip the notification exists to save.

    It goes in the BODY rather than only in `data` because the body is what
    every platform renders without being asked: web and iOS get it in the FCM
    `notification` block, and on Android the app copies it straight onto the
    notification it draws. Anything that lives ONLY in `data` has to be read
    and placed deliberately by each client, which is how the comment came to
    be delivered but never shown.
    """
    meal = (meal_name or "your meal").strip()
    coach = (coach_name or "Your expert").strip()

    body = f"{coach} reviewed your {meal}"
    if rating is not None:
        body += f" — {float(rating):.1f}⭐"
    body += " 🍽️"

    preview = _preview(comment or "")
    if preview:
        body += f" “{preview}”"

    print(f"[NOTIFY_TEMPLATE] type=meal_review_completed "
          f"expert={coach} rating={rating} meal={meal} "
          f"hasComment={bool(preview)} hasImage={bool(image_url)}")

    return Notification(
        title="Zino • Meal Review",
        body=body,
        type="meal_review_completed",
        category="meal_snap",
        action="diet",
        # An athlete waits for this one; it is not a digest item.
        priority="high",
        data=_clean({
            "type": "meal_review_completed",
            # `mealId` is the name every installed build already reads.
            # `mealCheckinId` is the same value under the clearer name — both
            # are sent so the rename can happen without breaking old apps.
            "mealId": checkin_id,
            "mealCheckinId": checkin_id,
            "coachId": coach_id,
            "expertId": coach_id,
            "athleteId": athlete_id,
            "coachingId": athlete_id,
            "rating": rating,
            # Untruncated — the in-app screen shows the whole comment; only
            # the tray copy above is shortened.
            "comment": (comment or "").strip(),
            "deepLink": f"zitlas://meal-review/{checkin_id}",
            # When the EVENT happened, so the tray entry is timestamped by the
            # review rather than by when the phone happened to receive it —
            # they differ by however long the device was offline or dozing.
            "timestamp": datetime.now(timezone.utc).isoformat(),
            # The meal photo. Android renders it as the notification's large
            # icon collapsed and as a BigPicture expanded, which is the
            # difference between "you have a notification" and something
            # worth opening. Fetched best-effort by the client — a photo that
            # will not load costs the picture, never the notification.
            "imageUrl": image_url,
            # Stable per EVENT. The client uses it as the tray id, so a
            # redelivered push replaces its own entry instead of stacking a
            # second copy of the same review.
            "eventId": f"meal_review_completed_{checkin_id}",
        }),
    )


def meal_review_pending(
    *,
    checkin_id: str,
    meal_name: str,
    athlete_name: str,
    athlete_id: str,
    coach_id: str,
) -> Notification:
    """An athlete sent a meal photo; their expert needs to review it."""
    meal = (meal_name or "a meal").strip()
    who = (athlete_name or "An athlete").strip()

    return Notification(
        title="Zino • Meal Review",
        body=f"{who} sent {meal} for review 📷",
        type="meal_review_pending",
        category="meal_snap",
        action="expert_dashboard",
        priority="high",
        data=_clean({
            "type": "meal_review_pending",
            "mealId": checkin_id,
            "mealCheckinId": checkin_id,
            "athleteId": athlete_id,
            "coachId": coach_id,
            "expertId": coach_id,
            "deepLink": f"zitlas://meal-review/{checkin_id}",
            "eventId": f"meal_review_pending_{checkin_id}",
        }),
    )
