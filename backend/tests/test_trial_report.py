"""
ZITLAS — Trial Completion Report computation tests
(backend/tests/test_trial_report.py)

Exercises the REAL services/trial_report_service.py. The pure calculation
helpers are tested against plain dicts with no Firestore at all; the
orchestrator is tested against tests/fake_firestore.py's in-process fake,
same harness and posture as test_coaching.py and test_expert_ratings.py.

THE PROPERTY THESE TESTS EXIST TO PROTECT is that the report never
fabricates precision. Several tests below assert that a value is None —
those are the important ones. A future change that starts returning a
plausible-looking number where the data does not support one should break
this suite, because that is the failure this whole module was built to
prevent.
"""

from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from services import firestore_service  # noqa: E402
from services import trial_report_service as trs  # noqa: E402
from tests.fake_firestore import FakeClient  # noqa: E402

ATHLETE = "athlete_1"
COACH = "coach_1"
ENGAGEMENT = "req_trial_abc"

# A fixed 10-day window: Mon 2026-03-02 .. Wed 2026-03-11.
START = datetime(2026, 3, 2, 9, 0, tzinfo=timezone.utc)
END = datetime(2026, 3, 12, 9, 0, tzinfo=timezone.utc)
NOW = datetime(2026, 3, 12, 10, 0, tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _checkin(day_offset: int, *, meal_type="breakfast", status="pending",
             overall=None, score=None, reaction=None, reviewed=False):
    """One meal_checkins document, shaped exactly as diet.js writes it."""
    ts = START + timedelta(days=day_offset, hours=1)
    return {
        "checkinId": f"MCI_{day_offset}_{meal_type}",
        "athleteId": ATHLETE,
        "coachId": COACH,
        # Deliberately a weekday NAME, as production stores it — any test
        # that passed while the code bucketed on this field would be lying.
        "day": ts.strftime("%A"),
        "mealType": meal_type,
        "mealName": meal_type.title(),
        "timestamp": _iso(ts),
        "status": status,
        "overallRating": overall,
        "score": score,
        "reaction": reaction,
        "reviewedAt": _iso(ts + timedelta(hours=2)) if reviewed else None,
        "reviewedBy": "Coach Test" if reviewed else None,
    }


def _plan(meals_per_day=3, days=None):
    """A coaching_plans `diet` value — weekly template keyed by weekday."""
    names = days or ["Monday", "Tuesday", "Wednesday", "Thursday",
                     "Friday", "Saturday", "Sunday"]
    return {
        "days": [
            {"day": name,
             "meals": [{"id": f"m{i}", "name": f"Meal {i}", "options": []}
                       for i in range(meals_per_day)]}
            for name in names
        ]
    }


# ══════════════════════════════════════════════════════════════════════════
# parse_iso / date_keys — the date plumbing everything else rests on
# ══════════════════════════════════════════════════════════════════════════


class TestDateHandling:
    def test_parses_z_suffix_and_offset_alike(self):
        z = trs.parse_iso("2026-03-02T09:00:00Z")
        offset = trs.parse_iso("2026-03-02T14:30:00+05:30")
        assert z == offset

    def test_naive_string_is_treated_as_utc(self):
        assert trs.parse_iso("2026-03-02T09:00:00") == START

    def test_naive_datetime_is_made_aware(self):
        naive = datetime(2026, 3, 2, 9, 0)
        assert trs.parse_iso(naive) == START

    @pytest.mark.parametrize("bad", [None, "", "   ", "not-a-date", 42, {}])
    def test_unparseable_returns_none_rather_than_raising(self, bad):
        assert trs.parse_iso(bad) is None

    def test_date_keys_are_inclusive_of_both_ends(self):
        keys = trs.date_keys(START, START + timedelta(days=2))
        assert keys == ["2026-03-02", "2026-03-03", "2026-03-04"]

    def test_date_keys_single_day_window(self):
        assert trs.date_keys(START, START + timedelta(hours=3)) == ["2026-03-02"]

    def test_date_keys_reversed_window_is_empty_not_negative(self):
        assert trs.date_keys(END, START) == []

    def test_window_membership_is_inclusive_at_both_boundaries(self):
        assert trs._in_window(_iso(START), START, END) is True
        assert trs._in_window(_iso(END), START, END) is True
        assert trs._in_window(_iso(START - timedelta(seconds=1)), START, END) is False
        assert trs._in_window(_iso(END + timedelta(seconds=1)), START, END) is False

    def test_day_key_comes_from_timestamp_not_the_weekday_name_field(self):
        # Two check-ins a week apart both say "Monday" — bucketing on `day`
        # would collapse them into one, which is the bug this guards.
        first = _checkin(0)
        second = _checkin(7)
        assert first["day"] == second["day"] == "Monday"
        assert trs._checkin_day_key(first) != trs._checkin_day_key(second)

    def test_utc_boundary_late_night_checkin_lands_on_its_utc_day(self):
        late = {"timestamp": "2026-03-02T23:59:00Z"}
        just_after = {"timestamp": "2026-03-03T00:01:00Z"}
        assert trs._checkin_day_key(late) == "2026-03-02"
        assert trs._checkin_day_key(just_after) == "2026-03-03"

    def test_offset_timestamp_is_bucketed_by_its_utc_instant(self):
        # 2026-03-03T04:00+05:30 is 2026-03-02T22:30Z — the UTC day.
        assert trs._checkin_day_key(
            {"timestamp": "2026-03-03T04:00:00+05:30"}) == "2026-03-02"


# ══════════════════════════════════════════════════════════════════════════
# Expected meals — the denominator that must never be invented
# ══════════════════════════════════════════════════════════════════════════


class TestExpectedMeals:
    def test_reads_meal_counts_per_weekday(self):
        assert trs.expected_meals_by_weekday(_plan(3)) == {
            name: 3 for name in
            ["monday", "tuesday", "wednesday", "thursday",
             "friday", "saturday", "sunday"]
        }

    def test_per_weekday_counts_may_differ(self):
        plan = {"days": [
            {"day": "Monday", "meals": [{}, {}, {}, {}]},
            {"day": "Sunday", "meals": [{}, {}]},
        ]}
        assert trs.expected_meals_by_weekday(plan) == {"monday": 4, "sunday": 2}

    def test_empty_days_are_omitted_not_counted_as_zero(self):
        plan = {"days": [{"day": "Monday", "meals": []},
                         {"day": "Tuesday", "meals": [{}]}]}
        assert trs.expected_meals_by_weekday(plan) == {"tuesday": 1}

    def test_unknown_weekday_labels_are_ignored(self):
        plan = {"days": [{"day": "Day 1", "meals": [{}, {}]},
                         {"day": "Monday", "meals": [{}]}]}
        assert trs.expected_meals_by_weekday(plan) == {"monday": 1}

    @pytest.mark.parametrize("bad", [None, {}, {"days": None}, {"days": "x"}, 7])
    def test_malformed_plans_yield_no_expectation(self, bad):
        assert trs.expected_meals_by_weekday(bad) == {}


# ══════════════════════════════════════════════════════════════════════════
# Meal follow-through
# ══════════════════════════════════════════════════════════════════════════


def _one_segment(meals_by_weekday, *, source=trs.SOURCE_AI,
                 start=START, end=END):
    """A single-plan timeline — the shape these helpers saw before the
    Step 2.5 plan-version correction, so each calculation stays isolated."""
    return [trs.PlanSegment(
        effective_from=start, effective_to=end,
        meals_by_weekday=meals_by_weekday, source=source)]


class TestEngagementSlots:
    """§3 — elapsed 24-hour slots, not calendar dates."""

    def test_ten_day_trial_is_exactly_ten_slots(self):
        slots = trs.engagement_slots(START, START + timedelta(days=10))
        assert len(slots) == 10
        assert [s.index for s in slots] == list(range(1, 11))

    def test_no_eleventh_calendar_day(self):
        # The regression this model exists to kill: 09:00 -> 09:00 over ten
        # days touches ELEVEN calendar dates but is only TEN engagement days.
        start, end = START, START + timedelta(days=10)
        assert len(trs.date_keys(start, end)) == 11
        assert len(trs.engagement_slots(start, end)) == 10

    def test_slot_boundaries_are_exact_24h(self):
        slots = trs.engagement_slots(START, START + timedelta(days=3))
        assert slots[0].start == START
        assert slots[0].end == START + timedelta(days=1)
        assert slots[1].start == START + timedelta(days=1)
        assert slots[2].end == START + timedelta(days=3)
        assert all(not s.partial for s in slots)

    def test_early_end_produces_a_partial_final_slot(self):
        slots = trs.engagement_slots(START, START + timedelta(days=2, hours=6))
        assert len(slots) == 3
        assert slots[2].partial is True
        assert slots[2].end == START + timedelta(days=2, hours=6)

    def test_zero_or_negative_window_has_no_slots(self):
        assert trs.engagement_slots(START, START) == []
        assert trs.engagement_slots(START + timedelta(days=1), START) == []

    def test_start_boundary_belongs_to_slot_one(self):
        slots = trs.engagement_slots(START, START + timedelta(days=3))
        assert trs.slot_for(slots, START).index == 1

    def test_exact_internal_boundary_belongs_to_the_later_slot(self):
        slots = trs.engagement_slots(START, START + timedelta(days=3))
        assert trs.slot_for(slots, START + timedelta(days=1)).index == 2

    def test_end_boundary_belongs_to_the_final_slot_not_nothing(self):
        end = START + timedelta(days=3)
        slots = trs.engagement_slots(START, end)
        assert trs.slot_for(slots, end).index == 3

    def test_moments_outside_the_engagement_have_no_slot(self):
        slots = trs.engagement_slots(START, START + timedelta(days=3))
        assert trs.slot_for(slots, START - timedelta(seconds=1)) is None
        assert trs.slot_for(slots, START + timedelta(days=3, seconds=1)) is None

    def test_every_checkin_falls_in_exactly_one_slot(self):
        slots = trs.engagement_slots(START, START + timedelta(days=10))
        for hours in range(0, 240, 7):
            moment = START + timedelta(hours=hours)
            hits = [s for s in slots if s.start <= moment < s.end]
            assert len(hits) == 1, f"{moment} matched {len(hits)} slots"


def _slots(days=3, start=START):
    return trs.engagement_slots(start, start + timedelta(days=days))


class TestMealFollowThrough:
    def test_normal_case(self):
        checkins = [_checkin(0), _checkin(0, meal_type="lunch"), _checkin(1)]
        result = trs.compute_meal_follow_through(
            checkins, slots=_slots(3),
            timeline=_one_segment({"monday": 2, "tuesday": 2, "wednesday": 2}))
        assert result["available"] is True
        assert result["submitted"] == 3
        assert result["expected"] == 6
        assert result["percent"] == 50.0
        assert result["daysActive"] == 2
        assert result["engagementSlots"] == 3

    def test_zero_submitted_meals_is_zero_percent_not_unavailable(self):
        result = trs.compute_meal_follow_through(
            [], slots=_slots(3), timeline=_one_segment({"monday": 3}))
        assert result["available"] is True
        assert result["submitted"] == 0
        assert result["percent"] == 0.0
        assert result["daysActive"] == 0

    def test_submitted_exceeding_expected_clamps_to_100_but_flags_it(self):
        checkins = [_checkin(0, meal_type=f"m{i}") for i in range(9)]
        result = trs.compute_meal_follow_through(
            checkins, slots=_slots(1), timeline=_one_segment({"monday": 3}))
        assert result["percent"] == 100.0
        assert result["submittedExceedsExpected"] is True
        assert result["submitted"] == 9  # raw fact preserved

    def test_no_expected_meals_refuses_to_assume_a_denominator(self):
        result = trs.compute_meal_follow_through(
            [_checkin(0)], slots=_slots(3), timeline=_one_segment({}))
        assert result["available"] is False
        assert result["reason"] == "expected_meals_unavailable"
        assert result["expected"] is None
        assert result["percent"] is None
        # The numerator is still real and still reported.
        assert result["submitted"] == 1

    def test_never_defaults_to_four_meals_a_day(self):
        # The Flutter model's hardcoded default must NOT be reproduced here.
        result = trs.compute_meal_follow_through(
            [], slots=_slots(10), timeline=_one_segment({}))
        assert result["expected"] is None
        assert result["expected"] != 40

    def test_empty_timeline_yields_unavailable(self):
        result = trs.compute_meal_follow_through(
            [_checkin(0)], slots=_slots(3), timeline=[])
        assert result["available"] is False
        assert result["reason"] == "expected_meals_unavailable"

    def test_partial_weekday_coverage_is_reported(self):
        # Plan covers Monday only; window is Mon/Tue/Wed.
        result = trs.compute_meal_follow_through(
            [_checkin(0)], slots=_slots(3),
            timeline=_one_segment({"monday": 2}))
        assert result["expected"] == 2
        assert result["daysWithoutPlannedMeals"] == 2

    def test_days_active_counts_distinct_slots_not_meals(self):
        checkins = [_checkin(0, meal_type="breakfast"),
                    _checkin(0, meal_type="lunch"),
                    _checkin(0, meal_type="dinner")]
        result = trs.compute_meal_follow_through(
            checkins, slots=_slots(3),
            timeline=_one_segment({"monday": 3, "tuesday": 3, "wednesday": 3}))
        assert result["daysActive"] == 1

    def test_empty_window_yields_unavailable(self):
        result = trs.compute_meal_follow_through(
            [], slots=[], timeline=_one_segment({"monday": 3}))
        assert result["available"] is False

    def test_expected_is_attributed_to_the_plan_source(self):
        result = trs.compute_meal_follow_through(
            [], slots=_slots(2),
            timeline=_one_segment({"monday": 3, "tuesday": 3},
                                  source=trs.SOURCE_COACH))
        assert result["expectedBySource"] == {trs.SOURCE_COACH: 6}

    def test_ten_day_trial_denominator_is_ten_days_not_eleven(self):
        # 3 meals/day for a 10-day trial must be 30, never 33.
        meals = {d: 3 for d in ["monday", "tuesday", "wednesday", "thursday",
                                "friday", "saturday", "sunday"]}
        result = trs.compute_meal_follow_through(
            [], slots=trs.engagement_slots(START, START + timedelta(days=10)),
            timeline=_one_segment(meals))
        assert result["expected"] == 30
        assert result["engagementSlots"] == 10

    def test_partial_final_slot_is_charged_and_disclosed(self):
        result = trs.compute_meal_follow_through(
            [], slots=trs.engagement_slots(
                START, START + timedelta(days=2, hours=6)),
            timeline=_one_segment({"monday": 3, "tuesday": 3, "wednesday": 3}))
        assert result["engagementSlots"] == 3
        assert result["expected"] == 9      # the partial day counts in full
        assert result["partialSlots"] == 1

    def test_a_checkin_at_the_exact_end_instant_still_counts_as_active(self):
        end = START + timedelta(days=3)
        checkin = {"timestamp": _iso(end)}
        result = trs.compute_meal_follow_through(
            [checkin], slots=trs.engagement_slots(START, end),
            timeline=_one_segment({"monday": 1, "tuesday": 1, "wednesday": 1}))
        assert result["daysActive"] == 1

    def test_plan_version_change_at_an_exact_slot_boundary(self):
        # A coach save landing exactly on a slot boundary applies to THAT
        # slot onward, never retroactively.
        boundary = START + timedelta(days=2)
        timeline = [
            trs.PlanSegment(effective_from=START, effective_to=boundary,
                            meals_by_weekday={"monday": 2, "tuesday": 2,
                                              "wednesday": 2},
                            source=trs.SOURCE_AI),
            trs.PlanSegment(effective_from=boundary,
                            effective_to=START + timedelta(days=4),
                            meals_by_weekday={"monday": 5, "tuesday": 5,
                                              "wednesday": 5, "thursday": 5},
                            source=trs.SOURCE_COACH),
        ]
        result = trs.compute_meal_follow_through(
            [], slots=_slots(4), timeline=timeline)
        assert result["expectedBySource"] == {
            trs.SOURCE_AI: 4,       # slots 1-2 at 2 meals
            trs.SOURCE_COACH: 10,   # slots 3-4 at 5 meals
        }


# ══════════════════════════════════════════════════════════════════════════
# Meal quality
# ══════════════════════════════════════════════════════════════════════════


class TestAiPlanIdentification:
    """The AI plan is positional (index 0 == Monday), not weekday-labelled."""

    def test_reads_meals_per_weekday_from_a_seven_day_ai_plan(self):
        ai = {"days": [{"meals": [{}] * (i + 1)} for i in range(7)]}
        result = trs.meals_by_weekday_from_ai_plan(ai)
        assert result["monday"] == 1     # index 0 == Monday, per diet.js
        assert result["sunday"] == 7

    def test_short_ai_plan_cycles_like_dietfromaiplan_does(self):
        ai = {"days": [{"meals": [{}, {}]}, {"meals": [{}, {}, {}]}]}
        result = trs.meals_by_weekday_from_ai_plan(ai)
        assert result["monday"] == 2      # index 0
        assert result["tuesday"] == 3     # index 1
        assert result["wednesday"] == 2   # index 2 -> cycles back to 0
        assert result["sunday"] == 2      # index 6 -> 6 % 2 == 0

    def test_unwraps_the_expert_review_schema(self):
        wrapped = {"originalDietPlan": {"days": [{"meals": [{}, {}]}]},
                   "currentDietPlan": {"days": [{"meals": [{}, {}, {}, {}]}]}}
        # currentDietPlan wins, exactly as _normalizeAthleteDoc does.
        assert trs.meals_by_weekday_from_ai_plan(wrapped)["monday"] == 4

    @pytest.mark.parametrize("bad", [None, {}, {"days": []}, {"days": "x"}, 5])
    def test_malformed_ai_plans_yield_nothing(self, bad):
        assert trs.meals_by_weekday_from_ai_plan(bad) == {}

    def test_ai_and_coach_shapes_are_distinguished_by_shape(self):
        coach = _plan(3)                                  # weekday-labelled
        ai = {"days": [{"meals": [{}, {}]} for _ in range(7)]}  # positional
        assert trs._plan_shape_meals(coach)["monday"] == 3
        assert trs._plan_shape_meals(ai)["monday"] == 2


def _version(day_offset, *, meals=3, vtype="diet", version=1,
             saved_by="Coach Test", plan_id="plan_A", data=None):
    saved = START + timedelta(days=day_offset)
    return {
        "type": vtype,
        "version": version,
        "savedAt": _iso(saved),
        "savedBy": saved_by,
        "data": data if data is not None else {
            "planId": plan_id,
            "days": [{"day": name, "meals": [{"id": f"m{i}"}
                                             for i in range(meals)]}
                     for name in ["Monday", "Tuesday", "Wednesday", "Thursday",
                                  "Friday", "Saturday", "Sunday"]],
        },
    }


class TestPlanTimeline:
    AI = {"days": [{"meals": [{}, {}, {}, {}]} for _ in range(7)]}  # 4 meals

    def test_no_coach_versions_means_the_whole_period_is_the_ai_plan(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[])
        assert len(timeline) == 1
        assert timeline[0].source == trs.SOURCE_AI
        assert timeline[0].meals_by_weekday["monday"] == 4

    def test_ai_segment_ends_at_the_first_coach_save(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(3, meals=5)])
        assert len(timeline) == 2
        assert timeline[0].source == trs.SOURCE_AI
        assert timeline[0].effective_to == START + timedelta(days=3)
        assert timeline[1].source == trs.SOURCE_COACH
        assert timeline[1].meals_by_weekday["monday"] == 5

    def test_the_prompt_scenario_day1_ai_day4_v1_day7_v2(self):
        # Day 1-3 AI (4 meals), day 4-6 coach v1 (5), day 7+ coach v2 (6).
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(3, meals=5, version=1),
                            _version(6, meals=6, version=2)])
        assert [s.source for s in timeline] == [
            trs.SOURCE_AI, trs.SOURCE_COACH, trs.SOURCE_COACH]
        assert trs.segment_for(
            timeline, START + timedelta(days=1)).meals_by_weekday["monday"] == 4
        assert trs.segment_for(
            timeline, START + timedelta(days=4)).meals_by_weekday["monday"] == 5
        assert trs.segment_for(
            timeline, START + timedelta(days=8)).meals_by_weekday["monday"] == 6

    def test_versions_are_ordered_by_savedat_not_input_order(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(6, meals=6, version=2),
                            _version(3, meals=5, version=1)])
        assert [s.version for s in timeline if s.version] == [1, 2]

    def test_training_versions_are_ignored(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(3, vtype="training", meals=9)])
        assert len(timeline) == 1
        assert timeline[0].source == trs.SOURCE_AI

    def test_versions_without_a_parseable_savedat_are_dropped(self):
        broken = _version(3)
        broken["savedAt"] = "not-a-date"
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[broken])
        assert len(timeline) == 1
        assert timeline[0].source == trs.SOURCE_AI

    def test_regenerated_ai_plan_invalidates_the_ai_segment(self):
        # The athlete regenerated their plan since the coach's save, so the
        # live dietPlan is NOT what applied then — no expectation is guessed.
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_B_NEWER",
            coach_versions=[_version(3, plan_id="plan_A")])
        ai_segment = timeline[0]
        assert ai_segment.source == trs.SOURCE_AI
        assert ai_segment.meals_by_weekday == {}
        assert ai_segment.available is False

    def test_matching_planid_keeps_the_ai_segment_usable(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(3, plan_id="plan_A")])
        assert timeline[0].available is True

    def test_missing_ai_planid_leaves_the_ai_segment_unusable(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id=None,
            coach_versions=[])
        assert timeline[0].available is False

    def test_version_saved_before_the_engagement_covers_from_the_start(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(-5, meals=5)])
        assert len(timeline) == 1
        assert timeline[0].source == trs.SOURCE_COACH
        assert timeline[0].effective_from == START

    def test_versions_saved_after_the_engagement_are_excluded(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=self.AI, ai_plan_id="plan_A",
            coach_versions=[_version(30, meals=9)])
        assert len(timeline) == 1
        assert timeline[0].source == trs.SOURCE_AI

    def test_blank_template_plan_is_labelled_differently(self):
        timeline = trs.build_plan_timeline(
            start=START, end=END, ai_plan=None, ai_plan_id=None,
            coach_versions=[_version(2, meals=4, data={
                "days": [{"day": "Monday", "meals": [{}, {}, {}, {}]}]})])
        coach = [s for s in timeline if s.source != trs.SOURCE_AI][0]
        assert coach.source == trs.SOURCE_COACH_TEMPLATE


