"""
ZITLAS — every composite query has an index (backend/tests/test_firestore_indexes.py)

THE BUG THIS PINS. Render logs filled with:

    google.api_core.exceptions.FailedPrecondition: 400
    The query requires an index.

`firestore.indexes.json` was empty (`"indexes": []`) while two APScheduler
sweeps ran EVERY 15 MINUTES with equality + range filters, which Firestore
cannot serve from single-field indexes:

    personal_coach_requests  status ==      + expiresAt <=
    personal_coaching        status == active + endDateTs <=

So the 48h request-expiry and 30d relationship-expiry sweeps never completed —
the error was not cosmetic, it meant those sweeps had silently stopped working.

This file asserts the declared indexes still cover the queries the code
actually issues, so adding a filter without adding an index fails here rather
than in production 15 minutes later.

Run: python -m pytest tests/test_firestore_indexes.py -q
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

REPO = Path(__file__).resolve().parents[2]
INDEXES = REPO / "firestore.indexes.json"


def _declared() -> set[tuple[str, tuple[str, ...]]]:
    """{(collection, (field, field, …)), …} from firestore.indexes.json."""
    data = json.loads(INDEXES.read_text(encoding="utf-8"))
    return {
        (i["collectionGroup"], tuple(f["fieldPath"] for f in i["fields"]))
        for i in data.get("indexes", [])
    }


class TestTheIndexFileItself:
    def test_it_exists_and_is_valid_json(self):
        assert INDEXES.exists(), "firestore.indexes.json is missing"
        data = json.loads(INDEXES.read_text(encoding="utf-8"))
        assert isinstance(data.get("indexes"), list)

    def test_it_is_not_empty(self):
        """It WAS empty — that is the whole bug."""
        assert _declared(), "no indexes declared; the sweeps will fail again"

    def test_firebase_json_points_at_it(self):
        cfg = json.loads((REPO / "firebase.json").read_text(encoding="utf-8"))
        assert cfg["firestore"]["indexes"] == "firestore.indexes.json"

    def test_every_entry_is_well_formed(self):
        data = json.loads(INDEXES.read_text(encoding="utf-8"))
        for i in data["indexes"]:
            assert i.get("collectionGroup")
            assert i.get("queryScope") == "COLLECTION"
            assert len(i.get("fields") or []) >= 2, (
                "a single-field index is created automatically — declaring "
                "one here suggests a mistake")
            for f in i["fields"]:
                assert f.get("fieldPath")
                assert f.get("order") in ("ASCENDING", "DESCENDING")


class TestTheSweepQueriesAreCovered:
    """The two queries that were actually failing every 15 minutes."""

    def test_expired_request_sweep(self):
        assert ("personal_coach_requests", ("status", "expiresAt")) in _declared()

    def test_expired_relationship_sweep(self):
        assert ("personal_coaching", ("status", "endDateTs")) in _declared()

    def test_the_sweeps_still_issue_those_queries(self):
        """If the query changes shape, the index above stops matching it —
        this catches that at test time rather than in production."""
        src = (REPO / "backend" / "services" / "coaching_sweep.py").read_text(
            encoding="utf-8")
        assert 'FieldFilter("status", "==", "pending")' in src
        assert 'FieldFilter("expiresAt", "<=", now_iso)' in src
        assert 'FieldFilter("status", "==", "active")' in src
        assert 'FieldFilter("endDateTs", "<=", now())' in src


class TestOnlyGenuinelyRequiredIndexesAreDeclared:
    """Equality-ONLY queries are deliberately absent.

    Each was run against the live project and returned results without a
    composite index — Firestore serves them by merging single-field indexes.
    Declaring them would be noise, and the instruction was explicitly not to
    create indexes blindly.
    """

    @pytest.mark.parametrize("collection,fields", [
        ("personal_coach_requests", ("athleteId", "status")),
        ("personal_coach_requests", ("athleteId", "expertId", "requestType")),
        ("expert_ratings", ("expertId", "status")),
        ("device_tokens", ("uid", "enabled")),
    ])
    def test_equality_only_queries_are_not_declared(self, collection, fields):
        assert (collection, fields) not in _declared(), (
            f"{collection}{fields} is equality-only and was verified to work "
            "without a composite index")

    def test_exactly_the_two_range_queries_are_declared(self):
        assert _declared() == {
            ("personal_coach_requests", ("status", "expiresAt")),
            ("personal_coaching", ("status", "endDateTs")),
        }
