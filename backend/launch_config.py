"""
ZITLAS — LAUNCH CONFIGURATION (the one place the launch business model lives)
============================================================================

AT LAUNCH, PREMIUM IS THE ONLY PAID FEATURE.

    | Feature            | Launch State | Payment       |
    |--------------------|--------------|---------------|
    | Premium            | ACTIVE       | Razorpay ONLY |
    | Personal Coaching  | ACTIVE       | FREE          |
    | Expert Verification| FROZEN       | NO PAYMENT    |
    | Wallet             | FROZEN       | DISABLED      |
    | Expert Payouts     | FROZEN       | DISABLED      |

WHY THIS FILE EXISTS. The payment engine — Razorpay orders, HMAC verification,
escrow reservations, the wallet ledger, idempotency, the platform-fee split —
is real, tested infrastructure worth keeping for future monetization. None of
it is being deleted. What changes at launch is POLICY: which of those paths is
allowed to run. Policy belongs in one file that the server reads, not scattered
through route handlers where "is coaching free?" is answered differently in
five places.

RELATIONSHIP TO trial_config.py. That flag answers a narrower, temporary
question ("is the 10-day client trial on?"). This file answers the permanent
launch one. Coaching is free here because the launch model says so, NOT
because a trial happens to be running — so turning the trial off cannot
accidentally start charging for coaching.

THE CLIENT IS NEVER TRUSTED. Every guard below runs on the server, inside the
request, before any money moves. `GET /api/system/launch-config` serves the
same matrix to the website and the app so their UI matches, but that response
is for DISPLAY. A client that ignores it, or a curl that never reads it, still
hits these guards.

TO MONETIZE LATER: flip the relevant `payment_required` / `enabled` below (or
set the matching environment variable) and the existing engine runs again with
no other change.
"""

from __future__ import annotations

import os

from fastapi import HTTPException


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# ── The matrix ───────────────────────────────────────────────────────────────

#: Premium subscription — the ONLY paid feature at launch.
PREMIUM_ENABLED: bool = _env_bool("PREMIUM_ENABLED", True)
PREMIUM_PAYMENT_REQUIRED: bool = _env_bool("PREMIUM_PAYMENT_REQUIRED", True)
PREMIUM_PROVIDER: str = os.getenv("PREMIUM_PROVIDER", "razorpay")

#: Personal Coaching — fully available, and free. `price = 0` is the launch
#: price, not a discount applied at checkout: there is no checkout.
PERSONAL_COACHING_ENABLED: bool = _env_bool("PERSONAL_COACHING_ENABLED", True)
PERSONAL_COACHING_PAYMENT_REQUIRED: bool = _env_bool(
    "PERSONAL_COACHING_PAYMENT_REQUIRED", False)
PERSONAL_COACHING_PRICE: int = int(os.getenv("PERSONAL_COACHING_PRICE", "0"))

#: Expert services (plan reviews, expert chat) — free at launch, same rule.
EXPERT_SERVICES_PAYMENT_REQUIRED: bool = _env_bool(
    "EXPERT_SERVICES_PAYMENT_REQUIRED", False)

#: Expert verification/onboarding — frozen. The three approved experts stay
#: authorized; there is no public application, and no fee for becoming one.
EXPERT_VERIFICATION_ENABLED: bool = _env_bool("EXPERT_VERIFICATION_ENABLED", False)
EXPERT_VERIFICATION_PAYMENT_REQUIRED: bool = _env_bool(
    "EXPERT_VERIFICATION_PAYMENT_REQUIRED", False)

#: Wallet — frozen. Data preserved, operations refused.
WALLET_ENABLED: bool = _env_bool("WALLET_ENABLED", False)

#: Expert payouts / withdrawals — frozen. The 80/20 split constant stays in
#: services/coaching_service.py for V2; nothing executes it at launch.
EXPERT_PAYOUTS_ENABLED: bool = _env_bool("EXPERT_PAYOUTS_ENABLED", False)


# ── Messages the clients render ──────────────────────────────────────────────

WALLET_FROZEN_MESSAGE = (
    "Wallet is temporarily unavailable. It's coming in a future update — "
    "your balance and transaction history are safe."
)
COACHING_FREE_MESSAGE = "Personal Coaching is free at launch."


