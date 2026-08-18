"""
ZITLAS — Help Center support conversation tests (backend/tests/test_support.py)

Covers the full loop: athlete opens a conversation -> it is stored -> the
support inbox is emailed with a conversation id -> support replies in Gmail
-> the reply is ingested over IMAP into the SAME conversation -> the athlete
is notified -> nobody else can read any of it.

NO REAL EMAIL IS EVER SENT. Every test either monkeypatches
support_service.send_support_email / smtplib.SMTP, or drives ingestion through
_ingest_one() with a locally-constructed message. imaplib is never contacted.
"""

from __future__ import annotations

import email.utils
import os
import sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient  # noqa: E402

from services import support_service  # noqa: E402
from services.auth_service import require_admin, verify_firebase_token  # noqa: E402
import routes.support as support_routes  # noqa: E402


ATHLETE = {"uid": "athlete_1", "email": "athlete@example.com", "name": "Test Athlete",
           "admin": False, "expert": False, "email_verified": True}
OTHER   = {"uid": "athlete_2", "email": "other@example.com", "name": "Other Athlete",
           "admin": False, "expert": False, "email_verified": True}
ADMIN   = {"uid": "admin_1", "email": "admin@zitlas.com", "name": "Admin",
           "admin": True, "expert": False, "email_verified": True}


@pytest.fixture
def db():
    return FakeClient()


@pytest.fixture
def sent(monkeypatch):
    """Capture outbound mail instead of sending it. Returns the list of
    kwargs each send_support_email call received."""
    calls: list[dict] = []

    def _fake_send(**kwargs):
        calls.append(kwargs)
        return email.utils.make_msgid(domain="zitlas.com")

    monkeypatch.setattr(support_service, "send_support_email", _fake_send)
    return calls


def make_app(db, caller=ATHLETE):
    app = FastAPI()
    app.include_router(support_routes.router, prefix="/api/support")
    app.dependency_overrides[verify_firebase_token] = lambda: caller
    app.dependency_overrides[require_admin] = lambda: (
        caller if caller.get("admin") else pytest.fail("require_admin let a non-admin through")
    )
    monkey = getattr(support_routes, "firestore_service")
    monkey.get_client = lambda: db  # type: ignore[assignment]
    return TestClient(app)


@pytest.fixture(autouse=True)
def _restore_firestore():
    original = support_routes.firestore_service.get_client
    yield
    support_routes.firestore_service.get_client = original


def open_conversation(client, subject="Diet plan help",
                      message="Hello, I need help with my diet plan."):
    res = client.post("/api/support/contact", json={
        "name": "Test Athlete", "email": "athlete@example.com",
        "subject": subject, "category": "Diet", "message": message,
    })
    assert res.status_code == 200, res.text
    return res.json()


def _ingest_one(db, *, subject, body, from_addr=None, message_id=None,
                in_reply_to="", notify=None):
    """Drive one message through the exact parsing/threading/persistence path
    ingest_replies() uses, without touching imaplib."""
    from_addr = from_addr or support_service.SUPPORT_INBOX
    message_id = message_id or email.utils.make_msgid(domain="zitlas.com")

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = from_addr
    msg["To"] = support_service.SUPPORT_INBOX
    msg["Message-ID"] = message_id
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
    msg.attach(MIMEText(body, "plain", "utf-8"))

    if message_id and support_service.lookup_email(db, message_id):
        return None
    if (msg.get(support_service.OUTBOUND_HEADER) or "").strip():
        return None
    sender_addr = email.utils.parseaddr(msg["From"])[1].lower()
    if sender_addr != support_service.SUPPORT_INBOX.lower():
        return None

    cid = support_service.resolve_conversation_id(
        db, subject=subject, in_reply_to=in_reply_to, references="")
    if not cid:
        return None
    conv = support_service.get_conversation(db, cid)
    if not conv:
        return None

    text = support_service.extract_reply_text(body)
    if not text:
        return None

    support_service.add_message(db, cid, sender_type=support_service.SENDER_SUPPORT,
                                sender_id="zitlas_support", message=text,
                                email_message_id=message_id)
    support_service.remember_email(db, message_id, cid, "inbound")
    if notify is not None:
        notify(conv, cid, text)
    return cid


# ── 1-2. Conversation is created and the message is stored ───────────────────

def test_user_creates_conversation_and_message_is_stored(db, sent):
    client = make_app(db)
    body = open_conversation(client)

    cid = body["conversationId"]
    assert cid and body["success"] is True

    conv = support_service.get_conversation(db, cid)
    assert conv["userId"] == ATHLETE["uid"]
    assert conv["status"] == support_service.STATUS_WAITING_FOR_SUPPORT
    assert conv["unreadBySupport"] == 1

    messages = support_service.list_messages(db, cid)
    assert len(messages) == 1
    assert messages[0]["senderType"] == "user"
    assert messages[0]["message"] == "Hello, I need help with my diet plan."


# ── 3-4. The support email is sent and carries the conversation id ───────────

def test_user_message_sends_support_email_with_conversation_id(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]

    assert len(sent) == 1
    call = sent[0]
    assert call["conversation_id"] == cid
    assert call["uid"] == ATHLETE["uid"]
    assert call["message"] == "Hello, I need help with my diet plan."