class TestCoachModifications:
    def test_counts_distinct_modifications_not_saves(self):
        v1 = _version(2, meals=3)
        v2 = _version(4, meals=3)      # identical content — a redundant save
        v2["data"] = v1["data"]
        v3 = _version(6, meals=5)      # a real change
        result = trs.count_coach_modifications([v1, v2, v3], START, END)
        assert result["planSaves"] == 3
        assert result["modifications"] == 2
        assert result["redundantSaves"] == 1

    def test_identical_consecutive_saves_count_once(self):
        v1 = _version(2, meals=3)
        v2 = _version(3, meals=3)
        v2["data"] = v1["data"]
        v3 = _version(4, meals=3)
        v3["data"] = v1["data"]
        result = trs.count_coach_modifications([v1, v2, v3], START, END)
        assert result["planSaves"] == 3
        assert result["modifications"] == 1

    def test_a_save_that_re_persists_the_pre_engagement_plan_is_not_a_change(self):
        prior = _version(-3, meals=3)
        same = _version(1, meals=3)
        same["data"] = prior["data"]
        result = trs.count_coach_modifications([prior, same], START, END)
        assert result["planSaves"] == 1
        assert result["modifications"] == 0
        assert result["hadPriorPlanBeforeEngagement"] is True

    def test_first_and_last_modified_timestamps(self):
        result = trs.count_coach_modifications(
            [_version(2, meals=3), _version(6, meals=5)], START, END)
        assert result["firstModifiedAt"] == _iso(START + timedelta(days=2))
        assert result["lastModifiedAt"] == _iso(START + timedelta(days=6))

    def test_no_versions_means_no_modifications(self):
        result = trs.count_coach_modifications([], START, END)
        assert result["planSaves"] == 0
        assert result["modifications"] == 0
        assert result["firstModifiedAt"] is None
        assert result["hadPriorPlanBeforeEngagement"] is False

    def test_modified_by_lists_the_coaches_who_saved(self):
        result = trs.count_coach_modifications(
            [_version(2, meals=3, saved_by="Coach A"),
             _version(5, meals=5, saved_by="Coach A")], START, END)
        assert result["modifiedBy"] == ["Coach A"]


