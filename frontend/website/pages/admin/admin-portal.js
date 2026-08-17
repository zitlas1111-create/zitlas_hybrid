/*!
 * ZITLAS — Admin Portal (pages/admin/admin-portal.js)
 *
 * PHASE 1: access gate, shell, Dashboard, System Health, Audit Logs.
 * The remaining sidebar sections render an explicit "not built yet" state
 * rather than a fake screen — an admin console that shows empty tables for
 * unimplemented features is worse than one that says so.
 *
 * SECURITY MODEL
 * --------------
 * The claim check below is UX ONLY. It decides what to draw, nothing more.
 * The real boundary is `require_admin` on every /api/admin endpoint, which
 * re-verifies the Firebase ID token server-side and returns 403 regardless of
 * what this file believes. A user who edits this script, forges localStorage,
 * or opens /admin/ directly still gets 403 from every endpoint.
 *
 * No secret ever reaches this file: it sends the user's own ID token and
 * receives already-redacted documents.
 */
(function () {
  'use strict';

  var API = '/api/admin';

  var state = {
    user: null,
    token: null,
    view: 'dashboard',
    env: null
  };

  // ── DOM helpers ────────────────────────────────────────────────────────

  function $(id) { return document.getElementById(id); }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function toast(message, kind) {
    var box = $('apToasts');
    if (!box) return;
    var t = el('div', 'ap-toast' + (kind ? ' is-' + kind : ''), message);
    box.appendChild(t);
    setTimeout(function () { t.remove(); }, 5200);
  }

  // ── API ────────────────────────────────────────────────────────────────

  /* Friendly text per status. Never surfaces a server stack trace: the
     backend already returns short machine-readable details, and anything
     longer belongs in the platform logs, not an admin's screen. */
  var ERRORS = {
    401: 'Your session expired. Sign in again.',
    403: 'You are not authorised for this action.',
    404: 'Not found.',
    409: 'That conflicts with the current state. Reload and retry.',
    422: 'The request was rejected as invalid.',
    429: 'Too many requests — slow down and retry shortly.',
    500: 'The server hit an error. It has been logged.',
    503: 'This service is temporarily unavailable.'
  };

  function api(path, options) {
    options = options || {};
    if (!state.token) return Promise.reject(new Error('not_authenticated'));

    var init = {
      method: options.method || 'GET',
      headers: {
        'Authorization': 'Bearer ' + state.token,
        'Content-Type': 'application/json'
      }
    };
    if (options.body) init.body = JSON.stringify(options.body);

    return fetch(API + path, init).then(function (res) {
      if (res.status === 401) {
        // The token may simply have aged out mid-session — refresh once and
        // let the caller retry rather than dumping the admin at the login
        // screen for a recoverable condition.
        return refreshToken().then(function () {
          var e = new Error(ERRORS[401]);
          e.status = 401;
          throw e;
        });
      }
      if (!res.ok) {
        var err = new Error(ERRORS[res.status] || ('Request failed (' + res.status + ')'));
        err.status = res.status;
        throw err;
      }
      return res.json();
    });
  }

  function refreshToken() {
    if (!state.user) return Promise.resolve(null);
    return state.user.getIdToken(true).then(function (t) {
      state.token = t;
      return t;
    });
  }

  // ── Admin login ────────────────────────────────────────────────────────
  //
  // The server is the authority on WHO may administer ZITLAS. This file never
  // hardcodes the authorised address: after sign-in it asks
  // GET /api/admin/session, which reads the email from the cryptographically
  // verified ID token and compares it against ZITLAS_ADMIN_EMAILS server-side.
  //
  // So there is no email in this bundle to edit — and editing anything here
  // still changes nothing, because every privileged endpoint independently
  // enforces require_admin.

  function gateBusy(title, sub) {
    $('apGateSpinner').style.display = '';
    $('apGateTitle').textContent = title;
    $('apGateSub').textContent = sub || '';
    $('apGateActions').innerHTML = '';
    $('apGateAccount').textContent = '';
  }

  function gateMessage(title, sub, actions, accountLine) {
    $('apGateSpinner').style.display = 'none';
    $('apGateTitle').textContent = title;
    $('apGateSub').textContent = sub;
    $('apGateAccount').textContent = accountLine || '';

    var box = $('apGateActions');
    box.innerHTML = '';
    (actions || []).forEach(function (a) {
      var b = el('button', a.google ? 'ap-google-btn' : ('ap-btn' + (a.primary ? ' is-primary' : '')));
      if (a.google) {
        // Inline SVG: Google's mark without an external request.
        b.innerHTML =
          '<svg viewBox="0 0 18 18" width="18" height="18" aria-hidden="true">' +
          '<path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.71-1.57 2.68-3.89 2.68-6.62z"/>' +
          '<path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.81.54-1.84.86-3.04.86-2.34 0-4.32-1.58-5.03-3.7H.96v2.34A9 9 0 0 0 9 18z"/>' +
          '<path fill="#FBBC05" d="M3.97 10.72a5.41 5.41 0 0 1 0-3.44V4.94H.96a9 9 0 0 0 0 8.12l3.01-2.34z"/>' +
          '<path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58C13.46.89 11.43 0 9 0A9 9 0 0 0 .96 4.94l3.01 2.34C4.68 5.16 6.66 3.58 9 3.58z"/>' +
          '</svg><span>' + a.label + '</span>';
      } else {
        b.textContent = a.label;
      }
      b.addEventListener('click', a.onClick);
      box.appendChild(b);
    });
  }

  /* STATE 1 — signed out, or signed in as somebody who is not the admin.
     Deliberately does NOT sign an existing session out: an athlete or expert
     who wanders onto /admin/ keeps their normal ZITLAS session intact and
     simply has to choose an account explicitly. */
  function showSignIn(existingEmail) {
    gateMessage(
      'Administrator Sign In',
      'Sign in with the ZITLAS administrator Google account to continue.',
      [{ label: 'Continue with Google', google: true, onClick: startGoogleSignIn }],
      existingEmail
        ? 'Currently signed in as ' + existingEmail + ' — choose an account to continue.'
        : ''
    );
  }

  /* STATE 3 — an explicit admin sign-in attempt with the wrong account. This
     path DOES sign out: the user just deliberately authenticated for admin
     access, so leaving that session attached would be misleading. */
  function showUnauthorized(email) {
    gateMessage(
      'Access denied',
      'This Google account is not authorized to access the ZITLAS Admin Portal.',
      [{ label: 'Sign in with another account', primary: true, onClick: startGoogleSignIn }],
      email ? 'Rejected: ' + email : ''
    );
  }

  /* STATE 4 — the authorised address, but the claim has never been written. */
  function showSetupRequired(email) {
    gateMessage(
      'Administrator setup required',
      'Your account is authorized, but the administrator role has not been ' +
      'activated yet. Activate it now, then sign in again.',
      [
        { label: 'Activate administrator role', primary: true, onClick: runBootstrap },
        { label: 'Sign out', onClick: signOut }
      ],
      email ? 'Authorized account: ' + email : ''
    );
  }

  function startGoogleSignIn() {
    if (typeof firebase === 'undefined' || !firebase.auth) {
      gateMessage('Authentication unavailable',
        'Firebase could not be initialised, so admin sign-in cannot proceed.', []);
      return;
    }
    gateBusy('Signing you in securely…', 'Complete the Google sign-in window.');

    var provider = new firebase.auth.GoogleAuthProvider();
    // Always offer the account chooser. Without this Google silently reuses
    // whichever account the browser last used — exactly how you end up staring
    // at "Access denied" for an athlete account with no way to pick the admin
    // one.
    provider.setCustomParameters({ prompt: 'select_account' });

    ZitlasAuth.signInWithPopup(provider).then(function (result) {
      return resolveSession(result.user, { explicitAttempt: true });
    }).catch(function (e) {
      var code = (e && e.code) || '';
      if (code === 'auth/popup-closed-by-user' || code === 'auth/cancelled-popup-request') {
        showSignIn();
        return;
      }
      console.error('[ADMIN] google sign-in failed', e);
      gateMessage('Sign-in failed',
        'Google sign-in could not be completed. Please try again.',
        [{ label: 'Try again', primary: true, onClick: startGoogleSignIn }]);
    });
  }

  /* The single decision point. Every branch is driven by the SERVER's answer,
     never by inspecting the email in this file. */
  function resolveSession(user, opts) {
    opts = opts || {};
    if (!user) { showSignIn(); return Promise.resolve(); }

    gateBusy('Verifying administrator access…', 'Checking your credentials with ZITLAS.');

    return user.getIdToken().then(function (token) {
      state.user = user;
      state.token = token;
      return api('/session');
    }).then(function (session) {
      setEnvBadge(session.environment);

      if (session.isAdmin) {
        enterPortal(user, session);          // STATE 5
        return;
      }
      if (session.bootstrapEligible) {
        showSetupRequired(session.email);    // STATE 4
        return;
      }

      // STATE 3 — not authorised.
      state.user = null;
      state.token = null;
      if (opts.explicitAttempt) {
        var rejected = user.email;
        ZitlasAuth.signOut()
          .then(function () { showUnauthorized(rejected); })
          .catch(function () { showUnauthorized(rejected); });
      } else {
        // Page load carrying somebody else's session — leave it alone.
        showSignIn(user.email);
      }
    }).catch(function (e) {
      console.error('[ADMIN] session check failed', e);
      state.token = null;
      gateMessage('Could not verify access',
        (e && e.message) ? e.message : 'Your administrator status could not be confirmed.',
        [{ label: 'Retry', primary: true, onClick: function () { resolveSession(user, opts); } },
         { label: 'Sign out', onClick: signOut }]);
    });
  }

  function runBootstrap() {
    gateBusy('Activating administrator role…', 'Writing your administrator claim.');
    // No request body at all: the server uses the uid from the verified token,
    // so there is nothing here for anyone to tamper with.
    api('/bootstrap', { method: 'POST' }).then(function (res) {
      if (!res.claimSet) throw new Error('The administrator claim could not be written.');
      gateMessage('Administrator role activated',
        'Sign in again so your session picks up the new administrator role — ' +
        'Firebase bakes claims into the token when the token is issued.',
        [{ label: 'Sign out and continue', primary: true, onClick: signOut }]);
    }).catch(function (e) {
      gateMessage('Activation failed',
        (e && e.message) ? e.message : 'The administrator role could not be activated.',
        [{ label: 'Try again', primary: true, onClick: runBootstrap },
         { label: 'Sign out', onClick: signOut }]);
    });
  }

  function startGate() {
    if (typeof ZitlasAuth === 'undefined') {
      gateMessage('Authentication unavailable',
        'Firebase could not be initialised, so admin access cannot be verified.', []);
      return;
    }
    ZitlasAuth.onAuthStateChanged(function (user) {
      // Not an explicit attempt: a pre-existing athlete/expert session must be
      // neither silently adopted nor destroyed.
      resolveSession(user, { explicitAttempt: false });
    });
  }

  function signOut() {
    state.user = null;
    state.token = null;
    var done = function () {
      $('apShell').hidden = true;
      $('apGate').style.display = '';
      $('apGate').hidden = false;
      showSignIn();
    };
    if (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.signOut) {
      ZitlasAuth.signOut().then(done).catch(done);
    } else {
      done();
    }
  }

  function enterPortal(user, session) {
    $('apGate').hidden = true;
    $('apGate').style.display = 'none';
    $('apShell').hidden = false;

    var name = user.displayName || user.email || 'Admin';
    $('apUserName').textContent = name;
    $('apAvatar').textContent = name.charAt(0).toUpperCase();
    // The email shown is the one the SERVER verified, not a browser profile
    // field.
    $('apUserEmail').textContent = (session && session.email) || user.email || '';

    // Firebase ID tokens expire after an hour; refresh well inside that so a
    // long admin session never fails a request it could have completed.
    setInterval(function () {
      refreshToken().catch(function () { /* next call surfaces it */ });
    }, 30 * 60 * 1000);

    wireChrome();
    loadHealthIndicator();
    render('dashboard');
  }

  // ── Chrome ─────────────────────────────────────────────────────────────

  var TITLES = {
    dashboard: 'Dashboard', users: 'Users', experts: 'Experts',
    verification: 'Expert Verification', coaching: 'Coaching',
    reviews: 'Plans & Reviews', diet: 'Diet & Nutrition', training: 'Training',
    recipes: 'Recipes', notifications: 'Notifications', payments: 'Payments',
    wallet: 'Wallet', support: 'Support', ai: 'AI / Knowledge Base',
    system: 'System Health', audit: 'Audit Logs'
  };

  function wireChrome() {
    $('apNav').addEventListener('click', function (e) {
      var btn = e.target.closest('.ap-nav-item');
      if (!btn) return;
      render(btn.getAttribute('data-view'));
      $('apSidebar').classList.remove('is-open');
    });

    $('apBurger').addEventListener('click', function () {
      $('apSidebar').classList.toggle('is-open');
    });

    $('apLogout').addEventListener('click', signOut);
  }

  function setActiveNav(view) {
    var items = document.querySelectorAll('.ap-nav-item');
    for (var i = 0; i < items.length; i++) {
      items[i].classList.toggle('is-active', items[i].getAttribute('data-view') === view);
    }
    $('apViewTitle').textContent = TITLES[view] || 'Admin';
  }

  function setEnvBadge(env) {
    if (!env || state.env === env) return;
    state.env = env;
    var badge = $('apEnv');
    badge.textContent = env;
    badge.className = 'ap-env is-' + env.toLowerCase();
  }

  function loadHealthIndicator() {
    api('/system/health').then(function (data) {
      setEnvBadge(data.environment);
      var comps = data.components || {};
      var statuses = Object.keys(comps).map(function (k) {
        return (comps[k] && comps[k].status) || 'DOWN';
      });
      var dot = $('apHealthDot');
      var cls = statuses.indexOf('DOWN') !== -1 ? 'is-down'
        : statuses.indexOf('DEGRADED') !== -1 ? 'is-degraded' : 'is-ok';
      dot.className = 'ap-health-dot ' + cls;
      dot.title = 'System: ' + cls.replace('is-', '');
    }).catch(function () { /* the System Health view reports properly */ });
  }

  // ── Rendering ──────────────────────────────────────────────────────────

  function render(view) {
    state.view = view;
    setActiveNav(view);
    var root = $('apContent');
    root.innerHTML = '';

    if (view === 'dashboard') return renderDashboard(root);
    if (view === 'system') return renderSystemHealth(root);
    if (view === 'audit') return renderAuditLogs(root);
    return renderNotBuilt(root, TITLES[view] || view);
  }

  function skeletonGrid(root, count) {
    var grid = el('div', 'ap-kpi-grid');
    for (var i = 0; i < count; i++) {
      var card = el('div', 'ap-card');
      card.appendChild(el('div', 'ap-skel'));
      var v = el('div', 'ap-skel');
      v.style.cssText = 'height:26px;margin-top:10px;width:55%';
      card.appendChild(v);
      grid.appendChild(card);
    }
    root.appendChild(grid);
    return grid;
  }

  function errorState(root, err) {
    root.innerHTML = '';
    var box = el('div', 'ap-error');
    box.appendChild(el('div', null, err && err.message ? err.message : 'Something went wrong.'));
    var retry = el('button', 'ap-btn', 'Retry');
    retry.style.marginTop = '12px';
    retry.addEventListener('click', function () { render(state.view); });
    box.appendChild(retry);
    root.appendChild(box);
  }

  function kpi(label, value, sub) {
    var card = el('div', 'ap-card');
    card.appendChild(el('div', 'ap-kpi-label', label));
    // -1 is the guarded-count sentinel: that collection could not be read.
    var unavailable = value === -1 || value === null || value === undefined;
    var v = el('div', 'ap-kpi-value' + (unavailable ? ' is-unavailable' : ''),
      unavailable ? 'Unavailable' : value);
    card.appendChild(v);
    if (sub) card.appendChild(el('div', 'ap-kpi-sub', sub));
    return card;
  }

  // ── Dashboard ──────────────────────────────────────────────────────────

  function renderDashboard(root) {
    skeletonGrid(root, 8);

    api('/dashboard').then(function (d) {
      root.innerHTML = '';
      setEnvBadge(d.environment);

      var grid = el('div', 'ap-kpi-grid');
      grid.appendChild(kpi('Total users', d.users.total));
      grid.appendChild(kpi('Experts', d.users.experts));
      grid.appendChild(kpi('Suspended', d.users.suspended));
      grid.appendChild(kpi('Verified experts', d.experts.verified));
      grid.appendChild(kpi('Approved experts', d.experts.approved,
        'Unapproved profiles are still listed publicly — see report'));
      grid.appendChild(kpi('Pending verification', d.experts.pendingVerification,
        'Certificates awaiting review'));
      grid.appendChild(kpi('Active coaching', d.coaching.active));
      grid.appendChild(kpi('Pending requests', d.coaching.pendingRequests));
      root.appendChild(grid);

      root.appendChild(el('div', 'ap-section-title', 'Reviews & support'));
      var g2 = el('div', 'ap-kpi-grid');
      g2.appendChild(kpi('Pending reviews', d.reviews.pending));
      g2.appendChild(kpi('Completed reviews', d.reviews.completed));
      g2.appendChild(kpi('Open support tickets', d.support.open));
      g2.appendChild(kpi('Audit records', d.audit.recent, 'Last 1000'));
      root.appendChild(g2);

      var note = el('p', 'ap-placeholder-note',
        'Counts are bounded and computed per collection — an unreadable ' +
        'collection shows as Unavailable rather than failing the page. ' +
        'Generated ' + (d.generatedAt || '').replace('T', ' ').slice(0, 19) + ' UTC.');
      root.appendChild(note);
    }).catch(function (e) { errorState(root, e); });
  }

  // ── System health ──────────────────────────────────────────────────────

  function statusBadge(status) {
    var cls = status === 'HEALTHY' ? 'is-ok' : status === 'DEGRADED' ? 'is-warn' : 'is-danger';
    return el('span', 'ap-badge ' + cls, status);
  }

  function renderSystemHealth(root) {
    skeletonGrid(root, 4);

    api('/system/health').then(function (d) {
      root.innerHTML = '';
      setEnvBadge(d.environment);

      var comps = d.components || {};
      var grid = el('div', 'ap-kpi-grid');

      Object.keys(comps).forEach(function (key) {
        var c = comps[key] || {};
        var card = el('div', 'ap-card');
        card.appendChild(el('div', 'ap-kpi-label', key));
        var row = el('div');
        row.style.marginTop = '9px';
        row.appendChild(statusBadge(c.status || 'DOWN'));
        card.appendChild(row);
        if (c.detail) card.appendChild(el('div', 'ap-kpi-sub', c.detail));
        grid.appendChild(card);
      });
      root.appendChild(grid);

      var providers = (comps.aiProviders && comps.aiProviders.configured) || {};
      root.appendChild(el('div', 'ap-section-title', 'AI providers'));
      var pg = el('div', 'ap-kpi-grid');
      Object.keys(providers).forEach(function (name) {
        var card = el('div', 'ap-card');
        card.appendChild(el('div', 'ap-kpi-label', name));
        var row = el('div');
        row.style.marginTop = '9px';
        row.appendChild(el('span', 'ap-badge ' + (providers[name] ? 'is-ok' : 'is-muted'),
          providers[name] ? 'CONFIGURED' : 'NOT CONFIGURED'));
        card.appendChild(row);
        pg.appendChild(card);
      });
      root.appendChild(pg);

      var rag = comps.rag || {};
      root.appendChild(el('div', 'ap-section-title', 'Knowledge base (RAG)'));
      var rc = el('div', 'ap-card');
      var rrow = el('div');
      rrow.appendChild(statusBadge(rag.status || 'DOWN'));
      rc.appendChild(rrow);
      rc.appendChild(el('div', 'ap-kpi-sub',
        'Loaded indexes: ' + ((rag.loadedKbs || []).join(', ') || 'none yet') +
        ' · cache ' + (rag.cacheSize || 0)));
      root.appendChild(rc);

      root.appendChild(el('p', 'ap-placeholder-note',
        'Providers report CONFIGURED or NOT CONFIGURED only. No key, prefix, ' +
        'or length is ever sent to the browser.'));
    }).catch(function (e) { errorState(root, e); });
  }

  // ── Audit logs ─────────────────────────────────────────────────────────

  var auditQuery = { page: 1, pageSize: 50, q: '', action: '' };

  function renderAuditLogs(root) {
    var bar = el('div', 'ap-toolbar');

    var search = el('input', 'ap-input');
    search.type = 'search';
    search.placeholder = 'Search action, admin UID, target UID, reason…';
    search.value = auditQuery.q;

    var action = el('select', 'ap-select');
    ['', 'ADMIN_GRANTED', 'ADMIN_REVOKED', 'EXPERT_APPROVED', 'EXPERT_REJECTED',
     'EXPERT_DEACTIVATED', 'CERT_APPROVED', 'CERT_REJECTED', 'VERIFICATION_RECOMPUTED'
    ].forEach(function (a) {
      var o = el('option', null, a || 'All actions');
      o.value = a;
      action.appendChild(o);
    });
    action.value = auditQuery.action;

    var size = el('select', 'ap-select');
    [50, 100].forEach(function (n) {
      var o = el('option', null, n + ' per page');
      o.value = String(n);
      size.appendChild(o);
    });
    size.value = String(auditQuery.pageSize);

    function reload() {
      auditQuery.q = search.value;
      auditQuery.action = action.value;
      auditQuery.pageSize = parseInt(size.value, 10);
      auditQuery.page = 1;
      fetchAudit();
    }

    var apply = el('button', 'ap-btn is-primary', 'Apply');
    apply.addEventListener('click', reload);
    search.addEventListener('keydown', function (e) { if (e.key === 'Enter') reload(); });

    bar.appendChild(search);
    bar.appendChild(action);
    bar.appendChild(size);
    bar.appendChild(apply);
    root.appendChild(bar);

    var host = el('div');
    root.appendChild(host);

    function fetchAudit() {
      host.innerHTML = '';
      var sk = el('div', 'ap-card');
      for (var i = 0; i < 6; i++) {
        var line = el('div', 'ap-skel');
        line.style.marginBottom = '9px';
        sk.appendChild(line);
      }
      host.appendChild(sk);

      var qs = '?page=' + auditQuery.page + '&pageSize=' + auditQuery.pageSize +
        (auditQuery.q ? '&q=' + encodeURIComponent(auditQuery.q) : '') +
        (auditQuery.action ? '&action=' + encodeURIComponent(auditQuery.action) : '');

      api('/audit-logs' + qs).then(function (page) {
        host.innerHTML = '';
        if (!page.items.length) {
          var empty = el('div', 'ap-empty');
          empty.appendChild(el('span', 'ap-empty-icon', '🗒️'));
          empty.appendChild(el('div', null, 'No audit records match.'));
          host.appendChild(empty);
          return;
        }

        var wrap = el('div', 'ap-table-wrap');
        var table = el('table', 'ap-table');
        var thead = el('thead');
        var hr = el('tr');
        ['When (UTC)', 'Action', 'Admin', 'Target', 'Change', 'Reason'].forEach(function (h) {
          hr.appendChild(el('th', null, h));
        });
        thead.appendChild(hr);
        table.appendChild(thead);

        var tbody = el('tbody');
        page.items.forEach(function (r) {
          var tr = el('tr');
          tr.appendChild(el('td', 'ap-mono', (r.timestamp || '').replace('T', ' ').slice(0, 19)));

          var actionCell = el('td');
          var danger = /REVOK|REJECT|DEACTIV|SUSPEND|DEBIT/.test(r.action || '');
          actionCell.appendChild(el('span', 'ap-badge ' + (danger ? 'is-danger' : 'is-ok'), r.action));
          tr.appendChild(actionCell);

          tr.appendChild(el('td', 'ap-mono', r.adminUid || '—'));
          tr.appendChild(el('td', 'ap-mono', r.targetUid || '—'));
          tr.appendChild(el('td', 'ap-mono',
            JSON.stringify(r.oldValue) + ' → ' + JSON.stringify(r.newValue)));
          tr.appendChild(el('td', null, r.reason || '—'));
          tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        wrap.appendChild(table);
        host.appendChild(wrap);

        var pager = el('div', 'ap-pager');
        var prev = el('button', 'ap-btn', '‹ Prev');
        var next = el('button', 'ap-btn', 'Next ›');
        prev.disabled = page.page <= 1;
        next.disabled = page.page >= page.totalPages;
        prev.addEventListener('click', function () { auditQuery.page--; fetchAudit(); });
        next.addEventListener('click', function () { auditQuery.page++; fetchAudit(); });
        pager.appendChild(prev);
        pager.appendChild(el('span', null,
          'Page ' + page.page + ' of ' + page.totalPages + ' · ' + page.total + ' records'));
        pager.appendChild(next);
        host.appendChild(pager);

        host.appendChild(el('p', 'ap-placeholder-note',
          'Append-only. There is no edit or delete path for audit records ' +
          'anywhere in the admin API, and Firestore rules deny browsers all ' +
          'direct access to the collection.'));
      }).catch(function (e) { errorState(host, e); });
    }

    fetchAudit();
  }

  // ── Sections not yet built ─────────────────────────────────────────────

  function renderNotBuilt(root, title) {
    var box = el('div', 'ap-empty');
    box.appendChild(el('span', 'ap-empty-icon', '🚧'));
    box.appendChild(el('div', null, title + ' is not built yet.'));
    box.appendChild(el('p', 'ap-placeholder-note',
      'Phase 1 ships the access gate, Dashboard, System Health and Audit ' +
      'Logs. This section is shown as pending rather than as an empty table ' +
      'so nothing here can be mistaken for real data.'));
    root.appendChild(box);
  }

  // ── Boot ───────────────────────────────────────────────────────────────

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startGate);
  } else {
    startGate();
  }
})();
