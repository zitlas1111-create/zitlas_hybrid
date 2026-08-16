"""
ZITLAS — Admin service (backend/services/admin_service.py)

Shared plumbing for the Admin Portal: the append-only audit trail and the
pagination/serialisation helpers every admin listing endpoint uses.

WHY THIS EXISTS
---------------
`routes/admin.py` already ran privileged mutations behind `require_admin`
(certificate approval, expert approval, expert deactivation, admin grants) —
correctly authorised, but recording NOTHING. There was no way to answer "who
revoked this expert, and when" after the fact. Every mutation now writes an
audit record through `record_audit()`.

The audit collection is deliberately unreachable from any browser client:
`firestore.rules` denies read AND write on `admin_audit_logs` outright, so the
only writer is the Admin SDK (which bypasses rules) and the only reader is
`GET /api/admin/audit-logs` behind `require_admin`. An admin cannot edit or
delete their own trail through the product, which is the entire point of
keeping it.
"""
from __future__ import annotations

import hashlib
import uuid
from datetime import datetime, timezone
from typing import Any, Iterable

from fastapi import HTTPException, Request

from services import firestore_service

AUDIT_COLLECTION = "admin_audit_logs"

# Canonical action names. Kept as constants so a typo becomes an ImportError
# rather than an un-queryable audit row.
ADMIN_GRANTED = "ADMIN_GRANTED"
ADMIN_REVOKED = "ADMIN_REVOKED"
USER_SUSPENDED = "USER_SUSPENDED"
USER_ACTIVATED = "USER_ACTIVATED"
ROLE_CHANGED = "ROLE_CHANGED"
EXPERT_APPROVED = "EXPERT_APPROVED"
EXPERT_REJECTED = "EXPERT_REJECTED"
EXPERT_DEACTIVATED = "EXPERT_DEACTIVATED"
CERT_APPROVED = "CERT_APPROVED"
CERT_REJECTED = "CERT_REJECTED"
VERIFICATION_RECOMPUTED = "VERIFICATION_RECOMPUTED"
REVIEW_REASSIGNED = "REVIEW_REASSIGNED"
WALLET_CREDIT = "WALLET_CREDIT"
WALLET_DEBIT = "WALLET_DEBIT"
SUPPORT_RESOLVED = "SUPPORT_RESOLVED"
BROADCAST_SENT = "BROADCAST_SENT"
COACHING_ENDED = "COACHING_ENDED"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def environment_label() -> str:
    """"PRODUCTION" | "STAGING" | "DEVELOPMENT" — shown persistently in the
    portal header.

    An admin panel that looks identical against prod and a laptop is how
    someone suspends a real account while "just testing". Derived from
    ZITLAS_ENV, defaulting to PRODUCTION: if the deployment has not said
    otherwise, the safe assumption is that the data is real.
    """
    import os
    raw = (os.getenv("ZITLAS_ENV") or "").strip().lower()
    if raw in ("dev", "development", "local"):
        return "DEVELOPMENT"
    if raw in ("stage", "staging", "test"):
        return "STAGING"
    return "PRODUCTION"


def db():
    """The Admin SDK client, or 503 with the configuration reason.

    Never leaks a stack trace — `config_error()` returns a short reason string
    (e.g. "missing FIREBASE_SERVICE_ACCOUNT_JSON"), which is safe to show an
    authenticated admin and useless to anyone else.
    """
    client = firestore_service.get_client()
    if client is None:
        reason = firestore_service.config_error() or "unknown"
        raise HTTPException(status_code=503, detail=f"admin_service_unavailable: {reason}")
    return client


def _client_fingerprint(request: Request | None) -> str | None:
    """A salted, truncated hash of the caller IP — never the IP itself.

    Enough to correlate a burst of actions to one origin during an incident,
    not enough to be a stored location record for an employee.
    """
    if request is None or request.client is None:
        return None
    raw = request.client.host or ""
    if not raw:
        return None
    return hashlib.sha256(f"zitlas-admin:{raw}".encode()).hexdigest()[:16]


