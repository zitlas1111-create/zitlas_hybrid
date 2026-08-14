"""
ZITLAS — Diet generation regressions (backend/tests/test_diet_generation.py)

Regression for a real production incident: Railway logs showed
    Groq: APIStatusError ... Request too large for model qwen/qwen3.6-27b
    ... tokens per minute (TPM) Limit 8000, Requested 8096
    Gemini: OSError: GEMINI_API_KEY is not set.
    OpenRouter: OSError: OPENROUTER_API_KEY is not set.
    [ASSESS] Diet LLM FAILED: RuntimeError: AI service temporarily unavailable.
followed by `POST /api/assessment/generate-plan HTTP/1.1 200 OK` with a null
diet plan — the Flutter app then showed "Diet plan could not be loaded."

Two independent root causes, both fixed in this changeset:

  1. `_call_diet_ai()` in routes/assessment.py had NO exception handling
     around `groq_service.chat()`. When every provider genuinely failed,
     the resulting RuntimeError propagated straight out of
     `_generate_diet_plan()` — past the "fewer than 7 days" retry AND past
     the existing `_engine_grounded_diet_plan()` deterministic fallback
     (both of which only ever ran on a MALFORMED response, never on "no
     response at all") — all the way to `generate_plan()`'s outer
     try/except, which just logs and leaves `diet_plan: null`. The fix
     wraps the call so a total provider failure is treated exactly like a
     malformed response, and the SAME pre-existing fallback fires either
     way.

  2. The diet prompt's `max_tokens` was a static 6000 — already lower than
     the 8000 the spec warned against, and it STILL blew the limit, because
     Requested (8096) = actual prompt tokens (~2096: RAG context + full
     profile block + diet/budget/medical rules) + max_tokens (6000). A
     static number can never be safe on its own; `groq_service.
     safe_max_tokens()` now sizes the completion budget against the
     estimated PROMPT size too.

Run: python -m pytest tests/test_diet_generation.py -q
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import assessment as assess  # noqa: E402
from services import groq_service as gs  # noqa: E402
from services.assessment_service import AssessmentInput, run_assessment  # noqa: E402


def _profile(**overrides) -> AssessmentInput:
    defaults = dict(
        age=28, gender="male", height_cm=175, weight_kg=80, goal_weight_kg=72,
        activity_level="moderate", occupation="working_professional",
        living_situation="home", diet_preference="vegetarian",
        workout_preference="gym", fitness_goal="weight_loss",
    )
    defaults.update(overrides)
    return AssessmentInput(**defaults)


def _calc(data: AssessmentInput) -> dict:
    return run_assessment(data)["calculations"]


# ── groq_service.safe_max_tokens: the actual token-budget fix ──────────────

def test_estimate_tokens_is_a_rough_but_stable_ratio():
    assert gs.estimate_tokens("") >= 1
    assert gs.estimate_tokens("a" * 400) == 100  # 4 chars/token


def test_safe_max_tokens_shrinks_for_a_large_prompt():
    """Reproduces the exact production failure condition: a prompt large
    enough that a static max_tokens=6000 would make
    prompt_tokens + max_tokens exceed Groq's observed 8000 TPM cap."""
    # ~2096 real prompt tokens, matching the incident's own numbers
    # (8096 requested - 6000 max_tokens = 2096 prompt tokens).
    big_prompt = "x" * (2096 * 4)
    result = gs.safe_max_tokens(big_prompt, "", desired=6000)
    total_estimated = gs.estimate_tokens(big_prompt) + result
    assert total_estimated <= gs.GROQ_FALLBACK_TPM_LIMIT - gs.GROQ_TPM_SAFETY_MARGIN
    assert result < 6000, "must actually shrink below the old static value for a prompt this size"


def test_safe_max_tokens_keeps_the_full_desired_budget_for_a_small_prompt():
    """A tiny prompt must not be punished — the ceiling (desired) should be
    returned unchanged when there's plenty of room."""
    small_prompt = "Generate a diet plan."
    result = gs.safe_max_tokens(small_prompt, "system prompt", desired=6000)
    assert result == 6000


def test_safe_max_tokens_never_goes_below_the_floor():
    """An absurdly large prompt still returns a usable floor rather than a
    negative/zero budget that could never produce anything."""
    huge_prompt = "x" * 100_000
    result = gs.safe_max_tokens(huge_prompt, "", desired=6000, floor=1500)
    assert result == 1500


