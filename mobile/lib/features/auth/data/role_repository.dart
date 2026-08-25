import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';

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
///
/// THREE OUTCOMES, NOT TWO. This used to collapse every failure into
/// `'user'`, which meant one flaky request — a cold backend, a lift-door
/// moment of no signal, a 502 — silently dropped a genuine expert onto the
/// athlete dashboard with no error and no retry. That is the "sometimes I log
/// in and I'm a normal user" report. `null` now means "could not resolve",
/// which is NOT the same claim as "this is a normal user" and must never be
/// routed as one. Authorization still fails closed: nothing grants expert
/// access without a positive server answer.
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

  /// Backoff between attempts. Short enough that a normal cold-start delay is
  /// invisible, long enough to outlast a backend waking from idle.
  static const retryDelays = [
    Duration(milliseconds: 400),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// `'expert'`, `'user'`, or `null` when the server could not be reached.
  ///
  /// A `null` is a *transport* outcome, never a verdict. Callers must hold
  /// the loading state and retry rather than treating it as `'user'` — see
  /// [AuthState.roleResolved].
  Future<String?> fetchRole() async {
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      final outcome = await _attempt();
      if (outcome != null) return outcome;
      if (attempt < retryDelays.length) {
        if (kDebugMode) {
          debugPrint('[ROLE] unresolved — retrying in '
              '${retryDelays[attempt].inMilliseconds}ms '
              '(attempt ${attempt + 2}/${retryDelays.length + 1})');
        }
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
    if (kDebugMode) {
      debugPrint('[ROLE] UNRESOLVED after ${retryDelays.length + 1} attempts — '
          'the caller must NOT assume "user"');
    }
    return null;
  }

  /// One request. Returns a definitive role, or null to mean "ask again".
  Future<String?> _attempt() async {
    try {
      final res = await _api.get('/api/auth/role');
      if (res is Map) {
        final isExpert = res['isExpert'] == true;
        final role = (res['role'] ?? '').toString();
        if (kDebugMode) {
          debugPrint('[ROLE SOURCE] GET /api/auth/role -> role=$role '
              'isExpert=$isExpert');
        }
        // A 200 is the server's verdict, whichever way it went.
        return isExpert && role == 'expert' ? 'expert' : 'user';
      }
      // 200 with a shape we do not understand. Treat as unresolved rather
      // than as "user" — a proxy or captive portal can return 200 HTML.
      if (kDebugMode) debugPrint('[ROLE] unexpected body shape: ${res.runtimeType}');
      return null;
    } on ApiException catch (e) {
      // 401/403 IS an answer: the server evaluated this caller and refused.
      // Anything else (no status = transport, or a 5xx) is the server failing
      // to answer, which tells us nothing about the account.
      if (e.isUnauthorized) {
        if (kDebugMode) {
          debugPrint('[ROLE SOURCE] GET /api/auth/role -> ${e.statusCode} '
              '(server refused this caller) -> user');
        }
        return 'user';
      }
      if (kDebugMode) {
        debugPrint('[ROLE] lookup failed (status=${e.statusCode ?? "network"}): '
            '${e.message}');
      }
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[ROLE] lookup threw: $e');
      return null;
    }
  }
}
