"""
ZITLAS — Medical Condition Rules Engine (backend/services/medical_conditions.py)

Medical conditions were previously mentioned ONLY inside the SWOT — diet,
workout, calories, and recommendations were generated identically to a
healthy user. This module makes a reported condition a first-priority input
to plan generation: each condition carries exercise/diet/warning/recovery/
progression rules that get injected into the diet and workout LLM prompts
(see routes/assessment.py::_generate_diet_plan / _generate_workout_plan) and
surfaced deterministically as "Today's Precautions" — precaution text is
never LLM-generated, so it can't vary in reliability between calls.

The input field (AssessmentInput.medical_conditions) is free text, not an
enum, so detection is keyword-based. Unrecognized-but-present conditions
fall back to a conservative generic rule set rather than being silently
ignored — see build_condition_directives().

Modular by design: add a new condition by adding one dict entry below.
Nothing else needs to change.
"""

from __future__ import annotations

from typing import Any

# ══════════════════════════════════════════════════════════════════════════════
# CONDITION → RULES
# ══════════════════════════════════════════════════════════════════════════════

CONDITION_RULES: dict[str, dict[str, Any]] = {
    "asthma": {
        "label": "Asthma",
        "keywords": ["asthma", "asthmatic", "wheez"],
        "exercise_rules": [
            "Use a longer, low-impact warm-up (8-10 minutes) before any cardio or strength work.",
            "Extend cool-down to 8-10 minutes and end every session with breathing exercises (pursed-lip or diaphragmatic breathing).",
            "Favor steady-state, moderate-intensity cardio over high-intensity intervals; cap intensity spikes.",
            "Recommend indoor workouts over outdoor sessions, especially in cold, humid, or high-pollen conditions.",
            "Avoid exercises requiring breath-holding or maximal-effort bursts (e.g. all-out sprints) without medical clearance.",
        ],
        "diet_rules": [
            "Prioritize anti-inflammatory foods: turmeric, ginger, leafy greens, berries.",
            "Include Vitamin C-rich foods (citrus fruits, amla, bell peppers) to support respiratory health.",
            "Include Omega-3 sources (flaxseeds, walnuts, chia seeds, fatty fish if non-vegetarian).",
            "Include Magnesium-rich foods (spinach, almonds, pumpkin seeds, bananas).",
            "Limit heavily processed and fried foods, which can increase systemic inflammation.",
            "Emphasize consistent hydration throughout the day to keep airways moist.",
        ],
        "warning_rules": [
            "Carry your prescribed inhaler during workouts if you have one.",
            "Avoid outdoor training when air quality or pollen levels are poor.",
            "Stop immediately and rest if wheezing, chest tightness, or breathlessness occurs.",
            "Perform breathing exercises after every cardio session.",
        ],
        "recovery_rules": [
            "Allow an extra rest day if any respiratory symptoms appear during the week.",
            "Prioritize 7-9 hours of sleep — poor sleep can worsen airway sensitivity.",
        ],
        "progression_rules": [
            "Increase workout intensity or duration by no more than ~10% per week.",
            "Re-baseline intensity after any flare-up rather than resuming at the prior level.",
        ],
    },
    "diabetes": {
        "label": "Diabetes",
        "keywords": ["diabet", "sugar patient", "high sugar", "blood sugar"],
        "exercise_rules": [
            "Favor a mix of moderate cardio and resistance training — both improve insulin sensitivity.",
            "Schedule workouts at consistent times relative to meals to avoid blood sugar swings.",
            "Avoid very long fasted high-intensity sessions; moderate intensity is safer for blood sugar stability.",
            "Include a 5-10 minute warm-up and cool-down to avoid sudden glucose/heart-rate shifts.",
        ],
        "diet_rules": [
            "Prioritize low-glycemic-index carbohydrates (whole grains, legumes, non-starchy vegetables).",
            "Distribute carbohydrates evenly across meals rather than large single servings.",
            "Include fiber-rich foods at every meal to slow glucose absorption.",
            "Limit refined sugar, sweetened beverages, and heavily processed carbohydrates.",
            "Pair carbohydrates with protein or healthy fats to blunt blood sugar spikes.",
        ],
        "warning_rules": [
            "Keep a fast-acting carbohydrate source nearby during workouts in case of low blood sugar.",
            "Check blood sugar before and after exercise if advised by your doctor.",
            "Stop and refuel immediately if you feel shaky, dizzy, or unusually fatigued.",
            "Stay well hydrated — dehydration can affect blood sugar readings.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep timing — irregular sleep affects insulin sensitivity.",
            "Avoid stacking multiple high-intensity days back to back.",
        ],
        "progression_rules": [
            "Increase intensity gradually and monitor how blood sugar responds before progressing further.",
        ],
    },
    "hypertension": {
        "label": "Hypertension (High Blood Pressure)",
        "keywords": ["hypertension", "high blood pressure", "high bp", "bp problem", "b.p."],
        "exercise_rules": [
            "Favor moderate-intensity steady-state cardio over maximal-effort or heavy-straining lifts.",
            "Avoid holding your breath during resistance exercises (Valsalva maneuver) — breathe continuously.",
            "Avoid sudden, explosive maximal-effort movements; build intensity gradually within a session.",
            "Include a longer warm-up and cool-down to avoid sharp blood-pressure spikes or drops.",
        ],
        "diet_rules": [
            "Reduce sodium intake — limit processed, packaged, and restaurant food.",
            "Prioritize potassium-rich foods (bananas, spinach, sweet potatoes, coconut water).",
            "Emphasize whole foods: vegetables, fruits, whole grains, and lean protein (DASH-style pattern).",
            "Limit caffeine and alcohol, which can temporarily raise blood pressure.",
        ],
        "warning_rules": [
            "Stop exercising and rest if you feel dizzy, get a headache, or notice blurred vision.",
            "Avoid very hot environments (saunas, hot outdoor workouts) which can affect blood pressure.",
            "Take prescribed blood-pressure medication as directed — do not skip doses around workouts.",
        ],
        "recovery_rules": [
            "Prioritize stress-reduction practices (breathing, light stretching) alongside physical recovery.",
        ],
        "progression_rules": [
            "Progress intensity slowly; avoid sudden jumps in weight lifted or cardio intensity.",
        ],
    },
    "hypothyroidism": {
        "label": "Hypothyroidism (Underactive Thyroid)",
        "keywords": ["hypothyroid", "underactive thyroid", "low thyroid"],
        "exercise_rules": [
            "Expect slower recovery and energy levels — plan moderate volume rather than high-frequency intense sessions.",
            "Include strength training to help offset thyroid-related muscle loss and slow metabolism.",
            "Build in slightly longer rest between sets if fatigue is noticeable.",
        ],
        "diet_rules": [
            "Include iodine-appropriate whole foods (as advised by a doctor) and selenium-rich foods (Brazil nuts, eggs, sunflower seeds).",
            "Prioritize adequate protein each meal to support metabolism and muscle maintenance.",
            "Cooked (rather than large amounts of raw) cruciferous vegetables are generally fine.",
            "Maintain consistent meal timing to support energy levels through the day.",
        ],
        "warning_rules": [
            "Take thyroid medication as prescribed, typically on an empty stomach, apart from calcium/iron supplements.",
            "Expect weight/energy changes to be slower than average — this is expected, not a plan failure.",
        ],
        "recovery_rules": [
            "Prioritize 7-9 hours of sleep — thyroid conditions are especially sensitive to poor sleep.",
            "Allow extra recovery days if fatigue is persistent.",
        ],
        "progression_rules": [
            "Progress volume/intensity conservatively; reassess every 2-3 weeks rather than weekly.",
        ],
    },
    "hyperthyroidism": {
        "label": "Hyperthyroidism (Overactive Thyroid)",
        "keywords": ["hyperthyroid", "overactive thyroid", "graves"],
        "exercise_rules": [
            "Avoid very high-intensity or prolonged endurance sessions, which can strain an already elevated heart rate.",
            "Favor moderate-intensity strength and mobility work over max-effort cardio.",
            "Monitor resting heart rate and reduce intensity if it feels unusually elevated.",
        ],
        "diet_rules": [
            "Prioritize higher-calorie, nutrient-dense meals if unintentional weight loss is occurring.",
            "Include calcium and Vitamin D-rich foods to support bone health.",
            "Prioritize adequate protein to offset muscle breakdown.",
            "Limit caffeine and stimulants, which can worsen symptoms like rapid heartbeat.",
        ],
        "warning_rules": [
            "Stop exercising if you notice a racing heartbeat, tremors, or excessive sweating beyond normal exertion.",
            "Stay well hydrated — hyperthyroidism increases fluid loss.",
        ],
        "recovery_rules": [
            "Prioritize calm, lower-stress recovery activities (walking, stretching) between harder sessions.",
        ],
        "progression_rules": [
            "Progress conservatively and prioritize consistency over intensity increases.",
        ],
    },
    "pcos": {
        "label": "PCOS (Polycystic Ovary Syndrome)",
        "keywords": ["pcos", "pcod", "polycystic"],
        "exercise_rules": [
            "Combine resistance training with moderate cardio — both improve insulin sensitivity, which is central to PCOS management.",
            "Include 2-3 strength sessions per week to support metabolic health and body composition.",
            "Avoid excessive high-intensity training without adequate recovery, which can raise cortisol and worsen symptoms.",
        ],
        "diet_rules": [
            "Prioritize low-glycemic-index carbohydrates and high-fiber foods to support insulin sensitivity.",
            "Include adequate protein at every meal to support satiety and blood sugar stability.",
            "Include anti-inflammatory foods (leafy greens, berries, nuts, fatty fish or flaxseed).",
            "Limit refined sugar and heavily processed carbohydrates.",
        ],
        "warning_rules": [
            "Expect a slower and non-linear weight-change pattern — this is typical with PCOS, not a plan failure.",
            "Prioritize stress management — elevated stress can worsen hormonal symptoms.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep and stress-reduction practices; both directly affect PCOS symptoms.",
        ],
        "progression_rules": [
            "Progress gradually and track non-scale measures (energy, cycle regularity, strength) alongside weight.",
        ],
    },
    "arthritis": {
        "label": "Arthritis",
        "keywords": ["arthritis", "joint pain", "rheumatoid"],
        "exercise_rules": [
            "Prioritize low-impact movement (swimming, cycling, walking) over high-impact activities (running, jumping).",
            "Include a thorough joint-mobility warm-up before any resistance training.",
            "Favor controlled, moderate-range-of-motion strength work over heavy maximal lifts.",
            "Avoid exercises that cause sharp joint pain — mild muscle fatigue is fine, joint pain is not.",
        ],
        "diet_rules": [
            "Prioritize anti-inflammatory foods: fatty fish or omega-3 sources, turmeric, leafy greens, berries.",
            "Limit excess sugar and heavily processed food, which can increase inflammation.",
            "Include adequate protein to support joint-supporting muscle mass.",
            "Maintain a healthy body weight to reduce mechanical load on joints.",
        ],
        "warning_rules": [
            "Stop any exercise that causes sharp or worsening joint pain and rest the affected joint.",
            "Apply a longer-than-usual warm-up on stiff or cold days.",
        ],
        "recovery_rules": [
            "Allow extra recovery time after flare-ups before resuming normal training volume.",
        ],
        "progression_rules": [
            "Progress load and range of motion very gradually, guided by pain-free movement.",
        ],
    },
    "knee_pain": {
        "label": "Knee Pain / Knee Injury",
        "keywords": ["knee pain", "knee injury", "knee problem", "acl", "meniscus"],
        "exercise_rules": [
            "Avoid high-impact exercises (running, jumping, box jumps) and deep unsupported squats/lunges.",
            "Prioritize low-impact cardio: swimming, cycling, elliptical.",
            "Strengthen surrounding muscles (quads, hamstrings, glutes) with controlled, pain-free range of motion.",
            "Avoid twisting or pivoting movements under load.",
        ],
        "diet_rules": [
            "Prioritize anti-inflammatory foods to support joint recovery (omega-3 sources, turmeric, berries).",
            "Ensure adequate protein intake to support connective tissue and muscle repair.",
            "Maintain a healthy body weight to reduce load on the knee joint.",
        ],
        "warning_rules": [
            "Stop immediately if you feel sharp knee pain, instability, or swelling during a movement.",
            "Ice and rest the knee after any session that causes soreness beyond normal muscle fatigue.",
        ],
        "recovery_rules": [
            "Prioritize mobility and light strengthening on rest days rather than complete inactivity.",
        ],
        "progression_rules": [
            "Increase load or range of motion only when the current level is fully pain-free.",
        ],
    },
    "back_pain": {
        "label": "Back Pain",
        "keywords": ["back pain", "backpain", "spine issue", "slip disc", "sciatica", "herniated disc"],
        "exercise_rules": [
            "Prioritize core-stabilization exercises (planks, bird-dogs, dead bugs) over heavy spinal loading.",
            "Avoid heavy deadlifts, loaded spinal flexion, or high-impact activities until pain-free and cleared.",
            "Favor neutral-spine movement patterns and controlled tempo over fast, jerky lifts.",
            "Include hip and hamstring mobility work — tightness here often contributes to back strain.",
        ],
        "diet_rules": [
            "Prioritize anti-inflammatory foods to support recovery (omega-3s, leafy greens, berries).",
            "Maintain a healthy body weight to reduce mechanical strain on the lower back.",
            "Ensure adequate protein for muscle and connective-tissue repair.",
        ],
        "warning_rules": [
            "Stop any exercise that causes sharp pain, numbness, or tingling radiating down the leg.",
            "Maintain good posture during daily activities, not just workouts.",
        ],
        "recovery_rules": [
            "Prioritize gentle mobility and walking on rest days over complete inactivity.",
        ],
        "progression_rules": [
            "Progress core and spinal loading very gradually, guided strictly by pain-free movement.",
        ],
    },
    "heart_disease": {
        "label": "Heart Disease",
        "keywords": ["heart disease", "cardiac", "heart condition", "heart attack", "bypass"],
        "exercise_rules": [
            "Prioritize moderate-intensity steady-state cardio; avoid maximal-effort or high-intensity interval training without medical clearance.",
            "Include a longer, gradual warm-up and cool-down to avoid sudden cardiac strain.",
            "Avoid heavy straining resistance work and breath-holding during lifts.",
            "Monitor perceived exertion closely and stay well within a comfortable range.",
        ],
        "diet_rules": [
            "Prioritize heart-healthy fats (olive oil, nuts, seeds, fatty fish) over saturated/trans fats.",
            "Limit sodium and heavily processed foods.",
            "Prioritize fiber-rich whole grains, vegetables, and fruits.",
            "Limit red meat and fried foods; favor lean protein sources.",
        ],
        "warning_rules": [
            "Stop immediately and seek help if you feel chest pain, unusual shortness of breath, or dizziness.",
            "Always train within medically-cleared intensity limits — do not push through discomfort.",
        ],
        "recovery_rules": [
            "Prioritize consistent, unhurried recovery — avoid back-to-back demanding sessions.",
        ],
        "progression_rules": [
            "Progress intensity extremely gradually and only alongside medical guidance/clearance.",
        ],
    },
    "fatty_liver": {
        "label": "Fatty Liver",
        "keywords": ["fatty liver", "liver disease", "nafld"],
        "exercise_rules": [
            "Combine moderate cardio with resistance training — both reduce liver fat over time.",
            "Aim for consistent, frequent moderate-intensity sessions rather than sporadic intense ones.",
        ],
        "diet_rules": [
            "Limit added sugar and refined carbohydrates, which directly contribute to liver fat.",
            "Limit alcohol intake, which places additional strain on the liver.",
            "Prioritize fiber-rich vegetables, whole grains, and lean protein.",
            "Include healthy fats (olive oil, nuts, avocado) instead of fried/processed fats.",
        ],
        "warning_rules": [
            "Avoid crash dieting or extreme calorie restriction, which can stress the liver further.",
            "Follow up regularly with your doctor to monitor liver enzymes.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep and stress management, which support overall metabolic health.",
        ],
        "progression_rules": [
            "Progress gradually with an emphasis on consistency over weeks/months rather than rapid change.",
        ],
    },
    "high_cholesterol": {
        "label": "High Cholesterol",
        "keywords": ["high cholesterol", "cholesterol", "dyslipidemia"],
        "exercise_rules": [
            "Prioritize regular moderate-intensity cardio — it directly helps raise HDL and lower LDL over time.",
            "Include resistance training 2-3x/week to support overall metabolic health.",
        ],
        "diet_rules": [
            "Limit saturated and trans fats (fried foods, processed snacks, fatty cuts of meat).",
            "Prioritize soluble fiber (oats, legumes, fruits) which helps lower LDL cholesterol.",
            "Include healthy unsaturated fats (nuts, seeds, olive oil, fatty fish).",
            "Limit added sugar, which can worsen triglyceride levels.",
        ],
        "warning_rules": [
            "Continue prescribed cholesterol medication as directed alongside diet/exercise changes.",
        ],
        "recovery_rules": [
            "Prioritize consistent activity across the week over occasional intense sessions.",
        ],
        "progression_rules": [
            "Progress steadily — cholesterol improvements typically take several weeks to show.",
        ],
    },
    "obesity": {
        "label": "Obesity",
        "keywords": ["obese", "obesity", "morbidly overweight"],
        "exercise_rules": [
            "Prioritize low-impact cardio initially (walking, cycling, swimming) to protect joints while building capacity.",
            "Introduce resistance training progressively to preserve/build muscle during fat loss.",
            "Build session duration and intensity gradually rather than starting with high-intensity training.",
        ],
        "diet_rules": [
            "Create a moderate, sustainable calorie deficit rather than an extreme one.",
            "Prioritize protein and fiber at every meal to support satiety.",
            "Limit ultra-processed, calorie-dense, low-nutrient foods.",
            "Encourage consistent meal timing to reduce impulsive snacking.",
        ],
        "warning_rules": [
            "Watch for joint discomfort during higher-impact activities and scale back if needed.",
            "Prioritize sustainable, gradual progress over rapid extreme changes.",
        ],
        "recovery_rules": [
            "Prioritize adequate sleep — poor sleep is strongly linked to appetite dysregulation.",
        ],
        "progression_rules": [
            "Progress duration/intensity gradually as fitness and joint tolerance improve.",
        ],
    },
    "underweight": {
        "label": "Underweight",
        "keywords": ["underweight", "very thin", "low weight"],
        "exercise_rules": [
            "Prioritize resistance training to build muscle mass rather than excessive cardio.",
            "Limit very high-volume cardio, which can hinder weight/muscle gain goals.",
        ],
        "diet_rules": [
            "Prioritize a calorie surplus with nutrient-dense foods rather than empty calories.",
            "Include protein at every meal to support muscle growth.",
            "Include healthy calorie-dense foods (nuts, nut butters, whole milk, healthy oils).",
            "Encourage frequent meals/snacks if appetite is limited.",
        ],
        "warning_rules": [
            "Rule out underlying medical causes of being underweight with a doctor if unintentional.",
        ],
        "recovery_rules": [
            "Prioritize adequate rest between strength sessions to support muscle recovery and growth.",
        ],
        "progression_rules": [
            "Progress training load steadily alongside consistent calorie surplus.",
        ],
    },
    "anemia": {
        "label": "Anemia",
        "keywords": ["anemia", "anaemia", "low hemoglobin", "low haemoglobin"],
        "exercise_rules": [
            "Favor moderate-intensity training and avoid maximal-effort sessions until energy levels normalize.",
            "Include longer rest between sets/sessions if fatigue or dizziness occurs.",
            "Avoid high-intensity cardio on days with noticeable fatigue.",
        ],
        "diet_rules": [
            "Prioritize iron-rich foods (leafy greens, legumes, lean red meat if non-vegetarian, fortified cereals).",
            "Pair iron-rich foods with Vitamin C sources (citrus, amla, bell peppers) to boost absorption.",
            "Limit tea/coffee around meals, which can reduce iron absorption.",
            "Include Vitamin B12 and folate-rich foods (dairy, eggs, leafy greens, fortified foods).",
        ],
        "warning_rules": [
            "Stop and rest if you feel dizzy, lightheaded, or unusually breathless during exercise.",
            "Follow prescribed iron supplementation as directed by your doctor.",
        ],
        "recovery_rules": [
            "Prioritize extra sleep and rest days — anemia significantly affects recovery capacity.",
        ],
        "progression_rules": [
            "Progress very gradually and reassess as energy levels and hemoglobin improve.",
        ],
    },
    "migraine": {
        "label": "Migraine",
        "keywords": ["migraine", "chronic headache"],
        "exercise_rules": [
            "Favor consistent, moderate-intensity exercise — irregular intense exertion can be a migraine trigger for some.",
            "Ensure thorough hydration before, during, and after workouts.",
            "Avoid exercising in very hot, bright, or high-glare environments if these are known triggers.",
        ],
        "diet_rules": [
            "Maintain consistent meal timing — skipping meals is a common migraine trigger.",
            "Stay well hydrated throughout the day.",
            "Note and limit personal trigger foods if known (common ones include excess caffeine, alcohol, processed meats).",
        ],
        "warning_rules": [
            "Stop exercising and rest in a calm, dark space if a migraine begins.",
            "Keep prescribed migraine medication accessible if you have one.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep timing — irregular sleep is a common migraine trigger.",
        ],
        "progression_rules": [
            "Progress training gradually and consistently rather than in sporadic intense bursts.",
        ],
    },
    "depression": {
        "label": "Depression",
        "keywords": ["depression", "depressed"],
        "exercise_rules": [
            "Prioritize consistency over intensity — regular moderate activity has strong mood benefits.",
            "Favor enjoyable, sustainable activities (walking, light cardio, group activities) to support adherence.",
            "Keep early sessions short and achievable to build momentum and confidence.",
        ],
        "diet_rules": [
            "Prioritize Omega-3 rich foods (flaxseed, walnuts, fatty fish), linked to supporting mood.",
            "Maintain regular meal timing to support stable energy and mood.",
            "Limit excessive caffeine and alcohol, which can affect mood and sleep.",
        ],
        "warning_rules": [
            "Be gentle with progress expectations — some days will be harder than others, and that's normal.",
            "Reach out to a mental health professional or support line if symptoms feel overwhelming.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep and daylight exposure alongside physical training.",
        ],
        "progression_rules": [
            "Progress slowly, celebrating consistency and small wins over performance metrics.",
        ],
    },
    "anxiety": {
        "label": "Anxiety",
        "keywords": ["anxiety", "anxious", "panic disorder"],
        "exercise_rules": [
            "Favor rhythmic, moderate-intensity activities (walking, cycling, swimming) known to reduce anxiety.",
            "Include breathing exercises or light stretching at the end of each session.",
            "Avoid excessive caffeine before workouts, which can heighten anxious feelings.",
        ],
        "diet_rules": [
            "Maintain regular meal timing to avoid blood-sugar swings that can worsen anxious feelings.",
            "Limit caffeine and alcohol intake.",
            "Include Magnesium-rich foods (leafy greens, nuts, seeds), often associated with calmer mood.",
        ],
        "warning_rules": [
            "Stop and use a calming breathing technique if you feel a panic response during exercise.",
            "It's okay to modify or shorten a session on high-anxiety days.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep and relaxation practices alongside physical training.",
        ],
        "progression_rules": [
            "Progress gradually, prioritizing a sense of control and comfort over rapid intensity increases.",
        ],
    },
    "sleep_apnea": {
        "label": "Sleep Apnea",
        "keywords": ["sleep apnea", "sleep apnoea", "cpap"],
        "exercise_rules": [
            "Prioritize regular moderate cardio — it's linked to reducing sleep apnea severity, especially with weight loss.",
            "Avoid intense training very close to bedtime, which can disrupt sleep further.",
            "Include daytime activity to support better sleep quality and reduce daytime fatigue.",
        ],
        "diet_rules": [
            "Support a moderate calorie deficit if overweight — weight loss can meaningfully reduce apnea severity.",
            "Limit alcohol and heavy meals close to bedtime, both of which can worsen apnea.",
            "Limit sedatives/heavy caffeine use late in the day.",
        ],
        "warning_rules": [
            "Use your prescribed CPAP/treatment consistently — it directly affects recovery quality.",
            "Expect more daytime fatigue on poor-sleep nights; scale training intensity down accordingly.",
        ],
        "recovery_rules": [
            "Prioritize consistent sleep and wake times to maximize whatever sleep quality is achievable.",
        ],
        "progression_rules": [
            "Progress training conservatively on days following poor sleep.",
        ],
    },
}

