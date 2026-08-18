"""
ZITLAS — Help Center outbound-mail deadline (backend/tests/test_support_timeout.py)

Reproduces the production failure and pins the fix.

WHAT HAPPENED: the shipped `_send_sync()` opened `smtplib.SMTP(host, port)` with
no `timeout` argument. Python then uses the global default socket timeout, which
is None — "block forever". On a host whose outbound SMTP ports are filtered the
TCP connect neither completes nor errors, so the request hung. Measured against
production:

    POST /api/support/contact  invalid body (no SMTP)  -> 422 in 0.70s
    POST /api/support/contact  valid body  (SMTP path) -> no response after 120s

The mobile client gives up at 30s (Env.apiTimeout) and surfaces
`TimeoutException` with no message, which is why this looked like a client bug.

These tests bind a real socket that ACCEPTS and then never speaks, which is
exactly what a filtered/blackholed SMTP endpoint looks like to the client. No
external network is used and no mail is sent.
"""

from __future__ import annotations

import os
import socket
import sys
import threading
import time

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tests.fake_firestore import FakeClient          # noqa: E402
from services import support_service                 # noqa: E402
from services.auth_service import verify_firebase_token  # noqa: E402
import routes.support as support_routes              # noqa: E402


ATHLETE = {"uid": "athlete_1", "email": "athlete@example.com",
           "name": "Test Athlete", "admin": False, "expert": False,
           "email_verified": True}

BODY = {
    "name": "Test Athlete",
    "email": "athlete@example.com",
    "subject": "Timeout probe",
    "category": "Technical Issue",
    "message": "Does this endpoint ever answer?",
}


