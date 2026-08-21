import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/auth/data/role_repository.dart';

/// The role decision must start from a FRESHLY MINTED ID token.
///
/// Firebase caches an ID token for up to an hour. When the three ZITLAS
/// experts were finally granted `expert: true`, every client still held a
/// token minted BEFORE the grant — so the claim was genuinely absent from it,
/// `/api/auth/role` correctly answered "user", and all three kept landing on
/// the user dashboard even though the authorisation data was perfect.
///
/// `getIdToken(true)` is therefore not a nicety: without it a newly-authorised
/// expert is locked out for up to an hour, and a REVOKED expert keeps access
/// for just as long.
class _FakeUser extends Fake implements User {
  _FakeUser();

  /// Every getIdToken call, with the forceRefresh flag it was given.
  final List<bool> calls = [];

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    calls.add(forceRefresh);
    // A cached token carries the OLD claims; a refreshed one carries the new.
    return forceRefresh ? 'fresh-token' : 'stale-token';
  }
}

class _FakeAuth extends Fake implements FirebaseAuth {
  _FakeAuth(this._user);
  final User? _user;
  @override
  User? get currentUser => _user;
}

void main() {
  test('the auth token provider forces a refresh', () async {
    final user = _FakeUser();
    final api = ApiClient();
    RoleRepository(apiClient: api, auth: _FakeAuth(user));

    final token = await api.authTokenProvider!();

    expect(user.calls, isNotEmpty, reason: 'no token was requested at all');
    expect(user.calls.every((forced) => forced), isTrue,
        reason: 'getIdToken() was called WITHOUT forceRefresh — a cached '
            'token can be an hour old and will not contain a claim granted '
            'after it was minted');
    expect(token, 'fresh-token');
  });

  test('a signed-out user yields no token rather than throwing', () async {
    final api = ApiClient();
    RoleRepository(apiClient: api, auth: _FakeAuth(null));

    expect(await api.authTokenProvider!(), isNull);
  });

  test('the refresh flag is passed on every call, not just the first',
      () async {
    final user = _FakeUser();
    final api = ApiClient();
    RoleRepository(apiClient: api, auth: _FakeAuth(user));

    await api.authTokenProvider!();
    await api.authTokenProvider!();
    await api.authTokenProvider!();

    expect(user.calls, [true, true, true],
        reason: 'a later call must not silently fall back to the cache');
  });
}