# Coaching-risk severity per condition — drives the red/orange/green badges
# and the always-visible warning banner on the coach's side. Anything not
# listed (including the generic fallback) is treated as "moderate".
CONDITION_SEVERITY: dict[str, str] = {
    "asthma":           "moderate",
    "diabetes":         "critical",
    "hypertension":     "critical",
    "hypothyroidism":   "moderate",
    "hyperthyroidism":  "moderate",
    "pcos":             "moderate",
    "arthritis":        "moderate",
    "knee_pain":        "moderate",
    "back_pain":        "moderate",
    "heart_disease":    "critical",
    "fatty_liver":      "moderate",
    "high_cholesterol": "moderate",
    "obesity":          "moderate",
    "underweight":      "minor",
    "anemia":           "moderate",
    "migraine":         "minor",
    "depression":       "moderate",
    "anxiety":          "moderate",
    "sleep_apnea":      "moderate",
}
_SEVERITY_RANK = {"minor": 1, "moderate": 2, "critical": 3}


# Applied when the user reports a real condition that matches nothing above —
# never silently ignored.
_GENERIC_FALLBACK: dict[str, list[str]] = {
    "exercise_rules": [
        "Reduce overall training intensity until the condition is discussed with a doctor.",
        "Prioritize low-impact, moderate-intensity movement over maximal-effort training.",
        "Extend warm-up and cool-down duration for extra safety margin.",
    ],
    "diet_rules": [
        "Prioritize whole, minimally processed foods and consistent meal timing.",
        "Avoid extreme calorie restriction or aggressive surpluses until cleared by a doctor.",
    ],
    "warning_rules": [
        "Consult a doctor before starting an intense training program with this condition.",
        "Stop immediately if you experience pain, dizziness, or unusual discomfort.",
    ],
    "recovery_rules": [
        "Prioritize extra rest and sleep while adapting the plan to this condition.",
    ],
    "progression_rules": [
        "Progress conservatively and reassess every 1-2 weeks.",
    ],
}

