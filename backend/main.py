"""
ZITLAS Backend — main.py
FastAPI server that serves the frontend and hosts all API routes.

Run from the backend/ directory:
    uvicorn main:app --reload

App opens at:
    http://127.0.0.1:8000
"""

import asyncio
import os
import sys
from contextlib import asynccontextmanager
from pathlib import Path

# LLM output can contain characters (non-breaking hyphens, emoji) that a
# cp1252 console can't encode; without this, a mere log print of a reply
# raises UnicodeEncodeError inside the request handler and gets mistaken
# for a provider failure. No-op on UTF-8 terminals (Render/Linux).
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles

# Load environment variables from .env before anything else
load_dotenv(Path(__file__).parent / ".env")

from routes import auth, player, diet, assessment
from routes import ai
from routes import chat
from routes import support
from routes import rag
from routes import review
from routes import system
from routes import certificates
from routes import coaching
from routes import meal_ai
from routes import payment
from routes import admin
from routes import notifications
from routes import review_apply
from routes import voice
from routes import swap
from routes import recipes
from routes import expert_ratings
from routes import creator_recipes
from routes import entitlements as entitlements_routes
from services import rag_service

# ── Directory paths ──────────────────────────────────────────────────────────
BASE_DIR     = Path(__file__).resolve().parent               # backend/
# The website lives at frontend/website/ so that frontend/ can hold any future
# web target alongside it; mobile/ is the Flutter client and is not served here.
FRONTEND_DIR = BASE_DIR.parent / "frontend" / "website"     # frontend/website/

# Fails fast with the exact resolved path rather than letting StaticFiles'
# own (much less specific) RuntimeError surface during app import. A missing
# directory here is a deployment/build-context problem, not a path-math bug:
# if the deploy host's build only ships BASE_DIR's own subtree (e.g. a
# platform "Root Directory" setting scoped to backend/ instead of the repo
# root), frontend/website is never copied in at all, and no path computed
# from __file__ can conjure a directory that doesn't exist on disk.
if not FRONTEND_DIR.is_dir():
    raise RuntimeError(
        f"Frontend directory not found: {FRONTEND_DIR}\n"
        f"(resolved from backend/main.py at {BASE_DIR})\n"
        "Expected layout: <repo root>/backend/main.py alongside "
        "<repo root>/frontend/website/. If this is a hosting platform "
        "deployment, this almost always means the service's build context "
        "is scoped to backend/ only (e.g. a 'Root Directory' setting), so "
        "frontend/ was never included in the build — that must be fixed in "
        "the platform's deployment configuration, not in this file."
    )


# ── Lifespan: startup tasks ───────────────────────────────────────────────────

async def _prewarm_kb(goal: str) -> None:
    """Pre-warm one goal KB in the background; failures never crash the server."""
    from services.kb_manager import kb_manager
    try:
        await asyncio.to_thread(kb_manager.get_kb, goal)
        print(f"[STARTUP] {goal} KB pre-warmed OK")
    except Exception as exc:
        print(f"[STARTUP] {goal} KB pre-warm failed (non-fatal): {exc}")


# Personal Coaching escrow — releases reservations the expert never
# responded to within 48h. In-process (not an external cron) by deliberate
# choice: this backend runs as a single Render free-tier web service with
# no cron/worker slot; sweeps simply pause while the dyno is asleep on
# inactivity and catch up on the next wake, which is an accepted tradeoff
# for this deployment. See services/coaching_sweep.py.


