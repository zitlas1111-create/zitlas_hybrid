"""
ZITLAS — Creator Recipe discovery via the YouTube Data API v3
(backend/services/youtube_recipe_service.py)

Finds real YouTube creator videos for a food the athlete is about to eat.
This is a SEPARATE content source from ZITLAS's own 637-recipe database
(services/recipe_service.py) and the two must never be conflated: a
creator's video is their work, surfaced with attribution, never "a ZITLAS
recipe".

SECRET HANDLING: the API key is read from the environment ONLY
(`YOUTUBE_API_KEY`, loaded by main.py's existing `load_dotenv`). It is never
logged, never included in an exception message, and never present in any
response body — see `_search()`'s deliberate exception handling.

QUOTA: YouTube Data API v3 bills `search.list` at 100 units against a
default 10,000/day allowance — roughly 100 searches per day for the entire
deployment. That is the binding constraint on this feature, so:
  * results are cached per (food, context) for `_CACHE_TTL`,
  * "See Another Recipe" is served from the SAME cached result page rather
    than re-searching (the exclusion happens client-side of the cache),
  * one search call per query, with a second variant attempted only when the
    first returns nothing usable,
  * `videos.list` (1 unit) supplies embeddability; `channels.list` (1 unit)
    is called only when a creator profile is actually opened.

NOT DONE HERE, deliberately: no scraping, no HTML parsing, no video
download, no re-hosting, no proxying of media bytes. Playback happens in the
client through YouTube's own IFrame embed.
"""

from __future__ import annotations

import os
import re
import time
from typing import Any

import requests

_SEARCH_URL = "https://www.googleapis.com/youtube/v3/search"
_VIDEOS_URL = "https://www.googleapis.com/youtube/v3/videos"
_CHANNELS_URL = "https://www.googleapis.com/youtube/v3/channels"

_TIMEOUT = 12

# Long enough to make "See Another Recipe" free, short enough that the feed
# doesn't feel frozen for a returning athlete.
_CACHE_TTL = 60 * 60 * 6  # 6 hours
_CACHE_MAX = 400

# Enough candidates to rank meaningfully and to serve several "See Another"
# taps from one search, without inflating the response.
_SEARCH_RESULTS = 15

_cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}


class YouTubeUnavailable(Exception):
    """Raised for any upstream failure. The message is deliberately generic —
    it reaches the client, so it must never carry a key, a URL with a key in
    it, or an upstream error body."""


class YouTubeQuotaExceeded(YouTubeUnavailable):
    """Quota/rate limit. Callers must NOT auto-retry this."""


def is_configured() -> bool:
    return bool(os.getenv("YOUTUBE_API_KEY"))


# ── Query construction ───────────────────────────────────────────────────
# The goal is a small number of high-quality queries, not every profile field
# concatenated. Each modifier below only earns its place in the query when it
# genuinely changes what a good result looks like.

_GOAL_MODIFIER = {
    "muscle_gain": "high protein",
    "transformation": "high protein",
    "body_transformation": "high protein",
    "weight_loss": "healthy low calorie",
    "general_fitness": "healthy",
}

_DIET_MODIFIER = {
    "vegetarian": "vegetarian",
    "veg": "vegetarian",
    "vegan": "vegan",
    "eggetarian": "vegetarian",
    "egg": "vegetarian",
    # Non-vegetarian needs no modifier: it excludes nothing, and adding the
    # word narrows results to dishes ABOUT meat rather than dishes that may
    # contain it.
    "non-vegetarian": "",
    "non_veg": "",
    "nonveg": "",
}

# Only for a genuinely equipment-constrained situation. "Hostel" in a query
# returns videos about hostels, not recipes — the useful signal is the
# CONSTRAINT ("without oven", "no cook"), not the living situation's name.
_CONSTRAINT_MODIFIER = {
    "hostel": "without oven easy",
    "pg": "without oven easy",
    "college": "without oven easy",
    "travel": "no cook easy",
}

_MEAL_MODIFIER = {
    "breakfast": "breakfast",
    "lunch": "",
    "dinner": "",
    "snack": "snack",
}