def record_audit(
    *,
    admin_uid: str,
    action: str,
    target_uid: str | None = None,
    target_type: str = "user",
    old_value: Any = None,
    new_value: Any = None,
    reason: str | None = None,
    request: Request | None = None,
    extra: dict | None = None,
) -> str:
    """Appends one audit record and returns its id.

    Deliberately BEST-EFFORT: a Firestore failure here must never roll back or
    block the privileged operation the admin actually asked for — a completed
    action with a missing log line is recoverable, a half-applied mutation is
    not. Failures are printed so they surface in the platform logs.
    """
    request_id = uuid.uuid4().hex
    record = {
        "requestId": request_id,
        "adminUid": admin_uid,
        "action": action,
        "targetUid": target_uid,
        "targetType": target_type,
        "oldValue": old_value,
        "newValue": new_value,
        "reason": reason,
        "timestamp": now_iso(),
        "clientFingerprint": _client_fingerprint(request),
    }
    if extra:
        record["extra"] = extra
    try:
        db().collection(AUDIT_COLLECTION).document(request_id).set(record)
    except Exception as e:  # noqa: BLE001 - see docstring
        print(f"[ADMIN AUDIT] FAILED to record {action} by {admin_uid}: {type(e).__name__}: {e}")
    return request_id


# ── Pagination ───────────────────────────────────────────────────────────────

PAGE_SIZES = (20, 50, 100)
MAX_PAGE_SIZE = 100


def clamp_page_size(requested: int | None, default: int = 20) -> int:
    """Never let a caller ask for an unbounded page.

    An admin listing that streams every user into a browser is both a
    performance problem and a needless bulk export of personal data.
    """
    if requested is None:
        return default
    try:
        value = int(requested)
    except (TypeError, ValueError):
        return default
    if value <= 0:
        return default
    return min(value, MAX_PAGE_SIZE)


def paginate(items: list, *, page: int, page_size: int) -> dict:
    """Offset pagination over an already-materialised list.

    Offset rather than cursor because admin listings are small (thousands, not
    millions), need arbitrary page jumps, and must support the composite
    search/filter combinations below which Firestore cannot index. If a
    collection ever outgrows this, the fix is a cursor on a single ordered
    field — not raising [MAX_PAGE_SIZE].
    """
    total = len(items)
    size = max(1, page_size)
    pages = max(1, (total + size - 1) // size)
    current = min(max(1, page), pages)
    start = (current - 1) * size
    return {
        "items": items[start:start + size],
        "page": current,
        "pageSize": size,
        "total": total,
        "totalPages": pages,
    }


def matches_search(haystack: Iterable[Any], needle: str | None) -> bool:
    """Case-insensitive substring match across several fields."""
    if not needle:
        return True
    q = needle.strip().lower()
    if not q:
        return True
    for value in haystack:
        if value is None:
            continue
        if q in str(value).lower():
            return True
    return False


# ── Safe serialisation ───────────────────────────────────────────────────────

# Fields that must NEVER reach the admin browser, even for an authenticated
# admin. An admin needs to administer accounts, not read secrets out of them.
_REDACTED_KEYS = {
    "fcmToken", "fcmTokens", "deviceTokens", "password", "passwordHash",
    "razorpaySignature", "razorpay_signature", "keySecret", "apiKey",
    "api_key", "serviceAccount", "privateKey", "private_key", "refreshToken",
    "idToken", "customToken", "secret",
}


def redact(data: dict | None) -> dict:
    """Strips credential-ish fields from a Firestore document.

    Applied to every document the admin API returns. The point is not that an
    admin is untrusted — it is that a browser tab, a screenshare, or a logged
    HTTP response is a much worse place for a device token or a payment
    signature than the database it came from.
    """
    if not data:
        return {}
    return {k: v for k, v in data.items() if k not in _REDACTED_KEYS}


def doc_to_dict(doc) -> dict:
    """A Firestore snapshot as a redacted plain dict, with its id attached."""
    data = redact(doc.to_dict() or {})
    data["id"] = doc.id
    return data
