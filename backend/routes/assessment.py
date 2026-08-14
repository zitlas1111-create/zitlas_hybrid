"""
ZITLAS — Assessment Routes (Production)

POST /api/assessment/analyze       → calculations + rule-based SWOT (instant, no LLM)
POST /api/assessment/generate-plan → analyze + RAG retrieval + LLM diet + LLM workout
GET  /api/assessment/health        → service health check
"""

import asyncio
import gc
import json
import re
import time
import traceback as _tb
from typing import Any

from fastapi import APIRouter, HTTPException

from services import groq_service, rag_service, food_engine
from services import medical_conditions as medcon
from services import workout_engine, location_food_engine
from services.assessment_service import AssessmentInput, run_assessment

router = APIRouter()


def _ram() -> str:
    """Return current process RSS in MB as a log-friendly string."""
    try:
        import psutil as _psutil
        return f"{_psutil.Process().memory_info().rss / 1024 / 1024:.1f} MB"
    except Exception:
        return "N/A"


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _extract_json(text: str) -> dict | None:
    """Extract a JSON object from text that may contain markdown fences."""
    try:
        return json.loads(text.strip())
    except (json.JSONDecodeError, ValueError):
        pass
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1))
        except (json.JSONDecodeError, ValueError):
            pass
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group())
        except (json.JSONDecodeError, ValueError):
            pass
    return None


# Slot -> (display label, default time). Presentational only — the foods
# themselves always come from FoodRecommendationEngine (see
# _engine_grounded_diet_plan below), same hallucination-firewall guarantee
# as groq_service._apply_engine_foods() / offline_fallback.nutrition_weekly_plan().
_DIET_FALLBACK_SLOTS: list[tuple[str, str, str]] = [
    ("breakfast",      "Breakfast",      "8:00 AM"),
    ("mid_morning",    "Mid-Morning",    "11:00 AM"),
    ("lunch",          "Lunch",          "1:00 PM"),
    ("evening_snack",  "Evening Snack",  "5:00 PM"),
    ("dinner",         "Dinner",         "8:00 PM"),
]


def _engine_grounded_diet_plan(data: "AssessmentInput", calc: dict, fitness_goal: str) -> dict:
    """Safety net for when the LLM (both the initial call and the retry)
    never returns valid, complete JSON — e.g. Groq rate-limited -> Gemini
    fallback -> output truncated by max_tokens, or any other transient
    provider hiccup. Rather than surfacing `diet_plan: null` to the user
    (the actual root cause of "Diet plan could not be loaded" appearing
    right after assessment — there is no synchronization bug on the
    frontend; callGeneratePlan() already awaits this response correctly
    before rendering), this builds a REAL, complete 7-day plan directly
    from the same verified food database and engine every other diet
    surface (weekly-plan regen, meal swap, offline fallback) already uses,
    so the user is never blocked on the LLM being available at all.
    """
    player_profile = {
        "primary_goal":       fitness_goal,
        "occupation":         data.occupation,
        "medical_conditions": data.medical_conditions,
        "uses_supplements":   data.uses_supplements,
        "location":           data.location,
    }
    lifestyle_data = {
        "living_situation": data.living_situation,
        "diet_type":         data.diet_preference,
        "daily_budget":      data.budget,
        "disliked_foods":    data.disliked_foods,
    }
    ctx = groq_service._engine_query_context(player_profile, lifestyle_data)
    week = food_engine.get_engine().build_week_plan(
        goal_tags=ctx["goal_tags"], diet_tags=ctx["diet_tags"], living_situation=ctx["living_tag"],
        budget_tier=ctx["budget_tier"], disease_tags=ctx["disease_tags"], allergens=ctx["allergens"],
        favorite_foods=ctx["favorite_foods"], disliked_foods=ctx["disliked_foods"],
        daily_calorie_target=calc.get("weight_loss_calories_kcal"),
        profile=ctx["profile"], subgoal_tag=ctx["subgoal_tag"], season_tag=ctx["season_tag"],
        user_state=ctx.get("user_state"), compatible_regions=ctx.get("compatible_regions"),
    )

    days_out = []
    for day in week["days"]:
        meals_out = []
        total_cal, total_protein = 0, 0.0
        for slot_key, label, time in _DIET_FALLBACK_SLOTS:
            slot_data = day["meals"].get(slot_key)
            if not slot_data or not slot_data.get("primary"):
                continue
            combo = slot_data["primary"]
            cal = sum(f["calories"] for f in combo)
            protein = sum(f["protein"] for f in combo)
            meals_out.append({
                "meal_name": label,
                "time":      time,
                "foods":     [food_engine.format_food_line(f) for f in combo],
                "calories":  round(cal),
                "protein_g": round(protein, 1),
                "tip":       f"{combo[0]['name']} — {combo[0]['description']}",
            })
            total_cal += cal
            total_protein += protein
        days_out.append({
            "day":             day["day"],
            "theme":           "Balanced Nutrition Day",
            "total_calories":  round(total_cal),
            "total_protein_g": round(total_protein, 1),
            "meals":           meals_out,
        })

    print(f"[DIET AI] LLM produced no usable plan — served an engine-grounded fallback "
          f"({len(days_out)} days, sourced from the verified food database)")
    return {
        "plan_name":              "7-Day Personalised Meal Plan",
        "daily_calories_target":  calc.get("weight_loss_calories_kcal"),
        "daily_protein_target_g": calc.get("protein_target_g"),
        "days":                   days_out,
        "key_rules": [
            "Every meal is sourced from ZITLAS's verified food database.",
            "Stay consistent with your daily calorie and protein targets.",
            "Drink water regularly and prioritise whole foods.",
        ],
        "summary": "A balanced, goal-aligned 7-day plan built directly from our verified food database.",
    }


def _build_user_profile_block(
    data: AssessmentInput,
    calc: dict,
    fitness_goal: str = "weight_loss",
) -> str:
    """Format assessment + calculations as a readable block for LLM prompts."""
    is_muscle         = fitness_goal == "muscle_gain"
    is_general        = fitness_goal == "general_fitness"
    is_transformation = fitness_goal == "transformation"

    if is_transformation:
        cal_label  = "Daily Calories (transformation/recomposition)"
        cal_change = f"Mild Deficit: {calc['calorie_deficit_kcal']} kcal below TDEE — supports fat loss while preserving muscle"
    elif is_general:
        cal_label  = "Maintenance Calories (general fitness)"
        cal_change = "Eating at maintenance — balanced nutrition for energy, health, and performance"
    elif is_muscle:
        cal_label  = "Daily Calories (muscle-gain)"
        cal_change = f"Calorie Surplus: {abs(calc['calorie_deficit_kcal'])} kcal above TDEE"
    else:
        cal_label  = "Daily Calories (weight-loss)"
        cal_change = f"Calorie Deficit: {calc['calorie_deficit_kcal']} kcal below TDEE"

    weight_delta = abs(calc["weight_to_lose_kg"])

    goal_line = ""
    if not is_general and not is_transformation:
        weight_label = "Weight to Gain" if is_muscle else "Weight to Lose"
        goal_line = (
            f"\n  {weight_label}: {weight_delta} kg"
            f"\n  Estimated Time to Goal: {abs(calc['estimated_weeks_to_goal'])} weeks"
        )
    elif is_transformation:
        goal_line = "\n  Transformation Timeline: 12–16 weeks for visible body recomposition"

    tf_extra = ""
    if is_transformation:
        tf_goal   = getattr(data, 'transformation_goal', None) or 'general transformation'
        tf_months = getattr(data, 'goal_duration_months', None)
        tf_extra  = (
            f"\n  Transformation Target: {tf_goal.replace('_', ' ').title()}"
            + (f"\n  Target Duration: {tf_months} month(s)" if tf_months else "")
        )

    gf_extra = ""
    if is_general:
        fitness_level = getattr(data, 'fitness_level', 'beginner')
        health_goals  = getattr(data, 'health_goals', []) or []
        gf_extra = (
            f"\n  Fitness Level: {fitness_level}"
            f"\n  Health Goals: {', '.join(health_goals) if health_goals else 'general fitness'}"
        )

    return f"""USER PROFILE:
  Age: {data.age} | Gender: {data.gender}
  Current Weight: {data.weight_kg} kg{'' if is_general else f' | Goal Weight: {data.goal_weight_kg} kg'}
  Height: {data.height_cm} cm | BMI: {calc['bmi']} ({calc['bmi_category']})
  Activity Level: {data.activity_level} | Occupation: {data.occupation}
  Living Situation: {data.living_situation}
  Diet Preference: {data.diet_preference}
  Workout Preference: {data.workout_preference}
  Available Time: {data.available_time} min/day
  Sleep: {data.sleep_hours} hours | Stress: {data.stress_level}/10
  Budget: {data.budget or "not specified"}
  Medical Conditions: {data.medical_conditions or "none"}{gf_extra}{tf_extra}

CALCULATED TARGETS:
  {cal_label}: {calc['weight_loss_calories_kcal']} kcal
  {cal_change}
  Protein Target: {calc['protein_target_g']} g/day
  Water Target: {calc['water_target_liters']} L/day
  Daily Steps Goal: {calc['daily_steps_goal']:,} steps{goal_line}"""


