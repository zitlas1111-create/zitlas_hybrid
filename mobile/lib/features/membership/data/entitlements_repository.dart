import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/network/api_client.dart';

/// The plan matrix, exactly as the backend enforces it.
///
/// Flutter deliberately keeps NO definition of its own. `GET /api/entitlements`
/// serves the same numbers `services/entitlements.py` checks on every request,
/// so what the athlete is shown and what the server allows cannot drift.
///
/// The membership screen previously hard-coded "3 goal resets" and "25 meal
/// swaps" while the real matrix was 2 and 70/unlimited — the kind of
/// contradiction a second source of truth guarantees eventually.
class PlanLimits {
  const PlanLimits({
    required this.goalReset,
    required this.mealSwap,
    required this.recipe,
  });

  /// `null` means UNLIMITED — a sentinel, never a large number. Premium meal
  /// swaps have no numeric quota at all, so there is nothing to compare a
  /// count against.
  final int? goalReset;
  final int? mealSwap;
  final int? recipe;

  static int? _limit(dynamic value) {
    if (value == null || value == 'unlimited') return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  factory PlanLimits.fromMap(Map<String, dynamic> m) => PlanLimits(
        goalReset: _limit(m['goal_reset']),
        mealSwap: _limit(m['meal_swap']),
        recipe: _limit(m['recipe']),
      );

  String get goalResetLabel => label(goalReset);
  String get mealSwapLabel => label(mealSwap);
  String get recipeLabel => label(recipe);

  static String label(int? value) => value == null ? 'Unlimited' : '$value';
}

class Entitlements {
  const Entitlements({
    required this.tier,
    required this.free,
    required this.premium,
    required this.premiumPriceInr,
  });

  final String tier;
  final PlanLimits free;
  final PlanLimits premium;
  final int premiumPriceInr;

  bool get isPremium => tier == 'premium';

  /// What the app shows before the network answers, and if it never does.
  ///
  /// These MIRROR the server defaults rather than inventing softer ones: a
  /// fallback that under-promised would be its own contradiction. Enforcement
  /// is always the server's, so these values are display-only.
  static const fallback = Entitlements(
    tier: 'free',
    free: PlanLimits(goalReset: 2, mealSwap: 70, recipe: 7),
    premium: PlanLimits(goalReset: 5, mealSwap: null, recipe: 27),
    premiumPriceInr: 149,
  );

  factory Entitlements.fromMap(Map<String, dynamic> m) {
    final plans = (m['plans'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, dynamic> limitsOf(String tier) {
      final plan = (plans[tier] as Map?)?.cast<String, dynamic>();
      return (plan?['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    }

    final premiumPlan = (plans['premium'] as Map?)?.cast<String, dynamic>();
    return Entitlements(
      tier: (m['tier'] ?? 'free').toString(),
      free: PlanLimits.fromMap(limitsOf('free')),
      premium: PlanLimits.fromMap(limitsOf('premium')),
      premiumPriceInr:
          (premiumPlan?['priceInr'] as num?)?.toInt() ??
              (m['premiumPriceInr'] as num?)?.toInt() ??
              149,
    );
  }
}

class EntitlementsRepository {
  EntitlementsRepository({ApiClient? apiClient, FirebaseAuth? auth})
      : _api = apiClient ?? ApiClient(),
        // Nullable by design so the repo can fall back to
        // FirebaseAuth.instance lazily, exactly like profile_repository.
        // ignore: prefer_initializing_formals
        _auth = auth {
    _api.authTokenProvider = () async {
      try {
        return await (_auth ?? FirebaseAuth.instance).currentUser?.getIdToken();
      } catch (_) {
        return null;
      }
    };
  }

  final ApiClient _api;
  final FirebaseAuth? _auth;

  /// Never throws: the membership screen must still render its comparison if
  /// the network is down. Falls back to the mirrored defaults above.
  Future<Entitlements> fetch() async {
    try {
      final res = await _api.get('/api/entitlements');
      if (res is Map) {
        return Entitlements.fromMap(res.cast<String, dynamic>());
      }
    } catch (_) {
      /* fall through */
    }
    return Entitlements.fallback;
  }
}
