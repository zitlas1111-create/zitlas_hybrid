"""
ZITLAS — Trial Completion / Personal Coaching Report computation
(backend/services/trial_report_service.py)

PURE, READ-ONLY. This module computes a report from data that already
exists. It never writes to Firestore, never mutates a document it reads,
and is deliberately not imported by any route, scheduler job, or client.
Nothing in production calls it yet — that is Step 3.

WHAT THIS IS FOR
----------------
When a Personal Coaching engagement ends (free trial or paid), the athlete
should see what actually happened during it. This module answers "what can
the existing data honestly say about that engagement" — and, just as
importantly, what it cannot.

THE DESIGN RULE, WHICH IS THE WHOLE POINT
------------------------------------------
A report that fabricates precision is worse than no report. An athlete who
is told "78% plan adherence" will believe it, act on it, and pay for more
coaching because of it. So every metric here is one of:

    available: True       computed from records that actually exist
    available: "partial"  some components real, others absent — both named
    available: False      not computable, WITH the reason

Nothing is estimated into existence. There is no default meals-per-day, no
assumed workout schedule, and no overall score, because none of those exist
in the data (see the Step 1 audit). Where a number cannot be earned, this
returns None and says why in `reason`.

ENGAGEMENT IDENTITY
-------------------
`request_id` is the identity, not `athlete_uid`. `personal_coaching/{uid}`
is keyed by athlete and OVERWRITTEN when a new coach is accepted — the same
fact routes/expert_ratings.py documents at _resolve_engagement(). So the
relationship document describes only the MOST RECENT engagement, and asking
for an older one must fail loudly rather than return the wrong trial's
dates under the right trial's id. `_load_engagement` therefore verifies
`requestId` matches and raises EngagementUnavailable if it does not.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterable, Sequence

from services import firestore_service

REPORT_VERSION = "1.0"

#: Weekday names as BOTH clients write them — `kCoachPlanDays` in
#: mobile/lib/features/coaching/models/coach_diet_plan.dart and
#: `_pcTodayName()` in frontend/website/pages/diet/diet.js. Indexed the way
#: `date.weekday()` returns (Monday == 0).
_WEEKDAY_NAMES = ("monday", "tuesday", "wednesday", "thursday",
                  "friday", "saturday", "sunday")

#: `meal_checkins.reaction` -> a 1-5 rating, mirroring MealReaction in
#: mobile/lib/features/coaching/models/meal_checkin.dart. Used only as the
#: last fallback when neither overallRating nor score is present.
_REACTION_RATING = {
    "perfect": 5,
    "great": 4,
    "good": 3,
    "needs_improvement": 2,
    "not_recommended": 1,
}

#: Where a plan segment's meal expectations came from. ZITLAS does NOT have
#: coaches authoring plans from scratch: `ensureDietDraft()` in
#: coaching-workspace.js preloads the athlete's AI-generated diet
#: (`dietFromAiPlan()`) and banners it as "Preloaded from the user's
#: AI-generated diet plan — review, adjust anything, then Save to publish
#: your version." So a coach plan is a CUSTOMISATION of the AI plan, and the
#: report's wording must say so.
SOURCE_AI = "ai_generated"
SOURCE_COACH = "coach_customized"
#: The blank-week fallback the coach only reaches when the athlete has no AI
#: plan at all ("Start with template" in renderDietEditor).
SOURCE_COACH_TEMPLATE = "coach_authored_from_template"


class EngagementUnavailable(Exception):
    """The engagement named by `request_id` cannot be resolved.

    Deliberately an exception rather than an empty report: a caller that
    gets a report back must be able to trust that it describes the
    engagement they asked for. Silently returning the athlete's *current*
    relationship under a stale request_id is the one failure mode this
    whole module is arranged to prevent.
    """


# ══════════════════════════════════════════════════════════════════════════
# PURE HELPERS — no Firestore, no clock, no I/O.
#
# Everything below takes plain dicts/lists and returns plain dicts, so the
# unit tests exercise the real calculation rather than a mock of it.
# ══════════════════════════════════════════════════════════════════════════


def parse_iso(value: Any) -> datetime | None:
    """An aware UTC datetime from the ISO strings this codebase stores, or
    None if it is absent or unparseable.

    Every timestamp in the coaching data is written as `.toISOString()` (JS)
    or `.isoformat()` (Python), so 'Z' suffixes and offsets both occur. A
    naive value is treated as UTC — the writers are `datetime.now(timezone.utc)`
    and `new Date()`, both of which mean UTC here.

    Returns None rather than raising: one malformed timestamp in a check-in
    must not fail a whole report. Callers count what they had to drop and
    surface it in `dataQuality`.

    ALWAYS NORMALISED TO UTC, never merely made aware. Comparison operators
    handle mixed offsets correctly, but `.date()` does not — it reads the
    date in whatever offset the value carries. So `2026-03-03T04:00+05:30`
    and `2026-03-02T22:30Z` are the same instant yet would bucket into
    different days. Since the client writes offsets (`toISOString()` is UTC,
    but a hand-edited or re-serialised value need not be), converting here
    is what makes day bucketing depend on the instant rather than on how the
    timestamp happened to be spelled.
    """
    if isinstance(value, datetime):
        aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return aware.astimezone(timezone.utc)
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    aware = parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    return aware.astimezone(timezone.utc)


def _in_window(value: Any, start: datetime, end: datetime) -> bool:
    """Inclusive-start, inclusive-end membership for an ISO timestamp."""
    moment = parse_iso(value)
    return moment is not None and start <= moment <= end


def date_keys(start: datetime, end: datetime) -> list[str]:
    """Every `YYYY-MM-DD` key from start to end inclusive.

    These are the document ids of `users/{uid}/activity/{date}` and
    `users/{uid}/weight_log/{date}`.

    KNOWN SKEW, DELIBERATELY NOT PAPERED OVER: those ids are minted from the
    *device's local* clock (`_dtDateKey()` in day.js, `todayKey` in
    dashboard_repository.dart) while every timestamp compared against them
    here is UTC. For an athlete far from UTC that shifts a day-bucket by one
    at the window edges. Widening the window to hide it would silently pull
    in a neighbouring day's data, so the range stays honest and the report
    declares the limitation in `dataQuality`.
    """
    if end < start:
        return []
    first, last = start.date(), end.date()
    return [(first + timedelta(days=offset)).isoformat()
            for offset in range((last - first).days + 1)]


@dataclass(frozen=True)
class EngagementSlot:
    """One elapsed 24-hour day of the engagement.

    Slot 1 runs start -> start+24h, slot 2 start+24h -> start+48h, and so on.
    `end` is exclusive except on the final slot, which is clamped to the
    engagement end so no slot ever extends past it.
    """

    index: int          # 1-based, as an athlete would count "day 3"
    start: datetime
    end: datetime

    @property
    def partial(self) -> bool:
        return (self.end - self.start) < timedelta(days=1)


def engagement_slots(start: datetime, end: datetime) -> list[EngagementSlot]:
    """The engagement's elapsed 24-hour slots.

    WHY NOT CALENDAR DATES. A 10-day trial running 09:00 -> 09:00 touches
    ELEVEN calendar dates, two of them partial, and charging both boundary
    dates a full day of expected meals inflated the denominator by ~10% —
    costing the athlete around nine percentage points of follow-through for
    nothing they did. Elapsed slots make "10-day trial" mean exactly ten
    day-slots, each a full 24 hours, with every check-in landing in exactly
    one of them. Numerator and denominator then share one partition, so
    neither can inflate the other.

    A trial that ended early produces a final PARTIAL slot rather than a
    dropped one: the athlete did enter that day and could submit meals in
    it, so counting it keeps numerator and denominator consistent. The
    partial is disclosed in `dataQuality` rather than prorated, because
    prorating would require knowing which of the day's meals fell inside
    the window — data that does not exist.

    NOTE THE DELIBERATE SPLIT: only MEAL expectations use these slots.
    `users/{uid}/activity/{date}` and `weight_log/{date}` are day-keyed
    documents addressed by calendar date, so those keep `date_keys()`. The
    report therefore carries two day models on purpose, and says so.
    """
    if end <= start:
        return []
    slots: list[EngagementSlot] = []
    index = 1
    cursor = start
    while cursor < end:
        slot_end = min(cursor + timedelta(days=1), end)
        slots.append(EngagementSlot(index=index, start=cursor, end=slot_end))
        cursor = slot_end
        index += 1
    return slots


def slot_for(slots: Sequence[EngagementSlot],
             moment: datetime) -> EngagementSlot | None:
    """The slot a moment falls in, or None.

    The final slot's end is inclusive so a check-in written at the exact
    expiry instant belongs to the last day rather than to nothing.
    """
    if not slots:
        return None
    for slot in slots:
        if slot.start <= moment < slot.end:
            return slot
    last = slots[-1]
    return last if moment == last.end else None


def expected_meals_by_weekday(diet_plan: Any) -> dict[str, int]:
    """`{weekday_name: meals_that_day}` from a coach-authored diet plan.

    Reads `coaching_plans/{uid}.diet.days[].meals` — the shape
    CoachDietPlan/CoachDietDay parse and coaching-workspace.js writes.

    This is a weekly TEMPLATE keyed by weekday name, not a dated schedule,
    which is exactly why the count is resolved per weekday and then mapped
    onto real calendar dates by the caller. That yields a genuinely correct
    expectation for a window of any length or alignment, instead of the
    flat meals-per-day multiplication that would misprice any plan whose
    Sunday differs from its Monday.

    Days with no meals are omitted rather than recorded as 0: an empty day
    in a template usually means "not authored", and treating it as "zero
    meals expected" would flatter the follow-through percentage.
    """
    if not isinstance(diet_plan, dict):
        return {}
    days = diet_plan.get("days")
    if not isinstance(days, list):
        return {}

    by_weekday: dict[str, int] = {}
    for entry in days:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("day") or "").strip().lower()
        if name not in _WEEKDAY_NAMES:
            continue
        meals = entry.get("meals")
        count = len(meals) if isinstance(meals, list) else 0
        if count > 0:
            by_weekday[name] = count
    return by_weekday


def meals_by_weekday_from_ai_plan(ai_plan: Any) -> dict[str, int]:
    """`{weekday_name: meals_that_day}` from the athlete's AI-generated plan.

    The AI plan is stored at `users/{uid}.dietPlan` (cloud-sync.js mirrors
    `zitlas_diet_plan`) and its days are POSITIONAL, not weekday-labelled:
    diet.js states "Plan order: Mon=0, Tue=1, ..." and selects the day with
    `currentDay = (getDay() + 6) % 7`. Index 0 is therefore Monday, which is
    exactly what `date.weekday()` returns.

    A plan with fewer than 7 days CYCLES, mirroring `dietFromAiPlan()`'s own
    `aiDays[i % aiDays.length]` — so the expectation this derives is the same
    one the coach's editor was seeded with.

    Handles the `{originalDietPlan, currentDietPlan}` wrapper the same way
    `_normalizeAthleteDoc()` does, since `users/{uid}.dietPlan` carries
    either shape depending on whether an expert review has been accepted.
    """
    plan = ai_plan
    if isinstance(plan, dict) and (plan.get("currentDietPlan")
                                   or plan.get("originalDietPlan")):
        plan = plan.get("currentDietPlan") or plan.get("originalDietPlan")
    if not isinstance(plan, dict):
        return {}
    days = plan.get("days")
    if not isinstance(days, list) or not days:
        return {}

    by_weekday: dict[str, int] = {}
    for index, weekday in enumerate(_WEEKDAY_NAMES):
        entry = days[index % len(days)]
        if not isinstance(entry, dict):
            continue
        meals = entry.get("meals")
        count = len(meals) if isinstance(meals, list) else 0
        if count > 0:
            by_weekday[weekday] = count
    return by_weekday


@dataclass(frozen=True)
class PlanSegment:
    """One stretch of the engagement during which one plan applied.

    `effective_from` is inclusive, `effective_to` exclusive. `source` says
    whether the athlete was following their AI-generated plan or a
    coach-customised version of it during this stretch.
    """

    effective_from: datetime
    effective_to: datetime
    meals_by_weekday: dict[str, int]
    source: str
    version: int | None = None
    saved_at: str | None = None
    saved_by: str | None = None

    @property
    def available(self) -> bool:
        return bool(self.meals_by_weekday)

    def as_dict(self) -> dict:
        return {
            "effectiveFrom": self.effective_from.isoformat(),
            "effectiveTo": self.effective_to.isoformat(),
            "source": self.source,
            "version": self.version,
            "savedAt": self.saved_at,
            "savedBy": self.saved_by,
            "mealsByWeekday": dict(self.meals_by_weekday),
            "expectationAvailable": self.available,
        }


def _plan_shape_meals(plan_data: Any) -> dict[str, int]:
    """Meals-per-weekday from EITHER plan shape.

    A coach version's `data` is weekday-labelled (`{day: "Monday", meals:[]}`)
    while an AI plan is positional. Dispatching on shape rather than on
    provenance keeps this correct if a version is ever seeded differently.
    """
    labelled = expected_meals_by_weekday(plan_data)
    if labelled:
        return labelled
    return meals_by_weekday_from_ai_plan(plan_data)


def build_plan_timeline(
    *,
    start: datetime,
    end: datetime,
    ai_plan: Any,
    ai_plan_id: Any,
    coach_versions: Sequence[dict],
) -> list[PlanSegment]:
    """The ordered plan history covering [start, end).

    THE PRODUCT FLOW THIS MODELS — AI generates, coach customises, athlete
    follows — is what the data actually records:

      * Before the coach's first save the athlete follows their AI plan.
        diet.js's `initCoachDietMode()` says so outright: "Meal check-ins
        and Ask My Coach are coaching features, live even before the coach
        publishes a plan (AI meals still render)."
      * From each coach save onward the athlete follows that saved version
        (`_pcShowsCoachPlan()` switches the athlete's Diet page to
        `coaching_plans.diet` once one exists).

    WHY THE AI SEGMENT IS VERIFIED, NOT ASSUMED. `users/{uid}.dietPlan` holds
    only the CURRENT AI plan and is overwritten on every regeneration, so it
    is not automatically a valid snapshot of what applied weeks ago. But both
    the coach's saved plan and each version carry the `planId` they were
    seeded from (`draft.planId = athleteCtx().planId` at save time). When the
    athlete's live `planId` still equals that stamp, no regeneration has
    happened since and the live AI plan IS the one that applied. When it
    differs — or when there is no stamp to compare — the AI segment is
    emitted with an EMPTY expectation rather than a guessed one.
    """
    versions = _ordered_diet_versions(coach_versions)

    # The planId every coach version agrees on, if they agree. Used only to
    # decide whether the live AI plan may stand in for the earliest stretch.
    stamped_ids = {
        v["data"].get("planId") for v in versions
        if isinstance(v.get("data"), dict) and v["data"].get("planId")
    }
    ai_still_current = bool(
        ai_plan_id and (not stamped_ids or ai_plan_id in stamped_ids))

    segments: list[PlanSegment] = []
    first_save = versions[0]["_savedAt"] if versions else None

    # ── Segment 0: the AI plan, up to the coach's first save ──────────────
    ai_until = min(first_save, end) if first_save else end
    if ai_until > start:
        ai_meals = meals_by_weekday_from_ai_plan(ai_plan) if ai_still_current else {}
        segments.append(PlanSegment(
            effective_from=start,
            effective_to=ai_until,
            meals_by_weekday=ai_meals,
            source=SOURCE_AI,
        ))

    # ── Segments 1..n: each coach save, until the next one ────────────────
    for index, version in enumerate(versions):
        saved_at = version["_savedAt"]
        if saved_at >= end:
            break
        segment_from = max(saved_at, start)
        segment_to = (versions[index + 1]["_savedAt"]
                      if index + 1 < len(versions) else end)
        segment_to = min(segment_to, end)
        if segment_to <= segment_from:
            continue
        data = version.get("data")
        meals = _plan_shape_meals(data)
        # A version seeded from a blank week (the coach had no AI plan to
        # customise) is a different claim about the product flow, so it is
        # labelled differently rather than being called a customisation.
        source = SOURCE_COACH if (ai_plan or stamped_ids) else SOURCE_COACH_TEMPLATE
        segments.append(PlanSegment(
            effective_from=segment_from,
            effective_to=segment_to,
            meals_by_weekday=meals,
            source=source,
            version=_as_int(version.get("version")),
            saved_at=version.get("savedAt"),
            saved_by=version.get("savedBy"),
        ))

    return segments


def _ordered_diet_versions(coach_versions: Sequence[dict]) -> list[dict]:
    """Diet versions with a parseable `savedAt`, oldest first.

    Every document in `coaching_plans/{uid}/versions` is a COACH save by
    construction: firestore.rules grants `allow write: if
    isActiveCoachOf(athleteUid)` there and nothing else, so neither the AI
    nor the athlete can create one. Training versions are filtered out —
    they carry `type: 'training'` and say nothing about meal expectations.
    """
    ordered = []
    for version in coach_versions:
        if version.get("type") != "diet":
            continue
        saved_at = parse_iso(version.get("savedAt"))
        if saved_at is None:
            continue
        ordered.append({**version, "_savedAt": saved_at})
    ordered.sort(key=lambda v: v["_savedAt"])
    return ordered


def segment_for(timeline: Sequence[PlanSegment],
                moment: datetime) -> PlanSegment | None:
    """The segment covering `moment`, or None."""
    for segment in timeline:
        if segment.effective_from <= moment < segment.effective_to:
            return segment
    return timeline[-1] if timeline and moment >= timeline[-1].effective_to else None


def count_coach_modifications(coach_versions: Sequence[dict],
                              start: datetime, end: datetime) -> dict:
    """Coach plan saves in the window, and how many actually CHANGED anything.

    A save is not a modification. The workspace autosaves (`scheduleAutoSave`
    in coaching-workspace.js), and re-saving an unchanged plan writes a fresh
    version document — so counting documents would tell an athlete their
    coach made six changes when the coach made two. Consecutive versions
    whose `data` is deep-equal are therefore collapsed.

    The comparison baseline is the version immediately BEFORE the window
    where one exists, so a save at the start of the engagement that merely
    re-persists the pre-engagement plan is not counted as a change either.
    """
    ordered = _ordered_diet_versions(coach_versions)
    in_window = [v for v in ordered if start <= v["_savedAt"] <= end]

    baseline = None
    for version in ordered:
        if version["_savedAt"] < start:
            baseline = version.get("data")
        else:
            break

    modifications = 0
    previous = baseline
    for version in in_window:
        data = version.get("data")
        if previous is None or data != previous:
            modifications += 1
        previous = data

    return {
        "available": True,
        "planSaves": len(in_window),
        "modifications": modifications,
        "redundantSaves": len(in_window) - modifications,
        "firstModifiedAt": in_window[0].get("savedAt") if in_window else None,
        "lastModifiedAt": in_window[-1].get("savedAt") if in_window else None,
        "modifiedBy": sorted({
            v.get("savedBy") for v in in_window if v.get("savedBy")}),
        "totalVersionsAllTime": len(ordered),
        "hadPriorPlanBeforeEngagement": baseline is not None,
    }


def _checkin_day_key(checkin: dict) -> str | None:
    """The UTC calendar day a check-in belongs to.

    Derived from `timestamp`, NEVER from `day`: that field holds a recurring
    weekday NAME ("Monday"), so using it for date bucketing would collapse
    every Monday of a multi-week engagement into one.
    """
    moment = parse_iso(checkin.get("timestamp"))
    return moment.date().isoformat() if moment else None


def _weekday_of_key(day_key: str) -> str | None:
    try:
        return _WEEKDAY_NAMES[date.fromisoformat(day_key).weekday()]
    except (ValueError, TypeError):
        return None


def compute_meal_follow_through(
    checkins: Sequence[dict],
    *,
    slots: Sequence[EngagementSlot],
    timeline: Sequence[PlanSegment],
) -> dict:
    """Submitted meals against the meals the APPLICABLE plan expected.

    `checkins` must already be filtered to the engagement window by the
    caller (see `_filter_window`) — this helper does no date filtering of
    its own so it stays trivially testable.

    MEASURED IN ELAPSED 24-HOUR ENGAGEMENT SLOTS, not calendar dates, so a
    10-day trial has exactly ten day-slots and no eleventh partial date
    inflates the denominator. See `engagement_slots()`.

    DATE-ACCURATE. Each slot is priced against the plan segment in force at
    the moment that slot began, so an athlete is never charged for meals
    that did not exist in their plan yet. If the coach adds a fifth meal on
    day 7, days 1-6 are still measured against four.

    The slot is attributed to the plan the athlete STARTED it with. A coach
    save four hours into a slot changes the expectation from the NEXT slot,
    not retroactively for a day already half-eaten.

    NO DEFAULT DENOMINATOR. If no segment yields an expectation for any slot,
    this returns available=False with reason='expected_meals_unavailable'
    rather than assuming a number. `meal_compliance.dart` defaults to 4
    meals/day and its only caller never overrides it; reproducing that here
    would bake a guess into a number the athlete is asked to trust.
    """
    submitted = len(checkins)

    # Days ACTIVE is counted in the same partition as the denominator, so it
    # can never disagree with it (a check-in in slot 3 is day 3, whatever
    # calendar date it carries).
    active_slots: set[int] = set()
    for checkin in checkins:
        moment = parse_iso(checkin.get("timestamp"))
        if moment is None:
            continue
        slot = slot_for(slots, moment)
        if slot is not None:
            active_slots.add(slot.index)
    days_active = len(active_slots)

    expected = 0
    days_without_expectation = 0
    partial_slots = 0
    per_source: dict[str, int] = {}

    for slot in slots:
        if slot.partial:
            partial_slots += 1
        weekday = _WEEKDAY_NAMES[slot.start.weekday()]
        segment = segment_for(timeline, slot.start)
        count = segment.meals_by_weekday.get(weekday) if segment else None
        if count:
            expected += count
            per_source[segment.source] = per_source.get(segment.source, 0) + count
        else:
            days_without_expectation += 1

    if expected <= 0:
        return {
            "available": False,
            "reason": "expected_meals_unavailable",
            "submitted": submitted,
            "expected": None,
            "percent": None,
            "daysActive": days_active,
            "engagementSlots": len(slots),
        }

    percent = round(min(100.0, max(0.0, submitted / expected * 100)), 1)
    result = {
        "available": True,
        "submitted": submitted,
        "expected": expected,
        "percent": percent,
        "daysActive": days_active,
        "engagementSlots": len(slots),
        # Which plan the denominator came from, so a UI can say "measured
        # against your AI plan for 3 days and your coach's version for 7"
        # instead of implying one plan covered the whole engagement.
        "expectedBySource": per_source,
    }
    # Surfaced, not silently absorbed: a window whose plan covers only some
    # weekdays produces a smaller denominator, and the reader deserves to
    # know the coverage the percentage was measured against.
    if days_without_expectation:
        result["daysWithoutPlannedMeals"] = days_without_expectation
    # An engagement ended mid-day leaves a final slot shorter than 24h. It
    # is still charged in full (the athlete entered that day and could
    # submit in it), so the fact is reported rather than prorated away.
    if partial_slots:
        result["partialSlots"] = partial_slots
    # Over-submission is a real, observable state (a retake, a second
    # helping, an extra meal). The percentage clamps at 100 so it stays
    # readable, but the raw fact is preserved rather than discarded.
    if submitted > expected:
        result["submittedExceedsExpected"] = True
    return result


def _as_number(value: Any) -> float | None:
    """Numeric coercion that refuses bools and strings-that-aren't-numbers.

    The website writes these fields from JS, where a number can arrive as a
    string; `MealCheckin.fromMap` coerces for the same reason.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def _as_int(value: Any) -> int | None:
    number = _as_number(value)
    return int(number) if number is not None else None


