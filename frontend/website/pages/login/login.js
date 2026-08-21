﻿

'use strict';





const pwToggle = document.getElementById('pwToggle');
const pwInput  = document.getElementById('passwordInput');
const eyeIcon  = document.getElementById('eyeIcon');

const EYE_OPEN   = `<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/>`;
const EYE_CLOSED = `<path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/>`;

if (pwToggle && pwInput && eyeIcon) {
  pwToggle.addEventListener('click', () => {
    const hidden = pwInput.type === 'password';
    pwInput.type       = hidden ? 'text' : 'password';
    eyeIcon.innerHTML  = hidden ? EYE_CLOSED : EYE_OPEN;
    pwToggle.setAttribute('aria-label', hidden ? 'Hide password' : 'Show password');
  });
}



/* ONE ZITLAS LOGIN. There is no role selector, no expert login mode and no
   "Login as Expert" link — the sign-in form is identical for everybody.

   WHERE AN ACCOUNT LANDS IS DECIDED AFTER AUTHENTICATION, by the server:
   GET /api/auth/role reads the verified Firebase token's `expert` custom
   claim AND `experts/{uid}.approved`. `landingRole` below only ever holds
   that ANSWER — it is never an input, and nothing on this page can set it
   to 'expert'. */
let landingRole  = 'user';   // set from the server after sign-in
let isSignupMode = false;

const loginCardTitle = document.getElementById('loginCardTitle');
const loginCardSub   = document.getElementById('loginCardSub');

/* No role tabs and no "Login as Expert" link. One form, one flow. */



function setSignupMode(on) {
  isSignupMode = on;
  const nameGroup      = document.getElementById('nameGroup');
  const confirmPwGroup = document.getElementById('confirmPwGroup');
  const forgotRow      = document.querySelector('.lf-row-between');

  if (nameGroup)      nameGroup.style.display     = on ? '' : 'none';
  if (confirmPwGroup) confirmPwGroup.style.display = on ? '' : 'none';
  if (forgotRow)      forgotRow.style.display      = on ? 'none' : '';

  if (loginCardTitle) loginCardTitle.textContent = on ? 'Create Account' : 'Welcome Back';
  if (loginCardSub) loginCardSub.textContent = on
    ? 'Join ZITLAS - start your AI-powered fitness journey'
    : 'Sign in to continue your AI-powered fitness journey';
  if (loginBtnText) loginBtnText.textContent = on ? 'Create Account' : 'Sign In';
  if (createLink) createLink.textContent = on ? 'Already have an account? Sign In' : 'Create Account';
}



function getAuthErrorMsg(code) {
  var msgs = {
    'auth/user-not-found':         'No account found with this email.',
    'auth/wrong-password':         'Incorrect password. Please try again.',
    'auth/invalid-credential':     'Invalid email or password.',
    'auth/email-already-in-use':   'An account with this email already exists.',
    'auth/weak-password':          'Password must be at least 6 characters.',
    'auth/invalid-email':          'Please enter a valid email address.',
    'auth/too-many-requests':      'Too many attempts. Please try again later.',
    'auth/network-request-failed': 'Network error. Check your connection.',
  };
  return msgs[code] || 'Authentication failed. Please try again.';
}



/* ROOT CAUSE this whole block guards against — "log out as Athlete A, log in
   as Expert B, land on Athlete A's dashboard":
   The password sign-in path below never had its OWN redirect — it relied
   ENTIRELY on this passive listener firing for the FRESH sign-in. But this
   SAME listener also auto-redirects an ALREADY-signed-in user the instant
   this page loads (e.g. a session that was never genuinely Firebase
   signed-out). Both paths call the SAME async Firestore role lookup before
   redirecting, so if a stale pre-existing session's lookup is still in
   flight when the athlete submits fresh Expert B credentials, EITHER
   redirect can win the race — non-deterministically landing on the WRONG
   account's dashboard. `_explicitAuthInProgress`, checked both before AND
   after the async role lookup, makes this listener a NO-OP for the entire
   duration of an explicit sign-in attempt, so only that attempt's OWN
   (guaranteed-fresh) redirect can ever fire. */
let _explicitAuthInProgress = false;

/* Resolves 'expert' | 'athlete' | null (no users/{uid} doc yet) for `user`.
   The ONE role-determination rule — shared by the passive listener, the
   password sign-in path, and Google sign-in, so all three agree on what
   "expert" means and none of them can drift out of sync with the others. */