def test_support_email_threads_to_inbox_not_the_athlete(db):
    """The header that makes requirement 'no personal Gmail' actually hold."""
    msg = support_service.build_support_email(
        conversation_id="conv123", user_name="Test Athlete",
        user_email="athlete@example.com", uid="athlete_1",
        subject="Diet help", category="Diet", message="Hi",
        sender="zitlas1111@gmail.com", message_id="<abc@zitlas.com>",
    )
    assert msg["To"] == support_service.SUPPORT_INBOX
    assert msg["Reply-To"] == support_service.SUPPORT_INBOX
    # The athlete's address must never be a header a Reply would follow.
    assert "athlete@example.com" not in (msg["Reply-To"] or "")
    assert "athlete@example.com" not in (msg["To"] or "")
    assert "[ZITLAS SUPPORT #conv123]" in msg["Subject"]
    # ...but a human must still be able to find it in the body. utf-8 parts
    # are base64-encoded, so decode rather than scanning the raw MIME text.
    decoded = "".join(
        part.get_payload(decode=True).decode("utf-8", errors="replace")
        for part in msg.walk() if part.get_payload(decode=True)
    )
    assert "athlete@example.com" in decoded
    assert "athlete_1" in decoded
    assert "conv123" in decoded


# ── 5. Privacy: one athlete cannot read another's conversation ───────────────

def test_other_user_cannot_read_conversation(db, sent):
    cid = open_conversation(make_app(db, ATHLETE))["conversationId"]

    intruder = make_app(db, OTHER)
    assert intruder.get(f"/api/support/conversations/{cid}").status_code == 404
    assert intruder.get(f"/api/support/conversations/{cid}/messages").status_code == 404
    assert intruder.post(f"/api/support/conversations/{cid}/messages",
                         json={"message": "let me in"}).status_code == 404
    assert intruder.post(f"/api/support/conversations/{cid}/read").status_code == 404


def test_other_user_conversation_list_is_empty(db, sent):
    open_conversation(make_app(db, ATHLETE))
    res = make_app(db, OTHER).get("/api/support/conversations")
    assert res.status_code == 200
    assert res.json()["conversations"] == []


# ── 6-7. A Gmail reply lands in the right conversation ───────────────────────

def test_support_reply_is_associated_with_correct_conversation(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]

    ingested = _ingest_one(
        db,
        subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
        body="Hello, we received your request and will help you shortly.",
    )
    assert ingested == cid

    messages = support_service.list_messages(db, cid)
    assert len(messages) == 2
    assert messages[1]["senderType"] == "support"
    assert messages[1]["message"] == "Hello, we received your request and will help you shortly."

    conv = support_service.get_conversation(db, cid)
    assert conv["status"] == support_service.STATUS_WAITING_FOR_USER
    assert conv["unreadByUser"] == 1


def test_support_reply_appears_in_help_center_api(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]
    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
                body="We are on it.")

    res = client.get(f"/api/support/conversations/{cid}/messages")
    assert res.status_code == 200
    msgs = res.json()["messages"]
    assert [m["senderType"] for m in msgs] == ["user", "support"]
    assert msgs[1]["message"] == "We are on it."


def test_reply_to_wrong_conversation_never_crosses_over(db, sent):
    """A reply tagged with athlete 1's id must not appear for athlete 2."""
    cid_a = open_conversation(make_app(db, ATHLETE), subject="A")["conversationId"]
    cid_b = open_conversation(make_app(db, OTHER), subject="B")["conversationId"]

    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid_a)} A",
                body="Answer for A only.")

    assert len(support_service.list_messages(db, cid_a)) == 2
    assert len(support_service.list_messages(db, cid_b)) == 1


# ── 8-9. Multi-turn stays in one conversation ────────────────────────────────

def test_multiple_replies_stay_in_same_conversation(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]
    subject = f"Re: {support_service.subject_tag(cid)} Diet plan help"

    _ingest_one(db, subject=subject, body="First reply.")
    _ingest_one(db, subject=subject, body="Second reply.")
    _ingest_one(db, subject=subject, body="Third reply.")

    msgs = support_service.list_messages(db, cid)
    assert [m["senderType"] for m in msgs] == ["user", "support", "support", "support"]
    assert len(support_service.list_conversations_for_user(db, ATHLETE["uid"])) == 1


def test_user_reply_after_support_reply_stays_in_same_conversation(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]
    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
                body="How can we help?")

    res = client.post(f"/api/support/conversations/{cid}/messages",
                      json={"message": "It is about my calorie target."})
    assert res.status_code == 200
    assert res.json()["conversationId"] == cid

    msgs = support_service.list_messages(db, cid)
    assert [m["senderType"] for m in msgs] == ["user", "support", "user"]
    assert support_service.get_conversation(db, cid)["status"] == \
        support_service.STATUS_WAITING_FOR_SUPPORT
    assert len(support_service.list_conversations_for_user(db, ATHLETE["uid"])) == 1
    # The follow-up email threads onto the original rather than opening a new one.
    assert sent[-1]["conversation_id"] == cid
    assert sent[-1]["in_reply_to"]


def test_ingestion_is_idempotent(db, sent):
    """Re-scanning the mailbox must not double-post a reply."""
    cid = open_conversation(make_app(db))["conversationId"]
    subject = f"Re: {support_service.subject_tag(cid)} Diet plan help"
    mid = email.utils.make_msgid(domain="zitlas.com")

    _ingest_one(db, subject=subject, body="Only once.", message_id=mid)
    _ingest_one(db, subject=subject, body="Only once.", message_id=mid)

    assert len(support_service.list_messages(db, cid)) == 2


