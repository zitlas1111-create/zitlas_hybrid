/* =============================================
   ZITLAS Membership & Billing — membership.js
   ============================================= */

(function () {
  'use strict';

  /* ── Storage keys ── */
  var MEMBERSHIP_KEY     = 'zitlas_membership';
  var GOAL_RESETS_KEY    = 'zitlas_weekly_goal_resets';
  var MEAL_SWAPS_KEY     = 'zitlas_weekly_meal_swaps';

  /* ── Plan limits ── */
  var LIMITS = {
    basic:   { goalResets: 3,        mealSwaps: 5 },
    premium: { goalResets: 5,        mealSwaps: 25 },
  };

  /* ── ISO week key: "YYYY-Www" ── */
  function getWeekKey() {
    var d   = new Date();
    var jan = new Date(d.getFullYear(), 0, 1);
    var wk  = Math.ceil((((d - jan) / 86400000) + jan.getDay() + 1) / 7);
    return d.getFullYear() + '-W' + (wk < 10 ? '0' : '') + wk;
  }

  /* ── Read / reset weekly counter ── */
  function readCounter(key) {
    try {
      var raw = localStorage.getItem(key);
      if (!raw) return { count: 0, week_key: getWeekKey() };
      var obj = JSON.parse(raw);
      if (obj.week_key !== getWeekKey()) return { count: 0, week_key: getWeekKey() };
      return obj;
    } catch (_) {
      return { count: 0, week_key: getWeekKey() };
    }
  }

  function writeCounter(key, count) {
    try {
      localStorage.setItem(key, JSON.stringify({ count: count, week_key: getWeekKey() }));
    } catch (_) {}
  }

  /* ────────────────────────────────────────────
     window.ZitlasMembership — public helpers
  ──────────────────────────────────────────── */
  window.ZitlasMembership = {
    getMembership: function () {
      var fallback = { plan: 'basic', billing: 'monthly', active: true, started_at: new Date().toISOString() };
      try {
        var raw = localStorage.getItem(MEMBERSHIP_KEY);
        if (!raw) return fallback;
        var m = JSON.parse(raw);
        /* Expired premium degrades to basic automatically — the paid
           term (premium_expiry_date, written by the backend verify) is
           the authority, never a client-set flag. */
        if (m && m.plan === 'premium' && m.premium_expiry_date &&
            new Date(m.premium_expiry_date) <= new Date()) {
          return { plan: 'basic', billing: m.billing || 'monthly', active: true,
                   started_at: m.started_at, premium_expired: true };
        }
        return m || fallback;
      } catch (_) {
        return fallback;
      }
    },

    getCurrentPlan: function () {
      return this.getMembership().plan || 'basic';
    },

    canResetGoal: function () {
      var plan    = this.getCurrentPlan();
      var limit   = LIMITS[plan] ? LIMITS[plan].goalResets : LIMITS.basic.goalResets;
      var counter = readCounter(GOAL_RESETS_KEY);
      return { allowed: counter.count < limit, remaining: Math.max(0, limit - counter.count), limit: limit };
    },

    canSwapMeal: function () {
      var plan    = this.getCurrentPlan();
      var limit   = LIMITS[plan] ? LIMITS[plan].mealSwaps : LIMITS.basic.mealSwaps;
      var counter = readCounter(MEAL_SWAPS_KEY);
      if (limit === Infinity) return { allowed: true, remaining: Infinity, limit: Infinity };
      return { allowed: counter.count < limit, remaining: Math.max(0, limit - counter.count), limit: limit };
    },

    recordGoalReset: function () {
      var counter = readCounter(GOAL_RESETS_KEY);
      writeCounter(GOAL_RESETS_KEY, counter.count + 1);
    },

    recordMealSwap: function () {
      var counter = readCounter(MEAL_SWAPS_KEY);
      writeCounter(MEAL_SWAPS_KEY, counter.count + 1);
    },
  };

  /* ────────────────────────────────────────────
     Page-specific logic below
  ──────────────────────────────────────────── */

  var _billing = 'monthly';

  /* ── Theme ── */
  function loadTheme() {
    var pref = localStorage.getItem('zitlas_theme') || 'dark';
    var resolved = pref === 'system'
      ? (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
      : pref;
    document.documentElement.setAttribute('data-theme', resolved);
  }

  /* ── Toast ── */
  var _toastTimer;
  function showToast(msg) {
    var el = document.getElementById('mbToast');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2800);
  }

  /* ── Price label for premium based on billing ── */
  function getPremiumPrice(billing) {
    return billing === 'yearly' ? '₹999' : '₹149';
  }
  function getPremiumPeriod(billing) {
    return billing === 'yearly' ? '/year' : '/month';
  }

  /* ── Render the full plan UI ── */
  function renderPlanUI(membership) {
    var plan = (membership && membership.plan) || 'basic';
    var isPremium = plan === 'premium';

    /* Current plan banner */
    var cpIcon   = document.getElementById('mbCpIcon');
    var cpName   = document.getElementById('mbCpName');
    if (cpIcon) cpIcon.textContent = isPremium ? '⭐' : '🆓';
    if (cpName) cpName.textContent = isPremium ? 'Premium' : 'Basic';

    /* Basic card chip + button */
    var chipBasic   = document.getElementById('mbChipBasic');
    var btnBasic    = document.getElementById('mbBtnBasic');
    if (chipBasic) chipBasic.style.display = isPremium ? 'none' : '';
    if (btnBasic) {
      if (isPremium) {
        btnBasic.textContent = 'Downgrade';
        btnBasic.disabled    = false;
        btnBasic.className   = 'mb-action-btn mb-action-btn--current';
        btnBasic.style.cursor = 'not-allowed';
      } else {
        btnBasic.textContent = 'Current Plan';
        btnBasic.disabled    = true;
        btnBasic.className   = 'mb-action-btn mb-action-btn--current';
      }
    }

    /* Premium card chip + button */
    var chipPremium = document.getElementById('mbChipPremium');
    var btnUpgrade  = document.getElementById('mbBtnUpgrade');
    if (chipPremium) chipPremium.style.display = isPremium ? '' : 'none';
    if (btnUpgrade) {
      if (isPremium) {
        btnUpgrade.textContent = 'Current Plan';
        btnUpgrade.disabled    = true;
        btnUpgrade.className   = 'mb-action-btn mb-action-btn--on-premium';
      } else {
        btnUpgrade.textContent = 'Upgrade to Premium';
        btnUpgrade.disabled    = false;
        btnUpgrade.className   = 'mb-action-btn mb-action-btn--upgrade';
      }
    }

    /* Update premium price label */
    var priceEl  = document.getElementById('mbPremiumPrice');
    var periodEl = document.getElementById('mbPremiumPeriod');
    if (priceEl)  priceEl.textContent  = getPremiumPrice(_billing);
    if (periodEl) periodEl.textContent = getPremiumPeriod(_billing);
  }

  /* ── Billing toggle ── */
  function initBillingToggle() {
    var btnMonthly = document.getElementById('mbBtnMonthly');
    var btnYearly  = document.getElementById('mbBtnYearly');
    if (!btnMonthly || !btnYearly) return;

    function selectBilling(billing) {
      _billing = billing;
      btnMonthly.classList.toggle('active', billing === 'monthly');
      btnYearly.classList.toggle('active',  billing === 'yearly');

      var priceEl  = document.getElementById('mbPremiumPrice');
      var periodEl = document.getElementById('mbPremiumPeriod');
      if (priceEl)  priceEl.textContent  = getPremiumPrice(billing);
      if (periodEl) periodEl.textContent = getPremiumPeriod(billing);
    }

    btnMonthly.addEventListener('click', function () { selectBilling('monthly'); });
    btnYearly.addEventListener('click',  function () { selectBilling('yearly'); });
  }

  /* ── Upgrade handler ── */
  function initUpgradeBtn() {
    var btn = document.getElementById('mbBtnUpgrade');
    if (!btn) return;

    /* REAL PAYMENT FLOW — Premium is NEVER granted before a verified
       payment. Select billing → backend creates a Razorpay order with a
       SERVER-authoritative price (₹149/mo, ₹999/yr) → Razorpay checkout →
       backend verifies the HMAC signature and, only then, writes
       users/{uid}.membership (plan, premium_plan, start/expiry dates,
       payment_id, order_id, payment_status) inside a transaction. The
       verified membership object returned by the backend is what gets
       mirrored locally — the client never fabricates premium state.
       (The old handler here activated premium instantly on click, no
       payment — removed.) */
    function _resetBtn() { btn.disabled = false; btn.textContent = 'Upgrade to Premium'; }

    btn.addEventListener('click', function () {
      var membership = window.ZitlasMembership.getMembership();
      if (membership.plan === 'premium') return;
      if (typeof Razorpay === 'undefined') { showToast('Payment unavailable — please reload the page.'); return; }
      if (typeof getIdToken !== 'function' ||
          (typeof ZitlasAuth !== 'undefined' && !ZitlasAuth.currentUser)) {
        showToast('Please sign in first.');
        return;
      }

      var billing = _billing === 'yearly' ? 'yearly' : 'monthly';
      btn.disabled = true;
      btn.textContent = 'Starting payment…';

      getIdToken().then(function (token) {
        return fetch('/api/payment/membership/create-order', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify({ billing: billing }),
        });
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          return { status: res.status, data: data };
        });
      }).then(function (result) {
        if (result.status !== 200) {
          console.error('[MEMBERSHIP] create-order failed', result);
          showToast('Could not start payment — please try again.');
          _resetBtn();
          return;
        }
        var order = result.data;
        var rzp = new Razorpay({
          key: order.key_id, amount: order.amount, currency: order.currency, order_id: order.order_id,
          name: 'ZITLAS Premium',
          description: billing === 'yearly' ? 'Premium — ₹999/year' : 'Premium — ₹149/month',
          handler: function (response) { _verifyMembershipPayment(response, _resetBtn); },
          modal: { ondismiss: function () { showToast('Payment cancelled.'); _resetBtn(); } },
          theme: { color: '#234B35' },
        });
        rzp.on('payment.failed', function (resp) {
          console.error('[MEMBERSHIP] razorpay payment.failed', resp && resp.error);
          showToast('Payment failed — ' + ((resp && resp.error && resp.error.description) || 'please try again.'));
          _resetBtn();
        });
        rzp.open();
      }).catch(function (e) {
        console.error('[MEMBERSHIP] create-order failed', e);
        showToast('Could not start payment — please try again.');
        _resetBtn();
      });
    });

    function _verifyMembershipPayment(razorpayResponse, resetBtn) {
      btn.textContent = 'Verifying payment…';
      getIdToken().then(function (token) {
        return fetch('/api/payment/membership/verify', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            razorpay_order_id:   razorpayResponse.razorpay_order_id,
            razorpay_payment_id: razorpayResponse.razorpay_payment_id,
            razorpay_signature:  razorpayResponse.razorpay_signature,
          }),
        });
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          return { status: res.status, data: data };
        });
      }).then(function (result) {
        if (result.status !== 200 || !result.data.success || !result.data.membership) {
          console.error('[MEMBERSHIP] verification failed', result);
          showToast('Payment could not be verified — contact support if money was deducted.');
          resetBtn();
          return;
        }
        /* The backend already wrote the authoritative users/{uid}.
           membership inside its transaction — mirror the SAME object
           locally so this session unlocks instantly; cloud-sync's
           realtime listener keeps other devices in step. */
        var m = result.data.membership;
        try { localStorage.setItem(MEMBERSHIP_KEY, JSON.stringify(m)); } catch (_) {}
        renderPlanUI(m);
        resetBtn();
        showToast('⭐ Premium activated — priority handling & higher limits unlocked!');
      }).catch(function (e) {
        console.error('[MEMBERSHIP] verification failed', e);
        showToast('Payment could not be verified — contact support if money was deducted.');
        resetBtn();
      });
    }
  }

  /* ── Back button ── */
  function initBackBtn() {
    var btn = document.getElementById('mbBackBtn');
    if (!btn) return;
    btn.addEventListener('click', function () {
      if (history.length > 1) { history.back(); }
      else { window.location.href = '../profile.html'; }
    });
  }

  /* ── INIT ── */
  function init() {
    loadTheme();
    var membership = window.ZitlasMembership.getMembership();
    /* One-time migration/heal: existing premium members upgraded BEFORE
       membership was cloud-synced have the plan only in this device's
       localStorage — push it to users/{uid}.membership so their platform
       charges actually get waived (the charge transaction reads ONLY the
       cloud copy). Idempotent merge write, cheap to repeat. */
    if (membership.plan === 'premium' && typeof ZitlasCloudSync !== 'undefined') {
      ZitlasCloudSync.save('membership', membership);
    }
    _billing = (membership.billing === 'yearly') ? 'yearly' : 'monthly';
    initBillingToggle();
    renderPlanUI(membership);
    initUpgradeBtn();
    initBackBtn();

    /* Sync billing toggle pill to stored billing on load */
    var btnMonthly = document.getElementById('mbBtnMonthly');
    var btnYearly  = document.getElementById('mbBtnYearly');
    if (btnMonthly && btnYearly) {
      btnMonthly.classList.toggle('active', _billing === 'monthly');
      btnYearly.classList.toggle('active',  _billing === 'yearly');
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
