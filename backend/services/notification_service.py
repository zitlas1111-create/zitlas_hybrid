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

    # Current registry — the authoritative source. Keyed BY TOKEN, so a device
    # can only ever belong to one account at a time: signing in re-registers
    # the same document under the new uid.
    # Tokens deliberately NOT targeted, with the reason. Reported per send so
    # "this user has 5 tokens but got 1 notification" is explainable from the
    # log alone rather than looking like lost delivery.
    skipped: list[tuple[str, str]] = []

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

    # Legacy website array (assets/js/push-notifications.js writes only here).
    #
    # A TOKEN IN THIS ARRAY IS NOT PROOF OF A SESSION. The array is append-only
    # in practice, so it keeps a token after the device signs out or signs into
    # a DIFFERENT account — and it is per-user, so the same physical device can
    # sit in two accounts' arrays at once. Found in production: an expert's
    # users/{uid}.pushTokens still listed a token that device_tokens showed was
    # by then owned by a different athlete, so that athlete's phone would have
    # received the expert's private notifications.
    #
    # device_tokens is therefore consulted as the OWNER OF RECORD: the registry
    # decides, always. A token in the array is targeted ONLY when the registry
    # confirms this uid is signed in on it.
    #
    # A TOKEN WITH NO REGISTRY ROW IS NOT TARGETED. It used to be, on the
    # grounds that website devices only ever wrote the array — but the website
    # now registers in `device_tokens` too (assets/js/push-notifications.js
    # storeToken), so both clients populate it and "no row" no longer means
    # "web". It means a device that has not opened ZITLAS since that shipped:
    # an old token, kept alive by an append-only array that nothing prunes.
    # Delivering to those is precisely the "5 historical tokens, 1 real
    # device" behaviour. They self-heal the moment that browser or app opens
    # again, which re-registers it.
    try:
        snap = db.collection("users").document(user_id).get()
        for token in ((snap.to_dict() or {}).get("pushTokens") or []):
            if not token or token in out:
                continue
            owner_uid, owner_enabled, status = _registry_owner(db, token)
            if status == REGISTRY_UNAVAILABLE:
                # Could not find out. Deliver — a Firestore blip must not read
                # as "everyone signed out", and the worst case is one extra
                # notification to a device that was probably still valid.
                out[token] = "legacy"
                continue
            if status == REGISTRY_ABSENT:
                skipped.append((token, "unregistered_device"))
                continue
            if owner_uid != user_id:
                skipped.append((token, "owned_by_another_account"))
                continue
            if owner_enabled is False:
                skipped.append((token, "signed_out"))
                continue
            # Registry-confirmed and active, but only listed in the array —
            # the `enabled == True` query above should already have found it.
            out[token] = "registry"
    except Exception as e:
        print(f"[NOTIFY] pushTokens lookup failed uid={user_id}: {type(e).__name__}: {e}")

    for token, why in skipped:
        print(f"[NOTIFY] skipped uid={user_id} token={_short(token)} reason={why}")

    return list(out.items())


def _short(token: str) -> str:
    """First 12 characters of a token. Enough to correlate two log lines,
    never enough to send with — a full FCM token is a credential, and anyone
    holding it can push to that device."""
    return token if len(token) <= 12 else token[:12] + "…"


def _fcm_error_code(detail: Any) -> str:
    """The machine-readable status out of an FCM error body.

    FCM buries the useful part (UNREGISTERED, SENDER_ID_MISMATCH,
    THIRD_PARTY_AUTH_ERROR) two levels down and returns a long human sentence
    at the top level; logging the sentence is what made these failures look
    interchangeable."""
    if not isinstance(detail, dict):
        return "unknown"
    err = detail.get("error")
    if not isinstance(err, dict):
        return "unknown"
    for d in err.get("details", []) or []:
        if isinstance(d, dict) and d.get("errorCode"):
            return str(d["errorCode"])
    return str(err.get("status") or "unknown")


#: `_registry_owner` outcomes. "absent" and "unavailable" MUST stay distinct:
#: absent is a fact about the device (nobody has registered it), unavailable is
#: a fact about Firestore (we could not find out). They were once the same
#: value, which was harmless while an unknown token was delivered to anyway —
#: and became a silent outage the moment absence started skipping the token.
REGISTRY_FOUND = "found"
REGISTRY_ABSENT = "absent"
REGISTRY_UNAVAILABLE = "unavailable"


def _registry_owner(db, token: str) -> tuple[str | None, bool | None, str]:
    """(uid, enabled, status) from `device_tokens/{token}`.

    The registry is keyed by token, so this is the single answer to "who is
    signed in on this device right now".

    `status` is REGISTRY_ABSENT when the document genuinely is not there, and
    REGISTRY_UNAVAILABLE when the read itself failed. The caller treats the
    first as "not an active device" and the second as "assume active" — a
    Firestore blip must not look like every user signing out at once.
    """
    try:
        doc = db.collection("device_tokens").document(token).get()
        if not doc or not getattr(doc, "exists", False):
            return None, None, REGISTRY_ABSENT
        data = doc.to_dict() or {}
        return data.get("uid"), data.get("enabled"), REGISTRY_FOUND
    except Exception as e:
        print(f"[NOTIFY] registry ownership check failed: {type(e).__name__}: {e}")
        return None, None, REGISTRY_UNAVAILABLE


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

    # NO VERIFIED DEVICE = NOTHING TO SEND. Said explicitly rather than as a
    # bare tokens=0, because "nobody is signed in on any device" and "the push
    # failed" look identical in a log otherwise.
    if not tokens:
        print(f"[NOTIFY] type={type or 'general'} uid={user_id} "
              f"activeDevices=0 tokensTargeted=0 sent=0 failed=0 "
              f"staleTokensRemoved=0 reason=no_active_authenticated_session")
        return {"sent": 0, "failed": 0, "tokens": 0,
                "reason": "no_active_authenticated_session"}

    registry = sum(1 for _, src in tokens if src == "registry")
    sent = failed = stale_removed = 0
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
            # WHY it failed, not just that it did. A bare failed=1 is the
            # difference between "this phone uninstalled the app" and "the
            # service account lost its FCM scope" — the same number for a
            # dead device and a total outage. Logged per token because a
            # partial failure across a user's devices is the interesting case.
            print(f"[NOTIFY] delivery failed uid={user_id} "
                  f"source={source} token={_short(token)} "
                  f"status={res.get('status')} "
                  f"code={_fcm_error_code(res.get('detail'))} "
                  f"dead={bool(res.get('dead_token'))}")
            if res.get("dead_token"):
                # FCM says this token is permanently gone (UNREGISTERED /
                # NOT_FOUND) — the app was uninstalled or its data cleared.
                # Removing it here is what stops a dead device being retried
                # on every single send, forever.
                _prune_token(db, user_id, token, source)
                stale_removed += 1
    # Every number the on-call question needs, in one line: how many devices
    # this account is actually signed in on, how many were addressed, how it
    # went, and how many dead ones were dropped on the way. `activeDevices`
    # and `tokensTargeted` are equal now that the registry is authoritative —
    # a gap between them would mean a targeting bug, so both are printed.
    print(f"[NOTIFY] type={type or 'general'} uid={user_id} "
          f"activeDevices={registry} tokensTargeted={len(tokens)} "
          f"sent={sent} failed={failed} staleTokensRemoved={stale_removed} "
          f"fcmPriority={'high' if push_service.is_high_priority(type, priority) else 'normal'}")
    return {"sent": sent, "failed": failed, "tokens": len(tokens),
            "activeDevices": registry, "staleTokensRemoved": stale_removed}


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