class BlackholeSMTP:
    """Accepts the TCP connection, then never sends a banner.

    This is the failure mode that hangs smtplib: the socket is OPEN, so there
    is no connection error to raise — the client just waits for a greeting
    that never arrives. A refused connection would fail fast and would NOT
    reproduce the bug.
    """

    def __init__(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self._stop = threading.Event()
        self._held: list[socket.socket] = []
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        self._sock.settimeout(0.5)
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
                self._held.append(conn)   # hold it open, say nothing
            except socket.timeout:
                continue
            except OSError:
                break

    def close(self):
        self._stop.set()
        for c in self._held:
            try:
                c.close()
            except OSError:
                pass
        try:
            self._sock.close()
        except OSError:
            pass


@pytest.fixture
def blackhole():
    server = BlackholeSMTP()
    yield server
    server.close()


@pytest.fixture
def db():
    return FakeClient()


def make_app(db, caller=ATHLETE):
    app = FastAPI()
    app.include_router(support_routes.router, prefix="/api/support")
    app.dependency_overrides[verify_firebase_token] = lambda: caller
    support_routes.firestore_service.get_client = lambda: db
    return TestClient(app)


@pytest.fixture(autouse=True)
def _restore():
    original = support_routes.firestore_service.get_client
    host, port = support_service.SMTP_HOST, support_service.SMTP_PORT
    timeout = support_service.SMTP_TIMEOUT
    deadline = support_routes.SEND_DEADLINE_SECONDS
    yield
    support_routes.firestore_service.get_client = original
    support_service.SMTP_HOST, support_service.SMTP_PORT = host, port
    support_service.SMTP_TIMEOUT = timeout
    support_routes.SEND_DEADLINE_SECONDS = deadline


def _point_at(blackhole, monkeypatch, *, smtp_timeout=1.0, deadline=3.0):
    monkeypatch.setenv("SUPPORT_EMAIL", "zitlas1111@gmail.com")
    monkeypatch.setenv("SUPPORT_EMAIL_PASSWORD", "abcdefghijklmnop")
    support_service.SMTP_HOST = "127.0.0.1"
    support_service.SMTP_PORT = blackhole.port
    support_service.SMTP_TIMEOUT = smtp_timeout
    support_routes.SEND_DEADLINE_SECONDS = deadline


# ── The regression itself ────────────────────────────────────────────────────

def test_a_hanging_smtp_server_does_not_hang_the_request(db, blackhole, monkeypatch):
    """The endpoint must ALWAYS answer, even when SMTP never speaks."""
    _point_at(blackhole, monkeypatch)

    started = time.monotonic()
    res = make_app(db).post("/api/support/contact", json=BODY)
    elapsed = time.monotonic() - started

    assert res.status_code == 504, res.text
    # Comfortably inside the mobile client's 30s budget.
    assert elapsed < 10, f"request took {elapsed:.1f}s — client would time out"


def test_the_response_names_the_stall_rather_than_failing_silently(
        db, blackhole, monkeypatch):
    _point_at(blackhole, monkeypatch)

    detail = make_app(db).post("/api/support/contact", json=BODY).json()["detail"]
    assert detail["code"] == "smtp_unreachable"
    assert detail["stage"] == "smtp_send"
    # The hint must point at the actual production cause.
    assert "outbound SMTP" in detail["hint"]
    assert str(blackhole.port) in detail["hint"]


def test_no_conversation_is_created_when_mail_never_leaves(
        db, blackhole, monkeypatch):
    """Send-first still holds under a timeout: no orphan threads."""
    _point_at(blackhole, monkeypatch)

    make_app(db).post("/api/support/contact", json=BODY)
    assert support_service.list_conversations_for_user(db, ATHLETE["uid"]) == []


def test_repeated_timeouts_stay_bounded(db, blackhole, monkeypatch):
    """Three retries must cost ~3 deadlines, not pile up or degrade."""
    _point_at(blackhole, monkeypatch, smtp_timeout=1.0, deadline=3.0)
    client = make_app(db)

    started = time.monotonic()
    for _ in range(3):
        assert client.post("/api/support/contact", json=BODY).status_code == 504
    elapsed = time.monotonic() - started
    assert elapsed < 20, f"three attempts took {elapsed:.1f}s"


def test_the_deadline_beats_the_socket_timeout_when_smtp_stalls_late(
        db, blackhole, monkeypatch):
    """Even with a GENEROUS per-socket timeout, the route-level deadline is
    what ends the request — the property smtplib alone cannot provide, because
    it bounds each operation separately rather than the sequence as a whole.

    Asserted on the error text rather than wall-clock: `asyncio.wait_for`
    cannot kill the worker thread, and TestClient's blocking portal waits for
    that thread even though a real uvicorn worker has already flushed the
    response. Timing here would measure the harness, not the endpoint.
    """
    _point_at(blackhole, monkeypatch, smtp_timeout=6.0, deadline=2.0)

    res = make_app(db).post("/api/support/contact", json=BODY)

    assert res.status_code == 504
    detail = res.json()["detail"]
    assert detail["code"] == "smtp_unreachable"
    # "exceeded 2s" proves the ROUTE deadline fired first. A socket-level
    # failure would have surfaced as SMTPServerDisconnected at ~6s instead.
    assert "exceeded 2s" in detail["hint"] or "2s" in detail["hint"], detail


def test_a_reply_send_is_bounded_too(db, blackhole, monkeypatch):
    """The follow-up path shares the same deadline."""
    # Seed a conversation without touching SMTP.
    cid = support_service.create_conversation(
        db, uid=ATHLETE["uid"], user_name="Test Athlete",
        user_email="athlete@example.com", subject="S", category="General")
    support_service.add_message(db, cid, sender_type="user",
                                sender_id=ATHLETE["uid"], message="first")

    _point_at(blackhole, monkeypatch)

    started = time.monotonic()
    res = make_app(db).post(f"/api/support/conversations/{cid}/messages",
                            json={"message": "does this hang?"})
    elapsed = time.monotonic() - started

    assert res.status_code == 504
    assert elapsed < 10
    # The undelivered reply must not have been appended.
    assert len(support_service.list_messages(db, cid)) == 1


# ── Configuration guards ─────────────────────────────────────────────────────

def test_smtp_timeout_is_finite_and_under_the_client_budget():
    """The shipped bug was a MISSING timeout, i.e. an infinite one."""
    assert support_service.SMTP_TIMEOUT > 0
    assert support_service.SMTP_TIMEOUT < 30, "must beat Env.apiTimeout (30s)"


def test_send_deadline_is_finite_and_under_the_client_budget():
    assert support_routes.SEND_DEADLINE_SECONDS > 0
    assert support_routes.SEND_DEADLINE_SECONDS < 30, \
        "the response must arrive before the mobile client gives up"


def test_every_smtp_connection_passes_an_explicit_timeout():
    """Guards the exact defect: `smtplib.SMTP(host, port)` with no timeout."""
    import inspect

    source = inspect.getsource(support_service.send_support_email)
    assert "smtplib.SMTP(" in source
    assert "timeout=" in source, "SMTP opened without an explicit timeout"

    # And the health probe, which also dials Gmail.
    probe = inspect.getsource(support_routes.admin_email_health)
    assert "timeout=" in probe, "health probe opened SMTP without a timeout"
