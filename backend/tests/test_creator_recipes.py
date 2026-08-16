"""
ZITLAS — Creator Recipe (YouTube) tests
(backend/tests/test_creator_recipes.py)

Exercises the REAL routes/creator_recipes.py and
services/youtube_recipe_service.py with the upstream YouTube HTTP calls
stubbed. No test ever needs, reads, or fabricates an API key: `requests.get`
is replaced, so nothing reaches Google and no credential is involved.

The properties under test are the ones that would actually hurt in
production: workout slots must never reach an open recipe search, the key
must never appear in a response, quota failures must not be retried, and a
weak match must produce "nothing found" rather than an unrelated video.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import creator_recipes  # noqa: E402
from services import youtube_recipe_service as yt  # noqa: E402

# A recognisable placeholder. This is NOT a credential and never leaves the
# test process — the real key lives only in the environment.
_FAKE_ENV_KEY = "test-not-a-real-key"


class _Resp:
    def __init__(self, payload, status=200, text=""):
        self._payload = payload
        self.status_code = status
        self.text = text or ""

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


def _search_payload(*video_ids):
    return {"items": [{"id": {"videoId": v}} for v in video_ids]}


def _videos_payload(*videos):
    """Mirrors the REAL videos.list shape, including the contentDetails the
    Shorts gate depends on. `duration` defaults to a genuine Short so tests
    that aren't about duration stay readable."""
    items = []
    for v in videos:
        item = {
            "id": v["id"],
            "snippet": {
                "title": v.get("title", "Recipe"),
                "description": v.get("description", ""),
                "channelId": v.get("channel_id", "UC_test"),
                "channelTitle": v.get("channel", "Test Kitchen"),
                "thumbnails": {"high": {"url": f"https://i.ytimg.com/{v['id']}.jpg"}},
                "publishedAt": "2026-01-01T00:00:00Z",
                "liveBroadcastContent": v.get("live", "none"),
            },
            "status": {"embeddable": v.get("embeddable", True)},
            "contentDetails": {"duration": v.get("duration", "PT45S")},
        }
        if v.get("live_details"):
            item["liveStreamingDetails"] = {"actualStartTime": "2026-01-01T00:00:00Z"}
        items.append(item)
    return {"items": items}


@pytest.fixture(autouse=True)
def _clear_cache():
    yt._cache.clear()
    yield
    yt._cache.clear()


@pytest.fixture
def configured(monkeypatch):
    monkeypatch.setenv("YOUTUBE_API_KEY", _FAKE_ENV_KEY)


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(creator_recipes.router, prefix="/api/creator-recipes")
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _stub(monkeypatch, search_ids, videos, capture=None):
    """Replace the ONLY outbound call the service makes."""
    def _fake_get(url, params=None, timeout=None):
        if capture is not None:
            capture.append((url, dict(params or {})))
        if url == yt._SEARCH_URL:
            return _Resp(_search_payload(*search_ids))
        if url == yt._VIDEOS_URL:
            return _Resp(_videos_payload(*videos))
        if url == yt._CHANNELS_URL:
            return _Resp({"items": [{"snippet": {
                "title": "Rahul Fitness Kitchen",
                "customUrl": "@RahulFitness",
                "description": "High protein Indian recipes.",
                "thumbnails": {"medium": {"url": "https://i.ytimg.com/c.jpg"}},
            }}]})
        return _Resp({}, status=404)
    monkeypatch.setattr(yt.requests, "get", _fake_get)


# ── 1-3. Food relevance ──────────────────────────────────────────────────

@pytest.mark.parametrize("food", ["Pizza", "Burger", "Sandwich"])
def test_food_specific_results_are_returned(monkeypatch, configured, client, food):
    lower = food.lower()
    _stub(monkeypatch,
          ["v1", "v2"],
          [{"id": "v1", "title": f"High Protein {food} Recipe"},
           {"id": "v2", "title": f"Healthy {food} at home"}])
    body = client.get(f"/api/creator-recipes/recommended?food={food}&meal_type=lunch").json()
    assert body["count"] > 0
    assert lower in body["videos"][0]["title"].lower()


def test_a_video_unrelated_to_the_food_is_not_returned(monkeypatch, configured, client):
    """A weak match is worse than none — the screen must say "no suitable
    recipe", not fill itself with something irrelevant."""
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "My morning gym vlog", "description": "training day"}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["count"] == 0


