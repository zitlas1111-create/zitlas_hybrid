"""
ZITLAS — Assessment Service (Production)
Pure-Python calculation and rule-based SWOT engine.
No LLM required — instant results, zero latency.

Inputs  → 15 user data points
Outputs → BMI, BMR, TDEE, calorie target, protein, water, steps
          + personalized SWOT with scores and archetype
"""

from __future__ import annotations

import re
from typing import Literal, Optional

from pydantic import BaseModel, Field, model_validator

from services import medical_conditions as medcon


# ══════════════════════════════════════════════════════════════════════════════
# INPUT MODEL
# ══════════════════════════════════════════════════════════════════════════════

ActivityLevel    = Literal["sedentary", "light", "moderate", "active", "very_active"]
Gender           = Literal["male", "female", "other"]
WorkoutPref      = Literal["home", "gym", "walking", "none"]
DietPref         = Literal["vegetarian", "non-vegetarian", "vegan", "eggetarian", "mixed"]
LivingSituation  = Literal["hostel", "home", "pg", "rented", "office"]
Occupation       = Literal["hostel_student", "college_student", "office_worker",
                            "freelancer", "homemaker", "other"]


class AssessmentInput(BaseModel):
    # Basic biometrics
    age:            int   = Field(..., ge=12, le=80)
    gender:         str   = Field(...)                  # male | female | other
    height_cm:      float = Field(..., ge=100, le=250)
    weight_kg:      float = Field(..., ge=30,  le=300)
    goal_weight_kg: Optional[float] = Field(default=None, ge=30, le=250)

    # Lifestyle
    activity_level:    str = Field(default="sedentary")
    occupation:        str = Field(default="other")
    living_situation:  str = Field(default="home")
    diet_preference:   str = Field(default="mixed")
    workout_preference: str = Field(default="home")

    # Wellness
    sleep_hours:   float = Field(default=7.0, ge=2, le=14)
    stress_level:  int   = Field(default=5,   ge=1, le=10)
    available_time: int  = Field(default=30,  ge=0, le=180,
                                 description="Minutes per day available for exercise")

    # Context
    budget:             str = Field(default="",   description="e.g. ₹100/day or 150 rupees")
    medical_conditions: str = Field(default="none")

    # Personalization (all optional — absent fields behave exactly as before)
    uses_supplements:   str  = Field(default="", description="'no' | 'yes' | '' (not asked)")
    supplement_types:   list = Field(default_factory=list, description="e.g. ['Whey Protein', 'Creatine'] when uses_supplements='yes'")
    disliked_exercises: list = Field(default_factory=list, description="exercise names the user repeatedly skips — never recommend")
    disliked_foods:     list = Field(default_factory=list, description="foods the user dislikes — never recommend")
    # A PREFERENCE, never a restriction: the food engine already treats
    # `favorite_foods` as a ranking bonus (food_engine._region_component /
    # _preference_component), so this biases the plan toward foods the
    # athlete enjoys without ever forcing every meal to become one of them.
    # Also personalises Creator Recipe search (routes/creator_recipes.py).
    favorite_foods:     list = Field(default_factory=list, description="stable food ids the user enjoys, e.g. ['pizza','burger'] — a preference, not a filter")
    workout_intensity_preference: str = Field(default="", description="light | moderate | intense | '' ")
    preferred_workout_time:       str = Field(default="", description="morning | evening | flexible | ''")

    # Geo-Aware Food Intelligence (optional — absent behaves exactly as
    # before). {city, district, state, country, pincode, latitude,
    # longitude, timezone} — every key optional, set by the frontend's
    # location-permission prompt. See services/location_food_engine.py.
    location: dict = Field(default_factory=dict)

    # Fitness goal type — controls which RAG knowledge base is used.
    fitness_goal: str = Field(
        default="weight_loss",
        description="weight_loss | muscle_gain | general_fitness | transformation",
    )

    # ── Fitness readiness (all optional — absent behaves exactly as before)
    # The system knew how ACTIVE somebody was and never how CAPABLE. Two
    # sedentary athletes are not the same athlete if one climbs three floors
    # easily and the other cannot, and only these answers tell them apart.
    # Empty string = not asked; services/fitness_stage.py treats it as no
    # signal rather than guessing in either direction.
    workout_experience: str = Field(default="", description="beginner | novice | intermediate | advanced — the athlete's own claim")
    stair_ability:      str = Field(default="", description="easy | okay | tired | difficult — three floors without stopping")
    walk_ability:       str = Field(default="", description="easy | okay | tired | difficult — 30 minutes comfortably")
    squat_ability:      str = Field(default="", description="easy | okay | tired | difficult — a few bodyweight squats")

    # General fitness only
    health_goals:  list  = Field(default_factory=list,  description="multi-select: energy, health, fitness, habits, mobility, endurance, strength, posture, reduce_stress, sleep")
    fitness_level: str   = Field(default="beginner",    description="beginner | intermediate | advanced")

    # Transformation only
    goal_duration_months: Optional[int] = Field(default=None, ge=1, le=24, description="Target transformation duration in months (1–24)")
    transformation_goal:  Optional[str] = Field(default=None, description="six_pack | lean_physique | recomposition | aesthetic")

    @model_validator(mode="after")
    def validate_goal_weight(self) -> "AssessmentInput":
        if self.fitness_goal in ("general_fitness", "transformation"):
            # No weight goal for these — default to current weight (maintenance/recomp)
            if self.goal_weight_kg is None:
                self.goal_weight_kg = self.weight_kg
            return self
        if self.goal_weight_kg is None:
            raise ValueError("goal_weight_kg is required for weight_loss and muscle_gain goals")
        if self.fitness_goal != "muscle_gain" and self.goal_weight_kg >= self.weight_kg:
            raise ValueError(
                "goal_weight_kg must be less than weight_kg for weight_loss goal"
            )
        return self


# ══════════════════════════════════════════════════════════════════════════════
# CALCULATIONS
# ══════════════════════════════════════════════════════════════════════════════

_BMI_CATEGORIES = [
    (18.5, "Underweight"),
    (25.0, "Normal Weight"),
    (30.0, "Overweight"),
    (35.0, "Obese Class I"),
    (40.0, "Obese Class II"),
    (999,  "Obese Class III"),
]

_ACTIVITY_MULTIPLIERS: dict[str, float] = {
    "sedentary":  1.20,
    "light":      1.375,
    "moderate":   1.55,
    "active":     1.725,
    "very_active": 1.90,
}

_SAFETY_FLOORS: dict[str, int] = {
    "male":   1400,
    "female": 1200,
    "other":  1300,
}


def calculate_bmi(weight_kg: float, height_cm: float) -> tuple[float, str]:
    """BMI and WHO category."""
    bmi = weight_kg / (height_cm / 100) ** 2
    category = next(
        label for threshold, label in _BMI_CATEGORIES if bmi < threshold
    )
    return round(bmi, 2), category


def calculate_bmr(
    weight_kg: float,
    height_cm: float,
    age: int,
    gender: str,
) -> float:
    """
    Basal Metabolic Rate — Mifflin-St Jeor equation.
    Male:   (10×W) + (6.25×H) - (5×A) + 5
    Female: (10×W) + (6.25×H) - (5×A) - 161
    Other:  average of both
    """
    base = (10 * weight_kg) + (6.25 * height_cm) - (5 * age)
    gender_lc = gender.lower()
    if gender_lc == "male":
        return base + 5
    if gender_lc == "female":
        return base - 161
    return base - 78   # midpoint between +5 and -161


