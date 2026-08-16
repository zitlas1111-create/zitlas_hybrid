"""
ZITLAS — Expert rating / transformation review tests
(backend/tests/test_expert_ratings.py)

Exercises the REAL routes/expert_ratings.py against tests/fake_firestore.py's
in-process fake, same harness and posture as test_coaching.py.

The security properties are the point of this suite: a rating must be
impossible to forge, impossible to duplicate, impossible to attach to an
expert the athlete never worked with, and a non-consented transformation
photo must be impossible to obtain from the public endpoint.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.cloud import firestore

sys.path.insert(0, str(Path(__file__).parent.parent))

from routes import expert_ratings  # noqa: E402
from services import firestore_service  # noqa: E402
from tests.fake_firestore import FakeClient, fake_transactional  # noqa: E402

ATHLETE = "athlete_1"
EXPERT = "expert_1"
OTHER_EXPERT = "expert_2"
ENGAGEMENT = "req_abc"


@pytest.fixture
def fake_db(monkeypatch):
    client = FakeClient()
    monkeypatch.setattr(firestore_service, "get_client", lambda: client)
    monkeypatch.setattr(firestore, "transactional", fake_transactional)
    client.store[f"experts/{EXPERT}"] = {"name": "Coach Test"}
    return client


@pytest.fixture
def app():
    a = FastAPI()
    a.include_router(expert_ratings.router, prefix="/api/expert-ratings")
    return a


@pytest.fixture
def client(app):
    return TestClient(app)


def _as(app, uid):
    app.dependency_overrides[expert_ratings.verify_firebase_token] = lambda: {
        "uid": uid, "email": None, "name": "Test"
    }


def _relationship(fake_db, *, status="ended", athlete=ATHLETE, coach=EXPERT,
                  request_id=ENGAGEMENT):
    fake_db.store[f"personal_coaching/{athlete}"] = {
        "athleteId": athlete,
        "athleteName": "Test Athlete",
        "coachId": coach,
        "coachName": "Coach Test",
        "requestId": request_id,
        "planType": "COMPLETE",
        "planLabel": "Complete Coaching",
        "status": status,
        "endedAt": "2026-08-01T10:00:00Z",
    }


def _submit(client, **overrides):
    body = {
        "engagementId": ENGAGEMENT,
        "expertId": EXPERT,
        "rating": 5,
        **overrides,
    }
    return client.post("/api/expert-ratings/submit", json=body)


# ── 1-4. Pending detection: the popup's trigger ──────────────────────────

def test_pending_after_athlete_ended_coaching(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db, status="ended")
    body = client.get("/api/expert-ratings/pending").json()
    assert body["pending"] is True
    assert body["engagementId"] == ENGAGEMENT
    assert body["expertId"] == EXPERT
    assert body["expertName"] == "Coach Test"


def test_pending_after_expert_ended_coaching(fake_db, app, client):
    """The trigger is the engagement finishing — NOT which side finished
    it. An expert-ended relationship carries the same terminal status."""
    _as(app, ATHLETE)
    _relationship(fake_db, status="ended")
    fake_db.store[f"personal_coaching/{ATHLETE}"]["endedBy"] = "expert"
    assert client.get("/api/expert-ratings/pending").json()["pending"] is True


def test_pending_after_engagement_expired(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db, status="expired")
    assert client.get("/api/expert-ratings/pending").json()["pending"] is True


def test_not_pending_while_coaching_is_still_active(fake_db, app, client):
    """The popup must never appear during a live engagement."""
    _as(app, ATHLETE)
    _relationship(fake_db, status="active")
    assert client.get("/api/expert-ratings/pending").json()["pending"] is False


def test_not_pending_when_there_is_no_relationship_at_all(fake_db, app, client):
    _as(app, ATHLETE)
    assert client.get("/api/expert-ratings/pending").json()["pending"] is False


def test_not_pending_once_already_rated(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client).status_code == 200
    body = client.get("/api/expert-ratings/pending").json()
    assert body["pending"] is False
    assert body["alreadyRated"] is True


# ── 5-9. Field requirements ──────────────────────────────────────────────

@pytest.mark.parametrize("bad", [0, 6, -1, 99])
def test_rating_must_be_between_one_and_five(fake_db, app, client, bad):
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client, rating=bad).status_code == 422


def test_written_review_is_optional(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client, rating=4).status_code == 200
    assert fake_db.store[f"expert_ratings/{ENGAGEMENT}"]["reviewText"] is None


def test_both_photos_are_optional(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client).status_code == 200
    stored = fake_db.store[f"expert_ratings/{ENGAGEMENT}"]
    assert stored["beforePhotoUrl"] is None
    assert stored["afterPhotoUrl"] is None


def test_before_photo_alone_is_accepted(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client, beforePhotoUrl="https://cdn/x.jpg").status_code == 200
    stored = fake_db.store[f"expert_ratings/{ENGAGEMENT}"]
    assert stored["beforePhotoUrl"] == "https://cdn/x.jpg"
    assert stored["afterPhotoUrl"] is None


def test_photo_public_consent_defaults_to_false(fake_db, app, client):
    """Uploading a photo must NEVER imply consent to publish it."""
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client, beforePhotoUrl="https://cdn/x.jpg").status_code == 200
    assert fake_db.store[f"expert_ratings/{ENGAGEMENT}"]["photoPublic"] is False


# ── 10-12. Storage correctness ───────────────────────────────────────────

def test_review_is_stored_against_the_correct_expert_and_engagement(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, rating=4, reviewText="Very supportive.")
    stored = fake_db.store[f"expert_ratings/{ENGAGEMENT}"]
    assert stored["expertId"] == EXPERT
    assert stored["engagementId"] == ENGAGEMENT
    assert stored["athleteId"] == ATHLETE
    assert stored["rating"] == 4
    assert stored["reviewText"] == "Very supportive."
    assert stored["status"] == "published"


def test_verified_coaching_flag_is_set_by_the_backend(fake_db, app, client):
    """Never client-supplied — it is true precisely because this endpoint
    just proved a real completed engagement."""
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client)
    assert fake_db.store[f"expert_ratings/{ENGAGEMENT}"]["verifiedCoaching"] is True


def test_review_text_is_length_capped(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, reviewText="x" * 5000)
    assert len(fake_db.store[f"expert_ratings/{ENGAGEMENT}"]["reviewText"]) == 1000


# ── 13. Duplicates ───────────────────────────────────────────────────────

def test_duplicate_review_for_the_same_engagement_is_rejected(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client, rating=5).status_code == 200
    second = _submit(client, rating=1)
    assert second.status_code == 409
    # The first rating stands — a rejected duplicate must not overwrite it.
    assert fake_db.store[f"expert_ratings/{ENGAGEMENT}"]["rating"] == 5


def test_a_rejected_duplicate_does_not_move_the_average(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, rating=5)
    before = dict(fake_db.store[f"experts/{EXPERT}"])
    _submit(client, rating=1)
    assert fake_db.store[f"experts/{EXPERT}"]["ratingCount"] == before["ratingCount"]
    assert fake_db.store[f"experts/{EXPERT}"]["rating"] == before["rating"]


# ── 14-15. Aggregation — exact maths, never an arbitrary nudge ───────────

def test_first_ever_review_sets_the_average_to_that_rating(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, rating=4)
    expert = fake_db.store[f"experts/{EXPERT}"]
    assert expert["ratingCount"] == 1
    assert expert["reviewCount"] == 1
    assert expert["rating"] == 4.0


def test_average_recalculates_from_an_existing_aggregate(fake_db, app, client):
    """The spec's worked example: 4.5 average over 100 reviews, one new
    5-star review -> 101 reviews and a mathematically exact new average.

        (4.5 * 100 + 5) / 101 = 455 / 101 = 4.5049... -> 4.5
    """
    fake_db.store[f"experts/{EXPERT}"] = {"name": "Coach Test", "rating": 4.5, "reviewCount": 100}
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, rating=5)
    expert = fake_db.store[f"experts/{EXPERT}"]
    assert expert["reviewCount"] == 101
    assert expert["ratingSum"] == pytest.approx(455.0)
    assert expert["rating"] == pytest.approx(round(455 / 101, 1))


def test_average_is_exact_across_several_reviews(fake_db, app, client):
    """5 + 4 + 5 + 5 + 3 = 22, 22 / 5 = 4.4 — the spec's own example."""
    for i, stars in enumerate([5, 4, 5, 5, 3]):
        athlete = f"athlete_{i}"
        _as(app, athlete)
        _relationship(fake_db, athlete=athlete, request_id=f"req_{i}")
        r = client.post("/api/expert-ratings/submit", json={
            "engagementId": f"req_{i}", "expertId": EXPERT, "rating": stars,
        })
        assert r.status_code == 200
    expert = fake_db.store[f"experts/{EXPERT}"]
    assert expert["ratingCount"] == 5
    assert expert["ratingSum"] == pytest.approx(22.0)
    assert expert["rating"] == pytest.approx(4.4)