# ── 10. Notification on support reply ────────────────────────────────────────

def test_notification_is_sent_when_support_replies(db, sent):
    cid = open_conversation(make_app(db))["conversationId"]
    captured: list[dict] = []

    def _notify(conv, conversation_id, text):
        captured.append({"conv": conv, "cid": conversation_id, "text": text})

    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
                body="We replied.", notify=_notify)

    assert len(captured) == 1
    assert captured[0]["cid"] == cid
    assert captured[0]["conv"]["userId"] == ATHLETE["uid"]


def test_notify_helper_deep_links_to_the_conversation(db, monkeypatch):
    """The push must carry enough for both clients to open the right thread."""
    calls: list[dict] = []
    import services.notification_service as notif
    monkeypatch.setattr(notif, "send",
                        lambda db, uid, title, message, **kw: calls.append(
                            {"uid": uid, "title": title, **kw}) or {"ok": True})

    support_service._notify_user_of_reply(
        db, {"userId": "athlete_1"}, "conv123", "Support says hi")

    assert len(calls) == 1
    assert calls[0]["uid"] == "athlete_1"
    assert calls[0]["action"] == "open_support_conversation"
    assert calls[0]["action_id"] == "conv123"
    assert calls[0]["data"]["conversationId"] == "conv123"


# ── 11-12. Credentials never leak ────────────────────────────────────────────

SECRET = "abcd efgh ijkl mnop"


def test_gmail_credentials_never_appear_in_api_responses(db, sent, monkeypatch):
    monkeypatch.setenv("SUPPORT_EMAIL", "zitlas1111@gmail.com")
    monkeypatch.setenv("SUPPORT_EMAIL_PASSWORD", SECRET)

    client = make_app(db)
    cid = open_conversation(client)["conversationId"]

    bodies = [
        client.post("/api/support/contact", json={
            "name": "A", "email": "a@b.com", "subject": "S",
            "category": "General", "message": "Message body"}).text,
        client.get("/api/support/conversations").text,
        client.get(f"/api/support/conversations/{cid}").text,
        client.get(f"/api/support/conversations/{cid}/messages").text,
        client.post(f"/api/support/conversations/{cid}/messages",
                    json={"message": "again"}).text,
    ]
    for body in bodies:
        assert SECRET not in body
        assert SECRET.replace(" ", "") not in body
        assert "SUPPORT_EMAIL_PASSWORD" not in body


def test_gmail_credentials_never_appear_in_logs(db, monkeypatch, capsys):
    """An SMTP failure quotes the failing command — which contains the
    password — back at us. It must be redacted before it can be printed."""
    monkeypatch.setenv("SUPPORT_EMAIL", "zitlas1111@gmail.com")
    monkeypatch.setenv("SUPPORT_EMAIL_PASSWORD", SECRET)

    import smtplib

    class BoomSMTP:
        def __init__(self, *a, **kw): pass
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def ehlo(self): pass
        def starttls(self): pass
        def login(self, user, pw):
            raise smtplib.SMTPAuthenticationError(
                535, f"5.7.8 Username and Password not accepted: AUTH PLAIN {pw}")
        def sendmail(self, *a, **kw): pass

    monkeypatch.setattr(smtplib, "SMTP", BoomSMTP)

    with pytest.raises(RuntimeError) as exc:
        support_service.send_support_email(
            conversation_id="c1", user_name="A", user_email="a@b.com", uid="u1",
            subject="S", category="General", message="M")

    raised = str(exc.value)
    assert SECRET.replace(" ", "") not in raised
    assert "***REDACTED***" in raised

    print(f"[SUPPORT] outbound email failed (non-fatal): {raised}")
    captured = capsys.readouterr().out
    assert SECRET.replace(" ", "") not in captured
    assert SECRET not in captured


def test_redact_scrubs_both_spaced_and_unspaced_forms(monkeypatch):
    monkeypatch.setenv("SUPPORT_EMAIL_PASSWORD", SECRET)
    text = f"login failed for {SECRET} and {SECRET.replace(' ', '')}"
    out = support_service._redact(text)
    assert SECRET not in out
    assert SECRET.replace(" ", "") not in out


def test_app_password_spaces_are_stripped_before_login(monkeypatch):
    """Gmail rejects the spaced display form; passing it through would look
    like a wrong password rather than a formatting bug."""
    monkeypatch.setenv("SUPPORT_EMAIL", "zitlas1111@gmail.com")
    monkeypatch.setenv("SUPPORT_EMAIL_PASSWORD", SECRET)
    _, password = support_service._credentials()
    assert password == "abcdefghijklmnop"


# ── 13-14. Admin access, and only admin ──────────────────────────────────────

def test_admin_can_access_support_conversations(db, sent):
    cid = open_conversation(make_app(db, ATHLETE))["conversationId"]
    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
                body="Admin visible reply.")

    admin = make_app(db, ADMIN)
    listing = admin.get("/api/support/admin/conversations")
    assert listing.status_code == 200
    rows = listing.json()["conversations"]
    assert len(rows) == 1
    assert rows[0]["id"] == cid
    assert rows[0]["userId"] == ATHLETE["uid"]
    assert rows[0]["status"] == support_service.STATUS_WAITING_FOR_USER

    thread = admin.get(f"/api/support/admin/conversations/{cid}/messages")
    assert thread.status_code == 200
    assert len(thread.json()["messages"]) == 2


