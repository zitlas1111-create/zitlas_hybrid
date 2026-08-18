import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zitlas_mobile/features/support/data/support_repository.dart';

/// Pins the exact JSON body the app POSTs to `/api/support/contact`.
///
/// A build that sent only {subject, category, message} was answered
///     422  body.name  -> Field required
///          body.email -> Field required
/// by the backend that was live, and the athlete saw "Field required;
/// Field required" with no indication of which fields were missing.
///
/// `name` and `email` are REQUIRED by the contact schema and come from the
/// signed-in Firebase user — never re-typed, never invented. The matching
/// server-side assertions live in backend/tests/test_support.py
/// (CLIENT_CONTACT_BODY), so the two ends are checked against each other.

class _FakeUser extends Fake implements User {
  _FakeUser({this.displayName, this.email});
  @override
  final String? displayName;
  @override
  final String? email;
}

class _FakeAuth extends Fake implements FirebaseAuth {
  _FakeAuth(this._user);
  final User? _user;
  @override
  User? get currentUser => _user;
}

SupportRepository _repo({String? name, String? email}) => SupportRepository(
      auth: _FakeAuth(_FakeUser(displayName: name, email: email)),
    );

void main() {
  group('POST /api/support/contact body', () {
    test('carries every field the endpoint requires', () {
      final body = _repo(name: 'Test Athlete', email: 'athlete@example.com')
          .buildContactBody(
        subject: 'Diet plan help',
        category: 'Diet',
        message: 'Hello, I need help with my diet plan.',
      );

      // The five keys the schema declares. Missing name/email is the bug.
      expect(body.keys.toSet(),
          {'name', 'email', 'subject', 'category', 'message'});

      expect(body['name'], 'Test Athlete');
      expect(body['email'], 'athlete@example.com');
      expect(body['subject'], 'Diet plan help');
      expect(body['category'], 'Diet');
      expect(body['message'], 'Hello, I need help with my diet plan.');
    });

    test('every value is a String, as the schema declares', () {
      final body = _repo(name: 'A', email: 'a@b.com')
          .buildContactBody(subject: 's', category: 'c', message: 'm');
      for (final entry in body.entries) {
        expect(entry.value, isA<String>(), reason: entry.key);
      }
    });

    test('identity comes from the session, not from typed input', () {
      final body = _repo(name: 'Signed In User', email: 'signed@in.com')
          .buildContactBody(subject: 's', category: 'c', message: 'm');
      // The UI collects only subject/category/message; these two are derived.
      expect(body['name'], 'Signed In User');
      expect(body['email'], 'signed@in.com');
    });

    test('name is never empty — the schema enforces min_length 1', () {
      for (final n in <String?>[null, '', '   ']) {
        final body = _repo(name: n, email: 'a@b.com')
            .buildContactBody(subject: 's', category: 'c', message: 'm');
        expect((body['name'] as String).trim(), isNotEmpty,
            reason: 'displayName was ${n == null ? 'null' : '"$n"'}');
        expect(body['name'], 'ZITLAS Athlete');
      }
    });

    test('a signed-out user still produces a well-formed body', () {
      // Should not throw; the backend answers 401 on the token, which is a
      // far clearer failure than a client-side crash.
      final body = SupportRepository(auth: _FakeAuth(null))
          .buildContactBody(subject: 's', category: 'c', message: 'm');
      expect(body.keys.toSet(),
          {'name', 'email', 'subject', 'category', 'message'});
      expect(body['name'], 'ZITLAS Athlete');
      expect(body['email'], '');
    });

    test('whitespace around the display name is trimmed', () {
      final body = _repo(name: '  Padded Name  ', email: '  a@b.com  ')
          .buildContactBody(subject: 's', category: 'c', message: 'm');
      expect(body['name'], 'Padded Name');
      expect(body['email'], 'a@b.com');
    });

    test('the user-entered fields are passed through untouched', () {
      const message = 'Line one\nLine two — with an em dash & ampersand';
      final body = _repo(name: 'A', email: 'a@b.com').buildContactBody(
          subject: 'Subject with "quotes"',
          category: 'Technical Issue',
          message: message);
      expect(body['message'], message);
      expect(body['subject'], 'Subject with "quotes"');
      expect(body['category'], 'Technical Issue');
    });
  });
}