def _rating_of(checkin: dict) -> float | None:
    """A 1-5 rating for one reviewed check-in, or None if genuinely unrated.

    Precedence mirrors `MealCheckin.displayRating` in the Flutter model so
    the report and the app never disagree about what a meal scored:
      overallRating (1-5, what the star UI writes)
        -> score (2-10, the derived doubled value) halved
        -> reaction label, for meals reviewed before the star UI existed.
    """
    overall = _as_number(checkin.get("overallRating"))
    if overall is not None:
        return max(1.0, min(5.0, float(overall)))

    score = _as_number(checkin.get("score"))
    if score is not None:
        return max(1.0, min(5.0, float(score) / 2))

    reaction = checkin.get("reaction")
    if isinstance(reaction, str):
        mapped = _REACTION_RATING.get(reaction.strip().lower())
        if mapped is not None:
            return float(mapped)
    return None


def compute_meal_quality(checkins: Sequence[dict]) -> dict:
    """Average expert rating across REVIEWED meals only.

    `reviewedMeals` is returned alongside the average precisely so a single
    5-star meal cannot be presented as a stronger result than twenty meals
    averaging 4.2. The caller/UI is expected to show the count; this module
    refuses to hide it by returning a bare percentage.
    """
    ratings = [r for r in (_rating_of(c) for c in checkins) if r is not None]
    submitted = len(checkins)
    unrated_reviewed = sum(
        1 for c in checkins
        if str(c.get("status") or "").lower() == "reviewed" and _rating_of(c) is None
    )

    if not ratings:
        return {
            "available": False,
            "reason": "no_reviewed_meals",
            "submittedMeals": submitted,
            "reviewedMeals": 0,
            "averageRating": None,
            "percent": None,
            "highestRating": None,
            "lowestRating": None,
        }

    average = sum(ratings) / len(ratings)
    result = {
        "available": True,
        "submittedMeals": submitted,
        "reviewedMeals": len(ratings),
        "averageRating": round(average, 2),
        "percent": round(average / 5 * 100, 1),
        "highestRating": round(max(ratings), 2),
        "lowestRating": round(min(ratings), 2),
        # An explicit small-sample marker so a consumer never has to
        # rediscover that n=1 by inspecting reviewedMeals itself.
        "sampleSize": len(ratings),
        "lowConfidence": len(ratings) < 5,
    }
    if unrated_reviewed:
        result["reviewedWithoutRating"] = unrated_reviewed
    return result


