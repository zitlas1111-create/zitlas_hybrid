import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';

/// The account's role, as decided by the server.
///
/// `GET /api/auth/role` derives it from the verified Firebase ID token's
/// `expert` custom claim AND `experts/{uid}.approved`. Neither is writable
/// from a device, which is the entire point: the app previously read
/// `users/{uid}.role`/`roles`/`expert_status` — fields the client itself
/// writes — and counted `expert_pending`/`pending` as EXPERT, so simply
/// applying landed you on the expert dashboard.
///
/// The website resolves the role through the same endpoint, so both clients
/// reach the identical decision for the same account.
class RoleRepository {
  RoleRepository({ApiClient? apiClient, FirebaseAuth? auth})
      : _api = apiClient ?? ApiClient(),
        // Nullable by design so the repo can fall back to
        // FirebaseAuth.instance lazily, matching profile_repository.
        // ignore: prefer_initializing_formals
        _auth = auth {
    _api.authTokenProvider = () async {
      try {
        // getIdToken(TRUE) — force a refresh. Firebase caches an ID token
        // for up to an hour, so a custom claim granted after it was minted
        // is simply absent from it and the backend correctly answers "user".
        // The role decision must always start from a freshly minted token.
        return await (_auth ?? FirebaseAuth.instance)
            .currentUser
            ?.getIdToken(true);
      } catch (_) {
        return null;
      }
    };
  }

  final ApiClient _api;
  final FirebaseAuth? _auth;

  /// `'expert'` or `'user'`.
  ///
  /// FAILS CLOSED. A network error, a 401, an unexpected body — every one of
  /// them yields `'user'`. Granting expert access because a request failed
  /// would reintroduce exactly the hole this replaced; a genuine expert who
  /// briefly sees the user dashboard simply reopens the app.
  Future<String> fetchRole() async {
    try {
      final res = await _api.get('/api/auth/role');
      if (res is Map) {
        final isExpert = res['isExpert'] == true;
        final role = (res['role'] ?? '').toString();
        if (kDebugMode) {
          debugPrint('[ROLE SOURCE] GET /api/auth/role -> role=$role '
              'isExpert=$isExpert');
        }
        return isExpert && role == 'expert' ? 'expert' : 'user';
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ROLE] lookup failed, treating as user: $e');
    }
    return 'user';
  }
}
