/*!
 * ZITLAS — Web push notifications (assets/js/push-notifications.js)
 *
 * The missing layer between the in-app Notification Center (which only
 * shows a badge while the app is OPEN) and real device notifications.
 * Pipeline this module owns, end to end:
 *
 *   a signed-in page that loads this — the athlete dashboard or the expert
 *   dashboard — once Firebase Auth has restored the session
 *     -> friendly pre-prompt dialog (once — never re-asks after granted)
 *     -> Notification.requestPermission()
 *     -> register /firebase-messaging-sw.js (root scope)
 *     -> firebase.messaging().getToken()
 *     -> users/{uid}.pushTokens  arrayUnion (multi-device safe, no overwrite)
 *     -> foreground messages: onMessage -> system notification via the SW
 *     -> background messages: handled inside firebase-messaging-sw.js
 *
 * Denied -> one-time instructions for enabling from browser settings.
 * Skipped entirely in the Capacitor app (web push doesn't apply inside the
 * native webview — native uses its own channel) and on browsers without
 * serviceWorker/PushManager support.
 *
 * State: zitlas_push_state { status:'granted'|'denied_seen'|'snoozed', ts }
 * Sending: any server with FCM credentials can now deliver to
 * users/{uid}.pushTokens — see backend/routes/system.py test-push endpoint.
 */