def calculate_tdee(bmr: float, activity_level: str) -> float:
    """Total Daily Energy Expenditure = BMR × activity multiplier."""
    multiplier = _ACTIVITY_MULTIPLIERS.get(activity_level.lower(), 1.375)
    return bmr * multiplier


def calculate_weight_loss_calories(tdee: float, gender: str = "other") -> float:
    """
    Weight-loss calorie target: TDEE - 500 kcal deficit (≈ 0.5 kg/week).
    Capped at a safety floor (1200 kcal for females, 1400 for males).
    """
    floor  = _SAFETY_FLOORS.get(gender.lower(), 1300)
    target = tdee - 500
    return max(target, float(floor))


def calculate_muscle_gain_calories(tdee: float) -> float:
    """
    Muscle-gain calorie target: TDEE + 300 kcal lean-bulk surplus.
    +300 supports ~0.25 kg/week lean mass gain with minimal fat accumulation.
    """
    return tdee + 300


def calculate_protein_target(weight_kg: float, goal_weight_kg: float) -> float:
    """
    Protein target for weight loss: 2.0 g/kg of goal body weight.
    Minimum: 1.6 g/kg current weight to preserve lean mass during deficit.
    """
    from_goal    = goal_weight_kg * 2.0
    from_current = weight_kg * 1.6
    return max(from_goal, from_current)


def calculate_muscle_gain_protein(weight_kg: float, goal_weight_kg: float) -> float:
    """
    Protein target for muscle gain: 2.2 g/kg of goal body weight.
    Minimum: 2.0 g/kg current weight to maximise muscle protein synthesis.
    """
    from_goal    = goal_weight_kg * 2.2
    from_current = weight_kg * 2.0
    return max(from_goal, from_current)


def calculate_gf_protein(weight_kg: float) -> float:
    """General fitness protein: 1.6 g/kg current weight — maintains muscle and supports activity."""
    return weight_kg * 1.6


def calculate_water_target(weight_kg: float) -> float:
    """
    Water intake: 35 ml per kg body weight.
    Clamped to practical range: 2.0–4.0 L.
    """
    liters = (weight_kg * 35) / 1000
    return round(max(2.0, min(4.0, liters)), 1)


def calculate_daily_steps(activity_level: str, bmi: float) -> int:
    """
    Daily step goal:
    - Baseline by activity level
    - Extra 500 steps if BMI > 30 (movement especially beneficial for obese)
    """
    baseline = {
        "sedentary":   7_000,
        "light":       8_000,
        "moderate":    9_000,
        "active":     10_000,
        "very_active": 12_000,
    }.get(activity_level.lower(), 8_000)

    return baseline + (500 if bmi > 30 else 0)


def _parse_budget_inr(budget_str: str) -> int:
    """Extract a number from budget string like '₹150/day' → 150."""
    nums = re.findall(r"\d+", budget_str or "")
    return int(nums[0]) if nums else 0


def _has_medical_condition(medical_conditions: str) -> bool:
    """Return True if the user has a real medical condition (not 'none'/'nil'/'no')."""
    cleaned = (medical_conditions or "").strip().lower()
    return cleaned not in ("", "none", "no", "nil", "n/a", "na", "nothing")


# ══════════════════════════════════════════════════════════════════════════════
# SWOT ENGINE  (rule-based, deterministic, no LLM)
# ══════════════════════════════════════════════════════════════════════════════

def _item(title: str, detail: str) -> dict:
    return {"title": title, "detail": detail}


