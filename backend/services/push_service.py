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
#
# WHY EVERY ID CARRIES A VERSION SUFFIX. Android FREEZES a channel's importance
# and its sound at creation time and an app may never raise either afterwards
# — that restriction is the point of channels, so a user's own choices cannot
# be overridden. Giving these channels the ZITLAS tone therefore could not be
# done by editing them: every existing install would have kept the stock
# Android sound forever. A new id is the only mechanism that exists.
CHANNEL_MESSAGES = "zitlas_messages_v2"
# Bumped to v2 once already, to raise importance from default to high (a
# coaching approval was not producing a heads-up banner); v3 adds the tone.
CHANNEL_COACHING = "zitlas_coaching_v3"
CHANNEL_MEAL_REVIEWS = "zitlas_meal_reviews_v2"
CHANNEL_PLANS = "zitlas_plans_v2"
CHANNEL_GENERAL = "zitlas_general_v2"

#: The ZITLAS notification tone, `android/app/src/main/res/raw/zitlas_tone.wav`
#: in the Flutter app, named WITHOUT its extension (both Android resource
#: lookup and FCM refer to it that way).
#:
#: MUST stay identical to `FcmService.soundResource`. If this names a resource
#: the installed APK does not contain, Android falls back to the default sound
#: — quiet degradation, not an error, so a typo here would never be reported.
#:
#: NOTE this only affects devices BELOW Android 8. From 8 onward the channel's
#: own sound wins and this field is ignored, which is exactly why the channel
#: ids above had to change.
SOUND_ANDROID = "zitlas_tone"

#: Notification small icon, `res/drawable/ic_stat_zitlas.xml` in the app.
#: Android reduces a small icon to its ALPHA channel and re-tints it, so this
#: must name the monochrome drawable and never the launcher icon — an opaque
#: square renders as a featureless white blob. The manifest declares the same
#: resource as the default; sending it explicitly means a notification does
#: not depend on that meta-data surviving a manifest edit.
#: MUST stay identical to the icon name in FcmService.
ICON_ANDROID = "ic_stat_zitlas"

#: ZITLAS green — the tint Android fills the icon silhouette with, and the
#: accent on the shade entry. Must equal @color/zitlas_notification in the
#: app's colors.xml and FcmService._brandColor.
BRAND_COLOR = "#16A34A"

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
    platform: str | None = None,
    renders_own: bool = False,
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

    # ANDROID DRAWS ITS OWN NOTIFICATIONS.
    #
    # A message carrying a `notification` block is rendered by the FCM SDK
    # itself whenever the app is backgrounded or terminated — the app never
    # sees it, and cannot style it. Those are exactly the two states in which
    # anyone actually looks at the tray, so every bit of ZITLAS identity the
    # Flutter side applies (expanded text, the meal photo, the brand colour,
    # grouping) was being applied ONLY in the foreground, where the user is
    # already looking at the app. That is why the notification kept coming out
    # looking like a stock Android one no matter what was configured.
    #
    # Sending Android a DATA-ONLY message moves rendering into the app for
    # every state. `zitlasFirebaseMessagingBackgroundHandler` draws it through
    # flutter_local_notifications, which is the same code path the foreground
    # already used — so there is now exactly ONE renderer on Android and the
    # duplicate-notification risk disappears structurally rather than by
    # being carefully avoided.
    #
    # Web and iOS KEEP the notification block: the website's service worker
    # reads `payload.notification`, and iOS has no equivalent background
    # rendering hook. Per-token platform comes from the device registry.
    # BOTH conditions, not just the platform. `renders_own` is what the
    # DEVICE declared when it registered (fcm_service.dart
    # `rendersOwnNotifications`). A build that predates FcmService.render
    # cannot draw a data-only message — its background handler only logs — so
    # sending one would produce no notification at all. A backend deploy does
    # not upgrade anyone's phone, so assuming the capability from the platform
    # alone would silence every user who has not updated the app.
    android_native = (platform or "").lower() == "android" and renders_own

    message: dict[str, Any] = {
        "token": token,
        # Every value must be a string — FCM rejects non-string data values.
        # The Flutter side reads `type` + the id fields out of this to deep-link
        # (see NotificationRouter.routeFromData). On Android it ALSO reads the
        # title/body from here, because there is no notification block to read
        # them from.
        "data": ({**payload_data, "title": title, "body": body}
                 if android_native else payload_data),
        "android": {
            "priority": "high" if high else "normal",
            "notification": {
                "channel_id": channel,
                "sound": SOUND_ANDROID,
                # THE OS DRAWS THIS ONE ITSELF. When the app is backgrounded or
                # closed no Dart runs, so everything the notification looks
                # like has to be in this block. The Flutter side sets the same
                # four on the notification it draws in the foreground, or the
                # same event would look like two different apps.
                "icon": ICON_ANDROID,
                "color": BRAND_COLOR,
                # Readable on the lock screen. Safe because the BODY is
                # deliberately non-sensitive — notification_templates.py keeps
                # it to a meal name, a coach's display name and their
                # feedback. That constraint is what lets this be public.
                "visibility": "PUBLIC",
                # Distinct from android.priority above: that one governs
                # DELIVERY (whether it punches through Doze), this one governs
                # PRESENTATION (whether it peeks as a heads-up banner). Both
                # are needed for a time-critical notification to actually
                # interrupt; setting only the first delivers it silently into
                # the shade.
                "notification_priority": "PRIORITY_HIGH" if high else "PRIORITY_DEFAULT",
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

    if android_native:
        # DATA-ONLY. No `notification` block anywhere in the message, or the
        # FCM SDK draws it itself and the app never gets the chance.
        #
        # `priority: high` is not optional here: a NORMAL-priority data message
        # is held by Doze until the next maintenance window, so the app would
        # not wake to draw anything and the notification would arrive minutes
        # or hours late. A notification-message would still have displayed.
        # This is the one thing data-only genuinely costs, and high priority is
        # what buys it back.
        message["android"] = {"priority": "high"}
        if collapse_key:
            message["android"]["collapse_key"] = collapse_key
        # The channel is chosen by the APP for a data message, but it is sent
        # anyway so a future client can honour a server-side override without
        # a new field, and so the log below can state which channel this
        # notification belongs to.
        message["data"]["channelId"] = channel
        message["data"]["androidChannelId"] = channel
    else:
        message["notification"] = {"title": title, "body": body}
        # Drop a null tag rather than sending it — FCM rejects explicit nulls.
        if not message["android"]["notification"].get("tag"):
            message["android"]["notification"].pop("tag", None)
        if collapse_key:
            message["android"]["collapse_key"] = collapse_key

    print(f"[FCM] dataOnly={str(android_native).lower()} channel={channel} "
          f"priority={'high' if high else 'normal'} "
          f"platform={platform or 'unknown'} "
          f"renderer={'app' if android_native else 'fcm'}")

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
