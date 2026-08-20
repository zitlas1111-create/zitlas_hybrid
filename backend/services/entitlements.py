"""
ZITLAS — Subscription entitlements and weekly usage (backend/services/entitlements.py)

THE CANONICAL, SERVER-SIDE source of truth for what a subscription tier may do
and how much of it has been used this week.

WHY THIS EXISTS
---------------
Before this, every limit in ZITLAS was enforced ONLY in the browser:

    frontend/website/pages/profile/membership/membership.js
        LIMITS = { basic:   { goalResets: 3, mealSwaps: 5  },
                   premium: { goalResets: 5, mealSwaps: 25 } }
        counters in localStorage: zitlas_weekly_goal_resets,
                                  zitlas_weekly_meal_swaps

That is a display convention, not a limit. The counters live on the user's own
device, keyed to a week derived from the DEVICE clock, and the endpoints that
actually do the work — POST /api/diet/swap (Flutter), POST /api/ai/swap-meal
(website), and the recipe routes — never checked anything at all. Clearing
localStorage, changing the device date, or calling the endpoint directly all
bypassed every limit completely, and Flutter never had a counter in the first
place.

So this module is not a second entitlement system replacing a first one; it is
the first server-side one. `membership.js` keeps its display role and reads its
numbers from here (see GET /api/entitlements) instead of hardcoding them.

TIER SOURCE OF TRUTH
--------------------
`users/{uid}.membership` — exactly the document `payment-service.js`'s
`_membershipIsPremium()` already treats as authoritative, and which
`firestore.rules` already forbids the client from writing (see the
"athlete CANNOT self-activate premium membership" rule). The tier is NEVER read
from a request body, a header, or localStorage.

Because the tier is derived from that document on every call, an EXISTING
premium subscriber picks up changed limits immediately — no repurchase, no
migration, no per-user backfill.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException

from services import firestore_service

# ── Tiers ────────────────────────────────────────────────────────────────────

TIER_FREE = "free"
TIER_PREMIUM = "premium"

#: Sentinel for "no numeric quota". Deliberately not a very large number: a big
#: int would still be a quota, and a future refactor could compare against it
#: and reintroduce a ceiling. `None` cannot be compared by accident.
UNLIMITED = None

#: Feature keys. Constants so a typo is an ImportError rather than a silently
#: unlimited feature.
GOAL_RESET = "goal_reset"
MEAL_SWAP = "meal_swap"
RECIPE = "recipe"

_DEFAULT_LIMITS: dict[str, dict[str, int | None]] = {
    TIER_FREE: {
        GOAL_RESET: 2,
        MEAL_SWAP: 70,
        RECIPE: 7,
    },
    TIER_PREMIUM: {
        GOAL_RESET: 5,
        MEAL_SWAP: UNLIMITED,
        RECIPE: 27,
    },
}


def _env_int(name: str, default: int | None) -> int | None:
    """An env override, or the default. Empty/invalid values keep the default
    rather than silently becoming zero — a zero limit would lock everybody out
    of a feature, which is a worse failure than ignoring a typo."""
    raw = (os.getenv(name) or "").strip()
    if not raw:
        return default
    if raw.lower() in ("unlimited", "none", "-1"):
        return UNLIMITED
    try:
        value = int(raw)
    except ValueError:
        print(f"[ENTITLEMENTS] ignoring non-numeric {name}={raw!r}")
        return default
    return value if value >= 0 else UNLIMITED


def limits_for(tier: str) -> dict[str, int | None]:
    """The limit map for a tier, with env overrides applied.

    Overridable so a limit can be tuned on Railway without a deploy, and so
    tests can pin values. Never read from, or influenced by, the client.
    """
    tier = TIER_PREMIUM if tier == TIER_PREMIUM else TIER_FREE
    base = _DEFAULT_LIMITS[tier]
    prefix = "ZITLAS_LIMIT_" + tier.upper() + "_"
    return {
        feature: _env_int(prefix + feature.upper(), base[feature])
        for feature in base
    }


# ── Tier resolution ──────────────────────────────────────────────────────────

def _membership_is_premium(membership: dict | None) -> bool:
    """Mirror of `payment-service.js`'s `_membershipIsPremium()`.

    Kept deliberately identical so the server and the UI can never disagree
    about who is premium: plan must be 'premium', `active` must not be false,
    and an expiry in the past demotes to free regardless of the flag.
    """
    if not isinstance(membership, dict):
        return False
    if membership.get("plan") != "premium":
        return False
    if membership.get("active") is False:
        return False
    expiry = membership.get("premium_expiry_date")
    if expiry:
        try:
            when = datetime.fromisoformat(str(expiry).replace("Z", "+00:00"))
            if when.tzinfo is None:
                when = when.replace(tzinfo=timezone.utc)
            if when <= datetime.now(timezone.utc):
                return False
        except (ValueError, TypeError):
            # An unparseable expiry must not silently grant premium forever.
            print(f"[ENTITLEMENTS] unparseable premium_expiry_date={expiry!r} — treating as free")
            return False
    return True


def tier_for_uid(uid: str) -> str:
    """The caller's tier, read from `users/{uid}.membership`.

    Fails CLOSED to free: if Firestore is unreachable the user keeps the free
    allowance rather than being handed unlimited access. A free user briefly
    mis-scoped is recoverable; unmetered premium for everyone is not.
    """
    db = firestore_service.get_client()
    if db is None or not uid:
        return TIER_FREE
    try:
        snap = db.collection("users").document(uid).get()
        data = snap.to_dict() if snap.exists else None
        return TIER_PREMIUM if _membership_is_premium((data or {}).get("membership")) else TIER_FREE
    except Exception as e:  # noqa: BLE001 - see docstring
        print(f"[ENTITLEMENTS] tier lookup failed for {uid}: {type(e).__name__}: {e}")
        return TIER_FREE


# ── Weekly window ────────────────────────────────────────────────────────────

def week_key(now: datetime | None = None) -> str:
    """ISO year-week, e.g. "2026-W34", from the SERVER clock in UTC.

    Server-side on purpose. The website's counter derived its week from
    `new Date()` on the user's device, so moving the phone's clock forward
    started a fresh allowance. This cannot be influenced by the caller.

    ISO week (not a rolling 7-day window) so the boundary is identical for
    every user and every client, and "resets next week" means one predictable
    moment rather than a per-user anniversary.
    """
    moment = now or datetime.now(timezone.utc)
    iso_year, iso_week, _ = moment.astimezone(timezone.utc).isocalendar()
    return f"{iso_year}-W{iso_week:02d}"


def next_reset(now: datetime | None = None) -> str:
    """ISO timestamp of the next weekly boundary — for "resets next week" UI."""
    moment = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    days_until_monday = (7 - moment.isoweekday()) + 1
    monday = (moment + timedelta(days=days_until_monday)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return monday.isoformat()


# ── Usage ────────────────────────────────────────────────────────────────────

#: `usage_weekly/{uid}_{weekKey}` — one document per user per ISO week, holding
#: a counter per feature. A flat collection keyed by uid+week (rather than a
#: subcollection) keeps a whole week's usage in ONE read and lets an old week
#: expire without touching the user document.
USAGE_COLLECTION = "usage_weekly"


def _usage_doc_id(uid: str, key: str) -> str:
    return f"{uid}_{key}"


def read_usage(uid: str, *, now: datetime | None = None) -> dict[str, int]:
    """This week's counters. Missing document or unreadable -> all zero.

    Failing to ZERO here is deliberate and the opposite of `tier_for_uid`'s
    fail-closed: an infrastructure blip must not tell a paying user they have
    exhausted an allowance they have not used.
    """
    db = firestore_service.get_client()
    if db is None or not uid:
        return {}
    try:
        snap = db.collection(USAGE_COLLECTION).document(_usage_doc_id(uid, week_key(now))).get()
        if not snap.exists:
            return {}
        data = snap.to_dict() or {}
        return {k: int(v) for k, v in data.items() if isinstance(v, (int, float))}
    except Exception as e:  # noqa: BLE001
        print(f"[ENTITLEMENTS] usage read failed for {uid}: {type(e).__name__}: {e}")
        return {}


@dataclass(frozen=True)
class Allowance:
    """What the caller may do RIGHT NOW for one feature."""

    tier: str
    feature: str
    limit: int | None       # None == unlimited
    used: int
    week: str
    resets_at: str

    @property
    def unlimited(self) -> bool:
        return self.limit is None

    @property
    def allowed(self) -> bool:
        return self.unlimited or self.used < self.limit

    @property
    def remaining(self) -> int | None:
        return None if self.unlimited else max(0, self.limit - self.used)

    def as_dict(self) -> dict:
        return {
            "tier": self.tier,
            "feature": self.feature,
            "limit": "unlimited" if self.unlimited else self.limit,
            "used": self.used,
            "remaining": "unlimited" if self.unlimited else self.remaining,
            "allowed": self.allowed,
            "week": self.week,
            "resetsAt": self.resets_at,
        }


def check(uid: str, feature: str, *, now: datetime | None = None,
          tier: str | None = None) -> Allowance:
    """Whether `uid` may use `feature` this week. Reads only — never records."""
    resolved = tier or tier_for_uid(uid)
    return Allowance(
        tier=resolved,
        feature=feature,
        limit=limits_for(resolved).get(feature),
        used=int(read_usage(uid, now=now).get(feature, 0)),
        week=week_key(now),
        resets_at=next_reset(now),
    )


def require(uid: str, feature: str, *, now: datetime | None = None,
            tier: str | None = None) -> Allowance:
    """`check`, but raises 429 when the allowance is spent.

    429 (not 403): the caller is authorised, they have simply used their quota
    for now, and it will succeed again after the reset. The detail carries the
    tier so the client can show an upgrade prompt to a free user and a plain
    "resets next week" to a premium one — never an upgrade prompt to somebody
    who already pays.
    """
    allowance = check(uid, feature, now=now, tier=tier)
    if allowance.allowed:
        return allowance
    print(f"[ENTITLEMENTS] {feature} limit reached uid={uid} tier={allowance.tier} "
          f"used={allowance.used}/{allowance.limit} week={allowance.week}")
    raise HTTPException(
        status_code=429,
        detail={
            "error": "limit_reached",
            **allowance.as_dict(),
        },
    )


def record(uid: str, feature: str, *, now: datetime | None = None, amount: int = 1) -> None:
    """Consumes one unit of `feature`.

    MUST be called only AFTER the operation succeeded — a failed swap or a
    recipe request that errored must not cost the user part of their week.
    Every call site therefore records last, not first.

    Uses an atomic Increment so two concurrent requests cannot read-modify-write
    over each other and undercount. Never raises: losing a count is a metering
    inaccuracy, while failing an operation the user already received would be a
    visible bug.
    """
    db = firestore_service.get_client()
    if db is None or not uid:
        return
    try:
        from google.cloud import firestore as gcf

        key = week_key(now)
        db.collection(USAGE_COLLECTION).document(_usage_doc_id(uid, key)).set(
            {
                feature: gcf.Increment(amount),
                "uid": uid,
                "week": key,
                "updatedAt": datetime.now(timezone.utc).isoformat(),
            },
            merge=True,
        )
    except Exception as e:  # noqa: BLE001 - see docstring
        print(f"[ENTITLEMENTS] usage record failed uid={uid} {feature}: {type(e).__name__}: {e}")


def snapshot(uid: str, *, now: datetime | None = None) -> dict:
    """Every feature's allowance for one user — backs GET /api/entitlements.

    The UI renders from THIS rather than its own copy of the numbers, so the
    comparison table and the enforcement can never drift apart.
    """
    resolved = tier_for_uid(uid)
    used = read_usage(uid, now=now)
    tier_limits = limits_for(resolved)
    return {
        "tier": resolved,
        "week": week_key(now),
        "resetsAt": next_reset(now),
        "features": {
            feature: Allowance(
                tier=resolved,
                feature=feature,
                limit=tier_limits[feature],
                used=int(used.get(feature, 0)),
                week=week_key(now),
                resets_at=next_reset(now),
            ).as_dict()
            for feature in tier_limits
        },
        # Both tiers' limits, so the upgrade comparison is server-driven too.
        "plans": {
            TIER_FREE: {
                k: ("unlimited" if v is None else v) for k, v in limits_for(TIER_FREE).items()
            },
            TIER_PREMIUM: {
                k: ("unlimited" if v is None else v) for k, v in limits_for(TIER_PREMIUM).items()
            },
        },
    }