def _generate_swot_items(
    data: AssessmentInput,
    calc: dict,
) -> dict[str, list[dict]]:
    """
    Rule-based SWOT generation — branches on fitness_goal.
    Every item references the user's actual numbers — no generic text.
    """
    is_muscle         = data.fitness_goal == "muscle_gain"
    is_general        = data.fitness_goal == "general_fitness"
    is_transformation = data.fitness_goal == "transformation"

    S: list[dict] = []   # Strengths
    W: list[dict] = []   # Weaknesses
    O: list[dict] = []   # Opportunities
    T: list[dict] = []   # Threats

    bmi         = calc["bmi"]
    weight_gap  = calc["weight_to_lose_kg"]   # kg to lose (WL) or gain (MG) — always positive
    tdee        = calc["tdee_kcal"]
    target_cal  = calc["weight_loss_calories_kcal"]   # surplus for MG, deficit for WL
    protein_g   = calc["protein_target_g"]
    diet        = data.diet_preference.lower()
    living      = data.living_situation.lower()
    occ         = data.occupation.lower()
    budget_inr  = _parse_budget_inr(data.budget)
    has_medical = _has_medical_condition(data.medical_conditions)

    # ── BMI / Weight gap ─────────────────────────────────────────────────────
    if is_transformation:
        if bmi < 22.0:
            S.append(_item(
                "Low Body Fat Potential — Transformation Ready",
                f"Your BMI of {bmi:.1f} ({calc['bmi_category']}) gives you an excellent "
                "starting point for achieving a lean, aesthetic physique. "
                "Six pack visibility is primarily determined by body fat %, not scale weight."
            ))
        elif bmi < 26.0:
            O.append(_item(
                "Recomposition Sweet Spot",
                f"At BMI {bmi:.1f}, your body can simultaneously lose fat and build muscle "
                "(body recomposition) — the most efficient path to a visible six pack and "
                "lean physique. Expect results in 12–20 weeks with consistent effort."
            ))
        else:
            W.append(_item(
                "Body Fat Reduction Required First",
                f"At BMI {bmi:.1f}, some fat loss is needed before abs become visible. "
                "Abs are typically visible at 10–14% body fat for men and 16–20% for women. "
                "Your transformation plan combines a mild deficit with resistance training."
            ))
            T.append(_item(
                "Patience Required — Body Recomp Takes 16–24 Weeks",
                "Transformation is not linear. The first 4–6 weeks are habit and metabolic "
                "adaptation. Visible changes accelerate between weeks 8–16. "
                "Measure tape inches and progress photos — not just the scale."
            ))
        O.append(_item(
            "Transformation Visible in 12–16 Weeks",
            "With a structured plan combining calorie control, progressive resistance training, "
            "and adequate protein, visible transformation results appear in 12–16 weeks "
            "of consistent effort."
        ))
    elif is_general:
        if bmi < 25.0:
            S.append(_item(
                "Healthy BMI — Strong Fitness Foundation",
                f"Your BMI is {bmi:.1f} ({calc['bmi_category']}) — a great starting point. "
                "General fitness will build on this foundation with energy, strength, and mobility."
            ))
        elif bmi < 30.0:
            O.append(_item(
                "Fitness Improvements Naturally Improve Body Composition",
                f"At BMI {bmi:.1f}, consistent fitness habits — walking, strength, and recovery — "
                "naturally shift body composition without needing to focus on weight."
            ))
        else:
            W.append(_item(
                "High BMI — Low-Impact Starting Point",
                f"At BMI {bmi:.1f}, your plan starts with walking and mobility. "
                "This protects your joints while building an aerobic and strength base."
            ))
        O.append(_item(
            "Noticeable Results in 8–12 Weeks",
            "Consistent general fitness training produces measurable improvements in energy, "
            "sleep quality, and strength within 8–12 weeks — well before the scale moves much."
        ))
    elif is_muscle:
        if bmi < 25.0:
            S.append(_item(
                "Lean Starting Point — Ideal for Clean Bulk",
                f"Your BMI is {bmi:.1f} ({calc['bmi_category']}) — a lean frame means "
                f"the {weight_gap:.1f}kg you gain will be primarily muscle, not fat."
            ))
        elif bmi < 30.0:
            T.append(_item(
                "Slightly Overweight BMI — Keep the Surplus Lean",
                f"BMI {bmi:.1f} means some body fat is present. "
                f"A controlled +300 kcal surplus ({target_cal:.0f} kcal/day) limits fat gain "
                f"while building muscle over the next {calc['estimated_weeks_to_goal']} weeks."
            ))
        else:
            W.append(_item(
                "High BMI — Consider Recomposition First",
                f"At BMI {bmi:.1f}, a body recomposition approach (TDEE + very high protein) "
                "may work better than a full bulk. Resistance training at "
                f"{target_cal:.0f} kcal/day can add muscle while slowly reducing fat."
            ))
        if weight_gap > 15:
            T.append(_item(
                "Long Bulk — Patience Required",
                f"Gaining {weight_gap:.0f}kg of lean muscle takes 12–18+ months at natural rates. "
                "Track monthly strength gains and progress photos — the scale is a slow indicator."
            ))
            O.append(_item(
                "Beginner Gains — Fastest Progress Window",
                "In your first 6–12 months of consistent resistance training, your body gains muscle "
                "at 2–3× the rate it will later. This window is your biggest advantage — use it."
            ))
        elif weight_gap <= 10:
            S.append(_item(
                f"Achievable Goal — {weight_gap:.0f}kg to Target",
                f"At ~0.25kg/week lean muscle gain, you can reach your target in approximately "
                f"{calc['estimated_weeks_to_goal']} weeks with consistent training and nutrition."
            ))
    else:
        if bmi < 25.0:
            S.append(_item(
                "Healthy BMI — Cosmetic Goal",
                f"Your BMI is {bmi:.1f} ({calc['bmi_category']}) — this is a refinement "
                f"goal of {weight_gap:.1f}kg, not a medical necessity. "
                f"Progress will be visible fast."
            ))
        elif bmi < 30.0:
            W.append(_item(
                "Overweight BMI",
                f"BMI {bmi:.1f} puts you in the overweight range. A sustained 500 kcal "
                f"deficit ({target_cal:.0f} kcal/day) will move you to normal BMI "
                f"in roughly {calc['estimated_weeks_to_goal']} weeks."
            ))
        else:
            W.append(_item(
                "Obese BMI — High Priority",
                f"At BMI {bmi:.1f}, even a 20-min daily walk adds 150+ kcal burn. "
                f"Start small — {target_cal:.0f} kcal/day and 7,500 steps daily is enough "
                f"for strong early results."
            ))
            T.append(_item(
                "Weight-Loss Plateau After Week 8",
                "High-BMI journeys commonly stall after the first 8-10 kg. "
                "A diet break (maintenance for 1 week) every 8 weeks prevents this."
            ))
        if weight_gap > 20:
            T.append(_item(
                "Long Journey — Motivation Must Be Active",
                f"Losing {weight_gap:.0f}kg is a 12–18 month project. "
                "Celebrate every 5kg milestone with a non-food reward. "
                "Monthly progress photos are more motivating than the scale."
            ))
            O.append(_item(
                "Large Initial Drop From Water Weight",
                "The first 2–3 kg often drops in week 1–2 from glycogen and water. "
                "This early momentum is real and worth using."
            ))
        elif weight_gap <= 10:
            S.append(_item(
                f"Short Journey — {weight_gap:.0f}kg to Goal",
                f"At 0.5kg/week you'll reach your goal in approximately "
                f"{calc['estimated_weeks_to_goal']} weeks — a focused sprint, not a marathon."
            ))

    # ── Age ──────────────────────────────────────────────────────────────────
    if data.age < 25:
        S.append(_item(
            "Peak Metabolic Age",
            f"At {data.age}, your metabolism and muscle-building hormones "
            "(testosterone, GH, IGF-1) are at lifetime highs. "
            "Your body responds 20–30% faster to diet + exercise than it will at 35."
        ))
        O.append(_item(
            "Habits Formed Now Last a Lifetime",
            "Neurological habit grooves formed before age 25 are the most durable. "
            "Build the routine now — it will cost far less effort to maintain for decades."
        ))
    elif data.age >= 35:
        T.append(_item(
            "BMR Declining With Age",
            f"After 30, BMR drops ~2% per decade. At {data.age}, your "
            f"calculated BMR is {calc['bmr_kcal']} kcal — protein "
            f"({protein_g:.0f}g/day) becomes critical to slow muscle loss "
            "and maintain metabolic rate."
        ))

    # ── Sleep ─────────────────────────────────────────────────────────────────
    if data.sleep_hours >= 7.5:
        if is_transformation:
            S.append(_item(
                "Excellent Sleep — Transformation Accelerator",
                f"{data.sleep_hours:.0f} hours keeps cortisol low, GH high, and cravings "
                "suppressed — the trifecta for visible body transformation. "
                "Sleep is the single highest-leverage free transformation tool."
            ))
        elif is_general:
            S.append(_item(
                "Excellent Sleep — Fitness Recovery Optimized",
                f"{data.sleep_hours:.0f} hours supports full recovery, energy restoration, "
                "and growth hormone release. Good sleep is the #1 free fitness tool."
            ))
        elif is_muscle:
            S.append(_item(
                "Excellent Sleep — Optimal Muscle Recovery",
                f"{data.sleep_hours:.0f} hours triggers peak GH (growth hormone) release, "
                "which is essential for muscle protein synthesis. "
                "Your sleep quality is a direct advantage for muscle building."
            ))
        else:
            S.append(_item(
                "Excellent Sleep Foundation",
                f"{data.sleep_hours:.0f} hours keeps ghrelin (hunger hormone) low "
                "and leptin (fullness hormone) high — you'll experience fewer cravings "
                "than someone on 6 hours."
            ))
    elif data.sleep_hours >= 6.0:
        T.append(_item(
            "Sub-Optimal Sleep — Energy and Recovery Affected",
            f"At {data.sleep_hours:.0f}h/night you're above the danger zone but below optimal. "
            "Adding 30 min of sleep improves energy, mood, and workout performance more than "
            "any supplement."
        ))
    else:
        if is_transformation:
            W.append(_item(
                "Sleep Deprivation — Blocking Transformation",
                f"Only {data.sleep_hours:.0f}h per night raises cortisol, promotes visceral fat "
                "storage around the abdomen, and blocks GH release. "
                "Visible abs require low cortisol. No transformation plan works at full effect until sleep improves to 7–8h."
            ))
        elif is_general:
            W.append(_item(
                "Sleep Deprivation — Blocking Fitness Progress",
                f"Only {data.sleep_hours:.0f}h per night raises cortisol, reduces energy, "
                "and impairs exercise recovery. No fitness plan fully works until sleep improves to 7–8h."
            ))
        elif is_muscle:
            W.append(_item(
                "Sleep Deprivation — Blocking Muscle Growth",
                f"Only {data.sleep_hours:.0f}h per night severely limits GH and testosterone release. "
                "Muscle is built during sleep, not during workouts. "
                "No training programme fully works until sleep improves to 7–8h."
            ))
        else:
            W.append(_item(
                "Sleep Deprivation — Biggest Hidden Barrier",
                f"Only {data.sleep_hours:.0f}h per night raises cortisol, increases hunger "
                "by up to 24%, and directly promotes abdominal fat storage. "
                "No diet plan fully works until sleep improves."
            ))

    # ── Stress ────────────────────────────────────────────────────────────────
    if data.stress_level <= 3:
        if is_transformation:
            detail = (
                f"Stress at {data.stress_level}/10 means low cortisol — a critical advantage "
                "for body transformation. Low cortisol = less visceral fat, better fat mobilization, "
                "and higher GH release for muscle retention. Protect this environment."
            )
        elif is_general:
            detail = (
                f"Stress at {data.stress_level}/10 keeps cortisol low — supporting better energy, "
                "sleep, and fitness recovery. This is a significant advantage for consistent training."
            )
        elif is_muscle:
            detail = (
                f"Stress at {data.stress_level}/10 keeps cortisol low. "
                "Low cortisol = better testosterone ratio, faster muscle repair. Protect this advantage."
            )
        else:
            detail = (
                f"Stress at {data.stress_level}/10 keeps cortisol low. "
                "Low cortisol = less belly fat, fewer cravings, better recovery. Protect this advantage."
            )
        S.append(_item("Low-Stress Environment", detail))
    elif data.stress_level <= 6:
        T.append(_item(
            "Moderate Stress — Watch Energy and Recovery",
            f"At {data.stress_level}/10 stress, recovery between sessions may be slower. "
            "A 10-min mindfulness or breathing routine after workouts accelerates recovery."
        ))
    else:
        if is_transformation:
            W.append(_item(
                "High Stress — Cortisol Blocking Transformation",
                f"Stress level {data.stress_level}/10 elevates cortisol, which directly "
                "promotes visceral belly fat storage — the exact fat hiding your abs. "
                "Even perfect training and nutrition underperform until stress is managed. "
                "Stress management is a direct transformation intervention."
            ))
            T.append(_item(
                "Cortisol Belly Fat — The Transformation Blocker",
                "High cortisol preferentially stores fat in the abdominal region, making "
                "abs the last to appear. A 10-min mindfulness or breathing routine before "
                "bed is the #1 transformation intervention for high-stress individuals."
            ))
        elif is_general:
            W.append(_item(
                "High Stress — Blocking Energy and Recovery",
                f"Stress level {data.stress_level}/10 reduces workout recovery, lowers motivation, "
                "and impairs sleep quality. Stress reduction is a direct fitness intervention. "
                "Your plan includes recovery and mobility work to help manage this."
            ))
            T.append(_item(
                "Overtraining Risk Under High Stress",
                "High-stress individuals need more recovery days. "
                "Keep sessions to 30–40 min and prioritize sleep and mobility. "
                "A 10-min breathing routine before bed is the #1 performance intervention."
            ))
        elif is_muscle:
            W.append(_item(
                "High Stress — Cortisol Blocking Muscle Growth",
                f"Stress level {data.stress_level}/10 elevates cortisol, which suppresses "
                "testosterone and directly inhibits muscle protein synthesis. "
                "Even perfect nutrition and training underperform until stress is managed."
            ))
            T.append(_item(
                "Overtraining Risk Under High Stress",
                "High-stress individuals recover more slowly from resistance training. "
                "Keep sessions to 45 min max and ensure 48h rest between same-muscle groups. "
                "A 10-min breathing routine before bed is the #1 recovery intervention."
            ))
        else:
            W.append(_item(
                "High Stress — Cortisol Blocking Fat Loss",
                f"Stress level {data.stress_level}/10 elevates cortisol which directly "
                "promotes visceral fat storage. Even a perfect 1,500-kcal diet "
                "will underperform until stress is addressed."
            ))
            T.append(_item(
                "Binge-Eating Risk Under Stress",
                "High-stress individuals are 3× more likely to have binge episodes "
                "that can erase a week of deficit in one evening. "
                "A 10-min breathing routine before meals is the #1 intervention."
            ))

    # ── Activity level ────────────────────────────────────────────────────────
    al = data.activity_level.lower()
    if al in ("active", "very_active"):
        if is_transformation:
            S.append(_item(
                "High Activity — Rapid Transformation Potential",
                f"Your {al.replace('_', ' ')} lifestyle gives you a TDEE of {tdee:.0f} kcal. "
                "High activity means you can eat {target_cal:.0f} kcal/day, stay in a "
                "mild deficit, and still fuel resistance training — the perfect setup "
                "for visible body transformation without feeling starved."
            ))
        elif is_general:
            S.append(_item(
                "Active Lifestyle — Strong Fitness Foundation",
                f"Your {al.replace('_', ' ')} lifestyle gives you a TDEE of {tdee:.0f} kcal. "
                "You already have the movement habit — we'll build structure, variety, and "
                "intentional training on top of it."
            ))
        elif is_muscle:
            S.append(_item(
                "High Activity — Anabolic Foundation",
                f"Your {al.replace('_', ' ')} lifestyle gives you a TDEE of "
                f"{tdee:.0f} kcal — eating {target_cal:.0f} kcal/day creates "
                "a clean +300 kcal surplus for muscle building without excess fat gain."
            ))
        else:
            S.append(_item(
                "High TDEE — More Food Freedom",
                f"Your {al.replace('_', ' ')} lifestyle gives you a TDEE of "
                f"{tdee:.0f} kcal — you can eat {target_cal:.0f} kcal/day "
                "and still maintain a healthy 500 kcal deficit."
            ))
    elif al == "sedentary":
        if is_transformation:
            W.append(_item(
                "Sedentary Lifestyle — Transformation Requires Training",
                f"TDEE of {tdee:.0f} kcal. A sedentary lifestyle means limited fat burn "
                "between sessions. Resistance training 3–4×/week is mandatory for "
                "body recomposition — abs are built in the gym, revealed in the kitchen."
            ))
            O.append(_item(
                "Rapid Recomposition From Low Fitness Baseline",
                "Starting from sedentary, any resistance training creates an immediate "
                "body composition shift — muscle is gained and fat is lost simultaneously, "
                "producing visible transformation results faster than in trained individuals."
            ))
        elif is_general:
            W.append(_item(
                "Sedentary Starting Point — Walking Is Your First Tool",
                f"With a TDEE of {tdee:.0f} kcal, even 20 minutes of daily walking "
                "improves energy, sleep, and cardiovascular health within 2–3 weeks."
            ))
            O.append(_item(
                "Dramatic Fitness Gains from Low Baseline",
                "Going from sedentary to lightly active produces the largest relative fitness "
                "improvements — better energy, mood, and endurance in 4–6 weeks."
            ))
        elif is_muscle:
            W.append(_item(
                "Sedentary Lifestyle — Muscle Growth Requires Resistance",
                f"TDEE of {tdee:.0f} kcal, but calories alone won't build muscle. "
                "Resistance training is mandatory. Start with 3 sessions/week — "
                "compound movements (squats, push-ups, rows) for maximum anabolic stimulus."
            ))
            O.append(_item(
                "Beginner Gains From Any Resistance Training",
                "Starting from sedentary, even basic bodyweight training triggers "
                "significant muscle growth. Progressive bodyweight (push-ups → weighted "
                "push-ups) produces real hypertrophy without a gym."
            ))
        else:
            W.append(_item(
                "Sedentary Lifestyle — Low Calorie Ceiling",
                f"TDEE of {tdee:.0f} kcal means your weight-loss target is just "
                f"{target_cal:.0f} kcal — a tight budget. "
                "Every 30 min of walking adds ~120 kcal burn, giving you more food flexibility."
            ))
            O.append(_item(
                "Massive Gains From Tiny Movement Changes",
                "Going from fully sedentary to 'light' activity (20-min daily walk) "
                f"raises TDEE by ~350 kcal — equivalent to a full extra meal's worth "
                "of deficit without changing a single food."
            ))

    # ── Available time ────────────────────────────────────────────────────────
    if data.available_time >= 45:
        if is_general:
            S.append(_item(
                f"{data.available_time}-Minute Window — Balanced Fitness Protocol",
                f"With {data.available_time} min/day you can do a proper warm-up, "
                "main workout (cardio + strength or mobility), and cool-down — "
                "the ideal structure for sustainable general fitness."
            ))
        elif is_muscle:
            S.append(_item(
                f"{data.available_time}-Minute Window — Full Hypertrophy Protocol",
                f"With {data.available_time} min/day you can run a complete "
                "compound + isolation resistance session — enough for a full "
                "push/pull/legs split, the gold standard for muscle gain."
            ))
        else:
            S.append(_item(
                f"{data.available_time}-Minute Window — Full Protocol",
                f"With {data.available_time} min/day you can do a complete resistance + "
                "cardio session. This is the sweet spot for simultaneously "
                "burning fat and preserving muscle."
            ))
    elif data.available_time >= 20:
        if is_general:
            O.append(_item(
                "20-Minute Sessions Build Real Fitness",
                f"{data.available_time} minutes of purposeful training — walk + bodyweight or "
                "mobility + core — creates lasting fitness improvements when done consistently. "
                "Frequency beats duration."
            ))
        elif is_muscle:
            O.append(_item(
                "20-Minute Sessions Still Build Muscle",
                f"{data.available_time} minutes of heavy compound work (3 sets squats + "
                "3 sets rows + 3 sets press) is enough to stimulate hypertrophy — "
                "intensity matters more than duration."
            ))
        else:
            O.append(_item(
                "20-Minute HIIT Is Enough",
                f"{data.available_time} minutes of high-intensity circuit training "
                "burns 200–300 kcal and elevates metabolism for 12+ hours after — "
                "as effective as 45 min of steady cardio."
            ))
    else:
        if is_general:
            W.append(_item(
                "Very Limited Training Window",
                f"Only {data.available_time} min/day — focus on a single high-quality activity: "
                "a brisk walk, mobility routine, or short bodyweight circuit. "
                "10 intentional minutes daily beats zero."
            ))
        elif is_muscle:
            W.append(_item(
                "Very Limited Training Window",
                f"Only {data.available_time} min/day — focus on 2–3 heavy compound sets "
                "per session. Even 15 min of maximal-effort resistance work "
                "generates significant muscle protein synthesis."
            ))
        else:
            W.append(_item(
                "Very Limited Exercise Window",
                f"Only {data.available_time} min/day — diet controls 80% of weight loss "
                f"anyway. Focus on hitting {target_cal:.0f} kcal/day first; "
                "add a 10-min post-meal walk when possible."
            ))

    # ── Living situation ──────────────────────────────────────────────────────
    if living == "hostel":
        W.append(_item(
            "Hostel Canteen — Low Nutrition Control",
            "Canteen meals are typically high in refined oil and simple carbs. "
            f"Protein target ({protein_g:.0f}g/day) is hard to hit without "
            "supplements or smart ordering (extra dal, boiled eggs, curd)."
        ))
        O.append(_item(
            "Hostel = Blank Slate for New Habits",
            "Away from home food patterns, you can build a clean routine "
            "from scratch. No family pressure, no childhood food habits to fight."
        ))
    elif living in ("home",):
        S.append(_item(
            "Home Kitchen Access — Maximum Control",
            "Cooking at home lets you hit your exact calorie and protein targets. "
            f"A simple high-protein Indian meal (dal + egg + roti + salad) "
            f"costs <₹80 and delivers {protein_g // 4:.0f}g protein."
        ))

    # ── Occupation ────────────────────────────────────────────────────────────
    if occ in ("hostel_student", "college_student"):
        O.append(_item(
            "Fixed Class Schedule → Predictable Meal Windows",
            "Lecture timetables create natural meal timing anchors. "
            "Use breakfast before 9 AM, lunch 12–1 PM, dinner before 8 PM "
            "— this alone improves insulin sensitivity."
        ))
    elif occ == "office_worker":
        T.append(_item(
            "Desk Job — 7+ Hours Sitting",
            "Prolonged sitting reduces TDEE by 200–300 kcal vs an active day. "
            "Set a phone timer to stand and walk 2 min every 45 min "
            "— it adds 100+ kcal burn over the day."
        ))

    # ── Diet preference ───────────────────────────────────────────────────────
    is_veg = any(v in diet for v in ("vegetarian", "vegan", "eggetarian"))
    if is_veg:
        if is_muscle:
            S.append(_item(
                "Plant-Based Diet — High-Volume Eating",
                "Vegetarian diets allow large food volumes at relatively low calorie density, "
                "making it easy to stay satisfied on a surplus. "
                f"Hitting {target_cal:.0f} kcal/day with clean plant foods is achievable."
            ))
        else:
            S.append(_item(
                "Plant-Based Diet — Natural Calorie Density Advantage",
                "Vegetarian diets typically carry 20–30% fewer calories per gram "
                "of food. You can eat larger volumes and stay within "
                f"{target_cal:.0f} kcal easily."
            ))
        O.append(_item(
            f"Dal + Sprouts + Paneer = {protein_g:.0f}g Protein Stack",
            f"Hitting {protein_g:.0f}g protein daily is achievable: "
            "1 cup dal (18g) + 100g paneer (18g) + curd (10g) + "
            "sprouts (10g) + soya chunks (20g) = 76g before any other meal."
        ))
    else:
        S.append(_item(
            "Non-Veg Protein — Cost-Effective Target",
            f"Chicken breast (31g/100g, ~₹30) and eggs (6g each, ~₹8) "
            f"make hitting your {protein_g:.0f}g target both easy and affordable."
        ))

    # ── Budget ────────────────────────────────────────────────────────────────
    if budget_inr and budget_inr < 60:
        W.append(_item(
            "Very Low Budget — Cheap Calories Risk",
            f"₹{budget_inr}/day limits quality food options. "
            "Prioritize eggs, dal, and moong sprouts — "
            "the cheapest per-gram-protein foods available."
        ))
    elif budget_inr and budget_inr >= 150:
        S.append(_item(
            "Good Budget — No Compromises Needed",
            f"₹{budget_inr}/day covers 3 high-protein meals comfortably. "
            "You have access to paneer, chicken, curd, and fresh vegetables "
            "without sacrificing quality."
        ))

    # ── Medical conditions ────────────────────────────────────────────────────
    # Driven by the same modular rules engine that injects diet/exercise
    # directives into plan generation, so the SWOT reflects the SAME
    # condition-specific guidance the athlete's actual plan follows —
    # not a generic one-liner disconnected from the rest of the plan.
    if has_medical:
        med_directives = medcon.build_condition_directives(data.medical_conditions)
        cond_label = ", ".join(med_directives["labels"]) or data.medical_conditions
        sample_exercise_rule = med_directives["exercise_rules"][0] if med_directives["exercise_rules"] else None
        sample_diet_rule     = med_directives["diet_rules"][0] if med_directives["diet_rules"] else None

        W.append(_item(
            f"Medical Condition Requires Adjusted Approach — {cond_label}",
            (sample_exercise_rule or
             f"Your condition ({cond_label}) may affect metabolism, hormone levels, or safe exercise intensity.") +
            " Follow your doctor's guidance alongside this plan — "
            "progress may be 30–50% slower, and that is completely normal."
        ))
        if sample_diet_rule:
            O.append(_item(
                f"Diet Adapted for {cond_label}",
                f"{sample_diet_rule} This works alongside your calorie and protein targets, not instead of them."
            ))
        if is_muscle:
            T.append(_item(
                "Condition May Affect Muscle Building Rate",
                "Hormonal conditions (hypothyroidism, insulin resistance) reduce "
                "the anabolic response to training. Track strength gains monthly — "
                "progressive overload is the signal the plan is working."
            ))
        else:
            T.append(_item(
                "Medication or Condition May Affect Fat Loss Rate",
                "PCOS, hypothyroidism, and insulin resistance all reduce the "
                "calorie-deficit response. Track weight weekly, not daily — "
                "and expect non-linear progress."
            ))

    # Ensure minimum items per quadrant
    if not S:
        S.append(_item("Committed to Change", "Taking this assessment is the first step — motivation converts to results when paired with a structured plan."))
    if not W:
        if is_transformation:
            W.append(_item("Consistency Risk", "Transformation requires 12–20 weeks of near-daily consistency. Missing sessions or under-eating protein slows visible progress significantly."))
        elif is_general:
            W.append(_item("Consistency Risk", "General fitness requires showing up 3–5 times per week. Progress is invisible in any single session but unmistakable over 8 weeks."))
        elif is_muscle:
            W.append(_item("Consistency Risk", "Muscle gain requires months of consistent training and nutrition. Missing sessions or under-eating protein slows progress significantly."))
        else:
            W.append(_item("Consistency Risk", "Most weight-loss journeys stall not from bad plans but from missed weeks. Build non-negotiable anchor habits."))
    if not O:
        if is_transformation:
            O.append(_item("Body Recomposition Window", "Your transformation plan triggers simultaneous fat loss and muscle gain. Every week of consistent effort shifts body composition even when the scale barely moves."))
        elif is_general:
            O.append(_item("Compound Effect of Consistent Habits", "Three fitness sessions per week for 12 weeks = 36 training sessions. The energy, strength, and health improvements compound dramatically over this window."))
        elif is_muscle:
            O.append(_item("Progressive Overload = Guaranteed Progress", "Add 1 rep or 1 kg to each exercise every 1–2 weeks. This mechanical tension is the primary driver of muscle growth — more important than any supplement."))
        else:
            O.append(_item("Every Habit Has Compound Interest", "One extra 20-min walk per day = 12,000 extra kcal burned per year = 1.7kg of fat loss on top of your deficit."))
    if not T:
        if is_transformation:
            T.append(_item("Under-Eating Protein Kills Transformation", f"Hitting {protein_g:.0f}g protein every day is non-negotiable. Low protein = muscle loss + fat storage = the opposite of transformation."))
        elif is_general:
            T.append(_item("Skipping Recovery Days Causes Burnout", "Over-training without rest days reduces energy, motivation, and results. Your plan has built-in rest and active recovery days — honour them."))
        elif is_muscle:
            T.append(_item("Under-Eating Protein Stalls Gains", f"Hitting {protein_g:.0f}g protein every day is non-negotiable. A consistent shortfall stalls hypertrophy completely regardless of training effort."))
        else:
            T.append(_item("Weekend Calorie Drift", "Research shows weekend eating adds 400–800 kcal above weekday average. Plan 1 flexible meal, not 2 free days."))

    return {
        "strengths":     S[:5],
        "weaknesses":    W[:4],
        "opportunities": O[:4],
        "threats":       T[:4],
    }


