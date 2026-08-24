"""
ZITLAS — a free-trial coach's diet must reach the athlete
(backend/tests/test_coach_trial_diet_visibility.py)

THE BUG THIS PINS. A nutritionist accepted a FREE TRIAL, opened the athlete's
diet, modified it, saved successfully — and the athlete kept seeing their
original AI plan with no coach attribution anywhere.

Cause: `plan_type_val = None` for a FREE_TRIAL request (a trial is not one of
the three paid plans), and `/accept` copies that onto
`personal_coaching/{uid}`. The COACH side tolerated `planType: null`; the
ATHLETE side did not, so the published plan was never rendered.

This file pins the backend half of the contract: what a trial actually stores,
and that a trial coach is authorized exactly like a paid one. The client-side
gates are pinned in mobile/test/coach_trial_plan_visibility_test.dart.

Run: python -m pytest tests/test_coach_trial_diet_visibility.py -q
"""

from __future__ import annotations

import inspect
import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import routes.coaching as coaching_routes  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


class TestWhatATrialStores:
    def test_a_trial_stores_a_null_plan_type(self):
        """The fact the whole bug hinges on. Asserted so nobody 'fixes' it by
        inventing a planType and silently changing the pricing branch."""
        src = inspect.getsource(coaching_routes)
        assert "plan_type_val = None" in src
        # …and only inside the trial branch.
        trial = src[src.index("if is_trial:"):]
        assert "plan_type_val = None" in trial[:400]

    def test_the_relationship_carries_the_request_plan_type(self):
        src = inspect.getsource(coaching_routes)
        assert '"planType": req.get("planType")' in src, (
            "if this stops copying the request's planType, the client-side "
            "null default is no longer the right compatibility rule")

    def test_a_trial_is_marked_as_one(self):
        """`coachingType` is what tells the UI it is a trial — the athlete's
        plan visibility must not depend on it, but the label does."""
        src = inspect.getsource(coaching_routes)
        assert '"coachingType": request_type' in src


class TestTheTrialCoachIsAuthorized:
    RULES = REPO / "firestore.rules"

    def test_coach_write_access_does_not_depend_on_plan_type(self):
        """isActiveCoachOf keys on coachId + status only. If it ever gained a
        planType condition, a trial coach would lose write access to
        coaching_plans and the save would fail with permission-denied."""
        rules = self.RULES.read_text(encoding="utf-8")
        fn = rules[rules.index("function isActiveCoachOf(athleteId)"):]
        fn = fn[:fn.index("\n    }")]
        assert "coachId == request.auth.uid" in fn
        assert "status == 'active'" in fn
        assert "planType" not in fn, (
            "a planType condition here would break every free trial")

    def test_only_the_assigned_coach_can_write_the_plan(self):
        """Account isolation: Expert A must not be able to write Expert B's
        athlete's plan."""
        rules = self.RULES.read_text(encoding="utf-8")
        block = rules[rules.index("match /coaching_plans/{athleteUid}"):]
        block = block[:block.index("\n    }")]
        assert "isActiveCoachOf(athleteUid)" in block
        # The athlete themselves may only touch their own selections/context.
        assert "changedOnly(['dietSelections', 'athleteContext'," in block

    def test_the_athlete_cannot_forge_the_coach_plan(self):
        rules = self.RULES.read_text(encoding="utf-8")
        block = rules[rules.index("match /coaching_plans/{athleteUid}"):]
        block = block[:block.index("\n    }")]
        assert "createOmits(['diet', 'training'])" in block, (
            "an athlete could otherwise author a plan and show it back as "
            "their coach's prescription")


class TestTheTrialIsStillFree:
    def test_a_trial_reserves_and_debits_nothing(self):
        src = inspect.getsource(coaching_routes)
        trial = src[src.index("if is_trial:"):]
        assert "amount = 0" in trial[:400]

    def test_the_trial_branch_never_falls_through_to_pricing(self):
        """A trial must stay free even if the platform-free flags are turned
        off later."""
        src = inspect.getsource(coaching_routes)
        assert "PLAN_TO_FIELD[body.planType]" in src
        # The pricing lookup lives in the else branch, never the trial one.
        trial_start = src.index("if is_trial:")
        else_start = src.index("else:", trial_start)
        assert "PLAN_TO_FIELD" not in src[trial_start:else_start]


class TestBothClientsApplyTheSameRule:
    """The gates are in three files across two languages. A fix applied to one
    and forgotten in another means an athlete sees their coach's plan on the
    website and their AI plan in the app."""

    GATES = [
        ("frontend/website/pages/diet/diet.js", "_pcShowsCoachPlan"),
        ("frontend/website/pages/dashboard/weekly-plan/weekly-plan.js", None),
        ("mobile/lib/features/diet/diet_controller.dart", None),
        ("mobile/lib/features/workout/models/coach_training_plan.dart", None),
    ]

    @pytest.mark.parametrize("rel_path,_", GATES)
    def test_the_gate_defaults_a_null_plan_type(self, rel_path, _):
        path = REPO / rel_path
        if not path.exists():
            pytest.skip(f"{rel_path} not reachable")
        src = path.read_text(encoding="utf-8")
        assert re.search(r"planType \|\| 'complete'|planType \?\? 'complete'", src), (
            f"{rel_path} does not default a null planType to full coverage — "
            "free-trial athletes will not see their coach's plan there")

    def test_the_gates_still_require_an_active_relationship(self):
        """The null default must not accidentally show a retired coach's plan.
        Goal Reset retires the relationship to 'reset' precisely so the new AI
        plan is not overridden."""
        for rel_path, _ in self.GATES:
            path = REPO / rel_path
            if not path.exists():
                continue
            src = path.read_text(encoding="utf-8")
            # Either the literal status check, or the model's own `isActive`
            # getter (diet_controller.dart uses the latter).
            assert "'active'" in src or "isActive" in src, (
                f"{rel_path} no longer requires an active relationship — a "
                "retired coach's plan could override a fresh AI plan")
