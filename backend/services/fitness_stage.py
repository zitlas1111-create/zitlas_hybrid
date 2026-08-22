"""
ZITLAS — Starting fitness level (backend/services/fitness_stage.py)

    BEGINNER → NOVICE → INTERMEDIATE → ADVANCED → LEGEND

WHY THIS EXISTS. The workout prompt already branched on `fitness_level`, but
only the General Fitness flow ever ASKED for one. Weight Loss and Muscle Gain
derived it from BMI alone (routes/assessment.py):

    BMI > 35  -> Beginner       BMI 25-30 -> Intermediate
    BMI 30-35 -> Beginner       BMI < 25  -> Advanced

So a sedentary athlete at BMI 23 who cannot climb three floors was classified
ADVANCED and handed jump squats and interval cardio. BMI describes a body, not
an ability, and the two come apart exactly where it matters most.

WHAT THIS DOES. It reads several weak signals and combines them into one
level, on a simple rule: a CLAIM can be capped by DEMONSTRATED ABILITY, and
ability can lift somebody a little above what they claim.

    "I'm advanced" + sedentary + stairs are difficult  ->  BEGINNER
    "I'm new"      + active    + stairs are easy       ->  NOVICE

Nobody is diagnosed and nothing is scored out of ten. Every input is optional:
an athlete who answered none of the new questions resolves exactly the way
they did before this file existed, so existing users keep their plans.

LEGEND IS NOT REACHABLE FROM AN ASSESSMENT. It is the far end of the journey,
earned by training over time — telling a new athlete they are a legend because
they clicked "I train a lot" would make the whole ladder meaningless.
"""

from __future__ import annotations

# ── The ladder ───────────────────────────────────────────────────────────────

BEGINNER = "beginner"
NOVICE = "novice"
INTERMEDIATE = "intermediate"
ADVANCED = "advanced"
LEGEND = "legend"

#: In order. Index arithmetic below relies on this.
LADDER: list[str] = [BEGINNER, NOVICE, INTERMEDIATE, ADVANCED, LEGEND]

#: The highest an ASSESSMENT can place somebody. Legend is earned, not claimed.
MAX_ASSESSED = ADVANCED

#: Friendly, non-clinical copy for the "your starting level" card.
LADDER_COPY: dict[str, dict[str, str]] = {
    BEGINNER: {
        "emoji": "🌱",
        "title": "Beginner",
        "blurb": "That's completely fine — everyone starts here. "
                 "We'll build you up step by step.",
    },
    NOVICE: {
        "emoji": "🙂",
        "title": "Novice",
        "blurb": "You've got a base to work with. "
                 "We'll add a little more each week.",
    },
    INTERMEDIATE: {
        "emoji": "💪",
        "title": "Intermediate",
        "blurb": "You're comfortable with the basics. "
                 "Time to push a bit harder.",
    },
    ADVANCED: {
        "emoji": "🔥",
        "title": "Advanced",
        "blurb": "You train seriously. Your plan will keep up with you.",
    },
    LEGEND: {
        "emoji": "👑",
        "title": "Legend",
        "blurb": "Long-term mastery. Keep going.",
    },
}


def _index(level: str) -> int:
    try:
        return LADDER.index((level or "").strip().lower())
    except ValueError:
        return -1


def next_level(level: str) -> str | None:
    """The rung above `level`, or None at the top — for "what's next" copy."""
    i = _index(level)
    if i < 0 or i >= len(LADDER) - 1:
        return None
    return LADDER[i + 1]


# ── Signal normalisation ─────────────────────────────────────────────────────
#
# Every map below tolerates the value being absent, empty, or something this
# module has never seen. An unknown answer contributes NOTHING rather than
# defaulting to a guess in either direction.

#: "How much workout experience do you have?" — the athlete's own claim.
_EXPERIENCE_CLAIM: dict[str, str] = {
    "beginner": BEGINNER,          # "I'm completely new"
    "complete_beginner": BEGINNER,
    "novice": NOVICE,              # "I've tried a few times"
    "intermediate": INTERMEDIATE,  # "I work out sometimes"
    "advanced": ADVANCED,          # "I work out regularly"
}

#: Practical ability, scored -2 (struggles) .. +1 (easy). These are capability
#: EVIDENCE, which is why they can override a claim.
_ABILITY_SCORE: dict[str, int] = {
    "easy": 1,        # "Yes, easily"
    "okay": 0,        # "Yes, but a little tired"
    "tired": -1,      # "I need a short break" / "I get tired"
    "difficult": -2,  # "It's difficult for me"
}

#: Daily activity, already collected by every flow.
_ACTIVITY_SCORE: dict[str, int] = {
    "sedentary": -1,
    "light": 0,
    "moderate": 1,
    "active": 1,
    "very_active": 1,
}


