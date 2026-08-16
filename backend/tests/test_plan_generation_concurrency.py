"""
ZITLAS — /generate-plan concurrency (backend/tests/test_plan_generation_concurrency.py)

`generate_plan()`'s docstring claimed "Steps 3 and 4 run in parallel" for a
long time while the code actually awaited them one after the other, so an
athlete waited for the SUM of two LLM round trips instead of the slower one.
The plan-generation loading screen is the most impatient moment in the whole
product, so the gap between the comment and the code was worth real seconds.

These tests pin the behaviour rather than the comment: they replace both
generators with instrumented stand-ins and assert on observed overlap and
wall-clock, so if anyone re-sequentialises the calls the test fails.

Run: python -m pytest tests/test_plan_generation_concurrency.py -q
"""
from __future__ import annotations

import asyncio
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from routes import assessment as assess  # noqa: E402
from services.assessment_service import AssessmentInput  # noqa: E402


def _profile(**overrides) -> AssessmentInput:
    base = dict(
        age=28, gender="male", height_cm=175, weight_kg=82.0, goal_weight_kg=74.0,
        activity_level="moderate", diet_preference="vegetarian",
        workout_preference="gym", living_situation="home", fitness_goal="weight_loss",
    )
    base.update(overrides)
    return AssessmentInput(**base)


@pytest.fixture
def no_rag(monkeypatch):
    """RAG is deliberately sequential (one FAISS index in RAM at a time) and
    is not what these tests are about."""
    def _retrieve(_query, _k, _goal):
        return "", []
    monkeypatch.setattr(assess.rag_service, "retrieve_context", _retrieve)


_DELAY = 0.4


def _instrumented(monkeypatch, order: list[str], *, diet_delay=_DELAY, workout_delay=_DELAY):
    """Records enter/exit of each generator so overlap is directly observable."""
    async def _diet(*_args, **_kwargs):
        order.append("diet:start")
        await asyncio.sleep(diet_delay)
        order.append("diet:end")
        return {"days": []}, {"tokens_used": 1, "model": "test", "reply": ""}

    async def _workout(*_args, **_kwargs):
        order.append("workout:start")
        await asyncio.sleep(workout_delay)
        order.append("workout:end")
        return {"weekly_plan": []}, {"tokens_used": 1, "model": "test", "reply": ""}

    monkeypatch.setattr(assess, "_generate_diet_plan", _diet)
    monkeypatch.setattr(assess, "_generate_workout_plan", _workout)


def test_diet_and_workout_generation_overlap(monkeypatch, no_rag):
    order: list[str] = []
    _instrumented(monkeypatch, order)

    asyncio.run(assess.generate_plan(_profile()))

    # Sequential execution produces diet:start, diet:end, workout:start...
    # Concurrent execution starts BOTH before either finishes.
    assert order.index("workout:start") < order.index("diet:end"), (
        f"workout waited for diet to finish - still sequential: {order}"
    )


def test_wall_clock_is_the_slower_call_not_the_sum(monkeypatch, no_rag):
    order: list[str] = []
    _instrumented(monkeypatch, order)

    started = time.perf_counter()
    asyncio.run(assess.generate_plan(_profile()))
    elapsed = time.perf_counter() - started

    # Sum would be ~2*_DELAY. Allow generous headroom for slow CI while still
    # failing loudly on a re-sequentialisation.
    assert elapsed < _DELAY * 1.8, f"took {elapsed:.2f}s, expected ~{_DELAY:.2f}s"


def test_an_uneven_pair_costs_only_the_slower_one(monkeypatch, no_rag):
    order: list[str] = []
    _instrumented(monkeypatch, order, diet_delay=0.6, workout_delay=0.1)

    started = time.perf_counter()
    asyncio.run(assess.generate_plan(_profile()))
    elapsed = time.perf_counter() - started

    assert elapsed < 0.6 * 1.8, f"took {elapsed:.2f}s, expected ~0.6s"


def test_a_failing_diet_plan_still_returns_the_workout_plan(monkeypatch, no_rag):
    """gather(return_exceptions=True) must preserve the per-plan isolation the
    previous separate try/except blocks provided."""
    async def _diet_explodes(*_args, **_kwargs):
        raise RuntimeError("AI service temporarily unavailable.")

    async def _workout_ok(*_args, **_kwargs):
        return {"weekly_plan": [{"day": "Monday"}]}, {"tokens_used": 1, "model": "t", "reply": ""}

    monkeypatch.setattr(assess, "_generate_diet_plan", _diet_explodes)
    monkeypatch.setattr(assess, "_generate_workout_plan", _workout_ok)

    body = asyncio.run(assess.generate_plan(_profile()))

    assert body["diet_plan"] is None
    assert body["workout_plan"] is not None
    # The instant, non-LLM half of the response must survive either failure.
    assert body["calculations"]["bmi"] > 0


def test_a_failing_workout_plan_still_returns_the_diet_plan(monkeypatch, no_rag):
    async def _diet_ok(*_args, **_kwargs):
        return {"days": [{"day": "Monday"}]}, {"tokens_used": 1, "model": "t", "reply": ""}

    async def _workout_explodes(*_args, **_kwargs):
        raise RuntimeError("AI service temporarily unavailable.")

    monkeypatch.setattr(assess, "_generate_diet_plan", _diet_ok)
    monkeypatch.setattr(assess, "_generate_workout_plan", _workout_explodes)

    body = asyncio.run(assess.generate_plan(_profile()))

    assert body["workout_plan"] is None
    assert body["diet_plan"] is not None


def test_both_failing_still_returns_calculations_and_swot(monkeypatch, no_rag):
    async def _explodes(*_args, **_kwargs):
        raise RuntimeError("down")

    monkeypatch.setattr(assess, "_generate_diet_plan", _explodes)
    monkeypatch.setattr(assess, "_generate_workout_plan", _explodes)

    body = asyncio.run(assess.generate_plan(_profile()))

    assert body["diet_plan"] is None
    assert body["workout_plan"] is None
    assert body["calculations"]["bmi"] > 0
    assert body["swot"] is not None
