"""
ZITLAS — Centralized notification service (backend/services/notification_service.py)

THE single place that turns a ZITLAS event into (a) a persisted notification
document and (b) real FCM push delivery to every device the user has.

WHY THIS EXISTS: `push_service.send_to_token()` (raw FCM transport) has existed
for a long time, but the ONLY caller was routes/system.py's manual test
endpoint. Meanwhile `coaching_service.notify()` wrote a Firestore
`notifications` doc and stopped there. So every real ZITLAS event — coaching
accepted, meal reviewed, plan updated — produced an in-app list entry and NO
push: nothing ever reached a locked phone. This module joins the two halves,
once, so no route has to know anything about FCM.

DEVICE TOKENS — two sources, read together:
  * `device_tokens/{fcmToken}` — the current per-device registry, keyed BY THE
    TOKEN ITSELF. That key choice is deliberate and is what makes account
    switching safe: a physical device has one token, so the doc can only ever
    name ONE owning uid. When account B signs in on a device that was account
    A's, the SAME doc is overwritten with uid=B, and A's token list no longer
    contains it — A's notifications can never again be delivered there. A
    uid-keyed subcollection could not guarantee that (A's stale copy would
    survive and keep receiving).
  * `users/{uid}.pushTokens` — the legacy array the website's
    push-notifications.js still writes. Read for backwards compatibility so a
    web-only device keeps working; pruned in place when a token dies.

NEVER RAISES. A notification is always strictly additive to the event that
triggered it: a coaching relationship must not fail to activate because FCM
was unreachable. Every failure is logged and swallowed.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from services import push_service


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _tokens_for_user(db, user_id: str) -> list[tuple[str, str]]:
    """Every live token for `user_id` as (token, source) pairs, de-duplicated.

    `source` is 'registry' (device_tokens) or 'legacy' (users.pushTokens) so
    _prune_token knows where to remove a dead one from.
    """
    out: dict[str, str] = {}

    # Current registry — the authoritative source.
    try:
        q = (db.collection("device_tokens")
               .where("uid", "==", user_id)
               .where("enabled", "==", True))
        for doc in q.stream():
            token = (doc.to_dict() or {}).get("fcmToken") or doc.id
            if token:
                out.setdefault(token, "registry")
    except Exception as e:
        print(f"[NOTIFY] device_tokens lookup failed uid={user_id}: {type(e).__name__}: {e}")

    # Legacy website array.
    try:
        snap = db.collection("users").document(user_id).get()
        for token in ((snap.to_dict() or {}).get("pushTokens") or []):
            if token:
                out.setdefault(token, "legacy")
    except Exception as e:
        print(f"[NOTIFY] pushTokens lookup failed uid={user_id}: {type(e).__name__}: {e}")

    return list(out.items())


def _prune_token(db, user_id: str, token: str, source: str) -> None:
    """Remove a token FCM told us is permanently dead (UNREGISTERED /
    INVALID_ARGUMENT). Only ever called for those statuses — a transient FCM
    error must never delete a real device."""
    try:
        if source == "registry":
            db.collection("device_tokens").document(token).delete()
        else:
            from google.cloud import firestore as gcf
            db.collection("users").document(user_id).update(
                {"pushTokens": gcf.ArrayRemove([token])})
        print(f"[NOTIFY] pruned dead token uid={user_id} source={source}")
    except Exception as e:
        print(f"[NOTIFY] prune failed uid={user_id}: {type(e).__name__}: {e}")


def persist(db, user_id: str, *, title: str, message: str, category: str = "general",
            type: str | None = None, action: str | None = None,
            action_id: str | None = None, priority: str = "medium",
            notification_id: str | None = None) -> str | None:
    """Write the in-app notification document ONLY (no push).

    Shape is byte-for-byte the one assets/js/notification-center.js's send()
    writes, so the website's notification centre and the Flutter
    NotificationsScreen render server-sent notifications identically to
    client-sent ones. Returns the id, or None on failure.
    """
    if not user_id:
        return None
    notif_id = notification_id or ("notif_" + uuid.uuid4().hex[:20])
    try:
        db.collection("notifications").document(notif_id).set({
            "notificationId": notif_id, "userId": user_id,
            "title": title, "message": message or "",
            "category": category, "icon": None, "type": type,
            "action": action, "actionId": action_id, "expertId": None,
            "isRead": False, "priority": priority,
            "createdAt": _now_iso(),
        })
        return notif_id
    except Exception as e:
        print(f"[NOTIFY] persist failed uid={user_id}: {type(e).__name__}: {e}")
        return None


def push_only(db, user_id: str, *, title: str, body: str,
              type: str | None = None, data: dict[str, Any] | None = None,
              collapse_key: str | None = None,
              priority: str | None = None) -> dict[str, Any]:
    """FCM delivery ONLY (no persisted document) to all of `user_id`'s devices.

    Used for high-volume events that must not spam the notification centre —
    chat messages, where the conversation itself is already the record.
    """
    if not user_id:
        return {"sent": 0, "failed": 0, "tokens": 0}

    payload = {str(k): str(v) for k, v in (data or {}).items() if v is not None}
    payload.setdefault("type", type or "general")

    tokens = _tokens_for_user(db, user_id)
    sent = failed = 0
    for token, source in tokens:
        res = push_service.send_to_token(
            token, title, body, payload,
            notification_type=type, collapse_key=collapse_key,
            # FORWARDED, not dropped. `send()`'s callers pass priority="high"
            # for time-critical events; it used to reach only the Firestore
            # document and never the push itself.
            priority=priority,
        )
        if res.get("ok"):
            sent += 1
        else:
            failed += 1
            if res.get("dead_token"):
                _prune_token(db, user_id, token, source)
    print(f"[NOTIFY] push type={type} uid={user_id} tokens={len(tokens)} "
          f"sent={sent} failed={failed} "
          f"fcmPriority={'high' if push_service.is_high_priority(type, priority) else 'normal'}")
    return {"sent": sent, "failed": failed, "tokens": len(tokens)}


def send(db, user_id: str, title: str, message: str, *,
         category: str = "general", type: str | None = None,
         action: str | None = None, action_id: str | None = None,
         priority: str = "medium", data: dict[str, Any] | None = None,
         persist_doc: bool = True, collapse_key: str | None = None) -> dict[str, Any]:
    """Persist the notification AND push it to every device. The one function
    every route/service should call.

    `data` becomes the FCM payload the app deep-links from. `type`, `action`
    and `actionId` are always injected so the Flutter NotificationRouter and
    the website's navigateForAction() can resolve a destination from the push
    alone — without having to re-read Firestore first.
    """
    if not user_id:
        return {"ok": False, "reason": "no_user"}

    notif_id = persist(
        db, user_id, title=title, message=message, category=category,
        type=type, action=action, action_id=action_id, priority=priority,
    ) if persist_doc else None

    payload: dict[str, Any] = dict(data or {})
    payload.setdefault("type", type or "general")
    if action:
        payload.setdefault("action", action)
    if action_id:
        payload.setdefault("actionId", action_id)
    if notif_id:
        payload.setdefault("notificationId", notif_id)

    result = push_only(db, user_id, title=title, body=message, type=type,
                       data=payload, collapse_key=collapse_key,
                       priority=priority)
    return {"ok": True, "notificationId": notif_id, **result}