def test_normal_athlete_cannot_access_admin_support_routes(db, sent):
    """require_admin is NOT overridden here, so the real dependency runs."""
    cid = open_conversation(make_app(db, ATHLETE))["conversationId"]

    app = FastAPI()
    app.include_router(support_routes.router, prefix="/api/support")
    app.dependency_overrides[verify_firebase_token] = lambda: ATHLETE
    support_routes.firestore_service.get_client = lambda: db
    client = TestClient(app)

    assert client.get("/api/support/admin/conversations").status_code == 403
    assert client.get(
        f"/api/support/admin/conversations/{cid}/messages").status_code == 403
    assert client.post("/api/support/admin/ingest").status_code == 403


def test_admin_sees_every_athletes_conversation(db, sent):
    open_conversation(make_app(db, ATHLETE), subject="From athlete 1")
    open_conversation(make_app(db, OTHER), subject="From athlete 2")

    rows = make_app(db, ADMIN).get("/api/support/admin/conversations").json()["conversations"]
    assert {r["userId"] for r in rows} == {ATHLETE["uid"], OTHER["uid"]}


# ── 15. Website and Flutter read the same source ─────────────────────────────

def test_website_and_flutter_share_one_conversation_source(db, sent):
    """Both clients call the same endpoints against the same collection, so a
    message created by one is visible to the other with no translation."""
    flutter = make_app(db)
    cid = flutter.post("/api/support/contact", json={
        "name": "Test Athlete", "email": "athlete@example.com",
        "subject": "From Flutter", "category": "General",
        "message": "Sent from the mobile app."}).json()["conversationId"]

    website = make_app(db)
    listing = website.get("/api/support/conversations").json()["conversations"]
    assert [c["id"] for c in listing] == [cid]

    msgs = website.get(f"/api/support/conversations/{cid}/messages").json()["messages"]
    assert msgs[0]["message"] == "Sent from the mobile app."
    assert support_service.CONVERSATIONS == "support_conversations"


# ── Auth, status machine, and reply parsing ──────────────────────────────────

def test_contact_requires_authentication():
    """Without the dependency override the real verifier runs and rejects an
    anonymous caller — the old endpoint accepted anyone."""
    app = FastAPI()
    app.include_router(support_routes.router, prefix="/api/support")
    client = TestClient(app)
    res = client.post("/api/support/contact", json={
        "name": "Anon", "email": "anon@example.com", "subject": "S",
        "category": "General", "message": "Let me in"})
    assert res.status_code == 401


def test_identity_comes_from_token_not_body(db, sent):
    """A spoofed uid/email in the body must be ignored."""
    client = make_app(db)
    cid = client.post("/api/support/contact", json={
        "name": "Impersonator", "email": "victim@example.com",
        "subject": "S", "category": "General",
        "message": "Trying to attach to someone else"}).json()["conversationId"]

    conv = support_service.get_conversation(db, cid)
    assert conv["userId"] == ATHLETE["uid"]
    assert conv["userEmail"] == ATHLETE["email"]


def test_status_machine_transitions(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]
    assert support_service.get_conversation(db, cid)["status"] == "WAITING_FOR_SUPPORT"

    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
                body="Support here.")
    assert support_service.get_conversation(db, cid)["status"] == "WAITING_FOR_USER"

    client.post(f"/api/support/conversations/{cid}/messages", json={"message": "Thanks"})
    assert support_service.get_conversation(db, cid)["status"] == "WAITING_FOR_SUPPORT"


def test_mark_read_clears_unread_badge(db, sent):
    client = make_app(db)
    cid = open_conversation(client)["conversationId"]
    _ingest_one(db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
                body="Reply one.")
    assert support_service.get_conversation(db, cid)["unreadByUser"] == 1

    assert client.post(f"/api/support/conversations/{cid}/read").status_code == 200
    assert support_service.get_conversation(db, cid)["unreadByUser"] == 0


def test_extract_reply_text_strips_quoted_history():
    raw = (
        "Hello, we received your request and will help you shortly.\n"
        "\n"
        "On Mon, 18 Aug 2026 at 10:00, ZITLAS <zitlas1111@gmail.com> wrote:\n"
        "> ZITLAS Support Request\n"
        "> User: Test Athlete\n"
        "> Message: Hello, I need help with my diet plan.\n"
    )
    out = support_service.extract_reply_text(raw)
    assert out == "Hello, we received your request and will help you shortly."
    assert "Support Request" not in out
    assert ">" not in out


def test_resolve_conversation_id_prefers_subject_tag(db):
    cid = support_service.resolve_conversation_id(
        db, subject="Re: [ZITLAS SUPPORT #conv_abc123] Diet help",
        in_reply_to="", references="")
    assert cid == "conv_abc123"


def test_resolve_conversation_id_falls_back_to_in_reply_to(db):
    support_service.remember_email(db, "<orig@zitlas.com>", "conv_xyz", "outbound")
    cid = support_service.resolve_conversation_id(
        db, subject="Re: your ticket (subject rewritten)",
        in_reply_to="<orig@zitlas.com>", references="")
    assert cid == "conv_xyz"


