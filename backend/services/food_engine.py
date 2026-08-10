"""
ZITLAS — Food Recommendation Engine (backend/services/food_engine.py)

Loads food_dataset/zitlas_food_database_enriched.json ONCE at import time and
serves every diet/meal/swap feature from it. This is the single source of
truth for "what food can we recommend" — the LLM never invents a food name;
it only arranges foods this engine selected into a readable plan (see
groq_service.generate_nutrition_weekly_plan / generate_meal_swap, which call
build_week_plan() / find_swap_alternatives() and then overwrite whatever the
LLM wrote in the `foods` fields with the engine's own picks before returning
a response — so a hallucinated food can never reach a user even if the LLM
misbehaves).

INDEXING: every tag (meal/goal/diet/budget/living/disease/season/
availability/category) is inverted once at load time into dict[str, set[int]]
of food ids. A recommendation query intersects a handful of these sets
instead of scanning the food list — this is O(number of matching foods), not
O(4500), and stays that way at 10,000+ foods since nothing here is sized to
the current dataset.

MEDICAL SAFETY: condition detection is NOT reimplemented here. Free-text
medical_conditions input goes through services/medical_conditions.detect_
conditions() (the existing keyword matcher) and the matched keys are mapped
to this module's disease vocabulary (see _CONDITION_KEY_TO_DISEASE_TAG).
Only kidney/gluten/lactose — conditions medical_conditions.py has no entry
for at all — get a small keyword check of their own here.
"""

from __future__ import annotations

import json
import re
import threading
from collections import defaultdict
from pathlib import Path
from typing import Any

from services import medical_conditions

_ROOT = Path(__file__).parent.parent.parent
_DATASET_PATH = _ROOT / "food_dataset" / "zitlas_food_database_enriched.json"
_PROFILES_DIR = _ROOT / "food_profiles"

# CONDITION_RULES key (services/medical_conditions.py) -> diseaseSuitable tag
# (enrich_food_dataset.py). Conditions with no diet-safety meaning (arthritis,
# knee_pain, back_pain, obesity, underweight, migraine, depression, anxiety,
# sleep_apnea) are intentionally absent — they don't gate food selection.
_CONDITION_KEY_TO_DISEASE_TAG: dict[str, str] = {
    "asthma": "Asthma",
    "diabetes": "Diabetes",
    "hypertension": "Hypertension",
    "pcos": "PCOS",
    "hypothyroidism": "Thyroid",
    "hyperthyroidism": "Thyroid",
    "heart_disease": "Heart Disease",
    "fatty_liver": "Fatty Liver",
    "high_cholesterol": "High Cholesterol",
    "anemia": "Anemia",
}
# Not covered by medical_conditions.py at all — the only condition detection
# this module adds on its own, kept to a minimal keyword check.
_EXTRA_CONDITION_KEYWORDS: dict[str, tuple[str, ...]] = {
    "Kidney Disease": ("kidney", "ckd", "dialysis", "renal"),
    "Lactose Intolerance": ("lactose",),
    "Gluten Intolerance": ("gluten", "celiac", "coeliac"),
}

_ALLERGEN_KEYWORDS: dict[str, tuple[str, ...]] = {
    "Milk": ("milk", "dairy", "lactose"),
    "Gluten": ("gluten", "wheat", "celiac", "coeliac"),
    "Egg": ("egg",),
    "Shellfish/Fish": ("fish", "seafood", "prawn", "shrimp", "shellfish", "crab"),
    # No bare "nut" — it's a substring of "peanut" and would falsely flag
    # peanut allergies as a tree-nut allergy too.
    "Tree Nuts": ("almond", "cashew", "walnut", "pistachio", "hazelnut", "tree nut"),
    "Soy": ("soy", "soya"),
    "Peanuts": ("peanut", "groundnut"),
    "Sesame": ("sesame", "til"),
}

_MEAL_SLOTS = ("breakfast", "mid_morning", "lunch", "evening_snack", "dinner")
_SLOT_TO_MEAL_TAG = {
    "breakfast": "Breakfast", "mid_morning": "Snack", "lunch": "Lunch",
    "evening_snack": "Snack", "dinner": "Dinner",
}
_SLOT_CALORIE_WEIGHT = {
    "breakfast": 0.25, "mid_morning": 0.10, "lunch": 0.30,
    "evening_snack": 0.10, "dinner": 0.25,
}
_BUDGET_RANK = {"Low": 0, "Medium": 1, "High": 2}
_DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

# Score weights (SCORING PRIORITY ORDER from spec): must sum to 1.0.
# _W_REGION was added after a real bug: a Maharashtra user's "Gujarati Dal"
# swap was replaced with "Khaman Dhokla" — another Gujarat-specific dish —
# because the OLD scoring formula had no region term at all, so within the
# eligible pool (which the zone-level "region" gate treats Gujarat and
# Maharashtra as equally admissible, both being "West") ranking was decided
# purely by goal/avail/budget/pref, which two near-identical Gujarati snacks
# tie on. Region now carries real, second-highest weight (after goal) so a
# same-state/Pan-India candidate reliably outranks an equally-fit
# other-state dish that only shares the user's broad zone.
# Swap-time recency penalty. Deliberately larger than _W_VARIETY and
# non-saturating up to its cap: it has to be able to move a repeat suggestion
# BELOW a fresh one, which a 0.05-weighted, zero-flooring term cannot do.
# Capped so it can never outweigh goal fit + region + availability combined.
_RECENCY_STEP = 0.10
# Food quality as a ranking bonus, on top of the hard gate above.
_W_QUALITY = 0.30
# Nutrition-match penalty: a swap must stay a comparable MEAL. Weighted above
# recency so variety can never turn a lunch into a garnish.
_NUTRITION_STEP = 0.55
_MAX_NUTRITION_PENALTY = 0.60
_MAX_RECENCY_PENALTY = 0.45

# KITCHEN-FIRST WEIGHTS. Sum to 1.0.
#
# The old order put GOAL first (0.30) and the athlete's own food preferences
# LAST (0.05) — which is how you get a nutritionally perfect plan full of food
# someone has never cooked and can't buy nearby. ZITLAS's whole premise is the
# opposite: recommend what they can actually eat today.
#
# Safety is NOT in this table on purpose. Allergies, medical conditions, diet
# type and explicit exclusions are HARD FILTERS in `_pipeline_ids` — they can
# never be outweighed by a score, however strong a preference is.
#
# Order here mirrors the product spec: likes > region > budget > goal >
# kitchen fit > season > variety.
_W_PREF = 0.26      # foods the athlete already likes / already has at home
_W_REGION = 0.20    # commonly available where they actually are (GPS)
_W_BUDGET = 0.14    # affordable at their stated budget
_W_GOAL = 0.14      # fits the fitness goal
_W_KITCHEN = 0.10   # realistic for who actually cooks (hostel/family/self)
_W_AVAIL = 0.08     # everyday-household popularity signal from the dataset
_W_SEASON = 0.05    # in season right now
_W_VARIETY = 0.03   # nudge away from repetition (the hard work is in recency)

# Retained so the medical term keeps its documented shape; anything reaching
# scoring has already passed every medical filter, so this is a constant.
_W_MEDICAL = 0.0


def _norm(s: str) -> str:
    return (s or "").strip().lower()


_TRAILING_PAREN_RE = re.compile(r"\s*\([^()]*\)\s*$")


def strip_serving_suffix(name: str) -> str:
    """Removes a trailing serving-size clause, including NESTED parentheses.

    Plans store food lines as `"Quinoa Avocado Salad (Home Style) (1 bowl
    (150 g))"`. `_base_dish_name`'s regex requires a paren group with nothing
    nested inside, so it left that whole string untouched — meaning the line
    never matched its own dataset record, and the nutrition target resolved
    to None. The band then had nothing to measure against and silently did
    not apply.

    Scans from the right, balancing parens, and drops the final group.
    """
    text = (name or "").strip()
    if not text.endswith(")"):
        return text
    depth = 0
    for idx in range(len(text) - 1, -1, -1):
        ch = text[idx]
        if ch == ")":
            depth += 1
        elif ch == "(":
            depth -= 1
            if depth == 0:
                return text[:idx].strip()
    return text


def _base_dish_name(name: str) -> str:
    """Strip trailing "(...)" style-suffixes ("(Home Style)", "(Restaurant
    Style)", "(Punjabi)", ...) repeatedly, so "Dal Makhani (Punjabi) (Light
    / Low-Oil Version)" and "Dal Makhani" collapse to the same base name."""
    base = name
    while True:
        stripped = _TRAILING_PAREN_RE.sub("", base)
        if stripped == base:
            return _norm(base)
        base = stripped


# Words that CARRY a dish rather than name it. "Misal Pav" is misal served with
# pav; "Rajma Chawal" is rajma served with rice. Treating the carrier as the
# dish would group every rice-based plate into one family and every pav-based
# one into another, which is the opposite of useful.
_CARRIER_WORDS = frozenset({
    "pav", "rice", "chawal", "bhaat", "roti", "chapati", "bhakri", "paratha",
    "curry", "sabzi", "masala", "bowl", "plate", "combo", "meal", "style",
})

# Qualifier phrases that introduce an accompaniment rather than a new dish:
# "Khichdi with Extra Ghee" is still khichdi.
_QUALIFIER_SPLITS = (" with ", " and ", " served ", " topped ")


def dish_family(name: str) -> str:
    """The dish FAMILY a food belongs to — 'khichdi' for all of Sabudana
    Khichdi / Protein Rich Khichdi / Khichdi with Extra Ghee.

    `_base_dish_name` only strips style suffixes, so those three produce three
    DIFFERENT base names and dedup never groups them. That is exactly how a
    Maharashtra athlete ended up being offered khichdi after khichdi: each
    variant looked like a distinct dish to every diversity check in the
    pipeline.

    Heuristic, deliberately: the head noun of an Indian dish name is almost
    always the last significant word ("sabudana KHICHDI", "moong DAL",
    "veg PULAO"), after dropping accompaniment clauses and carrier words.
    """
    base = _base_dish_name(name)
    for split in _QUALIFIER_SPLITS:
        idx = base.find(split)
        if idx > 0:
            base = base[:idx]
            break
    tokens = [t for t in re.split(r"[\s/,-]+", base) if t]
    if not tokens:
        return base
    # Walk backwards past carrier words to the real head noun.
    for token in reversed(tokens):
        if token not in _CARRIER_WORDS:
            return token
    return tokens[-1]


# ── Nutritional equivalence gate ─────────────────────────────────────────────
#
# A swap has to be a REPLACEMENT, not merely another food. Without a hard
# band, ranking alone happily offered a 317 kcal fried bhajiya in place of a
# 215 kcal salad (+47%) — nutritionally a different meal wearing the same slot.
#
# Bands are asymmetric by intent: calories are the tightest because they drive
# the day's target, while the macros have a little more room since real foods
# rarely match on all three at once.
_BAND_CALORIES = 0.15
_BAND_PROTEIN = 0.20
_BAND_CARBS = 0.20
_BAND_FAT = 0.20


def _combo_macros(combo: list[dict]) -> dict[str, float]:
    return {
        "calories": float(sum(f.get("calories") or 0 for f in combo)),
        "protein": float(sum(f.get("protein") or 0 for f in combo)),
        "carbs": float(sum(f.get("carbs") or 0 for f in combo)),
        "fat": float(sum(f.get("fat") or 0 for f in combo)),
    }


def _within_band(actual: float, target: float, band: float) -> bool:
    """A zero/absent target means 'no opinion' — never a reason to reject."""
    if not target:
        return True
    return abs(actual - target) <= target * band


def combo_meets_nutrition(
    combo: list[dict],
    target: dict[str, float] | None,
    tolerance: float = 1.0,
) -> bool:
    """Whether a composed meal is a nutritionally acceptable stand-in.

    `tolerance` multiplies every band, and exists ONLY for the progressive
    relaxation in `find_swap_combos` — returning nothing at all is a worse
    outcome for the athlete than a slightly-off match, so the bands widen in
    steps rather than failing closed. The first pass always uses 1.0.
    """
    if not target:
        return True
    m = _combo_macros(combo)
    return (
        _within_band(m["calories"], target.get("calories", 0), _BAND_CALORIES * tolerance)
        and _within_band(m["protein"], target.get("protein", 0), _BAND_PROTEIN * tolerance)
        and _within_band(m["carbs"], target.get("carbs", 0), _BAND_CARBS * tolerance)
        and _within_band(m["fat"], target.get("fat", 0), _BAND_FAT * tolerance)
    )