(function (win) {
  'use strict';

  var STATE_KEY   = 'zitlas_push_state';
  var TOKEN_KEY   = 'zitlas_push_token';
  var SNOOZE_DAYS = 7;

  function $(id) { return document.getElementById(id); }
  function _state() {
    try { return JSON.parse(localStorage.getItem(STATE_KEY) || 'null'); } catch (_) { return null; }
  }
  function _setState(s) {
    try { localStorage.setItem(STATE_KEY, JSON.stringify(s)); } catch (_) {}
  }
  /* The SIGNED-IN Firebase user — and only that.

     This used to fall back to a uid cached in localStorage when the auth SDK
     had not restored the session yet. That cache can still name a PREVIOUS
     account on this browser, and a device registered under the wrong uid is
     either rejected by the security rule (so nobody gets push) or points one
     account's notifications at a browser somebody else is using. init() now
     waits for onAuthStateChanged, so a real session always exists here. */
  function currentUid() {
    return (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser)
      ? ZitlasAuth.currentUser.uid : null;
  }

  /* The ZITLAS Flutter app shows these pages inside an Android WebView
     (?webview=1, or the ZitlasWebview channel it injects — the same test
     webview-bridge.js uses). A WebView cannot receive web push, and the app
     registers the device natively, so this stays out of the way rather than
     prompting inside the app. */
  function inWebView() {
    return /[?&]webview=1(&|$)/.test((win.location && win.location.search) || '') ||
      !!win.ZitlasWebview;
  }

  /* Expert pages get expert wording: an expert is told about CLIENTS. */
  function isExpertPage() {
    return /\/pages\/experts\//.test((win.location && win.location.pathname) || '');
  }

  /* One browser notification per EVENT. MUST match web_tag() in
     backend/services/push_service.py and zitlasTag() in
     /firebase-messaging-sw.js. It used to be a fixed 'zitlas-foreground', so
     every foreground notification silently REPLACED the one before it — two
     client requests arriving together showed up as one. */
  function zitlasTag(data) {
    data = data || {};
    if (data.chatId) return 'zitlas-chat-' + data.chatId;
    var key = data.eventId || data.notificationId;
    return 'zitlas-' + (key || data.type || data.category || 'general');
  }

  function supported() {
    return !win.Capacitor &&
      !inWebView() &&
      typeof Notification !== 'undefined' &&
      'serviceWorker' in navigator &&
      'PushManager' in win &&
      typeof firebase !== 'undefined' &&
      typeof firebase.messaging === 'function';
  }

  /* ── Core pipeline (permission already granted) ────────────────────── */

  /* register() resolves when the registration EXISTS, not when the worker
     is ACTIVE — and PushManager.subscribe (inside getToken) aborts with
     "no active Service Worker" on a first-ever install if we don't wait. */
  function _waitForActive(reg) {
    if (reg.active) return Promise.resolve(reg);
    return new Promise(function (resolve) {
      var sw = reg.installing || reg.waiting;
      if (!sw) return resolve(reg);
      var to = setTimeout(function () { resolve(reg); }, 10000); /* never hang */
      sw.addEventListener('statechange', function () {
        if (sw.state === 'activated') { clearTimeout(to); resolve(reg); }
      });
    });
  }

  /* Writes this browser's session into BOTH stores.

     users/{uid}.pushTokens is a plain array with no session state: it keeps a
     token after that browser signs out, and the SAME token can end up listed
     under two different accounts. The backend therefore cannot tell an active
     device from an abandoned one by reading it — which is how a user with one
     phone came to be targeted as three devices.

     device_tokens/{fcmToken} is the registry the Flutter app already uses and
     the backend already trusts (see mobile/lib/core/notifications/
     fcm_service.dart and backend/services/notification_service.py). Keying by
     TOKEN is what makes it authoritative: a browser has one token, so the
     document can only ever name one owning uid, and signing in as somebody
     else overwrites it rather than adding a second claim.

     The array is still written so nothing that reads it breaks; the registry
     is what decides delivery. This is deliberately the SAME collection the app
     writes — a second, web-only device system would just reproduce the
     problem it is here to fix. */
  function storeToken(uid, token) {
    var now = new Date().toISOString();
    var registry = ZitlasDB.collection('device_tokens').doc(token).set({
      fcmToken: token,
      uid: uid,
      platform: 'web',
      deviceId: deviceId(),
      enabled: true,
      loggedIn: true,
      lastActiveAt: now,
      updatedAt: now,
    }).then(function () {
      console.log('[PUSH] device registered as active for ' + uid);
    });

    var legacy = ZitlasDB.collection('users').doc(uid).set({
      /* arrayUnion: each device APPENDS its own token — logging in on a
         second device never overwrites the first one's. */
      pushTokens: firebase.firestore.FieldValue.arrayUnion(token),
      pushTokensUpdatedAt: now,
    }, { merge: true });

    return Promise.all([registry, legacy]).catch(function (e) {
      console.warn('[PUSH] token store failed', e);
    });
  }

  /* FCM can issue this browser a NEW token (getToken revalidates on every
     visit). The previous token's registry row would otherwise stay
     enabled:true until FCM reported it dead — one browser counted as two
     devices, with pushes to the old one delivered nowhere. Retired the way
     the app does it (fcm_service.dart _rotateToken): enabled:false, never a
     delete, and dropped from the legacy array.

     Signing OUT is handled in assets/js/firebase-config.js
     (ZitlasAuth.releasePushSession), because most pages that can sign out
     do not load this file. */
  function retireToken(uid, oldToken, newToken) {
    var now = new Date().toISOString();
    return Promise.all([
      ZitlasDB.collection('device_tokens').doc(oldToken).set({
        fcmToken: oldToken,
        uid: uid,
        enabled: false,
        loggedIn: false,
        retiredAt: now,
        retiredFor: String(newToken).slice(0, 12),
      }, { merge: true }),
      ZitlasDB.collection('users').doc(uid).set({
        pushTokens: firebase.firestore.FieldValue.arrayRemove(oldToken),
      }, { merge: true }),
    ]).then(function () {
      console.log('[PUSH] previous token retired for ' + uid);
    }).catch(function (e) {
      console.warn('[PUSH] retiring the previous token failed (non-fatal)', e);
    });
  }

  /* Stable per-browser id, so a device stays recognisable across token
     rotations. Mirrors the app's DeviceIdentity; localStorage is the only
     durable per-browser store available here. */
  function deviceId() {
    var KEY = 'zitlas_device_id';
    try {
      var existing = localStorage.getItem(KEY);
      if (existing) return existing;
      var made = 'web_' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
      localStorage.setItem(KEY, made);
      return made;
    } catch (_) {
      return 'web_unknown';
    }
  }

  function registerAndStoreToken(uid) {
    var previous = null;
    try { previous = localStorage.getItem(TOKEN_KEY); } catch (_) {}
    return navigator.serviceWorker.register('/firebase-messaging-sw.js')
      .then(_waitForActive)
      .then(function (reg) {
        console.log('[PUSH] service worker registered + active, scope:', reg.scope);
        var opts = { serviceWorkerRegistration: reg };
        /* Optional project VAPID key (Firebase console -> Cloud Messaging ->
           Web Push certificates). Without it the SDK uses FCM's default
           key pair, which works but a project key is recommended. */
        if (win.ZITLAS_VAPID_KEY) opts.vapidKey = win.ZITLAS_VAPID_KEY;
        return firebase.messaging().getToken(opts);
      })
      .then(function (token) {
        if (!token) throw new Error('FCM returned no token');
        /* A prefix only — a full FCM token is a credential. */
        console.log('[PUSH] FCM token:', token.slice(0, 12) + '…');
        try { localStorage.setItem(TOKEN_KEY, token); } catch (_) {}
        if (!uid || typeof ZitlasDB === 'undefined') return token;
        return storeToken(uid, token).then(function () {
          if (previous && previous !== token) return retireToken(uid, previous, token);
        }).then(function () { return token; });
      });
  }

  /* Foreground messages: FCM only calls this while a ZITLAS tab has focus
     (background/closed is the SW's onBackgroundMessage). Show a system
     notification through the SW so look & tap behavior match. Attached ONCE
     per page — a second listener would show every message twice. */
  var _foregroundAttached = false;
  function attachForegroundHandler() {
    if (_foregroundAttached) return;
    _foregroundAttached = true;
    try {
      firebase.messaging().onMessage(function (payload) {
        var n = payload.notification || {};
        var data = payload.data || {};
        console.log('[PUSH] foreground message', data.type || '');
        navigator.serviceWorker.getRegistration('/firebase-messaging-sw.js').then(function (reg) {
          if (!reg) return;
          reg.showNotification(n.title || data.title || 'ZITLAS', {
            body: n.body || data.body || data.message || '',
            icon: '/assets/zino.png',
            badge: '/assets/zino.png',
            tag: zitlasTag(data),
            renotify: !!data.chatId,
            data: { url: data.url || '/pages/notifications/notifications.html' },
          });
        });
      });
    } catch (e) { console.warn('[PUSH] onMessage attach failed', e); }
  }

  /* ── Permission UX ─────────────────────────────────────────────────── */

  function closeDialog() {
    var el = $('pushOverlay');
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  function showDeniedHelp() {
    var s = _state();
    if (s && s.status === 'denied_seen') return; /* one-time only */
    _setState({ status: 'denied_seen', ts: Date.now() });
    var overlay = document.createElement('div');
    overlay.id = 'pushOverlay';
    overlay.className = 'push-overlay';
    overlay.innerHTML =
      '<div class="push-card" role="dialog" aria-modal="true">' +
        '<span class="push-icon">🔕</span>' +
        '<h3 class="push-title">Notifications are blocked</h3>' +
        '<p class="push-sub">To get reminders and expert updates, enable notifications for zitlas.com in your browser:</p>' +
        '<ol class="push-steps">' +
          '<li>Tap the <b>lock / tune icon</b> next to the address bar</li>' +
          '<li>Open <b>Permissions</b> (or <b>Site settings</b>)</li>' +
          '<li>Set <b>Notifications</b> to <b>Allow</b>, then reload</li>' +
        '</ol>' +
        '<div class="push-btns"><button class="push-btn push-btn--later" id="pushCloseBtn">Got it</button></div>' +
      '</div>';
    document.body.appendChild(overlay);
    $('pushCloseBtn').addEventListener('click', closeDialog);
  }

  function requestPermissionFlow() {
    var btn = $('pushEnableBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Waiting for browser…'; }
    Notification.requestPermission().then(function (perm) {
      console.log('[PUSH] permission result:', perm);
      if (perm === 'granted') {
        _setState({ status: 'granted', ts: Date.now() });
        var status = $('pushStatus');
        if (status) status.textContent = '✅ Notifications enabled!';
        registerAndStoreToken(currentUid())
          .then(function () { attachForegroundHandler(); })
          .catch(function (e) { console.warn('[PUSH] token setup failed', e); });
        setTimeout(closeDialog, 1100);
      } else if (perm === 'denied') {
        closeDialog();
        showDeniedHelp();
      } else { /* dismissed the browser prompt */
        _setState({ status: 'snoozed', ts: Date.now() });
        closeDialog();
      }
    });
  }

  /* Pre-prompt wording, by audience. Static strings only (never user data),
     so building the dialog's HTML from them is safe. */
  function promptCopy() {
    if (isExpertPage()) {
      return {
        title: 'Never miss a client',
        sub: 'Get notified the moment a client requests coaching or a review, sends a meal for review, or messages you — even when ZITLAS isn’t open.',
        items: ['New coaching &amp; review requests', 'Meals waiting for your review', 'Client messages &amp; payments'],
      };
    }
    return {
      title: 'Stay in the loop',
      sub: 'Get notified the moment your expert reviews your plan, your coach replies, or it’s time to move — even when ZITLAS isn’t open.',
      items: ['Expert review &amp; coach updates', 'Diet &amp; workout reminders', 'Wallet &amp; request activity'],
    };
  }

  function showPrePrompt() {
    if ($('pushOverlay')) return;
    var copy = promptCopy();
    var overlay = document.createElement('div');
    overlay.id = 'pushOverlay';
    overlay.className = 'push-overlay';
    overlay.innerHTML =
      '<div class="push-card" role="dialog" aria-modal="true" aria-label="Enable notifications">' +
        '<span class="push-icon">🔔</span>' +
        '<h3 class="push-title">' + copy.title + '</h3>' +
        '<p class="push-sub">' + copy.sub + '</p>' +
        '<ul class="push-list">' +
          copy.items.map(function (i) {
            return '<li><span class="push-tick">✔</span> ' + i + '</li>';
          }).join('') +
        '</ul>' +
        '<p class="push-status" id="pushStatus"></p>' +
        '<div class="push-btns">' +
          '<button class="push-btn push-btn--enable" id="pushEnableBtn">Enable Notifications</button>' +
          '<button class="push-btn push-btn--later" id="pushLaterBtn">Not Now</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(overlay);
    $('pushEnableBtn').addEventListener('click', requestPermissionFlow);
    $('pushLaterBtn').addEventListener('click', function () {
      _setState({ status: 'snoozed', ts: Date.now() });
      closeDialog();
    });
  }

  /* ── Eligibility + boot ────────────────────────────────────────────── */

  function maybeInit(uid) {
    if (!supported()) { console.log('[PUSH] web push not supported in this context — skipping'); return; }
    if (!uid) return; /* only for a real, restored session */

    firebase.messaging.isSupported && !firebase.messaging.isSupported()
      ? console.log('[PUSH] messaging.isSupported() = false — skipping')
      : route();

    function route() {
      var perm = Notification.permission;
      if (perm === 'granted') {
        /* Already granted (now or previously): NEVER show the dialog again.
           Refresh the token silently — getToken rotates/revalidates, and a
           changed token retires the previous one (see retireToken). */
        _setState({ status: 'granted', ts: Date.now() });
        registerAndStoreToken(uid)
          .then(function () { attachForegroundHandler(); })
          .catch(function (e) { console.warn('[PUSH] silent token refresh failed', e); });
        return;
      }
      if (perm === 'denied') { showDeniedHelp(); return; }

      /* perm === 'default' — show the pre-prompt unless snoozed */
      var s = _state();
      if (s && s.status === 'snoozed' && (Date.now() - (s.ts || 0)) / 86400000 < SNOOZE_DAYS) return;

      /* Don't stack on the geo-location prompt — wait our turn (same
         coordination pattern as step-permissions.js). */
      var tries = 0;
      var t = setInterval(function () {
        tries++;
        if (!document.getElementById('geoLocOverlay') || tries > 30) {
          clearInterval(t);
          showPrePrompt();
        }
      }, 1000);
    }
  }

  /* Starts once Firebase Auth has RESTORED the session — onAuthStateChanged
     fires only after persistence has been read, so the uid used below is the
     account actually signed in on this page (see currentUid). */
  function init() {
    if (inWebView()) {
      console.log('[PUSH] inside the ZITLAS app — the device registers natively');
      return;
    }
    if (typeof ZitlasAuth === 'undefined' || typeof ZitlasAuth.onAuthStateChanged !== 'function') return;
    var started = false;
    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user || started) return;
      started = true;
      /* Small delay so the page paints and the geo prompt (600ms) can claim
         its slot first. */
      setTimeout(function () { maybeInit(user.uid); }, 2200);
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  win.ZitlasPush = {
    show: showPrePrompt,
    getSavedToken: function () {
      try { return localStorage.getItem(TOKEN_KEY); } catch (_) { return null; }
    },
    refreshToken: function () { return registerAndStoreToken(currentUid()); },
  };
})(window);