class TestMealQuality:
    def test_average_of_overall_ratings(self):
        checkins = [
            _checkin(0, overall=5, status="reviewed", reviewed=True),
            _checkin(1, overall=3, status="reviewed", reviewed=True),
            _checkin(2, overall=4, status="reviewed", reviewed=True),
        ]
        result = trs.compute_meal_quality(checkins)
        assert result["available"] is True
        assert result["reviewedMeals"] == 3
        assert result["averageRating"] == 4.0
        assert result["percent"] == 80.0
        assert result["highestRating"] == 5
        assert result["lowestRating"] == 3

    def test_falls_back_to_score_halved_when_no_overall_rating(self):
        # score is written as stars*2 by coaching-workspace.js.
        result = trs.compute_meal_quality(
            [_checkin(0, score=8, status="reviewed", reviewed=True)])
        assert result["averageRating"] == 4.0

    def test_falls_back_to_reaction_label_for_pre_star_reviews(self):
        result = trs.compute_meal_quality(
            [_checkin(0, reaction="great", status="reviewed", reviewed=True)])
        assert result["averageRating"] == 4.0

    def test_overall_rating_wins_over_score_and_reaction(self):
        result = trs.compute_meal_quality([
            _checkin(0, overall=2, score=10, reaction="perfect",
                     status="reviewed", reviewed=True)])
        assert result["averageRating"] == 2.0

    def test_unreviewed_meals_are_excluded_entirely(self):
        checkins = [_checkin(0, overall=5, status="reviewed", reviewed=True),
                    _checkin(1),   # pending, no rating
                    _checkin(2)]   # pending, no rating
        result = trs.compute_meal_quality(checkins)
        assert result["reviewedMeals"] == 1
        assert result["averageRating"] == 5.0
        assert result["submittedMeals"] == 3

    def test_no_ratings_at_all_is_unavailable_not_zero(self):
        result = trs.compute_meal_quality([_checkin(0), _checkin(1)])
        assert result["available"] is False
        assert result["reason"] == "no_reviewed_meals"
        assert result["averageRating"] is None
        assert result["percent"] is None
        # Emphatically NOT 0.0 — no reviews is not a bad score.
        assert result["percent"] != 0

    def test_empty_input_is_unavailable(self):
        assert trs.compute_meal_quality([])["available"] is False

    def test_single_meal_is_flagged_low_confidence(self):
        result = trs.compute_meal_quality(
            [_checkin(0, overall=5, status="reviewed", reviewed=True)])
        assert result["percent"] == 100.0
        # The guard against a lone 5-star reading as a strong result.
        assert result["lowConfidence"] is True
        assert result["sampleSize"] == 1

    def test_large_sample_is_not_low_confidence(self):
        checkins = [_checkin(i, overall=4, status="reviewed", reviewed=True)
                    for i in range(6)]
        assert trs.compute_meal_quality(checkins)["lowConfidence"] is False

    def test_reviewed_but_unrated_meals_are_counted_separately(self):
        checkins = [_checkin(0, overall=4, status="reviewed", reviewed=True),
                    _checkin(1, status="reviewed", reviewed=True)]
        result = trs.compute_meal_quality(checkins)
        assert result["reviewedMeals"] == 1
        assert result["reviewedWithoutRating"] == 1

    def test_string_numbers_from_the_js_client_are_coerced(self):
        result = trs.compute_meal_quality(
            [{"overallRating": "4", "status": "reviewed"}])
        assert result["averageRating"] == 4.0

    def test_booleans_are_not_treated_as_ratings(self):
        result = trs.compute_meal_quality(
            [{"overallRating": True, "score": None, "status": "reviewed"}])
        assert result["available"] is False


