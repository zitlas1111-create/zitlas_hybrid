"""Diet personalization guarantees — dietary safety, variety, validation.

These are the regressions behind four real defects:

  1. A PURE VEGETARIAN was served eggs. Three independent causes:
     the assessment prompt's vegetarian rule listed "chicken, fish, meat,
     seafood" but never EGGS; `diet_tags_from_lifestyle` fell through to
     "no restriction" for any label its table did not literally contain
     (so "eggetarian" — the value both clients actually send — authorised
     meat, because the table's key is spelled "eggitarian"); and the
     dataset itself tags seven egg dishes as dietSuitable=Vegetarian.
  2. The same dish every day ("Sabudana Khichdi"), because the repetition
     cap counted food IDs while the dataset carries style variants of one
     dish, AND because the season filter excluded "All Season" foods and
     collapsed the vegetarian breakfast pool to 2 dish families.
  3. Stage 3's diet filter silently skipped itself when the pool came out
     empty, keeping non-vegetarian rows in a vegetarian's candidate set.
  4. TRANSFORMATION never asked for a target weight.

Run: python -m pytest tests/test_diet_personalization.py -q
"""

import json
from pathlib import Path

import pytest

from services import food_engine as fe

_DATASET = Path(__file__).resolve().parents[2] / "food_dataset" / "zitlas_food_database_enriched.json"


@pytest.fixture(scope="module")
def engine():
    return fe.get_engine()


@pytest.fixture(scope="module")
def dataset():
    return json.loads(_DATASET.read_text(encoding="utf-8"))


def _week(engine, diet_label, goal_tags=("Weight Loss",), goal_key="weight_loss"):
    return engine.build_week_plan(
        goal_tags=list(goal_tags),
        diet_tags=fe.diet_tags_from_lifestyle(diet_label),
        living_situation="Home",
        budget_tier="Medium",
        disease_tags=[],
        allergens=set(),
        favorite_foods=[],
        disliked_foods=[],
        daily_calorie_target=1800,
        profile=fe.load_profile(goal_key, "home"),
        subgoal_tag=None,
        season_tag=fe.current_season(),
    )


def _all_foods(week):
    return [f for d in week["days"] for m in d["meals"].values() for f in (m.get("primary") or [])]


def _families(week):
    return [fe.dish_family(fe.strip_serving_suffix(f["name"])) for f in _all_foods(week)]


# ── canonical dietary preference ──────────────────────────────────────────
class TestCanonicalDietKey:
    @pytest.mark.parametrize("sent,expected", [
        # The exact values Flutter and the website send today.
        ("vegetarian", fe.DIET_PURE_VEGETARIAN),
        ("non-vegetarian", fe.DIET_NON_VEGETARIAN),
        ("eggetarian", fe.DIET_EGGETARIAN),
        ("mixed", fe.DIET_NON_VEGETARIAN),
        # Spelling variants and prose labels.
        ("eggitarian", fe.DIET_EGGETARIAN),
        ("Pure Vegetarian", fe.DIET_PURE_VEGETARIAN),
        ("pure veg", fe.DIET_PURE_VEGETARIAN),
        ("vegan", fe.DIET_VEGAN),
        ("jain", fe.DIET_JAIN),
    ])
    def test_client_values_map_correctly(self, sent, expected):
        assert fe.canonical_diet_key(sent) == expected

    @pytest.mark.parametrize("junk", ["", None, "   ", "banana", "unknown-option"])
    def test_unknown_input_fails_closed(self, junk):
        """Unrecognized input must be the SAFEST option, never 'no restriction'.

        This is the bug that let eggs through: the old default returned
        ["Vegetarian", "Non Vegetarian"].
        """
        assert fe.canonical_diet_key(junk) == fe.DIET_PURE_VEGETARIAN
        assert "Non Vegetarian" not in fe.diet_tags_from_lifestyle(junk)

    def test_non_vegetarian_is_not_read_as_vegetarian(self):
        """'non-vegetarian' CONTAINS 'vegetarian' — order in the probe table
        is load-bearing and this pins it."""
        assert fe.canonical_diet_key("non-vegetarian") == fe.DIET_NON_VEGETARIAN

    def test_pure_vegetarian_tags_exclude_egg_tag(self):
        assert "Eggitarian" not in fe.diet_tags_from_lifestyle("vegetarian")