# ── Scheduled background jobs ────────────────────────────────────────────────
#
# These MUST be `async def`, and that is the whole fix for a production error
# that fired on EVERY tick:
#
#   File "/app/backend/main.py", line 173, in <lambda>
#     lambda: asyncio.create_task(asyncio.to_thread(support_service.ingest_replies))
#   RuntimeError: no running event loop
#   RuntimeWarning: coroutine 'to_thread' was never awaited
#
# AsyncIOScheduler inspects each job callable. A COROUTINE function is awaited
# on the event loop; a PLAIN function is handed to a worker thread instead —
# and a worker thread has no running loop, so `asyncio.create_task()` raised
# RuntimeError immediately. The `asyncio.to_thread(...)` coroutine had already
# been constructed by then and was therefore never awaited, which is the second
# warning. Net effect: the job body NEVER RAN, once per interval, silently.
#
# All THREE jobs shared the broken lambda. The support poll merely surfaced it
# first because it runs every 60s while the coaching sweeps run every 15 min —
# meaning the 48h request expiry and 30d relationship expiry sweeps had also
# never executed in production.
#
# `await asyncio.to_thread(fn)` is the correct boundary: the scheduler awaits
# the job on the loop, and the blocking IMAP/Firestore work runs off it.
#
# Deliberately named module-level functions rather than lambdas or
# functools.partial — `iscoroutinefunction()` must be unambiguously True for
# APScheduler to take the await path, and these are also importable by
# tests/test_scheduler_jobs.py.


async def job_sweep_expired_requests() -> None:
    """48h coaching-request expiry sweep."""
    from services.coaching_sweep import sweep_expired_requests
    await asyncio.to_thread(sweep_expired_requests)


async def job_sweep_expired_relationships() -> None:
    """30d coaching-relationship expiry sweep."""
    from services.coaching_sweep import sweep_expired_relationships
    await asyncio.to_thread(sweep_expired_relationships)


async def job_support_reply_ingest() -> None:
    """Pulls replies typed in the ZITLAS Gmail back into the athlete's in-app
    Help Center conversation. Idempotency (no double-import) is owned by
    support_service.ingest_replies itself, which marks each message
    processed — this wrapper only fixes where the code runs."""
    from services import support_service
    await asyncio.to_thread(support_service.ingest_replies)


