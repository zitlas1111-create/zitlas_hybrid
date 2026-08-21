"""
ZITLAS — Support / Help Center routes (backend/routes/support.py)

  POST   /api/support/contact                        open a conversation (first message)
  GET    /api/support/conversations                  my conversations
  GET    /api/support/conversations/{cid}            one conversation (mine)
  GET    /api/support/conversations/{cid}/messages   full history (mine)
  POST   /api/support/conversations/{cid}/messages   my reply, stays in-thread
  POST   /api/support/conversations/{cid}/read       clear my unread badge
  GET    /api/support/admin/conversations            every conversation (admin)
  GET    /api/support/admin/conversations/{cid}/messages   history (admin)
  POST   /api/support/admin/ingest                   force an IMAP poll (admin)

EVERY route is Firebase-authenticated. The previous version was not, which
meant name/email/UID were whatever the client posted and any anonymous caller
on the internet could push mail through the ZITLAS SMTP account.

IDENTITY COMES FROM THE VERIFIED TOKEN, NOT THE BODY. `uid` and `email` are
read off the decoded Firebase token; the request body cannot influence them.
A display name may still be supplied because tokens often lack one, but it is
cosmetic and never used for authorisation.

SEND FIRST, THEN STORE. A 2xx from this module means the support inbox has
actually accepted the mail — never merely that we tried.

This reverses an earlier store-first design. Store-first protected the
athlete's text when SMTP was down, but it returned {"success": true} for a
message no human would ever receive, and the UI showed "sent" on top of that.
An undelivered message that LOOKS delivered is worse than a visible failure,
because nobody retries it.

The conversation id is minted without a write (new_conversation_id), used in
the subject, and only committed once smtplib has accepted the message. So a
failed send leaves no orphan conversation, and a retry does not pile up
duplicate threads.

The trade-off, stated plainly: if Gmail is unreachable the athlete must retry.
_delivery_error() gives them a specific reason rather than a generic failure.
"""

from __future__ import annotations

import asyncio
import os
import traceback
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator

from services import firestore_service, support_service
from services.auth_service import require_admin, verify_firebase_token

router = APIRouter()

# Hard ceiling on the whole outbound-mail step, in seconds.
#
# smtplib's own socket timeout covers a single blocking operation; this covers
# the SEQUENCE (connect + TLS + auth + send), so no combination of slow stages
# can push the response past the mobile client's 30s budget. Whatever happens,
# this endpoint answers — with a real error the athlete can read — rather than
# leaving the request hanging until the client raises TimeoutException.
SEND_DEADLINE_SECONDS = float(os.environ.get("SUPPORT_SEND_DEADLINE", "20"))


async def _send_with_deadline(**kwargs) -> str:
    """Run the blocking SMTP send off the event loop, under a hard deadline.

    asyncio.wait_for cannot kill the worker thread — the thread unwinds on its
    own socket timeout shortly after. What it DOES guarantee is that the
    client gets an answer on time, which is the property that was missing.
    """
    try:
        return await asyncio.wait_for(
            asyncio.to_thread(support_service.send_support_email, **kwargs),
            timeout=SEND_DEADLINE_SECONDS,
        )
    except asyncio.TimeoutError:
        raise RuntimeError(
            f"TimeoutError: outbound mail exceeded {SEND_DEADLINE_SECONDS:.0f}s "
            f"(connect/TLS/auth/send to {support_service.SMTP_HOST}:"
            f"{support_service.SMTP_PORT} did not complete)"
        ) from None


def _db():
    db = firestore_service.get_client()
    if db is None:
        raise HTTPException(status_code=503, detail="database_unavailable")
    return db


def _strip(v: Any) -> Any:
    return v.strip() if isinstance(v, str) else v


class ContactRequest(BaseModel):
    """`email` is accepted for backward compatibility with the existing form
    payloads but is deliberately IGNORED — the address on the verified token
    wins, so a caller cannot attach their ticket to somebody else's address."""
    name:     str = Field(default="", max_length=120)
    email:    str = Field(default="", max_length=200)
    subject:  str = Field(..., min_length=1, max_length=200)
    category: str = Field(default="General", max_length=100)
    message:  str = Field(..., min_length=1, max_length=support_service.MAX_MESSAGE_CHARS)

    _clean = field_validator("name", "email", "subject", "category", "message",
                             mode="before")(lambda cls, v: _strip(v))


class ReplyRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=support_service.MAX_MESSAGE_CHARS)

    _clean = field_validator("message", mode="before")(lambda cls, v: _strip(v))


def _load_owned(db, cid: str, caller: dict) -> dict[str, Any]:
    """Fetch a conversation and prove the caller owns it.

    A conversation that does not exist and one owned by somebody else both
    answer 404 — never 403 — so the endpoint cannot be used to probe which
    conversation ids are real.
    """
    conv = support_service.get_conversation(db, cid)
    if not support_service.owns(conv, caller.get("uid") or ""):
        raise HTTPException(status_code=404, detail="conversation_not_found")
    return conv  # type: ignore[return-value]