def describe_swap(combo: list[dict], target: dict[str, float] | None, goal_tags: list[str] | None = None) -> str:
    """The explanation shown to the athlete, generated FROM THE ACTUAL NUMBERS.

    Never a template and never model prose: an LLM asked to justify a swap
    will cheerfully call a deep-fried bhajiya "good protein and healthy
    carbs", because it is writing plausible text rather than reading the
    values. Every clause below is derived from real dataset figures, so a
    claim can only appear when the numbers support it.
    """
    m = _combo_macros(combo)
    name = combo[0].get("name", "This")
    parts: list[str] = []

    if target and target.get("calories"):
        delta = m["calories"] - target["calories"]
        pct = abs(delta) / target["calories"] * 100
        if pct < 5:
            parts.append(f"almost identical calories ({m['calories']:.0f} vs {target['calories']:.0f} kcal)")
        elif delta < 0:
            parts.append(f"{pct:.0f}% fewer calories ({m['calories']:.0f} vs {target['calories']:.0f} kcal)")
        else:
            parts.append(f"{pct:.0f}% more calories ({m['calories']:.0f} vs {target['calories']:.0f} kcal)")
    else:
        parts.append(f"{m['calories']:.0f} kcal")

    if target and target.get("protein"):
        pdelta = m["protein"] - target["protein"]
        # "More protein" is only claimed on a difference worth naming — a
        # 0.3 g edge is noise, and calling it an upgrade is the exact kind of
        # overclaim this function exists to prevent.
        if pdelta >= 2:
            parts.append(f"more protein ({m['protein']:.1f}g vs {target['protein']:.1f}g)")
        elif pdelta <= -2:
            parts.append(f"a little less protein ({m['protein']:.1f}g vs {target['protein']:.1f}g)")
        else:
            parts.append(f"about the same protein ({m['protein']:.1f}g)")
    else:
        parts.append(f"{m['protein']:.1f}g protein")

    sentence = f"{name} — " + ", ".join(parts) + "."

    # Only state what the data actually says.
    extras: list[str] = []
    if combo[0].get("high_protein"):
        extras.append("genuinely high in protein")
    if combo[0].get("high_fiber"):
        extras.append("high in fibre")
    if goal_tags and any(g in (combo[0].get("goalSuitable") or []) for g in goal_tags):
        extras.append(f"suited to your {goal_tags[0].lower()} goal")
    if combo[0].get("hostel_friendly"):
        extras.append("easy to get in a hostel mess")
    if extras:
        sentence += " Also " + ", ".join(extras) + "."
    return sentence


# ── Nutrition Quality Score ──────────────────────────────────────────────────
#
# ZITLAS is a fitness platform. A swap engine that offers Onion Bhajiya as a
# weight-loss meal is not merely unhelpful — it actively works against the
# thing the athlete opened the app to do. Ranking on macros alone allows it,
# because a deep-fried snack can hit a calorie band perfectly.
#
# Every signal below is read from the dataset. The only heuristic is the
# preparation keyword list, and it exists because the dataset has no explicit
# "deep fried" flag — the names are the evidence available.

# Deep-fried / ultra-processed preparations. Matched on the dish name.
_DEEP_FRIED_KEYWORDS = (
    "pakoda", "pakora", "bhajiya", "bhajji", "samosa", "kachori",
    # "pav bhaji" by name, NOT a bare "bhaji" — Patal Bhaji and Aluchi Patal
    # Bhaji are healthy Maharashtrian leafy-vegetable dishes and must stay.
    "pav bhaji", "mirchi bhaji", "misal pav" if False else "pav bhaji",
    "vada", "puri", "bhatura", "jalebi", "gulab jamun", "chips", "fries",
    "fried", "deep fry", "medu", "murukku", "chakli", "sev ", "namkeen",
    "papad", "wafer", "nugget", "cutlet", "spring roll", "manchurian",
)

_ULTRA_PROCESSED_KEYWORDS = (
    "instant noodles", "maggi", "burger", "pizza", "soft drink", "cola",
    "packaged", "candy", "chocolate bar", "energy drink", "ice cream",
    "pastry", "doughnut", "donut", "cake", "biscuit", "cookie", "white bread",
)

# Categories the dataset itself marks as outside a health plan.
_LOW_QUALITY_CATEGORIES = frozenset({
    "Fast Foods", "Street Foods", "Desserts & Sweets",
})

# Goals where food QUALITY is the point, not just hitting a calorie number.
_HEALTH_GOALS = frozenset({
    "Weight Loss", "Fat Loss", "General Fitness", "Endurance",
})


def _name_matches(name: str, keywords) -> bool:
    n = _norm(name)
    return any(k in n for k in keywords)


def nutrition_quality_score(food: dict) -> float:
    """0..1 — how defensible this food is inside a health plan.

    Deliberately NOT a nutrition-density score: a food can be macro-perfect
    and still be a deep-fried street snack. This measures whether a coach
    would put it in a plan.
    """
    score = 0.55  # neutral home-cooked baseline

    cal = float(food.get("calories") or 0)
    protein = float(food.get("protein") or 0)
    fiber = float(food.get("fiber") or 0)
    sugar = float(food.get("sugar") or 0)
    sodium = float(food.get("sodium") or 0)
    fat = float(food.get("fat") or 0)

    # ── Rewards, all from real values ──
    if cal > 0:
        # Protein and fibre DENSITY per 100 kcal — the two things that make a
        # meal satisfying and useful, independent of portion size.
        score += min(0.20, (protein / cal) * 100 * 0.020)
        score += min(0.12, (fiber / cal) * 100 * 0.030)
    if food.get("high_protein"):
        score += 0.08
    if food.get("high_fiber"):
        score += 0.06
    if food.get("heart_friendly"):
        score += 0.05
    if food.get("diabetes_friendly"):
        score += 0.04
    if food.get("weight_loss_friendly"):
        score += 0.06
    # The dataset's own weight-loss rating, normalised.
    score += min(0.10, (float(food.get("weightLossScore") or 0) / 100.0) * 0.10)

    # ── Severe penalties ──
    name = food.get("name", "")
    if _name_matches(name, _DEEP_FRIED_KEYWORDS):
        score -= 0.45
    if _name_matches(name, _ULTRA_PROCESSED_KEYWORDS):
        score -= 0.45
    if food.get("category") in _LOW_QUALITY_CATEGORIES:
        score -= 0.25
    if food.get("street_food"):
        score -= 0.12
    if food.get("festival_food"):
        score -= 0.10

    # Added sugar and sodium, scaled to portion.
    if cal > 0:
        if (sugar / cal) * 100 > 8:
            score -= 0.18
        if sodium > 600:
            score -= 0.12
        if (fat / cal) * 100 > 5.5:  # fat-dominant
            score -= 0.10

    return max(0.0, min(1.0, score))


# Below this, a food is not offered in a health-goal plan at all.
_MIN_QUALITY_FOR_HEALTH_GOALS = 0.40


def is_health_plan_appropriate(food: dict, goal_tags: list[str] | None) -> bool:
    """Hard gate. Applied only for health-oriented goals — a Weight Gain plan
    legitimately has more room, and an expert can still place anything by hand
    through the plan editor."""
    if not goal_tags or not any(g in _HEALTH_GOALS for g in goal_tags):
        return True
    return nutrition_quality_score(food) >= _MIN_QUALITY_FOR_HEALTH_GOALS