def test_diet_call_never_requests_more_than_the_groq_fallback_tpm_limit_allows(monkeypatch):
    """End-to-end version of the two tests above: drives the REAL
    _call_diet_ai() (via _generate_diet_plan) with a prompt inflated by a
    long rejected_foods-style disliked_foods list and RAG context, and
    asserts the actual max_tokens value passed to groq_service.chat never
    lets the request exceed the observed cap — this is item 12 of the
    original defect report, run against the real prompt-building code
    rather than a synthetic string."""
    captured: dict = {}

    async def _fake_chat(*, user_message, system_override, temperature, max_tokens,
                          json_mode, groq_key_env, provider):
        captured["user_message"] = user_message
        captured["system_override"] = system_override
        captured["max_tokens"] = max_tokens
        raise RuntimeError(gs.AI_UNAVAILABLE_MSG)  # provider chain exhausted

    monkeypatch.setattr(gs, "chat", _fake_chat)

    data = _profile(disliked_foods=[f"Disliked Food Item Number {i}" for i in range(200)])
    calc = _calc(data)
    big_rag_context = "Nutrition research context. " * 500  # inflate the prompt realistically

    import asyncio
    result, _llm_result = asyncio.run(assess._generate_diet_plan(data, calc, big_rag_context, "weight_loss"))

    assert captured, "groq_service.chat was never called"
    total_estimated = (
        gs.estimate_tokens(captured["user_message"])
        + gs.estimate_tokens(captured["system_override"])
        + captured["max_tokens"]
    )
    assert total_estimated <= gs.GROQ_FALLBACK_TPM_LIMIT - gs.GROQ_TPM_SAFETY_MARGIN, (
        f"request would still exceed the {gs.GROQ_FALLBACK_TPM_LIMIT} TPM cap: "
        f"estimated total={total_estimated}"
    )
    # And because chat() raised (all providers down), the engine-grounded
    # fallback must still have produced a real, complete plan (see next test).
    assert result is not None and len(result["days"]) == 7


# ── the actual defect: total provider failure must not become diet_plan: null ──

def test_total_provider_failure_falls_back_to_engine_grounded_plan(monkeypatch):
    """The exact production scenario: Groq/Gemini/OpenRouter all fail.
    Before the fix, this exception propagated out of _generate_diet_plan
    entirely and the caller was left with diet_plan: null."""
    async def _all_providers_down(*args, **kwargs):
        raise RuntimeError(gs.AI_UNAVAILABLE_MSG)

    monkeypatch.setattr(gs, "chat", _all_providers_down)

    data = _profile()
    calc = _calc(data)
    import asyncio
    result, _llm_result = asyncio.run(assess._generate_diet_plan(data, calc, "", "weight_loss"))

    assert result is not None, "diet plan must never be null when the engine-grounded fallback exists"
    assert isinstance(result.get("days"), list) and len(result["days"]) == 7
    for day in result["days"]:
        assert day.get("meals"), f"{day.get('day')} has no meals in the fallback plan"


def test_missing_env_key_also_falls_back_cleanly(monkeypatch):
    """A slightly different provider failure shape (EnvironmentError instead
    of RuntimeError, e.g. GROQ_API_KEY_DIET itself missing) must be caught
    the same way — the fix must not be narrowly typed to one exception."""
    async def _missing_key(*args, **kwargs):
        raise EnvironmentError("GROQ_API_KEY_DIET is not set. Add it to backend/.env.")

    monkeypatch.setattr(gs, "chat", _missing_key)

    data = _profile(fitness_goal="transformation")
    calc = _calc(data)
    import asyncio
    result, _llm_result = asyncio.run(assess._generate_diet_plan(data, calc, "", "transformation"))

    assert result is not None
    assert len(result["days"]) == 7


# ── normal success path (no regression) ─────────────────────────────────────

_MOCK_LLM_DAY = {
    "day": "Monday", "theme": "Balanced Day",
    "total_calories": 1800, "total_protein_g": 120,
    "meals": [
        {"meal_name": "Breakfast", "time": "8:00 AM", "foods": ["Poha"], "calories": 300, "protein_g": 8, "tip": "Great start"},
    ],
}


def _mock_full_week(day_template=_MOCK_LLM_DAY):
    days = []
    for name in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]:
        d = dict(day_template)
        d["day"] = name
        days.append(d)
    return {"days": days, "daily_calories_target": 1800, "daily_protein_target_g": 120}


@pytest.mark.parametrize("fitness_goal", ["weight_loss", "muscle_gain", "general_fitness", "transformation"])
def test_successful_llm_response_is_parsed_and_validated(monkeypatch, fitness_goal):
    import json as _json

    async def _fake_chat_success(*, user_message, system_override, temperature, max_tokens,
                                  json_mode, groq_key_env, provider):
        return {
            "reply": _json.dumps(_mock_full_week()),
            "model": "openai/gpt-oss-120b", "tokens_used": 1200,
            "prompt_tokens": 900, "completion_tokens": 300,
        }

    monkeypatch.setattr(gs, "chat", _fake_chat_success)

    data = _profile(fitness_goal=fitness_goal)
    calc = _calc(data)
    import asyncio
    result, _llm_result = asyncio.run(assess._generate_diet_plan(data, calc, "", fitness_goal))

    assert result is not None
    assert len(result["days"]) == 7
    assert {d["day"] for d in result["days"]} == {
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    }


def test_malformed_json_still_falls_back_as_before(monkeypatch):
    """Non-regression: the ORIGINAL fallback path (LLM responded, but the
    response wasn't parseable JSON) must keep working exactly as before."""
    async def _fake_chat_garbage(*args, **kwargs):
        return {"reply": "Sorry, I can't help with that right now.",
                "model": "openai/gpt-oss-120b", "tokens_used": 50}

    monkeypatch.setattr(gs, "chat", _fake_chat_garbage)

    data = _profile()
    calc = _calc(data)
    import asyncio
    result, _llm_result = asyncio.run(assess._generate_diet_plan(data, calc, "", "weight_loss"))

    assert result is not None
    assert len(result["days"]) == 7