# ── keyword-level enforcement ─────────────────────────────────────────────
class TestDietViolation:
    @pytest.mark.parametrize("text", [
        "2 boiled eggs", "Egg Bhurji", "Bread Omelette", "Anda Curry",
        "Chicken Curry", "Fish Fry", "Mutton Biryani", "Prawn Masala",
    ])
    def test_pure_vegetarian_rejects_animal_foods(self, text):
        assert fe.diet_violation(text, fe.DIET_PURE_VEGETARIAN) is not None

    @pytest.mark.parametrize("text", [
        "Eggplant Curry", "Baingan Bharta", "Eggless Cake", "Paneer Bhurji",
        "Dal Tadka", "Poha", "Soya Chunks Curry", "Custard Apple",
    ])
    def test_pure_vegetarian_accepts_lookalikes(self, text):
        """`bhurji` is a scramble style (Paneer Bhurji is vegetarian),
        `eggplant`/`eggless`/`custard apple` merely contain a keyword."""
        assert fe.diet_violation(text, fe.DIET_PURE_VEGETARIAN) is None

    def test_eggetarian_allows_eggs_but_not_meat(self):
        assert fe.diet_violation("2 boiled eggs", fe.DIET_EGGETARIAN) is None
        assert fe.diet_violation("Chicken Tikka", fe.DIET_EGGETARIAN) is not None

    @pytest.mark.parametrize("text", ["Curd Rice", "Paneer Tikka", "Whey Protein", "Ghee Rice"])
    def test_vegan_rejects_dairy(self, text):
        assert fe.diet_violation(text, fe.DIET_VEGAN) is not None

    def test_non_vegetarian_forbids_nothing(self):
        assert fe.diet_violation("Chicken Curry", fe.DIET_NON_VEGETARIAN) is None


# ── the dataset is mislabelled; the name-level layer must catch it ────────
class TestDatasetBackstop:
    def test_dataset_really_does_mislabel_egg_dishes(self, dataset):
        """Guards the ASSUMPTION behind the name-level filter.

        If a future dataset fixes these tags this test fails loudly, telling us
        the backstop is no longer load-bearing rather than letting it rot.
        """
        veg_tagged_eggs = [
            f["name"] for f in dataset
            if "Vegetarian" in (f.get("dietSuitable") or [])
            and fe.diet_violation(f["name"], fe.DIET_PURE_VEGETARIAN)
        ]
        assert veg_tagged_eggs, "expected mislabelled rows (e.g. 'Bread Omelette')"

    @pytest.mark.parametrize("diet", ["vegetarian", "vegan", "eggetarian"])
    def test_engine_pool_has_zero_violations(self, engine, diet):
        """Mislabelled rows must be excluded at CANDIDATE-SELECTION time, not
        merely flagged afterwards."""
        key = fe.canonical_diet_key(diet)
        ids = engine._pipeline_ids(
            disease_tags=[], allergens=set(), diet_tags=fe.diet_tags_from_lifestyle(diet),
            goal_tags=["Weight Loss"], subgoal_tag=None,
            profile=fe.load_profile("weight_loss", "home"),
            budget_tier="Medium", living_tag="Home", meal_tag="Breakfast",
            season_tag=fe.current_season(),
        )
        offenders = [engine.by_id[i]["name"] for i in ids
                     if fe.food_violates_diet(engine.by_id[i], key)]
        assert offenders == []


# ── generated week plans ──────────────────────────────────────────────────
class TestGeneratedWeekPlan:
    @pytest.mark.parametrize("diet", ["vegetarian", "vegan", "eggetarian", "non-vegetarian"])
    def test_no_dietary_violations_anywhere(self, engine, diet):
        key = fe.canonical_diet_key(diet)
        bad = [(f["name"], fe.food_violates_diet(f, key))
               for f in _all_foods(_week(engine, diet))
               if fe.food_violates_diet(f, key)]
        assert bad == []

    def test_pure_vegetarian_never_gets_eggs(self, engine):
        """TEST 1 — the hard rule."""
        names = " | ".join(f["name"] for f in _all_foods(_week(engine, "vegetarian"))).lower()
        for banned in ("egg", "omelette", "anda", "chicken", "fish", "mutton", "prawn"):
            assert banned not in names, f"pure vegetarian plan contained {banned!r}"

    def test_vegan_gets_no_dairy_or_eggs(self, engine):
        """TEST 2."""
        names = " | ".join(f["name"] for f in _all_foods(_week(engine, "vegan"))).lower()
        for banned in ("egg", "chicken", "fish", "paneer", "curd", "ghee"):
            assert banned not in names, f"vegan plan contained {banned!r}"

    @pytest.mark.parametrize("diet", ["vegetarian", "vegan", "eggetarian"])
    def test_meaningful_variety(self, engine, diet):
        """TEST 3 — before the fix a week held 6 distinct dish families with
        one of them repeated 28 times out of ~58 plates.

        The bound is deliberately per-WEEK-total and generous (a week has ~58
        plates across 5 slots, and khichdi genuinely works as breakfast, lunch
        AND dinner in Indian cuisine, so demanding near-uniqueness would be
        fighting the cuisine rather than the bug). The strict guarantee lives
        in the per-slot tests below, which is where "the same thing every day"
        is actually experienced.
        """
        fams = _families(_week(engine, diet))
        distinct = set(fams)
        worst = max(fams.count(f) for f in distinct)
        assert len(distinct) >= 25, f"only {len(distinct)} distinct dishes in a week"
        assert worst <= 8, f"one dish family appears {worst} times in the week"

    def test_sabudana_is_not_the_default_vegetarian_meal(self, engine):
        """The specific reported symptom: khichdi may appear, it may not be
        the default. It previously took 25 of 58 plates and 6 of 7 breakfasts.
        """
        week = _week(engine, "vegetarian")
        fams = _families(week)
        breakfasts = [
            fe.strip_serving_suffix(
                (d["meals"].get("breakfast", {}).get("primary") or [{}])[0].get("name", ""))
            for d in week["days"]
        ]
        assert fams.count("khichdi") <= 8, f"khichdi still dominates: {fams.count('khichdi')}"
        assert breakfasts.count("Sabudana Khichdi") <= 1, \
            f"sabudana is still the default breakfast: {breakfasts}"
        assert len(set(breakfasts)) >= 6, f"breakfasts barely vary: {breakfasts}"

    def test_no_identical_breakfast_on_consecutive_days(self, engine):
        bf = [
            fe.dish_family(fe.strip_serving_suffix(
                (d["meals"].get("breakfast", {}).get("primary") or [{}])[0].get("name", "")))
            for d in _week(engine, "vegetarian")["days"]
        ]
        repeats = [(a, b) for a, b in zip(bf, bf[1:]) if a and a == b]
        assert repeats == [], f"identical breakfast on consecutive days: {repeats}"