class FoodRecommendationEngine:
    def __init__(self, path: Path = _DATASET_PATH):
        raw: list[dict] = json.loads(path.read_text(encoding="utf-8"))

        # A record with no `id` used to raise a bare KeyError here, killing
        # backend startup with a traceback that says nothing about which food
        # or how many. Skipping it lets the integrity report below name the
        # real problem — a diagnosable boot beats an opaque crash.
        self.by_id: dict[int, dict] = {
            f["id"]: f for f in raw if f.get("id") is not None
        }
        self.all_ids: set[int] = set(self.by_id.keys())

        # tag-tuple -> ids whose NAME violates that diet (see
        # _diet_name_violation_ids). Lazily filled, never invalidated: the
        # dataset is immutable for the life of the process.
        self._diet_violation_cache: dict[tuple[str, ...], set[int]] = {}
        # dish family -> ids. Lazily built by _family_sibling_ids.
        self._family_index: dict[str, set[int]] | None = None

        self._idx_meal: dict[str, set[int]] = defaultdict(set)
        self._idx_goal: dict[str, set[int]] = defaultdict(set)
        self._idx_diet: dict[str, set[int]] = defaultdict(set)
        self._idx_budget: dict[str, set[int]] = defaultdict(set)
        self._idx_living: dict[str, set[int]] = defaultdict(set)
        self._idx_category: dict[str, set[int]] = defaultdict(set)
        self._idx_type: dict[str, set[int]] = defaultdict(set)
        self._idx_season: dict[str, set[int]] = defaultdict(set)
        self._idx_availability: dict[str, set[int]] = defaultdict(set)
        self._idx_disease_unsafe: dict[str, set[int]] = defaultdict(set)  # tag -> ids UNSAFE for it
        self._idx_allergen: dict[str, set[int]] = defaultdict(set)
        # STEP 11 (geo enrichment, enrich_food_dataset_v2.py): index the
        # new state_of_origin/region fields the same way as every other
        # tag — this is what lets location_food_engine.py derive its
        # regional boost straight from the dataset instead of a hand-typed
        # dish list, and stays correct automatically as the dataset grows.
        self._idx_state: dict[str, set[int]] = defaultdict(set)
        self._idx_region: dict[str, set[int]] = defaultdict(set)
        # Real-bug fix: `state_of_origin` is empty on 3748/4520 foods (83%)
        # — including plenty of unmistakably state-specific dishes, e.g.
        # "Gujarati Dal" (category "Gujarati Foods") has state_of_origin=[].
        # `available_states` is a SEPARATE dataset field that is never empty
        # (verified against the live dataset: 0/4520 empty) — it's "All" for
        # genuine Pan-India foods and an explicit state list otherwise, and
        # is a superset-consistent match with state_of_origin wherever both
        # are populated. Indexing on this field instead is what lets a
        # Maharashtra user's own state bucket actually include foods whose
        # state_of_origin was simply never filled in, and — just as
        # importantly — keeps a Gujarat-tagged dish OUT of that bucket even
        # though both share the dataset's broad "West" region/zone label.
        self._effective_states: dict[int, frozenset[str]] = {}

        for f in raw:
            fid = f.get("id")
            if fid is None:
                continue  # already excluded from by_id; keep indexes consistent
            for tag in f.get("mealSuitable", []):
                self._idx_meal[tag].add(fid)
            for tag in f.get("goalSuitable", []):
                self._idx_goal[tag].add(fid)
            for tag in f.get("dietSuitable", []):
                self._idx_diet[tag].add(fid)
            self._idx_budget[f.get("budgetCategory", "Medium")].add(fid)
            for tag in f.get("livingSuitable", []):
                self._idx_living[tag].add(fid)
            self._idx_category[f.get("category", "")].add(fid)
            self._idx_type[f.get("type", "")].add(fid)
            for tag in f.get("season", []):
                self._idx_season[tag].add(fid)
            for tag in f.get("availability", []):
                self._idx_availability[tag].add(fid)
            for disease, safe in f.get("diseaseSuitable", {}).items():
                if not safe:
                    self._idx_disease_unsafe[disease].add(fid)
            for allergen in f.get("allergens", []):
                if allergen and allergen != "None":
                    self._idx_allergen[allergen].add(fid)
            states = frozenset(s for s in f.get("available_states", []) if s and s != "All")
            self._effective_states[fid] = states
            for state in states:
                self._idx_state[state].add(fid)
            self._idx_region[f.get("region", "Pan-India")].add(fid)

        self._print_startup_report(raw)

    # ── Startup report ───────────────────────────────────────────────────

    def _print_startup_report(self, raw: list[dict]) -> None:
        """Dataset inventory, printed once at import.

        Includes an INTEGRITY CHECK, which is the part that earns its keep:
        counting rows in the file and comparing against what actually made it
        into the index is the only way a silent truncation (a duplicate id
        overwriting an entry, a malformed record) shows up as anything other
        than mysteriously poor recommendations months later.
        """
        file_records = len(raw)
        loaded = len(self.by_id)

        def tally(index: dict[str, set[int]]) -> list[tuple[str, int]]:
            return sorted(index.items(), key=lambda kv: -len(kv[1]))

        line = "=" * 62
        print()
        print(line)
        print("  ZITLAS FOOD ENGINE")

        if loaded == file_records:
            print(f"  Dataset Loaded Successfully  -  {loaded:,} foods")
        else:
            # Never a silent pass: a mismatch means records were dropped.
            missing = file_records - loaded
            print(f"  !! INCOMPLETE LOAD - {loaded:,} of {file_records:,} "
                  f"({missing:,} records lost)")
            ids = [f.get("id") for f in raw]
            dupes = len(ids) - len(set(ids))
            no_id = sum(1 for i in ids if i is None)
            if dupes:
                print(f"    cause: {dupes:,} duplicate id(s) overwriting entries")
            if no_id:
                print(f"    cause: {no_id:,} record(s) with no id")

        print(line)
        print(f"  Source        : {_DATASET_PATH.name}")
        print(f"  States Covered: {len(self._idx_state)}")
        print()

        print("  BY MEAL TYPE")
        for tag, ids in tally(self._idx_meal):
            print(f"    {tag:<30} {len(ids):>6,}")
        print()

        print("  BY DIET PREFERENCE")
        for tag, ids in tally(self._idx_diet):
            print(f"    {tag:<30} {len(ids):>6,}")
        print()

        print("  BY BUDGET")
        for tag, ids in tally(self._idx_budget):
            print(f"    {tag:<30} {len(ids):>6,}")
        print()

        print("  BY SEASON")
        for tag, ids in tally(self._idx_season):
            print(f"    {tag:<30} {len(ids):>6,}")
        print()

        print("  BY REGION")
        for tag, ids in tally(self._idx_region):
            print(f"    {tag:<30} {len(ids):>6,}")
        print()

        # Top states only — 30+ entries of mostly single digits is noise.
        states = tally(self._idx_state)
        print(f"  TOP STATES  (of {len(states)} covered)")
        for tag, ids in states[:10]:
            print(f"    {tag:<30} {len(ids):>6,}")
        print()

        categories = tally(self._idx_category)
        print(f"  TOP CATEGORIES  (of {len(categories)})")
        for tag, ids in categories[:10]:
            print(f"    {(tag or '(uncategorised)'):<30} {len(ids):>6,}")
        print()

        # Health quality is what gates every fitness recommendation, so its
        # distribution belongs in the boot report rather than buried in a test.
        healthy = sum(
            1 for f in self.by_id.values()
            if nutrition_quality_score(f) >= _MIN_QUALITY_FOR_HEALTH_GOALS
        )
        pct = (healthy / loaded * 100) if loaded else 0
        print("  HEALTH QUALITY")
        print(f"    {'Plan-eligible':<30} {healthy:>6,}  ({pct:.0f}%)")
        print(f"    {'Excluded':<30} {loaded - healthy:>6,}  "
              f"(deep-fried / ultra-processed / high-sugar)")
        print()

        print(f"  Indexes: meal:{len(self._idx_meal)} goal:{len(self._idx_goal)} "
              f"diet:{len(self._idx_diet)} disease:{len(self._idx_disease_unsafe)} "
              f"allergen:{len(self._idx_allergen)}")
        print(line)
        print()

    # ── Condition / allergen resolution (reuses medical_conditions.py) ─────

    @staticmethod
    def resolve_disease_tags(medical_conditions_raw: str) -> list[str]:
        """Free-text condition -> this module's diseaseSuitable vocabulary,
        via medical_conditions.detect_conditions() (no re-implementation)."""
        if not medical_conditions.has_medical_condition(medical_conditions_raw):
            return []
        matched = medical_conditions.detect_conditions(medical_conditions_raw)
        tags = {_CONDITION_KEY_TO_DISEASE_TAG[k] for k in matched if k in _CONDITION_KEY_TO_DISEASE_TAG}
        norm = _norm(medical_conditions_raw)
        for tag, keywords in _EXTRA_CONDITION_KEYWORDS.items():
            if any(kw in norm for kw in keywords):
                tags.add(tag)
        return sorted(tags)

    @staticmethod
    def resolve_allergens(allergy_strings: list[str]) -> set[str]:
        """Free-text allergy list (e.g. 'no peanuts', 'lactose intolerant')
        -> the dataset's canonical allergen vocabulary."""
        resolved: set[str] = set()
        for raw in allergy_strings or []:
            norm = _norm(raw)
            if not norm:
                continue
            for canonical, keywords in _ALLERGEN_KEYWORDS.items():
                if any(kw in norm for kw in keywords):
                    resolved.add(canonical)
        return resolved

    # ── Filtering ────────────────────────────────────────────────────────
    # Stage order per spec: Medical -> Allergies -> Diet -> Goal -> SubGoal ->
    # Lifestyle -> Budget -> Living -> MealType -> Season -> Variety.
    # Medical, Allergies, Diet, and a profile's avoidCategories are PROTECTED
    # (folded into `base`, never relaxed — serving an unsafe or wrong-diet
    # food is never an acceptable "relax the filter" outcome). Everything
    # from Goal onward relaxes from the tail if it empties the candidate set,
    # so an over-constrained query degrades gracefully instead of returning
    # nothing. Variety has no filter stage — it's a scoring component only,
    # via the usage_count penalty in _score().

    def _union(self, index: dict[str, set[int]], tags) -> set[int]:
        out: set[int] = set()
        for t in tags:
            out |= index.get(t, set())
        return out

    def _family_of(self, food_id: int) -> str:
        return dish_family(strip_serving_suffix(self.by_id[food_id].get("name", "")))

    def _with_slot_family_penalty(
        self, usage_counts: dict[int, float], slot_families: dict[str, float]
    ) -> dict[int, float]:
        """`usage_counts` plus this slot's dish-family history.

        Returned as a NEW dict so the week-level per-id counts stay clean —
        the family charge is slot-local and must not leak into other slots.
        Only ids belonging to already-used families are touched, so the cost is
        proportional to what has actually been served, not to the dataset.
        """
        if not slot_families:
            return usage_counts
        effective = dict(usage_counts)
        for family, penalty in slot_families.items():
            for fid in self._family_ids_for(family):
                effective[fid] = effective.get(fid, 0.0) + penalty
        return effective

    def _family_ids_for(self, family: str) -> set[int]:
        self._family_sibling_ids(next(iter(self.by_id)))  # ensure index built
        return (self._family_index or {}).get(family, set())

    def _family_sibling_ids(self, food_id: int) -> set[int]:
        """Every id sharing this food's dish family, including itself.

        Built once on first use. `dish_family` already exists and is what
        `_spread_families` ranks with; this exposes the same grouping to the
        week-plan repetition cap.
        """
        if self._family_index is None:
            index: dict[str, set[int]] = defaultdict(set)
            for fid, food in self.by_id.items():
                index[dish_family(strip_serving_suffix(food.get("name", "")))].add(fid)
            self._family_index = dict(index)
            print(f"[FOOD ENGINE] dish-family index: {len(self._family_index)} families "
                  f"across {len(self.by_id)} foods (variety cap is charged per family)")
        fam = dish_family(strip_serving_suffix(self.by_id[food_id].get("name", "")))
        return self._family_index.get(fam, {food_id})

    def _diet_name_violation_ids(self, diet_tags) -> set[int]:
        """Ids whose NAME breaks the diet these tags represent.

        Computed once per distinct tag set and cached: the regex sweep is over
        the whole 4.5k-row database and must not run per request. Keyed by the
        tag tuple rather than the canonical key because every existing caller
        (`recommend`, `build_week_plan`, `find_swap_*`) already threads
        `diet_tags`, so this needs no signature changes.
        """
        cache_key = tuple(sorted(diet_tags))
        cached = self._diet_violation_cache.get(cache_key)
        if cached is not None:
            return cached
        # Reverse-map tags -> canonical key to know WHICH families to forbid.
        diet_key = next(
            (k for k, tags in _DIET_KEY_TO_TAGS.items() if tuple(sorted(tags)) == cache_key),
            None,
        )
        if diet_key is None:
            bad: set[int] = set()
        else:
            bad = {
                fid for fid, food in self.by_id.items()
                if diet_violation(food.get("name", ""), diet_key)
            }
        self._diet_violation_cache[cache_key] = bad
        if bad:
            print(f"[FOOD ENGINE] diet={diet_key}: excluded {len(bad)} mislabelled "
                  f"row(s) by name-level check (e.g. omelettes tagged Vegetarian)")
        return bad

    def _budget_ids(self, budget_tier: str) -> set[int]:
        max_rank = _BUDGET_RANK.get(budget_tier, 2)
        allowed = [b for b, r in _BUDGET_RANK.items() if r <= max_rank]
        return self._union(self._idx_budget, allowed)

    def _region_eligible_ids(
        self,
        user_state: str | None,
        compatible_regions: set[str] | None,
        favorite_foods: list[str] | None,
    ) -> set[int] | None:
        """Bucket A (state_of_origin matches) + B (Pan-India) + C (same zone
        as the user) are eligible by default; bucket D (a different zone,
        not the user's state) is excluded UNLESS the athlete's own
        favorite_foods/cuisine preference names the dish, its category, or
        its region explicitly — "location is a default, never a
        prohibition" (spec #5). Returns `None` (no filter — identical to
        pre-existing behavior) when no location resolved at all.
        """
        if compatible_regions is None and not user_state:
            return None
        eligible: set[int] = set()
        for zone in compatible_regions or ():
            eligible |= self._idx_region.get(zone, set())
        if user_state:
            eligible |= self._idx_state.get(user_state, set())

        fav_lc = [_norm(f) for f in (favorite_foods or []) if f]
        if fav_lc:
            for i in self.all_ids:
                if i in eligible:
                    continue
                f = self.by_id[i]
                haystack = f"{_norm(f['name'])} {_norm(f.get('category', ''))} {_norm(f.get('region', ''))}"
                if any(kw in haystack for kw in fav_lc):
                    eligible.add(i)
        return eligible

    def _pipeline_ids(
        self,
        disease_tags: list[str],
        allergens: set[str],
        diet_tags: list[str],
        goal_tags: list[str],
        subgoal_tag: str | None,
        profile: dict | None,
        budget_tier: str | None,
        living_tag: str | None,
        meal_tag: str | None,
        season_tag: str | None,
        disliked_foods: list[str] | None = None,
        max_prep_minutes: int | None = None,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
        favorite_foods: list[str] | None = None,
    ) -> set[int]:
        profile = profile or {}
        avoid_categories = set(profile.get("avoidCategories") or [])
        preferred_categories = set(profile.get("preferredCategories") or [])

        # Stages 1-2: Medical, Allergies — always applied, never relaxed.
        base = set(self.all_ids)
        for disease in disease_tags:
            base -= self._idx_disease_unsafe.get(disease, set())
        for allergen in allergens:
            base -= self._idx_allergen.get(allergen, set())
        if disliked_foods:
            disliked_lc = [_norm(d) for d in disliked_foods if d]
            base = {i for i in base if not any(d in _norm(self.by_id[i]["name"]) for d in disliked_lc)}

        # Stage 3: Diet Preference — never relaxed (never serve meat to a
        # vegetarian just because the candidate pool got thin).
        #
        # This used to read `if base & diet_ids: base &= diet_ids`, which meant
        # that when the intersection came out EMPTY the filter was skipped and
        # `base` kept its non-vegetarian rows — the exact opposite of the
        # promise in the comment above. An empty pool must stay empty so the
        # caller widens some OTHER axis (budget, region, season) or falls back;
        # it must never be resolved by serving meat to a vegetarian.
        if diet_tags:
            base &= self._union(self._idx_diet, diet_tags)
            # Name-level backstop for MISLABELLED rows. The database really
            # does tag "Bread Omelette", "Anda Curry" and five other omelettes
            # as dietSuitable=Vegetarian, and whey/casein products as Vegan, so
            # the tag filter above is not sufficient on its own — a pure
            # vegetarian would be served eggs straight out of the index.
            base -= self._diet_name_violation_ids(diet_tags)

        # Lifestyle's avoidCategories is a hard exclude too (a weight-loss
        # profile that says "avoid Desserts & Sweets" means it, not "prefer
        # not to") — folded into `base` alongside diet for the same reason.
        if avoid_categories:
            avoid_ids = self._union(self._idx_category, avoid_categories)
            if base - avoid_ids:
                base -= avoid_ids

        # Stages 4-9, relaxed from the TAIL on empty result — so list order
        # is protection order. Meal-slot integrity comes FIRST (relaxed
        # last): a thin pool must never bleed breakfast foods into dinner —
        # budget/living/season give way long before the slot does.
        stages: list[tuple[str, set[int] | None]] = [
            ("meal", self._idx_meal.get(meal_tag) if meal_tag else None),
            ("goal", self._union(self._idx_goal, goal_tags) if goal_tags else None),
            ("subgoal", self._idx_goal.get(subgoal_tag) if subgoal_tag else None),
            ("lifestyle_preferred", self._union(self._idx_category, preferred_categories) if preferred_categories else None),
            ("budget", self._budget_ids(budget_tier) if budget_tier else None),
            ("living", self._idx_living.get(living_tag) if living_tag else None),
            # "All Season" foods are eligible in EVERY season — that is what
            # the tag means. Filtering on the current season alone excluded
            # them, and since the overwhelming majority of the dataset is
            # tagged "All Season", a vegetarian breakfast pool collapsed from
            # 1,420 candidates to 66 (2 dish families), which is the real
            # reason a "personalised" week served khichdi every morning: there
            # was nothing else left to pick. Seasonality still influences the
            # RANKING via _score's seasonal bonus, which is where a
            # preference-shaped signal belongs.
            ("season", self._union(self._idx_season, [season_tag, "All Season"]) if season_tag else None),
            # STEP 14 (time intelligence): a relaxable preference, not a hard
            # cut — someone with 10 minutes shouldn't get zero food options
            # just because everything left in a thin pool takes 15.
            ("prep_time", (
                {i for i in self.all_ids if self.by_id[i].get("preparation_time_minutes", 20) <= max_prep_minutes}
                if max_prep_minutes else None
            )),
            # Regional availability/familiarity gate — LAST (most relaxable)
            # of every stage, so nutrition/goal/budget/living/season NEVER
            # lose out to localization (spec priority: safety > diet type >
            # explicit preference > nutrition targets > regional
            # availability > variety). Eligible = Pan-India + the user's own
            # zone + anything whose state_of_origin literally includes their
            # state (bucket A/B/C) + an explicit favorite_foods/cuisine
            # override (bucket D allowed back in on request). `None` means
            # no location resolved — a pure no-op, identical to today.
            ("region", self._region_eligible_ids(user_state, compatible_regions, favorite_foods)),
        ]
        active = [(n, s) for n, s in stages if s is not None]

        # MEAL SLOT IS NOT RELAXABLE. The loop below degrades gracefully by
        # dropping stages from the tail, and `cut=0` returns `base` — which
        # has no meal filter at all. That is how breakfast-only foods could
        # surface at dinner: a thin pool fell all the way through. The slot
        # is pinned separately so every fallback still respects it.
        meal_ids = next((s for n, s in active if n == "meal"), None)

        for cut in range(len(active), -1, -1):
            ids = set(base)
            for _, s in active[:cut]:
                ids &= s
            if meal_ids is not None:
                ids &= meal_ids
            if ids:
                return ids
        # Everything else exhausted — still never cross the meal boundary.
        return (base & meal_ids) if meal_ids is not None else base

    # ── Scoring ──────────────────────────────────────────────────────────

    def _region_component(
        self,
        food: dict,
        user_state: str | None,
        compatible_regions: set[str] | None,
        favorite_foods: list[str] | None,
    ) -> float:
        """Tiered regional fit — the score-side counterpart to
        `_region_eligible_ids`'s filter-side gating. The filter only asks
        "is this admissible at all" (Pan-India + user's zone + user's own
        state + explicit favorites); it does NOT distinguish, within that
        admitted pool, "this is actually the user's own state" from "this
        just happens to share the user's broad zone" — which is exactly how
        a Maharashtra user's Gujarati Dal got swapped for Khaman Dhokla,
        another Gujarat-specific dish sharing the "West" zone label. This
        tiering makes that distinction explicit and real-weighted:

            1.00  user's own state (bucket A)
            0.75  genuine Pan-India (bucket B)
            0.50  a specific OTHER state's dish, admitted only because the
                  athlete's own favorite_foods explicitly names it/its
                  category/region (bucket D, opt-in)
            0.30  a specific OTHER state's dish that is merely in the same
                  broad zone (bucket C) — e.g. Gujarat for a Maharashtra
                  user — no explicit ask for it
            0.15  outside the user's zone entirely (should only be reached
                  via a relaxed/edge-case pool, since eligibility already
                  excludes this)
            0.70  no location resolved at all — neutral, matches the
                  pre-region-fix behaviour exactly (a pure no-op)
        """
        if compatible_regions is None and not user_state:
            return 0.70
        fid = food["id"]
        states = self._effective_states.get(fid, frozenset())
        if user_state and user_state in states:
            return 1.00
        food_region = food.get("region", "Pan-India")
        if food_region == "Pan-India" or not states:
            return 0.75
        fav_lc = [_norm(f) for f in (favorite_foods or []) if f]
        explicit_override = False
        if fav_lc:
            haystack = f"{_norm(food['name'])} {_norm(food.get('category', ''))} {_norm(food_region)}"
            explicit_override = any(kw in haystack for kw in fav_lc)
        if explicit_override:
            return 0.50
        if compatible_regions and food_region in compatible_regions:
            return 0.30
        return 0.15

    def _score(
        self,
        food: dict,
        goal_tags: list[str],
        living_tag: str | None,
        budget_tier: str | None,
        favorite_foods: list[str],
        usage_count: int,
        profile: dict | None = None,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
        season_tag: str | None = None,
        meal_preparer: str | None = None,
        disliked_foods: list[str] | None = None,
    ) -> float:
        goal_hits = sum(1 for g in goal_tags if g in food.get("goalSuitable", []))
        goal_component = min(1.0, goal_hits / max(1, len(goal_tags))) if goal_tags else 0.7

        medical_component = 1.0  # already hard-filtered; anything left passed every check

        avail_component = 1.0 if (living_tag and living_tag in food.get("livingSuitable", [])) else 0.6
        # STEP 7/9 (geo enrichment): blend in the dataset's own popularity/
        # availability signal ("would a normal person actually eat this
        # today?") — folded into the existing Availability bucket, same
        # convention as every other profile-rule bonus above, so the
        # documented 40/25/15/10/5/5 weight formula never changes shape.
        # daily_household_score (the "Chapati/Dal/Rice first" anchor signal)
        # averages in equally, so everyday staples outrank niche regional
        # dishes and festival foods among otherwise-equal candidates.
        pop_avail = food.get("availability_score")
        if pop_avail is not None:
            household = food.get("daily_household_score")
            signal = (pop_avail + (household if household is not None else pop_avail)) / 200.0
            avail_component = min(1.0, avail_component * 0.5 + signal * 0.5)

        if budget_tier:
            diff = _BUDGET_RANK.get(food.get("budgetCategory", "Medium"), 1) - _BUDGET_RANK.get(budget_tier, 1)
            budget_component = 1.0 if diff <= 0 else max(0.0, 1.0 - diff * 0.5)
        else:
            budget_component = 0.8

        name_lc = _norm(food["name"])
        # LIKES are now the heaviest signal, so the gap between "they told us
        # they love this" and "we have no signal" has to be wide enough to
        # actually move ranking — a 1.0/0.5 split under a 0.26 weight is what
        # makes "I already have this at home" win.
        liked = any(_norm(f) in name_lc for f in favorite_foods if f)
        pref_component = 1.0 if liked else 0.45

        # A stated dislike is a soft-zero rather than a hard filter here: the
        # hard exclusion already happened in `_pipeline_ids`, and this only
        # catches near-misses (a variant whose name didn't match exactly).
        for d in (disliked_foods or []):
            if d and _norm(d) in name_lc:
                pref_component = 0.0
                break

        # SEASON — prefer what is actually in the market this month. "All
        # Season" foods are neutral rather than penalised; they're the staples
        # a plan legitimately leans on year-round.
        food_seasons = food.get("season") or []
        if not season_tag or not food_seasons:
            season_component = 0.7
        elif season_tag in food_seasons:
            season_component = 1.0
        elif "All Season" in food_seasons:
            season_component = 0.8
        else:
            season_component = 0.25

        # KITCHEN FIT — is this realistic for whoever actually cooks?
        season_component = min(1.0, season_component)
        kitchen_component = self._kitchen_fit(food, meal_preparer)

        # Profile-rule bonuses fold into the existing Availability/Preference
        # buckets rather than adding new weight categories (keeps the 40/25/
        # 15/10/5/5 formula intact) — a food matching the occupation profile's
        # preferred categories/difficulty/protein priority ranks higher among
        # otherwise-equal candidates.
        if profile:
            if food.get("category") in (profile.get("preferredCategories") or []):
                pref_component = min(1.0, pref_component + 0.3)
            if profile.get("difficulty") and food.get("difficulty") == profile["difficulty"]:
                avail_component = min(1.0, avail_component + 0.2)
            if profile.get("hostelFriendly") and "Hostel" in food.get("livingSuitable", []):
                avail_component = min(1.0, avail_component + 0.2)
            if profile.get("proteinPriority") == "High" and food.get("proteinScore", 0) >= 50:
                goal_component = min(1.0, goal_component + 0.15)

        variety_component = max(0.0, 1.0 - usage_count * 0.35)

        region_component = self._region_component(food, user_state, compatible_regions, favorite_foods)

        return (
            _W_PREF * pref_component
            + _W_REGION * region_component
            + _W_BUDGET * budget_component
            + _W_GOAL * goal_component
            + _W_KITCHEN * kitchen_component
            + _W_AVAIL * avail_component
            + _W_SEASON * season_component
            + _W_VARIETY * variety_component
            + _W_MEDICAL * medical_component
        )


    # Who actually cooks decides what "realistic" means. The dataset already
    # carries every signal this needs (hostel_friendly, home_cooked,
    # restaurant_food, preparation_time_minutes, difficulty), so this reads
    # real food metadata rather than guessing from names.
    _PREPARER_NEUTRAL = 0.6

    def _kitchen_fit(self, food: dict, preparer: str | None) -> float:
        if not preparer:
            return self._PREPARER_NEUTRAL
        prep_minutes = food.get("preparation_time_minutes") or 20
        easy = (food.get("difficulty") or "Medium") in ("Easy", "Very Easy")

        if preparer in ("hostel_mess", "tiffin"):
            # No kitchen of their own — it has to be something the mess
            # actually serves or that needs no cooking.
            if food.get("hostel_friendly"):
                return 1.0
            return 0.8 if "Ready to Eat" in (food.get("availability") or []) else 0.25

        if preparer == "restaurant":
            # Eating out: reward things a restaurant plausibly serves, and
            # don't pretend they'll assemble a home salad.
            if food.get("restaurant_food"):
                return 1.0
            return 0.7 if food.get("street_food") else 0.4

        if preparer == "self":
            # Cooking for one, usually short on time — quick and easy wins.
            if prep_minutes <= 15 and easy:
                return 1.0
            if prep_minutes <= 30:
                return 0.75
            return 0.35

        if preparer in ("family", "cook"):
            # A household kitchen: proper home-cooked meals are the point, and
            # prep time is somebody else's constraint.
            return 1.0 if food.get("home_cooked") else 0.7

        return self._PREPARER_NEUTRAL

    def recommend(
        self,
        meal_slot: str,
        goal_tags: list[str],
        diet_tags: list[str],
        living_situation: str | None,
        budget_tier: str | None,
        disease_tags: list[str],
        allergens: set[str],
        favorite_foods: list[str] | None = None,
        disliked_foods: list[str] | None = None,
        usage_counts: dict[int, int] | None = None,
        top_n: int = 4,
        exclude_ids: set[int] | None = None,
        profile: dict | None = None,
        subgoal_tag: str | None = None,
        season_tag: str | None = None,
        max_prep_minutes: int | None = None,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
        meal_preparer: str | None = None,
    ) -> list[dict]:
        """Filter -> score -> rank. Returns up to top_n real dataset foods."""
        meal_tag = _SLOT_TO_MEAL_TAG.get(meal_slot, meal_slot)
        ids = self._pipeline_ids(
            disease_tags=disease_tags, allergens=allergens, diet_tags=diet_tags,
            goal_tags=goal_tags, subgoal_tag=subgoal_tag, profile=profile,
            budget_tier=budget_tier, living_tag=living_situation, meal_tag=meal_tag,
            season_tag=season_tag, disliked_foods=disliked_foods,
            max_prep_minutes=max_prep_minutes, user_state=user_state,
            compatible_regions=compatible_regions, favorite_foods=favorite_foods,
        )
        if exclude_ids:
            ids -= exclude_ids
            if not ids:
                # exclude_ids ate the whole relaxed pool (e.g. a very small
                # variety window) — retry once without it rather than return empty.
                ids = self._pipeline_ids(
                    disease_tags=disease_tags, allergens=allergens, diet_tags=diet_tags,
                    goal_tags=goal_tags, subgoal_tag=subgoal_tag, profile=profile,
                    budget_tier=budget_tier, living_tag=living_situation, meal_tag=meal_tag,
                    season_tag=season_tag, disliked_foods=disliked_foods,
                    max_prep_minutes=max_prep_minutes, user_state=user_state,
                    compatible_regions=compatible_regions, favorite_foods=favorite_foods,
                )

        usage_counts = usage_counts or {}
        favorite_foods = favorite_foods or []
        scored = [
            (self._score(self.by_id[i], goal_tags, living_situation, budget_tier,
                         favorite_foods, usage_counts.get(i, 0), profile,
                         user_state=user_state, compatible_regions=compatible_regions,
                         season_tag=season_tag, meal_preparer=meal_preparer,
                         disliked_foods=disliked_foods), i)
            for i in ids
        ]
        scored.sort(key=lambda t: (-t[0], t[1]))
        return [self.by_id[i] for _, i in scored[:top_n]]

    # ── Location-aware queries (STEP 11: data-driven regional boost) ──────
    # These replace the earlier hand-typed dish-list approach in
    # location_food_engine.py — the dataset's own state_of_origin/region/
    # popularity_score fields (enrich_food_dataset_v2.py) are now the single
    # source of truth for "what's eaten in this state", so coverage grows
    # automatically as the dataset grows instead of needing a code change.

    def foods_by_state(self, state: str, limit: int = 8) -> list[dict]:
        """Top-N DISTINCT dishes whose state_of_origin includes `state`,
        ranked by popularity_score. Deduplicates "(Home Style)"/"(Restaurant
        Style)"/"(Street Style)"/"(Hostel Mess Style)" variants of the same
        dish to ONE entry (its highest-scoring variant) first — otherwise a
        single very popular pan-India dish with 8 style-variants (e.g. Poha)
        can fill the entire result and crowd out every other dish the state
        actually has, which defeats the point of asking "what's eaten here"."""
        ids = self._idx_state.get(state, set())
        foods = sorted((self.by_id[i] for i in ids), key=lambda f: -(f.get("popularity_score") or 0))
        seen_base_names: set[str] = set()
        deduped = []
        for f in foods:
            base = _base_dish_name(f["name"])
            if base in seen_base_names:
                continue
            seen_base_names.add(base)
            deduped.append(f)
        return deduped[:limit]

    def regional_categories_for_state(self, state: str, limit: int = 6) -> list[str]:
        """Food categories most associated with a state's regional dishes,
        ordered by how many of that state's foods fall in each category."""
        ids = self._idx_state.get(state, set())
        counts: dict[str, int] = defaultdict(int)
        for i in ids:
            cat = self.by_id[i].get("category")
            if cat:
                counts[cat] += 1
        return [c for c, _ in sorted(counts.items(), key=lambda kv: -kv[1])[:limit]]

    def foods_by_region(self, region: str, limit: int = 8) -> list[dict]:
        """Top-N foods for a broader region label (North/South/East/West/
        Pan-India), ranked by popularity_score."""
        ids = self._idx_region.get(region, set())
        foods = [self.by_id[i] for i in ids]
        foods.sort(key=lambda f: -(f.get("popularity_score") or 0))
        return foods[:limit]

    # ── Public plan builders ─────────────────────────────────────────────

    # ── Meal Validation Engine ────────────────────────────────────────────
    # Built on the dataset's meal_role/complete_meal classification
    # (enrich_food_dataset_v3.py): lunch and dinner must be anchored by a
    # genuine full meal (Rajma Chawal, Roti with Sabzi, ...), never by a
    # single ingredient, fruit, soup, or beverage — those may only join a
    # combo as sides. Breakfast is culturally more permissive (Poha, Eggs,
    # Milk are all legitimate breakfasts on their own); snacks are free.

    _MAIN_SLOTS = frozenset({"lunch", "dinner"})
    # roles that may ANCHOR a breakfast (a plate someone actually calls
    # breakfast) — fruit/beverage/supplement still can't be the whole plate.
    _BREAKFAST_ANCHOR_ROLES = frozenset({
        "breakfast_dish", "complete_meal", "protein_source", "dairy",
    })
    # roles that can complete a main meal as sides
    _VEG_SIDE_ROLES = frozenset({"vegetable", "soup_salad", "side_dish", "single_ingredient"})

    @staticmethod
    def _role(food: dict) -> str:
        return food.get("meal_role", "side_dish")

    def _is_meal_anchor(self, food: dict, slot: str) -> bool:
        if slot in self._MAIN_SLOTS:
            return food.get("complete_meal") is True
        if slot == "breakfast":
            return self._role(food) in self._BREAKFAST_ANCHOR_ROLES
        return True

    def build_meal_combo(self, pool: list[dict], slot: str, slot_target: float | None) -> list[dict]:
        """Compose one realistic meal from a ranked candidate pool.

        Mains (lunch/dinner): anchor on a complete meal, then fill missing
        roles the way an Indian nutritionist plates food — protein first,
        then carb, then a vegetable/fiber side ("Dal + Chapati + Sabzi").
        Breakfast: anchor on a breakfast-legitimate dish, then top up toward
        the calorie target. Snack slots: the top-ranked item stands alone.
        """
        anchor = next((f for f in pool if self._is_meal_anchor(f, slot)), None)
        if anchor is None and slot in self._MAIN_SLOTS:
            # No ready-made complete meal in this pool (e.g. muscle-gain +
            # low-budget filters leave mostly protein singles) — compose the
            # plate from parts instead: protein anchor + carb + veg below is
            # exactly the "Paneer + Chapati + Salad" pattern.
            anchor = next((f for f in pool if self._role(f) in ("protein_source", "dairy")), None)
        if anchor is None:
            anchor = pool[0]
        combo = [anchor]
        combo_ids = {anchor["id"]}
        combo_bases = {_base_dish_name(anchor["name"])}

        def _shares_staple(f: dict) -> bool:
            # "Curd Rice + Lemon Rice + Fried Rice" is three plates of rice,
            # not a meal — never let a FILL add a second dish built on a
            # staple the plate already has (the carb-base fill is exempt;
            # adding the staple is its whole job).
            name = _norm(f["name"])
            for staple in ("rice", "roti", "khichdi", "paratha", "dal"):
                if staple in name and any(staple in _norm(x["name"]) for x in combo):
                    return True
            return False

        def _add_first(predicate, allow_shared_staple: bool = False) -> bool:
            for f in pool:
                if f["id"] in combo_ids or _base_dish_name(f["name"]) in combo_bases:
                    continue
                if not allow_shared_staple and _shares_staple(f):
                    continue
                if predicate(f):
                    combo.append(f)
                    combo_ids.add(f["id"])
                    combo_bases.add(_base_dish_name(f["name"]))
                    return True
            return False

        if slot in self._MAIN_SLOTS:
            # Fill like a plate, not a buffet: prefer true sides to complete
            # the anchor (Curd Rice + Chole Rice is two dinners, not one).
            # Last-resort tiers accept imperfect items — an incomplete plate
            # is the worse outcome, and validate_meal_combo + the caller's
            # retry handle whatever still can't be fixed from this pool.
            #
            # 1. Carb base is STRUCTURAL: an Indian main sits on rice/roti
            #    unless the anchor is already a complete plate. Checking
            #    carb grams instead is how "Moong Dal + Masoor Dal" (50g of
            #    carbs, no rice) slipped through as a lunch.
            if not any(f.get("complete_meal") or self._role(f) == "carb_source" for f in combo):
                _add_first(lambda f: self._role(f) == "carb_source", allow_shared_staple=True) \
                    or _add_first(lambda f: f["carbs"] >= 25 and not f.get("complete_meal")
                                  and f["category"] != anchor["category"], allow_shared_staple=True)
            # 2. Protein — from a different category than what's plated
            #    (a second dal adds bulk, not balance).
            if sum(f["protein"] for f in combo) < 12:
                cats = {f["category"] for f in combo}
                _add_first(lambda f: self._role(f) in ("protein_source", "dairy")
                           and not f.get("complete_meal") and f["category"] not in cats) \
                    or _add_first(lambda f: f["protein"] >= 10 and not f.get("complete_meal")) \
                    or _add_first(lambda f: f["protein"] >= 6)
            # 3. Vegetable/fiber side
            if len(combo) < 3 and sum(f["fiber"] for f in combo) < 5 \
                    and not any(self._role(f) in self._VEG_SIDE_ROLES for f in combo):
                _add_first(lambda f: self._role(f) in self._VEG_SIDE_ROLES and f["calories"] <= 200)
        elif slot_target:
            total_cal = anchor["calories"]
            while total_cal < slot_target * 0.85 and len(combo) < 3:
                if not _add_first(lambda f: total_cal + f["calories"] <= slot_target * 1.25):
                    break
                total_cal = sum(f["calories"] for f in combo)
        return combo

    def validate_meal_combo(self, combo: list[dict], slot: str) -> list[str]:
        """STEP-15-style checklist for a single composed meal. Empty = valid."""
        issues: list[str] = []
        if not combo:
            return ["empty meal"]
        if slot in self._MAIN_SLOTS:
            if not any(f.get("complete_meal") or self._role(f) in ("protein_source", "carb_source") for f in combo):
                issues.append("no substantial main item (only sides/produce)")
            if sum(f["protein"] for f in combo) < 8:
                issues.append("no meaningful protein")
            # Structural, not gram-based: a main needs a complete plate or a
            # real carb base (rice/roti) — 50g of carbs from two dals is
            # still not a lunch.
            if not any(f.get("complete_meal") or self._role(f) == "carb_source" for f in combo):
                issues.append("no carb base (rice/roti/complete plate)")
            if len(combo) == 1 and not combo[0].get("complete_meal"):
                issues.append(f"single non-complete item as a main meal ({combo[0]['name']})")
        for f in combo:
            if f.get("festival_food"):
                issues.append(f"festival food in a regular meal ({f['name']})")
        return issues

    def build_week_plan(
        self,
        goal_tags: list[str],
        diet_tags: list[str],
        living_situation: str | None,
        budget_tier: str | None,
        disease_tags: list[str],
        allergens: set[str],
        favorite_foods: list[str] | None = None,
        disliked_foods: list[str] | None = None,
        daily_calorie_target: int | None = None,
        profile: dict | None = None,
        subgoal_tag: str | None = None,
        season_tag: str | None = None,
        max_prep_minutes: int | None = None,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
    ) -> dict[str, Any]:
        """
        Deterministic 7-day x 5-slot plan sourced entirely from the dataset.
        Each slot is a COMBO of 1-3 foods approaching that slot's share of
        daily_calorie_target, or the occupation profile's own maxCalories*
        cap when one is loaded (a single dataset item is rarely a whole meal
        — real breakfasts are "Poha + Milk + Banana", not just "Poha").
        Tracks per-food usage across the week so nothing repeats more than
        3 times (spec: 'avoid repeating identical foods every day').
        """
        target = daily_calorie_target or 1600
        profile = profile or {}
        slot_calorie_cap = {
            "breakfast": profile.get("maxCaloriesBreakfast"),
            "lunch": profile.get("maxCaloriesLunch"),
            "dinner": profile.get("maxCaloriesDinner"),
        }
        usage_counts: dict[int, float] = defaultdict(float)
        # slot -> dish family -> times that family filled THIS slot this week.
        slot_family_usage: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
        days = []
        for day_name in _DAY_NAMES:
            day_meals = {}
            for slot in _MEAL_SLOTS:
                pool = self.recommend(
                    meal_slot=slot, goal_tags=goal_tags, diet_tags=diet_tags,
                    living_situation=living_situation, budget_tier=budget_tier,
                    disease_tags=disease_tags, allergens=allergens,
                    favorite_foods=favorite_foods, disliked_foods=disliked_foods,
                    usage_counts=self._with_slot_family_penalty(usage_counts, slot_family_usage[slot]),
                    top_n=12,
                    profile=profile, subgoal_tag=subgoal_tag, season_tag=season_tag,
                    max_prep_minutes=max_prep_minutes,
                    user_state=user_state, compatible_regions=compatible_regions,
                )
                if not pool:
                    continue
                slot_target = slot_calorie_cap.get(slot) or (target * _SLOT_CALORIE_WEIGHT.get(slot, 0.2))
                combo = self.build_meal_combo(pool, slot, slot_target)
                if slot in self._MAIN_SLOTS and self.validate_meal_combo(combo, slot):
                    # Reject-and-regenerate (STEP 15): the pool couldn't make
                    # a valid plate. Retry WITHOUT the goal hard-filter (a
                    # muscle-gain "every item >=15g protein" cut can leave
                    # only dairy singles at low budgets) — goal still shapes
                    # the RANKING, and a balanced complete lunch serves the
                    # goal better than a lone bowl of curd. Medical/diet
                    # filters are inside the pipeline and never relax.
                    wide_pool = self.recommend(
                        meal_slot=slot, goal_tags=[], diet_tags=diet_tags,
                        living_situation=living_situation, budget_tier=budget_tier,
                        disease_tags=disease_tags, allergens=allergens,
                        favorite_foods=favorite_foods, disliked_foods=disliked_foods,
                        usage_counts=usage_counts, top_n=40,
                        profile=profile, subgoal_tag=None, season_tag=season_tag,
                        max_prep_minutes=max_prep_minutes,
                        user_state=user_state, compatible_regions=compatible_regions,
                    )
                    retry = self.build_meal_combo(wide_pool, slot, slot_target)
                    if len(self.validate_meal_combo(retry, slot)) < len(self.validate_meal_combo(combo, slot)):
                        combo = retry
                combo_ids = {f["id"] for f in combo}
                # A food used 3x already this week drops out of future primary
                # picks entirely (still eligible as a lower-priority alternative).
                for food in combo:
                    usage_counts[food["id"]] += 1.0
                    # Dish-family repetition is charged PER SLOT, not globally.
                    #
                    # Both simpler options were wrong. Charging the id alone let
                    # the dataset's style variants ("Sabudana Khichdi",
                    # "… (Home Style)", "… (Restaurant Style)") pose as
                    # different meals, so khichdi took 25 of 58 plates and six
                    # of seven breakfasts. Charging every sibling GLOBALLY
                    # instead burned through the high-protein families by day
                    # six and left Saturday/Sunday dinners with no protein
                    # anchor (caught by test_meal_quality.py). Scoping the
                    # charge to the slot suppresses repetition exactly where an
                    # athlete experiences it — "the same breakfast every
                    # morning" — while leaving each slot's own protein anchors
                    # available for the rest of the week.
                    slot_family_usage[slot][self._family_of(food["id"])] += 1.0
                day_meals[slot] = {
                    "primary": combo,
                    "alternatives": [f for f in pool if f["id"] not in combo_ids][:3],
                }
            days.append({"day": day_name, "meals": day_meals})
        plan = {"days": days, "usage_counts": dict(usage_counts)}
        plan["validation"] = self.validate_week_plan(plan, target)
        if not plan["validation"]["passed"]:
            print(f"[FOOD ENGINE] Plan validation flagged issues: {plan['validation']['issues']}")
        return plan

    # STEP 15 (AI validation): a cheap, deterministic post-hoc checklist —
    # this engine's filter pipeline already structurally prevents most of
    # the spec's failure modes (medical/diet/budget are hard filters, not
    # suggestions), so this is a defensive double-check, not a generator.
    # Never raises — a flagged plan is still returned and logged, since a
    # rules-based engine re-running the same deterministic pipeline would
    # just reproduce the same result rather than "regenerate" something new.
    def validate_week_plan(self, plan: dict, daily_calorie_target: int) -> dict[str, Any]:
        issues: list[str] = []
        for day in plan["days"]:
            day_name = day["day"]
            day_cal = 0
            for slot, meal in day["meals"].items():
                primary = meal.get("primary") or []
                if not primary:
                    issues.append(f"{day_name}/{slot}: empty meal")
                    continue
                day_cal += sum(f.get("calories", 0) for f in primary)
                for issue in self.validate_meal_combo(primary, slot):
                    issues.append(f"{day_name}/{slot}: {issue}")
            if daily_calorie_target and not (0.75 * daily_calorie_target <= day_cal <= 1.25 * daily_calorie_target):
                issues.append(f"{day_name}: total calories {day_cal} outside ±25% of target {daily_calorie_target}")
        food_counts: dict[int, int] = defaultdict(int)
        for day in plan["days"]:
            for meal in day["meals"].values():
                for f in meal.get("primary") or []:
                    food_counts[f["id"]] += 1
        for fid, count in food_counts.items():
            if count > 3:
                issues.append(f"food id={fid} repeated {count}x this week (limit 3)")
        return {"passed": not issues, "issues": issues}

    def _is_excluded(self, food: dict, exclude_strings: list[str], exclude_bases: set[str]) -> bool:
        """Rejected/current foods arrive as free-form display strings ('150g
        grilled chicken breast (marinated...)', 'Sweet Corn (Raw) (100 g ...)')
        — an exact-name comparison never matches them, which is exactly how a
        rejected Sweet Corn kept coming back. Match on the dish's BASE name
        (style/serving suffixes stripped) in both directions instead: the
        candidate is out if its base name equals an excluded base OR appears
        anywhere inside an excluded display string."""
        base = _base_dish_name(food["name"])
        if base in exclude_bases:
            return True
        return any(base in s for s in exclude_strings)

    def _ranked_swap_pool(
        self, meal_slot, goal_tags, diet_tags, living_situation, budget_tier,
        disease_tags, allergens, exclude_names, profile, subgoal_tag, season_tag,
        pool_size: int = 30,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
        favorite_foods: list[str] | None = None,
        recent_families: dict[str, int] | None = None,
        target_calories: float | None = None,
        meal_preparer: str | None = None,
        disliked_foods: list[str] | None = None,
    ) -> list[dict]:
        exclude_strings = [_norm(n) for n in exclude_names if n]
        exclude_bases = {_base_dish_name(n) for n in exclude_names if n}
        ids = self._pipeline_ids(
            disease_tags=disease_tags, allergens=allergens, diet_tags=diet_tags,
            goal_tags=goal_tags, subgoal_tag=subgoal_tag, profile=profile,
            budget_tier=budget_tier, living_tag=living_situation,
            meal_tag=_SLOT_TO_MEAL_TAG.get(meal_slot, meal_slot), season_tag=season_tag,
            user_state=user_state, compatible_regions=compatible_regions, favorite_foods=favorite_foods,
        )
        ids = {i for i in ids if not self._is_excluded(self.by_id[i], exclude_strings, exclude_bases)}

        # HEALTH GATE — deep-fried, ultra-processed and high-sugar foods are
        # removed outright for fitness goals. They are not "a bit worse"; they
        # are the opposite of what the athlete is training for, and no macro
        # match justifies offering one.
        healthy = {i for i in ids if is_health_plan_appropriate(self.by_id[i], goal_tags)}
        if healthy:
            ids = healthy

        # HARD family exclusion. A score penalty alone is not enough: in a
        # pool already narrowed by region + diet + goal, one family can lead
        # by more than any bounded penalty, so khichdi kept winning even at
        # full penalty. The rule the athlete actually needs is categorical —
        # if they just had khichdi, don't offer khichdi — so recently-seen
        # families are REMOVED here, and only restored if that would leave
        # nothing to suggest (a genuinely empty pool is worse than a repeat).
        blocked = set(recent_families or {})
        if blocked:
            without_blocked = {
                i for i in ids if dish_family(self.by_id[i]["name"]) not in blocked
            }
            if without_blocked:
                ids = without_blocked

        if not ids:
            # Relax goal/budget/living but NEVER the meal slot — a dinner swap
            # must stay a dinner-suitable food (diet/medical stay protected
            # inside _pipeline_ids itself). Region is relaxed here too (it's
            # the most-relaxable stage everywhere else in the pipeline).
            ids = self._pipeline_ids(
                disease_tags=disease_tags, allergens=allergens, diet_tags=diet_tags,
                goal_tags=[], subgoal_tag=None, profile=None,
                budget_tier=None, living_tag=None,
                meal_tag=_SLOT_TO_MEAL_TAG.get(meal_slot, meal_slot), season_tag=None,
            )
            ids = {i for i in ids if not self._is_excluded(self.by_id[i], exclude_strings, exclude_bases)}
        # `favorite_foods` used to be hardcoded to `[]` here regardless of
        # what the caller passed in — meaning pref_component AND (now)
        # region_component's explicit-override tier were silently disabled
        # for every swap. Passing the real list through fixes both.
        #
        # `usage_count` used to be hardcoded to 0 as well, which made
        # `_score`'s variety term a CONSTANT for every swap — so an identical
        # query always returned the identical top result, forever. It is now
        # driven by how recently the candidate's dish FAMILY was seen (in
        # today's plan or in earlier suggestions), which is what turns the
        # variety weight back on.
        def _swap_score(fid: int) -> float:
            food = self.by_id[fid]
            base = self._score(
                food, goal_tags, living_situation, budget_tier,
                favorite_foods or [], 0, profile,
                user_state=user_state, compatible_regions=compatible_regions,
                season_tag=season_tag, meal_preparer=meal_preparer,
                disliked_foods=disliked_foods,
            )
            # Recency penalty applied OUTSIDE the fixed 30/20/20/12/8/5/5
            # formula, on purpose. Routing it through `_score`'s variety term
            # caps it at _W_VARIETY (0.05) AND floors at zero after ~3 uses,
            # so a dish family leading by more than 0.05 stayed #1 forever —
            # which is exactly how breakfast came back khichdi 90 times out
            # of 100. Here it keeps growing until it can actually reorder,
            # while the cap stops variety from ever outranking safety, diet
            # type, or goal fit.
            seen = (recent_families or {}).get(dish_family(food["name"]), 0)
            score = base - min(_MAX_RECENCY_PENALTY, seen * _RECENCY_STEP)
            # Quality is a ranking term as well as a gate: among foods that
            # all clear the bar, the better one should still come first.
            score += _W_QUALITY * nutrition_quality_score(food)

            # NUTRITION MATCH — a replacement has to be a comparable meal, not
            # merely a different one. Without this, pushing hard for variety
            # eventually surfaces a 15 kcal side dish as a "lunch": every
            # substantial option has been penalised for being seen before,
            # and nothing was checking size. Scaled by relative distance so it
            # is meaningful for a 200 kcal snack and a 700 kcal dinner alike.
            if target_calories and target_calories > 0:
                cal = food.get("calories") or 0
                drift = abs(cal - target_calories) / target_calories
                score -= min(_MAX_NUTRITION_PENALTY, drift * _NUTRITION_STEP)
            return score

        scored = [(_swap_score(i), i) for i in ids]
        scored.sort(key=lambda t: (-t[0], t[1]))
        scored = self._spread_families([i for _, i in scored], pool_size)
        scored = [(0.0, i) for i in scored]
        if user_state or compatible_regions:
            print(f"[REGION_RANK] user_state={user_state} compatible_regions={compatible_regions}")
            for rank, (score, i) in enumerate(scored[:5], start=1):
                f = self.by_id[i]
                states = self._effective_states.get(i, frozenset())
                region_class = (
                    "preferred" if user_state and user_state in states else
                    "common" if (f.get("region", "Pan-India") == "Pan-India" or not states) else
                    "other_region_explicit" if favorite_foods and any(
                        _norm(kw) in f"{_norm(f['name'])} {_norm(f.get('category',''))} {_norm(f.get('region',''))}"
                        for kw in favorite_foods if kw
                    ) else
                    "other_region_same_zone" if compatible_regions and f.get("region", "Pan-India") in compatible_regions else
                    "out_of_zone"
                )
                print(f"[REGION_RANK] {rank}. food={f['name']!r} foodRegion={f.get('region')} "
                      f"states={sorted(states)} regionClass={region_class} finalScore={score:.4f}")
        return [self.by_id[i] for _, i in scored[:pool_size]]


    def _spread_families(self, ranked_ids: list[int], limit: int) -> list[int]:
        """Re-orders a ranked list so consecutive picks come from DIFFERENT
        dish families, without discarding the ranking.

        Sorting by score alone clusters every khichdi variant at the top,
        because near-identical dishes score near-identically. This takes the
        best-of-each-family first, then the second-best of each, and so on —
        so the head of the list is maximally varied while still strictly
        preferring higher-scored foods within each family.
        """
        by_family: dict[str, list[int]] = {}
        for i in ranked_ids:
            by_family.setdefault(dish_family(self.by_id[i]["name"]), []).append(i)
        # Families keep their best member's rank, so a stronger family still
        # leads — variety reorders, it never promotes a bad food.
        order = sorted(by_family, key=lambda f: ranked_ids.index(by_family[f][0]))
        out: list[int] = []
        round_index = 0
        while len(out) < min(limit, len(ranked_ids)):
            added = False
            for family in order:
                members = by_family[family]
                if round_index < len(members):
                    out.append(members[round_index])
                    added = True
                    if len(out) >= min(limit, len(ranked_ids)):
                        break
            if not added:
                break
            round_index += 1
        return out

    def find_swap_alternatives(
        self,
        meal_slot: str,
        goal_tags: list[str],
        diet_tags: list[str],
        living_situation: str | None,
        budget_tier: str | None,
        disease_tags: list[str],
        allergens: set[str],
        exclude_names: list[str],
        top_n: int = 4,
        profile: dict | None = None,
        subgoal_tag: str | None = None,
        season_tag: str | None = None,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
        favorite_foods: list[str] | None = None,
        recent_families: dict[str, int] | None = None,
        target_calories: float | None = None,
        meal_preparer: str | None = None,
        disliked_foods: list[str] | None = None,
    ) -> list[dict]:
        """Ranked single-food alternatives (kept for offline fallback and
        snack slots). For main meals, anchors-only: never offers a single
        ingredient/soup/fruit as the replacement for a lunch or dinner."""
        pool = self._ranked_swap_pool(
            meal_slot, goal_tags, diet_tags, living_situation, budget_tier,
            disease_tags, allergens, exclude_names, profile, subgoal_tag, season_tag,
            user_state=user_state, compatible_regions=compatible_regions, favorite_foods=favorite_foods,
            recent_families=recent_families,
            target_calories=target_calories,
            meal_preparer=meal_preparer,
            disliked_foods=disliked_foods,
        )
        if meal_slot in self._MAIN_SLOTS or meal_slot == "breakfast":
            anchors = [f for f in pool if self._is_meal_anchor(f, meal_slot)]
            if anchors:
                pool = anchors
        # Never offer two style-variants of the same dish as "alternatives"
        seen: set[str] = set()
        out = []
        for f in pool:
            base = _base_dish_name(f["name"])
            if base in seen:
                continue
            seen.add(base)
            out.append(f)
            if len(out) == top_n:
                break
        return out

    def find_swap_combos(
        self,
        meal_slot: str,
        goal_tags: list[str],
        diet_tags: list[str],
        living_situation: str | None,
        budget_tier: str | None,
        disease_tags: list[str],
        allergens: set[str],
        exclude_names: list[str],
        n_combos: int = 2,
        profile: dict | None = None,
        subgoal_tag: str | None = None,
        season_tag: str | None = None,
        user_state: str | None = None,
        compatible_regions: set[str] | None = None,
        favorite_foods: list[str] | None = None,
        recent_families: dict[str, int] | None = None,
        target_calories: float | None = None,
        meal_preparer: str | None = None,
        disliked_foods: list[str] | None = None,
        nutrition_target: dict[str, float] | None = None,
    ) -> list[list[dict]]:
        """Full-meal swap: each result is a COMPLETE composed meal (e.g.
        'Paneer Bhurji with Roti + Curd + Salad'), never a lone ingredient.
        A swap replaces the entire plate — the same way build_week_plan
        composes one — and every combo passes validate_meal_combo before
        it's offered. Snack/pre/post slots return single-item combos."""
        # Pool must SCALE with how many options are wanted. It was pinned at
        # 30 regardless, and each option consumes far more than one candidate:
        # family dedup collapses every khichdi variant to a single slot, the
        # nutrition band rejects whatever falls outside +/-15%, and season
        # narrows further. Asking for 5 options out of 30 candidates ran the
        # pool dry and returned 1. Rank deep, then choose.
        pool = self._ranked_swap_pool(
            meal_slot, goal_tags, diet_tags, living_situation, budget_tier,
            disease_tags, allergens, exclude_names, profile, subgoal_tag, season_tag,
            pool_size=max(30, n_combos * 40),
            user_state=user_state, compatible_regions=compatible_regions, favorite_foods=favorite_foods,
            recent_families=recent_families,
            target_calories=target_calories,
            meal_preparer=meal_preparer,
            disliked_foods=disliked_foods,
        )
        # WIDEN THE POOL when it cannot possibly yield the requested number of
        # distinct dishes. A narrow athlete profile (hostel + vegetarian +
        # weight-loss + one state) can leave as few as 8 candidates, all in a
        # single dish family — at which point no amount of nutrition-band
        # relaxation produces a second option, because there is no second
        # family to offer.
        #
        # Relaxes SOFT context only, in increasing order of how much the
        # athlete would notice: season, then living situation, then budget.
        # Diet type, allergens, medical safety and meal slot are NEVER
        # relaxed here — those are the filters that keep a suggestion safe and
        # appropriate, and a thin pool is not a reason to compromise them.
        def _families(candidates: list[dict]) -> int:
            return len({dish_family(f["name"]) for f in candidates})

        for relax in ("season", "living", "budget"):
            if _families(pool) >= n_combos:
                break
            if relax == "season":
                season_tag = None
            elif relax == "living":
                living_situation = None
            else:
                budget_tier = None
            pool = self._ranked_swap_pool(
                meal_slot, goal_tags, diet_tags, living_situation, budget_tier,
                disease_tags, allergens, exclude_names, profile, subgoal_tag, season_tag,
                pool_size=max(30, n_combos * 40),
                user_state=user_state, compatible_regions=compatible_regions,
                favorite_foods=favorite_foods, recent_families=recent_families,
                target_calories=target_calories, meal_preparer=meal_preparer,
                disliked_foods=disliked_foods,
            )
            print(f"[SWAP FUNNEL] pool widened (relaxed {relax}) -> "
                  f"{len(pool)} candidates in {_families(pool)} families")

        if not pool:
            return []
        combos: list[list[dict]] = []
        used_anchor_bases: set[str] = set()
        rejected_for_nutrition: list[list[dict]] = []
        _tolerance = 1.0
        # Reset per call. Read by callers to tell the athlete when a result is
        # a "closest available match" rather than a true nutritional peer —
        # silently widening the band and presenting the result as equivalent
        # would be dishonest.
        self.last_swap_tolerance = 1.0
        for anchor in pool:
            if len(combos) >= n_combos:
                break
            if not self._is_meal_anchor(anchor, meal_slot):
                continue
            # FAMILY, not base name: base-name dedup let "Sabudana Khichdi"
            # and "Protein Rich Khichdi" both through as "different" dishes.
            base = dish_family(anchor["name"])
            if base in used_anchor_bases:
                continue
            sub_pool = [anchor] + [f for f in pool if f["id"] != anchor["id"]]
            combo = self.build_meal_combo(sub_pool, meal_slot, None)
            if self.validate_meal_combo(combo, meal_slot):
                continue  # failed validation — try the next anchor
            # NUTRITION GATE — a replacement outside the band is rejected and
            # the search continues, rather than being offered because it
            # happened to rank well.
            if not combo_meets_nutrition(combo, nutrition_target, _tolerance):
                rejected_for_nutrition.append(combo)
                continue
            used_anchor_bases.add(base)
            combos.append(combo)
        # PROGRESSIVE RELAXATION — only ever of the nutrition band, and only
        # when the strict pass found nothing. Widening in steps keeps the
        # closest match first: an athlete is better served by a 20%-off meal
        # labelled honestly than by an empty sheet. Safety/diet/allergy
        # filters are NOT part of this and are never relaxed.
        if len(combos) < n_combos and rejected_for_nutrition and nutrition_target:
            # Widen in steps and KEEP FILLING until we have enough options.
            # Stopping at the first factor that yielded anything is what left
            # the athlete staring at a single choice: one near-miss passed at
            # 1.5x and the search ended there.
            seen_families = {dish_family(c[0]["name"]) for c in combos}
            for factor in (1.5, 2.0, 3.0):
                for candidate in rejected_for_nutrition:
                    if len(combos) >= n_combos:
                        break
                    fam = dish_family(candidate[0]["name"])
                    if fam in seen_families:
                        continue
                    if combo_meets_nutrition(candidate, nutrition_target, factor):
                        combos.append(candidate)
                        seen_families.add(fam)
                        self.last_swap_tolerance = max(self.last_swap_tolerance, factor)
                if len(combos) >= n_combos:
                    break
            if self.last_swap_tolerance > 1.0:
                print(f"[SWAP ENGINE] nutrition band widened to x{self.last_swap_tolerance}")

        if not combos and pool:
            # No anchor survived validation (ultra-restrictive filters) —
            # degrade to the best single candidates rather than nothing.
            combos = [[f] for f in pool[:n_combos]]

        # Per-request funnel log. Without this the only visible symptom of a
        # collapse is "one option appeared", with no way to tell which stage
        # ate the candidates.
        rej_families = {dish_family(c[0]["name"]) for c in rejected_for_nutrition}
        print(
            f"[SWAP FUNNEL] slot={meal_slot} pool={len(pool)} "
            f"anchors_passed={len(used_anchor_bases)} "
            f"nutrition_rejected={len(rejected_for_nutrition)} "
            f"(in {len(rej_families)} families) "
            f"tolerance=x{self.last_swap_tolerance} returned={len(combos)}"
        )
        return combos