# ══════════════════════════════════════════════════════════════════════════════
# LLM PLAN GENERATORS  (called in parallel inside /generate-plan)
# ══════════════════════════════════════════════════════════════════════════════

_DIET_SYSTEM = """You are Zino, the ZITLAS nutrition assistant.
Generate a 7-day personalized weight-loss diet plan grounded in the retrieved research.

STRICT RULES:
1. Use ONLY the retrieved research context to guide food recommendations and meal timing.
2. All calories and protein must precisely match the user's calculated daily targets.
3. Suggest Indian foods suited to the user's living situation.
   - Hostel users: canteen-compatible options (dal, sabzi, roti, curd, boiled eggs).
   - Home users: simple home-cooked Indian meals.
4. Vegetarian/vegan users: absolutely no meat or fish.
5. Keep meal preparation simple — no recipe requiring more than 10 minutes.
6. Output ONLY valid JSON. No markdown, no preamble.

GOAL: Weight loss — calorie deficit, high protein, fat reduction.

JSON SCHEMA:
{
  "plan_name": "string",
  "daily_calories_target": number,
  "daily_protein_target_g": number,
  "days": [
    {
      "day": "Monday",
      "theme": "one-phrase day focus",
      "total_calories": number,
      "total_protein_g": number,
      "meals": [
        {
          "meal_name": "Breakfast | Mid-Morning | Lunch | Evening Snack | Dinner",
          "time": "8:00 AM",
          "foods": ["food item 1", "food item 2"],
          "calories": number,
          "protein_g": number,
          "tip": "one practical tip"
        }
      ]
    }
  ],
  "key_rules": ["rule1", "rule2", "rule3"],
  "summary": "2 sentences — strategy and expected outcome"
}"""

_DIET_SYSTEM_MUSCLE = """You are Zino, the ZITLAS nutrition assistant.
Generate a 7-day personalized muscle-gain diet plan grounded in the retrieved research.

STRICT RULES:
1. Use ONLY the retrieved research context to guide food recommendations and meal timing.
2. All calories and protein must precisely match the user's calculated daily targets.
3. Suggest Indian foods suited to the user's living situation.
   - Hostel users: canteen-compatible options (dal, sabzi, roti, curd, boiled eggs, paneer).
   - Home users: simple home-cooked Indian meals with adequate protein sources.
4. Vegetarian/vegan users: absolutely no meat or fish.
5. Keep meal preparation simple — no recipe requiring more than 10 minutes.
6. Output ONLY valid JSON. No markdown, no preamble.

GOAL: Muscle gain — calorie surplus, very high protein (2g/kg), progressive overload support.

JSON SCHEMA:
{
  "plan_name": "string",
  "daily_calories_target": number,
  "daily_protein_target_g": number,
  "days": [
    {
      "day": "Monday",
      "theme": "one-phrase day focus",
      "total_calories": number,
      "total_protein_g": number,
      "meals": [
        {
          "meal_name": "Breakfast | Mid-Morning | Lunch | Evening Snack | Dinner",
          "time": "8:00 AM",
          "foods": ["food item 1", "food item 2"],
          "calories": number,
          "protein_g": number,
          "tip": "one practical tip"
        }
      ]
    }
  ],
  "key_rules": ["rule1", "rule2", "rule3"],
  "summary": "2 sentences — strategy and expected outcome"
}"""


_WORKOUT_SYSTEM = """You are Zino, the ZITLAS fitness coach.
Generate a 7-day personalized weight-loss workout plan grounded in the retrieved research.

═══════════════════════════════════════════════════════════
CORE PRINCIPLE
═══════════════════════════════════════════════════════════
Weight Loss = Calorie Deficit + Cardio + Bodyweight Strength Training.
EVERY PLAN must mix cardio AND strength AND core AND one recovery day.
NEVER generate a plan where all workout days are walking sessions only.
Walking alone is ONLY acceptable on dedicated Cardio Focus or Active Recovery days.
Every workout day MUST contain at least one strength or core exercise.

═══════════════════════════════════════════════════════════
EXERCISE BANKS BY FITNESS LEVEL
═══════════════════════════════════════════════════════════
The user's fitness level is given in the prompt. Use only the appropriate bank.

BEGINNER (BMI > 30 or sedentary activity level):
  Cardio:   Brisk Walk, Incline Walk, Interval Walk (slow/fast), Low-Pace Cycling
  Strength: Chair Squat, Wall Push-Up, Glute Bridge, Step-Up, Standing Calf Raise
  Core:     Plank (on knees or full), Bird Dog, Dead Bug
  Recovery: Light Full-Body Stretching, Easy Walk (15–20 min)
  Rep scheme: 2–3 sets × 10–12 reps. Rest 60 seconds. Form over speed.
  NO jumping, NO burpees, NO high-impact movements.

INTERMEDIATE (BMI 25–30 with moderate activity, or beginner with BMI < 25):
  Cardio:   Fast Walk, Stair Climbing, High Knees, Cycling, Elliptical (gym)
  Strength: Bodyweight Squat, Lunge, Push-Up, Glute Bridge, Dumbbell Row (gym)
  Core:     Plank (full), Mountain Climbers, Bicycle Crunch, Leg Raise
  Recovery: Yoga Flow, Mobility Stretches, Easy Walk
  Rep scheme: 3 sets × 12–15 reps. Rest 45 seconds.

ADVANCED (BMI < 25 with active or very active level):
  Cardio:   HIIT Interval Walk/Jog, Stair Sprints, Jump Rope, Rowing Machine (gym)
  Strength: Bulgarian Split Squat, Jump Squat, Push-Up Variations, Walking Lunge
  Core:     Plank Variations, Burpees, V-Sit, Bicycle Crunch
  Recovery: Active Stretching, Foam Rolling
  Rep scheme: 3–4 sets × 15 reps. Rest 30–45 seconds.

═══════════════════════════════════════════════════════════
MANDATORY WEEKLY STRUCTURE (7 days)
═══════════════════════════════════════════════════════════
Every plan MUST include ALL of the following:
  ✓ 2–3 Cardio sessions  (walk or cardio — short, 20–35 min)
  ✓ 2–3 Strength sessions (lower, upper, or full body + strength exercises)
  ✓ 1–2 Combined days    (Cardio warm-up 10–20 min, then 2–4 strength exercises)
  ✓ 1   Core-focused session (3–4 core exercises)
  ✓ 1   Full Rest day
  ✓ 1   Active Recovery day (easy walk 15–20 min + stretching)

REFERENCE TEMPLATE (adapt to fitness level and available time):
  Monday:    Cardio + Lower Body Strength
  Tuesday:   Cardio Focus (walk/cycle — no strength)
  Wednesday: Upper Body + Core
  Thursday:  Interval Cardio (walking intervals OR stair climbing)
  Friday:    Full Body Strength + Core
  Saturday:  Longer Moderate Cardio (30–40 min walk)
  Sunday:    Active Recovery (15 min easy walk + full-body stretch)

═══════════════════════════════════════════════════════════
PERSONALIZATION RULES
═══════════════════════════════════════════════════════════
1. BMI > 35: LOW IMPACT ONLY. No jumping, no burpees, no high-impact HIIT.
             Use only Beginner bank. Reduce reps if user is very deconditioned.
2. BMI 30–35: Beginner bank. Keep sessions under 35 min. Prioritize consistency.
3. BMI 25–30: Intermediate bank. Mix cardio and strength 3–4 days.
4. BMI < 25: Intermediate or Advanced bank. More strength, interval cardio allowed.
5. WORKOUT PREFERENCE:
   - walking  → Walking is the cardio. Still add bodyweight strength on workout days.
   - home     → Bodyweight strength + walking or home cardio. No gym equipment.
   - gym      → Use treadmill, dumbbells, resistance machines, cables as appropriate.
   - none     → Light bodyweight only (wall push-ups, chair squats, easy walks).
6. Never exceed the user's available time per session.
7. Age > 55 or medical conditions: reduce intensity, prioritize low-impact exercises.
8. Preserve muscle: avoid excessive cardio. Include strength every week.

═══════════════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════════════
Output ONLY valid JSON. No markdown, no preamble.

GOAL: Fat loss while preserving lean muscle. Consistency over intensity.

JSON SCHEMA:
{
  "plan_name": "string",
  "fitness_level": "Beginner | Intermediate | Advanced",
  "weekly_frequency": "X days/week",
  "weekly_plan": [
    {
      "day": "Monday",
      "type": "Workout | Cardio | Rest | Active Recovery",
      "focus": "e.g. Cardio + Lower Body | Upper Body + Core | Interval Walk",
      "duration_minutes": number,
      "calories_burned_est": number,
      "exercises": [
        {
          "name": "exercise name",
          "sets": number,
          "reps_or_duration": "12 reps | 30 sec | 25 min",
          "rest_seconds": number,
          "tip": "one coaching cue for safety or form"
        }
      ],
      "daily_tip": "one motivating or practical tip"
    }
  ],
  "weekly_calorie_burn_est": number,
  "summary": "2 sentences — why this plan works for this specific user"
}"""