def test_obvious_non_recipe_formats_rank_below_real_recipes(monkeypatch, configured, client):
    _stub(monkeypatch,
          ["junk", "real"],
          [{"id": "junk", "title": "PIZZA MUKBANG reaction vlog"},
           {"id": "real", "title": "High Protein Pizza Recipe"}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["videos"][0]["video_id"] == "real"


# ── 4-6. Context shapes the query ────────────────────────────────────────

def test_vegetarian_diet_reaches_the_query(monkeypatch, configured, client):
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Vegetarian Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&diet_type=vegetarian")
    query = next(p["q"] for u, p in seen if u == yt._SEARCH_URL)
    assert "vegetarian" in query.lower()


def test_muscle_gain_asks_for_protein(monkeypatch, configured, client):
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "High Protein Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&fitness_goal=muscle_gain")
    query = next(p["q"] for u, p in seen if u == yt._SEARCH_URL)
    assert "high protein" in query.lower()


def test_weight_loss_asks_for_healthy_not_bulk_protein(monkeypatch, configured, client):
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Healthy Low Calorie Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&fitness_goal=weight_loss")
    query = next(p["q"] for u, p in seen if u == yt._SEARCH_URL)
    assert "healthy" in query.lower() or "low calorie" in query.lower()


def test_a_vegetarian_athlete_is_not_handed_a_chicken_video_first(monkeypatch, configured, client):
    _stub(monkeypatch,
          ["meat", "veg"],
          [{"id": "meat", "title": "Chicken Pizza Recipe"},
           {"id": "veg", "title": "Paneer Pizza Recipe vegetarian"}])
    body = client.get(
        "/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&diet_type=vegetarian").json()
    assert body["videos"][0]["video_id"] == "veg"


def test_query_never_becomes_an_unusable_pile_of_every_field(monkeypatch, configured, client):
    """An over-specified query matches nothing on YouTube — the builder must
    stay readable regardless of how much profile context exists."""
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "High Protein Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch"
               "&fitness_goal=muscle_gain&diet_type=vegetarian"
               "&living_situation=hostel&region=Maharashtra")
    query = next(p["q"] for u, p in seen if u == yt._SEARCH_URL)
    assert len(query.split()) <= 8, f"query too long to match anything: {query!r}"


def test_a_messy_plan_food_line_is_cleaned_before_searching(monkeypatch, configured, client):
    """Plan foods read like "Poha (Home Style) (1 plate (200 g))" — the
    parenthetical noise wrecks relevance and must be stripped."""
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Poha Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?"
               "food=Poha%20(Home%20Style)%20(1%20plate%20(200%20g))&meal_type=breakfast")
    query = next(p["q"] for u, p in seen if u == yt._SEARCH_URL)
    assert "(" not in query and "200" not in query
    assert "poha" in query.lower()


# ── 7-9. Workout slots are refused ───────────────────────────────────────

@pytest.mark.parametrize("slot", ["pre_workout", "post_workout", "pre-workout", "post-workout"])
def test_workout_slots_are_refused_outright(monkeypatch, configured, client, slot):
    """The purpose-built workout nutrition system must not be bypassed by an
    open YouTube search."""
    called = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}], capture=called)
    r = client.get(f"/api/creator-recipes/recommended?food=Banana&meal_type={slot}")
    assert r.status_code == 400
    assert r.json()["detail"] == "workout_slot_not_supported"
    assert called == [], "a workout slot must not even reach YouTube"


@pytest.mark.parametrize("slot", ["breakfast", "lunch", "dinner", "snack"])
def test_normal_meal_slots_are_allowed(monkeypatch, configured, client, slot):
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}])
    r = client.get(f"/api/creator-recipes/recommended?food=Pizza&meal_type={slot}")
    assert r.status_code == 200


# ── 10-11. See Another Recipe ────────────────────────────────────────────

def test_excluded_video_is_not_returned_again(monkeypatch, configured, client):
    _stub(monkeypatch,
          ["a", "b", "c"],
          [{"id": "a", "title": "Pizza Recipe one"},
           {"id": "b", "title": "Pizza Recipe two"},
           {"id": "c", "title": "Pizza Recipe three"}])
    body = client.get(
        "/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&exclude_ids=a").json()
    ids = [v["video_id"] for v in body["videos"]]
    assert "a" not in ids
    assert ids