def test_resolve_conversation_id_never_guesses_from_sender(db):
    """No tag and no threading headers must yield None, not a best guess.
    Guessing here means leaking one athlete's reply into another's chat."""
    assert support_service.resolve_conversation_id(
        db, subject="Random unrelated email", in_reply_to="", references="") is None


def test_reply_from_a_stranger_is_ignored(db, sent):
    """Only the ZITLAS mailbox may author a support message."""
    cid = open_conversation(make_app(db))["conversationId"]
    result = _ingest_one(
        db, subject=f"Re: {support_service.subject_tag(cid)} Diet plan help",
        body="I am not ZITLAS support.", from_addr="attacker@evil.com")
    assert result is None
    assert len(support_service.list_messages(db, cid)) == 1


# ── Send-first: a 2xx must mean the mail really went out ─────────────────────

def _fail_send(monkeypatch, exc):
    def _boom(**kwargs):
        raise exc
    monkeypatch.setattr(support_service, "send_support_email", _boom)


def test_failed_delivery_is_reported_as_an_error_not_a_success(db, monkeypatch):
    """The whole point of the fix: the endpoint must never answer 200 for a
    message the support inbox never received."""
    _fail_send(monkeypatch, RuntimeError("Connection refused"))

    res = make_app(db).post("/api/support/contact", json={
        "name": "Test Athlete", "email": "athlete@example.com",
        "subject": "S", "category": "General", "message": "Undeliverable"})

    # A refused connection is a REACHABILITY failure, not a generic one.
    assert res.status_code == 504
    detail = res.json()["detail"]
    assert detail["code"] == "smtp_unreachable"
    assert detail["stage"] == "smtp_send"
    assert "could not reach" in detail["message"].lower()
    # The hint must name what to actually check.
    assert "587" in detail["hint"]


def test_a_failed_send_leaves_no_orphan_conversation(db, monkeypatch):
    """Send-first exists so a retry does not pile up dead threads."""
    _fail_send(monkeypatch, RuntimeError("Connection refused"))
    client = make_app(db)

    for _ in range(3):
        client.post("/api/support/contact", json={
            "name": "A", "email": "a@b.com", "subject": "S",
            "category": "General", "message": "retry"})

    assert support_service.list_conversations_for_user(db, ATHLETE["uid"]) == []


def test_missing_credentials_are_reported_as_a_config_problem(db, monkeypatch):
    """Must name the exact variables, so the operator is not left guessing."""
    _fail_send(monkeypatch, RuntimeError(
        "SUPPORT_EMAIL or SUPPORT_EMAIL_PASSWORD not set in environment."))

    res = make_app(db).post("/api/support/contact", json={
        "name": "A", "email": "a@b.com", "subject": "S",
        "category": "General", "message": "x"})

    assert res.status_code == 503
    detail = res.json()["detail"]
    assert detail["code"] == "smtp_not_configured"
    assert "not configured" in detail["message"].lower()
    assert "SUPPORT_EMAIL" in detail["hint"]
    assert "SUPPORT_EMAIL_PASSWORD" in detail["hint"]


def test_rejected_gmail_credentials_are_reported_distinctly(db, monkeypatch):
    """A 535 is a ZITLAS-side config fault, not something a retry can fix, so
    it must not read like a transient network blip."""
    _fail_send(monkeypatch, RuntimeError(
        "SMTPAuthenticationError: (535, b'5.7.8 Username and Password not "
        "accepted ... BadCredentials')"))

    res = make_app(db).post("/api/support/contact", json={
        "name": "A", "email": "a@b.com", "subject": "S",
        "category": "General", "message": "x"})

    assert res.status_code == 502
    detail = res.json()["detail"]
    assert detail["code"] == "smtp_auth_failed"
    assert "535" in detail["message"]
    # The hint must point at the exact remedy.
    assert "apppasswords" in detail["hint"]
    assert "SUPPORT_EMAIL_PASSWORD" in detail["hint"]
    assert "2-Step" in detail["hint"]


def test_every_delivery_failure_is_classified_with_a_stable_code(db, monkeypatch):
    """The frontend branches on `code`, so each failure mode needs its own."""
    cases = [
        (RuntimeError("SUPPORT_EMAIL or SUPPORT_EMAIL_PASSWORD not set in "
                      "environment."), 503, "smtp_not_configured"),
        (RuntimeError("SMTPAuthenticationError: (535, BadCredentials)"),
         502, "smtp_auth_failed"),
        (RuntimeError("SMTPRecipientsRefused: {}"), 502, "smtp_address_refused"),
        (RuntimeError("TimeoutError: timed out"), 504, "smtp_unreachable"),
        (RuntimeError("socket.gaierror: getaddrinfo failed"), 504,
         "smtp_unreachable"),
        (ValueError("something unexpected"), 502, "smtp_send_failed"),
    ]
    for exc, status, code in cases:
        _fail_send(monkeypatch, exc)
        res = make_app(db).post("/api/support/contact", json={
            "name": "A", "email": "a@b.com", "subject": "S",
            "category": "General", "message": "x"})
        assert res.status_code == status, f"{code}: got {res.status_code}"
        assert res.json()["detail"]["code"] == code


