/* ══════════════════════════════════════════════════════════
   ZITLAS — Firebase Configuration
   Firebase project: zitlas-b8677 (shared with ZITLAS Hiring)
   SDK: Firebase v10 compat (same API surface as v8)

   Firestore security rules required in Firebase Console:
   ──────────────────────────────────────────────────────
   rules_version = '2';
   service cloud.firestore {
     match /databases/{database}/documents {
       match /users/{userId} {
         allow read, write: if request.auth != null && request.auth.uid == userId;
       }
     }
   }
   ══════════════════════════════════════════════════════════ */

'use strict';

var FIREBASE_CONFIG = {
  apiKey:            "AIzaSyAR4Q0Ldur2Y2N8iHwsAmPS4V2cWCvf_pg",
  authDomain:        "zitlas-b8677.firebaseapp.com",
  projectId:         "zitlas-b8677",
  storageBucket:     "zitlas-b8677.firebasestorage.app",
  messagingSenderId: "203730393646",
  appId:             "1:203730393646:web:f1f4776d8b0d1134bf1dbf",
  measurementId:     "G-MK3CYXXS8Q"
};

/* Guard against double-init on multi-page navigation */
if (!firebase.apps.length) {
  firebase.initializeApp(FIREBASE_CONFIG);
}

/* Global singletons — used across login.js, profile.js, dashboard.js */
var ZitlasAuth = firebase.auth();
var ZitlasDB   = firebase.firestore();

/* Firebase Storage — only defined on pages that also load
   firebase-storage-compat.js (currently just expert-dashboard.html, the
   only page that uploads a file). Guarded so every other page — which
   loads this same firebase-config.js but not the storage SDK — doesn't
   throw on `firebase.storage` being undefined. */
var ZitlasStorage = (typeof firebase.storage === 'function') ? firebase.storage() : null;

/* Persist login across tabs and page reloads */
ZitlasAuth.setPersistence(firebase.auth.Auth.Persistence.LOCAL);

/* ── Release this browser's push session BEFORE signing out ──────────────
   A logged-out browser must stop receiving ZITLAS notifications. Marking it
   inactive is an owner-only Firestore write, so it has only one valid window:
   BEFORE firebase.auth().signOut() tears the auth context down. Afterwards
   the security rules reject it and the device would stay listed as active
   forever — which is exactly how a user who logged out yesterday kept
   receiving pushes.

   Wrapping the singleton (rather than every call site) is deliberate:
   sign-out is invoked from profile.js, expert-dashboard.js, admin-portal.js
   and webview-bridge.js, and `ZitlasAuth === firebase.auth()`, so patching
   the instance covers all four — including the ones that call
   firebase.auth().signOut() directly. push-notifications.js is NOT loaded on
   most of those pages, which is why this cannot live there.

   Registry semantics match the app's (fcm_service.dart unregisterDevice):
   enabled:false, never a delete. The backend treats a token with no registry
   row as an unverifiable device, so a tombstone is stronger than a deletion.

   Best-effort and non-blocking on failure: signing out must always finish. */