# ── post-generation validator (LLM output) ────────────────────────────────
class TestDeliveredPlanAudit:
    def test_catches_eggs_in_pure_vegetarian_llm_plan(self):
        """The exact failure the user reported."""
        plan = {"days": [{"day": "Monday", "meals": [
            {"meal_name": "Breakfast", "foods": ["2 boiled eggs", "Toast"]}]}]}
        audit = fe.audit_delivered_plan(plan, fe.DIET_PURE_VEGETARIAN)
        assert audit["ok"] is False
        assert audit["diet_violations"][0]["food"] == "2 boiled eggs"

    def test_catches_excessive_and_consecutive_repetition(self):
        plan = {"days": [
            {"day": d, "meals": [{"meal_name": "Breakfast",
                                  "foods": ["Sabudana Khichdi (1 plate)"]}]}
            for d in ("Monday", "Tuesday", "Wednesday", "Thursday")
        ]}
        audit = fe.audit_delivered_plan(plan, fe.DIET_PURE_VEGETARIAN)
        assert audit["ok"] is False
        rep = audit["repetition"][0]
        assert rep["consecutive"] is True and rep["count"] == 4

    def test_catches_allergen(self):
        plan = {"days": [{"day": "Monday", "meals": [
            {"meal_name": "Snack", "foods": ["Peanut chikki"]}]}]}
        audit = fe.audit_delivered_plan(plan, fe.DIET_PURE_VEGETARIAN, allergens={"peanut"})
        assert [v["matched"] for v in audit["allergen_violations"]] == ["peanut"]

    def test_clean_plan_passes(self):
        plan = {"days": [
            {"day": "Monday", "meals": [{"meal_name": "Breakfast", "foods": ["Poha (1 plate)"]}]},
            {"day": "Tuesday", "meals": [{"meal_name": "Breakfast", "foods": ["Idli (3 pcs)"]}]},
        ]}
        assert fe.audit_delivered_plan(plan, fe.DIET_PURE_VEGETARIAN)["ok"] is True

    def test_empty_plan_is_not_ok(self):
        assert fe.audit_delivered_plan(None, fe.DIET_PURE_VEGETARIAN)["ok"] is False
        assert fe.audit_delivered_plan({"days": []}, fe.DIET_PURE_VEGETARIAN)["ok"] is False


# ── transformation goal ───────────────────────────────────────────────────
class TestTransformationTargetWeight:
    def test_transformation_question_set_asks_current_and_target_weight(self):
        """TEST 4 — both clients must ask. Parsed from source so the test
        fails if either question set regresses."""
        root = Path(__file__).resolve().parents[2]
        dart = (root / "mobile/lib/features/assessment/models/assessment_question.dart").read_text(encoding="utf-8")
        tf_dart = dart[dart.index("transformationQuestions ="):]
        assert "'weight_kg'" in tf_dart
        assert "'goal_weight_kg'" in tf_dart, "Flutter transformation set has no target weight"

        js = (root / "frontend/website/pages/dashboard/ai-coach/ai-coach.js").read_text(encoding="utf-8")
        tf_js = js[js.index("var TF_QUESTIONS = ["):js.index("if (state.selectedGoal === 'transformation')")]
        assert "'weight_kg'" in tf_js
        assert "'goal_weight_kg'" in tf_js, "website transformation set has no target weight"

    def test_transformation_forwards_the_answered_target(self):
        """Both clients previously overwrote the answer with current weight."""
        root = Path(__file__).resolve().parents[2]
        js = (root / "frontend/website/pages/dashboard/ai-coach/ai-coach.js").read_text(encoding="utf-8")
        assert "isTransformation\n        ? (a.goal_weight_kg" in js or \
               "? (a.goal_weight_kg || a.weight_kg" in js
