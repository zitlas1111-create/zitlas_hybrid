"""
ZITLAS — FCM push sender (backend/services/push_service.py)

Delivers web-push notifications to the tokens the frontend stores in
users/{uid}.pushTokens (assets/js/push-notifications.js). Uses the FCM
HTTP v1 API with a Firebase service account — google-auth is already a
transitive dependency of google-genai, so no new requirements.

Credential loading (env var names, configuration) lives in
services/google_credentials.py, shared with services/firestore_service.py.

Without credentials every send is a clean no-op that reports
{"configured": false} — nothing in the app depends on push succeeding.
Get the file from Firebase console -> Project settings -> Service
accounts -> Generate new private key.
"""

from __future__ import annotations

from typing import Any

from services.google_credentials import load_credentials, last_error

_PROJECT_ID = "zitlas-b8677"
_FCM_URL = f"https://fcm.googleapis.com/v1/projects/{_PROJECT_ID}/messages:send"
_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


def _load_credentials():
    return load_credentials([_SCOPE])


def is_configured() -> bool:
    return _load_credentials() is not None


def _access_token() -> str:
    import google.auth.transport.requests

    creds = _load_credentials()
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


# Android notification channels. These IDs MUST match the ones the Flutter app
# creates in lib/core/notifications/fcm_service.dart — Android silently DROPS a
# notification whose channel_id does not exist on the device, so a typo here is
# an invisible delivery failure, not an error.
CHANNEL_MESSAGES = "zitlas_messages"
# v2: Android CACHES a channel's importance at creation time, so raising the
# old `zitlas_coaching` channel to high importance would have had no effect on
# any device that already had it — every existing install would have kept the
# silent, no-heads-up behaviour forever. A new id is the only way to change it.
# MUST stay identical to FcmService.channelCoaching in the Flutter app.
CHANNEL_COACHING = "zitlas_coaching_v2"
CHANNEL_MEAL_REVIEWS = "zitlas_meal_reviews"
CHANNEL_PLANS = "zitlas_plans"
CHANNEL_GENERAL = "zitlas_general"

# notification `type` -> channel. Chat is the only HIGH-priority one (it is the
# only type a user expects to interrupt them, like any messaging app).
_TYPE_CHANNELS = {
    "chat_message": CHANNEL_MESSAGES,
    "meal_review_pending": CHANNEL_MEAL_REVIEWS,
    "meal_checkin": CHANNEL_MEAL_REVIEWS,
    "meal_review_completed": CHANNEL_MEAL_REVIEWS,
    "meal_reviewed": CHANNEL_MEAL_REVIEWS,
    "diet_updated": CHANNEL_PLANS,
    "workout_updated": CHANNEL_PLANS,
    "zino_message": CHANNEL_GENERAL,
}


def channel_for(notification_type: str | None) -> str:
    """Channel for a notification type. Anything coaching_* shares one channel
    so a user can mute coaching chatter without losing chat or meal reviews."""
    if not notification_type:
        return CHANNEL_GENERAL
    if notification_type in _TYPE_CHANNELS:
        return _TYPE_CHANNELS[notification_type]
    if notification_type.startswith("coaching") or notification_type.startswith("payment"):
        return CHANNEL_COACHING
    return CHANNEL_GENERAL


# FCM error statuses that mean "this token is permanently dead — stop storing
# it". Anything else (quota, internal, unavailable) is transient and the token
# must be KEPT, or a temporary FCM outage would wipe every user's devices.
_DEAD_TOKEN_STATUSES = {"UNREGISTERED", "INVALID_ARGUMENT", "NOT_FOUND"}


def _is_dead_token(status_code: int, detail: Any) -> bool:
    if status_code not in (400, 404):
        return False
    try:
        err = (detail or {}).get("error", {}) if isinstance(detail, dict) else {}
        if err.get("status") in _DEAD_TOKEN_STATUSES:
            return True
        for d in err.get("details", []) or []:
            if isinstance(d, dict) and d.get("errorCode") in _DEAD_TOKEN_STATUSES:
                return True
    except Exception:
        pass
    return False


#: Notification types that are TIME-CRITICAL and must punch through Doze.
#: A coaching approval the athlete paid for, an expert replying, a review
#: finishing — none of these are useful an hour late.
_HIGH_PRIORITY_TYPES = frozenset({
    "chat_message",
    "coaching_accepted",
    "coaching_started",
    "coaching_request",
    "coaching_rejected",
    "coaching_ended",
    "review_completed",
    "review_complete",
    "expert_request",
    "meal_review_completed",
    "meal_reviewed",
    "diet_updated",
    "workout_updated",
})