def build_queries(
    *,
    food: str,
    fitness_goal: str | None = None,
    diet_type: str | None = None,
    meal_type: str | None = None,
    living_situation: str | None = None,
    region: str | None = None,
) -> list[str]:
    """2-3 ranked query variants, most specific first.

    Each is a real sentence a person might search, not a bag of every field:
    an over-specified query ("high protein vegetarian Maharashtra hostel
    lunch pizza recipe without oven") matches nothing on YouTube.
    """
    food = _clean_food_term(food)
    if not food:
        return []

    goal = _GOAL_MODIFIER.get(_norm(fitness_goal), "")
    diet = _DIET_MODIFIER.get(_norm(diet_type), "")
    constraint = _CONSTRAINT_MODIFIER.get(_norm(living_situation), "")
    meal = _MEAL_MODIFIER.get(_norm(meal_type), "")

    variants: list[str] = []

    def _add(*parts: str) -> None:
        q = " ".join(p for p in parts if p).strip()
        q = re.sub(r"\s+", " ", q)
        if q and q not in variants:
            variants.append(q)

    # 1. Goal + diet + food — the athlete's actual intent.
    _add(goal, diet, food, "recipe")
    # 2. Drop the goal modifier: a plain "vegetarian pizza recipe" often has
    #    far better creator content than a niche fitness phrasing.
    _add(diet, food, "recipe")
    # 3. Regional/meal flavour LAST, and only if it adds something — region
    #    must never outrank food relevance.
    if region:
        _add(goal, food, "recipe", str(region))
    elif meal:
        _add(goal, diet, meal, food, "recipe")
    # 4. Absolute fallback so a result always exists to rank.
    _add(food, "recipe")

    if constraint:
        # Inserted as a SECOND-choice variant rather than folded into the
        # primary query, which would over-narrow it.
        variants.insert(1, re.sub(r"\s+", " ", f"{food} recipe {constraint}").strip())

    return variants[:3]