# ══════════════════════════════════════════════════════════════════════════
# Expert engagement / workout / plan adherence / follow-up / overall
# ══════════════════════════════════════════════════════════════════════════


class TestExpertEngagement:
    def test_returns_raw_counts_and_their_sum(self):
        result = trs.compute_expert_engagement(
            meal_reviews=7, meal_responses=5, plan_modifications=2,
            expert_messages=8, workout_reviews=1)
        assert result["available"] is True
        assert result["activityCount"] == 23
        assert result["mealReviews"] == 7

    def test_does_not_invent_a_score(self):
        result = trs.compute_expert_engagement(
            meal_reviews=7, meal_responses=5, plan_modifications=2,
            expert_messages=8)
        assert result["percent"] is None
        assert result["scoreReason"] == "engagement_scoring_model_not_finalized"

    def test_zero_activity_is_still_available_with_zero_counts(self):
        result = trs.compute_expert_engagement(
            meal_reviews=0, meal_responses=0, plan_modifications=0,
            expert_messages=0)
        assert result["available"] is True
        assert result["activityCount"] == 0


class TestWorkoutAdherence:
    def test_counts_completed_days_and_checkins(self):
        activity = [{"date": "2026-03-02", "workoutCompleted": True},
                    {"date": "2026-03-03", "workoutCompleted": False},
                    {"date": "2026-03-04", "workoutCompleted": True}]
        checkins = [{"timestamp": _iso(START), "status": "reviewed"},
                    {"timestamp": _iso(START + timedelta(days=1)),
                     "status": "pending"}]
        result = trs.compute_workout_adherence(
            activity_days=activity, workout_checkins=checkins, window_days=10)
        assert result["completedWorkoutDays"] == 2
        assert result["workoutCheckins"] == 2
        assert result["reviewedWorkoutCheckins"] == 1
        assert result["completionRateOfElapsedDays"] == 20.0

    def test_never_claims_prescribed_comparison(self):
        result = trs.compute_workout_adherence(
            activity_days=[], workout_checkins=[], window_days=10)
        assert result["available"] == "partial"
        assert result["prescribedComparisonAvailable"] is False
        assert "dated_prescribed_workouts" in result["missing"]

    def test_zero_window_days_yields_none_not_a_division_error(self):
        result = trs.compute_workout_adherence(
            activity_days=[], workout_checkins=[], window_days=0)
        assert result["completionRateOfElapsedDays"] is None

    def test_active_days_unions_checkins_and_completed_flags(self):
        activity = [{"date": "2026-03-05", "workoutCompleted": True}]
        checkins = [{"timestamp": _iso(START)}]  # 2026-03-02
        result = trs.compute_workout_adherence(
            activity_days=activity, workout_checkins=checkins, window_days=10)
        assert result["activeWorkoutDays"] == 2

    def test_workout_completed_must_be_true_not_merely_truthy(self):
        activity = [{"date": "2026-03-02", "workoutCompleted": "yes"},
                    {"date": "2026-03-03", "workoutCompleted": 1}]
        result = trs.compute_workout_adherence(
            activity_days=activity, workout_checkins=[], window_days=5)
        assert result["completedWorkoutDays"] == 0