_NEGATIVE_VALUES = ("", "none", "no", "nil", "n/a", "na", "nothing", "not applicable")


def _normalize(raw: str) -> str:
    return (raw or "").strip().lower()


def has_medical_condition(raw: str) -> bool:
    """True if the user reported a real condition (not empty/'none'/'no')."""
    return _normalize(raw) not in _NEGATIVE_VALUES


def detect_conditions(raw: str) -> list[str]:
    """Return matched condition keys. May be empty even when has_medical_condition()
    is True — the free-text condition just isn't in the rules dict yet."""
    norm = _normalize(raw)
    if not norm:
        return []
    matched = []
    for key, rules in CONDITION_RULES.items():
        if any(kw in norm for kw in rules["keywords"]):
            matched.append(key)
    return matched


def build_condition_directives(raw: str) -> dict[str, Any]:
    """
    Single entry point used by both plan generators and the SWOT engine.

    Returns:
      matched              — condition keys detected, e.g. ["asthma"]
      labels               — display names, e.g. ["Asthma"]
      exercise_rules / diet_rules / warning_rules / recovery_rules / progression_rules
                            — deduped, combined across every matched condition
      is_generic_fallback  — True when real condition text existed but matched
                              nothing in CONDITION_RULES (still gets safe defaults)
    Empty/"none" input returns all-empty lists and matched=[].
    """
    result: dict[str, Any] = {
        "matched": [], "labels": [],
        "conditions_meta": [],       # [{key, label, severity}] for badge rendering
        "overall_severity": None,    # worst severity across matches: minor|moderate|critical
        "exercise_rules": [], "diet_rules": [], "warning_rules": [],
        "recovery_rules": [], "progression_rules": [],
        "is_generic_fallback": False,
    }
    if not has_medical_condition(raw):
        return result

    matched = detect_conditions(raw)
    if not matched:
        result["is_generic_fallback"] = True
        result["labels"] = [raw.strip()]
        result["conditions_meta"] = [{"key": "unknown", "label": raw.strip(), "severity": "moderate"}]
        result["overall_severity"] = "moderate"
        for cat, items in _GENERIC_FALLBACK.items():
            result[cat] = list(items)
        return result

    result["matched"] = matched
    worst = 0
    for key in matched:
        rules = CONDITION_RULES[key]
        severity = CONDITION_SEVERITY.get(key, "moderate")
        worst = max(worst, _SEVERITY_RANK.get(severity, 2))
        result["labels"].append(rules["label"])
        result["conditions_meta"].append({"key": key, "label": rules["label"], "severity": severity})
        for cat in ("exercise_rules", "diet_rules", "warning_rules", "recovery_rules", "progression_rules"):
            for item in rules[cat]:
                if item not in result[cat]:
                    result[cat].append(item)
    result["overall_severity"] = {1: "minor", 2: "moderate", 3: "critical"}[worst]
    return result