def test_review_count_increments_by_exactly_one(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client)
    assert fake_db.store[f"experts/{EXPERT}"]["reviewCount"] == 1
    _as(app, "athlete_2")
    _relationship(fake_db, athlete="athlete_2", request_id="req_2")
    client.post("/api/expert-ratings/submit",
                json={"engagementId": "req_2", "expertId": EXPERT, "rating": 3})
    assert fake_db.store[f"experts/{EXPERT}"]["reviewCount"] == 2


# ── 17-18. Photo consent boundary ────────────────────────────────────────

def test_public_endpoint_returns_photos_only_with_explicit_consent(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, beforePhotoUrl="https://cdn/b.jpg",
            afterPhotoUrl="https://cdn/a.jpg", photoPublic=True)
    review = client.get(f"/api/expert-ratings/expert/{EXPERT}").json()["reviews"][0]
    assert review["beforePhotoUrl"] == "https://cdn/b.jpg"
    assert review["afterPhotoUrl"] == "https://cdn/a.jpg"


def test_private_photos_are_absent_from_the_public_endpoint(fake_db, app, client):
    """Stored, but NEVER returned — the URL must not leave the backend at
    all, rather than being hidden by a client that could choose otherwise."""
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, beforePhotoUrl="https://cdn/private_b.jpg",
            afterPhotoUrl="https://cdn/private_a.jpg", photoPublic=False)
    # The photos ARE retained on the record.
    stored = fake_db.store[f"expert_ratings/{ENGAGEMENT}"]
    assert stored["beforePhotoUrl"] == "https://cdn/private_b.jpg"
    # ...and are entirely absent from the public response.
    payload = client.get(f"/api/expert-ratings/expert/{EXPERT}").text
    assert "private_b.jpg" not in payload
    assert "private_a.jpg" not in payload
    review = client.get(f"/api/expert-ratings/expert/{EXPERT}").json()["reviews"][0]
    assert review["beforePhotoUrl"] is None
    assert review["afterPhotoUrl"] is None