def _calculate_scores(data: AssessmentInput, calc: dict) -> dict:
    """
    Score each wellness dimension (0–100).
    Scores reflect current state, not potential — lower = more room to improve.
    """
    al      = data.activity_level.lower()
    diet    = data.diet_preference.lower()
    budget  = _parse_budget_inr(data.budget)
    has_med = _has_medical_condition(data.medical_conditions)

    # Nutrition (diet quality, budget, living situation)
    nutrition = 55
    if any(v in diet for v in ("vegetarian", "vegan")):
        nutrition += 10
    if budget >= 150:
        nutrition += 10
    elif budget < 60 and budget > 0:
        nutrition -= 15
    if data.living_situation.lower() == "hostel":
        nutrition -= 10
    if has_med:
        nutrition -= 8
    nutrition = max(20, min(95, nutrition))

    # Activity (movement and exercise behavior)
    activity = {"sedentary": 20, "light": 40, "moderate": 60,
                 "active": 80, "very_active": 95}.get(al, 40)
    if data.workout_preference.lower() == "none":
        activity = max(10, activity - 15)
    if data.available_time >= 45:
        activity = min(95, activity + 5)
    activity = max(10, min(95, activity))

    # Sleep
    if data.sleep_hours >= 8:
        sleep = 90
    elif data.sleep_hours >= 7:
        sleep = 75
    elif data.sleep_hours >= 6:
        sleep = 50
    else:
        sleep = 25

    # Habits (proxy for consistency and routine stability)
    habits = 50
    if data.sleep_hours >= 7:
        habits += 10
    if data.stress_level <= 4:
        habits += 15
    elif data.stress_level >= 7:
        habits -= 15
    if data.occupation.lower() in ("hostel_student", "college_student"):
        habits += 5   # fixed schedules help
    habits = max(20, min(90, habits))

    # Mindset (stress, available_time → mental bandwidth)
    mindset = 65
    mindset -= (data.stress_level - 5) * 5
    if data.available_time >= 30:
        mindset += 8
    mindset = max(20, min(95, mindset))

    # Consistency (lifestyle stability factors)
    consistency = 55
    if data.occupation.lower() in ("hostel_student", "college_student"):
        consistency += 8
    if data.living_situation.lower() == "hostel":
        consistency -= 5
    if data.stress_level <= 4:
        consistency += 10
    elif data.stress_level >= 7:
        consistency -= 10
    consistency = max(20, min(90, consistency))

    overall = round(
        (nutrition + activity + sleep + habits + mindset + consistency) / 6
    )

    return {
        "nutrition":   nutrition,
        "activity":    activity,
        "sleep":       sleep,
        "habits":      habits,
        "mindset":     mindset,
        "consistency": consistency,
        "overall":     overall,
    }


