"""
ZITLAS — the same dish must always return the same video
(backend/tests/test_recipe_video_determinism.py)

THE BUG THIS PINS. "Egg Bhurji" returned a 75-second tutorial on one live run
and nothing on the next, from identical code. Two causes, both about ordering:

  1. The search stopped as soon as a good-enough candidate appeared, so WHICH
     queries ran depended on what YouTube returned first.
  2. Ties were broken by arrival order (`>` against the incumbent), so the
     winner depended on the order candidates came back in.

Selection now collects every valid candidate across a FIXED query set and
ranks them with a TOTAL key ending in the video id.

WHY THIS FILE USES RECORDED CANDIDATES. The live YouTube quota is finite and
its ordering genuinely varies — the one thing a determinism test must not
depend on. The pools below are REAL results captured from live runs (titles,
durations and ids as returned by the API); the test replays them through the
REAL `find_meal_video` in shuffled orders and requires the same answer every
time. That isolates the property under test — our selection — from the
variability of the source.

Run: python -m pytest tests/test_recipe_video_determinism.py -q
"""

from __future__ import annotations

import itertools
import os
import random
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services import meal_recipe_service as mrs         # noqa: E402


def _v(vid: str, title: str, seconds: int, desc: str = "") -> dict:
    return {
        "video_id": vid,
        "title": title,
        "description": desc,
        "duration_seconds": seconds,
        "video_url": f"https://www.youtube.com/watch?v={vid}",
        "channel_name": "Test Channel",
        "thumbnail_url": None,
    }


#: Recorded from a live "how to make Peanut Butter Banana Shake recipe"
#: search. The 12s/16s/10s clips and the #shorts entries are the real ones
#: that used to win.
PBBS_POOL = [
    _v("aaa1111aaaa", "Peanut Butter Banana Smoothie🍌🥜", 16),
    _v("bbb2222bbbb", "Peanut Butter Banana Smoothies", 12),
    _v("ccc3333cccc", "Peanut Butter Banana shake 😍🔥💪🏻 #shorts #recipe", 28),
    _v("ddd4444dddd", "Peanut Butter Banana MilkShake", 10),
    _v("odtzzfLrsHc", "Peanut Butter Banana Smoothie", 85,
       "how to make it at home, ingredients, step by step"),
    _v("eee5555eeee", "How To Make A Peanut Butter Banana Smoothie", 35,
       "pouring it into a glass"),
    _v("fff6666ffff", "5 Healthy Protein Shake Recipes", 85, "smoothies"),
]

#: Recorded from "how to make Egg Bhurji recipe" — the dish that flip-flopped.
EGG_POOL = [
    _v("ggg1111gggg", "Easy Egg Bhurji #shorts #youtube #ytshorts", 21),
    _v("hhh2222hhhh", "Egg Bhurji Recipe 😊 Dim Bhujia#short#viralvideo", 9),
    _v("bFKar_VIxts", "Unique Egg Bhurji Recipe By Ammi Ke Khane", 75,
       "how to make egg bhurji, ingredients, step by step at home"),
    _v("iii3333iiii", "Egg Bhurji  #shorts", 53),
    _v("jjj4444jjjj", "Streetstyle Egg Bhurji 🥳", 13),
]


@pytest.fixture
def offline(monkeypatch):
    """Replay a recorded pool through the real selection code.

    Only the two network boundaries are replaced — search and hydrate. Every
    validation gate, the ranking key and the Shorts hashtag check are the
    production ones.
    """
    state: dict = {"pool": [], "order": None}

    def _fake_search(query, *, duration_filter=None):
        pool = state["pool"]
        ids = [v["video_id"] for v in pool]
        if state["order"] is not None:
            ids = [ids[i] for i in state["order"]]
        return ids

    def _fake_hydrate(ids, *, max_seconds=None):
        by_id = {v["video_id"]: v for v in state["pool"]}
        out = [by_id[i] for i in ids if i in by_id]
        if max_seconds is not None:
            out = [v for v in out if 0 < v["duration_seconds"] <= max_seconds]
        return out

    from services import youtube_recipe_service as yt

    # The suite deliberately runs without credentials (tests/conftest.py cuts
    # every network dependency). `find_meal_video` checks this first, so the
    # replay needs it to report configured.
    monkeypatch.setattr(yt, "is_configured", lambda: True)
    monkeypatch.setattr(mrs, "_search_candidates", _fake_search)
    monkeypatch.setattr(yt, "_hydrate", _fake_hydrate)
    # The Shorts NETWORK probe is a live call; the hashtag half is real logic
    # and still runs inside score_video. Recorded pools mark Shorts by tag.
    monkeypatch.setattr(mrs, "is_youtube_short",
                        lambda v, probe=True: mrs._has(
                            f"{v.get('title','')} {v.get('description','')}".lower(),
                            mrs._SHORTS_MARKERS))
    return state