/* ── ROLE RESOLUTION IS SERVER-SIDE ────────────────────────────────────────
   Asks GET /api/auth/role, which derives the answer from the verified
   Firebase token's `expert` claim AND `experts/{uid}.approved`. Neither is
   writable from the browser.

   This replaces a client-side read of `users/{uid}`, which was wrong twice
   over: that document's `role`/`roles` fields are client-writable (the
   sign-up role modal set them), and the old logic treated `expert_pending`
   and `expert_status === 'pending'` as EXPERT — so merely applying landed
   you on the expert dashboard.

   Fails to 'user', never to 'expert': if the role cannot be established the
   safe answer is the one that grants nothing. Returns null only when there
   is no profile yet, preserving the caller's "nothing to redirect to" case. */
async function resolveRole(user) {
  const docSnap = await ZitlasDB.collection('users').doc(user.uid).get();
  if (!docSnap.exists) return null;

  const t = { email: user.email, uid: user.uid };
  try {
    /* FORCE A FRESH TOKEN — getIdTokenResult(TRUE), not the cached one.
       Firebase caches an ID token for up to an hour. A custom claim set
       after that token was minted is simply NOT IN IT, so the backend
       correctly sees no `expert` claim and answers "user". That is exactly
       why the three approved experts still landed on the user dashboard
       after being authorised: the claim was right, the token was stale.
       Every role decision must start from a freshly minted token. */
    const tokenResult = await user.getIdTokenResult(true);

    t.provider   = (user.providerData && user.providerData[0])
      ? user.providerData[0].providerId : 'password';
    t.expertClaim = tokenResult.claims.expert;
    t.issuedAt    = tokenResult.issuedAtTime;
    t.expiresAt   = tokenResult.expirationTime;

    const resp = await fetch('/api/auth/role', {
      headers: { 'Authorization': 'Bearer ' + tokenResult.token }
    });
    t.roleEndpointStatus = resp.status;

    let role = 'user';
    if (resp.ok) {
      const data = await resp.json();
      t.roleEndpointResponse = data;
      role = data.role === 'expert' ? 'expert' : 'user';
    } else {
      /* NOT a silent fallback: the failure is reported loudly and the role
         still degrades to 'user', because granting expert access on an
         unverifiable answer would be the worse bug. */
      t.roleEndpointResponse = '(non-OK response)';
      console.error('[AUTH] /api/auth/role FAILED with', resp.status,
                    '— cannot establish role, treating as user');
    }
    t.resolvedRole = role;
    _printAuthTrace(t);
    return role;
  } catch (e) {
    t.error = String(e && e.message || e);
    t.resolvedRole = 'user';
    _printAuthTrace(t);
    console.error('[AUTH] role lookup threw — treating as user', e);
    return 'user';
  }
}

/* The full picture in one block, for debugging a real sign-in.
   Deliberately never prints the ID TOKEN itself — only its claims and
   validity window. */
function _printAuthTrace(t) {
  var lines = [
    '[REAL AUTH TRACE]',
    '  Firebase email        : ' + t.email,
    '  Firebase UID          : ' + t.uid,
    '  provider              : ' + (t.provider || '(unknown)'),
    '  token expert claim    : ' + JSON.stringify(t.expertClaim),
    '  token issuedAt        : ' + (t.issuedAt || '-'),
    '  token expiration      : ' + (t.expiresAt || '-'),
    '  role endpoint URL     : /api/auth/role',
    '  role endpoint status  : ' + (t.roleEndpointStatus || '(not reached)'),
    '  role endpoint response: ' + JSON.stringify(t.roleEndpointResponse),
    '  resolvedRole          : ' + t.resolvedRole,
    '  final redirect        : ' + (t.resolvedRole === 'expert'
        ? '../experts/expert-dashboard.html'
        : '../dashboard/dashboard.html')
  ];
  if (t.error) lines.push('  ERROR                 : ' + t.error);
  console.log(lines.join('\n'));
}