def _determine_archetype(data: AssessmentInput, scores: dict) -> str:
    """Assign the closest user archetype based on lifestyle signals and goal."""
    is_muscle         = data.fitness_goal == "muscle_gain"
    is_general        = data.fitness_goal == "general_fitness"
    is_transformation = data.fitness_goal == "transformation"
    al  = data.activity_level.lower()
    occ = data.occupation.lower()
    liv = data.living_situation.lower()

    if is_transformation:
        if liv == "hostel":
            return "Hostel Transformer"
        if occ == "office_worker" and data.stress_level >= 5:
            return "Busy Professional Transformer"
        if al in ("active", "very_active"):
            return "Active Body Recomposer"
        if data.age < 23 and occ in ("college_student", "student"):
            return "College Transformation Seeker"
        bmi_val, _ = calculate_bmi(data.weight_kg, data.height_cm)
        if bmi_val < 22.0:
            return "Lean Physique Achiever"
        if scores.get("consistency", 50) >= 65:
            return "Consistent Transformer"
        return "Motivated Transformer"
    elif is_general:
        if liv == "hostel":
            return "Campus Fitness Seeker"
        if occ == "office_worker" and data.stress_level >= 5:
            return "Busy Professional Health Builder"
        if al in ("active", "very_active"):
            return "Active Lifestyle Optimizer"
        if data.age < 23:
            return "Young Fitness Enthusiast"
        if getattr(data, 'fitness_level', 'beginner') == "advanced":
            return "Experienced Fitness Enthusiast"
        if scores.get("consistency", 50) >= 65:
            return "Consistent Lifestyle Builder"
        return "General Fitness Beginner"
    elif is_muscle:
        if liv == "hostel":
            return "Hostel Builder"
        if occ == "office_worker" and data.stress_level >= 5:
            return "Busy Lifter"
        if al in ("active", "very_active"):
            return "Active Builder"
        if data.age < 23 and occ == "college_student":
            return "College Lifter"
        gap = data.goal_weight_kg - data.weight_kg
        if gap > 15:
            return "Long-Game Gainer"
        if scores.get("consistency", 50) >= 65:
            return "Consistent Builder"
        return "Motivated Gainer"
    else:
        gap = data.weight_kg - data.goal_weight_kg
        if liv == "hostel":
            return "Hostel Dieter"
        if occ == "office_worker" and data.stress_level >= 5:
            return "Busy Professional"
        if al in ("active", "very_active"):
            return "Active Loser"
        if data.age < 23 and occ == "college_student":
            return "College Challenger"
        if scores.get("mindset", 50) >= 75:
            return "Mindful Eater"
        if gap > 20:
            return "Plateau Fighter"
        if scores.get("consistency", 50) >= 65:
            return "Habit Builder"
        return "Motivated Beginner"