def test_cycling_back_rather_than_returning_nothing_when_all_seen(monkeypatch, configured, client):
    _stub(monkeypatch, ["a"], [{"id": "a", "title": "Pizza Recipe"}])
    body = client.get(
        "/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&exclude_ids=a").json()
    assert body["count"] == 1
    assert body["cycled"] is True


def test_see_another_costs_no_extra_youtube_search(monkeypatch, configured, client):
    """The whole quota strategy: the second request is served from cache."""
    searches = []
    _stub(monkeypatch,
          ["a", "b"],
          [{"id": "a", "title": "Pizza Recipe one"}, {"id": "b", "title": "Pizza Recipe two"}],
          capture=searches)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    first = sum(1 for u, _ in searches if u == yt._SEARCH_URL)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&exclude_ids=a")
    second = sum(1 for u, _ in searches if u == yt._SEARCH_URL)
    assert first == 1
    assert second == 1, "See Another must not trigger a second YouTube search"


# ── 12. Works with no food preference at all ─────────────────────────────

def test_works_without_any_profile_context(monkeypatch, configured, client):
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza").json()
    assert body["count"] == 1


# ── 13-14. Failure handling ──────────────────────────────────────────────

def test_no_results_is_a_clean_empty_response_not_an_error(monkeypatch, configured, client):
    _stub(monkeypatch, [], [])
    r = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    assert r.status_code == 200
    assert r.json()["count"] == 0


def test_quota_exhaustion_returns_429_and_is_not_retried(monkeypatch, configured, client):
    calls = []

    def _fake_get(url, params=None, timeout=None):
        calls.append(url)
        return _Resp(None, status=403, text='{"error":{"errors":[{"reason":"quotaExceeded"}]}}')

    monkeypatch.setattr(yt.requests, "get", _fake_get)
    r = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    assert r.status_code == 429
    assert r.json()["detail"] == "creator_recipes_quota"
    # Exactly one upstream attempt — auto-retrying a quota error just burns
    # what little is left.
    assert len(calls) == 1


def test_upstream_failure_returns_502_without_leaking_details(monkeypatch, configured, client):
    def _boom(url, params=None, timeout=None):
        raise yt.requests.RequestException(
            f"Connection failed for https://googleapis.com/x?key={_FAKE_ENV_KEY}")

    monkeypatch.setattr(yt.requests, "get", _boom)
    r = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    assert r.status_code == 502
    assert _FAKE_ENV_KEY not in r.text


def test_missing_configuration_is_reported_not_crashed(monkeypatch, client):
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    r = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    assert r.status_code == 503
    assert r.json()["detail"] == "creator_recipes_not_configured"


def test_food_is_required(configured, client):
    assert client.get("/api/creator-recipes/recommended?meal_type=lunch").status_code == 422


# ── 15. THE API KEY NEVER REACHES THE CLIENT ─────────────────────────────

def test_api_key_is_absent_from_every_response_on_the_happy_path(monkeypatch, configured, client):
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}])
    for path in (
        "/api/creator-recipes/recommended?food=Pizza&meal_type=lunch",
        "/api/creator-recipes/channel/UC_test",
        "/api/creator-recipes/health",
    ):
        body = client.get(path).text
        assert _FAKE_ENV_KEY not in body, f"key leaked via {path}"


def test_health_reports_configuration_without_revealing_anything(monkeypatch, configured, client):
    body = client.get("/api/creator-recipes/health").json()
    assert body["status"] == "ready"
    assert _FAKE_ENV_KEY not in str(body)
    assert "key" not in {k.lower() for k in body}


def test_the_key_is_sent_to_youtube_but_never_stored_in_the_result(monkeypatch, configured, client):
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}], capture=seen)
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    # It IS used upstream...
    assert any(p.get("key") == _FAKE_ENV_KEY for _, p in seen)
    # ...and appears nowhere in what the client receives.
    assert _FAKE_ENV_KEY not in str(body)


# ── Embeddability / no re-hosting ────────────────────────────────────────

def test_non_embeddable_videos_are_filtered_out_of_recommendations(monkeypatch, configured, client):
    _stub(monkeypatch,
          ["no", "yes"],
          [{"id": "no", "title": "Pizza Recipe blocked", "embeddable": False},
           {"id": "yes", "title": "Pizza Recipe playable", "embeddable": True}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert [v["video_id"] for v in body["videos"]] == ["yes"]


def test_search_asks_youtube_for_embeddable_videos_only(monkeypatch, configured, client):
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    params = next(p for u, p in seen if u == yt._SEARCH_URL)
    assert params["videoEmbeddable"] == "true"
    assert params["type"] == "video"


def test_response_carries_only_youtube_references_never_media(monkeypatch, configured, client):
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}])
    video = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()["videos"][0]
    assert video["video_url"].startswith("https://www.youtube.com/watch?v=")
    assert video["platform"] == "youtube"
    # No downloadable/proxied media field of any kind.
    assert not any(k in video for k in ("stream_url", "file_url", "download_url", "media"))


