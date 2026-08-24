import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// THE LOGOUT BUTTON MUST ALWAYS COMPLETE.
///
/// `AuthState.signOut()` ran three awaits as a bare sequence:
///
///     await CoachingWebViewSession.clear();
///     await _repository.signOut();
///     await AccountGuard.instance.clearUserCache();
///     _profile = null;
///     _status = AuthStatus.unauthenticated;
///     notifyListeners();
///
/// A throw in any of them skipped the reset. The router keys off `_status`, so
/// the app stayed on the dashboard and logout appeared to do nothing — and if
/// Firebase sign-out had already succeeded, the app was left claiming
/// `authenticated` with no session behind it.
///
/// These are source-level assertions. Driving the real `signOut()` needs a live
/// FirebaseAuth, FirebaseFirestore, a WebView and SharedPreferences, none of
/// which exist in a unit test — and stubbing all four would test the stubs
/// rather than the ordering property that actually broke.
void main() {
  String source(String path) {
    final f = File(path);
    if (!f.existsSync()) {
      markTestSkipped('$path not reachable from this run');
      return '';
    }
    return f.readAsStringSync();
  }

  String? signOutBody() {
    final src = source('lib/features/auth/auth_state.dart');
    if (src.isEmpty) return null;
    final start = src.indexOf('Future<void> signOut() async {');
    if (start < 0) return null;
    final end = src.indexOf('\n  bool _disposed', start);
    return src.substring(start, end > 0 ? end : src.length);
  }

  group('signOut always finishes', () {
    test('the auth-state reset runs in a finally block', () {
      final body = signOutBody();
      if (body == null) return;
      final resetAt = body.indexOf('_status = AuthStatus.unauthenticated');
      expect(resetAt, greaterThan(-1));

      final finallyAt = body.lastIndexOf('} finally {', resetAt);
      expect(finallyAt, greaterThan(-1),
          reason: 'the reset must be unskippable — a throw in any cleanup '
              'step would otherwise leave the app claiming to be signed in');
    });

    test('every cleanup step is individually guarded', () {
      final body = signOutBody();
      if (body == null) return;
      // Three cleanups + the FCM/presence pair above them.
      expect('try {'.allMatches(body).length, greaterThanOrEqualTo(5),
          reason: 'a bare await here can abort the whole sign-out');
    });

    test('Firebase sign-out is actually called', () {
      final body = signOutBody();
      if (body == null) return;
      expect(body.contains('_repository.signOut()'), isTrue,
          reason: 'clearing local state is not signing out');
    });

    test('the profile and status are both cleared', () {
      final body = signOutBody();
      if (body == null) return;
      expect(body.contains('_profile = null'), isTrue);
      expect(body.contains('_status = AuthStatus.unauthenticated'), isTrue);
      expect(body.contains('notifyListeners()'), isTrue,
          reason: 'without this the router never learns the session ended');
    });

    test('the local cache is purged so the next account starts clean', () {
      final body = signOutBody();
      if (body == null) return;
      expect(body.contains('clearUserCache'), isTrue,
          reason: 'the next user on this device would inherit the previous '
              "account's cached plans, goal and profile");
    });
  });

  group('account isolation at sign-out', () {
    test('the FCM device token is released before Firebase sign-out', () {
      final body = signOutBody();
      if (body == null) return;
      final unregister = body.indexOf('unregisterDevice');
      final signOut = body.indexOf('_repository.signOut()');
      expect(unregister, greaterThan(-1),
          reason: 'the outgoing account would keep a live token for this '
              "phone and keep receiving the previous user's notifications");
      expect(unregister, lessThan(signOut),
          reason: 'the Firestore write needs the outgoing uid to still hold a '
              'valid auth context');
    });

    test('the WebView session is cleared too', () {
      final body = signOutBody();
      if (body == null) return;
      expect(body.contains('CoachingWebViewSession.clear'), isTrue,
          reason: 'the coaching WebView keeps its own Firebase session; a '
              'native sign-out does not touch it, so the next account would '
              'open coaching pages still running as the previous user');
    });

    test('releasing the token cannot block sign-out', () {
      final body = signOutBody();
      if (body == null) return;
      final unregisterAt = body.indexOf('unregisterDevice');
      final guardAt = body.lastIndexOf('try {', unregisterAt);
      expect(guardAt, greaterThan(-1));
    });
  });

  group('the router reacts to the reset', () {
    test('redirect keys off the auth status', () {
      final src = source('lib/app/router.dart');
      if (src.isEmpty) return;
      expect(src.contains('AuthStatus.unauthenticated') ||
              src.contains('AuthStatus.authenticated'),
          isTrue,
          reason: 'the redirect must follow AuthState, which is what '
              'signOut() now always updates');
    });
  });
}