_WORKOUT_SYSTEM_MUSCLE = """You are Zino, the ZITLAS fitness and wellness assistant.
Generate a 7-day personalized muscle-gain workout plan grounded in the retrieved research.

STRICT RULES:
1. Use the retrieved muscle-gain research context to select exercises and protocols.
2. GOAL IS HYPERTROPHY — every session must use resistance training. NEVER program walking,
   jogging, HIIT, or steady-state cardio as a workout session. These are weight-loss tools.
3. Match exercises to the user's workout preference:
   - home     → bodyweight progressive overload only:
                 Upper: push-ups, diamond push-ups, pike push-ups, dips (chair), rows (table/bar).
                 Lower: squats, Bulgarian split squats, lunges, glute bridges, jump squats.
                 Core: plank, hollow hold, bicycle crunches, leg raises.
   - gym      → compound + isolation lifts:
                 Push: bench press, incline dumbbell press, overhead press, triceps pushdown.
                 Pull: barbell row, lat pulldown, dumbbell curl, face pulls.
                 Legs: barbell squat, Romanian deadlift, leg press, leg curl, calf raises.
   - walking  → treat EXACTLY like home preference — resistance bodyweight training only.
                 Do NOT program walking sessions for a muscle-gain plan.
   - none     → minimal-equipment bodyweight resistance circuit.
4. Respect the user's available time — never exceed it.
5. Programme 3–5 resistance training sessions per week. Minimum 2 rest or active-recovery days.
6. Active recovery = gentle mobility and stretching ONLY — not cardio.
7. Hypertrophy rep range: 8–12 reps per set. Rest: 60–90 seconds between sets.
   Each session: 3–5 exercises, 3–4 sets each.
8. Include a progression instruction for every exercise (e.g. "add 1 rep per week" or
   "progress to diamond push-ups when you can do 15 standard push-ups").
9. Keep instructions simple enough for a complete beginner.
10. Output ONLY valid JSON. No markdown, no preamble.

GOAL: Muscle gain — progressive resistance overload, hypertrophy, strength. NOT fat loss.

JSON SCHEMA:
{
  "plan_name": "string",
  "weekly_frequency": "X days/week",
  "training_split": "e.g. Full Body 3x | Push/Pull/Legs | Upper/Lower",
  "weekly_plan": [
    {
      "day": "Monday",
      "type": "Workout | Rest | Active Recovery",
      "focus": "e.g. Upper Body Push | Lower Body | Full Body Hypertrophy",
      "duration_minutes": number,
      "sets_volume_est": number,
      "exercises": [
        {
          "name": "exercise name",
          "sets": number,
          "reps_or_duration": "8-12 reps",
          "rest_seconds": number,
          "tip": "one coaching cue for form or intensity",
          "progression": "how to make it harder next week"
        }
      ],
      "daily_tip": "one motivating muscle-gain tip"
    }
  ],
  "weekly_training_volume_sets": number,
  "summary": "2 sentences — why this split and volume works for muscle gain"
}"""


_DIET_SYSTEM_GENERAL = """You are Zino, the ZITLAS nutrition assistant.
Generate a 7-day personalized general fitness diet plan grounded in the retrieved research.

STRICT RULES:
1. Use ONLY the retrieved research context to guide food recommendations and meal timing.
2. Calories must match the user's MAINTENANCE level (TDEE) — this is NOT a deficit or surplus.
3. Suggest Indian foods suited to the user's living situation.
   - Hostel users: canteen-compatible options (dal, sabzi, roti, curd, boiled eggs, seasonal fruits).
   - Home users: simple home-cooked Indian meals with adequate protein and vegetables.
4. Vegetarian/vegan users: absolutely no meat or fish.
5. Keep meal preparation simple — no recipe requiring more than 10 minutes.
6. Output ONLY valid JSON. No markdown, no preamble.

GOAL: General fitness — balanced nutrition for sustained energy, overall health, and fitness performance.
Focus on: whole foods, adequate protein, micronutrient density, hydration. NOT weight loss or muscle gain.
DO NOT focus on calorie restriction or calorie surplus — focus on QUALITY and BALANCE.

JSON SCHEMA:
{
  "plan_name": "string",
  "daily_calories_target": number,
  "daily_protein_target_g": number,
  "days": [
    {
      "day": "Monday",
      "theme": "one-phrase day focus (e.g. Energy Day, Recovery Day, Strength Fuel)",
      "total_calories": number,
      "total_protein_g": number,
      "meals": [
        {
          "meal_name": "Breakfast | Mid-Morning | Lunch | Evening Snack | Dinner",
          "time": "8:00 AM",
          "foods": ["food item 1", "food item 2"],
          "calories": number,
          "protein_g": number,
          "tip": "one practical tip"
        }
      ]
    }
  ],
  "key_rules": ["rule1", "rule2", "rule3"],
  "summary": "2 sentences — balanced nutrition strategy for general fitness"
}"""


_DIET_SYSTEM_TRANSFORMATION = """You are the ZITLAS Transformation Coach — nutrition specialist.
Generate a 7-day body transformation diet plan grounded in the retrieved tf1.pdf research.

STRICT RULES:
1. Use ONLY the retrieved transformation research context (tf1.pdf) to guide recommendations.
2. NEVER import meal ideas from weight loss, muscle gain, or general fitness plans.
3. Calories must reflect a MILD DEFICIT (200–350 kcal below TDEE) — enough to lose fat without sacrificing muscle.
4. Protein must be HIGH: 2.0–2.2g per kg of body weight — critical for body recomposition.
5. Suggest Indian foods suited to the user's living situation.
   - Hostel users: canteen-compatible options (eggs, dal, paneer, curd, sprouts, roti).
   - Home users: simple home-cooked high-protein Indian meals.
6. Vegetarian/vegan users: absolutely no meat or fish.
7. Every meal must serve the transformation goal: high protein, moderate carbs, healthy fats.
8. Keep meal preparation simple — no recipe requiring more than 10 minutes.
9. Output ONLY valid JSON. No markdown, no preamble.

GOAL: Body transformation — six pack abs, lean physique, body recomposition.
Focus on: high protein, mild calorie deficit, nutrient timing, progressive fat loss while building muscle.

JSON SCHEMA:
{
  "plan_name": "string",
  "daily_calories_target": number,
  "daily_protein_target_g": number,
  "days": [
    {
      "day": "Monday",
      "theme": "one-phrase transformation focus (e.g. Lean Fuel Day, Recomp Day, High Protein Day)",
      "total_calories": number,
      "total_protein_g": number,
      "meals": [
        {
          "meal_name": "Breakfast | Pre-Workout | Lunch | Post-Workout | Dinner",
          "time": "8:00 AM",
          "foods": ["food item 1", "food item 2"],
          "calories": number,
          "protein_g": number,
          "tip": "one transformation-specific practical tip"
        }
      ]
    }
  ],
  "key_rules": ["rule1", "rule2", "rule3"],
  "summary": "2 sentences — transformation nutrition strategy and expected visible results"
}"""


