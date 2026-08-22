import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/membership/data/entitlements_repository.dart';
import 'package:zitlas_mobile/features/payments/launch_config.dart';
import 'package:zitlas_mobile/features/payments/wallet_freeze.dart';

/// THE FINAL ZITLAS LAUNCH MODEL, as the app presents it.
///
///     | Feature             | Launch State | Payment       |
///     |---------------------|--------------|---------------|
///     | Premium             | ACTIVE       | Razorpay ONLY |
///     | Personal Coaching   | ACTIVE       | FREE          |
///     | Expert Verification | FROZEN       | NO PAYMENT    |
///     | Wallet              | FROZEN       | DISABLED      |
///     | Expert Payouts      | FROZEN       | DISABLED      |
///
/// These pin the DISPLAYED half. The enforced half — which is the half that
/// matters — lives in backend/tests/test_launch_config.py, because a flag in
/// a Flutter build can be patched and a server guard cannot.
void main() {
  group('the launch matrix', () {
    test('Premium is the only paid feature', () {
      expect(kPremiumPaymentRequired, isTrue);
      expect(kPersonalCoachingPaymentRequired, isFalse);
      expect(kExpertServicesPaymentRequired, isFalse);
    });

    test('expert verification is frozen', () {
      expect(kExpertVerificationEnabled, isFalse);
    });

    test('the wallet is frozen', () {
      expect(kWalletFrozen, isTrue);
    });

    test('expert payouts are frozen', () {
      expect(kExpertPayoutsEnabled, isFalse);
    });

    test('the app mirrors the backend matrix exactly', () {
      // backend/launch_config.py's defaults, restated. If the two ever drift,
      // the app shows one model while the server enforces another.
      expect(kPremiumPaymentRequired, isTrue); // PREMIUM_PAYMENT_REQUIRED
      expect(kPersonalCoachingPaymentRequired, isFalse);
      expect(kExpertServicesPaymentRequired, isFalse);
      expect(kExpertVerificationEnabled, isFalse);
      expect(kExpertPayoutsEnabled, isFalse);
      expect(kWalletFrozen, isTrue); // WALLET_ENABLED == false
    });
  });

  group('a free feature never shows a price', () {
    test('a free service reads FREE, not ₹0', () {
      // "₹0" beside a Continue button reads as a payment step that happens
      // to cost nothing. Personal Coaching and expert reviews are not
      // payment steps at all.
      expect(launchPriceLabel(0, paymentRequired: false), 'FREE');
      expect(launchPriceLabel(499, paymentRequired: false), 'FREE');
    });

    test('a zero amount reads FREE even when the feature is paid', () {
      expect(launchPriceLabel(0, paymentRequired: true), 'FREE');
    });

    test('a real price is still rendered when one applies', () {
      // The engine is frozen, not deleted: turning a feature paid again must
      // put its price straight back on screen.
      expect(launchPriceLabel(499, paymentRequired: true), '₹499');
    });
  });

  group('nothing else was disturbed', () {
    test('the entitlement matrix is unchanged', () {
      final free = Entitlements.fallback.free;
      final premium = Entitlements.fallback.premium;
      expect([free.goalReset, free.mealSwap, free.recipe], [2, 70, 7]);
      expect(premium.goalReset, 5);
      expect(premium.mealSwap, isNull);
      expect(premium.recipe, 27);
    });

    test('Premium is still ₹149', () {
      expect(Entitlements.fallback.premiumPriceInr, 149);
    });
  });
}