(function wrapSignOutForPush(auth) {
  if (!auth || auth.__zitlasPushSignOutWrapped) return;
  auth.__zitlasPushSignOutWrapped = true;

  var nativeSignOut = auth.signOut.bind(auth);
  /* 'uid|token' this page has already tried to release, and whether it
     worked — so a logout that releases early (below) and then signs out does
     not write twice, and never retries against a terminated client. */
  var attemptedFor = null;
  var releasedFor = null;

  /* Exposed because a logout flow that TERMINATES Firestore to stop its
     listeners (profile.js, expert-dashboard.js) must release the push session
     BEFORE doing so. Once firestore().terminate() has run, the write below
     cannot run at all: it failed silently, and a logged-out user went on
     receiving that account's notifications in this browser.

     Never rejects and never hangs — a stuck write (offline) gives up after a
     few seconds, because signing out must always finish. Resolves true once
     this device has been released. */
  auth.releasePushSession = function () {
    try {
      var uid = auth.currentUser && auth.currentUser.uid;
      var token = null;
      try { token = localStorage.getItem('zitlas_push_token'); } catch (_) {}

      if (!uid || !token || typeof ZitlasDB === 'undefined') return Promise.resolve(false);
      var key = uid + '|' + token;
      if (attemptedFor === key) return Promise.resolve(releasedFor === key);
      attemptedFor = key;

      var now = new Date().toISOString();
      var writes = Promise.all([
        ZitlasDB.collection('device_tokens').doc(token).set({
          fcmToken: token,
          uid: uid,
          enabled: false,
          loggedIn: false,
          signedOutAt: now,
        }, { merge: true }),
        ZitlasDB.collection('users').doc(uid).set({
          pushTokens: firebase.firestore.FieldValue.arrayRemove(token),
        }, { merge: true }),
      ]).then(function () {
        releasedFor = key;
        console.log('[PUSH] device released from ' + uid + ' before sign-out');
        return true;
      }).catch(function (e) {
        console.warn('[PUSH] sign-out cleanup failed (non-fatal)', e);
        return false;
      });
      return Promise.race([
        writes,
        new Promise(function (r) { setTimeout(function () { r(false); }, 4000); }),
      ]);
    } catch (e) {
      console.warn('[PUSH] sign-out cleanup could not run (non-fatal)', e);
      return Promise.resolve(false);
    }
  };

  auth.signOut = function () {
    return auth.releasePushSession().then(nativeSignOut, nativeSignOut);
  };
})(ZitlasAuth);

/* Firebase ID token for authenticated backend calls (/api/coaching/*, the
   first backend routes in this codebase that verify a real caller identity
   server-side instead of trusting a client-supplied uid). Rejects instead
   of resolving null so a caller can't silently fetch() with a bad/missing
   Authorization header. */
function getIdToken() {
  return ZitlasAuth.currentUser
    ? ZitlasAuth.currentUser.getIdToken()
    : Promise.reject(new Error('not_signed_in'));
}

/* Diagnostic — confirms every page is talking to the same Firebase app/project.
   Compare projectId across the athlete and expert consoles when debugging sync issues. */
console.log('[FIREBASE] app options', firebase.app().options);
console.log('[FIREBASE] apps', firebase.apps);
console.log('[FIREBASE] firestore instance', ZitlasDB);

/* ══════════════════════════════════════════════════════════
   ZITLAS ACCOUNT GUARD — multi-user data isolation
   ══════════════════════════════════════════════════════════
   ROOT CAUSE THIS FIXES: the whole app is localStorage-first with
   GLOBAL key names (zitlas_diet_plan, zitlas_membership, zitlas_goal,
   zitlas_wallet, expert_plan_reviews, …), and login/logout only ever
   cleared ~10 auth/identity keys. localStorage is per-BROWSER, not
   per-user — so when account B signed in after account A on the same
   device, B inherited A's entire cache (plans, goal, premium, wallet,
   reviews), and cloud-sync then UPLOADED A's leftovers into
   users/{B.uid}, making the leak permanent and cross-device.

   THE FIX: one owner stamp (zitlas_cache_owner_uid) + one purge
   choke point, enforced from this file because it loads on every
   Firebase page BEFORE all app scripts. If the signed-in uid differs
   from the cache owner, every user-scoped key is wiped before any
   page code can read — or re-upload — another account's data.
   Firestore itself was already correctly per-uid everywhere; this
   closes the local-cache layer. Runs three ways:
     1. parse-time (below) — before the page's own scripts read anything
     2. onAuthStateChanged — catches a stale/absent local identity
     3. beginSession(uid) — called by login.js the moment sign-in succeeds
   Logout calls clearUserCache() (full purge, identity included). */
