/// WALLET FREEZE — the Wallet moves no money this release.
///
/// Mirrors `backend/wallet_config.py`'s `WALLET_FROZEN`, the same way
/// `Entitlements.fallback` mirrors the server's plan matrix: the value here
/// decides only what the UI SHOWS. Every wallet money movement is refused by
/// the backend with `503 wallet_frozen` regardless of what this app believes,
/// so flipping it in a patched build buys nothing.
///
/// Frozen means: no deposit, no withdrawal, no transfer, no spending, no
/// earning. It does NOT mean hidden — balance, usage totals and the full
/// transaction history keep rendering, because freezing the feature must not
/// take an athlete's own money and records away from them.
///
/// Premium is unaffected and always has been: it is bought from Razorpay
/// directly (`/api/payment/membership/*`) and has no wallet path at all.
///
/// When the Wallet ships in V2, flip this AND `WALLET_FROZEN` in
/// `backend/wallet_config.py`. The backend is the one that matters.
const bool kWalletFrozen = true;

/// The copy shown wherever a wallet action would otherwise be offered.
/// Kept identical to `wallet_config.WALLET_FROZEN_MESSAGE`.
const String kWalletFrozenMessage =
    "Wallet is temporarily unavailable. It's coming in a future update — "
    'your balance and transaction history are safe.';
