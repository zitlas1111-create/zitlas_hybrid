"""
ZITLAS — interactive API docs are local-only (backend/tests/test_api_docs_exposure.py)

/docs, /redoc and /openapi.json publish every route and its exact request
schema. That is a development asset and a production liability: several
endpoints are not yet authenticated, and the schema is precisely what turns a
rejected request into an accepted one.

WHY THE GATE IS ENVIRONMENT-DETECTED RATHER THAN CONFIGURED. Railway injects
RAILWAY_* into every deployed container and nothing sets them on a
developer's machine, so the correct behaviour happens in both places with no
.env step and no way to forget one. ENABLE_API_DOCS overrides in either
direction for the cases that need it (a staging service that wants docs; a
local run that does not).

These tests reimport `main` under different environments, so they must
control the exact variables the gate reads and restore them afterwards.
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent.parent))

_GATE_VARS = (
    "RAILWAY_ENVIRONMENT",
    "RAILWAY_ENVIRONMENT_NAME",
    "RAILWAY_PROJECT_ID",
    "RAILWAY_SERVICE_ID",
    "ENABLE_API_DOCS",
)

DOC_PATHS = ("/docs", "/redoc", "/openapi.json")


@pytest.fixture
def app_under(monkeypatch):
    """Builds the real app with a controlled environment.

    KB pre-warm is disabled so importing main never starts loading FAISS
    indexes during a unit test.
    """
    def _build(**env: str):
        for name in _GATE_VARS:
            monkeypatch.delenv(name, raising=False)
        monkeypatch.setenv("DISABLE_KB_PREWARM", "true")
        for key, value in env.items():
            monkeypatch.setenv(key, value)
        sys.modules.pop("main", None)
        return importlib.import_module("main").app

    yield _build
    # Leave no half-configured module behind for the next test file.
    sys.modules.pop("main", None)


class TestDocsAreOffInProduction:
    @pytest.mark.parametrize("marker", [
        "RAILWAY_ENVIRONMENT",
        "RAILWAY_ENVIRONMENT_NAME",
        "RAILWAY_PROJECT_ID",
        "RAILWAY_SERVICE_ID",
    ])
    def test_any_railway_marker_disables_them(self, app_under, marker):
        client = TestClient(app_under(**{marker: "production"}))
        for path in DOC_PATHS:
            assert client.get(path).status_code == 404, (
                f"{path} is reachable on a deployed environment")

    def test_the_routes_are_not_registered_at_all(self, app_under):
        """404 because the route never exists — not because a guard rejects
        it. A guard could be bypassed; an absent route cannot."""
        app = app_under(RAILWAY_ENVIRONMENT="production")
        paths = {r.path for r in app.routes if hasattr(r, "path")}
        for path in DOC_PATHS:
            assert path not in paths


class TestDocsStayOnLocally:
    def test_no_railway_markers_means_docs_work(self, app_under):
        client = TestClient(app_under())
        for path in DOC_PATHS:
            assert client.get(path).status_code == 200, (
                f"{path} must keep working for local development")


class TestTheOverrideWorksBothWays:
    def test_it_can_re_enable_docs_on_a_deployed_environment(self, app_under):
        client = TestClient(
            app_under(RAILWAY_ENVIRONMENT="production", ENABLE_API_DOCS="true"))
        for path in DOC_PATHS:
            assert client.get(path).status_code == 200

    def test_it_can_disable_docs_locally(self, app_under):
        client = TestClient(app_under(ENABLE_API_DOCS="false"))
        for path in DOC_PATHS:
            assert client.get(path).status_code == 404

    @pytest.mark.parametrize("truthy", ["1", "true", "TRUE", "yes", "on"])
    def test_truthy_spellings_match_the_projects_convention(self, app_under, truthy):
        client = TestClient(
            app_under(RAILWAY_ENVIRONMENT="production", ENABLE_API_DOCS=truthy))
        assert client.get("/docs").status_code == 200


class TestNothingElseChanged:
    """The gate must touch documentation only — not routing, not auth."""

    def test_the_railway_healthcheck_still_answers(self, app_under):
        # railway.json's healthcheckPath. If this 404s, every deploy fails.
        client = TestClient(app_under(RAILWAY_ENVIRONMENT="production"))
        res = client.get("/api/auth/health")
        assert res.status_code == 200
        assert res.json().get("status") == "ready"

    def test_api_routes_are_unaffected(self, app_under):
        client = TestClient(app_under(RAILWAY_ENVIRONMENT="production"))
        assert client.get("/api/system/trial-mode").status_code == 200

    def test_protected_routes_still_reject_anonymous_callers(self, app_under):
        client = TestClient(app_under(RAILWAY_ENVIRONMENT="production"))
        for path in ("/api/entitlements", "/api/trial-reports"):
            assert client.get(path).status_code in (401, 403)

    def test_the_route_table_is_the_same_size_apart_from_the_doc_routes(
            self, app_under):
        local = {r.path for r in app_under().routes if hasattr(r, "path")}
        deployed = {r.path for r in
                    app_under(RAILWAY_ENVIRONMENT="production").routes
                    if hasattr(r, "path")}
        # Exactly the documentation paths differ; every API route survives.
        # /openapi.json is the only doc path that is a plain route on both.
        assert local - deployed <= set(DOC_PATHS) | {"/docs/oauth2-redirect"}
        assert deployed - local == set()