class TestPlanAdherence:
    def test_reports_components_without_blending_them(self):
        follow = {"available": True, "percent": 60.0}
        workout = {"completionRateOfElapsedDays": 40.0,
                   "completedWorkoutDays": 4}
        result = trs.compute_plan_adherence(follow, workout)
        assert result["available"] == "partial"
        assert result["percent"] is None          # no fabricated composite
        assert result["components"]["mealFollowThrough"] == 60.0
        assert result["components"]["workoutActivity"] == 40.0
        assert "verified_recommendation_completion" in result["missing"]

    def test_unavailable_meal_component_becomes_none_not_zero(self):
        follow = {"available": False, "reason": "expected_meals_unavailable"}
        workout = {"completionRateOfElapsedDays": None,
                   "completedWorkoutDays": None}
        result = trs.compute_plan_adherence(follow, workout)
        assert result["components"]["mealFollowThrough"] is None
        assert result["available"] is False


class TestFollowUpAndOverall:
    def test_follow_up_is_always_unavailable_with_a_reason(self):
        result = trs.compute_follow_up()
        assert result["available"] is False
        assert result["percent"] is None
        assert result["reason"] == "follow_up_completion_not_tracked"

    def test_overall_score_is_always_unavailable_with_a_reason(self):
        result = trs.compute_overall()
        assert result["available"] is False
        assert result["percent"] is None
        assert result["reason"] == "scoring_model_not_finalized"