def _ability_signals(*answers: str) -> list[int]:
    """Scores for the practical questions that were actually answered."""
    return [
        _ABILITY_SCORE[a.strip().lower()]
        for a in answers
        if a and a.strip().lower() in _ABILITY_SCORE
    ]


def resolve_stage(
    *,
    workout_experience: str = "",
    fitness_level: str = "",
    activity_level: str = "",
    stair_ability: str = "",
    walk_ability: str = "",
    squat_ability: str = "",
    bmi: float | None = None,
    medical_restricted: bool = False,
) -> str:
    """The athlete's STARTING level, from everything that is known.

    `workout_experience` is the new question; `fitness_level` is General
    Fitness's existing one — whichever is present acts as the claim, and they
    are never both asked, so there is no duplicate question anywhere.

    Returns one of BEGINNER / NOVICE / INTERMEDIATE / ADVANCED.
    """
    claim = _EXPERIENCE_CLAIM.get((workout_experience or "").strip().lower())
    if claim is None:
        claim = _EXPERIENCE_CLAIM.get((fitness_level or "").strip().lower())

    abilities = _ability_signals(stair_ability, walk_ability, squat_ability)
    activity = _ACTIVITY_SCORE.get((activity_level or "").strip().lower())

    # ── Nothing new was answered ──
    # An existing athlete, or one who skipped the new questions. Fall back to
    # exactly what the system did before: the claim if there is one, otherwise
    # the BMI reading. Their plan does not change.
    if claim is None and not abilities:
        return _from_bmi(bmi)

    if claim is None:
        # Ability without a claim (General Fitness before its fitness_level is
        # known, say). Start from the middle and let the evidence move it.
        claim = NOVICE

    level = _index(claim)

    if abilities:
        avg = sum(abilities) / len(abilities)

        # CAPABILITY CAPS A CLAIM. Somebody who cannot climb three floors does
        # not get an advanced programme because they ticked "I train a lot" —
        # this is the safety half of the rule, so it is a hard ceiling rather
        # than a nudge.
        if avg <= -1.5:
            level = min(level, _index(BEGINNER))
        elif avg <= -0.5:
            level = min(level, _index(NOVICE))
        elif avg < 0.5:
            level = min(level, _index(INTERMEDIATE))

        # ABILITY ALSO LIFTS. A beginner who finds all of it easy is not
        # incapable, and treating them as such is its own kind of wrong —
        # but only by one rung, because self-reported ease is weak evidence.
        if avg >= 0.5 and level < _index(ADVANCED):
            level += 1

    # Daily activity is a supporting signal, never a decisive one: it can move
    # somebody one rung, and only when the practical answers agree with it.
    if activity is not None and abilities:
        avg = sum(abilities) / len(abilities)
        if activity <= -1 and avg <= 0:
            level = max(0, level - 1)

    # ── Bodyweight ceiling ──
    # Joint loading really IS a function of bodyweight, so this survives any
    # claim and any demonstrated ease. It is the one thing the old BMI ladder
    # got right, kept here rather than in one route so that EVERY consumer
    # inherits it — including workout_engine's difficulty band, which would
    # otherwise hand advanced-difficulty exercises to a BMI-38 athlete who
    # ticked "I work out regularly".
    if bmi is not None:
        if bmi > 35:
            level = min(level, _index(BEGINNER))
        elif bmi > 30:
            level = min(level, _index(NOVICE))

    # ── Safety last, and it can only lower ──
    # A medical restriction never raises a level and never gets overridden by
    # a confident claim. medical_conditions.py stays the final authority on
    # what may actually be prescribed; this only keeps the starting point
    # conservative.
    if medical_restricted:
        level = min(level, _index(NOVICE))

    level = max(0, min(level, _index(MAX_ASSESSED)))
    return LADDER[level]


def _from_bmi(bmi: float | None) -> str:
    """The pre-existing behaviour, preserved for athletes with no new answers.

    Kept deliberately: it is what every current user's plan was built from, so
    changing it would silently re-level people who never asked for it.
    """
    if bmi is None:
        return BEGINNER
    if bmi > 30:
        return BEGINNER
    if bmi > 25:
        return INTERMEDIATE
    return INTERMEDIATE  # never ADVANCED on body composition alone


def describe(level: str) -> dict:
    """Everything the "your starting level" card needs, ready to render."""
    key = (level or "").strip().lower()
    copy = LADDER_COPY.get(key, LADDER_COPY[BEGINNER])
    nxt = next_level(key)
    return {
        "level": key or BEGINNER,
        "emoji": copy["emoji"],
        "title": copy["title"],
        "blurb": copy["blurb"],
        "ladder": [LADDER_COPY[s]["title"] for s in LADDER],
        "position": max(0, _index(key)),
        "next": LADDER_COPY[nxt]["title"] if nxt else None,
    }
