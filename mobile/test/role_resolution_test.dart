import 'package:flutter_test/flutter_test.dart';
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
}
