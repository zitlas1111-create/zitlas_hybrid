"""
ZITLAS — the logout button must always work (backend/tests/test_logout_flow.py)

THE BUG THIS PINS. The website logout button stopped responding in production.
Both logout screens wired their button as ONE STEP IN A BARE SEQUENCE:

    profile.js  init()      → … → initLogoutModal() → …
    expert-dashboard.js     renderAll() → … → initLogout() → …

A throw in ANY earlier step — a malformed cached profile, a missing element,
a failed render — aborted the rest of the chain. When that happened before the
logout wiring, the click listener was never attached: the button did nothing,
silently, with no error a user could see.

Signing out is the one control that has to survive a broken page, because a
broken page is exactly when somebody reaches for it. So logout is now wired
FIRST and every other step runs in isolation.

These are source-level assertions rather than browser tests: the website has
no JS test runner, and the properties being protected are structural.

Run: python -m pytest tests/test_logout_flow.py -q
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

WEB = Path(__file__).resolve().parents[2] / "frontend" / "website"
PROFILE_JS = WEB / "pages" / "profile" / "profile.js"
PROFILE_HTML = WEB / "pages" / "profile" / "profile.html"
EXPERT_JS = WEB / "pages" / "experts" / "expert-dashboard.js"
EXPERT_HTML = WEB / "pages" / "experts" / "expert-dashboard.html"


def _read(p: Path) -> str:
    if not p.exists():
        pytest.skip(f"{p.name} not reachable from this run")
    return p.read_text(encoding="utf-8")


# ── The button exists and is wired ───────────────────────────────────────────

class TestTheButtonIsWired:
    def test_athlete_logout_elements_exist(self):
        html = _read(PROFILE_HTML)
        # profile.js bails out entirely if ANY of these is missing.
        for el in ("logoutBtn", "logoutModal", "logoutCancel", "logoutConfirm"):
            assert f'id="{el}"' in html, f"{el} missing — the handler returns early"

    def test_expert_logout_elements_exist(self):
        html = _read(EXPERT_HTML)
        assert 'id="edLogoutBtn"' in html or 'id="edLogoutFullBtn"' in html

    def test_athlete_logout_is_wired_before_anything_else(self):
        """The fix: a failure elsewhere on the page can no longer prevent it."""
        js = _read(PROFILE_JS)
        init = js[js.index("function init() {"):]
        init = init[:init.index("\n  }")]
        first = init.index("initLogoutModal")
        for later in ("loadAthleteProfile", "initAppearanceModal",
                      "initSettingsItems", "initEditProfile"):
            assert first < init.index(later), (
                f"{later} runs before logout is wired — if it throws, the "
                "logout button is dead")

    def test_expert_logout_is_wired_before_anything_else(self):
        js = _read(EXPERT_JS)
        block = js[js.index("function renderAll(baseExpert) {"):]
        block = block[:block.index("\n}")]
        first = block.index("initLogout")
        for later in ("renderHeader", "renderDashboard", "renderProfile"):
            assert first < block.index(later), (
                f"{later} runs before logout is wired")

    def test_each_init_step_is_isolated(self):
        assert "function step(name, fn)" in _read(PROFILE_JS)
        assert "function _edStep(name, fn)" in _read(EXPERT_JS)


# ── The handler actually signs out ───────────────────────────────────────────

class TestItActuallySignsOut:
    @pytest.mark.parametrize("path", ["profile", "expert"])
    def test_firebase_signout_is_called(self, path):
        js = _read(PROFILE_JS if path == "profile" else EXPERT_JS)
        assert "ZitlasAuth.signOut()" in js, (
            "clearing localStorage is not signing out — the session would "
            "survive and the next page load would restore it")

    @pytest.mark.parametrize("path", ["profile", "expert"])
    def test_local_auth_state_is_cleared(self, path):
        js = _read(PROFILE_JS if path == "profile" else EXPERT_JS)
        assert "clearUserCache" in js

    @pytest.mark.parametrize("path", ["profile", "expert"])
    def test_signout_happens_before_the_cache_purge(self, path):
        """Purging while still signed in lets an in-flight sync re-upload the
        account it was meant to wipe."""
        js = _read(PROFILE_JS if path == "profile" else EXPERT_JS)
        assert js.index("ZitlasAuth.signOut()") < js.index("clearUserCache")


# ── It finishes even when something fails ────────────────────────────────────

class TestLogoutIsDefensive:
    def test_logout_does_not_depend_on_a_firestore_query(self):
        """Firestore being unavailable must never trap a user in a session."""
        for js in (_read(PROFILE_JS), _read(EXPERT_JS)):
            block = js[js.index("signOut()"):]
            block = block[:block.index("login.html")]
            for forbidden in (".where(", ".stream(", "await ZitlasDB"):
                assert forbidden not in block, (
                    f"logout queries Firestore ({forbidden}) after sign-out — "
                    "it would hang or throw when Firestore is unavailable")

    def test_a_failed_cache_purge_still_navigates(self):
        for js in (_read(PROFILE_JS), _read(EXPERT_JS)):
            assert "cache purge failed, leaving anyway" in js

    @pytest.mark.parametrize("path", ["profile", "expert"])
    def test_navigation_uses_replace_not_assign(self, path):
        """Back must not reopen a protected page after signing out."""
        js = _read(PROFILE_JS if path == "profile" else EXPERT_JS)
        block = js[js.index("clearUserCache"):]
        assert "window.location.replace(" in block, (
            "href/assign leaves the protected page in history — Back would "
            "reopen the dashboard of an account that is signed out")


# ── Logout is not affected by the Firestore index bug ────────────────────────

class TestLogoutIsUnaffectedByTheIndexError:
    def test_the_failing_sweeps_are_scheduler_only(self):
        """PART 4: the FailedPrecondition came from APScheduler jobs, never
        from a request path — so it could not have blocked logout."""
        routes = Path(__file__).resolve().parents[1] / "routes"
        for f in routes.glob("*.py"):
            assert "sweep_expired" not in f.read_text(encoding="utf-8"), (
                f"{f.name} calls a sweep in a request path")

    def test_logout_makes_no_backend_call_at_all(self):
        for js in (_read(PROFILE_JS), _read(EXPERT_JS)):
            block = js[js.index("signOut()"):]
            block = block[:block.index("login.html")]
            assert "fetch(" not in block, (
                "logout must not depend on the backend being reachable")
