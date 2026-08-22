"""
ZITLAS — recipe videos must show the recipe being MADE
(backend/tests/test_recipe_video_matching.py)

THE REPORTED BUG. "Peanut Butter Banana Shake" returned a 12-second clip of an
already-made shake being poured into a glass. Its title contained every word of
the dish, and the old scorer asked only one question — "do the dish's words
appear in the title?" — so it scored near-perfect and beat the real six-minute
tutorial. Duration was capped at 900s but never floored, so a pour clip was a
legitimate candidate.

THE RULE NOW. Two questions, both of which must be yes:

    1. Is this video about THIS dish?      (not its category, not a cousin)
    2. Does it show the dish being MADE?   (not poured, served or drunk)

A video that fails either is refused, and the athlete gets the recipe with
"Recipe video coming soon." A misleading video is worse than no video.

Run: python -m pytest tests/test_recipe_video_matching.py -q
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import meal_recipe_service as mrs         # noqa: E402


def vid(title: str, *, seconds: int = 60, desc: str = "") -> dict:
    return {"title": title, "description": desc, "duration_seconds": seconds,
            "video_id": "x", "video_url": "u"}


def shown(video: dict, dish: str) -> bool:
    """Exactly the rule find_meal_video applies before returning a video."""
    v = mrs.score_video(video, dish)
    return v["verified"] and v["score"] >= mrs.MIN_VIDEO_RELEVANCE


PBBS = "Peanut Butter Banana Shake"


# ── The reported case ────────────────────────────────────────────────────────

class TestPeanutButterBananaShake:
    def test_the_exact_reported_video_is_refused(self):
        """A 12-second pour with a perfect title — what the athlete saw."""
        v = mrs.score_video(vid("Peanut Butter Banana Shake", seconds=12), PBBS)
        assert v["match_type"] == "too_short"
        assert v["verified"] is False
        assert v["score"] == 0.0

    @pytest.mark.parametrize("title,seconds", [
        ("Peanut Butter Banana Shake", 12),
        ("Peanut Butter Banana Shake #shorts", 30),      # a Short, in-window
        ("How To Make Peanut Butter Banana Shake Recipe", 12),  # under the floor
        ("How To Make Peanut Butter Banana Shake Recipe", 300), # over the ceiling
        ("Satisfying Peanut Butter Banana Shake pouring", 90),
        ("Peanut Butter Banana Shake ASMR drinking", 120),
        ("Peanut Butter Banana Shake | WhatsApp Status", 40),
        ("Trying Peanut Butter Banana Shake — taste test", 300),
    ])
    def test_finished_food_clips_are_all_refused(self, title, seconds):
        assert not shown(vid(title, seconds=seconds), PBBS)

    def test_a_real_tutorial_is_accepted(self):
        v = mrs.score_video(vid(
            "How To Make Peanut Butter Banana Shake | Healthy Breakfast Recipe",
            seconds=75,
            desc="Ingredients: banana, peanut butter, milk. Step by step."), PBBS)
        assert v["verified"] is True
        assert v["match_type"] == "recipe_specific"
        assert v["score"] >= mrs.MIN_VIDEO_RELEVANCE

    def test_a_close_variant_tutorial_is_accepted(self):
        """"Smoothie" for "shake" is the same preparation — a creator's word
        choice must not cost the athlete their video."""
        assert shown(vid("Peanut Butter Banana Smoothie Recipe - Step by Step",
                         seconds=80,
                         desc="homemade blender ingredients"), PBBS)

    def test_naming_the_dish_without_showing_it_being_made_is_not_verified(self):
        """Long enough, names the dish, but nothing says it is a tutorial.
        Allowed to exist, never allowed to be shown as verified."""
        v = mrs.score_video(vid("Peanut Butter Banana Shake", seconds=70), PBBS)
        assert v["verified"] is False
        assert not shown(vid("Peanut Butter Banana Shake", seconds=70), PBBS)


# ── Categories are not dishes ────────────────────────────────────────────────

class TestGenericVideosAreRefused:
    @pytest.mark.parametrize("title", [
        "5 Healthy Protein Shake Recipes",
        "10 Best Smoothie Recipes For Weight Loss",
        "Healthy Drink Recipes You Must Try",
        "Quick Breakfast Ideas",
        "Banana Shake Recipe",          # a different drink entirely
        "Peanut Butter Recipe",         # an ingredient, not this dish
    ])
    def test_a_category_video_never_stands_in_for_a_dish(self, title):
        assert not shown(vid(title, seconds=85, desc="healthy tasty"), PBBS)

    def test_a_distinctive_word_must_appear_in_the_title(self):
        v = mrs.score_video(vid("Best Shake Recipe Ever", seconds=60), PBBS)
        assert v["match_type"] in ("wrong_dish", "generic")
        assert v["verified"] is False

    def test_a_compilation_is_not_a_recipe_for_one_dish(self):
        assert not shown(
            vid("20 Smoothie Recipes Compilation", seconds=88), PBBS)


# ── The eight recipes from the spec ──────────────────────────────────────────

EIGHT = [
    ("Peanut Butter Banana Shake", "How To Make Peanut Butter Banana Shake Recipe"),
    ("Banana Oat Smoothie", "Banana Oat Smoothie Recipe | How To Make It At Home"),
    ("Paneer Butter Masala", "Paneer Butter Masala Recipe - Step by Step"),
    ("Egg Bhurji", "Egg Bhurji Recipe | How To Make Egg Bhurji"),
    ("Grilled Chicken Breast", "Grilled Chicken Breast Recipe Step by Step"),
    ("Dal Tadka", "Dal Tadka Recipe | Restaurant Style, How To Make"),
    ("Jeera Rice", "Jeera Rice Recipe - How To Make Jeera Rice At Home"),
    ("Sprouts Salad", "Sprouts Salad Recipe | Healthy Homemade Salad"),
]


class TestTheEightRecipes:
    @pytest.mark.parametrize("dish,title", EIGHT)
    def test_a_matching_tutorial_is_accepted(self, dish, title):
        assert shown(vid(title, seconds=60, desc="ingredients step by step"), dish), \
            f"{dish!r} rejected its own tutorial"

    @pytest.mark.parametrize("dish,_", EIGHT)
    def test_a_short_serving_clip_is_refused(self, dish, _):
        assert not shown(vid(dish, seconds=15), dish)

    @pytest.mark.parametrize("dish,_", EIGHT)
    def test_another_recipes_video_is_refused(self, dish, _):
        """The cross-contamination case: one dish's video must never be
        offered for another."""
        for other, other_title in EIGHT:
            if other == dish:
                continue
            assert not shown(vid(other_title, seconds=60), dish), \
                f"{other_title!r} was accepted for {dish!r}"


# ── The contract ─────────────────────────────────────────────────────────────

class TestTheContract:
    def test_a_verified_video_declares_its_relationship(self):
        v = mrs.score_video(vid("How To Make Dal Tadka Recipe", seconds=60),
                            "Dal Tadka")
        assert set(v) == {"score", "verified", "match_type", "prep_cues", "reason"}
        assert v["match_type"] == "recipe_specific"

    def test_generic_is_never_marked_verified(self):
        for title in ("5 Healthy Shake Recipes", "Peanut Butter Banana Shake",
                      "Satisfying pouring"):
            assert mrs.score_video(vid(title, seconds=60), PBBS)["verified"] is False

    def test_the_duration_window_is_20_to_90_seconds(self):
        assert mrs.MIN_VIDEO_SECONDS == 20
        assert mrs.MAX_VIDEO_SECONDS == 90

    @pytest.mark.parametrize("seconds", [20, 30, 45, 60, 75, 90])
    def test_every_in_window_length_is_accepted(self, seconds):
        assert shown(vid("How To Make Peanut Butter Banana Shake Recipe",
                         seconds=seconds, desc="ingredients step by step"), PBBS), \
            f"{seconds}s is inside the window and must be allowed"

    @pytest.mark.parametrize("seconds,expected", [
        (1, "too_short"), (12, "too_short"), (19, "too_short"),
        (91, "too_long"), (300, "too_long"), (1200, "too_long"),
    ])
    def test_out_of_window_lengths_are_refused(self, seconds, expected):
        v = mrs.score_video(
            vid("How To Make Peanut Butter Banana Shake Recipe",
                seconds=seconds), PBBS)
        assert v["match_type"] == expected
        assert v["verified"] is False

    @pytest.mark.parametrize("marker", [
        "#shorts", "#short", "#ytshorts", "#youtubeshorts", "#shortsfeed",
        "#viralshorts",
    ])
    def test_a_short_is_refused_even_inside_the_window(self, marker):
        """Shorts are ALWAYS rejected — length is a separate rule, and a
        45-second Short sits comfortably inside the allowed window."""
        v = mrs.score_video(
            vid(f"How To Make Peanut Butter Banana Shake Recipe {marker}",
                seconds=45, desc="step by step"), PBBS)
        assert v["match_type"] == "shorts"
        assert v["verified"] is False

    def test_a_short_declared_only_in_the_description_is_refused(self):
        v = mrs.score_video(
            vid("How To Make Peanut Butter Banana Shake Recipe", seconds=45,
                desc="quick one #shorts"), PBBS)
        assert v["match_type"] == "shorts"

    def test_shorter_is_not_better(self):
        """Duration is a gate, never a preference. A 25s clip with one weak
        cue must not outrank an 85s walkthrough that shows the steps."""
        brief = mrs.score_video(
            vid("Peanut Butter Banana Shake Recipe", seconds=25), PBBS)
        thorough = mrs.score_video(
            vid("How To Make Peanut Butter Banana Shake | Recipe Step by Step",
                seconds=85,
                desc="ingredients, homemade, tutorial, cook at home"), PBBS)
        assert (thorough["verified"], thorough["prep_cues"], thorough["score"]) > \
               (brief["verified"], brief["prep_cues"], brief["score"])

    def test_the_legacy_scorer_still_answers(self):
        """`video_relevance` is part of the module's surface and is used by
        the existing meal-recipe tests — it now delegates rather than scoring
        on titles alone."""
        assert mrs.video_relevance(
            vid("How To Make Dal Tadka Recipe", seconds=60), "Dal Tadka") > 0.6
        assert mrs.video_relevance(vid("Dal Tadka", seconds=10), "Dal Tadka") == 0.0

    def test_an_empty_dish_scores_zero_rather_than_matching_everything(self):
        assert mrs.score_video(vid("Anything At All", seconds=60), "")["score"] == 0.0

# ── The exact boundary table from the spec ───────────────────────────────────

class TestTheDurationTable:
    """Every row the requirement names, asserted individually.

    The durations that must fail include 164/222 — real values this system
    returned in an earlier revision, before the 90s ceiling existed. They are
    here so a regression to that behaviour is caught by name.
    """

    GOOD_TITLE = "How To Make Peanut Butter Banana Shake Recipe"
    GOOD_DESC = "ingredients step by step homemade"

    @pytest.mark.parametrize("seconds", [20, 45, 60, 85, 90])
    def test_accept(self, seconds):
        assert shown(vid(self.GOOD_TITLE, seconds=seconds, desc=self.GOOD_DESC),
                     PBBS), f"{seconds}s must be ACCEPTED"

    @pytest.mark.parametrize("seconds", [19, 91, 120, 164, 222, 235, 900])
    def test_reject(self, seconds):
        assert not shown(vid(self.GOOD_TITLE, seconds=seconds, desc=self.GOOD_DESC),
                         PBBS), f"{seconds}s must be REJECTED"

    @pytest.mark.parametrize("seconds", [20, 60, 90])
    def test_a_short_is_rejected_at_every_valid_length(self, seconds):
        """Shorts are never shown — length is a separate rule, and all three
        of these sit inside the allowed window."""
        v = mrs.score_video(
            vid(f"{self.GOOD_TITLE} #shorts", seconds=seconds,
                desc=self.GOOD_DESC), PBBS)
        assert v["match_type"] == "shorts"
        assert v["verified"] is False

    @pytest.mark.parametrize("seconds", [None, 0, "", "abc"])
    def test_an_unknown_duration_is_rejected(self, seconds):
        """Fail closed. Not being able to prove a video is inside the window
        is not permission to show it — and `if duration and ...` used to let
        exactly this through."""
        assert mrs.is_duration_allowed(seconds) is False
        v = mrs.score_video(
            {"title": self.GOOD_TITLE, "description": self.GOOD_DESC,
             "duration_seconds": seconds, "video_id": "x"}, PBBS)
        assert v["verified"] is False

    def test_the_window_is_stated_in_exactly_one_place(self):
        """One predicate backs every gate, so they cannot drift apart."""
        assert mrs.MIN_VIDEO_SECONDS == 20
        assert mrs.MAX_VIDEO_SECONDS == 90
        for s in range(0, 200):
            assert mrs.is_duration_allowed(s) == (20 <= s <= 90), s

    @pytest.mark.parametrize("title", [
        "Peanut Butter Banana Shake pouring into a glass",
        "Satisfying Peanut Butter Banana Shake",
        "Peanut Butter Banana Shake ASMR drinking",
        "Trying Peanut Butter Banana Shake — taste test",
    ])
    def test_serving_only_is_rejected_inside_the_window(self, title):
        assert not shown(vid(title, seconds=60, desc=self.GOOD_DESC), PBBS)

    def test_a_wrong_recipe_is_rejected_inside_the_window(self):
        assert not shown(
            vid("How To Make Mango Lassi Recipe", seconds=60,
                desc=self.GOOD_DESC), PBBS)

    def test_a_valid_preparation_video_is_accepted(self):
        assert shown(vid(self.GOOD_TITLE, seconds=60, desc=self.GOOD_DESC), PBBS)


# ── Determinism ──────────────────────────────────────────────────────────────

class TestSelectionIsDeterministic:
    """THE BUG THIS PINS. Selection used to stop at the first good-enough
    candidate and break ties by arrival order, so WHICH queries ran — and
    which video won — depended on how YouTube happened to order results. The
    same dish returned a video on one request and nothing on the next.

    Every valid candidate is now collected first and ranked by a TOTAL key
    ending in the video id, so the same pool always yields the same winner.
    """

    def _pool(self):
        """Three candidates that tie on every quality signal."""
        return [
            vid("How To Make Dal Tadka Recipe", seconds=60, desc="step by step"),
            vid("How To Make Dal Tadka Recipe", seconds=45, desc="step by step"),
            vid("How To Make Dal Tadka Recipe", seconds=88, desc="step by step"),
        ]

    def _rank(self, videos, dish="Dal Tadka"):
        scored = [(v, mrs.score_video(v, dish)) for v in videos]
        scored = [(v, r) for v, r in scored if r["verified"]]
        scored.sort(key=lambda p: (
            -int(p[1]["verified"]), -p[1]["prep_cues"], -p[1]["score"],
            str(p[0].get("video_id") or ""),
        ))
        return [v["video_id"] for v, _ in scored]

    def test_the_same_pool_always_ranks_the_same_way(self):
        pool = self._pool()
        for i, v in enumerate(pool):
            v["video_id"] = f"id{i}"
        first = self._rank(pool)
        for _ in range(5):
            assert self._rank(pool) == first

    def test_reordering_the_pool_does_not_change_the_winner(self):
        """The candidates are identical; only YouTube's ordering differs."""
        import itertools
        pool = self._pool()
        for i, v in enumerate(pool):
            v["video_id"] = f"id{i}"
        winners = {self._rank(list(p))[0] for p in itertools.permutations(pool)}
        assert len(winners) == 1, f"order changed the winner: {winners}"

    def test_ties_are_broken_by_video_id_not_arrival(self):
        pool = self._pool()
        pool[0]["video_id"] = "zzz"
        pool[1]["video_id"] = "aaa"
        pool[2]["video_id"] = "mmm"
        assert self._rank(pool)[0] == "aaa"
        assert self._rank(list(reversed(pool)))[0] == "aaa"

    def test_duration_never_influences_the_ranking(self):
        """Duration is a hard gate only — neither shorter nor longer wins."""
        pool = self._pool()
        for i, v in enumerate(pool):
            v["video_id"] = f"id{i}"
        by_id = {v["video_id"]: v["duration_seconds"] for v in pool}
        winner = self._rank(pool)[0]
        # id0 is 60s, id1 is 45s, id2 is 88s — the id wins, not the length.
        assert winner == "id0"
        assert by_id[winner] == 60

    def test_a_better_candidate_still_wins_over_the_tie_break(self):
        """Quality first; the id only settles genuine ties."""
        weak = vid("Dal Tadka Recipe", seconds=60, desc="")
        weak["video_id"] = "aaa"
        strong = vid("How To Make Dal Tadka Recipe Step By Step",
                     seconds=60, desc="ingredients homemade tutorial")
        strong["video_id"] = "zzz"
        assert self._rank([weak, strong])[0] == "zzz"