# ══════════════════════════════════════════════════════════════════════════
# Progress
# ══════════════════════════════════════════════════════════════════════════


class TestProgress:
    def test_weight_change_is_signed_and_unjudged(self):
        entries = [{"date": "2026-03-02", "weightKg": 80.0},
                   {"date": "2026-03-11", "weightKg": 78.0}]
        result = trs.compute_progress(weight_entries=entries, activity_days=[])
        assert result["startingWeightKg"] == 80.0
        assert result["endingWeightKg"] == 78.0
        assert result["weightChangeKg"] == -2.0
        assert result["weightChangePercent"] == -2.5
        # No "good"/"bad" verdict without knowing the athlete's goal.
        assert result["weightInterpretation"] == "not_evaluated_goal_unknown"

    def test_weight_gain_is_reported_as_positive_not_as_failure(self):
        entries = [{"weightKg": 70.0}, {"weightKg": 73.0}]
        result = trs.compute_progress(weight_entries=entries, activity_days=[])
        assert result["weightChangeKg"] == 3.0

    def test_single_weight_entry_gives_no_delta(self):
        result = trs.compute_progress(
            weight_entries=[{"weightKg": 80.0}], activity_days=[])
        assert result["weightChangeKg"] is None
        assert result["insufficientWeightData"] is True
        assert result["startingWeightKg"] == 80.0

    def test_no_weight_entries_leaves_every_weight_field_none(self):
        result = trs.compute_progress(weight_entries=[], activity_days=[])
        assert result["startingWeightKg"] is None
        assert result["weightChangeKg"] is None
        assert result["weightEntries"] == 0

    def test_activity_aggregates_ignore_missing_days(self):
        activity = [
            {"date": "2026-03-02", "steps": 8000, "waterMl": 2000, "sleepHours": 7.0},
            {"date": "2026-03-03", "steps": 6000},  # no water, no sleep
        ]
        result = trs.compute_progress(weight_entries=[], activity_days=activity)
        assert result["steps"]["total"] == 14000
        assert result["steps"]["dailyAverage"] == 7000.0
        assert result["water"]["daysRecorded"] == 1
        assert result["sleep"]["dailyAverageHours"] == 7.0

    def test_empty_activity_leaves_averages_none_not_zero(self):
        result = trs.compute_progress(weight_entries=[], activity_days=[])
        assert result["steps"]["total"] is None
        assert result["steps"]["dailyAverage"] is None
        assert result["sleep"]["dailyAverageHours"] is None

    def test_streaks_pass_through(self):
        result = trs.compute_progress(
            weight_entries=[], activity_days=[],
            current_streak=5, longest_streak=12)
        assert result["streak"] == {"current": 5, "longest": 12}


# ══════════════════════════════════════════════════════════════════════════
# compute_trial_report — orchestration against the in-process fake
# ══════════════════════════════════════════════════════════════════════════


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    return client


def _seed_relationship(db, *, request_id=ENGAGEMENT, status="expired",
                       coaching_type="FREE_TRIAL", ended_at=None,
                       expired_at=None, start=START, end=END):
    db.store[f"personal_coaching/{ATHLETE}"] = {
        "athleteId": ATHLETE,
        "athleteName": "Test Athlete",
        "coachId": COACH,
        "coachName": "Coach Test",
        "coachingType": coaching_type,
        "trialDurationDays": 10 if coaching_type == "FREE_TRIAL" else None,
        "planType": None,
        "planLabel": "Personal Coaching Free Trial",
        "fee": 0,
        "paymentId": None,
        "subscriptionId": "sub_1772000000000",
        "requestId": request_id,
        "startDate": _iso(start),
        "endDate": _iso(end),
        "status": status,
        "endedAt": ended_at,
        "expiredAt": expired_at,
    }


class TestEngagementResolution:
    def test_resolves_the_named_engagement(self, fake_db):
        _seed_relationship(fake_db)
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["engagementId"] == ENGAGEMENT
        assert report["coach"]["id"] == COACH
        assert report["period"]["coachingType"] == "FREE_TRIAL"
        assert report["period"]["durationDays"] == 10
        assert report["plan"]["label"] == "Personal Coaching Free Trial"

    def test_refuses_to_substitute_a_different_engagement(self, fake_db):
        # The overwrite hazard: the athlete has since started a NEW
        # engagement, so the old one's dates are gone. Reporting the new
        # one's data under the old id is the exact bug being prevented.
        _seed_relationship(fake_db, request_id="req_NEWER_engagement")
        with pytest.raises(trs.EngagementUnavailable) as exc:
            trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert "req_NEWER_engagement" in str(exc.value)
        assert "Refusing to substitute" in str(exc.value)

    def test_missing_relationship_raises(self, fake_db):
        with pytest.raises(trs.EngagementUnavailable):
            trs.compute_trial_report("nobody", ENGAGEMENT, now=NOW)

    def test_unparseable_dates_raise_rather_than_defaulting(self, fake_db):
        _seed_relationship(fake_db)
        fake_db.store[f"personal_coaching/{ATHLETE}"]["startDate"] = "garbage"
        with pytest.raises(trs.EngagementUnavailable) as exc:
            trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert "unusable dates" in str(exc.value)

    def test_unconfigured_firestore_raises_rather_than_empty_report(self, monkeypatch):
        monkeypatch.setattr(firestore_service, "get_client", lambda: None)
        with pytest.raises(trs.EngagementUnavailable) as exc:
            trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert "not configured" in str(exc.value)

    def test_early_end_shortens_the_window(self, fake_db):
        # Ended on day 3 of a 10-day trial: the athlete must not be measured
        # against seven days they never had.
        ended = START + timedelta(days=2, hours=1)
        _seed_relationship(fake_db, status="ended", ended_at=_iso(ended))
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["period"]["durationDays"] == 10   # scheduled
        assert report["period"]["elapsedDays"] == 3     # actually elapsed

    def test_still_running_engagement_is_capped_at_now(self, fake_db):
        _seed_relationship(fake_db, status="active")
        mid = START + timedelta(days=4, hours=2)
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=mid)
        assert report["period"]["elapsedDays"] == 5
        assert report["period"]["effectiveEndDate"] == _iso(mid)


