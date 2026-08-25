import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zitlas_mobile/core/network/api_client.dart';
import 'package:zitlas_mobile/features/auth/data/role_repository.dart';
import 'package:zitlas_mobile/models/user_model.dart';

/// Role resolution is SERVER-AUTHORITATIVE.
///
/// This file previously pinned the opposite contract: it asserted that
/// `roles: ['expert_pending']` and `expert_status: 'pending'` resolved to
/// EXPERT, read off `users/{uid}` — a document the client itself writes. So
/// an account that had merely *applied* landed on the expert dashboard, and
/// anyone who could write their own user document could self-promote.
///
/// The role now comes from `GET /api/auth/role`, which the backend derives
/// from the verified Firebase token's `expert` custom claim AND
/// `experts/{uid}.approved` (see backend/services/auth_service.py and
/// backend/tests/test_expert_freeze.py). `UserModel` carries that answer in
/// [UserModel.serverRole] and trusts nothing else.
///
/// The legacy `role` / `roles` / `expertStatus` fields are still PARSED,
/// because they exist on live Firestore documents and other code displays
/// them — they are simply no longer an authorisation signal.
void main() {
  UserModel user({
    String? serverRole,
    String role = 'user',
    List<String> roles = const [],
    String expertStatus = 'none',
  }) =>
      UserModel(
        uid: 'u1',
        email: 'u1@example.com',
        role: role,
        roles: roles,
        expertStatus: expertStatus,
        serverRole: serverRole,
      );

  RoleRepository repoReturning(
    List<http.Response> Function() responses, {
    List<Uri>? calls,
  }) {
    final queue = responses();
    var i = 0;
    final client = MockClient((req) async {
      calls?.add(req.url);
      final res = queue[i < queue.length ? i : queue.length - 1];
      i++;
      return res;
    });
    return RoleRepository(
      apiClient: ApiClient(httpClient: client, baseUrl: 'https://api.test'),
    );
  }

  http.Response ok(Map<String, dynamic> body) => http.Response(
        jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  group('the server decides', () {
    test('serverRole "expert" resolves to expert', () {
      final u = user(serverRole: 'expert');
      expect(u.isExpert, isTrue);
      expect(u.resolvedRole, 'expert');
    });

    test('serverRole "user" resolves to user', () {
      final u = user(serverRole: 'user');
      expect(u.isExpert, isFalse);
      expect(u.resolvedRole, 'user');
    });

    test('the two values match what GET /api/auth/role returns', () {
      expect(user(serverRole: 'expert').resolvedRole, 'expert');
      expect(user(serverRole: 'user').resolvedRole, 'user');
    });
  });

  group('fails closed', () {
    test('an unresolved role is a normal user, never an expert', () {
      final u = user(serverRole: null);
      expect(u.isExpert, isFalse,
          reason: 'a device that could not reach the server must not be '
              'granted expert access');
      expect(u.resolvedRole, 'user');
    });

    test('an unrecognised server value is a normal user', () {
      expect(user(serverRole: 'admin').isExpert, isFalse);
      expect(user(serverRole: '').isExpert, isFalse);
      expect(user(serverRole: 'Expert').isExpert, isFalse,
          reason: 'the contract is lowercase; anything else is not a match');
    });
  });

  group('client-writable fields can no longer promote an account', () {
    // Each of these previously resolved to EXPERT.
    test('legacy role: "expert" alone does not', () {
      expect(user(role: 'expert').isExpert, isFalse);
    });

    test('roles containing "expert" alone does not', () {
      expect(user(roles: const ['expert']).isExpert, isFalse);
    });

    test('roles containing "expert_pending" does not — an application under '
        'review is NOT an expert', () {
      expect(user(roles: const ['expert_pending']).isExpert, isFalse);
    });

    test('expert_status "approved" alone does not', () {
      expect(user(expertStatus: 'approved').isExpert, isFalse);
    });

    test('expert_status "pending" does not', () {
      expect(user(expertStatus: 'pending').isExpert, isFalse);
    });

    test('every legacy marker at once still does not', () {
      final u = user(
        role: 'expert',
        roles: const ['expert', 'expert_pending'],
        expertStatus: 'approved',
      );
      expect(u.isExpert, isFalse,
          reason: 'only the server may grant the expert role');
      expect(u.resolvedRole, 'user');
    });

    test('the server wins even when the legacy fields disagree', () {
      // A real approved expert whose user document was never back-filled.
      final u = user(serverRole: 'expert', role: 'user', expertStatus: 'none');
      expect(u.isExpert, isTrue);

      // And the reverse: a revoked expert whose stale document still says so.
      final revoked = user(
          serverRole: 'user', role: 'expert', expertStatus: 'approved');
      expect(revoked.isExpert, isFalse);
    });
  });

  group('fromMap — still tolerant of real Firestore documents', () {
    test('a document with no role fields at all does not crash', () {
      final u = UserModel.fromMap({'uid': 'u1', 'email': 'a@b.com'});
      expect(u.role, 'user');
      expect(u.roles, isEmpty);
      expect(u.expertStatus, 'none');
      // Never parsed from the document — it is not in there.
      expect(u.serverRole, isNull);
      expect(u.isExpert, isFalse);
    });

    test('the legacy fields are still READ, just not trusted', () {
      final u = UserModel.fromMap({
        'uid': 'u1',
        'email': 'a@b.com',
        'role': 'expert',
        'roles': ['expert', 'coach'],
        'expert_status': 'approved',
      });
      expect(u.role, 'expert');
      expect(u.roles, ['expert', 'coach']);
      expect(u.expertStatus, 'approved');
      expect(u.isExpert, isFalse, reason: 'read, but not an authority');
    });

    test('an existing document round-trips through toMap/fromMap', () {
      final original = UserModel.fromMap({
        'uid': 'u1',
        'email': 'a@b.com',
        'role': 'expert',
        'roles': ['expert'],
        'expert_status': 'approved',
      });
      final restored = UserModel.fromMap(original.toMap());
      expect(restored.role, original.role);
      expect(restored.roles, original.roles);
      expect(restored.expertStatus, original.expertStatus);
    });

    test('serverRole is not written back into the user document', () {
      // It belongs to the session, not to Firestore — persisting it would
      // recreate a client-writable role field.
      final u = user(serverRole: 'expert');
      expect(u.toMap().containsKey('serverRole'), isFalse);
    });
  });

  group('withServerRole', () {
    test('attaches the server answer without disturbing identity', () {
      final base = UserModel.fromMap({
        'uid': 'u1', 'email': 'a@b.com', 'role': 'user',
      });
      final promoted = base.withServerRole('expert');
      expect(promoted.uid, base.uid);
      expect(promoted.email, base.email);
      expect(promoted.role, base.role);
      expect(promoted.isExpert, isTrue);
      // The original is untouched.
      expect(base.isExpert, isFalse);
    });

    test('can demote just as easily — no cached expert state survives', () {
      final expert = user(serverRole: 'expert');
      expect(expert.withServerRole('user').isExpert, isFalse);
      expect(expert.withServerRole(null).isExpert, isFalse);
    });
  });

  group('resolved-vs-unresolved (the routing gate)', () {
    test('a served role is resolved', () {
      expect(user(serverRole: 'expert').roleResolved, isTrue);
      expect(user(serverRole: 'user').roleResolved, isTrue);
    });

    test('UNRESOLVED is not the same claim as "user"', () {
      final u = user(serverRole: null);
      // Fails closed for AUTHORIZATION...
      expect(u.isExpert, isFalse);
      expect(u.resolvedRole, 'user');
      // ...but the router must be able to tell the difference, or a flaky
      // role lookup silently lands an approved expert in the athlete shell.
      expect(u.roleResolved, isFalse);
    });

    test('legacy fields never make an account look resolved', () {
      final forged = user(
        role: 'expert',
        roles: const ['expert', 'admin'],
        expertStatus: 'approved',
      );
      expect(forged.roleResolved, isFalse);
      expect(forged.isExpert, isFalse);
    });

    test('an athlete WITH a coach is still not an expert', () {
      // Receiving coaching lives in personal_coaching/coaching_plans and has
      // no bearing on the account's own role.
      final athlete = user(serverRole: 'user', role: 'athlete');
      expect(athlete.isExpert, isFalse);
      expect(athlete.roleResolved, isTrue);
    });
  });

group('the server answered', () {
    test('an approved expert resolves to expert', () async {
      final repo = repoReturning(() => [ok({'role': 'expert', 'isExpert': true})]);
      expect(await repo.fetchRole(), 'expert');
    });

    test('a normal user resolves to user', () async {
      final repo = repoReturning(() => [ok({'role': 'user', 'isExpert': false})]);
      expect(await repo.fetchRole(), 'user');
    });

    test('a half-answer is not enough to be an expert', () async {
      // isExpert true but role not 'expert' — both halves are required.
      final repo = repoReturning(() => [ok({'role': 'user', 'isExpert': true})]);
      expect(await repo.fetchRole(), 'user',
          reason: 'expert access needs the server to say expert outright');
    });

    test('401/403 is a verdict, not a failure — and is not retried', () async {
      final calls = <Uri>[];
      final repo = repoReturning(
        () => [http.Response('{"detail":"nope"}', 403)],
        calls: calls,
      );
      expect(await repo.fetchRole(), 'user');
      expect(calls.length, 1,
          reason: 'the server evaluated this caller; asking again is pointless');
    });
  });

group('the server did NOT answer', () {
    test('THE BUG: a 502 does not silently become "user"', () async {
      final repo = repoReturning(() => [http.Response('bad gateway', 502)]);
      expect(await repo.fetchRole(), isNull,
          reason: 'null means unresolved — the caller must hold, not route');
    });

    test('a network error does not silently become "user"', () async {
      final client = MockClient((_) async => throw const SocketishError());
      final repo = RoleRepository(
        apiClient: ApiClient(httpClient: client, baseUrl: 'https://api.test'),
      );
      expect(await repo.fetchRole(), isNull);
    });

    test('a 200 with an HTML body (captive portal) is unresolved', () async {
      final repo = repoReturning(() => [
            http.Response('<html>sign in to wifi</html>', 200,
                headers: {'content-type': 'text/html'}),
          ]);
      expect(await repo.fetchRole(), isNull,
          reason: 'a proxy page is not the server saying "user"');
    });

    test('it retries, and a later success still wins', () async {
      final calls = <Uri>[];
      final repo = repoReturning(
        () => [
          http.Response('bad gateway', 502),
          http.Response('bad gateway', 502),
          ok({'role': 'expert', 'isExpert': true}),
        ],
        calls: calls,
      );
      expect(await repo.fetchRole(), 'expert',
          reason: 'a transient blip must not cost an expert their dashboard');
      expect(calls.length, greaterThanOrEqualTo(3));
    });

    test('it gives up rather than guessing', () async {
      final calls = <Uri>[];
      final repo = repoReturning(
        () => [http.Response('bad gateway', 502)],
        calls: calls,
      );
      expect(await repo.fetchRole(), isNull);
      expect(calls.length, RoleRepository.retryDelays.length + 1,
          reason: 'every attempt is made before giving up');
    });
  });

group('the router refuses to guess', () {
    // A full router mount is not viable here: the destination screens build
    // Firebase/WebView platform objects in initState and the harness hangs.
    // The DECISION is what matters, so this pins the guard itself — the
    // redirect must key on roleResolved, not on resolvedRole, which reads
    // 'user' for an unresolved account because isExpert fails closed.
    final routerSrc = File('lib/app/router.dart').readAsStringSync();

    test('the redirect holds the splash while the role is unresolved', () {
      expect(routerSrc.contains('if (!authState.roleResolved)'), isTrue,
          reason: 'without this an unresolved role falls through to the '
              "resolvedRole branch and lands an expert on '/dashboard'");
      final guard = routerSrc.substring(
        routerSrc.indexOf('if (!authState.roleResolved)'),
      );
      expect(guard.contains("return onSplash ? null : '/splash';"), isTrue);
    });

    test('the guard runs BEFORE the role is read', () {
      expect(routerSrc.indexOf('if (!authState.roleResolved)'),
          lessThan(routerSrc.indexOf("final role = authState.profile?.resolvedRole")),
          reason: 'reading the role first would defeat the hold');
    });

    test('AuthState exposes what the guard and the splash need', () {
      final authSrc = File('lib/features/auth/auth_state.dart').readAsStringSync();
      expect(authSrc.contains('bool get roleResolved'), isTrue);
      expect(authSrc.contains('bool get roleResolutionFailed'), isTrue);
      expect(authSrc.contains('Future<void> retryRoleResolution()'), isTrue,
          reason: 'the splash offers a retry rather than stranding the user');
    });
  });
}

/// A transport failure that is not an HTTP status.
class SocketishError implements Exception {
  const SocketishError();
  @override
  String toString() => 'Connection closed before full header was received';
}