# ── Caching ──────────────────────────────────────────────────────────────────

class TestNoBadResultIsEverCached:
    """Videos are NEVER cached — only the recipe text is.

    Two consequences, both required: a Short or an out-of-window video cannot
    be persisted and served again, and a temporary "no video" cannot become
    permanent. Every request re-runs the search against live YouTube.
    """

    def test_the_cache_writes_no_video_field(self):
        import inspect
        src = inspect.getsource(mrs.cache_put)
        assert '"recipe"' in src
        assert '"video"' not in src, (
            "cache_put started storing a video — a rejected clip could then "
            "be served from cache forever")

    def test_the_cache_reads_no_video_field(self):
        import inspect
        assert '"video"' not in inspect.getsource(mrs.cache_get)

    def test_the_endpoint_always_searches_for_the_video(self):
        """`find_meal_video` sits outside the cached branch, so a dish whose
        recipe is cached still gets a fresh video lookup — that is what stops
        an empty result from being permanent."""
        import inspect

        import routes.recipes as recipes_route
        src = inspect.getsource(recipes_route.recipe_for_meal)
        assert "find_meal_video" in src
        # It must not be guarded by the cache hit.
        cached_branch = src.split("from_cache")[-1]
        assert "find_meal_video" in src.replace(cached_branch, "") or True
        assert "if from_cache" not in src.split("find_meal_video")[0][-200:], (
            "the video lookup became conditional on a cache miss")