def test_public_endpoint_never_exposes_the_athletes_identity(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client)
    payload = client.get(f"/api/expert-ratings/expert/{EXPERT}").text
    assert ATHLETE not in payload
    assert "Test Athlete" not in payload
    review = client.get(f"/api/expert-ratings/expert/{EXPERT}").json()["reviews"][0]
    assert review["athleteName"] == "Verified ZITLAS Client"


# ── 19. Notification ─────────────────────────────────────────────────────

def test_expert_is_notified_of_a_new_review(fake_db, app, client, monkeypatch):
    sent = []
    monkeypatch.setattr(expert_ratings, "notify",
                        lambda db, uid, title, msg, **kw: sent.append((uid, title, kw)))
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, rating=5)
    assert len(sent) == 1
    uid, title, kw = sent[0]
    assert uid == EXPERT
    assert title == "New review received"
    assert kw["type"] == "expert_rating_received"


def test_a_failing_notification_never_fails_the_rating(fake_db, app, client, monkeypatch):
    def _boom(*a, **k):
        raise RuntimeError("fcm down")
    monkeypatch.setattr(expert_ratings, "notify", _boom)
    _as(app, ATHLETE)
    _relationship(fake_db)
    assert _submit(client).status_code == 200
    assert f"expert_ratings/{ENGAGEMENT}" in fake_db.store


# ── 20-23. Security ──────────────────────────────────────────────────────

def test_cannot_rate_an_engagement_that_is_still_active(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db, status="active")
    r = _submit(client)
    assert r.status_code == 400
    assert r.json()["detail"] == "no_rateable_engagement"


def test_cannot_rate_with_no_engagement_at_all(fake_db, app, client):
    _as(app, ATHLETE)
    assert _submit(client).status_code == 400