# ── Creator profile ──────────────────────────────────────────────────────

def test_channel_returns_only_fields_youtube_actually_provides(monkeypatch, configured, client):
    _stub(monkeypatch, [], [])
    body = client.get("/api/creator-recipes/channel/UC_test").json()
    assert body["channel_name"] == "Rahul Fitness Kitchen"
    assert body["channel_handle"] == "@RahulFitness"
    assert body["channel_url"].endswith("@RahulFitness")
    # Never invented.
    for invented in ("subscribers", "subscriber_count", "rating", "verified", "reviews"):
        assert invented not in body


def test_unknown_channel_is_a_clean_404(monkeypatch, configured, client):
    monkeypatch.setattr(yt.requests, "get", lambda url, params=None, timeout=None: _Resp({"items": []}))
    assert client.get("/api/creator-recipes/channel/UC_missing").status_code == 404


# ── Query builder unit coverage ──────────────────────────────────────────

def test_build_queries_puts_the_most_specific_variant_first():
    qs = yt.build_queries(food="Pizza", fitness_goal="muscle_gain", diet_type="vegetarian")
    assert qs
    assert "pizza" in qs[0].lower()
    assert "recipe" in qs[0].lower()


def test_build_queries_returns_nothing_for_an_empty_food():
    assert yt.build_queries(food="   ") == []


def test_build_queries_is_capped_to_a_few_variants():
    qs = yt.build_queries(food="Pizza", fitness_goal="muscle_gain", diet_type="vegetarian",
                          meal_type="lunch", living_situation="hostel", region="Maharashtra")
    assert 1 <= len(qs) <= 3, "too many variants would multiply quota cost"


def test_region_never_displaces_the_food_from_the_primary_query():
    qs = yt.build_queries(food="Pizza", region="Maharashtra", fitness_goal="weight_loss")
    assert "pizza" in qs[0].lower()


# ── SHORT-FORM ONLY ──────────────────────────────────────────────────────
# Creator Recipe means a SHORT recipe video. Long-form is rejected outright,
# never down-ranked — filling a thin result set with a 10-minute tutorial is
# explicitly not acceptable.

def test_duration_parser_handles_every_iso8601_shape():
    assert yt.parse_iso8601_duration("PT45S") == 45
    assert yt.parse_iso8601_duration("PT1M30S") == 90
    assert yt.parse_iso8601_duration("PT3M") == 180
    assert yt.parse_iso8601_duration("PT10M15S") == 615
    assert yt.parse_iso8601_duration("PT1H2M3S") == 3723
    # Unparseable/absent is NOT optimistically allowed through.
    assert yt.parse_iso8601_duration(None) is None
    assert yt.parse_iso8601_duration("garbage") is None


@pytest.mark.parametrize("duration,seconds", [
    ("PT15S", 15), ("PT59S", 59), ("PT1M", 60), ("PT2M59S", 179), ("PT3M", 180),
])
def test_videos_at_or_under_180s_are_accepted(monkeypatch, configured, client, duration, seconds):
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe", "duration": duration}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["count"] == 1
    assert body["videos"][0]["duration_seconds"] == seconds


@pytest.mark.parametrize("duration", ["PT3M1S", "PT5M", "PT8M30S", "PT10M", "PT15M", "PT22M", "PT1H"])
def test_long_form_videos_are_rejected_outright(monkeypatch, configured, client, duration):
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "High Protein Pizza Recipe", "duration": duration}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["count"] == 0, f"{duration} is long-form and must never be returned"


def test_a_highly_relevant_long_video_is_still_rejected(monkeypatch, configured, client):
    """Relevance must NEVER buy a long-form video its way in — the only
    survivor here is the shorter, less keyword-dense clip."""
    _stub(monkeypatch, ["long", "short"], [
        {"id": "long", "title": "High Protein Vegetarian Pizza Recipe healthy homemade", "duration": "PT12M"},
        {"id": "short", "title": "Pizza recipe", "duration": "PT30S"},
    ])
    body = client.get(
        "/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&fitness_goal=muscle_gain").json()
    ids = [v["video_id"] for v in body["videos"]]
    assert ids == ["short"]