def _priority_action(data: AssessmentInput, calc: dict, scores: dict) -> str:
    """Single most impactful action based on the weakest dimension and goal."""
    is_muscle         = data.fitness_goal == "muscle_gain"
    is_general        = data.fitness_goal == "general_fitness"
    is_transformation = data.fitness_goal == "transformation"
    lowest_dim = min(scores, key=lambda k: scores[k] if k != "overall" else 999)

    if data.sleep_hours < 6 or lowest_dim == "sleep":
        if is_transformation:
            return (
                "Tonight: set a fixed 7–8h sleep window — low cortisol during sleep "
                "is the #1 prerequisite for visible abs. High cortisol from poor sleep "
                "stores fat directly around the abdomen. Sleep more to transform faster."
            )
        elif is_general:
            return (
                "Tonight: set a fixed 7–8h sleep window — sleep is the #1 free fitness "
                "tool. Better sleep means more energy for workouts, faster recovery, and "
                "better results from every session."
            )
        elif is_muscle:
            return (
                "Tonight: set a fixed 7–8h sleep window — growth hormone is released "
                "during deep sleep and is the most powerful muscle-building signal. "
                "No supplement comes close to its effect."
            )
        return (
            "Tonight: set a fixed sleep alarm — even 30 extra minutes of sleep "
            "reduces hunger hormones more effectively than any supplement."
        )
    if lowest_dim == "activity" or data.activity_level == "sedentary":
        if is_transformation:
            return (
                "This week: start your first resistance session — 3 sets of compound lifts "
                "(push-ups, squats, rows, plank) creates the body recomposition stimulus. "
                "Resistance training 4×/week paired with a mild deficit is the fastest path "
                "to a lean, aesthetic physique."
            )
        elif is_general:
            return (
                "Tomorrow morning: start with a 20-minute brisk walk. "
                "This single habit — done consistently every day — "
                "improves energy, sleep, mood, and cardiovascular health within 2 weeks."
            )
        elif is_muscle:
            return (
                "This week: start your first resistance session — 3 sets each of push-ups, "
                "squats, and rows creates an anabolic stimulus. "
                "Progressive resistance 3×/week is the minimum effective dose for muscle gain."
            )
        return (
            f"Tomorrow morning: a 20-minute brisk walk creates a 150–200 kcal deficit — "
            f"enough to lose 0.25 kg/month before changing a single meal."
        )
    if lowest_dim == "mindset" or data.stress_level >= 7:
        if is_transformation:
            return (
                "This week: add one 10-minute breathing or mindfulness session before bed — "
                "high cortisol is the #1 enemy of visible abs. Cortisol stores belly fat. "
                "Stress reduction is a direct body transformation intervention."
            )
        elif is_general:
            return (
                "This week: add one 10-minute breathing or stretching session after your workout — "
                "stress reduction directly improves workout recovery, energy, and sleep quality."
            )
        elif is_muscle:
            return (
                "This week: add one 10-minute breathing or journaling session before bed — "
                "cortisol suppresses testosterone and blocks muscle protein synthesis. "
                "Stress management is a direct muscle-gain intervention."
            )
        return (
            "This week: add one 10-minute breathing or journaling session before bed — "
            "stress reduction is a direct fat-loss intervention, not optional."
        )
    if is_transformation:
        return (
            f"Starting today: hit {calc['weight_loss_calories_kcal']:.0f} kcal "
            f"with {calc['protein_target_g']:.0f}g protein and complete your resistance "
            "training session — body transformation happens when nutrition + training + "
            "recovery all align consistently. This is your daily non-negotiable."
        )
    if is_general:
        return (
            f"Starting today: follow your workout plan 3–5 days this week and hit "
            f"{calc['protein_target_g']:.0f}g protein daily — "
            "consistent training + adequate protein is the foundation of all fitness improvements."
        )
    if is_muscle:
        return (
            f"Starting today: hit exactly {calc['weight_loss_calories_kcal']:.0f} kcal "
            f"with {calc['protein_target_g']:.0f}g protein every day — "
            "muscle gain stalls within days of under-eating protein, "
            "so hitting this target consistently is non-negotiable."
        )
    return (
        f"Starting today: log every meal and aim for exactly "
        f"{calc['weight_loss_calories_kcal']:.0f} kcal with "
        f"{calc['protein_target_g']:.0f}g protein — "
        "consistent tracking for 7 days is the single fastest way to accelerate results."
    )