_WORKOUT_SYSTEM_TRANSFORMATION = """You are the ZITLAS Transformation Coach — fitness specialist.
Generate a 7-day body transformation workout plan grounded in the retrieved tf1.pdf research.

GOAL: Body transformation — six pack abs, lean physique, body recomposition.
NOT general fitness. NOT muscle gain bulk. NOT weight loss cardio-only plan.
This is a TRANSFORMATION plan: resistance training + strategic cardio + core work.

═══════════════════════════════════════════════════════════
TRANSFORMATION TRAINING PRINCIPLES
═══════════════════════════════════════════════════════════
1. Resistance training is MANDATORY 3–4 days/week — preserves and builds muscle while in mild deficit.
2. Strategic cardio (20–30 min) 2–3 days/week — accelerates fat loss without burning muscle.
3. Core-focused work 3+ days/week — directly targets six pack development.
4. Progressive overload every week — add 1 rep or 1 kg to each exercise.
5. Abs are built with resistance training but REVEALED by diet. Plan must address both.
6. Never programme 5+ cardio-only days — that is a weight loss plan, not transformation.

═══════════════════════════════════════════════════════════
EXERCISE SELECTION
═══════════════════════════════════════════════════════════
Resistance (pick based on gym/home preference):
  Home: Push-ups, Pike Push-ups, Bulgarian Split Squat, Glute Bridge, Dips (chair), Rows (table)
  Gym:  Bench Press, Overhead Press, Barbell Squat, Romanian Deadlift, Pull-ups, Cable Row

Cardio (transformation-specific — fat burning without muscle loss):
  Preferred: LISS (Low Intensity Steady State) — 20–30 min brisk walk or light cycle
  Optional:  Short HIIT (10–15 min) — only 1–2 sessions/week max to avoid catabolism

Core (for six pack development):
  Plank, Hollow Hold, Hanging Leg Raise, Cable Crunch, Bicycle Crunch, Ab Rollout, V-Sit, Dead Bug

═══════════════════════════════════════════════════════════
MANDATORY WEEKLY STRUCTURE
═══════════════════════════════════════════════════════════
Every transformation plan MUST include:
  ✓ 3–4 Resistance training days    (compound + isolation + core)
  ✓ 2   Strategic cardio days       (LISS — not HIIT marathon)
  ✓ 1   Core-focused session        (4–5 core exercises, targeting visible abs)
  ✓ 1   Active Recovery day         (light stretching + mobility)
  ✓ 1   Full Rest day

═══════════════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════════════
Output ONLY valid JSON. No markdown, no preamble.

JSON SCHEMA:
{
  "plan_name": "string",
  "weekly_frequency": "X days/week",
  "training_split": "e.g. Push/Pull/Legs + Core | Upper/Lower + Cardio",
  "weekly_plan": [
    {
      "day": "Monday",
      "type": "Resistance | Cardio | Core | Rest | Active Recovery",
      "focus": "e.g. Upper Body + Core | LISS Cardio | Lower Body Recomp",
      "duration_minutes": number,
      "exercises": [
        {
          "name": "exercise name",
          "sets": number,
          "reps_or_duration": "10-12 reps | 30 sec | 25 min",
          "rest_seconds": number,
          "tip": "one transformation coaching cue",
          "progression": "how to make it harder next week"
        }
      ],
      "daily_tip": "one transformation-specific motivating tip"
    }
  ],
  "weekly_calorie_burn_est": number,
  "summary": "2 sentences — why this transformation plan creates visible results for this specific user"
}"""


_WORKOUT_SYSTEM_GENERAL = """You are Zino, the ZITLAS fitness coach.
Generate a 7-day personalized general fitness workout plan grounded in the retrieved research.

GOAL: General fitness — balanced health, energy, strength, and mobility.
NOT weight loss calorie-burn plans. NOT muscle gain bodybuilding routines.

═══════════════════════════════════════════════════════════
WORKOUT ROUTING — apply the FIRST rule that matches the user profile
═══════════════════════════════════════════════════════════
Rule 1: IF fitness_level = Beginner AND workout_preference = walking
         → WALKING PROGRESSION: Walking + Gentle Mobility. No running. No gym. Start slow.

Rule 2: IF fitness_level = Beginner AND workout_preference = home
         → BODYWEIGHT BASICS: Walking + Bodyweight. Chair squats, wall push-ups, gentle core.

Rule 3: IF fitness_level = Beginner (any other preference)
         → WALKING + MOBILITY: Start with walking, add simple stretching and mobility.

Rule 4: IF health_goals includes "mobility" OR "posture" (any fitness level)
         → MOBILITY FIRST: Prioritize mobility, flexibility, and posture correction.
           Supplement with light cardio and gentle strength.

Rule 5: IF activity_level = sedentary (any fitness level)
         → WALKING PROGRESSION: Build from short walks. Add bodyweight when ready.

Rule 6: IF fitness_level = Intermediate
         → FUNCTIONAL FITNESS: Balanced mix of cardio, functional strength, and mobility.
           3 workout days + 1 dedicated mobility/yoga day + rest days.

Rule 7: IF fitness_level = Advanced
         → COMPLETE FITNESS: Higher intensity functional training, sport conditioning,
           advanced mobility. 4–5 workout days.

═══════════════════════════════════════════════════════════
APPROVED EXERCISE TYPES (use these — general fitness only)
═══════════════════════════════════════════════════════════
Cardio:    Brisk Walking, Cycling, Light Jogging (intermediate/advanced only), Swimming
Strength:  Bodyweight Squats, Push-ups, Lunges, Glute Bridges, Plank, Bird Dog
Mobility:  Hip Circles, Shoulder Rolls, Spinal Twists, Hip Flexor Stretch, Hamstring Stretch
Core:      Plank, Dead Bug, Bird Dog, Bicycle Crunch (no-impact core)
Functional:Farmer Carry, Step-ups, Box Step, Lateral Shuffles
Recovery:  Easy Walk, Full-Body Stretch, Yoga Flow, Foam Rolling, Breathing Exercises

═══════════════════════════════════════════════════════════
NEVER USE (these belong to other goals)
═══════════════════════════════════════════════════════════
- Bodybuilding terms: hypertrophy, progressive overload, lean bulk, cutting
- Weight loss terms: fat burn, calorie torch, HIIT circuit for fat loss
- Heavy barbell lifts (bench press, deadlift, barbell squat) — unless user is Advanced + Gym
- Burpees, Jump Squats, Box Jumps for Beginners

═══════════════════════════════════════════════════════════
MANDATORY WEEKLY STRUCTURE
═══════════════════════════════════════════════════════════
Every plan MUST include:
  ✓ 2–4 workout days    (based on fitness level and available time)
  ✓ 1   dedicated Mobility / Flexibility day
  ✓ 1   Active Recovery day  (easy walk 15–20 min + stretching)
  ✓ 1–2 Full Rest days
  ✓ Mix of cardio + strength + mobility across the week

═══════════════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════════════
Output ONLY valid JSON. No markdown, no preamble.

JSON SCHEMA:
{
  "plan_name": "string",
  "fitness_level": "Beginner | Intermediate | Advanced",
  "weekly_frequency": "X days/week",
  "weekly_plan": [
    {
      "day": "Monday",
      "type": "Workout | Mobility | Rest | Active Recovery",
      "focus": "e.g. Brisk Walk + Core | Mobility Flow | Functional Strength",
      "duration_minutes": number,
      "exercises": [
        {
          "name": "exercise name",
          "sets": number,
          "reps_or_duration": "10 reps | 30 sec | 20 min",
          "rest_seconds": number,
          "tip": "one coaching cue for form or safety"
        }
      ],
      "daily_tip": "one motivating general fitness tip"
    }
  ],
  "weekly_calorie_burn_est": number,
  "summary": "2 sentences — why this plan builds general fitness for this specific user"
}"""