class TestFullReport:
    def test_empty_engagement_produces_a_valid_honest_report(self, fake_db):
        _seed_relationship(fake_db)
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)

        assert report["reportVersion"] == "1.0"
        assert report["activity"]["mealCheckins"] == 0
        m = report["metrics"]
        assert m["mealFollowThrough"]["available"] is False
        assert m["mealQuality"]["available"] is False
        assert m["followUp"]["available"] is False
        assert m["overall"]["available"] is False
        assert m["expertEngagement"]["activityCount"] == 0
        # No metric silently became a number.
        assert m["mealFollowThrough"]["percent"] is None
        assert m["overall"]["percent"] is None

    def test_populated_engagement_computes_every_available_metric(self, fake_db):
        _seed_relationship(fake_db)
        fake_db.store[f"coaching_plans/{ATHLETE}"] = {"diet": _plan(3)}
        # The AI plan the coach's version was customised from — same planId,
        # so the pre-first-save days are priced against it.
        fake_db.store[f"users/{ATHLETE}"] = {
            "currentStreak": 4, "longestStreak": 9, "planId": "plan_A",
            "dietPlan": {"days": [{"meals": [{}, {}, {}]} for _ in range(7)]}}
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_0"] = _version(
            1, meals=3, version=1)

        for offset, overall in ((0, 5), (1, 4), (2, 3)):
            c = _checkin(offset, overall=overall, status="reviewed", reviewed=True)
            fake_db.store[f"meal_checkins/{c['checkinId']}"] = c
        extra = _checkin(3, meal_type="lunch")
        fake_db.store[f"meal_checkins/{extra['checkinId']}"] = extra

        fake_db.store[f"workout_checkins/WCI_1"] = {
            "checkinId": "WCI_1", "athleteId": ATHLETE, "coachId": COACH,
            "timestamp": _iso(START + timedelta(days=1)),
            "status": "reviewed",
            "reviewedAt": _iso(START + timedelta(days=1, hours=3)),
        }
        fake_db.store[f"users/{ATHLETE}/activity/2026-03-02"] = {
            "date": "2026-03-02", "steps": 9000, "waterMl": 2100,
            "sleepHours": 7.5, "workoutCompleted": True,
        }
        fake_db.store[f"users/{ATHLETE}/weight_log/2026-03-02"] = {
            "date": "2026-03-02", "weightKg": 80.0}
        fake_db.store[f"users/{ATHLETE}/weight_log/2026-03-11"] = {
            "date": "2026-03-11", "weightKg": 78.5}
        fake_db.store[f"coaching_meal_requests/CMR_1"] = {
            "requestId": "CMR_1", "athleteId": ATHLETE, "coachId": COACH,
            "status": "replied", "createdAt": _iso(START),
            "repliedAt": _iso(START + timedelta(days=1))}
        fake_db.store[f"chat_rooms/chat_{ATHLETE}_{COACH}/messages/msg_1"] = {
            "id": "msg_1", "senderId": COACH, "senderType": "expert",
            "text": "Great work", "timestamp": _iso(START + timedelta(days=2))}
        fake_db.store[f"chat_rooms/chat_{ATHLETE}_{COACH}/messages/msg_2"] = {
            "id": "msg_2", "senderId": ATHLETE, "senderType": "athlete",
            "text": "Thanks", "timestamp": _iso(START + timedelta(days=2))}

        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        m = report["metrics"]

        assert m["mealFollowThrough"]["available"] is True
        assert m["mealFollowThrough"]["submitted"] == 4
        # 10 engagement slots x 3 meals. Slot 1 is priced against the AI plan
        # (the coach's save lands at the slot-1/slot-2 boundary), slots 2-10
        # against the coach version — 3 meals either way.
        assert m["mealFollowThrough"]["expected"] == 30
        assert m["mealFollowThrough"]["engagementSlots"] == 10
        assert m["mealFollowThrough"]["daysActive"] == 4

        assert m["mealQuality"]["available"] is True
        assert m["mealQuality"]["reviewedMeals"] == 3
        assert m["mealQuality"]["averageRating"] == 4.0

        eng = m["expertEngagement"]
        assert eng["mealReviews"] == 3
        assert eng["mealResponses"] == 1
        assert eng["planModifications"] == 1
        assert eng["expertMessages"] == 1     # the athlete's message excluded
        assert eng["workoutReviews"] == 1
        assert eng["activityCount"] == 7

        assert m["workoutAdherence"]["completedWorkoutDays"] == 1
        assert m["workoutAdherence"]["reviewedWorkoutCheckins"] == 1
        assert m["progress"]["weightChangeKg"] == -1.5
        assert m["progress"]["streak"] == {"current": 4, "longest": 9}

        # Still unavailable no matter how rich the data is.
        assert m["followUp"]["available"] is False
        assert m["overall"]["available"] is False

    def test_checkins_outside_the_window_are_excluded(self, fake_db):
        _seed_relationship(fake_db)
        before = _checkin(-5)
        before["checkinId"] = "MCI_before"
        after = _checkin(30)
        after["checkinId"] = "MCI_after"
        inside = _checkin(1)
        for c in (before, after, inside):
            fake_db.store[f"meal_checkins/{c['checkinId']}"] = c

        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["activity"]["mealCheckins"] == 1

    def test_another_coachs_checkins_are_excluded(self, fake_db):
        _seed_relationship(fake_db)
        mine = _checkin(1)
        theirs = _checkin(2)
        theirs["checkinId"] = "MCI_other_coach"
        theirs["coachId"] = "coach_other"
        for c in (mine, theirs):
            fake_db.store[f"meal_checkins/{c['checkinId']}"] = c

        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["activity"]["mealCheckins"] == 1

    def test_another_athletes_checkins_are_excluded(self, fake_db):
        _seed_relationship(fake_db)
        mine = _checkin(1)
        fake_db.store[f"meal_checkins/{mine['checkinId']}"] = mine
        other = _checkin(1)
        other["checkinId"] = "MCI_other_athlete"
        other["athleteId"] = "athlete_2"
        fake_db.store[f"meal_checkins/{other['checkinId']}"] = other

        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["activity"]["mealCheckins"] == 1

    def test_ten_day_trial_is_measured_over_ten_days_not_eleven(self, fake_db):
        # The Step 2.5 finding, now fixed: a 09:00->09:00 ten-day trial
        # touches eleven calendar dates but must be measured over ten.
        _seed_relationship(fake_db)
        fake_db.store[f"users/{ATHLETE}"] = {
            "planId": "plan_A",
            "dietPlan": {"days": [{"meals": [{}, {}, {}]} for _ in range(7)]}}
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["period"]["durationDays"] == 10
        assert report["period"]["elapsedDays"] == 10        # slots
        assert report["period"]["calendarDatesTouched"] == 11
        assert report["metrics"]["mealFollowThrough"]["expected"] == 30
        assert "partialSlots" not in report["metrics"]["mealFollowThrough"]
        assert report["dataQuality"]["dayModels"]["mealExpectations"] == (
            "elapsed_24h_engagement_slots")

    def test_early_ended_trial_discloses_its_partial_final_day(self, fake_db):
        ended = START + timedelta(days=2, hours=6)
        _seed_relationship(fake_db, status="ended", ended_at=_iso(ended))
        fake_db.store[f"users/{ATHLETE}"] = {
            "planId": "plan_A",
            "dietPlan": {"days": [{"meals": [{}, {}, {}]} for _ in range(7)]}}
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert report["period"]["elapsedDays"] == 3
        assert report["metrics"]["mealFollowThrough"]["partialSlots"] == 1
        assert any("ended part-way through day 3" in w
                   for w in report["dataQuality"]["warnings"])

    def test_data_quality_always_states_the_permanent_limitations(self, fake_db):
        _seed_relationship(fake_db)
        warnings = " ".join(
            trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
            ["dataQuality"]["warnings"])
        assert "Follow-up completion is not currently tracked" in warnings
        assert "prescribed workout adherence is not available" in warnings
        assert "Overall ZITLAS Score is not computed" in warnings

    def test_report_is_json_serialisable(self, fake_db):
        import json
        _seed_relationship(fake_db)
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert json.loads(json.dumps(report))["engagementId"] == ENGAGEMENT