if (typeof ZitlasAuth !== 'undefined') {
  ZitlasAuth.onAuthStateChanged(async function (user) {
    if (!user) return;
    if (_explicitAuthInProgress) return; // an explicit sign-in owns the redirect now
    console.log('[AUTH STATE] Firebase UID:', user.uid, ' Firebase email:', user.email, ' Firebase auth state: signed-in');
    try {
      const resolvedRole = await resolveRole(user);
      if (resolvedRole == null) return; // no profile doc yet — nothing to redirect to
      if (_explicitAuthInProgress) return; // re-check: an explicit sign-in may have started WHILE this was awaiting
      console.log('[AUTH STATE] Detected role:', resolvedRole, ' Profile UID:', user.uid);

      try {
        await ZitlasDB.collection('users').doc(user.uid).update({
          name:       user.displayName || '',
          photo:      user.photoURL    || null,
          last_login: firebase.firestore.FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      syncFirebaseUser(user, resolvedRole);

      const dest = resolvedRole === 'expert'
        ? '../experts/expert-dashboard.html'
        : (function () {
            const p = new URLSearchParams(window.location.search);
            const r = p.get('redirect');
            const q = sessionStorage.getItem('zitlas_pending_action');
            return (r === 'set-goal' || q === 'set-goal')
              ? '../dashboard/dashboard.html?action=set-goal'
              : '../dashboard/dashboard.html';
          }());
      console.log('[AUTH STATE] Redirect destination:', dest);
      window.location.replace(dest);
    } catch (e) {
      console.warn('[AUTH] onAuthStateChanged error:', e);
    }
  });
}



function getRedirectDestination() {
  /* `landingRole` is whatever GET /api/auth/role replied — never a choice
     made on this page. */
  if (landingRole === 'expert') {
    return '../experts/expert-dashboard.html';
  }
  const params   = new URLSearchParams(window.location.search);
  const redirect = params.get('redirect');
  const pending  = sessionStorage.getItem('zitlas_pending_action');

  if (redirect === 'set-goal' || pending === 'set-goal') {
    return '../dashboard/dashboard.html?action=set-goal';
  }
  return '../dashboard/dashboard.html';
}



const loginOverlay = document.getElementById('loginOverlay');

function showLoginOverlay() {
  if (!loginOverlay) return;
  const msgEl = loginOverlay.querySelector('.overlay-msg');
  if (msgEl) {
    msgEl.textContent = landingRole === 'expert'
      ? 'Expert Portal Loading'
      : 'Welcome back';
  }
  loginOverlay.removeAttribute('aria-hidden');
  loginOverlay.classList.add('active');
  const dest = getRedirectDestination();
 setTimeout(() => {
    sessionStorage.removeItem('zitlas_pending_action');

    // Try to open Flutter app
    window.location.href = "zitlas://login";

    // If app is not installed, continue website normally
    setTimeout(() => {
        window.location.href = dest;
    }, 1200);

}, 1900);
}



function setInputError(groupId) {
  const el = document.getElementById(groupId);
  if (!el) return;
  el.classList.add('input-error');
  el.addEventListener('animationend', () => el.classList.remove('input-error'), { once: true });
  el.querySelector('input')?.focus();
}

function clearInputError(groupId) {
  document.getElementById(groupId)?.classList.remove('input-error');
}



const loginForm      = document.getElementById('loginForm');
const loginBtn       = document.getElementById('loginBtn');
const loginBtnText   = document.getElementById('loginBtnText');
const loginBtnSpinner = document.getElementById('loginBtnSpinner');
const emailInput     = document.getElementById('emailInput');
const passwordInput  = document.getElementById('passwordInput');
const nameInput      = document.getElementById('nameInput');
const confirmPwInput = document.getElementById('confirmPwInput');
const rememberInput  = document.getElementById('rememberInput');

function setLoading(on) {
  if (!loginBtn) return;
  loginBtn.disabled = on;
  if (loginBtnText)   loginBtnText.style.opacity = on ? '0' : '1';
  if (loginBtnSpinner) loginBtnSpinner.classList.toggle('active', on);
}

if (emailInput)    emailInput.addEventListener('input',    () => clearInputError('emailGroup'));
if (passwordInput) passwordInput.addEventListener('input', () => clearInputError('passwordGroup'));

if (loginForm) {
  loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();

    const email     = emailInput?.value.trim()  || '';
    const password  = passwordInput?.value      || '';
    const name      = nameInput?.value.trim()   || '';
    const confirmPw = confirmPwInput?.value     || '';

    if (!email)    { setInputError('emailGroup');    return; }
    if (!password) { setInputError('passwordGroup'); return; }

    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      setInputError('emailGroup');
      showToast('Please enter a valid email address.');
      return;
    }

    if (typeof ZitlasAuth === 'undefined') {
      showToast('Firebase not configured. Please set up firebase-config.js.');
      return;
    }

    if (isSignupMode) {
      if (!name)                 { setInputError('nameGroup');      showToast('Please enter your full name.');           return; }
      if (password.length < 6)   { setInputError('passwordGroup'); showToast('Password must be at least 6 characters.'); return; }
      if (password !== confirmPw) { setInputError('confirmPwGroup'); showToast('Passwords do not match.');               return; }
    }

    setLoading(true);
    // From here on, this explicit attempt owns the redirect — see the
    // passive onAuthStateChanged listener above for why this matters.
    _explicitAuthInProgress = true;

    try {
      if (isSignupMode) {
        

        
        const existingMethods = await ZitlasAuth.fetchSignInMethodsForEmail(email);
        if (existingMethods.length > 0) {
          showToast('Account already exists. Please sign in.');
          setLoading(false);
          return;
        }

        
        
        const cred = await ZitlasAuth.createUserWithEmailAndPassword(email, password);
        const user = cred.user;

        
        try {
          await user.updateProfile({ displayName: name });
          const ts = firebase.firestore.FieldValue.serverTimestamp();

          /* Every new account is a USER. Expert onboarding is closed, and
             an expert is only ever created by an admin granting the claim
             plus `experts/{uid}.approved`. */
          await ZitlasDB.collection('users').doc(user.uid).set({
            uid: user.uid, email: user.email, name,
            role: 'athlete', photo: '', createdAt: ts,
          });
          syncEmailUser(user, name, 'athlete');
          landingRole = 'user';
          showLoginOverlay();
        } catch (firestoreErr) {
          
          console.warn('[AUTH] Firestore setup failed  deleting orphan Auth account', firestoreErr);
          try { await user.delete(); } catch (_) {}
          throw firestoreErr; 
        }
      } else {
        // Explicit sign-in owns its OWN redirect using THIS uid — it must
        // never depend on (or race against) the passive listener above,
        // which is exactly what let a stale previous session's redirect win
        // over a fresh Expert sign-in. See resolveRole()/the comment above.
        const cred = await ZitlasAuth.signInWithEmailAndPassword(email, password);
        const user = cred.user;
        if (rememberInput?.checked) localStorage.setItem('zitlas_remember', 'true');
        console.log('[LOGIN] New Firebase UID:', user.uid, ' New Firebase email:', user.email);

        const resolvedRole = await resolveRole(user);
        console.log('[LOGIN] New detected role:', resolvedRole);
        if (resolvedRole == null) {
          setLoading(false);
          _explicitAuthInProgress = false;
          showToast('Account setup incomplete. Please contact support.');
          return;
        }
        try {
          await ZitlasDB.collection('users').doc(user.uid).update({
            name:       user.displayName || '',
            photo:      user.photoURL    || null,
            last_login: firebase.firestore.FieldValue.serverTimestamp(),
          });
        } catch (_) {}
        syncFirebaseUser(user, resolvedRole);
        landingRole = resolvedRole;
        showLoginOverlay();
      }
    } catch (err) {
      setLoading(false);
      _explicitAuthInProgress = false; // this attempt failed — don't leave the passive listener disabled
      showToast(getAuthErrorMsg(err.code));
      if (['auth/user-not-found', 'auth/wrong-password', 'auth/invalid-credential'].includes(err.code)) {
        setInputError('emailGroup');
        setInputError('passwordGroup');
      } else if (err.code === 'auth/email-already-in-use') {
        setInputError('emailGroup');
      } else if (err.code === 'auth/weak-password') {
        setInputError('passwordGroup');
      }
    }
  });
}