def _clean_food_term(food: str) -> str:
    """A plan's food line is written for a human ("Poha (Home Style)
    (1 plate (200 g))"), not for a search box. Strip the parenthetical
    style/quantity noise that would otherwise wreck relevance."""
    s = re.sub(r"\([^)]*\)", " ", food or "")
    s = re.sub(r"[^A-Za-z\s]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    # Keep it short: long multi-dish lines search worse than their head term.
    words = s.split()
    return " ".join(words[:4])


def _norm(s: str | None) -> str:
    return (s or "").strip().lower().replace(" ", "_").replace("-", "_")


# ── Ranking ──────────────────────────────────────────────────────────────

_RECIPE_SIGNALS = ("recipe", "how to make", "banane", "banaye", "kaise", "cook", "homemade")
_JUNK_SIGNALS = (
    "vlog", "mukbang", "what i eat", "day in my life", "reaction", "unboxing",
    "review", "prank", "song", "trailer", "podcast", "interview", "asmr",
)
_NON_VEG_TOKENS = ("chicken", "mutton", "fish", "prawn", "egg", "beef", "pork", "keema")


# Stable Assessment ids -> the words a creator would actually put in a title.
# "north_indian" is never written as "north_indian" by a human.
_FAVOURITE_FOOD_TERMS = {
    "pizza": ("pizza",), "burger": ("burger",), "sandwich": ("sandwich",),
    "wrap": ("wrap", "roll"), "pasta": ("pasta",), "noodles": ("noodles", "noodle"),
    "tacos": ("taco",), "cake": ("cake",), "pancakes": ("pancake",),
    "chocolate_desserts": ("chocolate",), "ice_cream": ("ice cream",),
    "maharashtrian": ("maharashtrian", "marathi"),
    "north_indian": ("north indian", "punjabi"),
    "south_indian": ("south indian", "dosa", "idli"),
    "bengali": ("bengali",), "street_food": ("street food", "chaat"),
}


def _rank(video: dict[str, Any], *, food: str, diet_type: str | None,
          fitness_goal: str | None, favorite_foods: list[str] | None = None) -> float:
    title = (video.get("title") or "").lower()
    desc = (video.get("description") or "").lower()
    score = 0.0

    # 1. Food relevance dominates — a video that isn't about the food is
    #    wrong no matter how good it is.
    food_words = [w for w in _clean_food_term(food).lower().split() if len(w) > 2]
    if food_words:
        in_title = sum(1 for w in food_words if w in title)
        score += 6.0 * (in_title / len(food_words))
        if in_title == 0:
            score -= 4.0
            if not any(w in desc for w in food_words):
                # Not about this food at all.
                score -= 6.0

    # 2. Is it actually a recipe/tutorial?
    if any(sig in title for sig in _RECIPE_SIGNALS):
        score += 3.0
    elif any(sig in desc for sig in _RECIPE_SIGNALS):
        score += 1.0

    # 3. Obvious non-recipe formats.
    if any(sig in title for sig in _JUNK_SIGNALS):
        score -= 5.0

    # 3b. Shorts. Found by a REAL API call during verification: a plain
    #     search returns mostly Shorts, and a 30-second vertical clip is a
    #     poor "watch a creator make it" experience next to a full
    #     demonstration. A PENALTY rather than an exclusion — a Short that
    #     genuinely demonstrates the recipe is still a valid answer, it just
    #     shouldn't outrank a full video.
    if any(tag in title for tag in ("#shorts", "#short", "#recipeshorts", "#ytshorts")):
        score -= 2.5

    # 4. Fitness relevance, only where the goal asks for it.
    goal = _norm(fitness_goal)
    if goal in ("muscle_gain", "transformation", "body_transformation"):
        if "protein" in title:
            score += 2.0
    elif goal == "weight_loss":
        if any(t in title for t in ("healthy", "low calorie", "weight loss", "diet")):
            score += 2.0

    # 5. Diet compatibility — a hard-ish penalty, never a hard filter: a
    #    vegetarian athlete may still legitimately be shown a video whose
    #    title merely mentions a non-veg variant.
    diet = _norm(diet_type)
    if diet in ("vegetarian", "veg", "vegan", "eggetarian", "egg"):
        if any(t in title for t in _NON_VEG_TOKENS):
            score -= 4.0
        if "veg" in title or "vegetarian" in title or "vegan" in title:
            score += 1.5

    # 6. The athlete's saved food preferences — a TIE-BREAKER, deliberately
    #    small (+1.0 against food relevance's 6.0). Between two equally good
    #    videos for tonight's dish, prefer the one that also matches their
    #    taste; never let it outrank being about the right food.
    for fav in (favorite_foods or []):
        terms = _FAVOURITE_FOOD_TERMS.get(_norm(fav))
        if terms and any(t in title for t in terms):
            score += 1.0
            break

    if video.get("embeddable"):
        score += 1.0
    return score


# ── YouTube calls ────────────────────────────────────────────────────────

def _api_key() -> str:
    key = os.getenv("YOUTUBE_API_KEY")
    if not key:
        raise YouTubeUnavailable("creator_recipes_not_configured")
    return key


def _get(url: str, params: dict[str, Any]) -> dict[str, Any]:
    """One upstream call.

    Exceptions raised here NEVER echo the request URL or params — both carry
    the API key, and this message travels to the client.
    """
    try:
        resp = requests.get(url, params={**params, "key": _api_key()}, timeout=_TIMEOUT)
    except requests.RequestException as e:
        # Type name only. `str(e)` on a requests error embeds the full URL,
        # query string included — i.e. the key.
        print(f"[YOUTUBE] transport failure: {type(e).__name__}")
        raise YouTubeUnavailable("creator_recipes_unavailable") from None

    if resp.status_code == 403:
        body = resp.text[:400]
        if "quota" in body.lower() or "rateLimit" in body:
            print("[YOUTUBE] quota/rate limit reached")
            raise YouTubeQuotaExceeded("creator_recipes_quota") from None
        print("[YOUTUBE] request forbidden (key/referrer/API-enablement)")
        raise YouTubeUnavailable("creator_recipes_unavailable") from None
    if resp.status_code >= 400:
        print(f"[YOUTUBE] upstream status {resp.status_code}")
        raise YouTubeUnavailable("creator_recipes_unavailable") from None

    try:
        return resp.json()
    except ValueError:
        raise YouTubeUnavailable("creator_recipes_unavailable") from None


def _search(query: str) -> list[str]:
    """`search.list` — 100 quota units. Returns video IDs only."""
    data = _get(_SEARCH_URL, {
        "part": "id",
        "q": query,
        "type": "video",
        # API-level embeddability filter: cheaper and more reliable than
        # discovering un-embeddable videos after the fact.
        "videoEmbeddable": "true",
        "maxResults": _SEARCH_RESULTS,
        "safeSearch": "moderate",
        "relevanceLanguage": "en",
        "regionCode": "IN",
    })
    return [
        item["id"]["videoId"]
        for item in data.get("items", [])
        if isinstance(item.get("id"), dict) and item["id"].get("videoId")
    ]


def _hydrate(video_ids: list[str]) -> list[dict[str, Any]]:
    """`videos.list` — 1 quota unit for the whole batch. Confirms
    embeddability and supplies the snippet used for attribution."""
    if not video_ids:
        return []
    data = _get(_VIDEOS_URL, {
        "part": "snippet,status",
        "id": ",".join(video_ids[:50]),
    })
    out = []
    for item in data.get("items", []):
        snippet = item.get("snippet") or {}
        status = item.get("status") or {}
        thumbs = snippet.get("thumbnails") or {}
        thumb = (thumbs.get("high") or thumbs.get("medium") or thumbs.get("default") or {})
        vid = item.get("id")
        if not vid:
            continue
        out.append({
            "video_id": vid,
            "title": snippet.get("title") or "",
            "description": (snippet.get("description") or "")[:400],
            "thumbnail_url": thumb.get("url"),
            "channel_id": snippet.get("channelId"),
            "channel_name": snippet.get("channelTitle"),
            "published_at": snippet.get("publishedAt"),
            "video_url": f"https://www.youtube.com/watch?v={vid}",
            "platform": "youtube",
            "embeddable": bool(status.get("embeddable", True)),
        })
    return out


def _cache_key(**parts: Any) -> str:
    return "|".join(f"{k}={_norm(str(v))}" for k, v in sorted(parts.items()) if v)


def _cache_get(key: str) -> list[dict[str, Any]] | None:
    hit = _cache.get(key)
    if not hit:
        return None
    stored_at, value = hit
    if time.time() - stored_at > _CACHE_TTL:
        _cache.pop(key, None)
        return None
    return value


def _cache_put(key: str, value: list[dict[str, Any]]) -> None:
    if len(_cache) >= _CACHE_MAX:
        # Cheap eviction — drop the oldest quarter rather than tracking LRU
        # for what is a small, short-lived cache.
        for k in sorted(_cache, key=lambda k: _cache[k][0])[: _CACHE_MAX // 4]:
            _cache.pop(k, None)
    _cache[key] = (time.time(), value)


def find_creator_recipes(
    *,
    food: str,
    fitness_goal: str | None = None,
    diet_type: str | None = None,
    meal_type: str | None = None,
    living_situation: str | None = None,
    region: str | None = None,
    favorite_foods: list[str] | None = None,
    limit: int = 10,
) -> list[dict[str, Any]]:
    """Ranked creator videos for this food + context.

    Returns a LIST so "See Another Recipe" can walk it without another
    search — the single most important quota decision in this module.
    """
    queries = build_queries(
        food=food, fitness_goal=fitness_goal, diet_type=diet_type,
        meal_type=meal_type, living_situation=living_situation, region=region,
    )
    if not queries:
        return []

    # Preferences are part of the key: two athletes with different tastes
    # must not share a cached ranking, and an athlete who EDITS their
    # preferences immediately gets a re-ranked result rather than a stale one.
    key = _cache_key(food=_clean_food_term(food), goal=fitness_goal, diet=diet_type,
                     meal=meal_type, living=living_situation, region=region,
                     favs=",".join(sorted(favorite_foods or [])))
    cached = _cache_get(key)
    if cached is not None:
        print(f"[YOUTUBE] cache hit — {key}")
        return cached[:limit]

    ranked: list[dict[str, Any]] = []
    for query in queries:
        ids = _search(query)
        videos = _hydrate(ids)
        scored = [
            (v, _rank(v, food=food, diet_type=diet_type, fitness_goal=fitness_goal,
                      favorite_foods=favorite_foods))
            for v in videos if v.get("embeddable")
        ]
        # A weakly-matching result is worse than none: showing an unrelated
        # video to fill the screen is explicitly not acceptable here.
        scored = [(v, s) for v, s in scored if s > 0]
        if scored:
            scored.sort(key=lambda p: (-p[1], p[0]["video_id"]))
            ranked = [v for v, _ in scored]
            break
        # Nothing usable — try the next, less specific variant. At most 3.

    _cache_put(key, ranked)
    print(f"[YOUTUBE] search '{queries[0]}' -> {len(ranked)} usable results")
    return ranked[:limit]


def fetch_channel(channel_id: str) -> dict[str, Any] | None:
    """`channels.list` — 1 quota unit. Only the fields YouTube actually
    returns; nothing here is invented. Follower counts, ratings and verified
    badges are deliberately NOT surfaced by this feature."""
    key = _cache_key(channel=channel_id)
    cached = _cache_get(key)
    if cached is not None:
        return cached[0] if cached else None

    data = _get(_CHANNELS_URL, {"part": "snippet", "id": channel_id})
    items = data.get("items") or []
    if not items:
        _cache_put(key, [])
        return None
    snippet = items[0].get("snippet") or {}
    thumbs = snippet.get("thumbnails") or {}
    handle = snippet.get("customUrl")  # e.g. "@rahulfitness" — may be absent
    channel = {
        "channel_id": channel_id,
        "channel_name": snippet.get("title"),
        "channel_handle": handle,
        "channel_thumbnail": (thumbs.get("medium") or thumbs.get("default") or {}).get("url"),
        "channel_url": (
            f"https://www.youtube.com/{handle}" if handle
            else f"https://www.youtube.com/channel/{channel_id}"
        ),
        "description": (snippet.get("description") or "")[:400],
        "platform": "youtube",
    }
    _cache_put(key, [channel])
    return channel