def compute_expert_engagement(
    *,
    meal_reviews: int,
    meal_responses: int,
    plan_modifications: int,
    expert_messages: int,
    workout_reviews: int = 0,
) -> dict:
    """Raw counts of what the expert actually did during the engagement.

    NO 0-100 SCORE. Weighting a plan edit against a chat message requires a
    model this product does not have, and inventing one would produce a
    number that looks measured and is not. Counts are reported; scoring is
    a later, deliberate decision.
    """
    activity_count = (meal_reviews + meal_responses + plan_modifications
                      + expert_messages + workout_reviews)
    return {
        "available": True,
        "mealReviews": meal_reviews,
        "mealResponses": meal_responses,
        "planModifications": plan_modifications,
        "expertMessages": expert_messages,
        "workoutReviews": workout_reviews,
        "activityCount": activity_count,
        "percent": None,
        "scoreReason": "engagement_scoring_model_not_finalized",
    }


def compute_workout_adherence(
    *,
    activity_days: Sequence[dict],
    workout_checkins: Sequence[dict],
    window_days: int,
) -> dict:
    """What the workout record can and cannot support.

    CAN: how many days carry `workoutCompleted == true`, how many workouts
    were sent to the coach, how many of those were reviewed.

    CANNOT: true prescribed-vs-completed adherence. Workout plans in ZITLAS
    are 7-day TEMPLATES (`users/{uid}.workoutPlan`, `coaching_plans.training`)
    with no dated prescription, so "workouts missed" has no denominator that
    is not invented. `completionRateOfElapsedDays` below is explicitly named
    as a share of ELAPSED DAYS and `prescribedComparisonAvailable` is False,
    so no consumer can mistake it for the real thing.
    """
    completed_days = sum(
        1 for day in activity_days if day.get("workoutCompleted") is True)
    reviewed = sum(
        1 for c in workout_checkins
        if str(c.get("status") or "").lower() == "reviewed"
        or c.get("reviewedAt") is not None
    )
    active_days = len({
        key for key in (_checkin_day_key(c) for c in workout_checkins)
        if key is not None
    } | {
        str(day.get("date")) for day in activity_days
        if day.get("workoutCompleted") is True and day.get("date")
    })

    rate = (round(min(100.0, completed_days / window_days * 100), 1)
            if window_days > 0 else None)

    return {
        "available": "partial",
        "activeWorkoutDays": active_days,
        "completedWorkoutDays": completed_days,
        "workoutCheckins": len(workout_checkins),
        "reviewedWorkoutCheckins": reviewed,
        "windowDays": window_days,
        "completionRateOfElapsedDays": rate,
        "prescribedComparisonAvailable": False,
        "missing": ["dated_prescribed_workouts"],
        "limitation": (
            "Workout plans are 7-day templates with no dated prescription, so "
            "'workouts prescribed' and 'workouts missed' cannot be derived. "
            "completionRateOfElapsedDays is the share of elapsed days marked "
            "complete — it is NOT prescribed-vs-completed adherence."
        ),
    }