def test_error_details_never_carry_the_password(db, monkeypatch):
    """Every classified branch, not just the auth one."""
    for exc in (
        RuntimeError(f"SMTPAuthenticationError: AUTH PLAIN {SECRET}"),
        RuntimeError(f"timed out while sending with {SECRET}"),
        ValueError(f"weird failure {SECRET}"),
    ):
        _fail_send(monkeypatch, exc)
        res = make_app(db).post("/api/support/contact", json={
            "name": "A", "email": "a@b.com", "subject": "S",
            "category": "General", "message": "x"})
        assert SECRET not in res.text
        assert SECRET.replace(" ", "") not in res.text


def test_delivery_failure_detail_never_leaks_the_password(db, monkeypatch):
    _fail_send(monkeypatch, RuntimeError(
        f"SMTPAuthenticationError: (535, AUTH PLAIN ***REDACTED***)"))

    res = make_app(db).post("/api/support/contact", json={
        "name": "A", "email": "a@b.com", "subject": "S",
        "category": "General", "message": "x"})

    assert SECRET not in res.text
    assert SECRET.replace(" ", "") not in res.text


def test_a_successful_send_reports_emailed_true_and_persists(db, sent):
    """The success path still stores everything, in the right order."""
    res = make_app(db).post("/api/support/contact", json={
        "name": "Test Athlete", "email": "athlete@example.com",
        "subject": "S", "category": "General", "message": "Delivered"})

    assert res.status_code == 200
    body = res.json()
    assert body["success"] is True
    assert body["emailed"] is True
    assert "sent successfully" in body["message"].lower()

    msgs = support_service.list_messages(db, body["conversationId"])
    assert len(msgs) == 1 and msgs[0]["message"] == "Delivered"
    # The outbound Message-Id is indexed, so the eventual reply can thread.
    assert msgs[0]["emailMessageId"]
    assert support_service.lookup_email(db, msgs[0]["emailMessageId"])


def test_the_emailed_subject_carries_the_committed_conversation_id(db, sent):
    """The id put in the subject must be the id actually written to Firestore —
    a mismatch would silently orphan every reply."""
    body = make_app(db).post("/api/support/contact", json={
        "name": "A", "email": "a@b.com", "subject": "S",
        "category": "General", "message": "x"}).json()

    assert sent[0]["conversation_id"] == body["conversationId"]
    assert support_service.get_conversation(db, body["conversationId"]) is not None


def test_a_failed_reply_does_not_append_to_the_thread(db, sent, monkeypatch):
    """Same contract on the follow-up path."""
    cid = open_conversation(make_app(db))["conversationId"]
    _fail_send(monkeypatch, RuntimeError("Connection refused"))

    res = make_app(db).post(f"/api/support/conversations/{cid}/messages",
                            json={"message": "never delivered"})

    assert res.status_code == 504
    assert res.json()["detail"]["code"] == "smtp_unreachable"
    msgs = support_service.list_messages(db, cid)
    assert len(msgs) == 1
    assert msgs[0]["message"] != "never delivered"


def test_ingest_replies_is_safe_when_unconfigured(db, monkeypatch):
    """A missing credential must return a summary, never raise into the
    scheduler."""
    monkeypatch.delenv("SUPPORT_EMAIL", raising=False)
    monkeypatch.delenv("SUPPORT_EMAIL_PASSWORD", raising=False)
    out = support_service.ingest_replies(db=db)
    assert out["error"] == "not_configured"
    assert out["imported"] == 0


# ── ingest_replies() itself, against a stubbed mailbox ───────────────────────
#
# The tests above drive the parse/thread/persist path through _ingest_one().
# These drive the REAL production function, with imaplib replaced by a fake
# connection, so the IMAP search/fetch/skip/idempotency logic is covered too.
# Still no network: FakeIMAP never opens a socket.

class FakeIMAP:
    """Enough of imaplib.IMAP4_SSL for ingest_replies() to run."""

    def __init__(self, messages):
        # messages: list of raw RFC822 bytes
        self._messages = messages
        self.logged_in = False
        self.selected = None
        self.logged_out = False

    def login(self, user, password):
        self.logged_in = True
        return ("OK", [b"logged in"])

    def select(self, folder):
        self.selected = folder
        return ("OK", [str(len(self._messages)).encode()])

    def search(self, charset, *criteria):
        ids = b" ".join(str(i + 1).encode() for i in range(len(self._messages)))
        return ("OK", [ids])

    def fetch(self, num, spec):
        idx = int(num) - 1
        if idx < 0 or idx >= len(self._messages):
            return ("NO", None)
        return ("OK", [(b"1 (RFC822 {n})", self._messages[idx])])

    def close(self):
        return ("OK", [b"closed"])

    def logout(self):
        self.logged_out = True
        return ("BYE", [b"bye"])


def _raw(subject, body, from_addr=None, message_id=None, outbound=False,
         in_reply_to=""):
    from_addr = from_addr or support_service.SUPPORT_INBOX
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = from_addr
    msg["To"] = support_service.SUPPORT_INBOX
    msg["Message-ID"] = message_id or email.utils.make_msgid(domain="zitlas.com")
    if outbound:
        msg[support_service.OUTBOUND_HEADER] = "outbound"
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
    msg.attach(MIMEText(body, "plain", "utf-8"))
    return msg.as_bytes()