def as_dict() -> dict:
    """The matrix, for `GET /api/system/launch-config`.

    DISPLAY ONLY. The clients render "FREE"/"Coming Soon"/"Upgrade to Premium"
    from this so their copy cannot drift from the server's behaviour — but
    every rule it describes is separately enforced by the guards below.
    """
    return {
        "premium": {
            "enabled": PREMIUM_ENABLED,
            "paymentRequired": PREMIUM_PAYMENT_REQUIRED,
            "provider": PREMIUM_PROVIDER,
        },
        "personalCoaching": {
            "enabled": PERSONAL_COACHING_ENABLED,
            "paymentRequired": PERSONAL_COACHING_PAYMENT_REQUIRED,
            "price": PERSONAL_COACHING_PRICE,
            "message": COACHING_FREE_MESSAGE,
        },
        "expertServices": {
            "paymentRequired": EXPERT_SERVICES_PAYMENT_REQUIRED,
        },
        "expertVerification": {
            "enabled": EXPERT_VERIFICATION_ENABLED,
            "paymentRequired": EXPERT_VERIFICATION_PAYMENT_REQUIRED,
        },
        "wallet": {
            "enabled": WALLET_ENABLED,
            "message": WALLET_FROZEN_MESSAGE,
        },
        "expertPayouts": {
            "enabled": EXPERT_PAYOUTS_ENABLED,
        },
    }


# ── Guards ───────────────────────────────────────────────────────────────────

def _frozen(error: str, message: str, **extra) -> HTTPException:
    """503, not 403: the caller is entitled to the feature — the feature is
    unavailable this release, and it is coming back."""
    return HTTPException(
        status_code=503,
        detail={"error": error, "message": message, **extra},
    )


def coaching_price(requested: float) -> float:
    """The price Personal Coaching ACTUALLY costs, decided server-side.

    Returns 0 while coaching is free, whatever the caller asked for or an
    expert's `pricing` map happens to say. Callers use the return value; a
    price arriving from anywhere else is advisory at best.
    """
    if not PERSONAL_COACHING_PAYMENT_REQUIRED:
        return 0.0
    return max(0.0, float(requested or 0))


def assert_coaching_charge_allowed(amount: float) -> None:
    """Refuse any attempt to charge for Personal Coaching.

    Belt to `coaching_price()`'s braces. That function zeroes the amount, so
    this should be unreachable — which is exactly why it is here: if a future
    edit routes a non-zero coaching amount to the wallet, this stops it rather
    than silently taking an athlete's money.
    """
    if PERSONAL_COACHING_PAYMENT_REQUIRED or amount <= 0:
        return
    print(f"[LAUNCH CONFIG] refused a coaching charge of ₹{amount} — "
          "Personal Coaching is free at launch")
    raise _frozen("coaching_is_free",
                  "Personal Coaching is free — no payment is required.",
                  amount=amount)


def assert_expert_service_charge_allowed(amount: float) -> None:
    """Same rule for plan reviews and expert chat: free means free."""
    if EXPERT_SERVICES_PAYMENT_REQUIRED or amount <= 0:
        return
    print(f"[LAUNCH CONFIG] refused an expert-service charge of ₹{amount} — "
          "expert services are free at launch")
    raise _frozen("expert_services_are_free",
                  "This expert service is free — no payment is required.",
                  amount=amount)


def assert_expert_verification_open() -> None:
    """Expert onboarding is frozen; a verification fee cannot exist."""
    if EXPERT_VERIFICATION_ENABLED:
        return
    raise _frozen("expert_verification_frozen",
                  "Expert applications are closed.")


def assert_expert_verification_payment_allowed() -> None:
    """There is no paid route to becoming a ZITLAS expert."""
    if EXPERT_VERIFICATION_PAYMENT_REQUIRED:
        return
    raise _frozen("expert_verification_is_free",
                  "There is no verification fee.")


def assert_payouts_enabled() -> None:
    """No withdrawal, no payout, no transfer of expert earnings at launch."""
    if EXPERT_PAYOUTS_ENABLED:
        return
    raise _frozen("expert_payouts_frozen",
                  "Expert payouts are not available yet.")


def assert_wallet_enabled(operation: str, amount: float | None = None) -> None:
    """Refuse a wallet MONEY MOVEMENT while the wallet is frozen.

    `amount is None` means the operation exists only to move money (a
    recharge, a credit) and is refused outright. A supplied `amount` is
    refused only above zero — a ₹0 "charge" moves nothing and writes nothing,
    and blocking it would take working, free features offline for no gain.
    """
    if WALLET_ENABLED:
        return
    if amount is not None and amount <= 0:
        return
    print(f"[LAUNCH CONFIG] wallet frozen — refused {operation}"
          + (f" amount=₹{amount}" if amount is not None else ""))
    raise _frozen("wallet_frozen", WALLET_FROZEN_MESSAGE, operation=operation)
