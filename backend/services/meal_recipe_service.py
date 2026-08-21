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
MIN_VIDEO_RELEVANCE = 0.55

# A cooking tutorial for one dish is usually 3-12 minutes. Creator Recipes caps
# at 180s because it is a Shorts feed; that default is left alone and this
# feature opts into a longer ceiling instead.
MAX_VIDEO_SECONDS = 900

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

def video_relevance(video: dict[str, Any], dish: str) -> float:
    """0..1 — how much this video is about THIS dish.

    Deliberately title-driven and independent of youtube_recipe_service._rank:
    that function ranks candidates against each other for the Creator Recipes
    feed (rewarding short-form, penalising junk). Here the question is a
    different one — "is this the right dish at all?" — and it must be
    answerable as an absolute threshold, not a relative ordering.
    """
    from services import youtube_recipe_service as yt

    title = (video.get("title") or "").lower()
    desc = (video.get("description") or "").lower()

    words = [w for w in yt._clean_food_term(dish).lower().split() if len(w) > 2]
    if not words:
        return 0.0

    in_title = sum(1 for w in words if w in title)
    in_desc = sum(1 for w in words if w in desc)

    # Title matches are what a human judges relevance by.
    score = 0.75 * (in_title / len(words)) + 0.25 * (in_desc / len(words))

    # A recipe/tutorial signal confirms it is a cooking video, not a vlog.
    if any(sig in title for sig in yt._RECIPE_SIGNALS):
        score = min(1.0, score + 0.10)

    # Nothing about the dish in the title is disqualifying on its own.
    if in_title == 0:
        score *= 0.4

    return round(min(1.0, max(0.0, score)), 3)


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

    queries = yt.build_queries(
        food=dish, meal_type=meal_type, diet_type=diet_type,
        fitness_goal=fitness_goal,
    )
    if not queries:
        return None

    print(f"[RECIPE] youtube query: {queries[0]!r}")

    best: dict[str, Any] | None = None
    best_score = 0.0
    for query in queries[:2]:          # 2 searches max — search.list is 100 units
        try:
            ids = yt._search(query)
            # A full tutorial for ONE dish is the goal here, so opt out of the
            # 180s Shorts ceiling Creator Recipes uses. Its default is
            # untouched, so that feature keeps returning short-form only.
            videos = yt._hydrate(ids, max_seconds=MAX_VIDEO_SECONDS) if ids else []
        except yt.YouTubeUnavailable as e:
            print(f"[RECIPE] youtube unavailable: {type(e).__name__}")
            return None
        except Exception as e:  # noqa: BLE001
            print(f"[RECIPE] youtube search failed: {type(e).__name__}: {e}")
            return None

        for video in videos:
            score = video_relevance(video, dish)
            if score > best_score:
                best, best_score = video, score

        if best_score >= 0.8:          # good enough; don't spend more quota
            break

    if best is None:
        print("[RECIPE] video selected: none — no candidates returned")
        return None

    print(f"[RECIPE] video selected: {best.get('title')!r}")
    print(f"[RECIPE] video relevance: {best_score} "
          f"(threshold {MIN_VIDEO_RELEVANCE})")

    if best_score < MIN_VIDEO_RELEVANCE:
        print("[RECIPE] video REJECTED — below relevance threshold; "
              "showing the recipe with no video rather than an unrelated one")
        return None

    # Field names mirror _hydrate()'s output exactly — see that function.
    return {
        "video_id": best.get("video_id"),
        "video_url": best.get("video_url"),
        "title": best.get("title"),
        "channel_name": best.get("channel_name"),
        "thumbnail_url": best.get("thumbnail_url"),
        "duration_seconds": best.get("duration_seconds"),
        "relevance": best_score,
    }