#: Caller-supplied priority words that mean "deliver now".
_HIGH_PRIORITY_WORDS = frozenset({"high", "urgent", "critical"})


def is_high_priority(notification_type: str | None,
                     priority: str | None = None) -> bool:
    """Whether this notification is delivered at FCM HIGH priority.

    THE BUG THIS FIXES: this used to be `high = notification_type ==
    "chat_message"`, so EVERY other notification — including a coaching
    approval whose caller explicitly passed `priority="high"` — went out at
    FCM `normal`. Android defers normal-priority messages while the device is
    in Doze or the app is in App Standby and releases them in a batch when the
    device next becomes active, which is why events "only appeared when the
    user opened the app", several at once.

    The caller's own `priority` now decides, with a type allowlist as the
    fallback for callers that never stated one. Genuinely informational
    notifications stay `normal` — high priority is a limited resource and
    marking everything urgent is the same as marking nothing urgent.
    """
    if priority and priority.strip().lower() in _HIGH_PRIORITY_WORDS:
        return True
    return (notification_type or "") in _HIGH_PRIORITY_TYPES


def send_to_token(
    token: str,
    title: str,
    body: str,
    data: dict[str, str] | None = None,
    *,
    notification_type: str | None = None,
    collapse_key: str | None = None,
    priority: str | None = None,
) -> dict[str, Any]:
    """Send one notification to one device token via FCM HTTP v1.

    Returns {ok, status, detail, dead_token}; never raises for delivery
    failures so a dead token in a user's list can't break the loop over their
    devices. `dead_token: True` tells the caller to remove this token (see
    notification_service.send, which prunes them).

    Carries android + apns blocks so the SAME call works for the Flutter app
    and the website: without `android.notification.channel_id` Android 8+
    drops the notification, and without `apns.headers.apns-priority` iOS may
    delay or coalesce it.
    """
    if not is_configured():
        return {"ok": False, "configured": False, "detail": last_error([_SCOPE])}

    import requests

    payload_data = {str(k): str(v) for k, v in (data or {}).items()}
    channel = channel_for(notification_type)
    # The caller's priority is HONOURED here. See is_high_priority().
    high = is_high_priority(notification_type, priority)

    message: dict[str, Any] = {
        "token": token,
        "notification": {"title": title, "body": body},
        # Every value must be a string — FCM rejects non-string data values.
        # The Flutter side reads `type` + the id fields out of this to deep-link
        # (see NotificationRouter.routeFromData).
        "data": payload_data,
        "android": {
            "priority": "high" if high else "normal",
            "notification": {
                "channel_id": channel,
                "sound": "default",
                # Groups multiple messages from the SAME conversation under one
                # entry instead of stacking them (messaging-app behaviour).
                "tag": payload_data.get("chatId") or payload_data.get("collapseKey") or None,
                "click_action": "FLUTTER_NOTIFICATION_CLICK",
            },
        },
        "apns": {
            "headers": {"apns-priority": "10" if high else "5"},
            "payload": {"aps": {"sound": "default", "badge": 1, "thread-id": channel}},
        },
        "webpush": {
            "fcm_options": {"link": payload_data.get("url", "/pages/notifications/notifications.html")},
        },
    }
    # Drop a null tag rather than sending it — FCM rejects explicit nulls.
    if not message["android"]["notification"].get("tag"):
        message["android"]["notification"].pop("tag", None)
    if collapse_key:
        message["android"]["collapse_key"] = collapse_key

    try:
        r = requests.post(
            _FCM_URL,
            headers={"Authorization": f"Bearer {_access_token()}",
                     "Content-Type": "application/json"},
            json={"message": message},
            timeout=15,
        )
        ok = r.status_code == 200
        detail = r.json() if r.headers.get("content-type", "").startswith("application/json") else r.text[:300]
        dead = (not ok) and _is_dead_token(r.status_code, detail)
        if not ok:
            print(f"[PUSH] send failed ({r.status_code}) dead_token={dead}: {str(detail)[:200]}")
        return {"ok": ok, "configured": True, "status": r.status_code,
                "detail": detail, "dead_token": dead}
    except Exception as e:
        print(f"[PUSH] send error: {type(e).__name__}: {e}")
        return {"ok": False, "configured": True, "detail": f"{type(e).__name__}: {e}",
                "dead_token": False}
