"""
ZITLAS — Personal Coaching Programs: catalog, price rules, request shape
(backend/services/coaching_programs.py)

    expert sets prices -> athlete requests a program -> expert accepts
        -> payment_required -> athlete pays from the wallet -> program active

Phase 2 added pricing and requests; Phase 3 adds the wallet payment and the
activation (routes/coaching_programs.py). Money moves ONLY in that one
transaction, never at request or acceptance time. When the program's end date
passes, the existing relationship expiry sweep (services/coaching_sweep.py)
marks it completed; nothing is deleted.

The existing Personal Coaching escrow (routes/coaching.py +
personal_coach_requests) is a different system and is deliberately NOT reused:
it reserves money at request time and charges when the EXPERT accepts.

Pure functions only — no Firestore, no FastAPI — so every rule here is unit
testable and the routes stay thin.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

# ── The catalog ──────────────────────────────────────────────────────────────
#
# Program ids are the app's own (mobile/lib/features/coaching_programs/
# coaching_programs.dart — kCoachingPrograms). The duration is decided HERE,
# never by the client.
#
# `programType` is the coaching scope in personal_coaching's existing
# `planType` vocabulary (diet | training | complete). Every program is 1:1
# nutrition coaching today, so all three are "diet".
PROGRAMS: dict[str, dict[str, Any]] = {
    "10_day": {"title": "10-Day Program", "durationDays": 10, "programType": "diet"},
    "1_month": {"title": "1-Month Program", "durationDays": 30, "programType": "diet"},
    "3_month": {"title": "3-Month Program", "durationDays": 90, "programType": "diet"},
}
PROGRAM_IDS: tuple[str, ...] = tuple(PROGRAMS)

CURRENCY = "INR"

# ── Price limits (integer paise) ─────────────────────────────────────────────
#
# MIN: ₹1 — Razorpay's own minimum order amount
#      (services/razorpay_service._MIN_AMOUNT_PAISE). A program cheaper than
#      the smallest payment the app can take could never be paid for.
# MAX: ₹50,000 — the app's single-payment ceiling (Add Funds: kMaxTopUp in
#      the app, max="50000" on the website's wallet panel).
MIN_PRICE_PAISE = 100
MAX_PRICE_PAISE = 5_000_000

# ── Request lifecycle (Phase 2) ──────────────────────────────────────────────
STATUS_PENDING = "pending_expert_acceptance"
STATUS_ACCEPTED = "accepted"
STATUS_DECLINED = "declined"
PAYMENT_UNPAID = "unpaid"
PAYMENT_REQUIRED = "payment_required"
PAYMENT_PAID = "paid"
STATUS_ACTIVE = "active"
#: A paid program whose end date has passed (set by the expiry sweep).
STATUS_COMPLETED = "completed"

#: Payment is possible ONLY from an accepted request whose payment is still
#: outstanding ("unpaid" is what a Phase 2 acceptance recorded).
PAYABLE_PAYMENT_STATUSES: frozenset[str] = frozenset({PAYMENT_UNPAID, PAYMENT_REQUIRED})

#: `serviceType` on the program purchase's wallet_transactions row.
SERVICE_TYPE = "personal_coaching_program"


def ledger_id(request_id: str) -> str:
    """wallet_transactions/{id} for paying `request_id`.

    Deterministic on purpose — the server-generated request id IS the
    idempotency key. A double tap, a retry after a timeout, a second device or
    a replayed call all land on the SAME ledger row, so a request can be paid
    at most once; a new purchase is always a new request with a new id.
    """
    return f"prog_{request_id}"


def program_end(start: datetime, duration_days: int) -> datetime:
    """startedAt + durationDays, in exact days — never calendar months."""
    return start + timedelta(days=duration_days)


def rupees_to_paise(rupees: Any) -> int:
    """The wallet's float rupees -> integer paise — the same conversion as
    routes/payment.py's _paise(): every affordability decision is an integer
    comparison, never a float one."""
    return int(round(float(rupees or 0) * 100))


#: A request in one of these still occupies the athlete+expert slot: asking
#: again returns it instead of creating another. An accepted request is still
#: open — it is waiting for the athlete's payment.
OPEN_STATUSES: frozenset[str] = frozenset({STATUS_PENDING, STATUS_ACCEPTED})

REQUESTS_COLLECTION = "coaching_program_requests"
PRICING_FIELD = "programPricing"


class PriceError(ValueError):
    """A price the server refuses. `code` is the machine-readable reason."""

    def __init__(self, code: str, program_id: str | None = None):
        super().__init__(code)
        self.code = code
        self.program_id = program_id


def validate_price_paise(value: Any) -> int:
    """The one gate every program price passes, on write AND on read.

    Only a real integer counts. `bool` is refused even though Python calls it
    an int; floats are refused even when whole (499.0) because JSON floats are
    how NaN, Infinity and 1e309 arrive; strings are refused because "49900" is
    exactly the kind of loosely-typed value a tampered client sends.
    """
    if type(value) is not int:  # noqa: E721 — bool must NOT pass
        raise PriceError("price_not_integer_paise")
    if value <= 0:
        raise PriceError("price_must_be_positive")
    if value < MIN_PRICE_PAISE:
        raise PriceError("price_below_minimum")
    if value > MAX_PRICE_PAISE:
        raise PriceError("price_above_maximum")
    return value


def stored_price(expert_data: dict | None, program_id: str) -> int | None:
    """The price an athlete may be quoted for `program_id`, or None.

    Re-validates what is stored rather than trusting it: a value that got
    into Firestore any other way (a direct write, an old client, a manual
    edit) is "not offered" — never ₹0, never free.
    """
    if program_id not in PROGRAMS:
        return None
    pricing = (expert_data or {}).get(PRICING_FIELD)
    if not isinstance(pricing, dict):
        return None
    entry = pricing.get(program_id)
    if not isinstance(entry, dict):
        return None
    if entry.get("currency", CURRENCY) != CURRENCY:
        return None
    try:
        return validate_price_paise(entry.get("pricePaise"))
    except PriceError:
        return None


def parse_pricing_update(payload: Any) -> dict[str, int | None]:
    """`{"prices": {"10_day": 49900, "1_month": null}}` -> validated changes.

    A number sets that program's price; null stops offering it; a program
    left out is unchanged. Any unknown program or bad value rejects the WHOLE
    update — a half-applied price list is worse than none.
    """
    if not isinstance(payload, dict) or not isinstance(payload.get("prices"), dict):
        raise PriceError("prices_required")
    prices = payload["prices"]
    if not prices:
        raise PriceError("prices_required")
    out: dict[str, int | None] = {}
    for program_id, value in prices.items():
        if program_id not in PROGRAMS:
            raise PriceError("unknown_program", program_id)
        if value is None:
            out[program_id] = None
            continue
        try:
            out[program_id] = validate_price_paise(value)
        except PriceError as e:
            raise PriceError(e.code, program_id) from None
    return out


def merge_pricing(current: Any, changes: dict[str, int | None], now_iso: str) -> dict:
    """The complete `programPricing` map after applying `changes`.

    An unchanged price keeps its original `updatedAt`, so the timestamp means
    "when this price last changed", not "when Save was last pressed". Stored
    entries that no longer validate are dropped rather than carried forward.
    """
    current = current if isinstance(current, dict) else {}
    merged: dict[str, dict] = {}
    for program_id in PROGRAM_IDS:
        existing = current.get(program_id) if isinstance(current.get(program_id), dict) else None
        existing_price = stored_price({PRICING_FIELD: current}, program_id)
        if program_id in changes:
            new_price = changes[program_id]
            if new_price is None:
                continue
            if existing_price == new_price and existing and existing.get("updatedAt"):
                merged[program_id] = {"pricePaise": new_price, "currency": CURRENCY,
                                      "updatedAt": existing["updatedAt"]}
            else:
                merged[program_id] = {"pricePaise": new_price, "currency": CURRENCY,
                                      "updatedAt": now_iso}
        elif existing_price is not None:
            merged[program_id] = {"pricePaise": existing_price, "currency": CURRENCY,
                                  "updatedAt": existing.get("updatedAt")}
    return merged


def pricing_view(expert_data: dict | None) -> list[dict]:
    """Every program with its current, validated price (None = not offered)."""
    pricing = (expert_data or {}).get(PRICING_FIELD)
    pricing = pricing if isinstance(pricing, dict) else {}
    out = []
    for program_id, program in PROGRAMS.items():
        price = stored_price(expert_data, program_id)
        entry = pricing.get(program_id) if isinstance(pricing.get(program_id), dict) else {}
        out.append({
            "programId": program_id,
            "title": program["title"],
            "durationDays": program["durationDays"],
            "programType": program["programType"],
            "pricePaise": price,
            "available": price is not None,
            "updatedAt": entry.get("updatedAt") if price is not None else None,
        })
    return out


#: The fields a client ever sees of a request — the stored doc is the source.
PUBLIC_REQUEST_FIELDS = (
    "requestId", "athleteId", "athleteName", "expertId", "expertName",
    "programId", "programTitle", "programType", "durationDays",
    "pricePaise", "currency", "status", "paymentStatus", "expertAccepted",
    "requestedAt", "updatedAt", "acceptedAt", "declinedAt",
    "paidAt", "activatedAt", "startedAt", "endsAt", "amountPaidPaise",
)


def public_request(data: dict | None) -> dict:
    data = data or {}
    return {k: data.get(k) for k in PUBLIC_REQUEST_FIELDS}


def is_open(data: dict | None) -> bool:
    return (data or {}).get("status") in OPEN_STATUSES
