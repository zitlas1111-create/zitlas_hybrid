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

  // ── Access gate ────────────────────────────────────────────────────────

  function gateMessage(title, sub, actions) {
    var spinner = $('apGateSpinner');
    if (spinner) spinner.style.display = 'none';
    $('apGateTitle').textContent = title;
    $('apGateSub').textContent = sub;

    var box = $('apGateActions');
    box.innerHTML = '';
    (actions || []).forEach(function (a) {
      var b = el('button', 'ap-btn' + (a.primary ? ' is-primary' : ''), a.label);
      b.addEventListener('click', a.onClick);
      box.appendChild(b);
    });
  }

  function toLogin() {
    window.location.href = '../login/login.html?redirect=' +
      encodeURIComponent(window.location.pathname);
  }

  function startGate() {
    if (typeof ZitlasAuth === 'undefined') {
      gateMessage('Authentication unavailable',
        'Firebase could not be initialised, so admin access cannot be verified.', []);
      return;
    }

    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user) {
        gateMessage('Sign in required',
          'The ZITLAS Admin Portal requires an administrator account.',
          [{ label: 'Go to sign in', primary: true, onClick: toLogin }]);
        return;
      }

      /* The AUTHORITATIVE signal is the `admin` custom claim baked into the
         verified ID token. A users/{uid}.role == 'admin' fallback is
         deliberately NOT accepted: that field is client-writable, so
         honouring it would be a pure spoof surface that the backend's
         require_admin would reject anyway. */
      user.getIdTokenResult().then(function (res) {
        var isAdmin = !!(res && res.claims && res.claims.admin);
        if (!isAdmin) {
          gateMessage('Access denied',
            'This account does not hold ZITLAS administrator privileges. If you were ' +
            'just granted admin, sign out and back in so your session picks up the change.',
            [{ label: 'Sign out', onClick: signOut }]);
          return;
        }
        state.user = user;
        state.token = res.token;
        enterPortal(user);
      }).catch(function (e) {
        console.error('[ADMIN] claim check failed', e);
        gateMessage('Could not verify access',
          'Your administrator status could not be confirmed. Try again shortly.',
          [{ label: 'Retry', primary: true, onClick: function () { window.location.reload(); } }]);
      });
    });
  }

  function signOut() {
    if (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.signOut) {
      ZitlasAuth.signOut().then(toLogin).catch(toLogin);
    } else {
      toLogin();
    }
  }

  function enterPortal(user) {
    $('apGate').hidden = true;
    $('apGate').style.display = 'none';
    $('apShell').hidden = false;

    var name = user.displayName || user.email || 'Admin';
    $('apUserName').textContent = name;
    $('apAvatar').textContent = name.charAt(0).toUpperCase();

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
