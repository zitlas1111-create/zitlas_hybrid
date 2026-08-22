"""
ZITLAS — WALLET FREEZE (single global switch)
==================================================

THE one place that decides whether the Wallet may move money.

The Wallet is not ready for launch, so for production it is FROZEN: no
deposit, no withdrawal, no transfer, no spending, no earning, no
wallet-to-wallet movement. Nothing is deleted — every balance, every
`users/{uid}.wallet` field and every `wallet_transactions` record stays
exactly where it is, readable, for V2 and for auditing.

    WALLET_ENABLED = False -> every wallet MONEY MOVEMENT is refused with
        503 wallet_frozen, at the endpoint, before any Firestore write:
        - POST /api/payment/create-order  (wallet recharge)      refused
        - POST /api/payment/verify        (wallet credit)        refused
        - POST /api/payment/charge        (wallet debit)         refused
                                          when the charge is > ₹0
        - POST /api/coaching/request      (escrow reservation)   refused
                                          when the reservation is > ₹0
        - POST /api/coaching/accept       (escrow debit)         refused
                                          when the debit is > ₹0

    WALLET_ENABLED = True  -> the wallet behaves exactly as it did before
        this switch existed. No other change is needed anywhere.

DELIBERATELY NOT AFFECTED — these never touch the wallet:
    - Premium subscription via Razorpay (POST /api/payment/membership/*).
      Premium is bought from Razorpay directly and activated only after
      server-side signature verification. It has never had, and must never
      gain, a wallet payment path.
    - READING a balance or a transaction history. Freezing is not hiding:
      an athlete can still see what they hold and what they spent.
    - Every ₹0 path. With CLIENT_TRIAL_MODE / PLATFORM_CHARGES_FREE on
      (both default True in trial_config.py) coaching and expert services
      already reserve and debit ₹0 and write no wallet field at all, so
      they keep working untouched. The guards below fire on money, not on
      the feature — freezing the wallet must not take Personal Coaching
      offline with it.

Optional override without a code change: set the WALLET_ENABLED environment
variable to "true"/"false" — launch_config reads it, and this module follows.
"""

import launch_config

#: The wallet freeze now lives in the one launch matrix
#: (backend/launch_config.py). This module stays as the name the wallet code
#: and its tests already import — one definition, two spellings, so nothing
#: has to be renamed and the two can never disagree.
WALLET_FROZEN: bool = not launch_config.WALLET_ENABLED

WALLET_FROZEN_MESSAGE = launch_config.WALLET_FROZEN_MESSAGE


def assert_wallet_unfrozen(operation: str, amount: float | None = None) -> None:
    """Refuse a wallet MONEY MOVEMENT while the wallet is frozen.

    See `launch_config.assert_wallet_enabled` for the rule. Reads the
    module-level `WALLET_FROZEN` first so a test that monkeypatches THIS
    module (tests/test_payment.py, tests/test_coaching.py, which exercise the
    wallet mechanism kept for V2) still takes effect.
    """
    if not WALLET_FROZEN:
        return
    launch_config.assert_wallet_enabled(operation, amount)
