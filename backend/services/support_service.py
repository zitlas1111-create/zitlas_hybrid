"""
ZITLAS — Support / Help Center service (backend/services/support_service.py)

The ONE place that knows how a Help Center conversation is stored, how it is
emailed to the ZITLAS support inbox, and how a reply typed in that inbox finds
its way back into the athlete's in-app chat.

    athlete types in Help Center
        -> POST /api/support/... (routes/support.py, Firebase-authenticated)
        -> conversation + message written here (Admin SDK)
        -> SMTP mail to SUPPORT_INBOX, subject carries [ZITLAS SUPPORT #<cid>]
    support hits Reply in the ZITLAS Gmail
        -> the reply lands back in that same mailbox (we send From==To==inbox,
           so Reply goes to the inbox itself, never to the athlete)
        -> ingest_replies() (APScheduler) reads it over IMAP, recovers <cid>,
           appends senderType="support"
        -> athlete sees it in-app and gets an FCM push

WHY IMAP AND NOT THE GMAIL API: SUPPORT_EMAIL_PASSWORD is a Gmail app
password, which authenticates SMTP *and* IMAP. The Gmail API would need an
OAuth client, a consent flow, a stored refresh token and a public webhook —
four new moving parts for the same result. Nothing here needs a new
dependency: imaplib/smtplib are stdlib and APScheduler already runs the
coaching sweeps.

CREDENTIAL POSTURE — the password is read from os.environ inside the two
send/fetch functions and is never returned, logged, stored on a document or
attached to an exception. _redact() scrubs it out of any SMTP/IMAP error text
before that text is allowed near a log line, because smtplib and imaplib both
quote the failing command back at you.

THREADING IS NOT EMAIL-ADDRESS MATCHING. A reply is bound to a conversation by
the [ZITLAS SUPPORT #<conversationId>] token in the subject, backed up by the
RFC-5322 In-Reply-To/References ids we recorded when we sent. The sender
address is never used to *pick* a conversation — one athlete may have several,
and a forwarded or aliased reply would otherwise land in the wrong thread or
silently open a new one.
"""

from __future__ import annotations

import email
import email.utils
import imaplib
import os
import re
import smtplib
import time
import traceback
from datetime import datetime, timedelta, timezone
from email.header import decode_header, make_header
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from typing import Any

# ── Collections ───────────────────────────────────────────────────────────────
CONVERSATIONS = "support_conversations"
MESSAGES      = "messages"
# Message-Id -> conversation. Doubles as the idempotency ledger for ingestion:
# an id present here has already been accounted for (either it is mail WE sent,
# or a reply we already imported), so ingest can never double-post.
EMAIL_INDEX   = "support_email_index"

# ── Status machine ────────────────────────────────────────────────────────────
STATUS_OPEN                = "OPEN"
STATUS_IN_PROGRESS         = "IN_PROGRESS"
STATUS_WAITING_FOR_USER    = "WAITING_FOR_USER"
STATUS_WAITING_FOR_SUPPORT = "WAITING_FOR_SUPPORT"
STATUS_RESOLVED            = "RESOLVED"

VALID_STATUSES = {
    STATUS_OPEN, STATUS_IN_PROGRESS, STATUS_WAITING_FOR_USER,
    STATUS_WAITING_FOR_SUPPORT, STATUS_RESOLVED,
}

SENDER_USER    = "user"
SENDER_SUPPORT = "support"

MAX_MESSAGE_CHARS = 5000

# The support mailbox. A module constant, never client-supplied — a request
# must not be able to redirect ZITLAS support mail to an attacker's address.
SUPPORT_INBOX = (os.environ.get("SUPPORT_INBOX") or "zitlas1111@gmail.com").strip()

