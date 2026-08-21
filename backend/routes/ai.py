"""
ZITLAS — AI Routes
All Groq-powered endpoints for the weight-loss and nutrition coaching platform.
"""

import asyncio
import json
import traceback as _tb

from fastapi import APIRouter, HTTPException, Header
from pydantic import BaseModel, Field
from typing import Any

from services import entitlements, groq_service, location_food_engine, offline_fallback, rag_service

router = APIRouter()


# ══════════════════════════════════════════════════════════════════════════════
# REQUEST / RESPONSE MODELS
# ══════════════════════════════════════════════════════════════════════════════

class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=2000, description="User's message to the AI")
    user_context: dict | None = Field(default=None, description="Optional user profile data for personalised responses")
    module: str = Field(default="general", description="AI module to use: general | swot | fitness | diet | goal | coach")

class CoachChatRequest(BaseModel):
    conversation_history: list[dict] = Field(default_factory=list)
    collected_data: dict = Field(default_factory=dict)
    current_phase: str = Field(default="intro")
    turn_count: int = Field(default=0)

class CoachFinalizeRequest(BaseModel):
    conversation_history: list[dict] = Field(default_factory=list)
    collected_data: dict = Field(default_factory=dict)

class ChatResponse(BaseModel):
    reply: str
    module: str
    model: str
    tokens_used: int
    sources: list[dict] | None = None   # RAG source chunk references


class SWOTRequest(BaseModel):
    user_profile: dict = Field(..., description="User profile data for weight-loss SWOT analysis")

class TrainingPlanRequest(BaseModel):
    user_profile: dict
    goal: dict = Field(..., description="Goal: {type, current_value, target_value, end_date}")

class DietPlanRequest(BaseModel):
    user_profile: dict
    training_load: str = Field(default="moderate", description="light | moderate | heavy | active | rest_day")

class GoalPlanRequest(BaseModel):
    user_profile: dict
    goal: dict = Field(..., description="Goal: {type, current_value, target_value, end_date}")

class EliteWeeklyPlanRequest(BaseModel):
    user_profile: dict
    goal: dict = Field(..., description="Goal: {type, current_value, target_value, end_date}")

class CoachRecommendRequest(BaseModel):
    user_profile: dict
    available_coaches: list[dict] = Field(default_factory=list)

class MentalQuestionsRequest(BaseModel):
    user_profile: dict

class MentalAssessmentRequest(BaseModel):
    user_profile: dict
    mental_answers: dict

class PhysicalQuestionsRequest(BaseModel):
    user_profile: dict
    mental_assessment: dict | None = Field(default=None, description="Brain 1 output for cross-referencing recovery/motivation signals")

class PhysicalAssessmentRequest(BaseModel):
    user_profile: dict
    physical_answers: dict
    mental_assessment: dict | None = Field(default=None, description="Brain 1 output for integrated cross-brain analysis")

class NutritionQuestionsRequest(BaseModel):
    user_profile: dict
    mental_assessment: dict | None = Field(default=None)
    physical_assessment: dict | None = Field(default=None)
    lifestyle_data: dict | None = Field(default=None)

class NutritionAssessmentRequest(BaseModel):
    user_profile: dict
    nutrition_answers: dict
    mental_assessment: dict | None = Field(default=None)
    physical_assessment: dict | None = Field(default=None)
    lifestyle_data: dict | None = Field(default=None)

class NutritionWeeklyPlanRequest(BaseModel):
    user_profile: dict
    nutrition_assessment: dict | None = Field(default=None)
    lifestyle_data: dict | None = Field(default=None)
    rejected_foods: list[str] = Field(default_factory=list)

class ZinoChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=1000)
    context: dict = Field(default_factory=dict, description="User snapshot: goal, calculations, swot, diet/workout summaries, coaching status, medical conditions, health status, streak, meal scores")
    history: list[dict] = Field(default_factory=list, description="[{role:'user'|'zino', text}] recent turns for continuity")


