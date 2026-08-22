"""
ZITLAS — Meal-specific recipe + video (backend/services/meal_recipe_service.py)

THE DISH THE ATHLETE SEES IS THE PRIMARY KEY, end to end.

WHAT WAS WRONG: the Diet page's recipe button carried `meal.meal_name`, which
in the ZITLAS plan schema is the SLOT ("Breakfast"/"Lunch"/"Dinner"/"Snacks") —
the dish itself lives in `meal.foods[]`. The dish was therefore discarded at the
very first hop, and the recipe page asked
`/api/recipes/recommended?meal_type=breakfast`, i.e. "give me *a* breakfast
recipe". A scored pick out of a 637-recipe pool reads as random, because with
respect to the dish it *is* random.

WHY A CATALOGUE LOOKUP CANNOT FIX IT: `recipes/data/zitlas_recipes.json` is 637
ZITLAS-ORIGINAL recipes (every single name is prefixed "ZITLAS"). Diet plans are
built from the 4,520-food dataset. Measured exact-name overlap: 13 / 4,520
(0.3%). "Masala Oats with Vegetables" simply is not in there, so no amount of
query fixing can return "the recipe for it".

So the recipe for the exact dish is GENERATED, then cached under the dish name.
The cache is what makes it deterministic: the same meal always renders the same
recipe (never a different one on a second click), and a repeat click costs no
LLM call.

The YouTube video is searched on the dish name and then VALIDATED — a video that
is not demonstrably about this dish is dropped rather than shown, because an
unrelated video is worse than no video.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any

from services import firestore_service

# Firestore cache: one document per distinct dish.
CACHE_COLLECTION = "meal_recipes"

# Recipes are cached indefinitely — a dish's recipe does not go stale, and
# stability is the point (requirement: the same meal must not switch recipes).
# Bump this when the generation prompt changes in a way that should invalidate
# everything previously produced.
RECIPE_SCHEMA_VERSION = 1

# A video must clear this to be shown at all. Below it we show the recipe with
# an explicit "no exact cooking video found" note instead of a loose match.
MIN_VIDEO_RELEVANCE = 0.62

#: THE DURATION WINDOW: 20s <= video <= 90s, both ends hard.
#:
#: Below 20s nothing can be demonstrated — that is the pour-and-serve tier
#: that produced the original complaint ("Peanut Butter Banana Shake" came
#: back as a 12-second clip of a finished shake). Above 90s the athlete is
#: being sent to a full cooking show when they wanted to see how to make one
#: meal.
#:
#: Duration is NOT a preference — a 25s video is not better than an 85s one.
#: Among candidates inside the window the clearest PREPARATION wins; see
#: `score_video`.
MIN_VIDEO_SECONDS = 20
MAX_VIDEO_SECONDS = 90

#: How many recipe-specific variants to try before giving up. Each is a
#: `search.list` call at 100 quota units, and the loop stops as soon as a
#: strong verified candidate appears — so a dish with an obvious tutorial
#: costs one search and a hard one costs several. Never a generic query.
_MAX_QUERIES = 4
#: Of those, how many to repeat WITHOUT YouTube's `videoDuration=short`
#: filter. That bucket is Shorts-dominated; an unfiltered pass is where the
#: ordinary 20-90s uploads actually are.
_MAX_UNFILTERED_QUERIES = 3


def is_duration_allowed(seconds: Any) -> bool:
    """THE duration rule. 20s <= d <= 90s, and nothing else.

    Every gate in this module calls this — the search ceiling, the scorer and
    the selection filter — so the window is stated once and cannot drift
    between them.

    An unknown, zero or unparseable duration is REJECTED. Fail closed: not
    being able to prove a video is inside the window is not permission to
    show it.
    """
    try:
        d = int(seconds)
    except (TypeError, ValueError):
        return False
    return MIN_VIDEO_SECONDS <= d <= MAX_VIDEO_SECONDS

# A cooking tutorial for one dish is usually 3-12 minutes. Creator Recipes caps
# at 180s because it is a Shorts feed; that default is left alone and this
# feature opts into a longer ceiling instead.

_MAX_DISH_CHARS = 160


# ── Dish identity ────────────────────────────────────────────────────────────

def normalize_dish(name: str | None) -> str:
    """Canonical form of a dish name, for cache keys and comparison.

    Lowercased, punctuation and portion parentheticals stripped, whitespace
    collapsed. "Masala Oats with Vegetables (1 bowl)" and
    "masala oats with vegetables" must land on the SAME key, or the same meal
    would generate twice and could return two different recipes.
    """
    text = (name or "").strip()
    text = re.sub(r"\([^)]*\)", " ", text)          # portion hints
    text = re.sub(r"[^A-Za-z0-9\s]", " ", text)
    text = re.sub(r"\s+", " ", text).strip().lower()
    return text[:_MAX_DISH_CHARS]


def cache_key(dish: str) -> str:
    """Firestore-safe document id for a dish."""
    norm = normalize_dish(dish)
    digest = hashlib.sha1(norm.encode("utf-8")).hexdigest()[:16]
    slug = re.sub(r"[^a-z0-9]+", "-", norm).strip("-")[:60] or "dish"
    return f"v{RECIPE_SCHEMA_VERSION}_{slug}_{digest}"


def dish_from_meal(meal_name: str | None, foods: list[str] | None) -> str:
    """The dish the athlete actually SEES on the Diet page.

    diet.js renders `meal.foods.join(', ')` under the slot heading, so that
    joined string — not the slot — is the source of truth the athlete clicked.
    `meal_name` is only a fallback for a caller that has no foods list.
    """
    items = [str(f).strip() for f in (foods or []) if str(f).strip()]
    if items:
        return ", ".join(items)[:_MAX_DISH_CHARS]
    return (meal_name or "").strip()[:_MAX_DISH_CHARS]


# ── Cache ────────────────────────────────────────────────────────────────────

def cache_get(dish: str) -> dict[str, Any] | None:
    db = firestore_service.get_client()
    if db is None:
        return None
    try:
        snap = db.collection(CACHE_COLLECTION).document(cache_key(dish)).get()
        if snap and getattr(snap, "exists", False):
            data = snap.to_dict() or {}
            return data.get("recipe") or None
    except Exception as e:  # noqa: BLE001 — a cache miss must never fail the request
        print(f"[RECIPE] cache read failed: {type(e).__name__}: {e}")
    return None


def cache_put(dish: str, recipe: dict[str, Any]) -> None:
    db = firestore_service.get_client()
    if db is None:
        return
    try:
        db.collection(CACHE_COLLECTION).document(cache_key(dish)).set({
            "dish": dish,
            "dishNormalized": normalize_dish(dish),
            "schemaVersion": RECIPE_SCHEMA_VERSION,
            "recipe": recipe,
            "createdAt": datetime.now(timezone.utc).isoformat(),
        })
    except Exception as e:  # noqa: BLE001
        print(f"[RECIPE] cache write failed: {type(e).__name__}: {e}")


# ── Recipe generation ────────────────────────────────────────────────────────

_SYSTEM = (
    "You are ZITLAS's Indian sports-nutrition recipe writer. You write clear, "
    "home-cookable recipes for a specific named dish. You never substitute a "
    "different dish, and you never invent a fusion variant: if the dish is "
    "'Masala Oats with Vegetables', you write THAT recipe. Reply with JSON only."
)

_SCHEMA_HINT = """Return ONLY this JSON object:
{
  "name": "<the exact dish name you were given>",
  "description": "<one sentence, max 25 words>",
  "servings": <integer>,
  "prep_time_min": <integer>,
  "cook_time_min": <integer>,
  "difficulty": "Easy" | "Medium" | "Hard",
  "ingredients": ["<quantity + item>", ...],
  "instructions": ["<step 1>", "<step 2>", ...],
  "nutrition_estimated": {"calories": <int>, "protein_g": <int>,
                          "carbs_g": <int>, "fat_g": <int>},
  "why_it_works": "<one sentence on the fitness benefit>"
}"""


def build_prompt(dish: str, meal_type: str | None, foods: list[str] | None,
                 description: str | None, diet_type: str | None,
                 fitness_goal: str | None) -> list[dict[str, str]]:
    """The dish is stated first, repeated, and fenced — the model must not
    drift to 'a similar breakfast'."""
    lines = [f'Write the recipe for this exact dish: "{dish}".']
    if meal_type:
        lines.append(f"It is served as: {meal_type}.")
    if foods and len(foods) > 1:
        lines.append("The plan lists these components: " + "; ".join(foods) + ".")
    if description:
        lines.append(f"Plan note: {description}")
    if diet_type:
        lines.append(f"Diet preference: {diet_type}. Do not violate it.")
    if fitness_goal:
        lines.append(f"The user's goal is {fitness_goal}.")
    lines.append(
        "Indian home kitchen, everyday ingredients, metric quantities. "
        f'The "name" field must be exactly "{dish}".'
    )
    lines.append(_SCHEMA_HINT)
    return [
        {"role": "system", "content": _SYSTEM},
        {"role": "user", "content": "\n".join(lines)},
    ]


def _strlist(value: Any) -> list[str]:
    """Flatten the shapes a model actually returns into a flat list of lines.

    A two-component dish ("Paneer Bhurji with Roti") frequently comes back
    SECTIONED — {"For the bhurji": [...], "For the roti": [...]} — or as a
    list of {step: ...} objects. Treating either as "no instructions" would
    reject a perfectly good recipe, so both are flattened here instead.
    """
    if value is None:
        return []
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []

    if isinstance(value, dict):
        out: list[str] = []
        for section, items in value.items():
            lines = _strlist(items)
            if not lines:
                continue
            label = str(section).strip()
            if label:
                out.append(f"{label}:")
            out.extend(lines)
        return out

    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, dict):
                text = (item.get("step") or item.get("text")
                        or item.get("instruction") or item.get("item")
                        or item.get("name"))
                if text is None:
                    continue
                qty = item.get("quantity") or item.get("amount")
                line = f"{qty} {text}".strip() if qty else str(text).strip()
                if line:
                    out.append(line)
            elif isinstance(item, (list, dict)):
                out.extend(_strlist(item))
            elif str(item).strip():
                out.append(str(item).strip())
        return out

    return []


# A line that is nothing but a quote (optionally with a comma) is never valid
# JSON. gemini-2.5-flash intermittently closes a string array with `",` instead
# of `],`, e.g.
#     "1 tbsp coriander leaves (for garnish)"
#   ",
#   "instructions": [
# which makes the whole payload unparseable. Repairing exactly this shape is
# far cheaper than a second LLM round-trip, and the pattern is narrow enough
# that it cannot corrupt well-formed JSON.
_STRAY_ARRAY_CLOSE = re.compile(r'^([ 	]*)"(\s*,?)[ 	]*$', re.MULTILINE)


def repair_json(raw: str) -> dict[str, Any] | None:
    """Parse `raw`, repairing the one malformation observed in production."""
    from services import groq_service

    parsed = groq_service._extract_json(raw)
    if parsed is not None:
        return parsed

    repaired = _STRAY_ARRAY_CLOSE.sub(lambda m: f'{m.group(1)}]{m.group(2).strip()}', raw)
    if repaired == raw:
        return None

    parsed = groq_service._extract_json(repaired)
    if parsed is not None:
        print("[RECIPE] repaired a malformed array terminator in the model output")
    return parsed


_NON_VEG = ("chicken", "mutton", "fish", "egg", "prawn", "meat", "keema")


def _diet_types(parsed: dict[str, Any], dish: str) -> list[str]:
    """Never guess vegetarian for a dish whose own name says otherwise —
    mislabelling a chicken dish as vegetarian is a genuine harm, not a
    cosmetic slip."""
    declared = parsed.get("diet_type")
    if isinstance(declared, str):
        declared = [declared]
    if isinstance(declared, list) and declared:
        return [str(d).strip() for d in declared if str(d).strip()]
    lowered = dish.lower()
    return ["Non-Vegetarian"] if any(w in lowered for w in _NON_VEG) else ["Vegetarian"]


def coerce_recipe(parsed: dict[str, Any] | None, dish: str,
                  meal_type: str | None) -> dict[str, Any] | None:
    """Normalise the model's JSON into the shape the recipe page renders.

    Returns None when the payload has no usable ingredients or steps — better
    to report failure than to render an empty recipe card for the dish.
    """
    if not isinstance(parsed, dict):
        return None

    ingredients = _strlist(parsed.get("ingredients"))
    instructions = _strlist(parsed.get("instructions") or parsed.get("steps"))
    if not ingredients or not instructions:
        return None

    def _int(value: Any, default: int | None = None) -> int | None:
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return default

    nutrition = parsed.get("nutrition_estimated")
    nutrition = nutrition if isinstance(nutrition, dict) else {}

    prep = _int(parsed.get("prep_time_min"), 0) or 0
    cook = _int(parsed.get("cook_time_min"), 0) or 0

    return {
        # Same field set the dataset recipes carry, so recipe.js renders this
        # with the EXISTING renderers and no UI branch — renderPreview reads
        # cost_level/diet_type/fitness_goals/home_friendly/hostel_friendly/
        # regional_tag, and a missing key would blank those chips out.
        "id": f"ZITLAS-MEAL-{cache_key(dish)}",
        "category": meal_type or "Meal",
        "cost_level": str(parsed.get("cost_level") or "Medium"),
        "diet_type": _diet_types(parsed, dish),
        "fitness_goals": _strlist(parsed.get("fitness_goals")),
        "home_friendly": True,
        "hostel_friendly": bool(parsed.get("hostel_friendly", False)),
        "regional_tag": str(parsed.get("regional_tag") or ""),
        "tags": _strlist(parsed.get("tags")),
        "equipment": _strlist(parsed.get("equipment")),
        "zitlas_original": False,
        # The name is FORCED back to the dish the athlete clicked: the model
        # occasionally rephrases, and a renamed recipe would look like the
        # random-substitution bug all over again.
        "name": dish,
        "description": str(parsed.get("description") or "").strip(),
        "servings": _int(parsed.get("servings"), 1) or 1,
        "prep_time_min": prep,
        "cook_time_min": cook,
        "total_time_min": prep + cook,
        "difficulty": str(parsed.get("difficulty") or "Easy").strip() or "Easy",
        "meal_type": [meal_type] if meal_type else [],
        "ingredients": ingredients,
        "instructions": instructions,
        "nutrition_estimated": {
            "calories": _int(nutrition.get("calories")),
            "protein_g": _int(nutrition.get("protein_g")),
            "carbs_g": _int(nutrition.get("carbs_g")),
            "fat_g": _int(nutrition.get("fat_g")),
        },
        "why_it_works": str(parsed.get("why_it_works") or "").strip(),
        "source": "zitlas_ai",
    }


async def generate_recipe(dish: str, *, meal_type: str | None = None,
                          foods: list[str] | None = None,
                          description: str | None = None,
                          diet_type: str | None = None,
                          fitness_goal: str | None = None
                          ) -> dict[str, Any] | None:
    """Generate the recipe for THIS dish. Returns None if generation fails."""
    messages = build_prompt(dish, meal_type, foods, description,
                            diet_type, fitness_goal)

    # Two attempts, not one. Observed live: gemini-2.5-flash occasionally
    # truncates mid-array (its thinking tokens share the output budget), and
    # partial JSON parses as nothing. A single retry cleared it; more would
    # only spend the athlete's wait on a bad day.
    for attempt in (1, 2):
        recipe = await _attempt_generate(messages, dish, meal_type, attempt)
        if recipe is not None:
            return recipe
    print(f"[RECIPE] generation gave up for {dish!r} after 2 attempts")
    return None


async def _attempt_generate(messages: list[dict[str, str]], dish: str,
                            meal_type: str | None,
                            attempt: int) -> dict[str, Any] | None:
    from services import groq_service

    try:
        result = await groq_service._ai_call(
            # 4000, not ~1400: gemini-2.5-flash spends part of the output
            # budget on thinking tokens, and a recipe truncated mid-array
            # parses as nothing at all. Measured: 1400 cut the JSON off inside
            # "ingredients"; 3500 still clipped a two-component dish.
            messages, temperature=0.4, max_tokens=4000, json_mode=True,
            groq_key_env="GROQ_API_KEY_DIET",
        )
    except Exception as e:  # noqa: BLE001
        print(f"[RECIPE] attempt {attempt} failed for {dish!r}: "
              f"{type(e).__name__}: {e}")
        return None

    raw = (result or {}).get("reply") or ""
    parsed = repair_json(raw) if raw else None
    recipe = coerce_recipe(parsed, dish, meal_type)
    if recipe is None:
        print(f"[RECIPE] attempt {attempt}: unusable output for {dish!r} "
              f"(raw_len={len(raw)} parsed={'yes' if parsed else 'no'})")
    return recipe


async def get_recipe_for_dish(dish: str, **kwargs: Any) -> tuple[dict[str, Any] | None, bool]:
    """(recipe, from_cache). Cache first, so a repeat click on the same meal
    returns the identical recipe rather than a fresh generation."""
    cached = cache_get(dish)
    if cached:
        print(f"[RECIPE] cache HIT for {dish!r}")
        return cached, True

    print(f"[RECIPE] cache MISS for {dish!r} — generating")
    recipe = await generate_recipe(dish, **kwargs)
    if recipe:
        cache_put(dish, recipe)
    return recipe, False


# ── Meal-specific video, with relevance validation ───────────────────────────

#: Evidence that a video SHOWS THE PREPARATION rather than the finished dish.
#: Hindi/Hinglish included because a large share of Indian recipe content is
#: titled that way and excluding it would quietly narrow the pool to English.
_PREPARATION_SIGNALS = (
    "how to make", "how to prepare", "recipe", "step by step", "step-by-step",
    "homemade", "ingredients", "banane ka", "banane ki", "banaye", "banana ka tarika",
    "kaise banaye", "kaise banate", "banate hain", "cooking", "cook", "make at home",
    "at home", "easy recipe", "quick recipe", "tutorial",
)

#: A finished-food clip, not a recipe. HARD REJECT — these are exactly the
#: videos the athlete complained about: the shake already made, being poured,
#: served or drunk, with a perfect title.
_SERVING_ONLY_SIGNALS = (
    "#shorts", "#short", "whatsapp status", "status video", "satisfying",
    "asmr", "mukbang", "eating", "taste test", "trying", "drinking",
    "pouring", "pour ", "just pour", "food porn", "stock footage",
    "royalty free", "no copyright", "aesthetic", "cinematic b roll", "b-roll",
    "short video", "reels", "#reels", "#ytshorts", "ytshorts",
)


#: Hashtags creators put on a Short. Present => it is a Short, no probe needed.
_SHORTS_MARKERS = (
    "#shorts", "#short", "#ytshorts", "#shortsfeed", "#shortvideo",
    "#youtubeshorts", "#shortsvideo", "#viralshorts", "#shortsviral",
    "/shorts/",
)


def is_youtube_short(video: dict[str, Any], *, probe: bool = True) -> bool:
    """Is this a YouTube Short?

    SHORTS ARE ALWAYS REJECTED, whatever their length — so this cannot be a
    duration test. A 45-second Short and a 45-second normal upload are both
    inside the allowed window and only one is acceptable.

    Two steps, cheapest first:

      1. The hashtags. Definitive when present, free, and how most Shorts
         announce themselves.
      2. `youtube.com/shorts/<id>`. A real Short answers 200; anything else
         redirects to `/watch?v=`. This is the only reliable answer the API
         does not give us — `contentDetails` has no Shorts flag at all — so
         it is worth one HEAD request for a finalist. Never for every
         candidate.

    A failed probe returns True: unable to prove it is NOT a Short means we
    do not show it. Refusing a good video costs the athlete a video; showing
    a Short breaks the rule outright.
    """
    text = f"{video.get('title') or ''} {video.get('description') or ''}".lower()
    if _has(text, _SHORTS_MARKERS):
        return True
    for tag in (video.get("tags") or []):
        if _has(str(tag).lower(), _SHORTS_MARKERS):
            return True
    if not probe:
        return False

    vid = video.get("video_id")
    if not vid:
        return True
    try:
        import urllib.request

        req = urllib.request.Request(
            f"https://www.youtube.com/shorts/{vid}", method="HEAD",
            headers={"User-Agent": "Mozilla/5.0 (compatible; ZITLAS/1.0)"},
        )

        class _NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *_args, **_kwargs):
                return None

        opener = urllib.request.build_opener(_NoRedirect)
        with opener.open(req, timeout=6) as resp:
            # 200 on /shorts/<id> == it really is a Short.
            return resp.status == 200
    except urllib.error.HTTPError as e:  # noqa: F821
        # 303/302 -> redirected to /watch -> a normal video.
        return e.code not in (301, 302, 303, 307, 308)
    except Exception as e:  # noqa: BLE001
        print(f"[RECIPE] shorts probe failed for {vid}: {type(e).__name__} — "
              "treating as a Short (fail closed)")
        return True


def _has(text: str, signals: tuple[str, ...]) -> bool:
    return any(sig in text for sig in signals)


def video_relevance(video: dict[str, Any], dish: str) -> float:
    """Backwards-compatible score. See `score_video` for the real answer."""
    return score_video(video, dish)["score"]


def score_video(video: dict[str, Any], dish: str) -> dict[str, Any]:
    """Is this video about THIS dish, and does it show it being MADE?

    Two questions, both of which have to be yes. The old scorer only asked the
    first, which is how a 12-second pour of an already-made shake — titled with
    every word of the dish — ended up on the recipe page.

    Returns {score, verified, match_type, reason}. `verified` is only ever true
    for a video that names the dish AND shows preparation; a generic or
    serving-only clip is never marked verified, whatever it scores.
    """
    from services import youtube_recipe_service as yt

    title = (video.get("title") or "").lower()
    desc = (video.get("description") or "").lower()
    both = f"{title} {desc}"
    # Never raises: a malformed duration from the API must be a rejection,
    # not a 500. `is_duration_allowed` treats 0 as unknown and refuses it.
    try:
        duration = int(video.get("duration_seconds") or 0)
    except (TypeError, ValueError):
        duration = 0

    words = [w for w in yt._clean_food_term(dish).lower().split() if len(w) > 2]
    if not words:
        return {"score": 0.0, "verified": False, "match_type": "none",
                "reason": "no usable dish words"}

    # ── Hard rejections ──────────────────────────────────────────────────
    # THE DURATION GATE. `if duration and ...` used to sit here, which meant a
    # video reporting 0 or no duration slipped past BOTH bounds — the one
    # shape that should never be trusted. One predicate now, and unknown is a
    # rejection.
    if not is_duration_allowed(duration):
        if not duration:
            return {"score": 0.0, "verified": False, "match_type": "unknown_duration",
                    "reason": "duration unknown — rejected (fail closed)"}
        kind = "too_short" if duration < MIN_VIDEO_SECONDS else "too_long"
        return {"score": 0.0, "verified": False, "match_type": kind,
                "reason": f"{duration}s — outside "
                          f"{MIN_VIDEO_SECONDS}-{MAX_VIDEO_SECONDS}s"}

    # SHORTS ARE ALWAYS REJECTED, whatever their length. Checked by hashtag
    # here (free); `find_meal_video` probes youtube.com/shorts/<id> for the
    # finalists, which is the only reliable answer available.
    if is_youtube_short(video, probe=False):
        return {"score": 0.0, "verified": False, "match_type": "shorts",
                "reason": "declares itself a YouTube Short"}

    if _has(both, _SERVING_ONLY_SIGNALS):
        return {"score": 0.0, "verified": False, "match_type": "serving_only",
                "reason": "reads as a finished-food / short-form clip"}

    if _has(title, yt._JUNK_SIGNALS):
        return {"score": 0.0, "verified": False, "match_type": "junk",
                "reason": "vlog / reaction / review, not a recipe"}

    # ── Is it this dish? ─────────────────────────────────────────────────
    in_title = sum(1 for w in words if w in title)
    in_desc = sum(1 for w in words if w in desc)
    title_cover = in_title / len(words)

    # A DISTINCTIVE word must appear. "banana shake" matching a
    # "peanut butter banana shake" query is a different drink; requiring the
    # rarest word keeps categories from standing in for dishes.
    distinctive = [w for w in words if w not in _COMMON_FOOD_WORDS]
    if distinctive and not any(w in title for w in distinctive):
        return {"score": 0.0, "verified": False, "match_type": "wrong_dish",
                "reason": f"title names none of {distinctive}"}

    # Most of the dish has to be in the TITLE. Creators name recipe videos
    # after the recipe; a partial match is usually a different dish.
    if title_cover < 0.6:
        return {"score": 0.0, "verified": False, "match_type": "generic",
                "reason": f"title covers only {in_title}/{len(words)} dish words"}

    score = 0.75 * title_cover + 0.25 * (in_desc / len(words))

    # ── Does it show it being MADE? ──────────────────────────────────────
    prep_in_title = _has(title, _PREPARATION_SIGNALS)
    prep_in_desc = _has(desc, _PREPARATION_SIGNALS)
    if prep_in_title:
        score = min(1.0, score + 0.15)
    elif prep_in_desc:
        score = min(1.0, score + 0.05)
    else:
        # Names the dish, shows no sign of making it. Not disqualifying on its
        # own — plenty of good tutorials are titled bare — but it must not
        # outrank a video that says so, and it is never "verified".
        score *= 0.7

    # PREPARATION CLARITY, not length. Duration deliberately contributes
    # NOTHING beyond the window gate: a 25-second video is not better than an
    # 85-second one, and the athlete wants whichever actually shows the steps.
    # Counting distinct preparation cues is the closest proxy available from
    # metadata for "this one really walks through it".
    prep_cues = sum(1 for sig in _PREPARATION_SIGNALS if sig in both)
    score = min(1.0, score + 0.03 * min(prep_cues, 3))

    verified = bool((prep_in_title or prep_in_desc) and title_cover >= 0.75)
    return {
        "score": round(min(1.0, max(0.0, score)), 3),
        "verified": verified,
        "match_type": "recipe_specific" if verified else "loose",
        "prep_cues": prep_cues,
        "reason": f"title {in_title}/{len(words)}, prep={prep_in_title or prep_in_desc}"
                  f" cues={prep_cues}, {duration}s",
    }


#: Words that describe a CATEGORY rather than a dish. Used only to find the
#: distinctive part of a dish name — never to filter a video on their own.
_COMMON_FOOD_WORDS = {
    "shake", "smoothie", "juice", "drink", "salad", "soup", "curry", "rice",
    "roti", "bread", "bowl", "recipe", "healthy", "protein", "homemade",
    "breakfast", "lunch", "dinner", "snack", "meal", "and", "with", "the",
}


#: Words creators use for the same preparation. A dish is not found under one
#: spelling only — "shake" and "smoothie" are the same drink to a cook, and
#: refusing to look for both is how a real tutorial gets missed.
#:
#: These generate RECIPE-SPECIFIC variants: the full dish name is always
#: present, only the last noun is swapped. They never produce a bare category
#: search like "banana" or "smoothie".
_DISH_ALIASES: dict[str, tuple[str, ...]] = {
    "shake": ("smoothie", "milkshake"),
    "smoothie": ("shake", "milkshake"),
    "milkshake": ("shake", "smoothie"),
    "curry": ("masala", "gravy", "sabzi"),
    "masala": ("curry", "gravy"),
    "gravy": ("curry", "masala"),
    "sabzi": ("curry", "sabji"),
    "fry": ("bhaji", "sabzi"),
    "salad": ("chaat",),
    "rice": ("pulao",),
    "roti": ("chapati",),
    "dal": ("daal", "lentil curry"),
    "bhurji": ("scramble", "anda bhurji"),
}

#: Phrasings that ask for a METHOD. Never a bare dish name — that is what
#: surfaces finished-food clips.
_QUERY_SHAPES = (
    "how to make {d} recipe",
    "{d} recipe step by step",
    "{d} easy recipe at home",
    "{d} recipe preparation",
)


def build_recipe_queries(dish: str) -> list[str]:
    """Recipe-specific searches for one dish, most direct first.

    Every query contains the FULL dish name (or an alias of its last word),
    so none of them can degenerate into a category search. Ordered so the
    cheapest, most likely variants run first — `find_meal_video` stops as
    soon as a verified candidate is found, so the later ones usually cost
    nothing.
    """
    from services import youtube_recipe_service as yt

    clean = yt._clean_food_term(dish)
    if not clean:
        return []

    names = [clean]
    words = clean.split()
    if words:
        last = words[-1].lower()
        for alias in _DISH_ALIASES.get(last, ()):
            names.append(" ".join(words[:-1] + [alias]))

    queries: list[str] = []
    for shape in _QUERY_SHAPES:
        for name in names:
            q = shape.format(d=name)
            if q not in queries:
                queries.append(q)
    return queries


def _search_candidates(query: str, *, duration_filter: str | None) -> list[str]:
    """`search.list` for the recipe page, with our own parameters.

    Separate from `youtube_recipe_service._search` so Creator Recipes' feed
    is untouched. Two differences, both about DEPTH, neither about validation:

      * `maxResults=50` instead of 25. The API charges 100 units for the
        call whatever the page size, so this doubles the candidate pool for
        free — the single cheapest improvement available.
      * `duration_filter=None` on some passes. YouTube's `videoDuration=short`
        bucket is "under 4 minutes", which in practice is dominated by
        Shorts; dropping it surfaces ordinary uploads that happen to be
        20-90s. Real duration is still read from `contentDetails` and still
        validated — this only changes what we get to look at.
    """
    from services import youtube_recipe_service as yt

    params = {
        "part": "id",
        "q": query,
        "type": "video",
        "videoEmbeddable": "true",
        "maxResults": 50,
        "safeSearch": "moderate",
        "relevanceLanguage": "en",
        "regionCode": "IN",
    }
    if duration_filter:
        params["videoDuration"] = duration_filter
    data = yt._get(yt._SEARCH_URL, params)
    return [
        item["id"]["videoId"]
        for item in data.get("items", [])
        if isinstance(item.get("id"), dict) and item["id"].get("videoId")
    ]


def find_meal_video(dish: str, *, meal_type: str | None = None,
                    diet_type: str | None = None,
                    fitness_goal: str | None = None) -> dict[str, Any] | None:
    """The best video that is genuinely about `dish`, or None.

    None is a first-class outcome. The requirement is explicit: show the recipe
    and say no exact video was found rather than substitute something loosely
    related.
    """
    from services import youtube_recipe_service as yt

    if not yt.is_configured():
        print("[RECIPE] youtube query: skipped — YOUTUBE_API_KEY not configured")
        return None

    # QUERIES THAT ASK FOR A METHOD, not a category.
    #
    # `build_queries` is Creator Recipes' builder and produces "<goal> <diet>
    # <food> recipe" — good for browsing a feed, but it never asks YouTube for
    # somebody MAKING the dish, so a pour clip is a legitimate result for it.
    # `build_recipe_queries` asks for the method directly and swaps only the
    # last noun for its aliases, so every variant still names the full dish.
    queries = build_recipe_queries(dish)
    if not queries:
        return None

    # Each search pass is (query, duration_filter). The `short` bucket is
    # tried first because it is the densest for this content; the unfiltered
    # pass follows because that bucket is Shorts-dominated and ordinary
    # 20-90s uploads sit outside it. Validation is identical either way.
    passes: list[tuple[str, str | None]] = []
    for q in queries[:_MAX_QUERIES]:
        passes.append((q, "short"))
    for q in queries[:_MAX_UNFILTERED_QUERIES]:
        passes.append((q, None))

    # COLLECT EVERY VALID CANDIDATE FIRST, THEN RANK. The previous version
    # stopped as soon as a good-enough candidate appeared, so WHICH queries
    # ran depended on what YouTube happened to return first — and ties were
    # broken by arrival order. The same dish could therefore return a video on
    # one request and nothing on the next. Nothing about the search is allowed
    # to depend on ordering any more.
    valid: list[tuple[dict[str, Any], dict[str, Any]]] = []
    rejected: list[str] = []
    seen_ids: set[str] = set()
    searches = 0
    #: Why each candidate was refused, for the log line at the end.
    tally: dict[str, int] = {}

    for query, duration_filter in passes:
        searches += 1
        print(f"[RECIPE] youtube query: {query!r} "
              f"(duration_filter={duration_filter or 'none'})")
        try:
            ids = [v for v in _search_candidates(query, duration_filter=duration_filter)
                   if v not in seen_ids]
            seen_ids.update(ids)
            videos = []
            # `videos.list` takes 50 ids per call and costs 1 unit.
            for chunk in range(0, len(ids), 50):
                videos += yt._hydrate(ids[chunk:chunk + 50],
                                      max_seconds=MAX_VIDEO_SECONDS)
        except yt.YouTubeUnavailable:
            print("[RECIPE] youtube unavailable")
            return None
        except Exception as e:  # noqa: BLE001
            print(f"[RECIPE] youtube search failed: {type(e).__name__}: {e}")
            break

        for video in videos:
            # ── VALIDATION — unchanged, applied to every candidate ──
            secs = video.get("duration_seconds")
            if not is_duration_allowed(secs):
                kind = "too_short" if (secs or 0) < MIN_VIDEO_SECONDS else "too_long"
                tally[kind] = tally.get(kind, 0) + 1
                rejected.append(f"{video.get('title')!r} ({secs}s, {kind})")
                continue
            verdict = score_video(video, dish)
            if verdict["score"] <= 0 or not verdict["verified"] \
                    or verdict["score"] < MIN_VIDEO_RELEVANCE:
                key = verdict["match_type"] if verdict["score"] <= 0 else "unverified"
                tally[key] = tally.get(key, 0) + 1
                rejected.append(f"{video.get('title')!r} ({key})")
                continue
            valid.append((video, verdict))

    print(f"[RECIPE] searched {searches} quer{'y' if searches == 1 else 'ies'}, "
          f"{len(seen_ids)} unique candidates, {len(valid)} valid, rejected "
          f"{sum(tally.values())} — {tally or 'none'}")

    # ── DETERMINISTIC RANKING ────────────────────────────────────────────
    # Sorted, not "first one that looked good". The key is total and its last
    # element is the video id, so two candidates that are equal on every
    # quality signal still resolve to the same winner on every run — which is
    # what makes the same dish return the same video each time.
    #
    # Duration is deliberately absent: it is a hard gate, never a preference,
    # so a 25s clip cannot outrank an 85s walkthrough.
    valid.sort(key=lambda pair: (
        -int(pair[1]["verified"]),                       # 1. recipe-specific + prep
        -pair[1]["prep_cues"],                           # 2. preparation evidence
        -pair[1]["score"],                  # 3. relevance
        str(pair[0].get("video_id") or ""),  # 4. stable, total tie-break
    ))

    best = best_verdict = None
    for video, verdict in valid:
        # Shorts are NEVER shown. The probe is a network call, so it runs in
        # rank order and stops at the first candidate that passes — the
        # ordering above is already fixed, so this stays deterministic.
        if is_youtube_short(video, probe=True):
            tally["shorts"] = tally.get("shorts", 0) + 1
            rejected.append(f"{video.get('title')!r} (shorts, probed)")
            continue
        best, best_verdict = video, verdict
        break

    if best_verdict is None:
        best_verdict = {"score": 0.0, "verified": False, "match_type": "none",
                        "prep_cues": 0, "reason": "no valid candidate survived"}

    for line in rejected[:8]:
        print(f"[RECIPE] video rejected: {line}")

    if best is None:
        print("[RECIPE] video selected: none — nothing showed this dish "
              "being prepared")
        return None

    print(f"[RECIPE] video selected: {best.get('title')!r} "
          f"({best.get('duration_seconds')}s)")
    print(f"[RECIPE] video relevance: {best_verdict['score']} "
          f"verified={best_verdict['verified']} "
          f"match={best_verdict['match_type']} "
          f"({best_verdict['reason']}; threshold {MIN_VIDEO_RELEVANCE})")

    if best_verdict["score"] < MIN_VIDEO_RELEVANCE:
        print("[RECIPE] video REJECTED — below relevance threshold; showing "
              "the recipe with no video rather than a misleading one")
        return None

    # The winner was PROBED in the ranking loop above, so it is already proved
    # not to be a Short. This re-asserts the hashtag half only (probe=False):
    # repeating the network call would add nothing and would make the result
    # depend on whether one more HTTP request happened to succeed — the exact
    # non-determinism this pass exists to remove.
    if is_youtube_short(best, probe=False):
        print("[RECIPE] video REJECTED — declares itself a Short; Shorts are "
              "never shown regardless of duration")
        return None

    if not best_verdict["verified"]:
        # It names the dish and is long enough, but nothing says it shows the
        # dish being MADE. A misleading video is worse than none: the athlete
        # gets the recipe and an honest "coming soon".
        print("[RECIPE] video REJECTED — not a verified preparation video")
        return None

    # THE LAST GATE. Everything above already filtered on the window, so this
    # can only fire if a future edit adds a path that skips them. It is here
    # because "no video" is always an acceptable answer and an out-of-window
    # video never is — the check costs nothing and closes the whole function.
    if not is_duration_allowed(best.get("duration_seconds")):
        print(f"[RECIPE] video REJECTED at the final gate — "
              f"{best.get('duration_seconds')}s is outside "
              f"{MIN_VIDEO_SECONDS}-{MAX_VIDEO_SECONDS}s")
        return None

    # Field names mirror _hydrate()'s output exactly — see that function.
    return {
        "video_id": best.get("video_id"),
        "video_url": best.get("video_url"),
        "title": best.get("title"),
        "channel_name": best.get("channel_name"),
        "thumbnail_url": best.get("thumbnail_url"),
        "duration_seconds": best.get("duration_seconds"),
        "relevance": best_verdict["score"],
        # The recipe -> video relationship, stated rather than implied. Only a
        # video that names the dish AND shows preparation is ever verified.
        "verified": True,
        "match_type": best_verdict["match_type"],
        "source": "youtube",
    }
