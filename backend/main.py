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
        from services.coaching_sweep import sweep_expired_relationships, sweep_expired_requests

        _coaching_scheduler = AsyncIOScheduler()
        _coaching_scheduler.add_job(
            lambda: asyncio.create_task(asyncio.to_thread(sweep_expired_requests)),
            "interval", minutes=15, id="coaching_sweep",
        )
        # Separate job, same interval — a 30-day expiry window doesn't need
        # finer granularity than the 48h one, and reusing the interval
        # avoids standing up a second scheduler for it.
        _coaching_scheduler.add_job(
            lambda: asyncio.create_task(asyncio.to_thread(sweep_expired_relationships)),
            "interval", minutes=15, id="coaching_relationship_sweep",
        )
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
        "http://127.0.0.1:8000",
        "http://localhost:8000",
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
app.include_router(rag.router,        prefix="/api/rag",        tags=["RAG"])
app.include_router(support.router,    prefix="/api/support",    tags=["Support"])
app.include_router(review.router,     prefix="/api/review",     tags=["Review"])
app.include_router(review_apply.router, prefix="/api/review",    tags=["Review Apply"])
app.include_router(system.router,     prefix="/api/system",     tags=["System"])
app.include_router(chat.router,       prefix="/api/chat",       tags=["Chat"])
app.include_router(certificates.router, prefix="/api/certificates", tags=["Certificates"])
app.include_router(coaching.router,     prefix="/api/coaching",    tags=["Coaching"])
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

# ── Serve frontend (must be last — catches everything else) ───────────────────
app.mount("/", StaticFiles(directory=str(FRONTEND_DIR)), name="frontend")