class SwapMealRequest(BaseModel):
    meal_name: str
    meal_time: str = Field(default="")
    current_foods: list[str] = Field(default_factory=list)
    reason: str = Field(..., description="Why the user wants to swap (e.g. not available, too expensive, vegetarian)")
    user_profile: dict
    lifestyle_data: dict | None = Field(default=None)
    rejected_foods: list[str] = Field(default_factory=list)
    previous_suggestions: list[list[str]] = Field(default_factory=list)
    fitness_goal: str = Field(default="general_fitness", description="User's fitness goal: weight_loss | muscle_gain | general_fitness")


# ══════════════════════════════════════════════════════════════════════════════
# HEALTH CHECK
# ══════════════════════════════════════════════════════════════════════════════

@router.get("/health")
async def ai_health():
    return {"module": "ai", "status": "ready", "provider": "Groq"}


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/chat  — general weight-loss assistant
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/chat", response_model=ChatResponse)
async def chat(body: ChatRequest):
    """
    Send a message to the ZITLAS AI weight-loss and nutrition assistant (Zino).

    - **message**: The user's question or request.
    - **user_context**: Optional dict with user profile data for personalised responses.
    - **module**: Which AI module to use (default: "general").
    """
    # ── RAG: retrieve relevant chunks — non-blocking (KB loads lazily in thread) ─
    # Pull fitness_goal from user_context so we search one KB instead of all four.
    # Searching all 4 KBs simultaneously causes OOM on free-tier (512 MB) deployments.
    _rag_goal: str | None = None
    if body.user_context:
        _raw_goal = body.user_context.get("fitness_goal") or body.user_context.get("goal")
        _VALID_RAG_GOALS = {"weight_loss", "muscle_gain", "general_fitness", "transformation"}
        if isinstance(_raw_goal, str) and _raw_goal in _VALID_RAG_GOALS:
            _rag_goal = _raw_goal
    if _rag_goal is None:
        _rag_goal = "weight_loss"  # safe default: single KB, stays within memory limits
    print(f"\n[CHAT] goal={_rag_goal!r}  query={body.message[:120]!r}")
    rag_context, sources = await asyncio.to_thread(
        rag_service.retrieve_context, body.message, 5, _rag_goal
    )

    # ── Build user message (user_context + RAG context + question) ──────────
    user_message = body.message
    if body.user_context:
        ctx_str = json.dumps(body.user_context, indent=2)
        user_message = f"User context:\n{ctx_str}\n\nQuestion: {body.message}"

    if rag_context:
        print(f"[CHAT] Injecting {len(sources)} RAG chunk(s) into prompt")
        user_message = (
            "RELEVANT KNOWLEDGE BASE CONTEXT (weight-loss research — use this to inform your answer):\n\n"
            f"{rag_context}\n\n"
            "---\n\n"
            f"{user_message}"
        )
    else:
        print("[CHAT] No RAG context found (below threshold or index empty)")

    try:
        result = await groq_service.chat(user_message=user_message)
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return ChatResponse(
        reply=result["reply"],
        module=body.module,
        model=result["model"],
        tokens_used=result["tokens_used"],
        sources=sources or None,
    )


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/zino-chat  — the permanent floating Zino companion
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/zino-chat")
async def zino_chat(body: ZinoChatRequest) -> dict[str, Any]:
    """
    Conversational endpoint for the always-available Zino floating assistant
    (frontend/assets/js/zino.js). Distinct from /chat: dedicated companion
    persona + tone (groq_service.ZINO_COMPANION_SYSTEM), full athlete context
    injection, and short conversation history for continuity.
    """
    # 16 turns (spec: "at least 10-20") so "it"/"that" a few messages back
    # still resolves — this is what conversation memory IS for this endpoint.
    history_lines = []
    for h in body.history[-16:]:
        role = 'User' if h.get('role') == 'user' else 'Zino'
        text = str(h.get('text', ''))[:400]
        if text:
            history_lines.append(f"{role}: {text}")
    history_block = ("RECENT CONVERSATION:\n" + "\n".join(history_lines) + "\n\n") if history_lines else ""

    ctx_str = json.dumps(body.context, indent=2, default=str) if body.context else "No profile data synced yet."
    user_message = (
        f"USER CONTEXT:\n{ctx_str}\n\n"
        f"{history_block}"
        f"User says: {body.message}"
    )

    print(f"[ZINO CHAT] message={body.message[:120]!r}  context_keys={list(body.context.keys())}")
    try:
        result = await groq_service.chat(
            user_message=user_message,
            system_override=groq_service.ZINO_COMPANION_SYSTEM,
            temperature=0.8,
            max_tokens=400,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Zino is having trouble connecting: {str(e)}")

    # Despite the prompt explicitly forbidding it, a model (Gemini's silent
    # fallback path in particular) occasionally self-wraps a plain answer
    # in JSON syntax — {"response": "..."} or a bare quoted string. Never
    # let that reach a chat bubble as visible braces.
    reply = groq_service.unwrap_conversational_reply(result["reply"])
    if reply != result["reply"]:
        print(f"[ZINO CHAT] unwrapped a JSON-formatted reply from {result['model']}")

    return {"reply": reply, "model": result["model"], "tokens_used": result["tokens_used"]}


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/swot  — weight-loss profile SWOT analysis
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/swot")
async def swot_analysis(body: SWOTRequest) -> dict[str, Any]:
    """
    Generate an AI-powered weight-loss profile analysis (SWOT).

    Returns structured JSON:
        { swot: { strengths, weaknesses, opportunities, threats },
          summary, priority_action }
    """
    try:
        result = await groq_service.generate_swot(body.user_profile)
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module": "swot",
        "model": result["model"],
        "tokens_used": result["tokens_used"],
        "reply": result["reply"],
        "structured": result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/training-plan  — personalised fitness plan
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/training-plan")
async def training_plan(body: TrainingPlanRequest) -> dict[str, Any]:
    """
    Generate a week-by-week personalised fitness plan for weight loss.

    Matches the user's workout type (home / gym / walking / none).
    """
    try:
        result = await groq_service.generate_training_plan(
            player_profile=body.user_profile,
            goal=body.goal,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module": "training_plan",
        "model": result["model"],
        "tokens_used": result["tokens_used"],
        "reply": result["reply"],
        "structured": result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/diet-plan  — daily calorie-deficit diet plan
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/diet-plan")
async def diet_plan(body: DietPlanRequest) -> dict[str, Any]:
    """
    Generate a personalised daily calorie-deficit diet plan.

    training_load options: light | moderate | heavy | active | rest_day
    """
    try:
        result = await groq_service.generate_diet_plan(
            player_profile=body.user_profile,
            training_load=body.training_load,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module": "diet_plan",
        "model": result["model"],
        "tokens_used": result["tokens_used"],
        "reply": result["reply"],
        "structured": result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/goal-plan  — weight-loss milestone breakdown
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/goal-plan")
async def goal_plan(body: GoalPlanRequest) -> dict[str, Any]:
    """
    Break a user's weight-loss goal into weekly milestones.

    Returns structured week-by-week targets with focus areas
    and motivational checkpoint messages.
    """
    try:
        result = await groq_service.generate_goal_plan(
            goal=body.goal,
            player_profile=body.user_profile,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module": "goal_plan",
        "model": result["model"],
        "tokens_used": result["tokens_used"],
        "reply": result["reply"],
        "structured": result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/elite-weekly-plan  — 7-day weight-loss roadmap
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/elite-weekly-plan")
async def elite_weekly_plan(body: EliteWeeklyPlanRequest) -> dict[str, Any]:
    """
    Generate a personalised 7-day weight-loss roadmap.

    Each day includes: calorie_target, protein_target_g, meals, workout,
    hydration goal, habit focus, and a motivational tip.
    """
    try:
        result = await groq_service.generate_elite_weekly_plan(
            player_profile=body.user_profile,
            goal=body.goal,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "elite_weekly_plan",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/coach-recommend  — coach matching
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/coach-recommend")
async def coach_recommend(body: CoachRecommendRequest) -> dict[str, Any]:
    """
    Recommend the best coaches for a user based on their profile and weight-loss goal.

    Pass the available_coaches list from your coach database.
    Returns a ranked list with match score and reasoning.
    """
    try:
        result = await groq_service.recommend_coaches(
            player_profile=body.user_profile,
            available_coaches=body.available_coaches,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module": "coach_recommend",
        "model": result["model"],
        "tokens_used": result["tokens_used"],
        "reply": result["reply"],
        "structured": result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/mental-questions  — mindset/habit follow-up questions
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/mental-questions")
async def mental_questions(body: MentalQuestionsRequest) -> dict[str, Any]:
    """
    Generate personalised follow-up questions to assess the user's mindset,
    habits, and psychological blockers around weight loss.
    """
    try:
        result = await groq_service.generate_mental_questions(body.user_profile)
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "mental_questions",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/mental-assessment  — full mindset/habit assessment
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/mental-assessment")
async def mental_assessment(body: MentalAssessmentRequest) -> dict[str, Any]:
    """
    Generate a full mindset and habit assessment for weight loss.

    Returns:
        mental_scores: motivation, consistency, stress_eating, sleep_quality, mindset, overall
        psychology_swot: strengths, weaknesses, opportunities, threats
        recommendations: 3 habit/mindset coaching interventions
        mental_profile: 2-3 sentence summary
        brain_diagnosis: single root-cause diagnosis sentence
    """
    try:
        result = await groq_service.generate_mental_assessment(
            player_profile=body.user_profile,
            mental_answers=body.mental_answers,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "mental_assessment",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/physical-questions  — fitness/activity follow-up questions
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/physical-questions")
async def physical_questions(body: PhysicalQuestionsRequest) -> dict[str, Any]:
    """
    Generate personalised physical activity questions to identify the user's
    fitness level, exercise history, and physical limiting factors for weight loss.
    """
    try:
        result = await groq_service.generate_physical_questions(
            player_profile=body.user_profile,
            mental_assessment=body.mental_assessment,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "physical_questions",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/physical-assessment  — full fitness assessment
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/physical-assessment")
async def physical_assessment(body: PhysicalAssessmentRequest) -> dict[str, Any]:
    """
    Generate a full physical fitness assessment for weight loss.

    Returns:
        physical_scores: strength, endurance, flexibility, activity_consistency, recovery, overall
        physical_bottleneck: the single biggest physical limiting factor
        physical_swot: strengths, weaknesses, opportunities, threats
        recommendations: 3 targeted fitness interventions
        physical_profile: 2-3 sentence summary
    """
    try:
        result = await groq_service.generate_physical_assessment(
            player_profile=body.user_profile,
            physical_answers=body.physical_answers,
            mental_assessment=body.mental_assessment,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "physical_assessment",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/nutrition-questions  — eating habits follow-up questions
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/nutrition-questions")
async def nutrition_questions(body: NutritionQuestionsRequest) -> dict[str, Any]:
    """
    Generate personalised nutrition questions to assess the user's eating habits,
    calorie awareness, meal consistency, and weight-loss blockers.
    """
    try:
        result = await groq_service.generate_nutrition_questions(
            player_profile=body.user_profile,
            mental_assessment=body.mental_assessment,
            physical_assessment=body.physical_assessment,
            lifestyle_data=body.lifestyle_data,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "nutrition_questions",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/nutrition-assessment  — full eating habits assessment
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/nutrition-assessment")
async def nutrition_assessment(body: NutritionAssessmentRequest) -> dict[str, Any]:
    """
    Generate a full nutrition assessment for weight loss.

    Returns:
        nutrition_scores: meal_consistency, calorie_awareness, protein_intake,
                          hydration, junk_food_control, overall
        nutrition_bottleneck: the single biggest eating blocker
        nutrition_swot: strengths, weaknesses, opportunities, threats
        recommendations: 3 targeted nutrition interventions
        daily_calorie_target: calculated target
        daily_protein_target_g: calculated target
    """
    try:
        result = await groq_service.generate_nutrition_assessment(
            player_profile=body.user_profile,
            nutrition_answers=body.nutrition_answers,
            mental_assessment=body.mental_assessment,
            physical_assessment=body.physical_assessment,
            lifestyle_data=body.lifestyle_data,
        )
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")

    return {
        "module":      "nutrition_assessment",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/nutrition-weekly-plan  — personalised 7-day calorie-deficit plan
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/nutrition-weekly-plan")
async def nutrition_weekly_plan(body: NutritionWeeklyPlanRequest) -> dict[str, Any]:
    """
    Generate a fully personalised 7-day calorie-deficit meal plan using the user's
    complete profile (goal weight, calorie target, protein target, diet type, budget).
    """
    print("\n" + "="*60)
    print("NUTRITION-WEEKLY-PLAN REQUEST")
    print(f"  lifestyle.living_situation : {(body.lifestyle_data or {}).get('living_situation', 'N/A')}")
    print(f"  lifestyle.diet_type        : {(body.lifestyle_data or {}).get('diet_type', 'N/A')}")
    print(f"  lifestyle.daily_budget     : {(body.lifestyle_data or {}).get('daily_budget', 'N/A')}")
    print(f"  lifestyle.cooking_access   : {(body.lifestyle_data or {}).get('cooking_access', 'N/A')}")
    print(f"  lifestyle.favourite_foods  : {(body.lifestyle_data or {}).get('favorite_foods', [])}")
    print(f"  lifestyle.disliked_foods   : {(body.lifestyle_data or {}).get('disliked_foods', [])}")
    print(f"  lifestyle.allergies        : {(body.lifestyle_data or {}).get('allergies', [])}")
    print(f"  rejected_foods             : {body.rejected_foods}")
    print(f"  profile.primary_goal       : {body.user_profile.get('primary_goal', 'N/A')}")
    print(f"  profile.calorie_target     : {body.user_profile.get('daily_calorie_target', 'N/A')}")
    print(f"  profile.age                : {body.user_profile.get('age', 'N/A')}")
    print(f"  nutrition_assessment       : {'yes' if body.nutrition_assessment else 'no'}")
    _diet_location = body.user_profile.get("location")
    print(f"[DIET_REGION] request location payload = {_diet_location}")
    print(f"[DIET_REGION] backend received = {location_food_engine.resolve_state(_diet_location) or 'None'}")
    print("="*60)

    try:
        result = await groq_service.generate_nutrition_weekly_plan(
            player_profile=body.user_profile,
            nutrition_assessment=body.nutrition_assessment,
            lifestyle_data=body.lifestyle_data,
            rejected_foods=body.rejected_foods,
        )
    except EnvironmentError as e:
        print(f"[nutrition-weekly-plan] EnvironmentError: {e}")
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        print(f"\n[nutrition-weekly-plan] ALL PROVIDERS FAILED — using offline fallback")
        print(f"  {type(e).__name__}: {e}")
        print(_tb.format_exc())
        plan = offline_fallback.nutrition_weekly_plan(
            player_profile=body.user_profile,
            lifestyle_data=body.lifestyle_data,
            rejected_foods=body.rejected_foods,
        )
        return {
            "module":      "nutrition_weekly_plan",
            "model":       "offline",
            "tokens_used": 0,
            "reply":       json.dumps(plan),
            "structured":  plan,
        }

    structured = result["structured"]
    if structured:
        days = structured.get("days", [])
        print(f"\n[nutrition-weekly-plan] SUCCESS")
        print(f"  plan_name       : {structured.get('plan_name', 'N/A')}")
        print(f"  days_count      : {len(days)}")
        if days:
            # meals is a slot-keyed dict on the engine/LLM path
            # (_apply_engine_foods) and a list on the offline path — log both.
            d0_meals = days[0].get("meals", [])
            d0_list = list(d0_meals.values()) if isinstance(d0_meals, dict) else d0_meals
            print(f"  day[0].theme    : {days[0].get('theme', 'N/A')}")
            print(f"  day[0].meals    : {[m.get('meal_name') or m.get('name') for m in d0_list]}")
            if d0_list:
                print(f"  day[0].breakfast: {d0_list[0].get('foods', [])}")
    else:
        raw_reply = result.get("reply", "") or ""
        print(f"\n[nutrition-weekly-plan] FAILURE — structured is None")
        print(f"  raw_reply length : {len(raw_reply)} chars")
        print(f"  first 500 chars  : {raw_reply[:500]}")
        print(f"  last 500 chars   : {raw_reply[-500:]}")
        raise HTTPException(
            status_code=500,
            detail="Nutrition plan generation failed — AI response could not be parsed as a valid meal plan.",
        )

    return {
        "module":      "nutrition_weekly_plan",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  structured,
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/swap-meal  — replace a single meal with a weight-loss alternative
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/swap-meal")
async def swap_meal(
    body: SwapMealRequest,
    authorization: str | None = Header(default=None),
) -> dict[str, Any]:
    """
    Replace a single meal with a realistic lower-calorie, higher-protein alternative.
    Takes the reason for swapping and the user's lifestyle context (living situation,
    budget, available foods) to generate a practical replacement.
    """
    # Same allowance as /api/diet/swap. BOTH swap paths must be gated or the
    # limit is decorative: the website uses this LLM endpoint while Flutter
    # uses the deterministic one, so leaving either open is a free bypass.
    swap_uid = entitlements.uid_from_authorization(authorization)
    if swap_uid:
        entitlements.require(swap_uid, entitlements.MEAL_SWAP)

    fitness_goal = body.fitness_goal or "general_fitness"

    print("\n" + "="*60)
    print("SWAP-MEAL REQUEST")
    print(f"  meal_name     : {body.meal_name}")
    print(f"  meal_time     : {body.meal_time}")
    print(f"  current_foods : {body.current_foods}")
    print(f"  reason        : {body.reason}")
    print(f"  rejected_foods: {body.rejected_foods}")
    print(f"  prev_suggest  : {len(body.previous_suggestions)} previous suggestion(s)")
    print(f"  living_sit    : {(body.lifestyle_data or {}).get('living_situation', 'N/A')}")
    print(f"  diet_type     : {(body.lifestyle_data or {}).get('diet_type', 'N/A')}")
    print(f"[SWAP MEAL] goal={fitness_goal}")
    _swap_location = (body.user_profile or {}).get("location")
    print(f"[SWAP_REGION] request location payload = {_swap_location}")
    print(f"[SWAP_REGION] backend received = {location_food_engine.resolve_state(_swap_location) or 'None'}")
    print("="*60)

    # RAG: pull nutrition context aligned with the user's fitness goal
    _rag_goal_map = {
        "weight_loss":     "weight_loss",
        "muscle_gain":     "muscle_gain",
        "general_fitness": "general_fitness",
    }
    swap_rag_query = (
        f"healthy {body.meal_name} alternatives "
        f"for {fitness_goal.replace('_', ' ')} "
        f"high protein {(body.lifestyle_data or {}).get('diet_type', 'balanced')} meal"
    )
    rag_goal_filter = _rag_goal_map.get(fitness_goal)
    rag_context, rag_sources = await asyncio.to_thread(
        rag_service.retrieve_context, swap_rag_query, 3, rag_goal_filter
    )
    rag_pdf_names = [s["source_pdf"] for s in rag_sources]
    print(f"[SWAP RAG] using {rag_pdf_names if rag_pdf_names else 'no context'}")

    try:
        result = await groq_service.generate_meal_swap(
            meal_name=body.meal_name,
            meal_time=body.meal_time,
            current_foods=body.current_foods,
            reason=body.reason,
            player_profile=body.user_profile,
            lifestyle_data=body.lifestyle_data,
            rejected_foods=body.rejected_foods,
            previous_suggestions=body.previous_suggestions,
            fitness_goal=fitness_goal,
            rag_context=rag_context,
        )
    except EnvironmentError as e:
        print(f"[swap-meal] EnvironmentError: {e}")
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        print(f"\n[swap-meal] ALL PROVIDERS FAILED — using offline fallback")
        print(f"  {type(e).__name__}: {e}")
        print(_tb.format_exc())
        meal = offline_fallback.meal_swap(
            meal_name=body.meal_name,
            meal_time=body.meal_time,
            current_foods=body.current_foods,
            reason=body.reason,
            lifestyle_data=body.lifestyle_data,
            rejected_foods=body.rejected_foods,
            previous_suggestions=body.previous_suggestions,
            player_profile=body.user_profile,
        )
        return {
            "module":      "swap_meal",
            "model":       "offline",
            "tokens_used": 0,
            "reply":       json.dumps(meal),
            "structured":  meal,
        }

    structured = result["structured"]
    print(f"[swap-meal] Result: {json.dumps(structured, ensure_ascii=True)[:300] if structured else 'None - raw: ' + str(result.get('reply',''))[:300]}")

    if structured is None:
        print("[swap-meal] AI succeeded but returned malformed JSON — falling back to offline")
        structured = offline_fallback.meal_swap(
            meal_name=body.meal_name,
            meal_time=body.meal_time,
            current_foods=body.current_foods,
            reason=body.reason,
            lifestyle_data=body.lifestyle_data,
            rejected_foods=body.rejected_foods,
            previous_suggestions=body.previous_suggestions,
            player_profile=body.user_profile,
        )

    # Recorded only now: the athlete has a real alternative in hand. A swap
    # that raised above this point never reaches here, so it costs nothing.
    if swap_uid:
        entitlements.record(swap_uid, entitlements.MEAL_SWAP)

    return {
        "module":      "swap_meal",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  structured,
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/coach-start  — begin the AI coach conversation
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/coach-start")
async def coach_start() -> dict[str, Any]:
    """Start the AI Coach (Zino) conversation with a warm greeting and goal question."""
    try:
        result = await groq_service.coach_start()
    except EnvironmentError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Groq API error: {str(e)}")
    return {"module": "coach_start", "model": result["model"],
            "tokens_used": result["tokens_used"], "reply": result["reply"], "structured": result["structured"]}


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/coach-chat  — one turn of the AI coach conversation
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/coach-chat")
async def coach_chat(body: CoachChatRequest) -> dict[str, Any]:
    """
    Handle one turn of the Zino AI Coach conversation.
    Returns the next coach message, question type (options/text/complete),
    and any profile data extracted from the user's last message.
    """
    import traceback as _tb

    print("\n" + "="*60)
    print("COACH-CHAT REQUEST")
    print(f"  phase       : {body.current_phase}")
    print(f"  turn_count  : {body.turn_count}")
    print(f"  collected   : {body.collected_data}")
    print(f"  history_len : {len(body.conversation_history)}")
    print("="*60)

    try:
        result = await groq_service.coach_chat(
            conversation_history=body.conversation_history,
            collected_data=body.collected_data,
            current_phase=body.current_phase,
            turn_count=body.turn_count,
        )
    except EnvironmentError as e:
        print(f"[coach-chat] EnvironmentError: {e}")
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        print(f"\n[coach-chat] EXCEPTION: {type(e).__name__}: {e}")
        print(_tb.format_exc())
        raise HTTPException(status_code=500, detail=f"{type(e).__name__}: {str(e)}")

    print(f"[coach-chat] OK — tokens={result.get('tokens_used')} phase={result.get('structured', {}).get('phase')}")
    return {
        "module":      "coach_chat",
        "model":       result["model"],
        "tokens_used": result["tokens_used"],
        "reply":       result["reply"],
        "structured":  result["structured"],
    }


# ══════════════════════════════════════════════════════════════════════════════
# POST /api/ai/coach-finalize  — build complete user profile from conversation
# ══════════════════════════════════════════════════════════════════════════════

@router.post("/coach-finalize")
async def coach_finalize(body: CoachFinalizeRequest) -> dict[str, Any]:
    """
    After the Zino Coach conversation is complete, generate the full weight-loss profile.
    Returns all data needed to populate localStorage: calorie target, protein target,
    BMI, SWOT analysis, fitness plan type, and development priority.
    """
    print("\n" + "="*60)
    print("COACH-FINALIZE REQUEST")
    print(f"  history_len    : {len(body.conversation_history)}")
    print(f"  collected_data : {json.dumps(body.collected_data, ensure_ascii=False)[:300]}")
    print("="*60)

    try:
        result = await groq_service.coach_finalize(
            conversation_history=body.conversation_history,
            collected_data=body.collected_data,
        )
    except EnvironmentError as e:
        print(f"[coach-finalize] EnvironmentError: {e}")
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        print(f"\n[coach-finalize] ALL PROVIDERS FAILED — using offline fallback")
        print(f"  {type(e).__name__}: {e}")
        print(_tb.format_exc())
        profile = offline_fallback.coach_finalize_profile(body.collected_data)
        return {
            "module":      "coach_finalize",
            "model":       "offline",
            "tokens_used": 0,
            "reply":       json.dumps(profile),
            "structured":  profile,
        }

    structured = result["structured"]
    print(f"[coach-finalize] structured={'yes' if structured else 'None'} tokens={result.get('tokens_used')}")
    if not structured:
        print(f"[coach-finalize] Raw reply (500 chars): {(result.get('reply','') or '')[:500]}")

    return {"module": "coach_finalize", "model": result["model"],
            "tokens_used": result["tokens_used"], "reply": result["reply"], "structured": structured}
