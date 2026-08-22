"""
ZITLAS — starting fitness level (backend/tests/test_fitness_stage.py)

    BEGINNER → NOVICE → INTERMEDIATE → ADVANCED → LEGEND

THE BUG THIS EXISTS TO PREVENT. Weight Loss and Muscle Gain never asked for a
fitness level, so routes/assessment.py derived one from BMI alone — and
anything under BMI 25 came out ADVANCED. A sedentary athlete who cannot climb
three floors was handed jump squats and interval cardio because they happened
to be slim. BMI describes a body; it says nothing about what that body can
currently do.

THE RULE BEING PINNED. A CLAIM is capped by DEMONSTRATED ABILITY, and ability
can lift somebody slightly above what they claim. Nobody is diagnosed, nothing
is scored, and an athlete who answered none of the new questions resolves
exactly as they did before — which is what keeps existing users' plans intact.

Run: python -m pytest tests/test_fitness_stage.py -q
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import fitness_stage as fs                 # noqa: E402


# ── The four validation users from the spec ──────────────────────────────────

class TestTheFourUsers:
    def test_user_a_completely_new_low_activity_struggles(self):
        """Expected: BEGINNER."""
        assert fs.resolve_stage(
            workout_experience="beginner",
            activity_level="sedentary",
            stair_ability="difficult",
            walk_ability="tired",
        ) == fs.BEGINNER

    def test_user_b_some_experience_moderately_active_handles_basics(self):
        """Expected: NOVICE or INTERMEDIATE."""
        level = fs.resolve_stage(
            workout_experience="novice",
            activity_level="moderate",
            stair_ability="okay",
            walk_ability="easy",
        )
        assert level in (fs.NOVICE, fs.INTERMEDIATE)

    def test_user_c_regular_training_strong_ability(self):
        """Expected: INTERMEDIATE or ADVANCED."""
        level = fs.resolve_stage(
            workout_experience="intermediate",
            activity_level="active",
            stair_ability="easy",
            squat_ability="easy",
        )
        assert level in (fs.INTERMEDIATE, fs.ADVANCED)

    def test_user_d_advanced_history_high_activity_strong_ability(self):
        """Expected: ADVANCED."""
        assert fs.resolve_stage(
            workout_experience="advanced",
            activity_level="active",
            stair_ability="easy",
            walk_ability="easy",
            squat_ability="easy",
        ) == fs.ADVANCED


# ── The claim is not the answer ──────────────────────────────────────────────

class TestClaimsAreCappedByAbility:
    def test_a_claimed_advanced_who_struggles_starts_at_beginner(self):
        """The spec's headline case: says "advanced", struggles with three
        floors, rarely exercises, struggles with squats."""
        assert fs.resolve_stage(
            workout_experience="advanced",
            activity_level="sedentary",
            stair_ability="difficult",
            squat_ability="difficult",
        ) == fs.BEGINNER

    def test_a_claimed_advanced_with_middling_ability_is_capped_too(self):
        level = fs.resolve_stage(
            workout_experience="advanced",
            activity_level="light",
            stair_ability="tired",
            walk_ability="tired",
        )
        assert fs.LADDER.index(level) <= fs.LADDER.index(fs.NOVICE)

    def test_ability_also_lifts_a_modest_claim(self):
        """A beginner who finds everything easy is not incapable, and
        treating them as such is its own kind of wrong."""
        level = fs.resolve_stage(
            workout_experience="beginner",
            activity_level="moderate",
            stair_ability="easy",
            walk_ability="easy",
        )
        assert fs.LADDER.index(level) > fs.LADDER.index(fs.BEGINNER)

    def test_ability_lifts_by_at_most_one_rung(self):
        """Self-reported ease is weak evidence — it must not vault somebody
        from complete beginner to advanced."""
        level = fs.resolve_stage(
            workout_experience="beginner",
            activity_level="active",
            stair_ability="easy",
            walk_ability="easy",
            squat_ability="easy",
        )
        assert fs.LADDER.index(level) <= fs.LADDER.index(fs.NOVICE)

    def test_two_sedentary_users_are_told_apart(self):
        """The whole reason these questions were added: activity level alone
        could not distinguish User A from User B."""
        capable = fs.resolve_stage(
            workout_experience="novice", activity_level="sedentary",
            stair_ability="easy", walk_ability="easy")
        struggling = fs.resolve_stage(
            workout_experience="novice", activity_level="sedentary",
            stair_ability="difficult", walk_ability="difficult")
        assert fs.LADDER.index(capable) > fs.LADDER.index(struggling)


# ── Safety ───────────────────────────────────────────────────────────────────

class TestSafety:
    def test_a_medical_restriction_lowers_and_never_raises(self):
        restricted = fs.resolve_stage(
            workout_experience="advanced", activity_level="active",
            stair_ability="easy", squat_ability="easy",
            medical_restricted=True)
        assert fs.LADDER.index(restricted) <= fs.LADDER.index(fs.NOVICE)

    def test_a_medical_restriction_cannot_be_overridden_by_confidence(self):
        assert fs.resolve_stage(
            workout_experience="advanced", stair_ability="easy",
            medical_restricted=True,
        ) != fs.ADVANCED

    def test_an_assessment_can_never_produce_legend(self):
        """Legend is earned over time. Handing it to somebody for clicking
        "I train a lot" would make the whole ladder meaningless."""
        assert fs.resolve_stage(
            workout_experience="advanced", activity_level="active",
            stair_ability="easy", walk_ability="easy", squat_ability="easy",
        ) != fs.LEGEND

    def test_bmi_alone_never_yields_advanced(self):
        """The old behaviour: BMI < 25 -> Advanced. A slim body is not a
        trained one."""
        for bmi in (18.0, 22.0, 24.9):
            assert fs.resolve_stage(bmi=bmi) != fs.ADVANCED


# ── Existing users ───────────────────────────────────────────────────────────

class TestExistingUsers:
    def test_no_new_answers_falls_back_to_the_previous_behaviour(self):
        """An athlete assessed before these questions existed. Their level
        must not move, or their plan silently changes under them."""
        assert fs.resolve_stage(bmi=32.0) == fs.BEGINNER
        assert fs.resolve_stage(bmi=27.0) == fs.INTERMEDIATE

    def test_empty_strings_are_treated_as_no_signal_not_as_a_low_score(self):
        with_nothing = fs.resolve_stage(
            workout_experience="", stair_ability="", walk_ability="",
            squat_ability="", activity_level="", bmi=22.0)
        assert with_nothing == fs.resolve_stage(bmi=22.0)

    def test_an_unrecognised_answer_contributes_nothing(self):
        """A future option value, or a client sending something odd, must not
        swing the result in either direction."""
        assert fs.resolve_stage(
            workout_experience="intermediate", stair_ability="banana",
        ) == fs.resolve_stage(workout_experience="intermediate")

    def test_a_partial_answer_set_still_resolves(self):
        """Each goal asks a different subset — the resolver must not need all
        three practical answers."""
        assert fs.resolve_stage(
            workout_experience="intermediate", stair_ability="easy",
        ) in fs.LADDER


# ── The ladder and its copy ──────────────────────────────────────────────────

class TestTheLadder:
    def test_the_five_levels_are_in_order(self):
        assert fs.LADDER == ["beginner", "novice", "intermediate",
                             "advanced", "legend"]

    @pytest.mark.parametrize("level,expected", [
        (fs.BEGINNER, fs.NOVICE),
        (fs.NOVICE, fs.INTERMEDIATE),
        (fs.INTERMEDIATE, fs.ADVANCED),
        (fs.ADVANCED, fs.LEGEND),
        (fs.LEGEND, None),
    ])
    def test_next_level(self, level, expected):
        assert fs.next_level(level) == expected

    def test_describe_gives_the_card_everything_it_needs(self):
        card = fs.describe(fs.BEGINNER)
        assert card["title"] == "Beginner"
        assert card["emoji"]
        assert card["next"] == "Novice"
        assert card["position"] == 0
        assert len(card["ladder"]) == 5

    def test_the_copy_is_encouraging_not_clinical(self):
        """A starting level is a starting point, not a verdict."""
        blurb = fs.describe(fs.BEGINNER)["blurb"].lower()
        assert "completely fine" in blurb
        for word in ("deficient", "poor", "unfit", "failure", "score"):
            assert word not in blurb

    def test_describe_survives_an_unknown_level(self):
        assert fs.describe("")["title"] == "Beginner"
        assert fs.describe("nonsense")["title"] == "Beginner"