def compute_plan_adherence(meal_follow_through: dict, workout: dict) -> dict:
    """The real components, named — not a blended percentage.

    A single adherence number would have to average a meal percentage that
    has a genuine denominator against a workout figure that does not. The
    components are returned side by side, and `missing` names what would be
    required to make a combined figure meaningful.
    """
    components: dict[str, Any] = {}
    if meal_follow_through.get("available") is True:
        components["mealFollowThrough"] = meal_follow_through.get("percent")
    else:
        components["mealFollowThrough"] = None
    components["workoutActivity"] = workout.get("completionRateOfElapsedDays")
    components["completedWorkoutDays"] = workout.get("completedWorkoutDays")

    has_any = any(v is not None for v in components.values())
    return {
        "available": "partial" if has_any else False,
        "percent": None,
        "components": components,
        "missing": [
            "dated_prescribed_workouts",
            "verified_recommendation_completion",
        ],
        "reason": "composite_adherence_model_not_finalized",
    }


def compute_follow_up() -> dict:
    """Always unavailable — the underlying tracking does not exist.

    The Step 1 audit found no follow-up entity anywhere in the codebase:
    no collection, no field, and no record of an athlete acting on an
    expert recommendation. `coaching_meal_requests.status` records that the
    EXPERT replied, never that the athlete followed the advice.

    This is a function rather than a constant so the shape stays consistent
    with every other metric, and so the day follow-up tracking ships there
    is exactly one place to change.
    """
    return {
        "available": False,
        "percent": None,
        "reason": "follow_up_completion_not_tracked",
    }


