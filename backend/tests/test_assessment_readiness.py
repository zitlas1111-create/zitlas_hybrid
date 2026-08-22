"""
ZITLAS — readiness answers reach the workout plan (backend/tests/test_assessment_readiness.py)

tests/test_fitness_stage.py proves the RESOLVER is right. This file proves the
answers actually travel: client → `AssessmentInput` → `/analyze` → the level
the workout generator uses. A resolver nothing consults would be the same bug
the entitlement matrix had.

Run: python -m pytest tests/test_assessment_readiness.py -q
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import routes.assessment as assessment_routes            # noqa: E402
from services import fitness_stage as fs                 # noqa: E402
from services.assessment_service import AssessmentInput  # noqa: E402


BASE = {
    "age": 28, "gender": "male", "height_cm": 175, "weight_kg": 70,
    "goal_weight_kg": 65, "fitness_goal": "weight_loss",
}


@pytest.fixture
def client():
    app = FastAPI()
    app.include_router(assessment_routes.router, prefix="/api/assessment")
    return TestClient(app)


# ── The contract carries the answers ─────────────────────────────────────────

class TestTheContract:
    def test_the_new_fields_exist_and_are_optional(self):
        """Optional with a default is what makes existing users safe: a
        payload from a client that has never heard of these still validates."""
        model = AssessmentInput(**BASE)
        assert model.workout_experience == ""
        assert model.stair_ability == ""
        assert model.walk_ability == ""
        assert model.squat_ability == ""

    def test_the_answers_survive_validation(self):
        model = AssessmentInput(**BASE, workout_experience="novice",
                                stair_ability="okay", walk_ability="easy",
                                squat_ability="tired")
        assert model.workout_experience == "novice"
        assert model.stair_ability == "okay"
        assert model.walk_ability == "easy"
        assert model.squat_ability == "tired"


# ── End to end through the real endpoint ─────────────────────────────────────

class TestAnalyzeReturnsTheStartingLevel:
    def test_the_card_comes_back_with_the_assessment(self, client):
        res = client.post("/api/assessment/analyze", json={
            **BASE, "workout_experience": "beginner",
            "activity_level": "sedentary", "stair_ability": "difficult",
        })
        assert res.status_code == 200
        stage = res.json()["fitness_stage"]
        assert stage["level"] == fs.BEGINNER
        assert stage["title"] == "Beginner"
        assert stage["next"] == "Novice"
        assert stage["ladder"] == ["Beginner", "Novice", "Intermediate",
                                   "Advanced", "Legend"]

    def test_the_headline_case_end_to_end(self, client):
        """Claims advanced, cannot climb three floors, sedentary. The old
        code gave this athlete an ADVANCED plan because their BMI was 22.9."""
        res = client.post("/api/assessment/analyze", json={
            **BASE, "workout_experience": "advanced",
            "activity_level": "sedentary",
            "stair_ability": "difficult", "squat_ability": "difficult",
        })
        assert res.json()["fitness_stage"]["level"] == fs.BEGINNER

    def test_a_genuinely_advanced_athlete_is_not_held_back(self, client):
        res = client.post("/api/assessment/analyze", json={
            **BASE, "workout_experience": "advanced", "activity_level": "active",
            "stair_ability": "easy", "walk_ability": "easy",
            "squat_ability": "easy",
        })
        assert res.json()["fitness_stage"]["level"] == fs.ADVANCED

    def test_an_existing_user_payload_still_works(self, client):
        """No readiness answers at all — the shape every current client sends.

        THE TRAP THIS CATCHES: `fitness_level` carries a schema default of
        "beginner". Reading it on a flow that never asks it turned an
        unanswered field into a claim of "I'm completely new", which would
        have quietly re-levelled every existing Weight Loss athlete DOWN on
        their next plan. Only General Fitness asks it, so only General
        Fitness reads it.
        """
        res = client.post("/api/assessment/analyze", json=BASE)
        assert res.status_code == 200
        body = res.json()
        assert body["fitness_stage"]["level"] == fs.INTERMEDIATE, (
            "an existing athlete with no readiness answers must resolve from "
            "BMI exactly as before, not be demoted to beginner")
        # And the rest of the assessment is untouched.
        assert body["calculations"]["bmi"] > 0
        assert body["calculations"]["tdee_kcal"] > 0
        assert body["swot"]["user_archetype"]

    def test_the_diet_side_is_unaffected_by_readiness(self, client):
        """Calories and protein come from the nutrition engine, which these
        answers must not touch."""
        without = client.post("/api/assessment/analyze", json=BASE).json()
        with_answers = client.post("/api/assessment/analyze", json={
            **BASE, "workout_experience": "advanced", "stair_ability": "easy",
        }).json()

        for key in ("tdee_kcal", "weight_loss_calories_kcal",
                    "protein_target_g", "bmi"):
            assert without["calculations"][key] == with_answers["calculations"][key], key


# ── The resolver is what the generator consults ──────────────────────────────

class TestTheGeneratorUsesIt:
    def test_the_route_helper_resolves_from_the_payload(self):
        model = AssessmentInput(**BASE, workout_experience="advanced",
                                activity_level="sedentary",
                                stair_ability="difficult")
        assert assessment_routes._resolved_level(model) == fs.BEGINNER

    def test_bmi_no_longer_decides_the_level_on_its_own(self):
        """BMI 22.9 used to mean ADVANCED regardless of ability."""
        model = AssessmentInput(**BASE, workout_experience="beginner",
                                activity_level="sedentary",
                                stair_ability="difficult")
        assert assessment_routes._resolved_level(model, 22.9) == fs.BEGINNER

    def test_a_high_bmi_still_forces_a_conservative_start(self):
        """Joint loading really is a function of bodyweight, so this floor
        stays — a confident claim must not lift it."""
        model = AssessmentInput(
            age=28, gender="male", height_cm=170, weight_kg=110,
            goal_weight_kg=85, fitness_goal="weight_loss",
            workout_experience="advanced", stair_ability="easy",
        )
        level = assessment_routes._resolved_level(model, 38.0)
        assert fs.LADDER.index(level) <= fs.LADDER.index(fs.INTERMEDIATE)

    def test_general_fitness_uses_its_existing_question_as_the_claim(self):
        """`fitness_level` is General Fitness's own question — it is read as
        the claim, which is why no second experience question was added
        there."""
        model = AssessmentInput(
            age=28, gender="male", height_cm=175, weight_kg=70,
            fitness_goal="general_fitness", fitness_level="advanced",
            activity_level="sedentary", stair_ability="difficult",
        )
        assert assessment_routes._resolved_level(model) == fs.BEGINNER