def generate_swot(data: AssessmentInput, calc: dict) -> dict:
    """
    Rule-based, data-driven SWOT + scoring.

    Returns:
        {swot, scores, user_archetype, summary, priority_action}
    """
    swot_items = _generate_swot_items(data, calc)
    scores     = _calculate_scores(data, calc)
    archetype  = _determine_archetype(data, scores)
    action     = _priority_action(data, calc, scores)

    is_muscle         = data.fitness_goal == "muscle_gain"
    is_general        = data.fitness_goal == "general_fitness"
    is_transformation = data.fitness_goal == "transformation"
    gap = calc["weight_to_lose_kg"]
    if is_transformation:
        health_goals_str = ", ".join(getattr(data, 'health_goals', []) or ['six pack', 'lean physique'])
        summary = (
            f"You are a {data.age}-year-old {data.gender} on a body transformation journey. "
            f"Your target: six pack abs, lean physique, and body recomposition. "
            f"Your maintenance calories are {calc['weight_loss_calories_kcal']:.0f} kcal/day "
            f"with a protein target of {calc['protein_target_g']:.0f}g/day. "
            f"Expect visible transformation results in 12–16 weeks of consistent effort. "
            f"Your strongest asset is {swot_items['strengths'][0]['title'].lower()}, "
            f"and your primary challenge is {swot_items['weaknesses'][0]['title'].lower()}."
        )
    elif is_general:
        health_goals_str = ", ".join(getattr(data, 'health_goals', []) or ['general fitness'])
        summary = (
            f"You are a {data.age}-year-old {data.gender} on a general fitness journey — "
            f"your goals are: {health_goals_str}. "
            f"Your maintenance calories are {calc['weight_loss_calories_kcal']:.0f} kcal/day "
            f"with a protein target of {calc['protein_target_g']:.0f}g/day. "
            f"Expect noticeable improvements in energy and fitness within 8–12 weeks. "
            f"Your strongest asset is {swot_items['strengths'][0]['title'].lower()}, "
            f"and your primary challenge is {swot_items['weaknesses'][0]['title'].lower()}."
        )
    elif is_muscle:
        rate_label = "0.25 kg/week lean muscle gain"
        cal_label  = "+300 kcal lean-bulk surplus"
        summary = (
            f"You are a {data.age}-year-old {data.gender} currently at {data.weight_kg}kg, "
            f"targeting {data.goal_weight_kg}kg — a {gap:.1f}kg muscle-gain journey "
            f"(~{calc['estimated_weeks_to_goal']} weeks at {rate_label}). "
            f"Your daily target is {calc['weight_loss_calories_kcal']:.0f} kcal "
            f"({cal_label}) with {calc['protein_target_g']:.0f}g protein. "
            f"Your strongest asset is {swot_items['strengths'][0]['title'].lower()}, "
            f"and your primary challenge is {swot_items['weaknesses'][0]['title'].lower()}."
        )
    else:
        rate_label = "0.5 kg/week"
        cal_label  = "500 kcal deficit"
        summary = (
            f"You are a {data.age}-year-old {data.gender} currently at {data.weight_kg}kg, "
            f"targeting {data.goal_weight_kg}kg — a {gap:.1f}kg weight-loss journey "
            f"(~{calc['estimated_weeks_to_goal']} weeks at {rate_label}). "
            f"Your daily target is {calc['weight_loss_calories_kcal']:.0f} kcal "
            f"({cal_label}) with {calc['protein_target_g']:.0f}g protein. "
            f"Your strongest asset is {swot_items['strengths'][0]['title'].lower()}, "
            f"and your primary challenge is {swot_items['weaknesses'][0]['title'].lower()}."
        )

    return {
        "swot":            swot_items,
        "scores":          scores,
        "user_archetype":  archetype,
        "summary":         summary,
        "priority_action": action,
    }