def compute_progress(
    *,
    weight_entries: Sequence[dict],
    activity_days: Sequence[dict],
    current_streak: Any = None,
    longest_streak: Any = None,
) -> dict:
    """Raw progress values over the window.

    `weight_entries` must be ordered oldest-first by the caller.

    DELIBERATELY UNJUDGED. A weight change is reported as a signed number
    and nothing more: whether -2kg is progress depends on the athlete's
    goal, and this module does not read goals. Labelling it "improved"
    would be wrong for anyone bulking.
    """
    progress: dict[str, Any] = {
        "startingWeightKg": None,
        "endingWeightKg": None,
        "weightChangeKg": None,
        "weightChangePercent": None,
        "weightEntries": len(weight_entries),
        "weightInterpretation": "not_evaluated_goal_unknown",
    }

    weights = [(w, _as_number(w.get("weightKg"))) for w in weight_entries]
    weights = [(entry, value) for entry, value in weights if value is not None]

    if len(weights) >= 2:
        first, last = weights[0][1], weights[-1][1]
        progress["startingWeightKg"] = round(first, 2)
        progress["endingWeightKg"] = round(last, 2)
        progress["weightChangeKg"] = round(last - first, 2)
        if first > 0:
            progress["weightChangePercent"] = round((last - first) / first * 100, 2)
    elif len(weights) == 1:
        # One reading is a data point, not a trend. Recorded as both ends so
        # the value is not lost, with the delta left None rather than 0 —
        # "no change measured" and "changed by zero" are different claims.
        only = weights[0][1]
        progress["startingWeightKg"] = round(only, 2)
        progress["endingWeightKg"] = round(only, 2)
        progress["insufficientWeightData"] = True

    steps = [s for s in (_as_number(d.get("steps")) for d in activity_days)
             if s is not None]
    water = [w for w in (_as_number(d.get("waterMl")) for d in activity_days)
             if w is not None]
    sleep = [s for s in (_as_number(d.get("sleepHours")) for d in activity_days)
             if s is not None]

    progress["steps"] = {
        "daysRecorded": len(steps),
        "total": int(sum(steps)) if steps else None,
        "dailyAverage": round(sum(steps) / len(steps), 1) if steps else None,
    }
    progress["water"] = {
        "daysRecorded": len(water),
        "dailyAverageMl": round(sum(water) / len(water), 1) if water else None,
    }
    progress["sleep"] = {
        "daysRecorded": len(sleep),
        "dailyAverageHours": round(sum(sleep) / len(sleep), 2) if sleep else None,
    }
    progress["streak"] = {
        "current": _as_int(current_streak),
        "longest": _as_int(longest_streak),
    }
    progress["activityDaysRecorded"] = len(activity_days)
    return progress


def compute_overall() -> dict:
    """Always unavailable at reportVersion 1.0.

    Two of the seven intended inputs (follow-up completion, prescribed
    workout adherence) do not exist in the data, and no agreed weighting
    exists for the five that do. Producing a number now would fix an
    arbitrary model into the first reports ever shown, which later tuning
    could not retroactively correct.
    """
    return {
        "available": False,
        "percent": None,
        "reason": "scoring_model_not_finalized",
    }


# ══════════════════════════════════════════════════════════════════════════
# FIRESTORE READS — every function below is read-only by construction.
# There is no .set(), .update(), .delete() or transaction anywhere in this
# module. Grep it and confirm.
# ══════════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class Engagement:
    """The resolved coaching engagement `request_id` names."""

    athlete_id: str
    request_id: str
    coach_id: str | None
    coach_name: str | None
    coaching_type: str | None
    trial_duration_days: int | None
    start: datetime
    scheduled_end: datetime
    effective_end: datetime
    status: str | None
    ended_at: str | None
    expired_at: str | None
    plan_type: str | None
    plan_label: str | None
    fee: Any
    payment_id: str | None
    subscription_id: str | None
    raw: dict


