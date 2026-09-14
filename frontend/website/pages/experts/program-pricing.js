/*!
 * ZITLAS — Personal Coaching Program pricing (frontend/website/pages/experts/program-pricing.js)
 *
 * The expert's 10-Day / 1-Month / 3-Month program prices. Saved ONLY through
 * PUT /api/coaching-programs/pricing: the backend validates every value and
 * stores experts/{uid}.programPricing in integer paise (firestore.rules
 * refuses a direct client write to that field). The checks below are for a
 * helpful message — the server is the authority and re-checks everything.
 *
 * Separate from pricing.js on purpose: that file keeps editing the existing
 * review / chat / monthly coaching prices exactly as before.
 */
(function () {
  'use strict';

  var PROGRAMS = [
    { id: '10_day',  el: 'prProgram10Day',  title: '10-Day Program' },
    { id: '1_month', el: 'prProgram1Month', title: '1-Month Program' },
    { id: '3_month', el: 'prProgram3Month', title: '3-Month Program' },
  ];

  /* Mirrors backend/services/coaching_programs.py (MIN/MAX_PRICE_PAISE);
     replaced by the server's own limits as soon as they load. */
  var limits = { minPaise: 100, maxPaise: 5000000 };

  var SERVER_ERRORS = {
    price_not_integer_paise: 'Enter a price in rupees, like 499 or 499.50.',
    price_must_be_positive:  'Price must be more than ₹0.',
    price_below_minimum:     'This price is below the minimum.',
    price_above_maximum:     'This price is above the maximum.',
    unknown_program:         'This program is not recognised.',
    prices_required:         'Enter at least one price.',
  };

  function $(id) { return document.getElementById(id); }

  /* 49900 → '499', 49950 → '499.50'. Integer maths — no float rounding. */
  function paiseToRupeesText(paise) {
    var rupees = Math.floor(paise / 100);
    var cents = paise % 100;
    return cents ? rupees + '.' + (cents < 10 ? '0' + cents : String(cents)) : String(rupees);
  }

  /* '499' → 49900 · '499.5' → 49950 · '' → null (not offered).
     Refused: 0, negatives, NaN, Infinity, '1e3', '499.555', anything outside
     the limits. Parsed from the text itself, never through parseFloat, so
     '0.1 + 0.2'-style float error cannot creep into a price. */
  function parseRupeesToPaise(raw, lim) {
    lim = lim || limits;
    var s = String(raw == null ? '' : raw).trim().replace(/,/g, '');
    if (s === '') return { ok: true, paise: null };
    if (!/^\d{1,9}(\.\d{1,2})?$/.test(s)) {
      return { ok: false, error: 'Enter a price in rupees, like 499 or 499.50.' };
    }
    var parts = s.split('.');
    var paise = parseInt(parts[0], 10) * 100 +
      (parts[1] ? parseInt((parts[1] + '0').slice(0, 2), 10) : 0);
    if (!isFinite(paise) || paise <= 0) return { ok: false, error: 'Price must be more than ₹0.' };
    if (paise < lim.minPaise) {
      return { ok: false, error: 'The lowest price is ₹' + paiseToRupeesText(lim.minPaise) + '.' };
    }
    if (paise > lim.maxPaise) {
      return { ok: false, error: 'The highest price is ₹' + paiseToRupeesText(lim.maxPaise) + '.' };
    }
    return { ok: true, paise: paise };
  }

  /* { '10_day': '499', ... } → { ok, prices: {id: paise|null}, errors: {id: msg} } */
  function collectProgramPrices(values, lim) {
    var prices = {};
    var errors = {};
    PROGRAMS.forEach(function (p) {
      var r = parseRupeesToPaise(values[p.id], lim);
      if (r.ok) prices[p.id] = r.paise;
      else errors[p.id] = r.error;
    });
    return { ok: Object.keys(errors).length === 0, prices: prices, errors: errors };
  }

  function showToast(msg) {
    var t = $('prToast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(showToast._t);
    showToast._t = setTimeout(function () { t.classList.remove('show'); }, 2600);
  }

  function setFieldError(p, msg) {
    var el = $(p.el + 'Error');
    if (!el) return;
    el.textContent = msg || '';
    el.hidden = !msg;
  }

  function renderLimits() {
    var hint = $('prProgramLimits');
    if (hint) {
      hint.textContent = 'Prices from ₹' + paiseToRupeesText(limits.minPaise) +
        ' to ₹' + Number(limits.maxPaise / 100).toLocaleString('en-IN') + '.';
    }
  }

  function fillFromServer(body) {
    if (body && body.limits && body.limits.minPaise > 0 && body.limits.maxPaise > 0) {
      limits = { minPaise: body.limits.minPaise, maxPaise: body.limits.maxPaise };
    }
    var byId = {};
    ((body && body.programs) || []).forEach(function (p) { byId[p.programId] = p; });
    PROGRAMS.forEach(function (p) {
      var input = $(p.el);
      if (!input) return;
      var price = byId[p.id] && byId[p.id].pricePaise;
      input.value = (typeof price === 'number' && price > 0) ? paiseToRupeesText(price) : '';
      setFieldError(p, '');
    });
    renderLimits();
  }

  function api(method, body) {
    if (typeof getIdToken !== 'function') return Promise.reject(new Error('no_auth'));
    return getIdToken().then(function (token) {
      var opts = { method: method, headers: { 'Authorization': 'Bearer ' + token } };
      if (body) {
        opts.headers['Content-Type'] = 'application/json';
        opts.body = JSON.stringify(body);
      }
      return fetch(method === 'GET' ? '/api/coaching-programs/pricing/me'
                                    : '/api/coaching-programs/pricing', opts);
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        return { status: res.status, data: data };
      });
    });
  }

  function loadProgramPricing() {
    api('GET').then(function (r) {
      if (r.status === 200) fillFromServer(r.data);
      else if (r.status === 403) showToast('Only approved experts can set program prices.');
      else console.warn('[PROGRAM PRICING] load failed', r);
    }).catch(function (e) { console.warn('[PROGRAM PRICING] load failed', e); });
  }

  function saveProgramPricing() {
    var values = {};
    PROGRAMS.forEach(function (p) { var i = $(p.el); values[p.id] = i ? i.value : ''; });
    var result = collectProgramPrices(values, limits);
    PROGRAMS.forEach(function (p) { setFieldError(p, result.errors[p.id]); });
    if (!result.ok) { showToast('Please fix the highlighted prices.'); return; }

    var btn = $('prProgramSaveBtn');
    if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
    api('PUT', { prices: result.prices }).then(function (r) {
      if (r.status === 200 && r.data && r.data.success) {
        fillFromServer(r.data);
        showToast('✅ Program pricing saved.');
      } else if (r.status === 400 && r.data && r.data.detail && r.data.detail.error) {
        var p = PROGRAMS.filter(function (x) { return x.id === r.data.detail.programId; })[0];
        var msg = SERVER_ERRORS[r.data.detail.error] || 'Please check this price.';
        if (p) setFieldError(p, msg);
        showToast(msg);
      } else if (r.status === 401) {
        showToast('Please sign in again to save.');
      } else if (r.status === 403) {
        showToast('Only approved experts can set program prices.');
      } else {
        console.error('[PROGRAM PRICING] save failed', r);
        showToast('Could not save program pricing — please try again.');
      }
    }).catch(function (e) {
      console.error('[PROGRAM PRICING] save failed', e);
      showToast('Could not save program pricing — please try again.');
    }).then(function () {
      if (btn) { btn.disabled = false; btn.textContent = 'Save Pricing'; }
    });
  }

  function init() {
    if (!$('prProgramCard')) return;
    renderLimits();
    var btn = $('prProgramSaveBtn');
    if (btn) btn.addEventListener('click', saveProgramPricing);
    if (typeof ZitlasAuth !== 'undefined') {
      ZitlasAuth.onAuthStateChanged(function (user) { if (user) loadProgramPricing(); });
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