# ══════════════════════════════════════════════════════════════════════════════
# ORCHESTRATOR
# ══════════════════════════════════════════════════════════════════════════════

def run_assessment(data: AssessmentInput) -> dict:
    """
    Main entry point — runs all calculations and SWOT generation.

    Returns:
        {
            "assessment":   dict,   # validated input fields
            "calculations": dict,   # BMI, BMR, TDEE, targets
            "swot":         dict,   # items, scores, archetype, summary, action
        }
    """
    is_muscle         = data.fitness_goal == "muscle_gain"
    is_general        = data.fitness_goal == "general_fitness"
    is_transformation = data.fitness_goal == "transformation"

    bmi, bmi_cat = calculate_bmi(data.weight_kg, data.height_cm)
    bmr          = calculate_bmr(data.weight_kg, data.height_cm, data.age, data.gender)
    tdee         = calculate_tdee(bmr, data.activity_level)
    water        = calculate_water_target(data.weight_kg)
    steps        = calculate_daily_steps(data.activity_level, bmi)

    if is_transformation:
        # Mild deficit (300 kcal) to support recomposition while preserving muscle
        target_cal = max(calculate_weight_loss_calories(tdee, data.gender) + 200, tdee - 300)
        protein    = calculate_muscle_gain_protein(data.weight_kg, data.weight_kg)  # 2.2g/kg
        weight_gap = 0.0      # recomposition — scale barely moves
        weeks      = 16       # standard transformation window
        print(f"[TRANSFORMATION CALC]")
        print(f"BMR = {round(bmr)} kcal")
        print(f"TDEE = {round(tdee)} kcal")
        print(f"Recomp Target = {round(target_cal)} kcal  (-300 deficit)")
        print(f"Protein = {round(protein)} g/day  (2.2g/kg for recomposition)")
    elif is_general:
        target_cal = tdee           # maintenance calories
        protein    = calculate_gf_protein(data.weight_kg)
        weight_gap = 0.0            # no weight goal
        weeks      = 0              # no timeline — 8–12 weeks is the standard estimate
        print(f"[GENERAL FITNESS CALC]")
        print(f"BMR = {round(bmr)} kcal")
        print(f"TDEE = {round(tdee)} kcal  (maintenance)")
        print(f"Protein = {round(protein)} g/day")
        print(f"Fitness Level = {getattr(data, 'fitness_level', 'beginner')}")
    elif is_muscle:
        target_cal = calculate_muscle_gain_calories(tdee)
        protein    = calculate_muscle_gain_protein(data.weight_kg, data.goal_weight_kg)
        surplus    = round(target_cal - tdee)
        print(f"[MUSCLE GAIN CALC]")
        print(f"BMR = {round(bmr)} kcal")
        print(f"TDEE = {round(tdee)} kcal")
        print(f"Surplus = +{surplus} kcal")
        print(f"Target Calories = {round(target_cal)} kcal")
        # Lean bulk: ~0.25 kg/week of muscle gain
        weight_gap = data.goal_weight_kg - data.weight_kg   # positive = kg to gain
        weeks      = round(weight_gap / 0.25)
    else:
        target_cal = calculate_weight_loss_calories(tdee, data.gender)
        protein    = calculate_protein_target(data.weight_kg, data.goal_weight_kg)
        # Weight loss: ~0.5 kg/week deficit
        weight_gap = data.weight_kg - data.goal_weight_kg   # positive = kg to lose
        weeks      = round(weight_gap / 0.5)

    calculations = {
        "bmi":                        round(bmi, 1),
        "bmi_category":               bmi_cat,
        "bmr_kcal":                   round(bmr),
        "tdee_kcal":                  round(tdee),
        "weight_loss_calories_kcal":  round(target_cal),    # holds surplus for muscle gain
        "calorie_deficit_kcal":       round(abs(tdee - target_cal)),  # always positive magnitude
        "protein_target_g":           round(protein),
        "water_target_liters":        water,
        "daily_steps_goal":           steps,
        "weight_to_lose_kg":          round(weight_gap, 1), # kg to lose (WL) or gain (MG)
        "estimated_weeks_to_goal":    weeks,
        "estimated_months_to_goal":   round(weeks / 4.33, 1),
    }

    swot = generate_swot(data, calculations)

    return {
        "assessment":   data.model_dump(),
        "calculations": calculations,
        "swot":         swot,
    }