const googleBtn = document.getElementById('googleBtn');

function setGoogleLoading(on) {
  if (!googleBtn) return;
  googleBtn.disabled       = on;
  googleBtn.style.opacity  = on ? '0.6' : '';
  googleBtn.style.cursor   = on ? 'wait' : '';
  const span = googleBtn.querySelector('span:last-of-type');
  if (span) span.textContent = on ? 'Signing in...' : 'Continue with Google';
}

if (googleBtn) {
  googleBtn.addEventListener('click', async () => {

    
    if (typeof ZitlasAuth === 'undefined') {
      showToast('Firebase not configured  fill in firebase-config.js first');
      return;
    }

    try {
      setGoogleLoading(true);
      // Same reasoning as the password path above — see the comment on
      // _explicitAuthInProgress near the passive onAuthStateChanged listener.
      _explicitAuthInProgress = true;

      const provider = new firebase.auth.GoogleAuthProvider();
      provider.setCustomParameters({ prompt: 'select_account' });

      const result = await ZitlasAuth.signInWithPopup(provider);
      const user   = result.user;
      console.log('[LOGIN] New Firebase UID:', user.uid, ' New Firebase email:', user.email);

      const resolvedRole = await resolveRole(user);

      if (resolvedRole != null) {
        console.log('[LOGIN] New detected role:', resolvedRole);
        try {
          await ZitlasDB.collection('users').doc(user.uid).update({
            name:       user.displayName || '',
            photo:      user.photoURL    || null,
            last_login: firebase.firestore.FieldValue.serverTimestamp(),
          });
        } catch (_) {}

        syncFirebaseUser(user, resolvedRole);
        landingRole = resolvedRole;
        showLoginOverlay();
      } else {
        
        console.log('[GOOGLE LOGIN] No users doc for uid=' + user.uid + '  checking experts by email');
        const expertByEmail = await ZitlasDB.collection('experts')
          .where('email', '==', user.email).limit(1).get();
        if (!expertByEmail.empty) {
          /* An `experts` row matching this email exists. That is a HINT, not
             an authorisation: the row is world-readable to signed-in users,
             so matching on it client-side would let anyone who knows an
             expert's address claim the role. Ask the server instead — it
             checks the custom claim AND `approved`. */
          console.log('[EXPERT MATCH] experts row found by email — verifying server-side');
          const verifiedRole = await resolveRole(user);
          await ZitlasDB.collection('users').doc(user.uid).set({
            uid: user.uid, name: user.displayName || '', email: user.email || '',
            photo: user.photoURL || null,
            created_at: firebase.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });
          syncFirebaseUser(user, verifiedRole || 'user');
          landingRole = verifiedRole || 'user';
          showLoginOverlay();
        } else {
          /* Brand-new Google account. Previously this opened a "Select
             Account Type" modal offering User or Expert. There is no choice
             to make any more: every new account is a user, and the only way
             to become an expert is an admin granting the claim. */
          await createUserProfile(user);
          landingRole = 'user';
          showLoginOverlay();
        }
      }

    } catch (err) {
      setGoogleLoading(false);
      _explicitAuthInProgress = false; // this attempt failed — don't leave the passive listener disabled
      if (err.code === 'auth/popup-closed-by-user' ||
          err.code === 'auth/cancelled-popup-request') return;
      console.error('[ZITLAS] Google sign-in error:', err);
      showToast(err.message || 'Sign-in failed. Please try again.');
    }
  });
}