# ── Profile/lifestyle string -> engine tag normalization ───────────────────
# The frontend/LLM-facing profile uses free-form strings ("weight_loss",
# "hostel", "₹100/day"); the dataset's tags are fixed vocab. This is the one
# place that translation happens so both call sites (weekly plan + swap) stay
# in sync.

_GOAL_STRING_TO_TAGS: dict[str, list[str]] = {
    "weight_loss": ["Weight Loss", "Fat Loss"],
    "fat_loss": ["Fat Loss", "Weight Loss"],
    "muscle_gain": ["Muscle Gain", "Lean Bulk"],
    "muscle_building": ["Muscle Gain", "Lean Bulk"],
    "weight_gain": ["Lean Bulk", "Muscle Gain"],
    "six_pack": ["Six Pack"],
    "lean_bulk": ["Lean Bulk"],
    "endurance": ["Endurance"],
    "athletic_performance": ["Athletic Performance"],
    "general_fitness": ["General Fitness"],
}


def goal_tags_from_profile(player_profile: dict) -> list[str]:
    raw = _norm(
        player_profile.get("primary_goal") or player_profile.get("goal_type")
        or player_profile.get("fitness_goal") or player_profile.get("goal") or ""
    )
    raw_key = raw.replace(" ", "_").replace("-", "_")
    for key, tags in _GOAL_STRING_TO_TAGS.items():
        if key in raw_key:
            return tags
    return ["General Fitness"]