async def _generate_diet_plan(
    data: AssessmentInput,
    calc: dict,
    rag_context: str,
    fitness_goal: str = "weight_loss",
) -> dict | None:
    """Call LLM with RAG context to produce a 7-day diet plan JSON."""
    is_muscle         = fitness_goal == "muscle_gain"
    is_general        = fitness_goal == "general_fitness"
    is_transformation = fitness_goal == "transformation"
    goal_label = (
        "muscle-gain"     if is_muscle         else
        "general-fitness" if is_general        else
        "transformation"  if is_transformation else
        "weight-loss"
    )
    diet_system = (
        _DIET_SYSTEM_MUSCLE          if is_muscle         else
        _DIET_SYSTEM_GENERAL         if is_general        else
        _DIET_SYSTEM_TRANSFORMATION  if is_transformation else
        _DIET_SYSTEM
    )

    # Canonical key, not substring guesswork. The previous line tested
    # `"veg" in diet_preference`, which is TRUE for "non-vegetarian" — so every
    # non-vegetarian was handed the vegetarian rule. And the vegetarian rule
    # itself listed "chicken, fish, meat, seafood" but never EGGS, which is how
    # "2 boiled eggs" kept landing in pure-vegetarian plans. Eggs are not
    # vegetarian in ZITLAS; the rule now says so explicitly, per canonical key.
    diet_key = food_engine.canonical_diet_key(data.diet_preference)
    _VEG_RULES = {
        food_engine.DIET_PURE_VEGETARIAN: (
            "User is PURE VEGETARIAN — a HARD CONSTRAINT. NEVER include eggs "
            "(no boiled eggs, omelette, bhurji made with egg, anda, mayonnaise), "
            "chicken, mutton, fish, seafood, or any meat. Meet protein with dal, "
            "paneer, curd, milk, soya, sprouts, chana, rajma, tofu and nuts."
        ),
        food_engine.DIET_VEGAN: (
            "User is VEGAN — a HARD CONSTRAINT. NEVER include eggs, meat, fish, "
            "seafood, OR any dairy (no milk, curd, paneer, cheese, butter, ghee, "
            "whey). Meet protein with dal, soya, tofu, chana, rajma, sprouts, nuts "
            "and seeds."
        ),
        food_engine.DIET_JAIN: (
            "User follows a JAIN diet — a HARD CONSTRAINT. No eggs, meat, fish or "
            "seafood, and no onion, garlic or root vegetables."
        ),
        food_engine.DIET_EGGETARIAN: (
            "User is EGGETARIAN — eggs ARE allowed and are a good protein source, "
            "but NEVER include chicken, mutton, fish, seafood or any meat."
        ),
        food_engine.DIET_NON_VEGETARIAN: (
            "User eats non-vegetarian food — eggs, chicken and fish are all "
            "available as protein sources alongside vegetarian options."
        ),
    }
    veg_rule = _VEG_RULES[diet_key]

    # Medical conditions are a first-priority input, not inert profile text —
    # this renders "" for healthy users, leaving the prompt unchanged.
    med_directives = medcon.build_condition_directives(data.medical_conditions)
    med_diet_block = medcon.format_prompt_block(med_directives, "diet")

    # Supplement preference (#2): a hard rule, not a suggestion. "" (not
    # asked — older clients) renders nothing, leaving the prompt unchanged.
    uses_supp = (getattr(data, "uses_supplements", "") or "").lower()
    if uses_supp == "no":
        # The whole-food examples must respect the diet: this used to name
        # "eggs" (and chicken/fish) to every user, actively prompting the model
        # to put eggs in a pure-vegetarian plan.
        _WHOLE_FOOD_SOURCES = {
            food_engine.DIET_PURE_VEGETARIAN: "dal, paneer, curd, milk, soya chunks, sprouts, chana, rajma, tofu, nuts",
            food_engine.DIET_VEGAN:           "dal, soya chunks, tofu, chana, rajma, sprouts, peanuts, seeds",
            food_engine.DIET_JAIN:            "dal, paneer, curd, milk, soya chunks, moong, nuts",
            food_engine.DIET_EGGETARIAN:      "eggs, dal, paneer, curd, milk, soya chunks, sprouts, chana",
            food_engine.DIET_NON_VEGETARIAN:  "eggs, chicken, fish, dal, paneer, curd, milk, soya chunks, sprouts, chana",
        }
        supplement_rule = (
            "\nSUPPLEMENT RULE — HARD CONSTRAINT: The user does NOT use supplements. "
            "NEVER recommend whey protein, protein powder, creatine, mass gainer, BCAA, "
            "pre-workout, or any supplement product. Meet protein targets with whole foods "
            f"only: {_WHOLE_FOOD_SOURCES[diet_key]}."
        )
    elif uses_supp == "yes":
        supp_list = ", ".join(getattr(data, "supplement_types", []) or []) or "general supplements"
        supplement_rule = (
            f"\nSUPPLEMENT NOTE: The user already uses: {supp_list}. You may include these "
            "where genuinely relevant (e.g. whey post-workout) — never push new supplements they didn't list."
        )
    else:
        supplement_rule = ""

    # Budget realism (#4): a low daily budget makes expensive foods a hard
    # exclusion, with the affordable staples spelled out explicitly.
    _budget_nums = re.findall(r"\d+", str(data.budget or ""))
    _budget_val = int(_budget_nums[0]) if _budget_nums else None
    if _budget_val is not None and _budget_val <= 150:
        budget_rule = (
            f"\nBUDGET RULE — HARD CONSTRAINT: The user's food budget is ~₹{_budget_val}/day. "
            "NEVER recommend salmon, avocado, blueberries, quinoa, kale, imported fruits, "
            "almond butter, or expensive nuts. Build every meal from affordable Indian staples: "
            "dal, rice, roti, eggs, banana, milk, curd, peanuts, sprouts, chana, poha, upma, "
            "seasonal local vegetables. The full day's food must realistically cost under the budget."
        )
    else:
        budget_rule = ""

    # Geo-Aware Food Intelligence (#12 spec): purely additive — a hard rule
    # only appears when the user actually shared a location; absent location
    # renders "" and this prompt is byte-for-byte what it was before.
    region_boost = location_food_engine.build_region_boost(data.location)
    if region_boost:
        geo_rule = (
            f"\nREGIONAL FOOD RULE: The user is in {region_boost['region_label']}. "
            f"Where it fits their goal and budget, prefer foods and dishes common in this "
            f"region ({', '.join(region_boost['preferred_keywords'])}) over foods that are "
            f"hard to find locally (e.g. imported/exotic items). If you include a popular "
            f"local street food, make it healthier rather than replacing it "
            f"(e.g. less oil/ghee, baked instead of fried, paired with curd/buttermilk) — "
            f"do not just drop it."
        )
    else:
        geo_rule = ""

    prompt = f"""RESEARCH CONTEXT ({goal_label} nutrition knowledge base):
{rag_context if rag_context else "No specific research retrieved — use general evidence-based principles."}

---

{_build_user_profile_block(data, calc, fitness_goal)}

DIET RULE: {veg_rule}
LIVING SITUATION NOTE: {'Hostel/canteen foods — keep suggestions mess-friendly.' if data.living_situation.lower() == 'hostel' else 'Home cooking available.'}
{med_diet_block}{supplement_rule}{budget_rule}{geo_rule}

Generate a complete 7-day {goal_label} diet plan. Hit {calc['weight_loss_calories_kcal']} kcal and {calc['protein_target_g']}g protein EVERY day.
Output valid JSON only — no extra text."""

    # Explicitly enumerate all 7 days so the model never stops at 5
    prompt += (
        "\n\nYou MUST generate exactly 7 day objects in the 'days' array: "
        "Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday. "
        "Never generate fewer than 7 days."
    )

    all_days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    _empty_diet_llm: dict = {"tokens_used": 0, "model": None, "reply": ""}

    async def _call_diet_ai(extra_hint: str = "") -> tuple[dict | None, dict]:
        _prompt = prompt + extra_hint
        # DYNAMIC, not a static number — see groq_service.safe_max_tokens's
        # docstring for the production incident this replaced: a fixed 6000
        # still exceeded Groq's 8000 TPM cap once the actual ~2100-token
        # prompt was counted against it. 6000 stays the ceiling when the
        # prompt is small; it shrinks automatically when the prompt is big.
        _max_tokens = groq_service.safe_max_tokens(_prompt, diet_system, desired=6000)
        print(f"[DIET AI] provider=groq_first goal={fitness_goal} "
              f"promptTokensEst={groq_service.estimate_tokens(_prompt) + groq_service.estimate_tokens(diet_system)} "
              f"maxCompletionTokens={_max_tokens}")
        try:
            _result = await groq_service.chat(
                user_message=_prompt,
                system_override=diet_system,
                temperature=0.5,
                max_tokens=_max_tokens,
                json_mode=True,
                groq_key_env="GROQ_API_KEY_DIET",
                provider="groq_first",
            )
        except Exception as e:
            # THE actual production bug: this call used to be unguarded, so
            # a total provider failure (Groq TPM-limited + Gemini/OpenRouter
            # unconfigured) raised straight out of _call_diet_ai — past the
            # "days < 7" retry AND past the _engine_grounded_diet_plan
            # fallback below (both only ever ran on a MALFORMED response,
            # never on "no response at all") — all the way to generate_plan's
            # outer except, which just logs and leaves diet_plan: null. That
            # is the exact defect this fixes: treating "provider chain threw"
            # exactly like "provider returned nothing usable" so the SAME
            # existing fallback fires either way.
            print(f"[DIET AI] provider=groq_first goal={fitness_goal} status=failed "
                  f"reason={type(e).__name__}: {str(e)[:200]}")
            return None, _empty_diet_llm
        print(f"[DIET AI] provider=groq_first goal={fitness_goal} status=success "
              f"model={_result.get('model')} tokensUsed={_result.get('tokens_used')}")
        return _extract_json(_result["reply"]), _result

    parsed, result = await _call_diet_ai()

    # ── Retry once if AI returned fewer than 7 days ──────────────────────────
    if not parsed or not isinstance(parsed.get("days"), list) or len(parsed["days"]) < 7:
        existing_days = [d.get("day", "") for d in (parsed or {}).get("days", [])]
        missing = [d for d in all_days if d not in existing_days]
        print(f"[DIET AI] WARNING: only got {len(existing_days)} days ({existing_days}), missing: {missing}. Retrying.")
        retry_hint = (
            f"\n\nCRITICAL: Your previous response was missing these days: {missing}. "
            f"You MUST include ALL 7 days: Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday. "
            f"Return the complete plan — do not omit any day."
        )
        parsed_retry, result_retry = await _call_diet_ai(retry_hint)
        if parsed_retry and isinstance(parsed_retry.get("days"), list) and len(parsed_retry["days"]) >= len((parsed or {}).get("days", [])):
            parsed, result = parsed_retry, result_retry
            print(f"[DIET AI] Retry succeeded — got {len(parsed['days'])} days")
        else:
            print(f"[DIET AI] Retry did not improve day count — using auto-pad")

    # ── Both attempts failed to produce ANY usable plan (e.g. every provider
    #    hit a rate limit / truncated output and _extract_json got nothing
    #    parseable) — serve a real, complete plan from the same verified
    #    food database instead of surfacing `diet_plan: null`. This is the
    #    actual fix for "Diet plan could not be loaded" right after
    #    assessment: the frontend already awaits this response correctly,
    #    there was never a race condition — the response body itself was
    #    legitimately empty, with no fallback to catch it, unlike every
    #    other diet surface in the app (weekly-plan regen, meal swap).
    if not parsed or not isinstance(parsed.get("days"), list) or len(parsed["days"]) == 0:
        parsed = _engine_grounded_diet_plan(data, calc, fitness_goal)
    else:
        # ── Auto-pad any still-missing days (copy last day as template) ──────
        days = parsed["days"]
        present = {d.get("day", "") for d in days}
        for day_name in all_days:
            if day_name not in present:
                template = dict(days[-1]) if days else {
                    "day": day_name, "theme": "Balanced Day",
                    "total_calories": parsed.get("daily_calories_target", 1600),
                    "total_protein_g": parsed.get("daily_protein_target_g", 90),
                    "meals": [],
                }
                template = dict(template)
                template["day"] = day_name
                days.append(template)
                print(f"[DIET AI] Auto-padded missing day: {day_name}")
        day_order = {d: i for i, d in enumerate(all_days)}
        parsed["days"] = sorted(days, key=lambda d: day_order.get(d.get("day", ""), 99))
        print(f"[DIET AI] Final day count: {len(parsed['days'])}")
    # ── POST-GENERATION VALIDATION GATE ──────────────────────────────────────
    # The LLM authors free-form meal text, so no tag-level filter can police it
    # — a prompt-only vegetarian rule is precisely how eggs reached pure
    # vegetarians. Every plan is audited against the canonical diet key and the
    # athlete's allergies BEFORE it is returned. A plan with a hard violation is
    # NOT shown and NOT "patched" with an apology: it is replaced wholesale by
    # the engine-grounded plan, which is built by intersecting the verified food
    # database and therefore cannot contain a forbidden food by construction.
    #
    # Repetition is reported but NOT treated as a hard failure here: the engine
    # already caps repeats per dish family, and discarding an otherwise-valid,
    # nutritionally-targeted LLM plan over a repeated snack would trade a real
    # benefit for a cosmetic one. Hard safety violations are absolute; variety
    # is enforced where it can be enforced without that trade.
    if parsed is not None:
        audit = food_engine.audit_delivered_plan(
            parsed, diet_key, allergens=set(getattr(data, "allergies", []) or [])
        )
        hard = audit["diet_violations"] + audit["allergen_violations"]
        if hard:
            sample = "; ".join(
                f"{v['day']}/{v['meal']}: {v['food']!r} (matched {v['matched']!r})"
                for v in hard[:5]
            )
            print(f"[DIET VALIDATOR] REJECTED LLM plan — {len(hard)} violation(s) for "
                  f"diet={diet_key}: {sample}")
            parsed = _engine_grounded_diet_plan(data, calc, fitness_goal)
            recheck = food_engine.audit_delivered_plan(
                parsed, diet_key, allergens=set(getattr(data, "allergies", []) or [])
            )
            still_bad = recheck["diet_violations"] + recheck["allergen_violations"]
            if still_bad:
                # Should be unreachable: the engine plan is filtered at the
                # database level. Logged loudly rather than silently served,
                # because it would mean the dataset itself is mislabelled in a
                # way the name-level backstop missed.
                print(f"[DIET VALIDATOR] CRITICAL: engine-grounded plan ALSO violates "
                      f"diet={diet_key}: {still_bad[:3]}")
            else:
                print(f"[DIET VALIDATOR] Served engine-grounded plan instead "
                      f"(diet={diet_key}, 0 violations)")
        else:
            reps = audit["repetition"]
            print(f"[DIET VALIDATOR] PASSED diet={diet_key} — 0 dietary/allergen "
                  f"violations, {len(reps)} repetition note(s)"
                  + (f": {[r['dish'] for r in reps[:4]]}" if reps else ""))

    if parsed is not None and region_boost:
        parsed["location_note"] = region_boost["explanation"]
    return parsed, result