var ZitlasAccountGuard = (function () {
  var OWNER_KEY = 'zitlas_cache_owner_uid';

  /* Device/UI-scoped keys that legitimately survive an account switch.
     EVERYTHING else in localStorage is treated as user data and purged —
     deny-by-default, so a future feature that forgets to namespace its
     key is still isolated. */
  var KEEP_KEYS = [
    OWNER_KEY,
    'zitlas_theme',           /* display preference */
    'zitlas_language',        /* i18n preference */
    'zitlas_trial_mode',      /* platform-wide flag, not user data */
    'zitlas_step_perm_state', /* device sensor permission state */
    'zitlas_remember',        /* login-form convenience */
  ];
  /* Identity keys login.js writes for the CURRENT session — preserved
     during a switch-purge only when they already belong to the new uid
     (login writes them before navigation; wiping them would render the
     fresh session logged-out). */
  var IDENTITY_KEYS = ['zitlas_user', 'zitlas_firebase_user', 'zitlas_token',
    'zitlas_user_role', 'loggedIn', 'zitlas_expert_id', 'zitlas_expert_profile'];

  function _localUid() {
    try {
      var fb = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      return (fb && fb.uid) || null;
    } catch (_) { return null; }
  }

  function purgeUserData(preserveIdentityForUid) {
    var preserved = {};
    if (preserveIdentityForUid && _localUid() === preserveIdentityForUid) {
      IDENTITY_KEYS.forEach(function (k) {
        var v = localStorage.getItem(k);
        if (v !== null) preserved[k] = v;
      });
    }
    var removed = 0;
    for (var i = localStorage.length - 1; i >= 0; i--) {
      var key = localStorage.key(i);
      if (key == null) continue;
      if (KEEP_KEYS.indexOf(key) !== -1) continue;
      /* Never touch the Firebase SDK's own persistence entries — purging
         them would sign the NEW user out mid-switch. */
      if (key.indexOf('firebase:') === 0 || key.indexOf('__sak') === 0) continue;
      localStorage.removeItem(key);
      removed++;
    }
    Object.keys(preserved).forEach(function (k) {
      try { localStorage.setItem(k, preserved[k]); } catch (_) {}
    });
    try { sessionStorage.clear(); } catch (_) {}
    console.warn('[ACCOUNT GUARD] purged ' + removed + ' user-scoped storage key(s)');
  }

  /* Claim the cache for `uid`. Purges first if it belonged to a
     different account. Returns true when a purge happened. */
  function beginSession(uid) {
    if (!uid) return false;
    var owner = null;
    try { owner = localStorage.getItem(OWNER_KEY); } catch (_) {}
    if (owner === uid) return false;
    var purged = false;
    if (owner && owner !== uid) {
      console.warn('[ACCOUNT GUARD] account switch detected (' + owner + ' → ' + uid + ') — isolating user data');
      purgeUserData(uid);
      purged = true;
    }
    /* No recorded owner (first run after this deploy): adopt the current
       uid WITHOUT purging, so existing single-user devices keep their
       offline cache. */
    try { localStorage.setItem(OWNER_KEY, uid); } catch (_) {}
    return purged;
  }

  /* Logout: full purge including identity keys + release ownership. */
  function clearUserCache() {
    purgeUserData(null);
    try { localStorage.removeItem(OWNER_KEY); } catch (_) {}
  }

  /* 1 — parse-time enforcement: this file loads before every page's own
     scripts, so a mismatch is resolved before anything renders. */
  beginSession(_localUid());

  /* 2 — auth-listener enforcement: authoritative uid from Firebase. If a
     mismatch surfaces only now (stale/absent zitlas_firebase_user), the
     page may already have rendered the previous account's data — purge
     and reload so it re-boots clean and hydrates the right account. */
  ZitlasAuth.onAuthStateChanged(function (user) {
    if (!user) return;
    var owner = null;
    try { owner = localStorage.getItem(OWNER_KEY); } catch (_) {}
    if (owner && owner !== user.uid) {
      console.warn('[ACCOUNT GUARD] signed-in uid differs from cache owner — purging and reloading');
      purgeUserData(user.uid);
      try { localStorage.setItem(OWNER_KEY, user.uid); } catch (_) {}
      window.location.reload();
      return;
    }
    if (!owner) {
      try { localStorage.setItem(OWNER_KEY, user.uid); } catch (_) {}
    }
  });

  return {
    beginSession:   beginSession,
    purgeUserData:  purgeUserData,
    clearUserCache: clearUserCache,
  };
})();