# ── Occupation/goal-folder resolution for food_profiles/ (rules only, never
# food data — see generate_food_profiles.py). Distinct from
# goal_tags_from_profile() above: that maps to goalSuitable dataset tags,
# this maps to one of the 4 food_profiles/ folder names. ─────────────────────

_GOAL_KEY_ALIASES: dict[str, str] = {
    "weight_loss": "weight_loss", "fat_loss": "weight_loss", "six_pack": "weight_loss",
    "wedding_transformation": "weight_loss", "post_pregnancy": "weight_loss", "obesity": "weight_loss",
    "muscle_gain": "muscle_gain", "muscle_building": "muscle_gain", "weight_gain": "muscle_gain",
    "lean_bulk": "muscle_gain", "bodybuilding": "muscle_gain", "strength": "muscle_gain",
    "general_fitness": "general_fitness", "healthy_lifestyle": "general_fitness",
    "athletic_performance": "athletic_performance", "endurance": "athletic_performance",
    "sports_performance": "athletic_performance", "marathon": "athletic_performance",
}


def resolve_goal_key(player_profile: dict) -> str:
    """-> one of the 4 food_profiles/ goal folder names."""
    raw = _norm(
        player_profile.get("primary_goal") or player_profile.get("goal_type")
        or player_profile.get("fitness_goal") or player_profile.get("goal") or ""
    )
    raw_key = raw.replace(" ", "_").replace("-", "_")
    for key, folder in _GOAL_KEY_ALIASES.items():
        if key in raw_key:
            return folder
    return "general_fitness"