def test_fewer_results_rather_than_padding_with_long_form(monkeypatch, configured, client):
    """If only one Short exists, return one — never top up with long-form."""
    _stub(monkeypatch, ["a", "b", "c"], [
        {"id": "a", "title": "Pizza Recipe", "duration": "PT40S"},
        {"id": "b", "title": "Pizza Recipe full tutorial", "duration": "PT9M"},
        {"id": "c", "title": "Pizza Recipe masterclass", "duration": "PT20M"},
    ])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&limit=10").json()
    assert body["count"] == 1
    assert body["videos"][0]["video_id"] == "a"


def test_a_video_with_no_duration_is_rejected(monkeypatch, configured, client):
    """Unknown length can't be proven short, so it is not eligible."""
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe", "duration": None}])
    assert client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()["count"] == 0


def test_livestreams_are_rejected(monkeypatch, configured, client):
    for marker in ({"live": "live"}, {"live": "upcoming"}, {"live_details": True}):
        _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe", "duration": "PT45S", **marker}])
        yt._cache.clear()
        body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
        assert body["count"] == 0, f"livestream marker {marker} must be rejected"


def test_search_asks_youtube_for_short_videos_only(monkeypatch, configured, client):
    """A pre-filter that improves the candidate mix for free. Not the rule —
    `videoDuration=short` means under FOUR minutes, so the real 180s gate
    still runs on contentDetails."""
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    params = next(p for u, p in seen if u == yt._SEARCH_URL)
    assert params["videoDuration"] == "short"
    assert params["type"] == "video", "type=video also excludes playlists and channels"


def test_duration_is_requested_from_the_videos_endpoint(monkeypatch, configured, client):
    seen = []
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Pizza Recipe"}], capture=seen)
    client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch")
    params = next(p for u, p in seen if u == yt._VIDEOS_URL)
    assert "contentDetails" in params["part"]
    assert "liveStreamingDetails" in params["part"]


# ── Shorts ranking ───────────────────────────────────────────────────────

def test_a_shorter_video_outranks_a_longer_one_all_else_equal(monkeypatch, configured, client):
    _stub(monkeypatch, ["longer", "shorter"], [
        {"id": "longer", "title": "Pizza Recipe", "duration": "PT2M50S"},
        {"id": "shorter", "title": "Pizza Recipe", "duration": "PT25S"},
    ])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["videos"][0]["video_id"] == "shorter"


def test_an_explicit_shorts_marker_is_rewarded_not_penalised(monkeypatch, configured, client):
    """Reverses the earlier heuristic that preferred full tutorials."""
    _stub(monkeypatch, ["plain", "tagged"], [
        {"id": "plain", "title": "Pizza Recipe", "duration": "PT90S"},
        {"id": "tagged", "title": "Pizza Recipe #shorts", "duration": "PT90S"},
    ])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["videos"][0]["video_id"] == "tagged"


def test_shorts_marker_is_not_required_to_be_eligible(monkeypatch, configured, client):
    """Creators often omit #shorts — duration decides eligibility, not tags."""
    _stub(monkeypatch, ["v1"], [{"id": "v1", "title": "Protein Pizza Recipe", "duration": "PT35S"}])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch").json()
    assert body["count"] == 1


def test_every_returned_video_satisfies_all_eligibility_rules(monkeypatch, configured, client):
    """The contract the Flutter client relies on, asserted as a whole."""
    _stub(monkeypatch, ["a", "b", "c", "d"], [
        {"id": "a", "title": "Protein Pizza Recipe #shorts", "duration": "PT30S"},
        {"id": "b", "title": "Pizza Recipe long", "duration": "PT11M"},
        {"id": "c", "title": "Pizza Recipe blocked", "duration": "PT40S", "embeddable": False},
        {"id": "d", "title": "Pizza Recipe live", "duration": "PT50S", "live": "live"},
    ])
    body = client.get("/api/creator-recipes/recommended?food=Pizza&meal_type=lunch&limit=10").json()
    assert body["count"] == 1
    for v in body["videos"]:
        assert v["duration_seconds"] <= 180
        assert v["embeddable"] is True
        assert v["platform"] == "youtube"