/* "Skip for Now" (guest access without authentication) has been removed —
   ZITLAS requires a signed-in account. The only remaining zitlas_guest
   writer is the expert-application-under-review flow (grmReviewHomeBtn),
   where the user IS authenticated via Google. */

function _clearAuthLocalStorage() {
  ['zitlas_user','zitlas_user_role','zitlas_expert_profile','zitlas_expert_id',
   'zitlas_firebase_user','zitlas_token','loggedIn','currentUser','user',
   'zitlas_experts'
  ].forEach(function(k) { localStorage.removeItem(k); });
  console.log('[LOCAL STORAGE CLEARED]');
}





function syncFirebaseUser(user, role) {
  /* ACCOUNT GUARD — claim the local cache for this uid BEFORE writing any
     identity keys. If the cache belonged to a different account, every
     user-scoped key (plans, goal, membership, wallet, reviews…) is purged
     here, so the new session can never inherit — or re-upload — another
     user's data. See ZitlasAccountGuard in assets/js/firebase-config.js. */
  if (typeof ZitlasAccountGuard !== 'undefined') ZitlasAccountGuard.beginSession(user.uid);
  _clearAuthLocalStorage();
  console.log('[AUTH] syncFirebaseUser uid=' + user.uid + ' role=' + role);

  const provider = (user.providerData && user.providerData[0])
    ? user.providerData[0].providerId : 'password';

  localStorage.setItem('zitlas_user', JSON.stringify({
    uid:      user.uid,
    name:     user.displayName || '',
    email:    user.email       || '',
    photo:    user.photoURL    || null,
    provider: provider,
  }));
  localStorage.setItem('loggedIn', 'true');
  localStorage.setItem('zitlas_token',     'firebase_' + user.uid);
  localStorage.setItem('zitlas_user_role', role);

  if (role === 'expert') {
    localStorage.setItem('zitlas_expert_id', user.uid);
    
    localStorage.setItem('zitlas_expert_profile', JSON.stringify({
      id:    user.uid,
      name:  user.displayName    || '',
    }));
  }

  localStorage.setItem('zitlas_firebase_user', JSON.stringify({
    uid:   user.uid,
    name:  user.displayName  || '',
    email: user.email        || '',
    photo: user.photoURL     || null,
    role:  role,
  }));
}