def _delivery_error(exc: Exception) -> HTTPException:
    """Turn an SMTP failure into an honest, actionable, STRUCTURED HTTP error.

    The response body is always
        {"detail": {"message", "code", "stage", "hint"}}
    so the client can show the operator a real diagnosis instead of "something
    went wrong", and can branch on `code` without string-matching prose.

    The FULL traceback is printed server-side; only the classified summary
    crosses the network. support_service._redact() has already scrubbed the app
    password out of `exc` before it reaches here — smtplib quotes the failing
    AUTH command (secret included) straight back at you, so this is the one
    place that must never be relaxed.
    """
    text = str(exc)
    lowered = text.lower()

    # Always keep the complete exception server-side, redacted.
    print("[SUPPORT] ================ EMAIL DELIVERY FAILED ================")
    print(f"[SUPPORT] exception: {type(exc).__name__}: {text}")
    print(support_service._redact(traceback.format_exc()))
    print("[SUPPORT] ========================================================")

    def _err(status: int, code: str, message: str, hint: str) -> HTTPException:
        print(f"[SUPPORT] classified as {code} -> HTTP {status}")
        return HTTPException(
            status_code=status,
            detail={"message": message, "code": code,
                    "stage": "smtp_send", "hint": hint},
        )

    if "not set in environment" in lowered:
        return _err(
            503, "smtp_not_configured",
            "Support email is not configured on the server.",
            "SUPPORT_EMAIL and/or SUPPORT_EMAIL_PASSWORD are missing from the "
            "backend environment. Set both (Render dashboard in production, "
            "backend/.env locally) and restart.",
        )

    if ("smtpauthenticationerror" in lowered or "535" in text
            or "badcredentials" in lowered or "username and password not accepted" in lowered):
        return _err(
            502, "smtp_auth_failed",
            "Gmail rejected the ZITLAS mail credentials (SMTP 535).",
            "SUPPORT_EMAIL_PASSWORD is not a valid Gmail App Password for "
            "SUPPORT_EMAIL. Turn ON 2-Step Verification, generate a new 16-"
            "character app password at "
            "https://myaccount.google.com/apppasswords, and update the "
            "variable in BOTH backend/.env and the Render dashboard.",
        )

    if "smtprecipientsrefused" in lowered or "smtpsenderrefused" in lowered:
        return _err(
            502, "smtp_address_refused",
            "Gmail refused the sender or recipient address.",
            f"Check SUPPORT_EMAIL and the SUPPORT_INBOX constant "
            f"({support_service.SUPPORT_INBOX}).",
        )

    if any(k in lowered for k in
           ("timeout", "timed out", "exceeded", "connection refused", "gaierror",
            "getaddrinfo", "network is unreachable", "socket")):
        return _err(
            504, "smtp_unreachable",
            "Could not reach the Gmail SMTP server.",
            f"The backend could not complete an SMTP exchange with "
            f"{support_service.SMTP_HOST}:{support_service.SMTP_PORT} within "
            f"{SEND_DEADLINE_SECONDS:.0f}s. The usual cause on a hosted "
            "platform is outbound SMTP (port 587/465/25) being filtered — "
            "the connect neither completes nor errors. Check the [SUPPORT] "
            "stage logs to see exactly which operation stalled.",
        )

    return _err(
        502, "smtp_send_failed",
        f"The mail server rejected the message ({type(exc).__name__}).",
        "The full exception and traceback are in the backend logs, tagged "
        "[SUPPORT].",
    )


@router.post("/contact")
async def contact_support(data: ContactRequest,
                          caller: dict = Depends(verify_firebase_token)):
    """Open a conversation. Answers 2xx ONLY once the mail is truly accepted."""
    print(f"[SUPPORT] request received  uid={caller.get('uid')} "
          f"category={data.category!r} subject_len={len(data.subject)} "
          f"message_len={len(data.message)}")
    db = _db()
    uid   = caller.get("uid") or ""
    email = (caller.get("email") or data.email or "").strip()
    name  = (data.name or caller.get("name") or "ZITLAS User").strip()
    print("[SUPPORT] validation complete")

    # Minted, not written — see the module docstring.
    cid = support_service.new_conversation_id(db)

    try:
        message_id = await _send_with_deadline(
            conversation_id=cid, user_name=name, user_email=email, uid=uid,
            subject=data.subject, category=data.category, message=data.message,
        )
    except Exception as exc:
        raise _delivery_error(exc) from None

    # Delivered. Only now does the conversation exist.
    support_service.create_conversation(
        db, uid=uid, user_name=name, user_email=email,
        subject=data.subject, category=data.category, conversation_id=cid,
    )
    support_service.add_message(
        db, cid, sender_type=support_service.SENDER_USER,
        sender_id=uid, message=data.message,
        email_message_id=message_id,
    )
    support_service.remember_email(db, message_id, cid, "outbound")

    print(f"[SUPPORT] response returned  conversationId={cid} emailed=True")
    return {
        "success": True,
        "conversationId": cid,
        "emailed": True,
        "message": "Your message has been sent successfully. Thank you for "
                   "contacting ZITLAS — our team will get back to you soon.",
    }