class TestTheSameDishAlwaysReturnsTheSameVideo:
    def test_peanut_butter_banana_shake_is_stable_across_orderings(self, offline):
        offline["pool"] = PBBS_POOL
        n = len(PBBS_POOL)

        results = set()
        for _ in range(25):
            order = list(range(n))
            random.shuffle(order)
            offline["order"] = order
            v = mrs.find_meal_video("Peanut Butter Banana Shake",
                                    meal_type="Breakfast")
            results.add(v["video_id"] if v else None)

        assert len(results) == 1, f"ordering changed the winner: {results}"
        assert results == {"odtzzfLrsHc"}, results

    def test_egg_bhurji_never_flip_flops(self, offline):
        """The reported symptom: a video on one run, nothing on the next."""
        offline["pool"] = EGG_POOL
        n = len(EGG_POOL)

        results = set()
        for order in itertools.permutations(range(n)):
            offline["order"] = list(order)
            v = mrs.find_meal_video("Egg Bhurji", meal_type="Breakfast")
            results.add(v["video_id"] if v else None)

        assert results == {"bFKar_VIxts"}, (
            f"Egg Bhurji resolved differently depending on order: {results}")

    def test_the_winner_obeys_every_rule(self, offline):
        offline["pool"] = PBBS_POOL
        offline["order"] = None
        v = mrs.find_meal_video("Peanut Butter Banana Shake", meal_type="Breakfast")

        assert v is not None
        assert 20 <= v["duration_seconds"] <= 90
        assert v["verified"] is True
        assert v["match_type"] == "recipe_specific"
        assert "shorts" not in v["title"].lower()

    def test_an_empty_result_is_also_stable(self, offline):
        """A dish with nothing valid must return None every time, not
        sometimes."""
        offline["pool"] = [
            _v("kkk1111kkkk", "Dal Tadka #shorts", 30),
            _v("lll2222llll", "Dal Tadka", 12),
            _v("mmm3333mmmm", "10 Best Indian Recipes", 80),
        ]
        for _ in range(10):
            order = list(range(3))
            random.shuffle(order)
            offline["order"] = order
            assert mrs.find_meal_video("Dal Tadka", meal_type="Lunch") is None

    def test_ties_resolve_by_video_id_not_arrival(self, offline):
        """Three candidates identical on every quality signal."""
        offline["pool"] = [
            _v("zzz9999zzzz", "How To Make Dal Tadka Recipe", 60, "step by step"),
            _v("aaa0000aaaa", "How To Make Dal Tadka Recipe", 45, "step by step"),
            _v("mmm5555mmmm", "How To Make Dal Tadka Recipe", 88, "step by step"),
        ]
        for order in itertools.permutations(range(3)):
            offline["order"] = list(order)
            v = mrs.find_meal_video("Dal Tadka", meal_type="Lunch")
            assert v["video_id"] == "aaa0000aaaa", (
                "the lowest id must win a genuine tie, whatever the order")

    def test_duration_does_not_decide_a_tie(self, offline):
        """45s, 60s and 88s all tie on quality — the id decides, not the
        length. Duration is a hard gate and nothing more."""
        offline["pool"] = [
            _v("bbb0000bbbb", "How To Make Dal Tadka Recipe", 88, "step by step"),
            _v("ccc1111cccc", "How To Make Dal Tadka Recipe", 21, "step by step"),
        ]
        offline["order"] = None
        v = mrs.find_meal_video("Dal Tadka", meal_type="Lunch")
        assert v["video_id"] == "bbb0000bbbb"   # lowest id, which is the 88s one
        assert v["duration_seconds"] == 88


class TestQuotaExhaustionIsHandledCleanly:
    def test_an_unavailable_youtube_yields_no_video_not_an_error(self, monkeypatch):
        """Observed for real: after enough live runs the API answers 429.
        The right response is "Recipe video coming soon.", never a crash and
        never a stale substitute."""
        from services import youtube_recipe_service as yt

        def _boom(*_a, **_k):
            raise yt.YouTubeUnavailable("quota")

        monkeypatch.setattr(yt, "is_configured", lambda: True)
        monkeypatch.setattr(mrs, "_search_candidates", _boom)
        assert mrs.find_meal_video("Dal Tadka", meal_type="Lunch") is None