@pytest.fixture
def imap_env(monkeypatch):
    monkeypatch.setenv("SUPPORT_EMAIL", "zitlas1111@gmail.com")
    monkeypatch.setenv("SUPPORT_EMAIL_PASSWORD", SECRET)


def _install_imap(monkeypatch, messages):
    holder = {}

    def _factory(host, port):
        conn = FakeIMAP(messages)
        holder["conn"] = conn
        return conn

    import imaplib
    monkeypatch.setattr(imaplib, "IMAP4_SSL", _factory)
    return holder


def test_ingest_replies_imports_a_real_reply(db, sent, imap_env, monkeypatch):
    cid = open_conversation(make_app(db))["conversationId"]
    subject = f"Re: {support_service.subject_tag(cid)} Diet plan help"
    body = (
        "Hello, we received your request and will help you shortly.\n"
        "\n"
        "On Mon, 18 Aug 2026 at 10:00, ZITLAS <zitlas1111@gmail.com> wrote:\n"
        "> ZITLAS Support Request\n"
        "> Message: Hello, I need help with my diet plan.\n"
    )
    holder = _install_imap(monkeypatch, [_raw(subject, body)])

    summary = support_service.ingest_replies(db=db)

    assert summary["imported"] == 1, summary
    assert summary["errors"] == 0
    assert holder["conn"].logged_in and holder["conn"].logged_out

    msgs = support_service.list_messages(db, cid)
    assert [m["senderType"] for m in msgs] == ["user", "support"]
    # Quoted history stripped, so the athlete does not see their own message
    # pasted back at them.
    assert msgs[1]["message"] == "Hello, we received your request and will help you shortly."


def test_ingest_replies_skips_our_own_outbound_mail(db, sent, imap_env, monkeypatch):
    """The notification WE sent is in the same mailbox. Importing it would post
    the athlete's own message back as if support had said it."""
    cid = open_conversation(make_app(db))["conversationId"]
    outbound = _raw(f"{support_service.subject_tag(cid)} Diet plan help",
                    "ZITLAS Support Request ...", outbound=True)
    _install_imap(monkeypatch, [outbound])

    summary = support_service.ingest_replies(db=db)

    assert summary["imported"] == 0
    assert summary["skipped"] == 1
    assert len(support_service.list_messages(db, cid)) == 1


def test_ingest_replies_is_idempotent_across_polls(db, sent, imap_env, monkeypatch):
    """The scheduler runs this every 60s against the same mailbox."""
    cid = open_conversation(make_app(db))["conversationId"]
    raw = _raw(f"Re: {support_service.subject_tag(cid)} Diet plan help",
               "Only once, please.")
    _install_imap(monkeypatch, [raw])

    first = support_service.ingest_replies(db=db)
    second = support_service.ingest_replies(db=db)
    third = support_service.ingest_replies(db=db)

    assert first["imported"] == 1
    assert second["imported"] == 0 and second["skipped"] == 1
    assert third["imported"] == 0
    assert len(support_service.list_messages(db, cid)) == 2


def test_ingest_replies_ignores_untagged_and_foreign_mail(db, sent, imap_env, monkeypatch):
    cid = open_conversation(make_app(db))["conversationId"]
    messages = [
        # No conversation tag at all — must never be guessed onto a thread.
        _raw("ZITLAS SUPPORT newsletter", "Unrelated."),
        # Correct tag but not from the ZITLAS mailbox.
        _raw(f"Re: {support_service.subject_tag(cid)} Diet plan help",
             "I am not ZITLAS.", from_addr="attacker@evil.com"),
        # Tag pointing at a conversation that does not exist.
        _raw("Re: [ZITLAS SUPPORT #does_not_exist] Ghost", "Nowhere to go."),
    ]
    _install_imap(monkeypatch, messages)

    summary = support_service.ingest_replies(db=db)

    assert summary["imported"] == 0
    assert summary["skipped"] == 3
    assert len(support_service.list_messages(db, cid)) == 1


def test_ingest_replies_survives_a_mailbox_outage(db, imap_env, monkeypatch):
    """A dead mailbox must return a summary, not raise into the scheduler and
    kill the job."""
    import imaplib

    def _boom(host, port):
        raise OSError("connection refused")

    monkeypatch.setattr(imaplib, "IMAP4_SSL", _boom)

    summary = support_service.ingest_replies(db=db)
    assert summary["imported"] == 0
    assert summary["errors"] == 1
    assert "OSError" in summary["error"]


def test_ingest_replies_never_logs_the_password(db, imap_env, monkeypatch, capsys):
    """imaplib puts the failing LOGIN command — password included — into its
    exception. ingest_replies must redact before printing."""
    import imaplib

    class LeakyIMAP(FakeIMAP):
        def login(self, user, password):
            raise imaplib.IMAP4.error(
                f"b'[AUTHENTICATIONFAILED] LOGIN {user} {password}'")

    monkeypatch.setattr(imaplib, "IMAP4_SSL", lambda h, p: LeakyIMAP([]))

    summary = support_service.ingest_replies(db=db)
    out = capsys.readouterr().out

    assert summary["errors"] == 1
    assert SECRET not in out
    assert SECRET.replace(" ", "") not in out
    assert SECRET.replace(" ", "") not in summary["error"]
    assert "***REDACTED***" in summary["error"]