@router.get("/conversations")
async def my_conversations(caller: dict = Depends(verify_firebase_token)):
    db = _db()
    return {"conversations": support_service.list_conversations_for_user(
        db, caller.get("uid") or "")}


@router.get("/conversations/{cid}")
async def one_conversation(cid: str, caller: dict = Depends(verify_firebase_token)):
    return {"conversation": _load_owned(_db(), cid, caller)}


@router.get("/conversations/{cid}/messages")
async def conversation_messages(cid: str,
                                caller: dict = Depends(verify_firebase_token)):
    db = _db()
    conv = _load_owned(db, cid, caller)
    return {"conversation": conv, "messages": support_service.list_messages(db, cid)}


@router.post("/conversations/{cid}/messages")
async def reply_in_conversation(cid: str, data: ReplyRequest,
                                caller: dict = Depends(verify_firebase_token)):
    """The athlete's follow-up. Reuses the SAME conversation and threads the
    outbound mail onto the original via In-Reply-To, so Gmail keeps one thread
    per conversation instead of opening a new one per message."""
    db = _db()
    conv = _load_owned(db, cid, caller)
    uid = caller.get("uid") or ""

    prior = [m for m in support_service.list_messages(db, cid)
             if m.get("emailMessageId")]
    in_reply_to = prior[0]["emailMessageId"] if prior else ""

    try:
        message_id = await _send_with_deadline(
            conversation_id=cid,
            user_name=conv.get("userName") or "ZITLAS User",
            user_email=conv.get("userEmail") or (caller.get("email") or ""),
            uid=uid, subject=conv.get("subject") or "Support",
            category=conv.get("category") or "General",
            message=data.message, in_reply_to=in_reply_to,
        )
    except Exception as exc:
        raise _delivery_error(exc) from None

    support_service.add_message(
        db, cid, sender_type=support_service.SENDER_USER,
        sender_id=uid, message=data.message, email_message_id=message_id,
    )
    support_service.remember_email(db, message_id, cid, "outbound")

    return {"success": True, "conversationId": cid, "emailed": True}


@router.post("/conversations/{cid}/read")
async def mark_conversation_read(cid: str,
                                 caller: dict = Depends(verify_firebase_token)):
    db = _db()
    _load_owned(db, cid, caller)
    support_service.mark_read(db, cid, by=support_service.SENDER_USER)
    return {"success": True}


# ── Admin / support side (read-only; replies happen in Gmail) ─────────────────

@router.get("/admin/conversations")
async def admin_conversations(limit: int = 100, status: str | None = None,
                              caller: dict = Depends(require_admin)):
    db = _db()
    return {"conversations": support_service.list_all_conversations(
        db, limit=min(limit, 300), status=status)}


@router.get("/admin/conversations/{cid}/messages")
async def admin_conversation_messages(cid: str, caller: dict = Depends(require_admin)):
    db = _db()
    conv = support_service.get_conversation(db, cid)
    if not conv:
        raise HTTPException(status_code=404, detail="conversation_not_found")
    return {"conversation": conv, "messages": support_service.list_messages(db, cid)}


@router.get("/admin/email-health")
async def admin_email_health(caller: dict = Depends(require_admin)):
    """Does outbound support email actually work right now?

    Performs a real SMTP login and disconnects WITHOUT sending anything, so it
    is safe to call repeatedly. Returns only booleans and a coarse reason —
    never the credential, and never Gmail's raw response (which quotes the
    failing AUTH command straight back at you).
    """
    def _probe() -> dict:
        import smtplib

        sender, password = support_service._credentials()
        if not sender or not password:
            return {"configured": False, "canSend": False,
                    "reason": "SUPPORT_EMAIL / SUPPORT_EMAIL_PASSWORD not set"}
        try:
            with smtplib.SMTP(support_service.SMTP_HOST,
                              support_service.SMTP_PORT, timeout=20) as srv:
                srv.ehlo(); srv.starttls(); srv.ehlo()
                srv.login(sender, password)
            return {"configured": True, "canSend": True, "reason": "ok"}
        except smtplib.SMTPAuthenticationError:
            return {
                "configured": True, "canSend": False,
                "reason": "gmail_rejected_credentials",
                "fix": "Regenerate the app password at "
                       "https://myaccount.google.com/apppasswords (2-Step "
                       "Verification must be ON) and update "
                       "SUPPORT_EMAIL_PASSWORD.",
            }
        except Exception as exc:
            return {"configured": True, "canSend": False,
                    "reason": type(exc).__name__}

    result = await asyncio.to_thread(_probe)
    result["inbox"] = support_service.SUPPORT_INBOX
    result["sender"] = support_service._credentials()[0] or None
    return result


@router.post("/admin/ingest")
async def admin_force_ingest(caller: dict = Depends(require_admin)):
    """Manual IMAP poll — lets an operator pull a reply in immediately instead
    of waiting for the scheduler tick."""
    return await asyncio.to_thread(support_service.ingest_replies)