def format_prompt_block(directives: dict[str, Any], section: str) -> str:
    """
    section: 'diet' | 'workout'. Injected into the LLM user prompt so the
    condition becomes a hard constraint instead of inert profile text.
    Returns "" when there's nothing to inject — healthy-user prompts are
    byte-for-byte unchanged.
    """
    if not directives["matched"] and not directives["is_generic_fallback"]:
        return ""
    labels = ", ".join(directives["labels"]) or "the user's reported condition"
    lines = [
        f"\nMEDICAL CONDITION REQUIREMENTS — HIGHEST PRIORITY (detected: {labels}):",
        "These override generic guidance above wherever they conflict. In the plan's "
        "summary/key_rules field, briefly explain WHY these adjustments matter for this condition.",
    ]
    if section == "diet":
        lines.extend(f"- {r}" for r in directives["diet_rules"])
    else:
        lines.extend(f"- {r}" for r in directives["exercise_rules"])
        if directives["progression_rules"]:
            lines.append("Progression pacing:")
            lines.extend(f"- {r}" for r in directives["progression_rules"])
        if directives["recovery_rules"]:
            lines.append("Recovery guidance:")
            lines.extend(f"- {r}" for r in directives["recovery_rules"])
    return "\n".join(lines)


def format_precautions(directives: dict[str, Any]) -> list[str]:
    """Deterministic 'Today's Precautions' — computed in Python, never by the
    LLM, so safety-relevant text never depends on model consistency."""
    return list(directives["warning_rules"])