# food_profiles/<goal>/ only ships 5 base lifestyle files (student, hostel,
# working_professional, homemaker, athlete) — every occupation the spec asks
# to "support" maps onto one of those 5 (see generate_food_profiles.py's
# LIFESTYLE_ALIASES for the same mapping, kept in sync by hand since one is a
# one-time generator and this is the runtime resolver).
_LIFESTYLE_KEY_ALIASES: dict[str, str] = {
    "hostel": "hostel", "pg": "hostel", "academy": "hostel",
    "college": "student", "university": "student", "student": "student",
    "homemaker": "homemaker", "housewife": "homemaker", "home_maker": "homemaker", "home": "homemaker",
    "athlete": "athlete", "sportsperson": "athlete", "professional_athlete": "athlete",
    "working_professional": "working_professional", "job": "working_professional",
    "office": "working_professional", "employee": "working_professional",
    "night_shift": "working_professional", "travel": "working_professional",
    "premium": "working_professional",
}


def resolve_lifestyle_key(player_profile: dict, lifestyle_data: dict | None) -> str:
    """-> one of the 5 food_profiles/<goal>/ file names."""
    ld = lifestyle_data or {}
    raw = _norm(
        player_profile.get("occupation") or player_profile.get("profession")
        or player_profile.get("role") or ld.get("occupation") or ld.get("living_situation") or ""
    )
    raw_key = raw.replace(" ", "_").replace("-", "_")
    for key, base in _LIFESTYLE_KEY_ALIASES.items():
        if key in raw_key:
            return base
    return "student"  # no usable signal — this app's majority user base


