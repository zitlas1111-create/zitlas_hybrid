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



let selectedRole = 'athlete';
let isSignupMode = false;

const roleTabAthlete = document.getElementById('roleTabAthlete');
const roleTabExpert  = document.getElementById('roleTabExpert');
const expertHintBtn  = document.getElementById('expertHintBtn');
const expertHint     = document.getElementById('expertHint');
const loginCardTitle = document.getElementById('loginCardTitle');
const loginCardSub   = document.getElementById('loginCardSub');
function setRole(role) {
  selectedRole = role;
  if (roleTabAthlete) roleTabAthlete.classList.toggle('active', role === 'athlete');
  if (roleTabExpert)  roleTabExpert.classList.toggle('active',  role === 'expert');
  if (expertHint)     expertHint.style.display = (role === 'expert' || isSignupMode) ? 'none' : '';
  if (loginCardTitle) loginCardTitle.textContent = isSignupMode
    ? (role === 'expert' ? 'Create Expert Account' : 'Create Account')
    : (role === 'expert' ? 'Expert Login' : 'Welcome Back');
  if (loginCardSub)   loginCardSub.textContent = isSignupMode
    ? 'Join ZITLAS - start your AI-powered fitness journey'
    : (role === 'expert' ? 'Sign in to your ZITLAS Expert Portal' : 'Sign in to continue your AI-powered fitness journey');
  if (emailInput)    emailInput.placeholder = role === 'expert' ? 'Expert Email' : 'Email or Mobile Number';
  if (loginBtnText) loginBtnText.textContent = isSignupMode
    ? (role === 'expert' ? 'Create Expert Account' : 'Create Account')
    : (role === 'expert' ? 'Expert Login' : 'Sign In');
}

if (roleTabAthlete) roleTabAthlete.addEventListener('click', () => setRole('athlete'));
if (roleTabExpert)  roleTabExpert.addEventListener('click',  () => setRole('expert'));
if (expertHintBtn)  expertHintBtn.addEventListener('click',  () => {
  setRole('expert');
  document.getElementById('emailInput')?.focus();
});