_coaching_scheduler = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _coaching_scheduler

    # Startup: initialize logger + environment only.
    # rag_service.initialize() is now a lightweight no-op that sets _is_ready=True.
    await asyncio.to_thread(rag_service.initialize)

    try:
        import psutil as _psutil
        _rss = _psutil.Process().memory_info().rss / 1024 / 1024
        print(f"[STARTUP] RAM at startup: {_rss:.1f} MB")
    except Exception:
        pass

    # Skip KB pre-warm on memory-constrained deployments (e.g. Render free tier).
    # Set DISABLE_KB_PREWARM=true in the environment to disable.
    if os.getenv("DISABLE_KB_PREWARM", "false").lower() != "true":
        asyncio.create_task(_prewarm_kb("weight_loss"))
    else:
        print("[STARTUP] KB pre-warm disabled (DISABLE_KB_PREWARM=true) — KBs load on first request")

    # Surface Firestore Admin configuration status at boot, not just on the
    # first request — this is the #1 thing to check in Render's logs if
    # /api/coaching/* returns 503 (missing FIREBASE_SERVICE_ACCOUNT_JSON /
    # FIREBASE_SERVICE_ACCOUNT_FILE in the environment is the usual cause).
    try:
        from services import firestore_service
        if firestore_service.is_configured():
            print("[STARTUP] Firestore Admin (coaching escrow) — CONFIGURED")
        else:
            print(f"[STARTUP] Firestore Admin (coaching escrow) — NOT CONFIGURED: "
                  f"{firestore_service.config_error()} — /api/coaching/* will 503 until this is set")
    except Exception as exc:
        print(f"[STARTUP] Firestore Admin config check itself failed (non-fatal): {exc}")

    try:
        from services import razorpay_service
        if razorpay_service.is_configured():
            print("[STARTUP] Razorpay — CONFIGURED")
        else:
            print("[STARTUP] Razorpay — NOT CONFIGURED: set RAZORPAY_KEY_ID and RAZORPAY_KEY_SECRET — "
                  "/api/payment/* will fail until this is set")
    except Exception as exc:
        print(f"[STARTUP] Razorpay config check itself failed (non-fatal): {exc}")

    try:
        from apscheduler.schedulers.asyncio import AsyncIOScheduler

        _coaching_scheduler = AsyncIOScheduler()
        _coaching_scheduler.add_job(
            job_sweep_expired_requests,
            "interval", minutes=15, id="coaching_sweep",
        )
        # Separate job, same interval — a 30-day expiry window doesn't need
        # finer granularity than the 48h one, and reusing the interval
        # avoids standing up a second scheduler for it.
        _coaching_scheduler.add_job(
            job_sweep_expired_relationships,
            "interval", minutes=15, id="coaching_relationship_sweep",
        )
        # Support Help Center: pull replies typed in the ZITLAS Gmail back
        # into the athlete's in-app conversation. Shares the coaching
        # scheduler rather than standing up a second one.
        try:
            from services import support_service

            if support_service.is_configured():
                _coaching_scheduler.add_job(
                    job_support_reply_ingest,
                    "interval",
                    seconds=int(os.environ.get("SUPPORT_IMAP_POLL_SECONDS", "60")),
                    id="support_reply_ingest",
                    # An IMAP round trip can outlast the 60s interval. Both
                    # values are APScheduler defaults, stated explicitly
                    # because they matter here: max_instances=1 stops two
                    # ingests racing the same mailbox (a real duplicate-import
                    # risk), and coalesce collapses a backlog after a stall
                    # into one run instead of replaying every missed tick.
                    max_instances=1,
                    coalesce=True,
                )
                print("[STARTUP] support reply ingestion scheduled (IMAP poll)")
            else:
                print("[STARTUP] support reply ingestion DISABLED — "
                      "SUPPORT_EMAIL / SUPPORT_EMAIL_PASSWORD not set")
        except Exception as exc:
            print(f"[STARTUP] support ingest scheduler failed (non-fatal): {exc}")

        _coaching_scheduler.start()
        print("[STARTUP] coaching expiry sweeps scheduled (48h requests + 30d relationships, every 15 min)")
    except Exception as exc:
        print(f"[STARTUP] coaching sweep scheduler failed to start (non-fatal): {exc}")

    yield

    if _coaching_scheduler is not None:
        _coaching_scheduler.shutdown(wait=False)


# ── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    lifespan=lifespan,
    title="ZITLAS API",
    description="AI-powered weight-loss and nutrition platform — backend API",
    version="2.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
)

# ── CORS (needed once frontend calls APIs) ───────────────────────────────────
# Same-origin calls (the website's own JS fetching '/api/...' from the same
# host FastAPI serves it from, including inside the Flutter coaching WebView)
# never hit this middleware at all — CORS is a browser cross-origin check,
# so neither of these production entries was the cause of the coaching-load
# failure investigated alongside this change. They were simply missing:
# this list still only had the two local-dev origins, so any genuinely
# cross-origin caller (a future separate frontend, a browser extension, a
# different subdomain) hitting this API from either production domain would
# have been rejected. www.zitlas.com is the canonical production origin;
# bare zitlas.com is kept allowed per "both domains may remain supported".
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://www.zitlas.com",
        "https://zitlas.com",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── API routers ───────────────────────────────────────────────────────────────
app.include_router(auth.router,       prefix="/api/auth",       tags=["Auth"])
app.include_router(player.router,     prefix="/api/user",       tags=["User"])
app.include_router(diet.router,       prefix="/api/diet",       tags=["Diet"])
app.include_router(assessment.router, prefix="/api/assessment", tags=["Assessment"])
app.include_router(ai.router,         prefix="/api/ai",         tags=["AI"])
app.include_router(voice.router,      prefix="/api/voice",      tags=["Voice"])
app.include_router(swap.router,       prefix="/api/diet",       tags=["Swap"])
# One source of truth for tier, usage and both plans — the comparison UI
# renders from this rather than hard-coding the numbers.
app.include_router(entitlements_routes.router, prefix="/api/entitlements",
                   tags=["Entitlements"])