async def _generate_workout_plan(
    data: AssessmentInput,
    calc: dict,
    rag_context: str,
    fitness_goal: str = "weight_loss",
) -> tuple[dict | None, dict]:
    """
    Exercises are ALWAYS retrieved from services/workout_engine.py (backend/
    workout/zitlas_kb_records.jsonl) — never invented by the LLM. The LLM
    below is only asked for plan_name/summary/daily_tip narration; whatever
    it writes for exercises/warmup/mobility/stretching/cooldown/breathing/
    mind_reset is discarded and replaced with the engine's picks in
    workout_engine.format_week_for_output(), regardless of what the LLM
    returns — the same hallucination firewall used for diet plans.

    An acute "I'm sick today" / "injured" mention in medical_conditions
    skips the LLM entirely and returns a KB-sourced recovery-only week
    (no strength work, per spec) — see workout_engine.build_recovery_week().
    """
    empty_llm_result = {"tokens_used": 0, "model": "kb-engine", "reply": ""}

    recovery_condition = workout_engine.WorkoutRecommendationEngine.resolve_recovery_condition(data.medical_conditions)
    if recovery_condition:
        engine = workout_engine.get_engine()
        recovery_plan = engine.build_recovery_week(recovery_condition, high_stress=data.stress_level >= 8)
        structured = workout_engine.format_recovery_for_output(recovery_plan, recovery_condition)
        print(f"[WORKOUT ENGINE] Recovery mode active — {recovery_condition}")
        return structured, empty_llm_result

    is_muscle         = fitness_goal == "muscle_gain"
    is_general        = fitness_goal == "general_fitness"
    is_transformation = fitness_goal == "transformation"
    goal_label = (
        "muscle-gain"     if is_muscle         else
        "general-fitness" if is_general        else
        "transformation"  if is_transformation else
        "weight-loss"
    )
    workout_system = (
        _WORKOUT_SYSTEM_MUSCLE          if is_muscle         else
        _WORKOUT_SYSTEM_GENERAL         if is_general        else
        _WORKOUT_SYSTEM_TRANSFORMATION  if is_transformation else
        _WORKOUT_SYSTEM
    )

    if is_transformation:
        pref = data.workout_preference.lower()
        if pref in ("home", "walking", "none"):
            equipment_note = (
                "EQUIPMENT: Bodyweight only — floor space, sturdy chair for dips, "
                "and a table edge for rows. No gym needed. "
                "Full transformation is achievable with bodyweight progressive overload."
            )
        else:
            equipment_note = (
                "EQUIPMENT: Full gym available — barbells, dumbbells, cables, machines, "
                "cable crunches, ab wheel. Use compound lifts + isolation core work."
            )
        muscle_context = f"""
WORKOUT PREFERENCE: {data.workout_preference} — {equipment_note}
TIME LIMIT: {data.available_time} minutes per session.
TRANSFORMATION GOAL: Six pack abs, lean physique, body recomposition.
CRITICAL RULES:
1. Include resistance training 3–4 days/week — preserves muscle while losing fat.
2. Include LISS cardio (20–30 min brisk walk/cycle) 2 days/week for fat burning.
3. Include dedicated core work (plank, hollow hold, leg raises, bicycle crunch) in EVERY resistance session.
4. Add a progression field for every exercise (1 rep/week or 1 kg/week).
5. This is a TRANSFORMATION plan — not a weight loss cardio plan and not a bodybuilding plan."""
    elif is_general:
        fitness_level = getattr(data, 'fitness_level', 'beginner')
        health_goals  = getattr(data, 'health_goals', []) or []
        pref          = data.workout_preference.lower()
        if pref == "gym":
            equip_note = "EQUIPMENT: Gym available — use machines and free weights for functional exercises."
        elif pref in ("walking", "none"):
            equip_note = "EQUIPMENT: Outdoor walking and bodyweight only — no gym equipment."
        elif pref == "mixed":
            equip_note = "EQUIPMENT: Mix of home/outdoor and occasional gym access."
        else:
            equip_note = "EQUIPMENT: Home/outdoor — bodyweight, walking, minimal equipment."

        muscle_context = f"""
FITNESS LEVEL: {fitness_level}
HEALTH GOALS: {', '.join(health_goals) if health_goals else 'general fitness'}
WORKOUT PREFERENCE: {data.workout_preference} — {equip_note}
TIME LIMIT: {data.available_time} minutes maximum per session.

ROUTING INSTRUCTIONS:
- Apply the workout routing rules from the system prompt based on the FITNESS LEVEL and HEALTH GOALS above.
- This is a GENERAL FITNESS plan — focus on energy, health, and balanced fitness.
- Do NOT generate weight-loss calorie-burn plans or muscle-gain bodybuilding plans.
- Include a Mobility day (stretching + flexibility) and an Active Recovery day every week."""
    elif is_muscle:
        pref = data.workout_preference.lower()
        if pref in ("home", "walking", "none"):
            equipment_note = (
                "EQUIPMENT: Bodyweight only — floor space, a sturdy chair for dips, "
                "and a table edge for rows. No gym needed."
            )
        else:
            equipment_note = (
                "EQUIPMENT: Full gym — barbells, dumbbells, cables, machines available."
            )
        muscle_context = f"""
WORKOUT PREFERENCE: {data.workout_preference} — {equipment_note}
TIME LIMIT: {data.available_time} minutes per session.
CRITICAL: This is a MUSCLE GAIN plan. Every training day must use RESISTANCE exercises.
Do NOT include walking, jogging, or cardio as a workout type for muscle gain.
Use the hypertrophy rep range (8–12 reps), 3–4 sets, 60–90s rest between sets.
Add a 'progression' field for every exercise showing how to advance week-over-week."""
    else:
        # ── Weight-loss prompt: BMI-aware intensity + mandatory Cardio+Strength mix ──
        bmi_val = float(calc.get("bmi", 25.0))

        if bmi_val > 35:
            fitness_level = "Beginner"
            intensity_note = (
                "BMI > 35 — LOW IMPACT ONLY. Use Brisk Walk, Chair Squat, Wall Push-Up, "
                "Glute Bridge, Bird Dog. Absolutely NO jumping, burpees, or high-impact drills."
            )
        elif bmi_val > 30:
            fitness_level = "Beginner"
            intensity_note = (
                "BMI 30–35 — Walking + Beginner Strength. Low-impact only. "
                "Keep sessions under 35 min. Prioritize form and consistency."
            )
        elif bmi_val > 25:
            fitness_level = "Intermediate"
            intensity_note = (
                "BMI 25–30 — Walking + Moderate Bodyweight Strength. "
                "Mix cardio and strength exercises every week."
            )
        else:
            fitness_level = "Advanced"
            intensity_note = (
                "BMI < 25 — More strength and conditioning. "
                "Interval cardio allowed. Can include jump squats and push-up variations."
            )

        pref = data.workout_preference.lower()
        if pref == "gym":
            equipment_note = (
                "EQUIPMENT: Full gym available — treadmill, dumbbells, "
                "resistance machines, cables, barbell."
            )
        elif pref == "walking":
            equipment_note = (
                "EQUIPMENT: Walking is the primary cardio. "
                "Add bodyweight strength exercises (no gym equipment needed)."
            )
        elif pref == "none":
            equipment_note = (
                "EQUIPMENT: None. Light bodyweight and walking only. "
                "Simple exercises: wall push-ups, chair squats, easy walks."
            )
        else:  # home
            equipment_note = (
                "EQUIPMENT: No gym — bodyweight exercises and walking/home cardio only."
            )

        muscle_context = f"""
FITNESS LEVEL: {fitness_level}
{intensity_note}
WORKOUT PREFERENCE: {data.workout_preference} — {equipment_note}
TIME LIMIT: {data.available_time} minutes maximum per session.

CRITICAL — FOLLOW THESE RULES OR THE PLAN WILL BE REJECTED:
1. The plan MUST include: Cardio sessions + Strength sessions + Core sessions + Rest/Recovery.
2. NEVER create a plan where all 5+ workout days are walking sessions only.
3. On Cardio+Strength days: 10–20 min cardio first, then 2–4 strength exercises after.
4. Walking-only is ONLY acceptable on dedicated Cardio Focus or Active Recovery days (max 2).
5. Every workout day must have at least one strength or core exercise.
6. Do NOT invent exercises outside the fitness level bank given in the system prompt."""

    # Medical conditions are a first-priority input, not inert profile text —
    # this renders "" for healthy users, leaving the prompt unchanged.
    med_directives = medcon.build_condition_directives(data.medical_conditions)
    med_workout_block = medcon.format_prompt_block(med_directives, "workout")

    # ── EXERCISE SELECTION happens here, deterministically, from the KB —
    #    BEFORE the LLM is ever called. See docstring above.
    if fitness_goal == "weight_loss":
        bmi_val = float(calc.get("bmi", 25.0))
        kb_fitness_level = "beginner" if bmi_val > 30 else ("intermediate" if bmi_val > 25 else "advanced")
    else:
        kb_fitness_level = getattr(data, "fitness_level", "intermediate")
    engine = workout_engine.get_engine()
    condition_names = workout_engine.WorkoutRecommendationEngine.resolve_condition_names(data.medical_conditions)

    # Age/gender/disability profile hints — same avoid_ex/recommended
    # resolution path as chronic conditions (see _unsafe_ids_for_condition),
    # just resolved from age/gender/free-text instead of a keyword-detected
    # illness. Senior/kids also force Beginner difficulty regardless of the
    # stated fitness_level — safety-first for those age brackets.
    age_profile = workout_engine.WorkoutRecommendationEngine.resolve_age_profile_name(data.age)
    disability_profile = workout_engine.WorkoutRecommendationEngine.resolve_disability_name(data.medical_conditions)
    women_profile = workout_engine.WorkoutRecommendationEngine.resolve_women_focus_name(data.gender, condition_names)
    for extra in (age_profile, disability_profile, women_profile):
        if extra:
            condition_names.append(extra)
    if data.age >= 60 or data.age <= 17:
        kb_fitness_level = "beginner"

    lifestyle_name = workout_engine.WorkoutRecommendationEngine.resolve_lifestyle_name(data.living_situation, data.occupation)
    difficulty_levels = workout_engine.difficulty_levels_for(kb_fitness_level)
    equipment_tags = workout_engine.equipment_tags_for(data.workout_preference, data.living_situation)
    high_stress = data.stress_level >= 8
    week_plan = engine.build_week_plan(
        fitness_goal=fitness_goal, difficulty_levels=difficulty_levels, equipment_tags=equipment_tags,
        condition_names=condition_names, lifestyle_name=lifestyle_name, high_stress=high_stress,
        available_time=data.available_time,
        disliked_exercises=getattr(data, "disliked_exercises", []) or [],
        equipment_label=data.workout_preference, level_label=kb_fitness_level,
    )
    print(f"[WORKOUT ENGINE] goal={fitness_goal} level={kb_fitness_level} equipment={equipment_tags} "
          f"conditions={condition_names} lifestyle={lifestyle_name} stress_high={high_stress}")

    kb_summary_lines = []
    for day in week_plan["days"]:
        names = ", ".join(e["name"] for e in day["exercises"]) or "(rest / recovery — no exercises)"
        kb_summary_lines.append(f"  {day['day']} ({day['type']} — {day['focus']}): {names}")
    kb_summary = "\n".join(kb_summary_lines)

    prompt = f"""RESEARCH CONTEXT ({goal_label} fitness and conditioning knowledge base):
{rag_context if rag_context else "No specific research retrieved — use general evidence-based principles."}

---

{_build_user_profile_block(data, calc, fitness_goal)}
{muscle_context}
{med_workout_block}

PRE-SELECTED EXERCISES (from the ZITLAS verified workout knowledge base — already chosen for
equipment/experience/goal/medical safety; do not add, remove, or substitute any exercise):
{kb_summary}

Write a plan_name, a 2-sentence summary, and one daily_tip per day for the plan above. Do not
restate exercises, sets, or reps yourself — those are filled in automatically.
Output valid JSON only — no extra text."""

    prompt += (
        "\n\nYou MUST generate exactly 7 day objects in the 'weekly_plan' array: "
        "Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday. "
        "Never generate fewer than 7 days."
    )

    print(f"[WORKOUT AI] {fitness_goal} prompt | Using GROQ_API_KEY")
    try:
        result = await groq_service.chat(
            user_message=prompt,
            system_override=workout_system,
            temperature=0.5,
            max_tokens=4000,
            json_mode=True,
            provider="groq_first",
        )
        llm_parsed = _extract_json(result["reply"])
    except Exception as e:
        print(f"[WORKOUT AI] LLM call failed ({type(e).__name__}: {e}) — "
              f"continuing with KB-only plan (names/tips auto-generated)")
        llm_parsed, result = None, empty_llm_result

    structured = workout_engine.format_week_for_output(week_plan, fitness_goal, llm_parsed)
    return structured, result