function setSignupMode(on) {
  isSignupMode = on;
  const nameGroup      = document.getElementById('nameGroup');
  const confirmPwGroup = document.getElementById('confirmPwGroup');
  const forgotRow      = document.querySelector('.lf-row-between');

  if (nameGroup)      nameGroup.style.display     = on ? '' : 'none';
  if (confirmPwGroup) confirmPwGroup.style.display = on ? '' : 'none';
  if (forgotRow)      forgotRow.style.display      = on ? 'none' : '';

  if (loginCardTitle) loginCardTitle.textContent = on
    ? (selectedRole === 'expert' ? 'Create Expert Account' : 'Create Account')
    : (selectedRole === 'expert' ? 'Expert Login' : 'Welcome Back');
  if (loginCardSub) loginCardSub.textContent = on
    ? 'Join ZITLAS - start your AI-powered fitness journey'
    : (selectedRole === 'expert' ? 'Sign in to your ZITLAS Expert Portal' : 'Sign in to continue your AI-powered fitness journey');
  if (loginBtnText) loginBtnText.textContent = on
    ? (selectedRole === 'expert' ? 'Create Expert Account' : 'Create Account')
    : (selectedRole === 'expert' ? 'Expert Login' : 'Sign In');
  if (createLink) createLink.textContent = on ? 'Already have an account? Sign In' : 'Create Account';
  if (expertHint) expertHint.style.display = (on || selectedRole === 'expert') ? 'none' : '';
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

  try {
    const token = await user.getIdToken();
    const resp  = await fetch('/api/auth/role', {
      headers: { 'Authorization': 'Bearer ' + token }
    });
    if (resp.ok) {
      const data = await resp.json();
      console.log('[AUTH] server role =', data.role, 'isExpert =', data.isExpert);
      return data.role === 'expert' ? 'expert' : 'user';
    }
    console.warn('[AUTH] /api/auth/role returned', resp.status, '— treating as user');
  } catch (e) {
    console.warn('[AUTH] role lookup failed — treating as user', e);
  }
  return 'user';
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
  if (selectedRole === 'expert') {
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
    msgEl.textContent = selectedRole === 'expert'
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

        
        if (selectedRole === 'expert') {
          const existingExpert = await ZitlasDB.collection('experts')
            .where('email', '==', email).limit(1).get();
          if (!existingExpert.empty) {
            console.log('[EXPERT FOUND] by email before signup  aborting account creation');
            showToast('Expert account already exists. Please sign in.');
            setLoading(false);
            return;
          }
        }

        
        const cred = await ZitlasAuth.createUserWithEmailAndPassword(email, password);
        const user = cred.user;

        
        try {
          await user.updateProfile({ displayName: name });
          const ts = firebase.firestore.FieldValue.serverTimestamp();

          if (selectedRole === 'expert') {
            console.log('[PROFILE CREATED] new expert uid=' + user.uid + ' email=' + user.email);
            await ZitlasDB.collection('users').doc(user.uid).set({
              uid: user.uid, email: user.email, name,
              role: 'expert', photo: '', createdAt: ts,
            });
            await ZitlasDB.collection('experts').doc(user.uid).set({
              uid: user.uid, email: user.email, name,
              role: 'expert', speciality: '', photo: '',
              verified: false, approved: false, rating: 0, reviews: 0, createdAt: ts,
            });
            syncEmailUser(user, name, 'expert');
            setLoading(false);
            showToast('Expert account created! Your application is under review.');
            setTimeout(() => window.location.replace('../experts/expert-dashboard.html'), 2200);
          } else {
            await ZitlasDB.collection('users').doc(user.uid).set({
              uid: user.uid, email: user.email, name,
              role: 'athlete', photo: '', createdAt: ts,
            });
            syncEmailUser(user, name, 'athlete');
            selectedRole = 'athlete';
            showLoginOverlay();
          }
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
        selectedRole = resolvedRole;
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
        selectedRole = resolvedRole;
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
          selectedRole = verifiedRole || 'user';
          showLoginOverlay();
        } else {
          setGoogleLoading(false);
          showRoleModal(user);
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

/* REMOVED — this used to write { role: 'expert', approved: true } into
   localStorage.zitlas_experts at sign-up. A browser-authored approval is
   worth nothing on the server, but the UI believed it, which is how a normal
   account could reach expert screens.

   Expert approval now lives only in `experts/{uid}.approved` plus the
   Firebase custom claim, both written exclusively by routes/admin.py behind
   require_admin. Kept as a no-op so no call site breaks. */
function _addToExpertsStorage(uid, email, name) {
  console.log('[EXPERT SIGNUP] ignored — expert onboarding is closed; ' +
              'approval is server-side only (uid=' + uid + ')');
}

/* Shown if the expert option is somehow reached. Reuses the existing
   "under review" panel so no new UI component is introduced. */
function showExpertOnboardingClosed() {
  var panel = document.getElementById('grmUnderReview');
  var title = panel && panel.querySelector('.grm-review-title');
  var sub   = document.getElementById('grmReviewEmail');
  var note  = panel && panel.querySelector('.grm-review-note');
  if (title) title.textContent = 'Expert onboarding is currently closed';
  if (sub)   sub.textContent   = 'ZITLAS is not accepting new expert accounts at this time.';
  if (note)  note.textContent  = 'You can continue using ZITLAS as a user.';
  if (panel) panel.style.display = '';
}

/* Expert onboarding is frozen, so the sign-up role chooser offers only one
   real option. Hidden rather than deleted: reopening onboarding is then a
   one-line change, and nothing else in the modal has to move. */
function hideExpertRoleOption() {
  var opt = document.getElementById('grmOptExpert');
  if (opt) {
    opt.style.display = 'none';
    opt.setAttribute('aria-hidden', 'true');
    opt.disabled = true;
  }
  var hint = document.getElementById('expertHint');
  if (hint) hint.style.display = 'none';
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', hideExpertRoleOption);
} else {
  hideExpertRoleOption();
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
    _addToExpertsStorage(user.uid, user.email || '', user.displayName || '');
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
    _addToExpertsStorage(user.uid, user.email || '', userName);
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

function showRoleModal(user) {
  _pendingGoogleUser = user;
  const backdrop = document.getElementById('grmBackdrop');
  if (!backdrop) return;

  const photoEl = document.getElementById('grmPhoto');
  const nameEl  = document.getElementById('grmUserName');
  const emailEl = document.getElementById('grmUserEmail');

  if (photoEl) {
    if (user.photoURL) { photoEl.src = user.photoURL; photoEl.style.display = ''; }
    else               { photoEl.style.display = 'none'; }
  }
  if (nameEl)  nameEl.textContent  = user.displayName || 'User';
  if (emailEl) emailEl.textContent = user.email       || '';

  backdrop.removeAttribute('aria-hidden');
  backdrop.classList.add('active');
  document.body.style.overflow = 'hidden';
}

function hideRoleModal() {
  const backdrop = document.getElementById('grmBackdrop');
  if (backdrop) {
    backdrop.setAttribute('aria-hidden', 'true');
    backdrop.classList.remove('active');
  }
  document.body.style.overflow = '';
}

(function initRoleModal() {
  const options     = document.querySelectorAll('.grm-option');
  const confirmBtn  = document.getElementById('grmConfirm');
  const confirmTxt  = document.getElementById('grmConfirmText');
  const confirmSpin = document.getElementById('grmConfirmSpinner');
  let   chosenRole  = null;

  options.forEach(function (opt) {
    opt.addEventListener('click', function () {
      options.forEach(function (o) { o.classList.remove('active'); });
      opt.classList.add('active');
      chosenRole = opt.dataset.role;
      if (confirmBtn) confirmBtn.disabled = false;
    });
  });

  if (!confirmBtn) return;

  confirmBtn.addEventListener('click', async function () {
    if (!chosenRole || !_pendingGoogleUser) return;
    const user = _pendingGoogleUser;

    confirmBtn.disabled = true;
    if (confirmTxt)  confirmTxt.textContent   = 'Setting up...';
    if (confirmSpin) confirmSpin.style.display = 'flex';

    try {
      
      const newRoles = ['athlete'];
      if (chosenRole === 'expert') newRoles.push('expert_pending');

      await ZitlasDB.collection('users').doc(user.uid).set({
        uid:           user.uid,
        name:          user.displayName || '',
        email:         user.email       || '',
        photo:         user.photoURL    || null,
        roles:         newRoles,
        expert_status: chosenRole === 'expert' ? 'pending' : 'none',
        created_at:    firebase.firestore.FieldValue.serverTimestamp(),
      });

      /* EXPERT ONBOARDING IS FROZEN. The option is hidden in the modal, so
         this branch is only reachable by a tampered DOM — it must therefore
         still refuse rather than record an application. */
      if (chosenRole === 'expert') {
        console.warn('[EXPERT SIGNUP] blocked — expert onboarding is closed');
        showExpertOnboardingClosed();
      } else {
        syncFirebaseUser(user, chosenRole);
        selectedRole = chosenRole;
        hideRoleModal();
        showLoginOverlay();
      }

    } catch (err) {
      console.error('[ZITLAS] saveUserRole error:', err);
      confirmBtn.disabled = false;
      if (confirmTxt)  confirmTxt.textContent   = 'Continue';
      if (confirmSpin) confirmSpin.style.display = 'none';
      showToast('Failed to save account. Please try again.');
    }
  });

  
  const reviewHomeBtn = document.getElementById('grmReviewHomeBtn');
  if (reviewHomeBtn) {
    reviewHomeBtn.addEventListener('click', function () {
      console.log('[ZITLAS] Under-review  continuing as athlete guest');
      sessionStorage.setItem('zitlas_guest', '1');
      
      window.location.replace('../dashboard/dashboard.html');
    });
  }
}());

function showExpertApplicationReview(email) {
  
  ['grmUserStrip', 'grmTitle'].forEach(function (id) {
    var el = document.getElementById(id);
    if (el) el.style.display = 'none';
  });
  document.querySelectorAll('.grm-sub, .grm-options, .grm-confirm-btn').forEach(function (el) {
    el.style.display = 'none';
  });

  
  var emailEl = document.getElementById('grmReviewEmail');
  if (emailEl && email) {
    emailEl.textContent = 'Application submitted for ' + email;
  }
  var panel = document.getElementById('grmUnderReview');
  if (panel) panel.style.display = 'flex';
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