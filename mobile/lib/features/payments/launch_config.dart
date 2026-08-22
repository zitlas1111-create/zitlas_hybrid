/// ZITLAS — the launch business model, as the app renders it.
///
///     | Feature             | Launch State | Payment       |
///     |---------------------|--------------|---------------|
///     | Premium             | ACTIVE       | Razorpay ONLY |
///     | Personal Coaching   | ACTIVE       | FREE          |
///     | Expert Verification | FROZEN       | NO PAYMENT    |
///     | Wallet              | FROZEN       | DISABLED      |
///     | Expert Payouts      | FROZEN       | DISABLED      |
///
/// Mirrors `backend/launch_config.py`, the same way `Entitlements.fallback`
/// mirrors the server's plan matrix. DISPLAY ONLY — the backend enforces
/// every rule here inside the request, so a patched build changes what the
/// screen says and nothing about what it can do.
///
/// The payment engine is deliberately intact underneath: Razorpay orders,
/// escrow, the wallet ledger, the 80/20 split. This file decides only which
/// of it is offered today. When a feature is monetized, flip it HERE and in
/// `backend/launch_config.py` — the backend is the one that matters.
library;

/// Premium — the ONLY paid feature at launch, and Razorpay is its only
/// payment method. See `membership_screen.dart`.
const bool kPremiumPaymentRequired = true;

/// Personal Coaching is FREE. Not "₹0 at checkout" — there is no checkout.
const bool kPersonalCoachingPaymentRequired = false;

/// Expert plan reviews and expert chat are free at launch too.
const bool kExpertServicesPaymentRequired = false;

/// Expert onboarding is frozen; there is no verification fee and no public
/// application. The three approved experts stay authorized.
const bool kExpertVerificationEnabled = false;

/// Expert payouts/withdrawals do not run at launch.
const bool kExpertPayoutsEnabled = false;

/// What to show where a price would otherwise go, for a feature that has no
/// price. "FREE" rather than "₹0": a zero price still reads as a payment
/// step that happens to cost nothing, and this is not one.
const String kFreeLabel = 'FREE';

/// Formats a launch price for display: [kFreeLabel] when the feature is free
/// or the amount is zero, `₹<amount>` otherwise.
String launchPriceLabel(num amount, {required bool paymentRequired}) {
  if (!paymentRequired || amount <= 0) return kFreeLabel;
  return '₹$amount';
}
