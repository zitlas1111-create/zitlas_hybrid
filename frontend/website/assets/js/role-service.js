/*!
 * ZITLAS — the one client-side role resolver (assets/js/role-service.js)
 *
 * `GET /api/auth/role` is the ONLY authority for expert-vs-user landing. The
 * backend derives it from the verified Firebase ID token's `expert` custom
 * claim AND `experts/{uid}.approved` — neither of which a browser can write.
 * Nothing here reads `users/{uid}`, localStorage, an email list or a URL
 * parameter, and this file must never start.
 *
 * WHY IT EXISTS
 * -------------
 * Two pages guard each other and they disagreed:
 *
 *   dashboard.js        read users/{uid}.roles/expert_status — CLIENT-WRITABLE,
 *                       and counted 'expert_pending'/'pending' as expert — and
 *                       bounced those accounts to the expert dashboard.
 *   expert-dashboard.js asked the server, and bounced to the athlete dashboard
 *                       whenever the answer was anything other than a clean
 *                       "expert" — INCLUDING when the request simply failed.
 *
 * So one flaky /api/auth/role call inside the expert dashboard sent an
 * approved expert to the athlete dashboard, which then read their legacy
 * fields and sent them straight back: a redirect ping-pong with the athlete
 * dashboard visible in between. All three approved experts carry those legacy
 * markers ('expert_pending'/'pending', or role:'expert'), so all three could
 * hit it. That is the "sometimes I land in the normal user experience" report.
 *
 * THREE OUTCOMES, NOT TWO.
 *   'expert' / 'user' — the server's verdict. Act on it.
 *   null             — could not ask. NOT a verdict, and never a reason to
 *                      redirect. Callers hold and retry.
 */
(function (win) {
  'use strict';

  /* A 401/403 is an answer; a 502 or a dead connection is not. */
  var RETRY_MS = [400, 1000, 2000, 4000];

  /**
   * @param {firebase.User} firebaseUser
   * @returns {Promise<'expert'|'user'|null>} null = unresolved
   */
  function resolve(firebaseUser) {
    if (!firebaseUser) return Promise.resolve(null);

    /* FORCE REFRESH. A cached ID token can be up to an hour old and will not
       contain a custom claim granted after it was minted — which is exactly
       how a newly-authorised expert kept landing back on the user dashboard. */
    return firebaseUser.getIdToken(true).then(function (token) {
      return _attemptLoop(token, 0);
    }).catch(function (e) {
      console.warn('[AUTH ROLE] could not mint an ID token:', e && e.message);
      return null;
    });
  }

  function _attemptLoop(token, attempt) {
    return _attempt(token).then(function (role) {
      if (role !== null) return role;
      if (attempt >= RETRY_MS.length) {
        console.error('[AUTH ROLE] request failed');
        console.error('[AUTH ROLE] unresolved after ' + (RETRY_MS.length + 1) +
                      ' attempts — refusing to guess a role');
        return null;
      }
      console.warn('[AUTH ROLE] unresolved — retry ' + (attempt + 2) + '/' +
                   (RETRY_MS.length + 1) + ' in ' + RETRY_MS[attempt] + 'ms');
      return new Promise(function (r) { setTimeout(r, RETRY_MS[attempt]); })
        .then(function () { return _attemptLoop(token, attempt + 1); });
    });
  }

  /* One request. A definitive role, or null meaning "ask again". */
  function _attempt(token) {
    return fetch('/api/auth/role', {
      headers: { 'Authorization': 'Bearer ' + token }
    }).then(function (resp) {
      if (resp.ok) {
        return resp.json().then(function (data) {
          var role = (data && data.isExpert === true && data.role === 'expert')
            ? 'expert' : 'user';
          console.log('[AUTH ROLE] endpoint=/api/auth/role');
          console.log('[AUTH ROLE] responseRole=' + (data && data.role));
          console.log('[AUTH ROLE] isExpert=' + (data && data.isExpert));
          return role;
        }).catch(function () {
          /* 200 with a body we cannot parse — a proxy or captive portal.
             Not the server saying "user". */
          console.warn('[AUTH ROLE] 200 with a non-JSON body — unresolved');
          return null;
        });
      }
      if (resp.status === 401 || resp.status === 403) {
        /* The server evaluated this caller and refused. That IS the verdict. */
        console.log('[AUTH ROLE] HTTP status=' + resp.status +
                    ' (server refused this caller) -> user');
        return 'user';
      }
      console.warn('[AUTH ROLE] HTTP status=' + resp.status + ' — unresolved');
      return null;
    }).catch(function (e) {
      console.warn('[AUTH ROLE] error=' + (e && e.message) + ' — unresolved');
      return null;
    });
  }

  /* A blocking, honest failure state. Used when the role cannot be resolved:
     redirecting on a guess is what caused the ping-pong, and silently doing
     nothing would leave a blank page. */
  function showUnresolvedNotice(onRetry) {
    if (document.getElementById('zitlasRoleUnresolved')) return;
    var el = document.createElement('div');
    el.id = 'zitlasRoleUnresolved';
    el.setAttribute('role', 'alert');
    el.style.cssText =
      'position:fixed;inset:0;z-index:2147483000;display:flex;' +
      'align-items:center;justify-content:center;padding:24px;' +
      'background:rgba(250,250,247,0.98);font-family:system-ui,sans-serif;';
    el.innerHTML =
      '<div style="max-width:320px;text-align:center">' +
        '<p style="font-size:16px;font-weight:800;color:#1E293B;margin:0 0 8px">' +
          'We couldn’t verify your account</p>' +
        '<p style="font-size:13px;color:#64748B;margin:0 0 18px;line-height:1.5">' +
          'Check your connection and try again.</p>' +
        '<button id="zitlasRoleRetry" style="padding:11px 22px;border-radius:12px;' +
          'border:none;background:linear-gradient(135deg,#234B35,#2E5F47);color:#fff;' +
          'font-weight:800;font-size:13px;cursor:pointer">Try again</button>' +
      '</div>';
    document.body.appendChild(el);
    var btn = document.getElementById('zitlasRoleRetry');
    if (btn) {
      btn.addEventListener('click', function () {
        el.remove();
        if (typeof onRetry === 'function') onRetry();
      });
    }
  }

  function hideUnresolvedNotice() {
    var el = document.getElementById('zitlasRoleUnresolved');
    if (el) el.remove();
  }

  win.ZitlasRole = {
    resolve: resolve,
    showUnresolvedNotice: showUnresolvedNotice,
    hideUnresolvedNotice: hideUnresolvedNotice,
    RETRY_MS: RETRY_MS,
  };
})(window);
