import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/diet/data/diet_repository.dart';
import 'package:zitlas_mobile/features/membership/data/entitlements_repository.dart';

/// THE APP MUST SEND ITS TOKEN, AND MUST HONOUR THE ANSWER.
///
/// The matrix was right and the backend gate existed, but no client sent an
/// Authorization header to the swap endpoints and nothing called
/// `/api/entitlements/consume` at all. So the backend saw an anonymous
/// caller, skipped metering, and every athlete had unlimited swaps and
/// unlimited goal resets — free and premium alike.
///
/// Two claims are pinned here, because either one alone leaves the hole
/// open: the request carries a token, and a refusal actually stops the app.
void main() {
  // ── 1. The swap request is authenticated ───────────────────────────────
  group('meal swap sends the athlete token', () {
    test('DietRepository installs a token provider on its ApiClient', () async {
      final client = ApiClient(baseUrl: 'https://api.test');
      DietRepository(firestore: FakeFirebaseFirestore(), apiClient: client);

      expect(client.authTokenProvider, isNotNull,
          reason: 'without this /api/diet/swap sees an anonymous caller, '
              'skips metering, and the 70/week free limit never applies');
    });

    test('the Authorization header actually reaches the swap endpoint',
        () async {
      Map<String, String>? headers;
      final mock = MockClient((request) async {
        headers = request.headers;
        return http.Response(
          jsonEncode({'module': 'deterministic_swap', 'options': []}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final api = ApiClient(httpClient: mock, baseUrl: 'https://api.test');
      api.authTokenProvider = () async => 'test-id-token';

      await DietRepository(
        firestore: FakeFirebaseFirestore(),
        apiClient: api,
      ).swapMeal(
        mealName: 'Breakfast',
        mealTime: '',
        currentFoods: const ['Poha'],
        reason: 'not available',
        userProfile: const {},
        lifestyleData: const {},
        rejectedFoods: const [],
        previousSuggestions: const [],
        fitnessGoal: 'transformation',
      );

      expect(headers?['Authorization'], 'Bearer test-id-token');
    });

    test('a spent allowance (429) is raised, never swallowed into a fallback',
        () async {
      // Only 404/405 fall back to the legacy LLM endpoint (the app ships
      // ahead of the backend). A 429 falling through would spend the
      // allowance twice and hand back a swap the athlete had not earned.
      final mock = MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {
                'error': 'limit_reached',
                'tier': 'free',
                'limit': 70,
                'used': 70,
              }
            }),
            429,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final repo = DietRepository(
        firestore: FakeFirebaseFirestore(),
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      );

      expect(
        () => repo.swapMeal(
          mealName: 'Breakfast',
          mealTime: '',
          currentFoods: const ['Poha'],
          reason: 'not available',
          userProfile: const {},
          lifestyleData: const {},
          rejectedFoods: const [],
          previousSuggestions: const [],
          fitnessGoal: 'transformation',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ── 2. Goal reset is reserved before it happens ────────────────────────
  group('goal reset consumption', () {
    EntitlementsRepository repoWith(int status, Map<String, dynamic> body) {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/entitlements/consume');
        expect(jsonDecode(request.body)['feature'], 'goal_reset');
        return http.Response(
          jsonEncode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      return EntitlementsRepository(
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      );
    }

    test('a granted unit allows the reset', () async {
      final outcome = await repoWith(200, {
        'ok': true,
        'feature': 'goal_reset',
        'allowance': {'used': 1, 'limit': 2},
      }).consume('goal_reset');

      expect(outcome.allowed, isTrue);
    });

    test('a free athlete out of resets is refused, with the real reason',
        () async {
      final outcome = await repoWith(429, {
        'detail': {
          'error': 'limit_reached',
          'tier': 'free',
          'limit': 2,
          'used': 2,
        }
      }).consume('goal_reset');

      expect(outcome.allowed, isFalse);
      expect(outcome.message, contains('2'));
      expect(outcome.message, contains('Premium'),
          reason: 'a free athlete at the cap should be told the way out');
    });

    test('a premium athlete at 5 is refused WITHOUT an upgrade prompt',
        () async {
      // Never show an upgrade prompt to somebody who already pays.
      final outcome = await repoWith(429, {
        'detail': {
          'error': 'limit_reached',
          'tier': 'premium',
          'limit': 5,
          'used': 5,
        }
      }).consume('goal_reset');

      expect(outcome.allowed, isFalse);
      expect(outcome.message, isNot(contains('Upgrade')));
    });

    test('an unauthenticated caller is refused, not waved through', () async {
      final outcome = await repoWith(401, {'detail': 'Not authenticated'})
          .consume('goal_reset');

      expect(outcome.allowed, isFalse);
      expect(outcome.message, contains('sign in'));
    });

    test('a transport failure fails OPEN, deliberately', () async {
      // The one case that does not block: refusing to let an athlete reset
      // their goal because the network blipped is worse than the rare
      // uncounted reset. Every DECISION the server makes is still honoured.
      final mock = MockClient((request) async => throw const SocketishError());
      final outcome = await EntitlementsRepository(
        apiClient: ApiClient(httpClient: mock, baseUrl: 'https://api.test'),
      ).consume('goal_reset');

      expect(outcome.allowed, isTrue);
    });

    test('the repository installs a token provider', () async {
      final client = ApiClient(baseUrl: 'https://api.test');
      EntitlementsRepository(apiClient: client);
      expect(client.authTokenProvider, isNotNull);
    });
  });

  // ── 3. The displayed matrix still matches the server's ─────────────────
  group('the matrix is unchanged', () {
    test('free is 2 / 70 / 7', () {
      final free = Entitlements.fallback.free;
      expect(free.goalReset, 2);
      expect(free.mealSwap, 70);
      expect(free.recipe, 7);
    });

    test('premium is 5 / unlimited / 27 at ₹149', () {
      final premium = Entitlements.fallback.premium;
      expect(premium.goalReset, 5);
      expect(premium.mealSwap, isNull, reason: 'unlimited is a sentinel');
      expect(premium.recipe, 27);
      expect(Entitlements.fallback.premiumPriceInr, 149);
    });
  });
}

/// Stands in for a transport-layer failure without importing dart:io.
class SocketishError implements Exception {
  const SocketishError();
}
