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

  group('a signed-out device stops being a target', () {
    // THE HOLE THIS CLOSES. Tokens reach the backend from two places:
    // device_tokens/{token} (the registry, which knows about sessions) and
    // the legacy users/{uid}.pushTokens array (which does not). The backend
    // treats a token with NO registry row as an unverifiable website-only
    // device and still delivers to it — so DELETING the row at logout, which
    // is what this used to do, turned a signed-out phone back into a valid
    // target whenever the array still listed the token. The arrayRemove is a
    // separate write that can fail, and the website appends to that array
    // independently, so 'still listed' is the normal case, not the edge one.

    String fcm() => source('lib/core/notifications/fcm_service.dart');

    test('logout leaves a tombstone rather than deleting the row', () {
      final src = fcm();
      if (src.isEmpty) return;
      final body = src.substring(src.indexOf('Future<void> unregisterDevice'));
      expect(body.contains("'enabled': false"), isTrue,
          reason: 'logout must be something the registry STATES, not '
              'something it merely stops mentioning');
      expect(body.contains('.delete()'), isFalse,
          reason: 'deleting the row makes the token unverifiable, and an '
              'unverifiable token is still delivered to');
    });

    test('the tombstone still satisfies the security rule', () {
      final src = fcm();
      if (src.isEmpty) return;
      final body = src.substring(src.indexOf('Future<void> unregisterDevice'));
      // firestore.rules validates the POST-merge document and requires
      // uid == request.auth.uid and fcmToken is string. Relying on those
      // surviving from the stored doc would pass only by accident.
      expect(body.contains("'uid': uid"), isTrue);
      expect(body.contains("'fcmToken': token"), isTrue);
    });

    test('signing back in re-owns the row outright, clearing the tombstone', () {
      final src = fcm();
      if (src.isEmpty) return;
      final store = src.substring(src.indexOf('Future<void> _storeToken'));
      final setCall = store.substring(0, store.indexOf('});') + 3);
      expect(setCall.contains('SetOptions(merge: true)'), isFalse,
          reason: 'a merge would leave signedOutAt sitting beside '
              'enabled:true, and leave fields from a previous owner');
    });

    test('a full token is never logged', () {
      final src = fcm();
      if (src.isEmpty) return;
      // An FCM token is a credential: whoever holds it can push to that
      // device. Only a prefix may reach a log.
      final logs = RegExp(r"debugPrint\('\[FCM\][^']*'").allMatches(src);
      expect(logs, isNotEmpty);
      expect(src.contains(r'$token'), isFalse,
          reason: 'interpolating the raw token puts a credential in logcat');
    });

    test('the device declares that it can render its own notifications', () {
      // THE MIGRATION LEVER. The backend sends a data-only message only to a
      // device that claims this; everything else keeps the old FCM
      // notification block. Without the claim, a backend deploy would send
      // data-only messages to builds whose background handler only logs —
      // and every un-upgraded user would silently stop getting notifications
      // altogether. A backend deploy does not upgrade anyone's phone.
      final src = fcm();
      if (src.isEmpty) return;
      final store = src.substring(src.indexOf('Future<void> _storeToken'));
      expect(store.contains("'rendersOwnNotifications': true"), isTrue,
          reason: 'this build DOES render its own notifications and must say '
              'so, or it keeps receiving the un-branded FCM-drawn ones');
    });

    test('logout is visible in a release log', () {
      final src = fcm();
      if (src.isEmpty) return;
      expect(src.contains('[FCM] user logout'), isTrue);
      expect(src.contains('[FCM] notification session disabled'), isTrue);
    });

    test('re-login in the same session re-registers', () {
      final src = source('lib/app/app.dart');
      if (src.isEmpty) return;
      final gate = src.substring(src.indexOf('static void maybeInit'));
      final unauth = gate.substring(
          gate.indexOf('status != AuthStatus.authenticated'));
      final block = unauth.substring(0, unauth.indexOf('}'));
      expect(block.contains('_initializedForUid = null'), isTrue,
          reason: 'the latch is static and used to survive sign-out, so '
              'logging back into the SAME account without killing the app '
              'skipped registration entirely — that account then received no '
              'push at all until the process restarted');
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