class TestPlanEvolutionEndToEnd:
    """The AI -> coach-customisation -> athlete flow, end to end."""

    def _seed_ai(self, fake_db, meals=4, plan_id="plan_A"):
        fake_db.store[f"users/{ATHLETE}"] = {
            "planId": plan_id,
            "dietPlan": {"days": [{"meals": [{}] * meals} for _ in range(7)]}}

    def test_ai_only_engagement_never_claims_coach_customization(self, fake_db):
        _seed_relationship(fake_db)
        self._seed_ai(fake_db, meals=4)
        evolution = trs.compute_trial_report(
            ATHLETE, ENGAGEMENT, now=NOW)["metrics"]["planEvolution"]
        assert evolution["startedFrom"] == trs.SOURCE_AI
        assert evolution["aiPlanApplied"] is True
        assert evolution["coachCustomizedPlanApplied"] is False
        assert evolution["customizationConfirmed"] is False
        assert evolution["modifications"] == 0
        assert evolution["wording"] == "ai_plan_only"

    def test_coach_customization_is_reported_as_customization(self, fake_db):
        _seed_relationship(fake_db)
        self._seed_ai(fake_db, meals=4)
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_1"] = _version(
            3, meals=5, version=1)
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_2"] = _version(
            6, meals=6, version=2)
        evolution = trs.compute_trial_report(
            ATHLETE, ENGAGEMENT, now=NOW)["metrics"]["planEvolution"]
        assert evolution["startedFrom"] == trs.SOURCE_AI
        assert evolution["coachCustomizedPlanApplied"] is True
        assert evolution["customizationConfirmed"] is True
        assert evolution["modifications"] == 2
        assert evolution["wording"] == "coach_customized_ai_plan"
        assert len(evolution["segments"]) == 3

    def test_redundant_autosaves_do_not_inflate_the_modification_count(self, fake_db):
        _seed_relationship(fake_db)
        self._seed_ai(fake_db)
        v1 = _version(3, meals=5, version=1)
        v2 = _version(4, meals=5, version=2)
        v2["data"] = v1["data"]          # autosave of unchanged content
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_1"] = v1
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_2"] = v2
        evolution = trs.compute_trial_report(
            ATHLETE, ENGAGEMENT, now=NOW)["metrics"]["planEvolution"]
        assert evolution["planSaves"] == 2
        assert evolution["modifications"] == 1
        assert evolution["redundantSaves"] == 1

    def test_expectations_change_at_the_coach_save_not_before(self, fake_db):
        # AI = 4 meals/day; coach saves 6 meals/day at Mar 6 09:00.
        _seed_relationship(fake_db)
        self._seed_ai(fake_db, meals=4)
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_1"] = _version(
            4, meals=6, version=1)
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        follow = report["metrics"]["mealFollowThrough"]
        # The coach's save lands exactly on the slot-4/slot-5 boundary, so
        # slots 1-4 keep the AI expectation and slots 5-10 take the coach's.
        assert follow["expectedBySource"] == {
            trs.SOURCE_AI: 16,      # 4 slots x 4
            trs.SOURCE_COACH: 36,   # 6 slots x 6
        }
        assert follow["expected"] == 52

    def test_a_regenerated_ai_plan_removes_only_the_ai_days(self, fake_db):
        _seed_relationship(fake_db)
        self._seed_ai(fake_db, meals=4, plan_id="plan_B_NEWER")
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_1"] = _version(
            4, meals=6, version=1, plan_id="plan_A")
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        follow = report["metrics"]["mealFollowThrough"]
        # The coach days still count; the unverifiable AI days do not.
        assert follow["expectedBySource"] == {trs.SOURCE_COACH: 36}
        assert follow["daysWithoutPlannedMeals"] == 4
        assert any("could not be verified as unchanged" in w
                   for w in report["dataQuality"]["warnings"])

    def test_report_never_implies_the_coach_authored_the_plan(self, fake_db):
        _seed_relationship(fake_db)
        self._seed_ai(fake_db)
        fake_db.store[f"coaching_plans/{ATHLETE}/versions/diet_1"] = _version(
            3, meals=5, version=1)
        report = trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        evolution = report["metrics"]["planEvolution"]
        # The only wording the report emits is a customisation claim, and
        # the blank-template flag stays false when an AI plan existed.
        assert evolution["wording"] == "coach_customized_ai_plan"
        assert evolution["coachAuthoredFromBlankTemplate"] is False


class TestReadOnly:
    def test_computing_a_report_writes_nothing(self, fake_db):
        """The load-bearing safety property of this whole module."""
        _seed_relationship(fake_db)
        fake_db.store[f"coaching_plans/{ATHLETE}"] = {"diet": _plan(3)}
        c = _checkin(1, overall=4, status="reviewed", reviewed=True)
        fake_db.store[f"meal_checkins/{c['checkinId']}"] = c
        fake_db.store[f"users/{ATHLETE}/activity/2026-03-03"] = {
            "date": "2026-03-03", "steps": 5000, "workoutCompleted": True}

        import copy
        before = copy.deepcopy(fake_db.store)
        trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert fake_db.store == before

    def test_no_report_document_is_created(self, fake_db):
        _seed_relationship(fake_db)
        keys_before = set(fake_db.store)
        trs.compute_trial_report(ATHLETE, ENGAGEMENT, now=NOW)
        assert set(fake_db.store) == keys_before
        assert not any(k.startswith("trial_reports/") for k in fake_db.store)