def _load_engagement(db, athlete_uid: str, request_id: str,
                     now: datetime) -> Engagement:
    """The engagement, or EngagementUnavailable with a specific reason.

    Verifies `requestId` matches before using ANY field of the relationship
    document. See the module docstring: this document is keyed by athlete
    and overwritten on the next accept, so a mismatch means the requested
    engagement's dates are simply gone — not that a different engagement
    should be reported in its place.
    """
    snap = db.collection("personal_coaching").document(athlete_uid).get()
    rel = snap.to_dict() if snap.exists else None
    if not rel:
        raise EngagementUnavailable(
            f"no personal_coaching document for athlete {athlete_uid!r}")

    stored_request_id = rel.get("requestId")
    # A Personal Coaching Program's relationship carries its own id in
    # `programRequestId` (routes/coaching_programs.py) and no escrow
    # `requestId`; either identity names the engagement.
    program_request_id = rel.get("programRequestId")
    if not request_id or request_id not in (stored_request_id, program_request_id):
        raise EngagementUnavailable(
            f"engagement {request_id!r} is not the athlete's current "
            f"relationship (that document holds requestId="
            f"{stored_request_id!r}, programRequestId={program_request_id!r}). "
            f"personal_coaching/{{athleteId}} is "
            f"overwritten on each new accept, so this engagement's dates no "
            f"longer exist. Refusing to substitute a different engagement."
        )

    start = parse_iso(rel.get("startDate"))
    scheduled_end = parse_iso(rel.get("endDate"))
    if start is None or scheduled_end is None:
        raise EngagementUnavailable(
            f"engagement {request_id!r} has unusable dates "
            f"(startDate={rel.get('startDate')!r}, "
            f"endDate={rel.get('endDate')!r})")

    # The window can only cover time that actually elapsed. An engagement
    # ended on day 3 of 10 must not be measured against 10 days of expected
    # meals, and one still running must not be measured against days that
    # have not happened yet.
    candidates = [scheduled_end, now]
    for key in ("endedAt", "expiredAt"):
        moment = parse_iso(rel.get(key))
        if moment is not None:
            candidates.append(moment)
    effective_end = min(candidates)
    if effective_end < start:
        effective_end = start

    return Engagement(
        athlete_id=rel.get("athleteId") or athlete_uid,
        request_id=request_id,
        coach_id=rel.get("coachId"),
        coach_name=rel.get("coachName"),
        coaching_type=rel.get("coachingType"),
        trial_duration_days=_as_int(rel.get("trialDurationDays")),
        start=start,
        scheduled_end=scheduled_end,
        effective_end=effective_end,
        status=rel.get("status"),
        ended_at=rel.get("endedAt"),
        expired_at=rel.get("expiredAt"),
        plan_type=rel.get("planType"),
        plan_label=rel.get("planLabel"),
        fee=rel.get("fee"),
        payment_id=rel.get("paymentId"),
        subscription_id=rel.get("subscriptionId"),
        raw=rel,
    )


def _stream_dicts(query) -> list[dict]:
    """Documents from a query as plain dicts. Never raises on a missing
    collection — an engagement with no chat is a valid engagement."""
    try:
        return [d.to_dict() or {} for d in query.stream()]
    except Exception as exc:  # noqa: BLE001 — one absent index/collection
        # must not lose the whole report; the gap shows in dataQuality.
        print(f"[TRIAL REPORT] query failed ({type(exc).__name__}: {exc}) "
              f"— treating as empty")
        return []


def _filter_window(records: Iterable[dict], field: str,
                   start: datetime, end: datetime) -> list[dict]:
    """Records whose `field` timestamp falls inside the window.

    Filtering happens HERE rather than in the Firestore query on purpose:
      * `meal_checkins.timestamp` is an ISO string, so an inequality query
        would need a composite index this project has not declared;
      * the equality-only query below (athleteId, then coachId in memory) is
        exactly the shape firestore.rules permits, matching the pattern
        coaching-workspace.js already uses for its weekly review.
    """
    return [r for r in records if _in_window(r.get(field), start, end)]


def _load_meal_checkins(db, engagement: Engagement) -> list[dict]:
    query = db.collection("meal_checkins").where(
        "athleteId", "==", engagement.athlete_id)
    records = _stream_dicts(query)
    # coachId is matched in memory so an engagement is never credited with a
    # different coach's check-ins, without needing a composite index.
    if engagement.coach_id:
        records = [r for r in records if r.get("coachId") == engagement.coach_id]
    return _filter_window(records, "timestamp",
                          engagement.start, engagement.effective_end)


def _load_workout_checkins(db, engagement: Engagement) -> list[dict]:
    query = db.collection("workout_checkins").where(
        "athleteId", "==", engagement.athlete_id)
    records = _stream_dicts(query)
    if engagement.coach_id:
        records = [r for r in records if r.get("coachId") == engagement.coach_id]
    return _filter_window(records, "timestamp",
                          engagement.start, engagement.effective_end)


def _load_meal_requests(db, engagement: Engagement) -> list[dict]:
    query = db.collection("coaching_meal_requests").where(
        "athleteId", "==", engagement.athlete_id)
    records = _stream_dicts(query)
    if engagement.coach_id:
        records = [r for r in records if r.get("coachId") == engagement.coach_id]
    return records


def _load_activity_days(db, engagement: Engagement,
                        keys: Sequence[str]) -> list[dict]:
    """`users/{uid}/activity/{date}` for each day in the window.

    Fetched by document id rather than by range query: the ids ARE the
    dates, so this needs no index and cannot over-read a neighbouring day.
    """
    collection = (db.collection("users").document(engagement.athlete_id)
                  .collection("activity"))
    days: list[dict] = []
    for key in keys:
        try:
            snap = collection.document(key).get()
        except Exception:  # noqa: BLE001
            continue
        if snap.exists:
            data = snap.to_dict() or {}
            data.setdefault("date", key)
            days.append(data)
    return days


def _load_weight_entries(db, engagement: Engagement,
                         keys: Sequence[str]) -> list[dict]:
    """`users/{uid}/weight_log/{date}`, oldest first — `keys` is already
    chronological, so the order the caller needs falls out for free."""
    collection = (db.collection("users").document(engagement.athlete_id)
                  .collection("weight_log"))
    entries: list[dict] = []
    for key in keys:
        try:
            snap = collection.document(key).get()
        except Exception:  # noqa: BLE001
            continue
        if snap.exists:
            data = snap.to_dict() or {}
            data.setdefault("date", key)
            entries.append(data)
    return entries


