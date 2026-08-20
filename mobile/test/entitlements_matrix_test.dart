import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/membership/data/entitlements_repository.dart';

/// Flutter must render the SAME plan matrix the backend enforces.
///
/// The membership screen used to hard-code "3 Goal Set/Resets" and "25 Meal
/// Swaps" while services/entitlements.py held 2 and 70/unlimited. Nothing made
/// that contradiction visible, which is precisely what a second source of
/// truth guarantees. The screen now renders from GET /api/entitlements; these
/// tests pin the parsing and the offline fallback.
///
/// The server-side matrix is asserted in backend/tests/test_entitlements.py —
/// together the two ends are checked against each other.
void main() {
  /// Exactly the payload GET /api/entitlements serves.
  Map<String, dynamic> payload({String tier = 'free'}) => {
        'tier': tier,
        'premiumPriceInr': 149,
        'plans': {
          'free': {
            'limits': {'goal_reset': 2, 'meal_swap': 70, 'recipe': 7},
            'perks': {'zino_ai': 'standard', 'expert_review_priority': false},
          },
          'premium': {
            'limits': {'goal_reset': 5, 'meal_swap': 'unlimited', 'recipe': 27},
            'perks': {'zino_ai': 'priority', 'expert_review_priority': true},
            'priceInr': 149,
          },
        },
      };

  group('parsing the served matrix', () {
    test('free limits are 2 / 70 / 7', () {
      final e = Entitlements.fromMap(payload());
      expect(e.free.goalReset, 2);
      expect(e.free.mealSwap, 70);
      expect(e.free.recipe, 7);
    });

    test('premium limits are 5 / unlimited / 27', () {
      final e = Entitlements.fromMap(payload());
      expect(e.premium.goalReset, 5);
      expect(e.premium.recipe, 27);
      expect(e.premium.mealSwap, isNull, reason: 'unlimited is a null sentinel');
    });

    test('"unlimited" renders as a word, never as a number', () {
      final e = Entitlements.fromMap(payload());
      expect(e.premium.mealSwapLabel, 'Unlimited');
      // The two numbers the spec explicitly forbids for premium swaps.
      expect(e.premium.mealSwapLabel, isNot(contains('70')));
      expect(e.premium.mealSwapLabel, isNot(contains('500')));
    });

    test('free labels are the plain numbers', () {
      final e = Entitlements.fromMap(payload());
      expect(e.free.mealSwapLabel, '70');
      expect(e.free.goalResetLabel, '2');
      expect(e.free.recipeLabel, '7');
    });

    test('the price comes from the server, not the app', () {
      expect(Entitlements.fromMap(payload()).premiumPriceInr, 149);
    });

    test('tier drives isPremium', () {
      expect(Entitlements.fromMap(payload(tier: 'premium')).isPremium, isTrue);
      expect(Entitlements.fromMap(payload()).isPremium, isFalse);
    });
  });

  group('the offline fallback mirrors the server', () {
    test('it is the same matrix, so it can never under-promise', () {
      const f = Entitlements.fallback;
      expect(f.free.goalReset, 2);
      expect(f.free.mealSwap, 70);
      expect(f.free.recipe, 7);
      expect(f.premium.goalReset, 5);
      expect(f.premium.mealSwap, isNull);
      expect(f.premium.recipe, 27);
      expect(f.premiumPriceInr, 149);
    });

    test('a fallback user is treated as free, never as premium', () {
      // Failing open to premium in the UI would promise access the server
      // would then refuse.
      expect(Entitlements.fallback.isPremium, isFalse);
    });

    test('the fallback agrees with a served payload field for field', () {
      final served = Entitlements.fromMap(payload());
      const f = Entitlements.fallback;
      expect(served.free.goalReset, f.free.goalReset);
      expect(served.free.mealSwap, f.free.mealSwap);
      expect(served.free.recipe, f.free.recipe);
      expect(served.premium.goalReset, f.premium.goalReset);
      expect(served.premium.mealSwap, f.premium.mealSwap);
      expect(served.premium.recipe, f.premium.recipe);
      expect(served.premiumPriceInr, f.premiumPriceInr);
    });
  });

  group('malformed responses degrade safely', () {
    test('an empty payload does not throw', () {
      final e = Entitlements.fromMap(const {});
      expect(e.tier, 'free');
      expect(e.premiumPriceInr, 149);
    });

    test('a missing plans block yields null limits, shown as Unlimited only '
        'where the server actually said so', () {
      final e = Entitlements.fromMap(const {'tier': 'free'});
      // Nothing was served, so nothing is claimed as a number.
      expect(e.free.mealSwap, isNull);
    });

    test('a numeric string limit is parsed', () {
      final e = Entitlements.fromMap({
        'plans': {
          'free': {'limits': {'meal_swap': '70'}},
          'premium': {'limits': {'meal_swap': 'unlimited'}},
        }
      });
      expect(e.free.mealSwap, 70);
      expect(e.premium.mealSwap, isNull);
    });
  });
}