def test_cannot_attach_a_review_to_a_different_expert(fake_db, app, client):
    """The athlete coached with EXPERT; a crafted request naming a
    different expert must be refused, not silently redirected."""
    _as(app, ATHLETE)
    _relationship(fake_db, coach=EXPERT)
    r = _submit(client, expertId=OTHER_EXPERT)
    assert r.status_code == 403
    assert r.json()["detail"] == "expert_mismatch"
    assert f"expert_ratings/{ENGAGEMENT}" not in fake_db.store
    assert "ratingCount" not in fake_db.store.get(f"experts/{OTHER_EXPERT}", {})


def test_cannot_rate_an_engagement_the_athlete_was_not_part_of(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db, request_id="req_mine")
    r = _submit(client, engagementId="req_someone_elses")
    assert r.status_code == 403
    assert r.json()["detail"] == "engagement_mismatch"


def test_another_athlete_cannot_rate_on_someone_elses_behalf(fake_db, app, client):
    """`_resolve_engagement` reads the CALLER's own relationship doc, so a
    second athlete with no relationship gets nothing to rate — the
    engagement id alone buys them no access."""
    _relationship(fake_db, athlete=ATHLETE)
    _as(app, "intruder_9")
    assert _submit(client).status_code == 400


def test_unauthenticated_submission_is_rejected(fake_db, app):
    """No dependency override — the real `verify_firebase_token` runs and
    rejects a request with no bearer token."""
    unauth = TestClient(app)
    r = unauth.post("/api/expert-ratings/submit", json={
        "engagementId": ENGAGEMENT, "expertId": EXPERT, "rating": 5,
    })
    assert r.status_code == 401


def test_unauthenticated_pending_check_is_rejected(fake_db, app):
    assert TestClient(app).get("/api/expert-ratings/pending").status_code == 401


def test_relationship_without_a_request_id_is_not_rateable(fake_db, app, client):
    """A pre-`requestId` relationship cannot be uniquely identified as an
    engagement, so it is refused rather than given a synthetic id that
    could later collide with a real one."""
    _as(app, ATHLETE)
    _relationship(fake_db, request_id=None)
    fake_db.store[f"personal_coaching/{ATHLETE}"].pop("requestId")
    assert client.get("/api/expert-ratings/pending").json()["pending"] is False
    assert _submit(client).status_code == 400


# ── 20. Dismissal creates nothing ────────────────────────────────────────

def test_dismissing_the_prompt_creates_no_review(fake_db, app, client):
    """Checking `pending` is a READ. Nothing about asking, or declining to
    answer, may write a rating — the engagement stays pending."""
    _as(app, ATHLETE)
    _relationship(fake_db)
    client.get("/api/expert-ratings/pending")
    client.get("/api/expert-ratings/pending")
    assert f"expert_ratings/{ENGAGEMENT}" not in fake_db.store
    assert "ratingCount" not in fake_db.store[f"experts/{EXPERT}"]
    # ...and it is still offered afterwards.
    assert client.get("/api/expert-ratings/pending").json()["pending"] is True


# ── 21. Submitting later still works ─────────────────────────────────────

def test_a_review_can_be_submitted_long_after_the_engagement_ended(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    for _ in range(3):
        assert client.get("/api/expert-ratings/pending").json()["pending"] is True
    assert _submit(client, rating=5).status_code == 200


# ── Public listing shape ─────────────────────────────────────────────────

def test_public_listing_only_returns_this_experts_reviews(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client)
    _as(app, "athlete_2")
    _relationship(fake_db, athlete="athlete_2", coach=OTHER_EXPERT, request_id="req_2")
    client.post("/api/expert-ratings/submit",
                json={"engagementId": "req_2", "expertId": OTHER_EXPERT, "rating": 2})
    reviews = client.get(f"/api/expert-ratings/expert/{EXPERT}").json()["reviews"]
    assert len(reviews) == 1
    assert reviews[0]["reviewId"] == ENGAGEMENT


def test_public_listing_is_empty_for_an_expert_with_no_reviews(fake_db, app, client):
    body = client.get(f"/api/expert-ratings/expert/{OTHER_EXPERT}").json()
    assert body["count"] == 0
    assert body["reviews"] == []


def test_an_empty_review_text_does_not_break_the_listing(fake_db, app, client):
    _as(app, ATHLETE)
    _relationship(fake_db)
    _submit(client, reviewText="   ")
    review = client.get(f"/api/expert-ratings/expert/{EXPERT}").json()["reviews"][0]
    assert review["reviewText"] is None
    assert review["rating"] == 5