def _load_plan_versions(db, engagement: Engagement) -> list[dict]:
    """EVERY version in `coaching_plans/{uid}/versions` — not just the ones
    inside the window.

    Versions before the engagement are needed twice: to establish the
    modification baseline (so a save that merely re-persists a pre-existing
    plan is not counted as a change), and to know what plan was already in
    force when the engagement began.
    """
    versions = (db.collection("coaching_plans").document(engagement.athlete_id)
                .collection("versions"))
    return _stream_dicts(versions)


def _load_expert_messages(db, engagement: Engagement) -> int:
    """Messages the COACH sent in the window.

    Room id is `chat_{athleteId}_{coachId}` — the convention `chatId()` in
    coaching-workspace.js, cprofile.js and diet.js all build.
    """
    if not engagement.coach_id:
        return 0
    room_id = f"chat_{engagement.athlete_id}_{engagement.coach_id}"
    messages = (db.collection("chat_rooms").document(room_id)
                .collection("messages"))
    records = _stream_dicts(messages)
    in_window = _filter_window(records, "timestamp",
                               engagement.start, engagement.effective_end)
    return sum(1 for m in in_window
               if m.get("senderId") == engagement.coach_id
               or str(m.get("senderType") or "").lower() == "expert")


def _load_coach_plan(db, engagement: Engagement) -> dict:
    """The current `coaching_plans/{uid}` document."""
    snap = (db.collection("coaching_plans")
            .document(engagement.athlete_id).get())
    return (snap.to_dict() or {}) if snap.exists else {}


def _load_user_doc(db, engagement: Engagement) -> dict:
    snap = db.collection("users").document(engagement.athlete_id).get()
    return (snap.to_dict() or {}) if snap.exists else {}


# ══════════════════════════════════════════════════════════════════════════
# ORCHESTRATION
# ══════════════════════════════════════════════════════════════════════════


def compute_trial_report(athlete_uid: str, request_id: str, *,
                         db: Any = None, now: datetime | None = None) -> dict:
    """The report for one coaching engagement. Reads only; writes nothing.

    Args:
        athlete_uid: the athlete whose engagement this is.
        request_id:  THE engagement identity. A relationship document whose
                     `requestId` differs raises EngagementUnavailable rather
                     than reporting on a different engagement.
        db:          Firestore client override, for tests. Defaults to
                     `firestore_service.get_client()`.
        now:         clock override, for deterministic tests.

    Raises:
        EngagementUnavailable: the engagement cannot be resolved, or
            Firestore is not configured.
    """
    moment = now or datetime.now(timezone.utc)
    client = db if db is not None else firestore_service.get_client()
    if client is None:
        raise EngagementUnavailable(
            "Firestore is not configured — "
            f"{firestore_service.config_error() or 'no client available'}")

    engagement = _load_engagement(client, athlete_uid, request_id, moment)
    # TWO DAY MODELS, ON PURPOSE. Meal expectations use elapsed 24-hour
    # engagement slots so a 10-day trial is measured over exactly ten days;
    # activity/weight documents are addressed by their own calendar-date
    # ids and keep those. Documented in dataQuality.dayModels.
    keys = date_keys(engagement.start, engagement.effective_end)
    slots = engagement_slots(engagement.start, engagement.effective_end)

    meal_checkins = _load_meal_checkins(client, engagement)
    workout_checkins = _load_workout_checkins(client, engagement)
    meal_requests = _load_meal_requests(client, engagement)
    activity_days = _load_activity_days(client, engagement, keys)
    weight_entries = _load_weight_entries(client, engagement, keys)
    plan_versions = _load_plan_versions(client, engagement)
    expert_messages = _load_expert_messages(client, engagement)
    coach_plan = _load_coach_plan(client, engagement)
    user_doc = _load_user_doc(client, engagement)

    # AI plan -> coach customisation -> athlete follow-through. The timeline
    # is what makes the denominator date-accurate instead of pricing the
    # whole engagement against whatever plan happens to exist right now.
    timeline = build_plan_timeline(
        start=engagement.start,
        end=engagement.effective_end,
        ai_plan=user_doc.get("dietPlan"),
        ai_plan_id=user_doc.get("planId"),
        coach_versions=plan_versions,
    )
    modifications = count_coach_modifications(
        plan_versions, engagement.start, engagement.effective_end)
    plan_modifications = modifications["modifications"]

    follow_through = compute_meal_follow_through(
        meal_checkins, slots=slots, timeline=timeline)
    quality = compute_meal_quality(meal_checkins)

    meal_reviews = sum(
        1 for c in meal_checkins
        if _in_window(c.get("reviewedAt"),
                      engagement.start, engagement.effective_end)
    )
    meal_responses = len(_filter_window(
        meal_requests, "repliedAt", engagement.start, engagement.effective_end))
    workout_reviews = sum(
        1 for c in workout_checkins
        if _in_window(c.get("reviewedAt"),
                      engagement.start, engagement.effective_end)
    )
    engagement_metrics = compute_expert_engagement(
        meal_reviews=meal_reviews,
        meal_responses=meal_responses,
        plan_modifications=plan_modifications,
        expert_messages=expert_messages,
        workout_reviews=workout_reviews,
    )

    workout = compute_workout_adherence(
        activity_days=activity_days,
        workout_checkins=workout_checkins,
        # Workout completion is read from calendar-keyed activity documents,
        # so its denominator stays on the calendar model.
        window_days=len(keys),
    )
    plan_adherence = compute_plan_adherence(follow_through, workout)
    progress = compute_progress(
        weight_entries=weight_entries,
        activity_days=activity_days,
        current_streak=user_doc.get("currentStreak"),
        longest_streak=user_doc.get("longestStreak"),
    )

    return {
        "reportVersion": REPORT_VERSION,
        "engagementId": engagement.request_id,
        "athleteId": engagement.athlete_id,
        "generatedAt": moment.isoformat(),

        "period": {
            "startDate": engagement.start.isoformat(),
            "endDate": engagement.scheduled_end.isoformat(),
            "effectiveEndDate": engagement.effective_end.isoformat(),
            "durationDays": max(
                0,
                (engagement.scheduled_end.date() - engagement.start.date()).days),
            # The engagement's real length, in elapsed 24h slots. A 10-day
            # trial is 10 here even though it touches 11 calendar dates.
            "elapsedDays": len(slots),
            "calendarDatesTouched": len(keys),
            "trialDurationDays": engagement.trial_duration_days,
            "coachingType": engagement.coaching_type,
            "status": engagement.status,
            "endedAt": engagement.ended_at,
            "expiredAt": engagement.expired_at,
        },

        "plan": {
            "type": engagement.plan_type,
            "label": engagement.plan_label,
            "fee": engagement.fee,
            "paymentId": engagement.payment_id,
            "subscriptionId": engagement.subscription_id,
        },

        "coach": {
            "id": engagement.coach_id,
            "name": engagement.coach_name,
        },

        "metrics": {
            "mealFollowThrough": follow_through,
            "mealQuality": quality,
            "expertEngagement": engagement_metrics,
            "workoutAdherence": workout,
            "planAdherence": plan_adherence,
            "followUp": compute_follow_up(),
            "progress": progress,
            "planEvolution": _plan_evolution(
                timeline=timeline, modifications=modifications,
                coach_plan=coach_plan),
            "overall": compute_overall(),
        },

        "activity": {
            "mealCheckins": len(meal_checkins),
            "workoutCheckins": len(workout_checkins),
            "mealRequests": len(meal_requests),
            "activityDaysRecorded": len(activity_days),
            "weightEntries": len(weight_entries),
            "planSaves": modifications["planSaves"],
            "planModifications": plan_modifications,
            "expertMessages": expert_messages,
        },

        "dataQuality": _data_quality(
            follow_through=follow_through,
            quality=quality,
            timeline=timeline,
            activity_days=activity_days,
            keys=keys,
            slots=slots,
            engagement=engagement,
        ),
    }


