"""
ZITLAS — Firestore Admin access (backend/services/firestore_service.py)

The Personal Coaching escrow flow (routes/coaching.py) is the first feature
in this backend that needs to read/write Firestore server-side — every
other route is deliberately Firestore-free (see routes/certificates.py's
docstring). Wallet reservations must be enforced where the caller can't
spoof the check, which means the balance/reservation math has to live here,
not in client JS.

Uses google-cloud-firestore directly (not the firebase-admin package,
which this codebase avoids everywhere else — see push_service.py) with the
same service-account credential source as FCM push.

Without FIREBASE_SERVICE_ACCOUNT_JSON/_FILE configured, get_client()
returns None — callers in routes/coaching.py must fail closed (503), unlike
push's silent no-op, because a coaching request that "succeeds" without
actually reserving money would be a real financial bug. config_error()
below is what routes/coaching.py surfaces in that 503's response body, so
"service unavailable" never ships without the actual reason attached.
"""

from __future__ import annotations

import traceback

from google.cloud import firestore

from services.google_credentials import last_error, load_credentials

_PROJECT_ID = "zitlas-b8677"
_SCOPE = "https://www.googleapis.com/auth/datastore"

_client: firestore.Client | None = None
_attempted = False
_construction_error: str | None = None


def get_client() -> firestore.Client | None:
    """Lazy-load and cache the Firestore Admin client. Returns None (and
    logs + records why, see config_error()) when unconfigured or when
    client construction itself fails."""
    global _client, _attempted, _construction_error
    if _client is not None:
        return _client
    if _attempted:
        return None
    _attempted = True

    print("[FIRESTORE SERVICE] initializing Firestore Admin client...")
    creds = load_credentials([_SCOPE])
    if creds is None:
        print("[FIRESTORE SERVICE] no credentials available — client stays None "
              "(see the [GOOGLE CREDENTIALS] log line above for the exact reason: "
              "most likely FIREBASE_SERVICE_ACCOUNT_JSON / FIREBASE_SERVICE_ACCOUNT_FILE "
              "is not set in this environment)")
        return None

    try:
        _client = firestore.Client(project=_PROJECT_ID, credentials=creds)
        print(f"[FIRESTORE SERVICE] client initialized OK — project={_PROJECT_ID}")
        # WHICH DATABASE, AND WHO DECIDED. Production was failing every read
        # with `InvalidArgument: 400 Invalid database id %28default%29` — a
        # percent-encoded "(default)" — while the identical code and library
        # versions worked locally. Nothing in this repo passes a database id,
        # so the value comes from the deployed environment; these lines make
        # the next deploy's logs say so outright instead of leaving it to be
        # inferred from a swallowed exception three layers up.
        import os as _os
        print("[FIRESTORE SERVICE] database_id="
              f"{getattr(_client, '_database', '(unknown)')!r} "
              f"library={getattr(firestore, '__version__', '?')}")
        _influencers = {k: v for k, v in _os.environ.items()
                        if ("FIRESTORE" in k or "DATASTORE" in k
                            or k in ("GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT"))}
        if _influencers:
            print(f"[FIRESTORE SERVICE] env influencing Firestore: {_influencers}")
    except Exception as e:
        _construction_error = f"{type(e).__name__}: {e}"
        print(f"[FIRESTORE SERVICE] client construction FAILED: {_construction_error}")
        print(traceback.format_exc())
        _client = None
        return None

    return _client


def is_configured() -> bool:
    return get_client() is not None


def config_error() -> str | None:
    """Human-readable reason get_client() returned None — either a missing
    credential (from google_credentials.last_error) or a client-construction
    failure (bad project id, malformed key, network error at init, etc.)."""
    return _construction_error or last_error([_SCOPE])