def test_ingest_replies_multi_turn_across_two_conversations(db, sent, imap_env, monkeypatch):
    """Two athletes, two threads, one mailbox — replies must not cross."""
    cid_a = open_conversation(make_app(db, ATHLETE), subject="A")["conversationId"]
    cid_b = open_conversation(make_app(db, OTHER), subject="B")["conversationId"]

    _install_imap(monkeypatch, [
        _raw(f"Re: {support_service.subject_tag(cid_a)} A", "Answer for A."),
        _raw(f"Re: {support_service.subject_tag(cid_b)} B", "Answer for B."),
        _raw(f"Re: {support_service.subject_tag(cid_a)} A", "Follow-up for A."),
    ])

    summary = support_service.ingest_replies(db=db)
    assert summary["imported"] == 3

    a = support_service.list_messages(db, cid_a)
    b = support_service.list_messages(db, cid_b)
    assert [m["message"] for m in a if m["senderType"] == "support"] == \
        ["Answer for A.", "Follow-up for A."]
    assert [m["message"] for m in b if m["senderType"] == "support"] == \
        ["Answer for B."]


# ── Client/server request contract ───────────────────────────────────────────
#
# The Flutter app and the website both POST /api/support/contact. A build that
# sent only {subject, category, message} answered
#     422  body.name -> Field required
#          body.email -> Field required
# against the backend that was live at the time, and the athlete saw the
# useless string "Field required; Field required".
#
# These tests pin the payload BOTH clients send, against BOTH the schema that
# shipped and the one in this branch, so the two can never drift apart again.

# Exactly the body support_repository.buildContactBody() and help-support.js
# now send. Keep in lockstep with those two call sites.
CLIENT_CONTACT_BODY = {
    "name": "ZITLAS Athlete",
    "email": "athlete@example.com",
    "subject": "Diet plan help",
    "category": "Diet",
    "message": "Hello, I need help with my diet plan.",
}


def test_client_body_satisfies_the_current_contact_schema(db, sent):
    """The payload the clients build must be accepted as-is."""
    res = make_app(db).post("/api/support/contact", json=CLIENT_CONTACT_BODY)
    assert res.status_code == 200, res.text
    assert res.json()["success"] is True


def test_client_body_carries_every_field_the_shipped_schema_required(db):
    """The previously deployed schema required all five fields.

    Reconstructed here rather than imported, so this test keeps protecting the
    contract even after the old module is gone: a client build that drops a key
    must fail HERE, not on a user's phone.
    """
    from pydantic import BaseModel, EmailStr, Field, ValidationError

    class ShippedContactRequest(BaseModel):
        name: str = Field(..., min_length=1, max_length=120)
        email: EmailStr
        subject: str = Field(..., min_length=1, max_length=200)
        category: str = Field(..., min_length=1, max_length=100)
        message: str = Field(..., min_length=20, max_length=5000)

    # Must not raise — this is the assertion.
    ShippedContactRequest(**CLIENT_CONTACT_BODY)

    # And prove the regression it guards against is real: dropping the two
    # identity fields reproduces the exact error the athlete saw.
    broken = {k: v for k, v in CLIENT_CONTACT_BODY.items()
              if k not in ("name", "email")}
    try:
        ShippedContactRequest(**broken)
        raise AssertionError("expected the reduced payload to be rejected")
    except ValidationError as exc:
        missing = {e["loc"][0] for e in exc.errors() if e["type"] == "missing"}
        assert missing == {"name", "email"}


def test_identity_still_comes_from_the_token_not_the_body(db, sent):
    """name/email are accepted for schema compatibility but must never be an
    authorisation input — the verified token wins."""
    res = make_app(db).post("/api/support/contact", json={
        **CLIENT_CONTACT_BODY,
        "email": "attacker@evil.com",
        "name": "Someone Else",
    })
    assert res.status_code == 200
    conv = support_service.get_conversation(db, res.json()["conversationId"])
    assert conv["userId"] == ATHLETE["uid"]
    assert conv["userEmail"] == ATHLETE["email"]      # token, not body
    assert conv["userEmail"] != "attacker@evil.com"


def test_a_missing_name_still_produces_a_usable_conversation(db, sent):
    """The client always sends a non-empty name, but a stale build might not."""
    res = make_app(db).post("/api/support/contact", json={
        "subject": "S", "category": "General", "message": "no name field"})
    assert res.status_code == 200
    conv = support_service.get_conversation(db, res.json()["conversationId"])
    assert conv["userName"]        # never blank in the support inbox
    assert conv["userId"] == ATHLETE["uid"]


def test_subject_and_message_remain_genuinely_required(db, sent):
    """The fix must NOT have been 'make everything optional'."""
    for missing in ("subject", "message"):
        body = {k: v for k, v in CLIENT_CONTACT_BODY.items() if k != missing}
        res = make_app(db).post("/api/support/contact", json=body)
        assert res.status_code == 422, f"{missing} should still be required"
        locs = {tuple(e["loc"]) for e in res.json()["detail"]}
        assert ("body", missing) in locs


def test_validation_errors_name_the_field_that_is_missing(db, sent):
    """The client renders `loc` alongside `msg`; that is only useful if the
    server actually reports which field failed."""
    res = make_app(db).post("/api/support/contact",
                            json={"category": "General"})
    assert res.status_code == 422
    reported = {e["loc"][-1] for e in res.json()["detail"]}
    assert {"subject", "message"} <= reported