SMTP_HOST = os.environ.get("SUPPORT_SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("SUPPORT_SMTP_PORT", "587"))

# Socket timeout for EVERY SMTP operation, in seconds.
#
# This must stay comfortably below the mobile client's 30s request timeout
# (mobile/lib/core/config/env.dart -> Env.apiTimeout), because a request that
# outlives the client is indistinguishable from a dead server: the athlete sees
# TimeoutException and no error message at all.
#
# The version that shipped called `smtplib.SMTP(host, port)` with NO timeout
# argument. Python then falls back to the global default socket timeout, which
# is None — meaning "block forever". On a host whose outbound SMTP ports are
# filtered, the TCP connect never completes and never errors, so the request
# hung until the client gave up. Measured on production: 120s with no response.
SMTP_TIMEOUT = float(os.environ.get("SUPPORT_SMTP_TIMEOUT", "12"))
IMAP_HOST = os.environ.get("SUPPORT_IMAP_HOST", "imap.gmail.com")
IMAP_PORT = int(os.environ.get("SUPPORT_IMAP_PORT", "993"))
IMAP_FOLDER = os.environ.get("SUPPORT_IMAP_FOLDER", "INBOX")
INGEST_LOOKBACK_DAYS = int(os.environ.get("SUPPORT_IMAP_LOOKBACK_DAYS", "7"))

# Subject token. Group 1 is the conversation id.
SUBJECT_TAG_RE = re.compile(r"\[ZITLAS SUPPORT #([A-Za-z0-9_-]{4,64})\]")

# Header stamped on everything we originate, so an operator reading raw source
# in Gmail can tell machine mail from a human reply at a glance.
OUTBOUND_HEADER = "X-Zitlas-Support"


def subject_tag(conversation_id: str) -> str:
    return f"[ZITLAS SUPPORT #{conversation_id}]"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── Credentials (server-side only) ────────────────────────────────────────────

def _credentials() -> tuple[str, str]:
    """(sender, password) from the environment.

    Gmail shows app passwords to humans in four 4-char groups; those spaces are
    display sugar. Stripping them is not cosmetic — passing the spaced form to
    login() makes Gmail reject an otherwise-correct secret, which presents as
    an unexplained 535 and sends you hunting for the wrong bug.
    """
    sender   = (os.environ.get("SUPPORT_EMAIL") or "").strip()
    password = (os.environ.get("SUPPORT_EMAIL_PASSWORD") or "").replace(" ", "").strip()
    return sender, password


def is_configured() -> bool:
    sender, password = _credentials()
    return bool(sender and password)


def _redact(text: str) -> str:
    """Scrub the app password (spaced or unspaced) out of arbitrary text.

    smtplib and imaplib both put the offending command — which contains the
    secret — into the exception they raise. Every except block that touches
    such a message routes it through here first, so a credential cannot reach
    a log aggregator by riding along inside a stack trace.
    """
    raw = os.environ.get("SUPPORT_EMAIL_PASSWORD") or ""
    out = text or ""
    for variant in {raw, raw.replace(" ", ""), raw.strip()}:
        if variant and len(variant) >= 6:
            out = out.replace(variant, "***REDACTED***")
    return out


# ── Firestore helpers ─────────────────────────────────────────────────────────

def _conv_ref(db, conversation_id: str):
    return db.collection(CONVERSATIONS).document(conversation_id)


def _messages_ref(db, conversation_id: str):
    return _conv_ref(db, conversation_id).collection(MESSAGES)


def get_conversation(db, conversation_id: str) -> dict[str, Any] | None:
    snap = _conv_ref(db, conversation_id).get()
    if not snap or not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    data["id"] = conversation_id
    return data


def owns(conversation: dict[str, Any] | None, uid: str) -> bool:
    """Ownership predicate behind every non-admin route. Deliberately total:
    a missing conversation, a missing uid or a missing userId is never an
    owner, so a caller cannot reach another athlete's thread by guessing an id
    that does not exist yet."""
    if not conversation or not uid:
        return False
    return bool(conversation.get("userId")) and conversation.get("userId") == uid


def new_conversation_id(db) -> str:
    """Mint a conversation id WITHOUT writing anything.

    Firestore allocates document ids client-side, so we can put the id in the
    email subject and only commit the conversation once the mail has actually
    been accepted. That is what lets /contact be send-first: a failed send
    leaves no orphan conversation behind.
    """
    return db.collection(CONVERSATIONS).document().id


def create_conversation(db, *, uid: str, user_name: str, user_email: str,
                        subject: str, category: str = "",
                        conversation_id: str | None = None) -> str:
    """Open a conversation and return its id.

    The Firestore auto-id IS the email threading token, so there is exactly one
    identifier to keep in sync between the database and the mailbox. Pass
    `conversation_id` to commit an id previously minted by
    new_conversation_id().
    """
    ref = (db.collection(CONVERSATIONS).document(conversation_id)
           if conversation_id else db.collection(CONVERSATIONS).document())
    ts = now_iso()
    ref.set({
        "userId":          uid,
        "userName":        user_name,
        "userEmail":       user_email,
        "subject":         subject,
        "category":        category,
        "status":          STATUS_WAITING_FOR_SUPPORT,
        "createdAt":       ts,
        "updatedAt":       ts,
        "lastMessageAt":   ts,
        "lastMessageBy":   SENDER_USER,
        "lastMessageText": "",
        "unreadByUser":    0,
        "unreadBySupport": 0,
    })
    return ref.id


def add_message(db, conversation_id: str, *, sender_type: str, sender_id: str,
                message: str, email_message_id: str = "",
                email_thread_id: str = "") -> str:
    """Append one message and roll the parent's denormalised summary + status
    forward in the same call.

    The parent carries lastMessage*/unread* so the conversation LIST costs one
    read per conversation instead of one per conversation plus a subcollection
    query — the list is the first screen both clients open.
    """
    if sender_type not in (SENDER_USER, SENDER_SUPPORT):
        raise ValueError(f"invalid sender_type: {sender_type}")

    ts = now_iso()
    msg_ref = _messages_ref(db, conversation_id).document()
    msg_ref.set({
        "senderType":     sender_type,
        "senderId":       sender_id,
        "message":        message,
        "createdAt":      ts,
        "emailMessageId": email_message_id,
        "emailThreadId":  email_thread_id,
        # Whichever side spoke has implicitly read their own message.
        "readByUser":     sender_type == SENDER_USER,
        "readBySupport":  sender_type == SENDER_SUPPORT,
    })

    conv = get_conversation(db, conversation_id) or {}
    patch: dict[str, Any] = {
        "updatedAt":       ts,
        "lastMessageAt":   ts,
        "lastMessageBy":   sender_type,
        "lastMessageText": message[:180],
    }
    if sender_type == SENDER_USER:
        patch["status"] = STATUS_WAITING_FOR_SUPPORT
        patch["unreadBySupport"] = int(conv.get("unreadBySupport") or 0) + 1
    else:
        patch["status"] = STATUS_WAITING_FOR_USER
        patch["unreadByUser"] = int(conv.get("unreadByUser") or 0) + 1

    _conv_ref(db, conversation_id).update(patch)
    return msg_ref.id


def list_messages(db, conversation_id: str, limit: int = 200) -> list[dict[str, Any]]:
    """Whole thread, oldest first. Sorted in Python rather than by order_by so
    the same code path works against the Admin SDK and the test fake; a support
    thread is bounded by `limit` and never large enough for that to matter."""
    out: list[dict[str, Any]] = []
    for snap in _messages_ref(db, conversation_id).limit(limit).stream():
        row = snap.to_dict() or {}
        row["id"] = snap.id
        out.append(row)
    out.sort(key=lambda r: r.get("createdAt") or "")
    return out


def list_conversations_for_user(db, uid: str, limit: int = 50) -> list[dict[str, Any]]:
    from google.cloud.firestore_v1.base_query import FieldFilter
    q = db.collection(CONVERSATIONS).where(filter=FieldFilter("userId", "==", uid)).limit(limit)
    out: list[dict[str, Any]] = []
    for snap in q.stream():
        row = snap.to_dict() or {}
        row["id"] = snap.id
        out.append(row)
    out.sort(key=lambda r: r.get("lastMessageAt") or "", reverse=True)
    return out


def list_all_conversations(db, limit: int = 100,
                           status: str | None = None) -> list[dict[str, Any]]:
    """Admin/support view — every athlete's conversation, newest activity
    first. Only ever reached through require_admin."""
    from google.cloud.firestore_v1.base_query import FieldFilter
    col = db.collection(CONVERSATIONS)
    q = col.where(filter=FieldFilter("status", "==", status)).limit(limit) if status \
        else col.limit(limit)
    out: list[dict[str, Any]] = []
    for snap in q.stream():
        row = snap.to_dict() or {}
        row["id"] = snap.id
        out.append(row)
    out.sort(key=lambda r: r.get("lastMessageAt") or "", reverse=True)
    return out


def mark_read(db, conversation_id: str, *, by: str) -> None:
    """Zero one side's unread counter. The per-message flags are updated
    best-effort behind it; the parent counter is what the badge reads."""
    field = "unreadByUser" if by == SENDER_USER else "unreadBySupport"
    _conv_ref(db, conversation_id).update({field: 0})

    flag  = "readByUser" if by == SENDER_USER else "readBySupport"
    other = SENDER_SUPPORT if by == SENDER_USER else SENDER_USER
    for snap in _messages_ref(db, conversation_id).limit(200).stream():
        row = snap.to_dict() or {}
        if row.get("senderType") == other and not row.get(flag):
            snap.reference.update({flag: True})


def set_status(db, conversation_id: str, status: str) -> None:
    if status not in VALID_STATUSES:
        raise ValueError(f"invalid status: {status}")
    _conv_ref(db, conversation_id).update({"status": status, "updatedAt": now_iso()})


# ── Email index (threading + idempotency) ─────────────────────────────────────

def _index_key(message_id: str) -> str:
    """Firestore document ids may not contain '/'. Message-Ids are arbitrary
    text, so hash-free sanitisation keeps them readable while staying legal."""
    return re.sub(r"[^A-Za-z0-9_.@-]", "_", (message_id or "").strip("<> "))[:400]


def remember_email(db, message_id: str, conversation_id: str, direction: str) -> None:
    if not message_id:
        return
    db.collection(EMAIL_INDEX).document(_index_key(message_id)).set({
        "conversationId": conversation_id,
        "direction":      direction,          # "outbound" | "inbound"
        "createdAt":      now_iso(),
    })


def lookup_email(db, message_id: str) -> dict[str, Any] | None:
    if not message_id:
        return None
    snap = db.collection(EMAIL_INDEX).document(_index_key(message_id)).get()
    if not snap or not getattr(snap, "exists", False):
        return None
    return snap.to_dict() or {}


# ── Outbound mail ─────────────────────────────────────────────────────────────

def build_support_email(*, conversation_id: str, user_name: str, user_email: str,
                        uid: str, subject: str, category: str, message: str,
                        sender: str, message_id: str,
                        in_reply_to: str = "") -> MIMEMultipart:
    """The notification that lands in the ZITLAS support inbox.

    From AND To are both the support inbox. That is the whole trick behind
    requirement "the user must not need their personal Gmail": pressing Reply
    in Gmail answers the From address, so the reply comes back to us for
    ingestion instead of going to the athlete. Reply-To is set to the inbox as
    well so a client that prefers Reply-To cannot route around it.

    The athlete's real address is still shown in the BODY, so a human can
    escalate deliberately — it is simply never a header a Reply would follow.
    """
    msg = MIMEMultipart("alternative")
    msg["Subject"]  = f"{subject_tag(conversation_id)} {subject}"
    msg["From"]     = sender
    msg["To"]       = SUPPORT_INBOX
    msg["Reply-To"] = SUPPORT_INBOX
    msg["Message-ID"] = message_id
    msg[OUTBOUND_HEADER] = "outbound"
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
        msg["References"]  = in_reply_to

    plain = (
        "ZITLAS Support Request\n"
        "======================\n\n"
        f"User:\n{user_name}\n\n"
        f"Email:\n{user_email}\n\n"
        f"UID:\n{uid}\n\n"
        f"Conversation ID:\n{conversation_id}\n\n"
        f"Category:\n{category}\n\n"
        f"Message:\n{message}\n\n"
        "----------------------------------------------------------\n"
        "Reply to this email and your reply appears in the athlete's\n"
        "ZITLAS Help Center chat. Keep the subject line intact — the\n"
        f"{subject_tag(conversation_id)} tag is what routes it back.\n"
    )

    def esc(v: str) -> str:
        return (str(v).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

    html = f"""\
<html>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
             background:#0A0A0A;color:#FFFFFF;margin:0;padding:32px 16px;">
  <div style="max-width:560px;margin:0 auto;background:#141414;
              border:1px solid #262626;border-radius:16px;overflow:hidden;">
    <div style="background:#FF8A00;padding:20px 28px;">
      <h1 style="margin:0;font-size:20px;font-weight:800;color:#fff;
                 letter-spacing:1px;">ZITLAS</h1>
      <p style="margin:4px 0 0;font-size:13px;color:rgba(255,255,255,0.85);">
        Support Request
      </p>
    </div>
    <div style="padding:24px 28px;">
      <table style="width:100%;border-collapse:collapse;">
        <tr><td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:12px;
            font-weight:600;color:#666;text-transform:uppercase;width:130px;">User</td>
            <td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:14px;
            color:#fff;">{esc(user_name)}</td></tr>
        <tr><td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:12px;
            font-weight:600;color:#666;text-transform:uppercase;">Email</td>
            <td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:14px;
            color:#FF8A00;">{esc(user_email)}</td></tr>
        <tr><td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:12px;
            font-weight:600;color:#666;text-transform:uppercase;">UID</td>
            <td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:13px;
            color:#B5B5B5;font-family:monospace;">{esc(uid)}</td></tr>
        <tr><td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:12px;
            font-weight:600;color:#666;text-transform:uppercase;">Conversation ID</td>
            <td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:13px;
            color:#B5B5B5;font-family:monospace;">{esc(conversation_id)}</td></tr>
        <tr><td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:12px;
            font-weight:600;color:#666;text-transform:uppercase;">Category</td>
            <td style="padding:9px 0;border-bottom:1px solid #1e1e1e;font-size:14px;
            color:#fff;">{esc(category)}</td></tr>
      </table>
      <div style="margin-top:20px;">
        <p style="font-size:12px;font-weight:600;color:#666;text-transform:uppercase;
                  margin:0 0 10px;">Message</p>
        <div style="background:#0f0f0f;border:1px solid #2a2a2a;border-radius:10px;
                    padding:16px;font-size:14px;color:#B5B5B5;line-height:1.7;
                    white-space:pre-wrap;">{esc(message)}</div>
      </div>
    </div>
    <div style="padding:16px 28px;border-top:1px solid #1e1e1e;font-size:11.5px;
                color:#666;text-align:center;line-height:1.6;">
      <strong style="color:#FF8A00;">Reply to this email</strong> and your reply
      appears in the athlete's ZITLAS Help Center chat.<br>
      Keep the subject line intact — <code>{esc(subject_tag(conversation_id))}</code>
      is what routes it back.
    </div>
  </div>
</body>
</html>
"""
    msg.attach(MIMEText(plain, "plain", "utf-8"))
    msg.attach(MIMEText(html, "html", "utf-8"))
    return msg


def send_support_email(*, conversation_id: str, user_name: str, user_email: str,
                       uid: str, subject: str, category: str, message: str,
                       in_reply_to: str = "") -> str:
    """Deliver one notification to the support inbox. Returns the Message-ID
    so the caller can record it for threading. Raises on failure — the caller
    decides whether that should fail the request (it should not: the athlete's
    message is already safely stored)."""
    sender, password = _credentials()
    if not sender or not password:
        raise RuntimeError("SUPPORT_EMAIL or SUPPORT_EMAIL_PASSWORD not set in environment.")

    message_id = email.utils.make_msgid(domain="zitlas.com")
    msg = build_support_email(
        conversation_id=conversation_id, user_name=user_name, user_email=user_email,
        uid=uid, subject=subject, category=category, message=message,
        sender=sender, message_id=message_id, in_reply_to=in_reply_to,
    )

    # Staged timing, so a hang can be attributed to an exact operation instead
    # of guessing. Every line is safe to keep in production: no credential, no
    # message body, just the stage and how long it took.
    t0 = time.monotonic()

    def _mark(stage: str) -> None:
        print(f"[SUPPORT] {stage}  (+{time.monotonic() - t0:.2f}s)")

    _mark(f"SMTP connection starting -> {SMTP_HOST}:{SMTP_PORT} "
          f"timeout={SMTP_TIMEOUT}s")
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=SMTP_TIMEOUT) as server:
            _mark("SMTP connection established")
            server.ehlo()
            server.starttls()
            server.ehlo()
            _mark("SMTP TLS negotiated")
            server.login(sender, password)
            _mark("SMTP authentication successful")
            server.sendmail(sender, [SUPPORT_INBOX], msg.as_string())
            _mark("email send completed")
    except Exception as exc:
        _mark(f"SMTP FAILED: {type(exc).__name__}")
        raise RuntimeError(_redact(f"{type(exc).__name__}: {exc}")) from None

    return message_id


# ── Inbound mail ──────────────────────────────────────────────────────────────

_QUOTE_MARKERS = (
    re.compile(r"^\s*On .+ wrote:\s*$", re.MULTILINE),
    re.compile(r"^-+\s*Original Message\s*-+\s*$", re.MULTILINE | re.IGNORECASE),
    re.compile(r"^-+\s*Forwarded message\s*-+\s*$", re.MULTILINE | re.IGNORECASE),
    re.compile(r"^\s*From:\s.+$", re.MULTILINE),
)


def extract_reply_text(body: str) -> str:
    """Keep only what the human just typed.

    Gmail appends the entire quoted history under an "On <date> ... wrote:"
    line. Without this the athlete would see their own message, the HTML
    footer and every prior turn pasted back at them on every single reply.
    """
    text = (body or "").replace("\r\n", "\n").replace("\r", "\n")

    cut = len(text)
    for pattern in _QUOTE_MARKERS:
        m = pattern.search(text)
        if m and m.start() < cut:
            cut = m.start()
    text = text[:cut]

    # Drop residual quoted lines and Gmail's "> " prefixes.
    kept = [ln for ln in text.split("\n") if not ln.lstrip().startswith(">")]
    return "\n".join(kept).strip()[:MAX_MESSAGE_CHARS]


def _decode_header(raw: str | None) -> str:
    if not raw:
        return ""
    try:
        return str(make_header(decode_header(raw)))
    except Exception:
        return str(raw)


def _body_text(msg: email.message.Message) -> str:
    """Prefer text/plain; fall back to stripping tags off text/html. Skips
    attachments so a screenshot can never be mistaken for message text."""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and \
               "attachment" not in str(part.get("Content-Disposition") or ""):
                try:
                    return part.get_payload(decode=True).decode(
                        part.get_content_charset() or "utf-8", errors="replace")
                except Exception:
                    continue
        for part in msg.walk():
            if part.get_content_type() == "text/html":
                try:
                    html = part.get_payload(decode=True).decode(
                        part.get_content_charset() or "utf-8", errors="replace")
                    return re.sub(r"<[^>]+>", " ", html)
                except Exception:
                    continue
        return ""
    try:
        payload = msg.get_payload(decode=True)
        if payload is None:
            return str(msg.get_payload())
        text = payload.decode(msg.get_content_charset() or "utf-8", errors="replace")
        if msg.get_content_type() == "text/html":
            text = re.sub(r"<[^>]+>", " ", text)
        return text
    except Exception:
        return ""


def resolve_conversation_id(db, *, subject: str, in_reply_to: str,
                            references: str) -> str | None:
    """Which ZITLAS conversation does this email belong to?

    Order matters. The subject tag is checked FIRST because it survives
    forwarding, mobile clients that drop References, and a support agent who
    composes a fresh mail with the tag pasted in. In-Reply-To/References are
    the fallback for a client that rewrites the subject.

    Returns None when neither yields an id — the caller must then skip the
    message rather than guess, since guessing means leaking one athlete's
    support reply into another athlete's chat.
    """
    m = SUBJECT_TAG_RE.search(subject or "")
    if m:
        return m.group(1)

    for header in (in_reply_to, references):
        for token in re.findall(r"<[^>]+>", header or ""):
            hit = lookup_email(db, token)
            if hit and hit.get("conversationId"):
                return hit["conversationId"]
    return None


def ingest_replies(db=None, *, limit: int = 50) -> dict[str, Any]:
    """Poll the support mailbox and import any support replies.

    Idempotent by construction: every Message-Id we have already accounted for
    lives in EMAIL_INDEX (outbound ones written at send time, inbound ones
    written here), and anything found there is skipped. That is what makes it
    safe to run on a timer and safe to re-run after a crash — it does not rely
    on the \\Seen flag, which Gmail sets inconsistently for mail you send to
    yourself.

    Returns a summary dict for logging/tests. Never raises: a mailbox outage
    must not take down the scheduler.
    """
    from services import firestore_service

    summary: dict[str, Any] = {"scanned": 0, "imported": 0, "skipped": 0, "errors": 0}

    db = db or firestore_service.get_client()
    if db is None:
        summary["error"] = "firestore_unavailable"
        return summary

    sender, password = _credentials()
    if not sender or not password:
        summary["error"] = "not_configured"
        return summary

    conn = None
    try:
        conn = imaplib.IMAP4_SSL(IMAP_HOST, IMAP_PORT)
        conn.login(sender, password)
        conn.select(IMAP_FOLDER)

        since = (datetime.now(timezone.utc) - timedelta(days=INGEST_LOOKBACK_DAYS)) \
            .strftime("%d-%b-%Y")
        typ, data = conn.search(None, 'SUBJECT', '"ZITLAS SUPPORT"', 'SINCE', since)
        if typ != "OK":
            summary["error"] = "search_failed"
            return summary

        ids = (data[0] or b"").split()[-limit:]
        for num in ids:
            summary["scanned"] += 1
            try:
                typ, raw = conn.fetch(num, "(RFC822)")
                if typ != "OK" or not raw or not raw[0]:
                    summary["errors"] += 1
                    continue

                msg = email.message_from_bytes(raw[0][1])
                message_id = (msg.get("Message-ID") or "").strip()

                # Already accounted for — our own outbound, or a reply we
                # imported on an earlier pass.
                if message_id and lookup_email(db, message_id):
                    summary["skipped"] += 1
                    continue

                # Anything we stamped is machine mail, never a human reply.
                if (msg.get(OUTBOUND_HEADER) or "").strip():
                    if message_id:
                        remember_email(db, message_id, "", "outbound")
                    summary["skipped"] += 1
                    continue

                # Only the support mailbox may author a support reply. Without
                # this, anyone who can get a mail with the tag into the inbox
                # could post into an athlete's chat as ZITLAS.
                from_addr = email.utils.parseaddr(_decode_header(msg.get("From")))[1].lower()
                if from_addr != SUPPORT_INBOX.lower() and from_addr != sender.lower():
                    summary["skipped"] += 1
                    continue

                subject = _decode_header(msg.get("Subject"))
                cid = resolve_conversation_id(
                    db, subject=subject,
                    in_reply_to=msg.get("In-Reply-To") or "",
                    references=msg.get("References") or "",
                )
                if not cid:
                    summary["skipped"] += 1
                    continue

                conv = get_conversation(db, cid)
                if not conv:
                    summary["skipped"] += 1
                    continue

                text = extract_reply_text(_body_text(msg))
                if not text:
                    summary["skipped"] += 1
                    continue

                add_message(db, cid, sender_type=SENDER_SUPPORT,
                            sender_id="zitlas_support", message=text,
                            email_message_id=message_id,
                            email_thread_id=(msg.get("References") or "").strip())
                if message_id:
                    remember_email(db, message_id, cid, "inbound")

                _notify_user_of_reply(db, conv, cid, text)
                summary["imported"] += 1

            except Exception as exc:
                summary["errors"] += 1
                print(f"[SUPPORT] ingest failed for one message: "
                      f"{_redact(f'{type(exc).__name__}: {exc}')}")

    except Exception as exc:
        summary["errors"] += 1
        summary["error"] = _redact(f"{type(exc).__name__}: {exc}")
        print(f"[SUPPORT] IMAP poll failed: {summary['error']}")
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
            try:
                conn.logout()
            except Exception:
                pass

    if summary["imported"]:
        print(f"[SUPPORT] ingest: {summary['imported']} reply/replies imported "
              f"({summary['scanned']} scanned, {summary['skipped']} skipped)")
    return summary


def _notify_user_of_reply(db, conv: dict[str, Any], cid: str, text: str) -> None:
    """FCM + in-app notification, deep-linked at the conversation.

    Best-effort on purpose: a push that fails must not roll back a reply that
    is already stored, because the athlete will still see it the moment they
    open Help Center.
    """
    try:
        from services import notification_service
        notification_service.send(
            db, conv.get("userId") or "",
            "ZITLAS Support replied",
            text[:140],
            category="support",
            type="support_reply",
            action="open_support_conversation",
            action_id=cid,
            priority="high",
            data={"conversationId": cid},
            collapse_key=f"support_{cid}",
        )
    except Exception as exc:
        print(f"[SUPPORT] reply notification failed (non-fatal): "
              f"{_redact(f'{type(exc).__name__}: {exc}')}")