def _plan_evolution(*, timeline: Sequence[PlanSegment], modifications: dict,
                    coach_plan: dict) -> dict:
    """AI plan -> coach customisation, as the product actually works.

    WORDING THIS EXISTS TO PREVENT. "Your coach created your diet plan" is
    false in ZITLAS: the coach's editor is preloaded from the athlete's
    AI-generated plan and the workspace banners exactly that. So this block
    reports `startedFrom` and a modification COUNT, letting a consumer say
    "your AI-generated plan was customised by your coach" or "your coach
    made 6 modifications to your nutrition plan" — never that the coach
    authored it.

    `customizationConfirmed` is True only when a coach save inside the
    engagement genuinely changed the plan's content, so the report cannot
    claim customisation on the strength of a redundant autosave.
    """
    coach_segments = [s for s in timeline if s.source != SOURCE_AI]
    started_from = timeline[0].source if timeline else None
    from_template = any(s.source == SOURCE_COACH_TEMPLATE for s in timeline)

    return {
        "available": True,
        "startedFrom": started_from,
        "aiPlanApplied": any(s.source == SOURCE_AI for s in timeline),
        "coachCustomizedPlanApplied": bool(coach_segments),
        "customizationConfirmed": modifications["modifications"] > 0,
        "coachAuthoredFromBlankTemplate": from_template,
        "planSaves": modifications["planSaves"],
        "modifications": modifications["modifications"],
        "redundantSaves": modifications["redundantSaves"],
        "firstModifiedAt": modifications["firstModifiedAt"],
        "lastModifiedAt": modifications["lastModifiedAt"],
        "modifiedBy": modifications["modifiedBy"],
        "hadPriorPlanBeforeEngagement":
            modifications["hadPriorPlanBeforeEngagement"],
        "currentDietVersion": _as_int(coach_plan.get("dietVersion")),
        "currentTrainingVersion": _as_int(coach_plan.get("trainingVersion")),
        "segments": [s.as_dict() for s in timeline],
        # Phrasing the data supports, so a UI never has to invent it.
        "wording": (
            "coach_customized_ai_plan" if modifications["modifications"] > 0
            else ("coach_authored_from_template" if from_template
                  else "ai_plan_only")),
    }


def _data_quality(*, follow_through: dict, quality: dict,
                  timeline: Sequence[PlanSegment],
                  activity_days: Sequence[dict],
                  keys: Sequence[str], slots: Sequence[EngagementSlot],
                  engagement: Engagement) -> dict:
    """Every limitation this report carries, stated plainly.

    Present so a consumer never has to infer a caveat from a null. The first
    three are permanent properties of the current data model, not conditions
    of any particular engagement.
    """
    warnings = [
        "Follow-up completion is not currently tracked "
        "(no expert-recommendation -> athlete-completion record exists).",
        "True prescribed workout adherence is not available — workout plans "
        "are 7-day templates with no dated prescription.",
        "Overall ZITLAS Score is not computed: the scoring model is not "
        "finalized and two of its intended inputs do not exist.",
    ]

    if follow_through.get("available") is not True:
        warnings.append(
            "Expected meals could not be derived from the coach-authored diet "
            "plan, so meal follow-through has no denominator. No default "
            "meals-per-day was assumed.")
    else:
        warnings.append(
            "Expected meals are priced per day against the plan in force that "
            "day (AI plan before the coach's first save, then each saved coach "
            "version), not against a single plan for the whole engagement.")
        # Meal expectations run on elapsed 24h slots, so the old
        # eleven-calendar-dates-for-a-ten-day-trial inflation is gone. What
        # remains disclosable is a final slot cut short by an early end.
        partial = [s for s in slots if s.partial]
        if partial:
            warnings.append(
                f"The engagement ended part-way through day {partial[0].index}. "
                f"That day is still charged a full day of expected meals, "
                f"because meals submitted in it are counted too — it is not "
                f"prorated, since which meals fell inside the window is not "
                f"recorded.")

    if follow_through.get("submittedExceedsExpected"):
        warnings.append(
            "More meals were submitted than the plan expected; the percentage "
            "is clamped to 100.")

    if quality.get("available") is True and quality.get("lowConfidence"):
        warnings.append(
            f"Meal quality averages only {quality.get('reviewedMeals')} "
            f"reviewed meal(s) — too small to generalise.")
    elif quality.get("available") is not True:
        warnings.append("No expert-reviewed meals in this period.")

    if not timeline:
        warnings.append(
            "No plan history could be reconstructed for this engagement.")
    else:
        blind = [s for s in timeline if not s.available]
        for segment in blind:
            if segment.source == SOURCE_AI:
                warnings.append(
                    "The AI plan that applied before the coach's first save "
                    "could not be verified as unchanged (users/{uid}.dietPlan "
                    "holds only the current generation and its planId no "
                    "longer matches), so those days carry no meal "
                    "expectation rather than a guessed one.")
            else:
                warnings.append(
                    f"A coach plan version saved at {segment.saved_at} "
                    f"contained no readable meals, so its days carry no "
                    f"expectation.")

    if len(activity_days) < len(keys):
        warnings.append(
            f"Activity records exist for {len(activity_days)} of {len(keys)} "
            f"days in the period.")

    warnings.append(
        "Meal expectations use elapsed 24-hour engagement days; activity and "
        "weight use device-local calendar dates, because those documents are "
        "addressed by date. The two models can disagree by up to one day at "
        "the edges for athletes far from UTC.")

    return {
        "warnings": warnings,
        "dayModels": {
            "mealExpectations": "elapsed_24h_engagement_slots",
            "activityAndWeight": "device_local_calendar_dates",
            "engagementSlots": len(slots),
            "calendarDatesTouched": len(keys),
        },
        "expectedMealsSource": (
            "plan_timeline(users.dietPlan + coaching_plans/versions)"
            if any(s.available for s in timeline) else "unavailable"),
        "planSegments": len(timeline),
        "planSegmentsWithoutExpectation": sum(
            1 for s in timeline if not s.available),
        "activityDayCoverage": {
            "recorded": len(activity_days),
            "inPeriod": len(keys),
        },
    }
