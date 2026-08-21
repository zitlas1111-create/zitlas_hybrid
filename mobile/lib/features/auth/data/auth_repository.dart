import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../models/user_model.dart';
import 'auth_exception.dart';

/// The two possible outcomes of [AuthRepository.signInWithGoogle], mirroring
/// the branch in `login.js`'s Google click-handler: either the `users/{uid}`
/// doc already exists (nothing more to decide), or it doesn't and the
/// athlete/expert role-picker modal (`grmBackdrop`) must be shown before an
/// account can be created.
sealed class GoogleSignInOutcome {
  const GoogleSignInOutcome();
}

class GoogleSignInResolved extends GoogleSignInOutcome {
  const GoogleSignInResolved(this.profile);
  final UserModel profile;
}

class GoogleSignInNeedsRole extends GoogleSignInOutcome {
  const GoogleSignInNeedsRole(this.firebaseUser);
  final User firebaseUser;
}

/// Talks to the *existing* ZITLAS Firebase Auth + `users`/`experts`
/// Firestore collections — no parallel user database, no new schema.
/// Every write here matches a specific write in `frontend/pages/login/login.js`
/// field-for-field; see docs/MIGRATION_INVENTORY.md §3 for the collection map.
///
/// [auth]/[firestore] are nullable so this can be constructed even when
/// Firebase hasn't been registered for `com.zitlas.app` yet (see
/// docs/MIGRATION_INVENTORY.md §4) — [isAvailable] reports that state so the
/// UI can degrade gracefully instead of crashing.
class AuthRepository {
  // Kept as `auth:`/`firestore:` named params (not `this._auth` initializing
  // formals) so the public constructor API doesn't expose the private field
  // names it assigns to.
  AuthRepository({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth, // ignore: prefer_initializing_formals
      _firestore = firestore; // ignore: prefer_initializing_formals

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _firestore;

  bool get isAvailable => _auth != null && _firestore != null;

  // `GoogleSignIn.instance.initialize()` must be called exactly once before
  // any other GoogleSignIn method — cached so concurrent/repeated sign-in
  // attempts share the same initialization instead of re-calling it.
  // No clientId/serverClientId is passed: on Android this is auto-derived
  // from the web OAuth client (`client_type: 3`) already present in
  // android/app/google-services.json, per the google_sign_in_android
  // package's own README — nothing is hardcoded here.
  Future<void>? _googleSignInInit;
  Future<void> _ensureGoogleSignInInitialized() {
    return _googleSignInInit ??= GoogleSignIn.instance.initialize();
  }

  Stream<User?> authStateChanges() {
    final auth = _auth;
    if (auth == null) return const Stream.empty();
    return auth.authStateChanges();
  }

  Future<String?> currentIdToken() {
    return _requireAuth().currentUser?.getIdToken() ?? Future.value(null);
  }

  /// Resolves a signed-in [User] to its ZITLAS profile, touching
  /// `name`/`photo`/`last_login` exactly like the `onAuthStateChanged`
  /// listener does on every page load on web.
  Future<UserModel> fetchProfile(User user) async {
    final firestore = _requireFirestore();
    final doc = await firestore.collection('users').doc(user.uid).get();
    if (!doc.exists) {
      throw const AuthException('Account profile not found.');
    }
    unawaited(_touchLastLogin(firestore, user));
    return _profileFromDoc(user, doc.data()!);
  }

  Future<UserModel> signInWithEmail(String email, String password) async {
    final auth = _requireAuth();
    try {
      final cred = await auth.signInWithEmailAndPassword(email: email, password: password);
      return fetchProfile(cred.user!);
    } on FirebaseAuthException catch (e) {
      throw AuthException(mapFirebaseAuthErrorCode(e.code), code: e.code);
    }
  }

  /// Mirrors `login.js`'s signup branch exactly: pre-checks, create Auth
  /// user, write `users/{uid}` (+ `experts/{uid}` for experts), and roll
  /// back the orphaned Auth account if the Firestore writes fail.
  Future<UserModel> signUpWithEmail({
    required String email,
    required String password,
    required String name,
    required String role, // 'athlete' | 'expert'
  }) async {
    final auth = _requireAuth();
    final firestore = _requireFirestore();

    // login.js also pre-checks `fetchSignInMethodsForEmail` before signup;
    // that API is unavailable on current firebase_auth (Google removed it
    // for email-enumeration-protection reasons). We rely on
    // `createUserWithEmailAndPassword` throwing `email-already-in-use`
    // instead — same user-facing outcome via mapFirebaseAuthErrorCode.
    if (role == 'expert') {
      final existingExpert = await firestore
          .collection('experts')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (existingExpert.docs.isNotEmpty) {
        throw const AuthException('Expert account already exists. Please sign in.');
      }
    }

    final User user;
    try {
      final cred = await auth.createUserWithEmailAndPassword(email: email, password: password);
      user = cred.user!;
    } on FirebaseAuthException catch (e) {
      throw AuthException(mapFirebaseAuthErrorCode(e.code), code: e.code);
    }

    try {
      await user.updateDisplayName(name);
      final ts = FieldValue.serverTimestamp();

      if (role == 'expert') {
        await firestore.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': user.email,
          'name': name,
          'role': 'expert',
          'photo': '',
          'createdAt': ts,
        });
        await firestore.collection('experts').doc(user.uid).set({
          'uid': user.uid,
          'email': user.email,
          'name': name,
          'role': 'expert',
          'speciality': '',
          'photo': '',
          'verified': false,
          'approved': false,
          'rating': 0,
          'reviews': 0,
          'createdAt': ts,
        });
      } else {
        await firestore.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': user.email,
          'name': name,
          'role': 'athlete',
          'photo': '',
          'createdAt': ts,
        });
      }
    } catch (firestoreErr) {
      try {
        await user.delete();
      } catch (_) {}
      throw const AuthException('Failed to set up your account. Please try again.');
    }

    return UserModel(
      uid: user.uid,
      email: user.email ?? email,
      name: name,
      role: role,
      expertStatus: role == 'expert' ? 'pending' : 'none',
    );
  }

  /// Native Android/iOS Google sign-in: the `google_sign_in` package drives
  /// the platform account picker (Credential Manager on Android) to get an
  /// ID token, which is then exchanged for a Firebase credential — this
  /// never opens a browser/Custom Tab, unlike `FirebaseAuth.signInWithProvider`
  /// (which was the Phase 2 implementation; it round-trips through a
  /// `firebaseapp.com` web page that depends on Chrome's sessionStorage, and
  /// broke with "missing initial state" on this device — that flow was
  /// removed, not patched, per instructions).
  ///
  /// After obtaining the Firebase user, mirrors the Google click-handler in
  /// `login.js`: look up `users/{uid}`. If it exists, resolve+return. If
  /// not, check `experts` by email (edge case: an expert record predates
  /// this uid's users doc). Otherwise the caller must show the role picker.
  Future<GoogleSignInOutcome> signInWithGoogle() async {
    final auth = _requireAuth();
    final firestore = _requireFirestore();

    final User user;
    try {
      await _ensureGoogleSignInInitialized();
      final googleAccount = await GoogleSignIn.instance.authenticate();
      final idToken = googleAccount.authentication.idToken;
      if (idToken == null) {
        throw const AuthException('Google sign-in did not return an identity token.');
      }
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final cred = await auth.signInWithCredential(credential);
      user = cred.user!;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        throw const AuthCancelledException();
      }
      throw AuthException(mapGoogleSignInErrorCode(e.code), code: e.code.name);
    } on FirebaseAuthException catch (e) {
      throw AuthException(mapFirebaseAuthErrorCode(e.code), code: e.code);
    }

    final doc = await firestore.collection('users').doc(user.uid).get();
    if (doc.exists) {
      unawaited(_touchLastLogin(firestore, user));
      return GoogleSignInResolved(_profileFromDoc(user, doc.data()!));
    }

    final expertByEmail = await firestore
        .collection('experts')
        .where('email', isEqualTo: user.email)
        .limit(1)
        .get();
    if (expertByEmail.docs.isNotEmpty) {
      await firestore.collection('users').doc(user.uid).set({
        'uid': user.uid,
        'name': user.displayName ?? '',
        'email': user.email ?? '',
        'photo': user.photoURL,
        'role': 'expert',
        'created_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return GoogleSignInResolved(
        UserModel(
          uid: user.uid,
          email: user.email ?? '',
          name: user.displayName,
          photoUrl: user.photoURL,
          role: 'expert',
        ),
      );
    }

    return GoogleSignInNeedsRole(user);
  }

  /// Mirrors the role-picker modal's confirm handler. Note: an expert
  /// choice here only sets `expert_status: 'pending'` on `users/{uid}` — it
  /// does NOT create an `experts/{uid}` doc (that only happens via the
  /// email/password expert-signup path). This is real production behavior,
  /// not an oversight — see docs/MIGRATION_INVENTORY.md §2.
  Future<UserModel> completeGoogleRoleSelection(User user, String chosenRole) async {
    final firestore = _requireFirestore();
    /* `chosenRole` is vestigial — the caller always passes 'user' now that
       the role picker is gone. A brand-new account is ALWAYS a plain user:
       nothing here can write 'expert_pending' or an 'experts/{uid}' row, and
       these fields are not an authorisation signal anyway (GET /api/auth/role
       is). Kept in the signature so the call sites and their tests stay
       stable. */
    const roles = ['user'];
    const expertStatus = 'none';

    await firestore.collection('users').doc(user.uid).set({
      'uid': user.uid,
      'name': user.displayName ?? '',
      'email': user.email ?? '',
      'photo': user.photoURL,
      'roles': roles,
      'expert_status': expertStatus,
      'created_at': FieldValue.serverTimestamp(),
    });

    return UserModel(
      uid: user.uid,
      email: user.email ?? '',
      name: user.displayName,
      photoUrl: user.photoURL,
      role: 'user',
      roles: roles,
      expertStatus: expertStatus,
    );
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _requireAuth().sendPasswordResetEmail(email: email);
    } on FirebaseAuthException catch (e) {
      throw AuthException(mapFirebaseAuthErrorCode(e.code), code: e.code);
    }
  }

  /// Signs out of both Firebase and Google. The Google half matters even
  /// though `google_sign_in`'s Credential Manager flow always shows an
  /// account chooser (unlike the old browser-cookie-based flow, it doesn't
  /// silently reuse a session) — but signing out here still revokes this
  /// app's lightweight-auth state so a fresh `authenticate()` always starts
  /// clean, matching the "another Google account can be selected later"
  /// requirement.
  Future<void> signOut() async {
    await _requireAuth().signOut();
    try {
      await _ensureGoogleSignInInitialized();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Best-effort — the Firebase sign-out above is what actually matters
      // for app auth state; a Google-side sign-out failure shouldn't block
      // logout.
    }
  }

  UserModel _profileFromDoc(User user, Map<String, dynamic> data) {
    return UserModel(
      uid: user.uid,
      email: (data['email'] as String?) ?? user.email ?? '',
      name: (data['name'] as String?) ?? user.displayName,
      photoUrl: (data['photo'] as String?) ?? user.photoURL,
      role: (data['role'] as String?) ?? 'athlete',
      roles: (data['roles'] as List?)?.cast<String>() ?? const [],
      expertStatus: (data['expert_status'] as String?) ?? 'none',
    );
  }

  Future<void> _touchLastLogin(FirebaseFirestore firestore, User user) async {
    try {
      await firestore.collection('users').doc(user.uid).update({
        'name': user.displayName ?? '',
        'photo': user.photoURL,
        'last_login': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Best-effort, matches the swallowed catch around the equivalent
      // `.update()` call in login.js.
    }
  }

  FirebaseAuth _requireAuth() {
    final auth = _auth;
    if (auth == null) {
      throw const AuthException('Firebase is not configured for this build yet.');
    }
    return auth;
  }

  FirebaseFirestore _requireFirestore() {
    final firestore = _firestore;
    if (firestore == null) {
      throw const AuthException('Firebase is not configured for this build yet.');
    }
    return firestore;
  }
}