app.include_router(recipes.router,    prefix="/api/recipes",    tags=["Recipes"])
app.include_router(rag.router,        prefix="/api/rag",        tags=["RAG"])
app.include_router(support.router,    prefix="/api/support",    tags=["Support"])
app.include_router(review.router,     prefix="/api/review",     tags=["Review"])
app.include_router(review_apply.router, prefix="/api/review",    tags=["Review Apply"])
app.include_router(system.router,     prefix="/api/system",     tags=["System"])
app.include_router(chat.router,       prefix="/api/chat",       tags=["Chat"])
app.include_router(certificates.router, prefix="/api/certificates", tags=["Certificates"])
app.include_router(coaching.router,     prefix="/api/coaching",    tags=["Coaching"])
app.include_router(expert_ratings.router, prefix="/api/expert-ratings", tags=["Expert Ratings"])
app.include_router(creator_recipes.router, prefix="/api/creator-recipes", tags=["Creator Recipes"])
app.include_router(meal_ai.router,      prefix="/api/meal",        tags=["Meal AI"])
app.include_router(payment.router,      prefix="/api/payment",     tags=["Payment"])
app.include_router(admin.router,        prefix="/api/admin",       tags=["Admin"])
app.include_router(notifications.router, prefix="/api/notifications", tags=["Notifications"])

# ── Root redirect ────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return RedirectResponse(url="/pages/login/login.html")

# ── Serve uploaded chat images ────────────────────────────────────────────────
_UPLOADS_DIR = BASE_DIR / "uploads"
_UPLOADS_DIR.mkdir(exist_ok=True)
app.mount("/uploads", StaticFiles(directory=str(_UPLOADS_DIR)), name="uploads")

# ── Admin Portal at /admin/ ──────────────────────────────────────────────────
#
# The portal's files live at frontend/website/pages/admin/, which the catch-all
# mount below already serves at /pages/admin/index.html. https://zitlas.com/admin/
# returned FastAPI's {"detail":"Not Found"} because that URL resolved to
# frontend/website/admin/ — a directory that does not exist.
#
# This is a second StaticFiles mount rather than a route handler so the portal's
# CSS and JS resolve as siblings: /admin/admin-portal.css and
# /admin/admin-portal.js are served straight from the same directory, with no
# rewriting and no duplicated asset paths. `html=True` is what makes the
# directory URL /admin/ serve index.html — the catch-all below deliberately
# omits it, which is why every other page is linked as an explicit .html file
# (see the root redirect to /pages/login/login.html).
#
# Scope is exactly one directory. It exposes nothing that /pages/admin/ did not
# already expose, and serving the HTML grants no privilege: every /api/admin
# endpoint independently re-verifies the caller's Firebase ID token through
# require_admin, so an unauthenticated visitor who loads this page gets a 403
# from every request it makes.
#
# MUST be registered BEFORE the catch-all — Starlette matches mounts in
# registration order and "/" matches everything.
_ADMIN_DIR = FRONTEND_DIR / "pages" / "admin"
if _ADMIN_DIR.is_dir():
    # Bare /admin (no trailing slash) would otherwise fall through to the
    # catch-all mount and 404 — the exact URL a person types by hand.
    @app.get("/admin", include_in_schema=False)
    def _admin_slash():
        return RedirectResponse(url="/admin/")

    app.mount("/admin", StaticFiles(directory=str(_ADMIN_DIR), html=True), name="admin_portal")
else:
    # Never fail app startup over the admin console: the API and the whole
    # website matter more than one internal tool being reachable.
    print(f"[STARTUP] admin portal directory missing, /admin/ not mounted: {_ADMIN_DIR}")

# ── Serve frontend (must be last — catches everything else) ───────────────────
app.mount("/", StaticFiles(directory=str(FRONTEND_DIR)), name="frontend")
