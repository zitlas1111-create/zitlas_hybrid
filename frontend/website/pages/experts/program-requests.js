/*!
 * ZITLAS — Personal Coaching Program Requests, expert side
 * (frontend/website/pages/experts/program-requests.js)
 *
 * The programs athletes have requested from THIS expert, with Accept /
 * Decline. Everything goes through /api/coaching-programs — the
 * coaching_program_requests collection is backend-only in firestore.rules,
 * and the server checks that the request is really this expert's.
 *
 * Phase 2: accepting does NOT charge the athlete and does NOT start
 * coaching. The request simply waits with payment pending.
 *
 * Separate from the existing Personal Coaching inbox in expert-dashboard.js
 * (personal_coach_requests), which is unchanged.
 */
(function () {
  'use strict';

  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var STATUS_PENDING = 'pending_expert_acceptance';

  var _requests = [];
  var _busy = {};

  function $(id) { return document.getElementById(id); }

  function escHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* 1234567 → '12,34,567' — Indian grouping, same as the app and wallet. */
  function groupIndian(n) {
    var digits = String(n);
    if (digits.length <= 3) return digits;
    var last3 = digits.slice(-3);
    var head = digits.slice(0, -3);
    var groups = [];
    while (head.length > 2) { groups.unshift(head.slice(-2)); head = head.slice(0, -2); }
    if (head) groups.unshift(head);
    return groups.join(',') + ',' + last3;
  }

  /* 499900 → '₹4,999' · 49950 → '₹499.50'. Never '₹0' for a missing price. */
  function formatPaise(paise) {
    if (typeof paise !== 'number' || !isFinite(paise) || paise <= 0 || Math.floor(paise) !== paise) {
      return '—';
    }
    var rupees = Math.floor(paise / 100);
    var cents = paise % 100;
    return '₹' + groupIndian(rupees) + (cents ? '.' + (cents < 10 ? '0' + cents : String(cents)) : '');
  }

  function formatRequestedDate(iso) {
    var d = new Date(iso);
    if (!iso || isNaN(d.getTime())) return '—';
    return d.getDate() + ' ' + MONTHS[d.getMonth()] + ' ' + d.getFullYear();
  }

  function statusLine(req) {
    if (req.status === STATUS_PENDING) return '🟢 Awaiting your response';
    if (req.status === 'accepted') return '✅ Accepted — payment pending';
    if (req.status === 'active') {
      return '💳 Paid — program active' +
        (req.endsAt ? ' until ' + formatRequestedDate(req.endsAt) : '');
    }
    if (req.status === 'declined') return '❌ Declined';
    return String(req.status || '');
  }

  function initialsOf(name) {
    return String(name || 'Athlete').split(/\s+/).map(function (w) { return w[0] || ''; })
      .slice(0, 2).join('').toUpperCase();
  }

  /* One request card — Athlete, Program, Duration, Price, Requested date,
     and Accept / Decline while it is waiting. Every value is escaped. */
  function cprCardHtml(req) {
    var name = req.athleteName || 'Athlete';
    var days = Number(req.durationDays);
    return '' +
      '<div class="ed-user-av">' + escHtml(initialsOf(name)) + '</div>' +
      '<div class="ed-user-info">' +
        '<span class="ed-user-name" title="Athlete">' + escHtml(name) + '</span>' +
        '<div class="ed-user-chips">' +
          '<span class="ed-chip ed-chip--type" title="Program">🗓️ ' +
            escHtml(req.programTitle || req.programId || 'Program') + '</span>' +
          '<span class="ed-chip ed-chip--type" title="Duration">' +
            escHtml(days > 0 ? days + ' days' : '—') + '</span>' +
          '<span class="ed-chip ed-chip--price" title="Price">' + escHtml(formatPaise(req.pricePaise)) + '</span>' +
        '</div>' +
        '<span class="ed-user-sub">Requested ' + escHtml(formatRequestedDate(req.requestedAt)) +
          ' · ' + escHtml(statusLine(req)) + '</span>' +
      '</div>' +
      (req.status === STATUS_PENDING
        ? '<div class="pc-req-actions">' +
            '<button class="erc-btn erc-btn--secondary cpr-decline" type="button">Decline</button>' +
            '<button class="erc-btn erc-btn--primary cpr-accept" type="button">Accept</button>' +
          '</div>'
        : '');
  }

  function toast(msg) {
    if (typeof edShowToast === 'function') edShowToast(msg);
    else console.log('[PROGRAM REQUESTS]', msg);
  }

  function render() {
    var wrap = $('cprRequestList');
    if (!wrap) return;
    var empty = $('cprEmpty');
    var badge = $('cprPendingCount');

    wrap.querySelectorAll('.cpr-card').forEach(function (el) { el.remove(); });
    if (empty) empty.style.display = _requests.length ? 'none' : '';

    var pending = _requests.filter(function (r) { return r.status === STATUS_PENDING; }).length;
    if (badge) {
      badge.textContent = pending;
      badge.style.display = pending > 0 ? '' : 'none';
    }

    _requests.forEach(function (req) {
      var card = document.createElement('div');
      card.className = 'ed-user-card cpr-card';
      card.setAttribute('data-request-id', req.requestId || '');
      card.innerHTML = cprCardHtml(req);
      var accept = card.querySelector('.cpr-accept');
      var decline = card.querySelector('.cpr-decline');
      if (accept) accept.addEventListener('click', function () { decide(req, 'accept', card); });
      if (decline) decline.addEventListener('click', function () { decide(req, 'decline', card); });
      wrap.appendChild(card);
    });
  }

  function api(path, method) {
    if (typeof getIdToken !== 'function') return Promise.reject(new Error('no_auth'));
    return getIdToken().then(function (token) {
      return fetch(path, { method: method, headers: { 'Authorization': 'Bearer ' + token } });
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        return { status: res.status, data: data };
      });
    });
  }

  function refresh() {
    return api('/api/coaching-programs/requests/expert', 'GET').then(function (r) {
      var block = $('cprBlock');
      if (r.status === 200) {
        _requests = (r.data && r.data.requests) || [];
        if (block) block.style.display = '';
        render();
      } else if (r.status === 403) {
        // Not an approved expert — nothing to show, and nothing to act on.
        if (block) block.style.display = 'none';
      } else {
        console.warn('[PROGRAM REQUESTS] load failed', r);
      }
    }).catch(function (e) { console.warn('[PROGRAM REQUESTS] load failed', e); });
  }

  function decide(req, decision, card) {
    var id = req.requestId;
    if (!id || _busy[id]) return;
    _busy[id] = true;
    if (card) card.querySelectorAll('button').forEach(function (b) { b.disabled = true; });

    api('/api/coaching-programs/requests/' + encodeURIComponent(id) + '/' + decision, 'POST')
      .then(function (r) {
        if (r.status === 200 && r.data && r.data.success) {
          toast(r.data.message || (decision === 'accept'
            ? 'Program request accepted. Payment is pending.'
            : 'Program request declined.'));
        } else if (r.status === 409) {
          toast('This request was already handled.');
        } else if (r.status === 403) {
          toast('This request is not assigned to you.');
        } else {
          console.error('[PROGRAM REQUESTS] ' + decision + ' failed', r);
          toast('Could not update the request — please try again.');
        }
      })
      .catch(function (e) {
        console.error('[PROGRAM REQUESTS] ' + decision + ' failed', e);
        toast('Could not update the request — please try again.');
      })
      .then(function () {
        _busy[id] = false;
        return refresh();
      });
  }

  function init() {
    if (!$('cprBlock')) return;
    var refreshBtn = $('cprRefresh');
    if (refreshBtn) refreshBtn.addEventListener('click', refresh);
    var nav = document.querySelector('[data-section="sectionCoaching"]');
    if (nav) nav.addEventListener('click', refresh);
    if (typeof ZitlasAuth !== 'undefined') {
      ZitlasAuth.onAuthStateChanged(function (user) { if (user) refresh(); });
    }
  }

  window.ZitlasProgramRequests = { refresh: refresh };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
