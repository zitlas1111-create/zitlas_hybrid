"""
ZITLAS — test isolation (backend/tests/conftest.py)

THE TEST SUITE MUST NEVER REACH PRODUCTION FIRESTORE.

It could, and it did. `services/firestore_service.get_client()` builds a real
Admin client from `FIREBASE_SERVICE_ACCOUNT_FILE`, and `backend/.env` points
that at a real service-account key on the developer's machine. Any test that
exercised a code path calling `entitlements.record()` therefore wrote usage
counters straight into the live `zitlas-b8677` project — which is how a
recipe test started failing with 429 after the seventh local `pytest` run:
the suite had genuinely spent a week's recipe allowance in production.

Nothing about that is specific to entitlements. Every service in this backend
reaches Firestore through the same accessor, so without this guard any future
test touching any collection would mutate production data on a laptop.

The guard returns None — "Firestore unavailable" — which every service
already handles, and handles by failing CLOSED (`tier_for_uid` degrades to
free rather than to unlimited). Tests that need real data monkeypatch the
same accessor with `tests/fake_firestore.FakeClient`; because this fixture is
autouse it is applied first, so a test's own patch still wins.
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import firestore_service  # noqa: E402


@pytest.fixture(autouse=True)
def _no_production_firestore(monkeypatch):
    """Cut every test off from the real project, unconditionally."""
    monkeypatch.setattr(firestore_service, "get_client", lambda: None)
    # Some modules cache the client on first use; clear it so a client built
    # by an earlier test cannot be handed to a later one.
    for attr in ("_client", "_db", "_CLIENT"):
        if hasattr(firestore_service, attr):
            monkeypatch.setattr(firestore_service, attr, None, raising=False)
    yield