def resolve_subgoal(player_profile: dict) -> str | None:
    raw = (
        player_profile.get("sub_goal") or player_profile.get("subgoal")
        or player_profile.get("secondary_goal") or ""
    )
    return raw.strip() if isinstance(raw, str) and raw.strip() else None


_CURRENT_MONTH_TO_SEASON: dict[int, str] = {
    12: "Winter", 1: "Winter", 2: "Winter",
    3: "Summer", 4: "Summer", 5: "Summer", 6: "Summer",
    7: "Monsoon", 8: "Monsoon", 9: "Monsoon",
    10: "All Season", 11: "All Season",
}


def current_season(month: int | None = None) -> str:
    import datetime
    month = month or datetime.date.today().month
    return _CURRENT_MONTH_TO_SEASON.get(month, "All Season")


_profile_cache: dict[tuple[str, str], dict] = {}


def load_profile(goal_key: str, lifestyle_key: str) -> dict:
    """Load+cache a food_profiles/<goal>/<lifestyle>.json rule file. Falls
    back to a neutral, unrestrictive profile for an unrecognised combination
    rather than erroring — goal/medical/diet filtering upstream still holds."""
    cache_key = (goal_key, lifestyle_key)
    if cache_key in _profile_cache:
        return _profile_cache[cache_key]

    path = _PROFILES_DIR / goal_key / f"{lifestyle_key}.json"
    if path.exists():
        profile = json.loads(path.read_text(encoding="utf-8"))
    else:
        print(f"[FOOD ENGINE] No profile at {path} — using neutral fallback profile")
        profile = {
            "profileName": f"{lifestyle_key} - {goal_key}", "goal": goal_key, "subGoals": [],
            "preferredCategories": [], "avoidCategories": [], "preferredMealTypes": [],
            "budget": None, "difficulty": None, "maxCaloriesBreakfast": None,
            "maxCaloriesLunch": None, "maxCaloriesDinner": None, "proteinPriority": "Medium",
            "hostelFriendly": False, "easyAvailability": True,
        }
    _profile_cache[cache_key] = profile
    return profile


def load_profile_for_user(player_profile: dict, lifestyle_data: dict | None) -> dict:
    """The one call groq_service.py needs — resolves goal+lifestyle from the
    raw profile/lifestyle dicts and returns the matching rule file."""
    goal_key = resolve_goal_key(player_profile)
    lifestyle_key = resolve_lifestyle_key(player_profile, lifestyle_data)
    return load_profile(goal_key, lifestyle_key)