# ══════════════════════════════════════════════════════════════════════════════
# ENDPOINTS
# ══════════════════════════════════════════════════════════════════════════════

@router.get("/health")
async def assessment_health():
    return {"module": "assessment", "status": "ready"}


@router.post("/analyze")
async def analyze(body: AssessmentInput) -> dict[str, Any]:
    """
    Instant assessment engine — pure Python, no LLM, no network calls.

    Computes:
      BMI, BMR, TDEE, weight-loss calories, protein target,
      water target, daily steps goal, SWOT, wellness scores, archetype.

    Response: {assessment, calculations, swot}
    """
    print(f"\n[ASSESS] /analyze  weight={body.weight_kg}kg  goal={body.goal_weight_kg}kg  "
          f"activity={body.activity_level}  living={body.living_situation}")
    try:
        result = run_assessment(body)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))

    print(f"[ASSESS] Done — BMI={result['calculations']['bmi']}  "
          f"TDEE={result['calculations']['tdee_kcal']} kcal  "
          f"target={result['calculations']['weight_loss_calories_kcal']} kcal  "
          f"archetype={result['swot']['user_archetype']}")
    return result


@router.post("/generate-plan")
async def generate_plan(body: AssessmentInput) -> dict[str, Any]:
    """
    Full pipeline: Assessment → Calculations → SWOT → RAG → Diet Plan → Workout Plan.

    Flow:
      1. run_assessment()         — instant calculations + SWOT
      2. RAG retrieval            — top-5 diet chunks + top-5 workout chunks from PDFs
      3. LLM diet plan            — 7-day meal plan grounded in PDF research
      4. LLM workout plan         — 7-day exercise plan grounded in PDF research
      (Steps 3 and 4 run in parallel.)

    Response: {assessment, calculations, swot, diet_plan, workout_plan, sources}
    """
    fitness_goal = body.fitness_goal
    _t0 = time.time()
    print(f"\n[ASSESS] /generate-plan ENTRY  weight={body.weight_kg}kg  goal={body.goal_weight_kg}kg  "
          f"diet={body.diet_preference}  workout={body.workout_preference}  "
          f"living={body.living_situation}  goal_type={fitness_goal!r}")

    # ── Step 1: Pure assessment ──────────────────────────────────────────────
    try:
        assessment_result = run_assessment(body)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))

    calc = assessment_result["calculations"]
    print(f"[ASSESS] Step 1 done ({time.time()-_t0:.1f}s) — BMI={calc['bmi']}  "
          f"target={calc['weight_loss_calories_kcal']} kcal  "
          f"protein={calc['protein_target_g']}g")

    print(f"[ASSESS] After assessment — RAM: {_ram()}")

    # ── Step 2: RAG retrieval (sequential to keep only one KB in RAM at a time) ──
    if fitness_goal == "muscle_gain":
        diet_query = (
            f"muscle gain diet high protein calorie surplus {body.diet_preference} "
            f"{body.living_situation} lean bulk Indian food"
        )
        workout_query = (
            f"muscle gain workout resistance training hypertrophy {body.workout_preference} "
            f"progressive overload strength beginner"
        )
    elif fitness_goal == "general_fitness":
        health_goals_str = " ".join(getattr(body, 'health_goals', []) or [])
        diet_query = (
            f"general fitness balanced nutrition energy health sustainable "
            f"{body.diet_preference} {body.living_situation} Indian food whole foods protein"
        )
        workout_query = (
            f"general fitness workout routine balanced training functional fitness "
            f"walking mobility bodyweight {body.workout_preference} {health_goals_str}"
        )
    elif fitness_goal == "transformation":
        diet_query = (
            f"body transformation diet high protein lean physique six pack abs recomposition "
            f"{body.diet_preference} {body.living_situation} mild deficit Indian food"
        )
        workout_query = (
            f"body transformation workout resistance training core six pack abs "
            f"lean physique recomposition {body.workout_preference} LISS cardio progressive overload"
        )
    else:
        diet_query = (
            f"weight loss diet plan meal plan {body.diet_preference} "
            f"{body.living_situation} calorie deficit high protein Indian food"
        )
        workout_query = (
            f"weight loss exercise workout fitness plan {body.workout_preference} "
            f"fat burning strength conditioning beginner"
        )

    _t_rag = time.time()
    print(f"[ASSESS] RAG start ({time.time()-_t0:.1f}s) — goal={fitness_goal!r} (sequential)")
    diet_sources: list[dict] = []
    workout_sources: list[dict] = []
    diet_context = ""
    workout_context = ""

    # Diet RAG — top_k=3 to reduce context size and memory pressure
    try:
        diet_context, diet_sources = await asyncio.to_thread(
            rag_service.retrieve_context, diet_query, 3, fitness_goal
        )
    except Exception as _rag_exc:
        _tb.print_exc()
        print(f"[ASSESS] Diet RAG FAILED: {type(_rag_exc).__name__}: {_rag_exc}")
    print(f"[ASSESS] After diet RAG — RAM: {_ram()}")

    # Workout RAG — same KB is already cached, so second load is fast
    try:
        workout_context, workout_sources = await asyncio.to_thread(
            rag_service.retrieve_context, workout_query, 3, fitness_goal
        )
    except Exception as _rag_exc:
        _tb.print_exc()
        print(f"[ASSESS] Workout RAG FAILED: {type(_rag_exc).__name__}: {_rag_exc}")
    print(f"[ASSESS] After workout RAG ({time.time()-_t_rag:.1f}s) — RAM: {_ram()}")

    # Deduplicate sources by chunk_id
    _n_diet_chunks    = len(diet_sources)
    _n_workout_chunks = len(workout_sources)
    seen: set[str] = set()
    all_sources: list[dict] = []
    for src in diet_sources + workout_sources:
        if src["chunk_id"] not in seen:
            seen.add(src["chunk_id"])
            all_sources.append(src)
    del seen, diet_sources, workout_sources

    print(f"[ASSESS] RAG done ({time.time()-_t_rag:.1f}s) — "
          f"total_unique={len(all_sources)}")

    # ── Step 3: Generate diet plan ───────────────────────────────────────────
    _t_llm = time.time()
    print(f"[ASSESS] Diet LLM start ({time.time()-_t0:.1f}s)")
    _empty_llm: dict = {"tokens_used": 0, "model": None, "reply": ""}

    diet_structured = None
    diet_llm_result = _empty_llm
    try:
        diet_structured, diet_llm_result = await _generate_diet_plan(
            body, calc, diet_context, fitness_goal
        )
    except Exception as _diet_exc:
        _tb.print_exception(type(_diet_exc), _diet_exc, _diet_exc.__traceback__)
        print(f"[ASSESS] Diet LLM FAILED: {type(_diet_exc).__name__}: {_diet_exc}")

    del diet_context
    gc.collect()
    print(f"[ASSESS] After diet LLM ({time.time()-_t_llm:.1f}s) — RAM: {_ram()}")

    # ── Step 4: Generate workout plan ────────────────────────────────────────
    _t_workout = time.time()
    print(f"[ASSESS] Workout LLM start ({time.time()-_t0:.1f}s)")

    workout_structured = None
    workout_llm_result = _empty_llm
    try:
        workout_structured, workout_llm_result = await _generate_workout_plan(
            body, calc, workout_context, fitness_goal
        )
    except Exception as _wo_exc:
        _tb.print_exception(type(_wo_exc), _wo_exc, _wo_exc.__traceback__)
        print(f"[ASSESS] Workout LLM FAILED: {type(_wo_exc).__name__}: {_wo_exc}")

    del workout_context
    gc.collect()
    print(f"[ASSESS] After workout LLM ({time.time()-_t_workout:.1f}s) — RAM: {_ram()}")

    # ── Build response ───────────────────────────────────────────────────────
    diet_tokens    = diet_llm_result.get("tokens_used", 0)
    workout_tokens = workout_llm_result.get("tokens_used", 0)

    if diet_structured is None:
        print(f"[ASSESS] WARN: diet plan JSON parse failed — raw: "
              f"{diet_llm_result.get('reply','')[:300]}")
    if workout_structured is None:
        print(f"[ASSESS] WARN: workout plan JSON parse failed — raw: "
              f"{workout_llm_result.get('reply','')[:300]}")

    print(f"[ASSESS] Plans done ({time.time()-_t0:.1f}s total) — "
          f"diet_ok={diet_structured is not None}  "
          f"workout_ok={workout_structured is not None}  "
          f"total_tokens={diet_tokens + workout_tokens}  RAM: {_ram()}")

    # Deterministic (never LLM-generated) precautions + detected condition
    # labels, so the frontend can show "Today's Precautions" and a coach-mode
    # medical-condition callout regardless of what the LLM produced.
    med_directives = medcon.build_condition_directives(body.medical_conditions)

    return {
        "assessment":   assessment_result["assessment"],
        "calculations": calc,
        "swot":         assessment_result["swot"],
        "diet_plan":    diet_structured,
        "workout_plan": workout_structured,
        "sources":      all_sources,
        "precautions":                medcon.format_precautions(med_directives),
        "medical_conditions_detected": med_directives["labels"],
        # Full rules-engine output (severity, exercise/diet/recovery rules) so
        # the coach-side UI can render restrictions without re-deriving them.
        "medical_directives":          med_directives,
        "meta": {
            "diet_model":         diet_llm_result.get("model"),
            "workout_model":      workout_llm_result.get("model"),
            "total_tokens":       diet_tokens + workout_tokens,
            "rag_diet_chunks":    _n_diet_chunks,
            "rag_workout_chunks": _n_workout_chunks,
        },
    }