function syncEmailUser(user, name, role) {
  /* ACCOUNT GUARD — same isolation claim as syncFirebaseUser above. */
  if (typeof ZitlasAccountGuard !== 'undefined') ZitlasAccountGuard.beginSession(user.uid);
  _clearAuthLocalStorage();
  console.log('[AUTH] syncEmailUser uid=' + user.uid + ' role=' + role);

  const userName = name || user.displayName || '';
  localStorage.setItem('zitlas_user', JSON.stringify({
    uid:      user.uid,
    name:     userName,
    email:    user.email || '',
    photo:    null,
    provider: 'password',
  }));
  localStorage.setItem('loggedIn',         'true');
  localStorage.setItem('zitlas_token',     'firebase_' + user.uid);
  localStorage.setItem('zitlas_user_role', role);

  if (role === 'expert') {
    localStorage.setItem('zitlas_expert_id', user.uid);
    
    localStorage.setItem('zitlas_expert_profile', JSON.stringify({
      id:    user.uid,
      name:  userName,
    }));
  }

  localStorage.setItem('zitlas_firebase_user', JSON.stringify({
    uid:   user.uid,
    name:  userName,
    email: user.email || '',
    photo: null,
    role:  role,
  }));

  if (rememberInput?.checked) localStorage.setItem('zitlas_remember', 'true');
}



let _pendingGoogleUser = null;

/* Creates the `users/{uid}` document for a brand-new account.
   Always a plain user: `roles: ['user']`, `expert_status: 'none'`. Nothing
   here can write an expert marker, and nothing reads these fields for
   authorisation anyway — GET /api/auth/role is the only authority. */
async function createUserProfile(user) {
  try {
    await ZitlasDB.collection('users').doc(user.uid).set({
      uid:           user.uid,
      name:          user.displayName || '',
      email:         user.email       || '',
      photo:         user.photoURL    || null,
      roles:         ['user'],
      expert_status: 'none',
      created_at:    firebase.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    syncFirebaseUser(user, 'user');
  } catch (err) {
    console.error('[ZITLAS] createUserProfile error:', err);
    showToast('Failed to set up your account. Please try again.');
    throw err;
  }
}





const createLink = document.getElementById('createLink');
if (createLink) {
  createLink.addEventListener('click', (e) => {
    e.preventDefault();
    setSignupMode(!isSignupMode);
  });
}

const forgotLink = document.getElementById('forgotLink');
if (forgotLink) {
  forgotLink.addEventListener('click', async (e) => {
    e.preventDefault();
    const email = emailInput?.value.trim() || '';
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      showToast('Enter your email address above, then click Forgot Password.');
      setInputError('emailGroup');
      return;
    }
    if (typeof ZitlasAuth === 'undefined') return;
    try {
      await ZitlasAuth.sendPasswordResetEmail(email);
      showToast('Password reset email sent! Check your inbox.');
    } catch (err) {
      showToast(getAuthErrorMsg(err.code));
    }
  });
}



let _toastEl, _toastTimer;

function showToast(msg) {
  if (!_toastEl) {
    _toastEl = document.createElement('div');
    _toastEl.style.cssText = [
      'position:fixed',
      'bottom:28px',
      'left:50%',
      'transform:translateX(-50%)',
      'background:var(--bg-card)',
      'border:1px solid var(--border)',
      'color:var(--text-primary)',
      'font-size:13px',
      'font-weight:600',
      'padding:11px 22px',
      'border-radius:40px',
      'box-shadow:0 4px 24px rgba(var(--black-rgb),0.5)',
      'z-index:10000',
      'opacity:0',
      'transition:opacity 0.22s ease',
      'pointer-events:none',
      'font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif',
      'white-space:nowrap',
    ].join(';');
    document.body.appendChild(_toastEl);
  }
  clearTimeout(_toastTimer);
  _toastEl.textContent = msg;
  _toastEl.style.opacity = '1';
  _toastTimer = setTimeout(() => { _toastEl.style.opacity = '0'; }, 2600);
}