# A diet PREFERENCE is what the user is ALLOWED to eat, not a requirement that
# every food carry that trait. A non-vegetarian eats vegetarian food too, so a
# non-veg preference must admit BOTH tags — otherwise a regional non-veg dish
# (e.g. Kolhapuri Mutton, a side_dish) can't be plated with its rice/roti/dal
# base (those are tagged Vegetarian), producing an incomplete meal. Diet is a
# hard filter (never relaxed) and combined by UNION in _pipeline_ids, so:
#   Vegetarian  -> only vegetarian foods (meat never served to a vegetarian)
#   Non-Veg     -> vegetarian ∪ non-vegetarian foods (veg staples + proteins)
#   Vegan       -> vegan only (stricter than veg: no dairy/egg — never widened)
#   Eggitarian  -> the dataset already tags every Vegetarian food Eggitarian
#                  (Vegetarian ⊆ Eggitarian, verified), so this already means
#                  "veg + egg" and correctly excludes meat/fish.
# ── Canonical dietary preference ──────────────────────────────────────────
# ONE source of truth for "what may this athlete eat", shared by the food
# engine, the assessment prompt builder and the post-generation validator, so
# Flutter and the website can never diverge on what "Pure Vegetarian" means.
#
# EGGS ARE NOT VEGETARIAN in ZITLAS. `pure_vegetarian` excludes them; only
# `eggetarian` and `non_vegetarian` allow them. This is a product rule, not an
# LLM suggestion — it is enforced by filtering candidates out of the database
# BEFORE generation and by rejecting violations AFTER generation.
DIET_PURE_VEGETARIAN = "pure_vegetarian"
DIET_VEGAN = "vegan"
DIET_EGGETARIAN = "eggetarian"
DIET_NON_VEGETARIAN = "non_vegetarian"
DIET_JAIN = "jain"

# Ordered longest/most-specific FIRST — these are substring probes against the
# normalized client value, and "non-vegetarian" contains "vegetarian", so a
# naive pass would classify every non-vegetarian as vegetarian (and vice
# versa). Order here is load-bearing; do not sort this table alphabetically.
_DIET_CANONICAL_PROBES: list[tuple[tuple[str, ...], str]] = [
    (("non-vegetarian", "non vegetarian", "nonvegetarian", "nonveg", "non veg",
      "mixed", "no preference", "omnivore"), DIET_NON_VEGETARIAN),
    (("vegan", "plant based", "plant-based"), DIET_VEGAN),
    # Both spellings: the clients send "eggetarian", the food database's own
    # `dietSuitable` tag is "Eggitarian". Accepting only one silently
    # fell through to the permissive default and served eggetarians meat.
    (("eggetarian", "eggitarian", "eggeterian", "egg-etarian", "eggs only"), DIET_EGGETARIAN),
    (("jain",), DIET_JAIN),
    (("pure vegetarian", "pure veg", "shakahari", "sattvic", "satvik",
      "vegetarian", "veg"), DIET_PURE_VEGETARIAN),
]

# dietSuitable tag sets per canonical key. `pure_vegetarian` deliberately does
# NOT include "Eggitarian": in this database egg dishes carry
# dietSuitable=["Non Vegetarian","Halal"], and admitting the Eggitarian tag
# would widen the pool to foods a pure vegetarian must never see.
_DIET_KEY_TO_TAGS: dict[str, list[str]] = {
    DIET_PURE_VEGETARIAN: ["Vegetarian"],
    DIET_VEGAN:           ["Vegan"],
    DIET_EGGETARIAN:      ["Vegetarian", "Eggitarian"],
    DIET_NON_VEGETARIAN:  ["Vegetarian", "Eggitarian", "Non Vegetarian"],
    DIET_JAIN:            ["Jain"],
}

# Name-level defense in depth. The dietSuitable tags are the primary filter;
# these catch a mislabelled database row and, critically, are what the
# post-generation validator uses to police LLM-authored meal text (which is
# free-form and never had a dietSuitable tag to begin with).
_MEAT_KEYWORDS = (
    "chicken", "mutton", "beef", "pork", "lamb", "bacon", "ham", "sausage",
    "salami", "pepperoni", "keema", "kheema", "meat", "steak", "liver",
    "turkey", "duck", "veal", "venison", "goat",
)
_SEAFOOD_KEYWORDS = (
    "fish", "prawn", "shrimp", "crab", "lobster", "squid", "calamari",
    "oyster", "mussel", "clam", "tuna", "salmon", "sardine", "mackerel",
    "pomfret", "surmai", "rohu", "hilsa", "anchovy", "seafood", "octopus",
)
_EGG_KEYWORDS = (
    # "bhurji" is deliberately absent: it names a SCRAMBLE STYLE, not an
    # ingredient — Paneer Bhurji is vegetarian. Egg versions are already
    # caught by "egg"/"anda" ("Egg Bhurji", "Anda Bhurji").
    "egg", "eggs", "omelette", "omelet", "anda", "frittata",
    "shakshuka", "mayonnaise", "mayo", "meringue", "custard",
)
_DAIRY_KEYWORDS = (
    "milk", "curd", "yogurt", "yoghurt", "paneer", "cheese", "butter",
    "ghee", "cream", "lassi", "buttermilk", "chaas", "khoya", "malai",
    "condensed", "whey", "casein", "kheer", "shrikhand", "raita",
)

# Which keyword families each canonical key FORBIDS.
_DIET_KEY_FORBIDDEN: dict[str, tuple[tuple[str, ...], ...]] = {
    DIET_PURE_VEGETARIAN: (_MEAT_KEYWORDS, _SEAFOOD_KEYWORDS, _EGG_KEYWORDS),
    DIET_VEGAN:           (_MEAT_KEYWORDS, _SEAFOOD_KEYWORDS, _EGG_KEYWORDS, _DAIRY_KEYWORDS),
    DIET_EGGETARIAN:      (_MEAT_KEYWORDS, _SEAFOOD_KEYWORDS),
    DIET_JAIN:            (_MEAT_KEYWORDS, _SEAFOOD_KEYWORDS, _EGG_KEYWORDS),
    DIET_NON_VEGETARIAN:  (),
}

# Words that contain a forbidden keyword as a substring but are themselves
# perfectly allowed — checked before flagging so "eggplant" is not read as
# "egg" and "vegetable" is not read as "veg...".
_KEYWORD_FALSE_POSITIVES = (
    "eggplant", "egg plant", "eggless", "egg-free", "eggfree",
    # A fruit, not a dairy/egg custard.
    "custard apple",
    "soy milk", "soya milk", "almond milk", "coconut milk", "oat milk",
    "rice milk", "cashew milk", "peanut butter", "almond butter",
    "milk thistle", "butter bean", "buttermilk squash", "butternut",
    "coconut cream", "vegan butter", "vegan cheese", "vegan mayo",
    "meat substitute", "meat-free", "mock meat", "soya chunks",
)


def canonical_diet_key(diet_type: str) -> str:
    """Client diet string -> canonical key.

    FAILS CLOSED. An unrecognized/blank value returns `pure_vegetarian`, the
    most restrictive everyday option, because the previous behaviour returned
    "no restriction" and any label the table did not literally contain (a
    reworded client option, a typo, a missing answer) silently authorised
    meat and eggs for someone who never asked for them. A too-restrictive
    plan is a support ticket; serving eggs to a pure vegetarian is a broken
    promise.
    """
    norm = _norm(diet_type)
    if not norm:
        return DIET_PURE_VEGETARIAN
    for probes, key in _DIET_CANONICAL_PROBES:
        if any(p in norm for p in probes):
            return key
    return DIET_PURE_VEGETARIAN


def diet_tags_from_lifestyle(diet_type: str) -> list[str]:
    """dietSuitable tags to filter the candidate pool with."""
    return list(_DIET_KEY_TO_TAGS[canonical_diet_key(diet_type)])


def diet_violation(text: str, diet_key: str) -> str | None:
    """The forbidden keyword `text` contains for `diet_key`, else None.

    Used on both database rows and LLM-authored meal strings, which is why it
    takes text rather than a food dict.
    """
    norm = _norm(text)
    if not norm:
        return None
    forbidden = _DIET_KEY_FORBIDDEN.get(diet_key, ())
    if not forbidden:
        return None
    # Neutralise known-safe compounds first so their substrings can't trip.
    scrubbed = norm
    for safe in _KEYWORD_FALSE_POSITIVES:
        if safe in scrubbed:
            scrubbed = scrubbed.replace(safe, " ")
    for family in forbidden:
        for word in family:
            if re.search(rf"(?<![a-z]){re.escape(word)}(?![a-z])", scrubbed):
                return word
    return None


def food_violates_diet(food: dict, diet_key: str) -> str | None:
    """Tag-level AND name-level check for one database row."""
    allowed = set(_DIET_KEY_TO_TAGS.get(diet_key, []))
    tags = set(food.get("dietSuitable") or [])
    if allowed and tags and not (tags & allowed):
        return f"dietSuitable={sorted(tags)}"
    return diet_violation(food.get("name", ""), diet_key)


# Max times one dish may appear across a 7-day plan before it reads as "the
# same thing every day" rather than a recurring favourite.
_MAX_DISH_REPEATS_PER_WEEK = 3


def audit_delivered_plan(
    plan: dict | None,
    diet_key: str,
    allergens: set[str] | None = None,
) -> dict[str, Any]:
    """Validate the plan shape that actually reaches the athlete.

    `validate_week_plan` above checks the ENGINE's internal structure
    (`days[].meals{slot}.primary[]` of database rows). This checks the
    DELIVERED structure (`days[].meals[].foods[]` of free-form strings), which
    is what the LLM authors and what gets stored and rendered. Those strings
    never carried a `dietSuitable` tag, so tag filtering alone could not police
    them — a prompt-only vegetarian rule is exactly how "2 boiled eggs" reached
    a pure vegetarian.

    Returns {"ok", "diet_violations", "allergen_violations", "repetition",
    "empty_meals"} and never raises: callers decide whether to repair the
    offending meals or discard the plan.
    """
    diet_violations: list[dict[str, Any]] = []
    allergen_violations: list[dict[str, Any]] = []
    empty_meals: list[str] = []
    # dish -> [(day_index, meal_name)] so callers can repair precisely.
    occurrences: dict[str, list[tuple[int, str]]] = defaultdict(list)
    allergens = {_norm(a) for a in (allergens or set()) if a and _norm(a) != "none"}

    days = (plan or {}).get("days")
    if not isinstance(days, list) or not days:
        return {
            "ok": False, "diet_violations": [], "allergen_violations": [],
            "repetition": [], "empty_meals": ["plan has no days"],
        }

    for di, day in enumerate(days):
        if not isinstance(day, dict):
            continue
        day_label = str(day.get("day") or f"Day {di + 1}")
        meals = day.get("meals")
        if not isinstance(meals, list):
            continue
        for meal in meals:
            if not isinstance(meal, dict):
                continue
            meal_name = str(meal.get("meal_name") or "Meal")
            foods = [str(f) for f in (meal.get("foods") or []) if f]
            if not foods:
                empty_meals.append(f"{day_label}/{meal_name}")
                continue
            for food_line in foods:
                bad = diet_violation(food_line, diet_key)
                if bad:
                    diet_violations.append({
                        "day": day_label, "day_index": di, "meal": meal_name,
                        "food": food_line, "matched": bad, "diet": diet_key,
                    })
                for allergen in allergens:
                    if re.search(rf"(?<![a-z]){re.escape(allergen)}(?![a-z])", _norm(food_line)):
                        allergen_violations.append({
                            "day": day_label, "day_index": di, "meal": meal_name,
                            "food": food_line, "matched": allergen,
                        })
            # Repetition is judged on the DISH, not the whole line: "Poha
            # (1 plate)" and "Poha (150 g)" are the same breakfast.
            anchor = dish_family(strip_serving_suffix(foods[0]))
            if anchor:
                occurrences[anchor].append((di, meal_name))

    repetition: list[dict[str, Any]] = []
    for dish, spots in occurrences.items():
        day_indexes = sorted({d for d, _ in spots})
        consecutive = any((b - a) == 1 for a, b in zip(day_indexes, day_indexes[1:]))
        if len(spots) > _MAX_DISH_REPEATS_PER_WEEK or consecutive:
            repetition.append({
                "dish": dish,
                "count": len(spots),
                "days": day_indexes,
                "consecutive": consecutive,
                "meals": sorted({m for _, m in spots}),
            })

    return {
        "ok": not (diet_violations or allergen_violations or repetition or empty_meals),
        "diet_violations": diet_violations,
        "allergen_violations": allergen_violations,
        "repetition": repetition,
        "empty_meals": empty_meals,
    }


_LIVING_STRING_TO_TAG: dict[str, str] = {
    "hostel": "Hostel", "academy": "Hostel", "pg": "PG", "paying guest": "PG",
    "home": "Home", "college": "College", "office": "Office", "travel": "Travel",
}


def living_tag_from_lifestyle(living_situation: str) -> str | None:
    norm = _norm(living_situation)
    for key, tag in _LIVING_STRING_TO_TAG.items():
        if key in norm:
            return tag
    return None


def budget_tier_from_lifestyle(daily_budget: str) -> str:
    nums = re.findall(r"\d+", str(daily_budget or ""))
    n = int(nums[0]) if nums else 150
    if n <= 80:
        return "Low"
    if n <= 200:
        return "Medium"
    return "High"


def format_food_line(food: dict) -> str:
    """'Poha (1 plate (200 g))' — the exact string shape the frontend's
    `foods: [...]` array has always used."""
    return f"{food['name']} ({food['serving_size']})"


# ── Lazy singleton — loaded once, shared by every request ──────────────────
_engine: FoodRecommendationEngine | None = None
_engine_lock = threading.Lock()


def get_engine() -> FoodRecommendationEngine:
    global _engine
    if _engine is None:
        with _engine_lock:
            if _engine is None:
                _engine = FoodRecommendationEngine()
    return _engine
