/* =============================================
   ZITLAS Membership & Billing — membership.js
   ============================================= */

(function () {
  'use strict';

  /* ── Storage keys ── */
  var MEMBERSHIP_KEY     = 'zitlas_membership';
  var GOAL_RESETS_KEY    = 'zitlas_weekly_goal_resets';
  var MEAL_SWAPS_KEY     = 'zitlas_weekly_meal_swaps';

  /* ── Plan limits ──
     DEAD, AND DELIBERATELY NOT THE SOURCE OF TRUTH. Nothing calls
     canResetGoal / canSwapMeal / recordGoalReset / recordMealSwap any more —
     verified by grep across the whole website. They are the pre-server-side
     localStorage counters, and their numbers have ALREADY drifted from what
     the backend actually enforces (free is 2 goal resets and 70 meal swaps,
     premium is unlimited on both — see services/entitlements.py).

     The real limits come from GET /api/entitlements and are rendered through
     fmtLimit() below; enforcement is server-side in
     services/entitlements.py::reserve(). Do NOT wire these back up — a
     second counter on the user's own device is exactly what the server-side
     allowance replaced, and these numbers would contradict it. */
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

      /* If the Wallet is frozen (server-driven — GET /api/system/trial-mode),
         there is no balance to spend from, so Premium falls back to buying
         directly from Razorpay. This keeps Premium purchasable if the wallet
         is ever refrozen by flipping WALLET_ENABLED. */
      if (_walletFrozen()) {
        _payWithRazorpay(billing);
        return;
      }

      /* WALLET FIRST. The ZITLAS Wallet is the internal payment balance:
         Razorpay puts money IN, and the wallet pays for Premium. So the
         upgrade tries to charge the balance the athlete already holds, and
         Razorpay is never opened when that succeeds.

         On 402 (insufficient) NOTHING was charged and Premium was not
         activated — the athlete is told how much is missing and offered
         Add Funds. Razorpay is NOT launched automatically: topping up is an
         explicit choice, not a surprise checkout sheet. */
      btn.textContent = 'Paying from wallet…';
      _payWithWallet(billing, function onNeedsFunds(detail) {
        _showInsufficientBalance(detail, billing);
        _resetBtn();
      });
      return;
    });

    /* Charges the wallet. Calls `onNeedsFunds(detail)` when the balance is
       short; every other failure is reported in place. */
    function _payWithWallet(billing, onNeedsFunds) {
      getIdToken().then(function (token) {
        return fetch('/api/payment/membership/purchase-with-wallet', {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
          /* One key per button press, reused if the request is retried, so a
             double-tap cannot be charged twice. */
          body: JSON.stringify({ billing: billing, idempotencyKey: _purchaseKey() }),
        });
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          return { status: res.status, data: data };
        });
      }).then(function (result) {
        if (result.status === 200) {
          showToast('✅ Premium activated — paid from your wallet.');
          setTimeout(function () { window.location.reload(); }, 1200);
          return;
        }
        if (result.status === 402) {
          onNeedsFunds((result.data && result.data.detail) || {});
          return;
        }
        console.error('[MEMBERSHIP] wallet purchase failed', result);
        showToast('Could not complete the upgrade — please try again.');
        _resetBtn();
      }).catch(function (e) {
        console.error('[MEMBERSHIP] wallet purchase failed', e);
        showToast('Could not complete the upgrade — please try again.');
        _resetBtn();
      });
    }

    /* Server-driven, exactly like components/wallet.js reads it. Defaults to
       NOT frozen: the wallet endpoint answers 503 wallet_frozen on its own if
       it really is, which is handled above, whereas wrongly assuming frozen
       would skip the wallet for someone who has the money. */
    function _walletFrozen() {
      try {
        if (typeof ZitlasPayment !== 'undefined' &&
            typeof ZitlasPayment.isWalletFrozen === 'function') {
          return ZitlasPayment.isWalletFrozen();
        }
      } catch (_) {}
      return false;
    }

    /* One idempotency token per press of the Upgrade button. */
    function _purchaseKey() {
      if (!_purchaseKey._value) {
        _purchaseKey._value = 'web_' + Date.now() + '_' +
          Math.random().toString(36).slice(2, 8);
      }
      return _purchaseKey._value;
    }

    /* Tells the athlete exactly how short they are and offers Add Funds.
       Deliberately does NOT open Razorpay by itself. */
    function _showInsufficientBalance(detail, billing) {
      var requiredRs = typeof detail.requiredRupees === 'number'
        ? detail.requiredRupees : (detail.required || 0) / 100;
      var availableRs = typeof detail.availableRupees === 'number'
        ? detail.availableRupees : (detail.available || 0) / 100;
      var shortRs = Math.max(0, requiredRs - availableRs);

      showToast(
        'Insufficient wallet balance — your wallet has ₹' + availableRs.toFixed(2) +
        ' and Premium costs ₹' + requiredRs.toFixed(2) + '. ' +
        'Please add funds to continue (₹' + shortRs.toFixed(2) + ' more).',
        6000
      );
      _offerAddFunds(shortRs);
    }

    /* Surfaces an explicit Add Funds action. The Wallet owns the top-up
       (and its own Razorpay flow); this only sends the athlete there. */
    function _offerAddFunds(shortRs) {
      try {
        if (typeof ZitlasWallet !== 'undefined' &&
            typeof ZitlasWallet.openAddFunds === 'function') {
          ZitlasWallet.openAddFunds(shortRs);
          return;
        }
        if (typeof ZitlasWallet !== 'undefined' &&
            typeof ZitlasWallet.open === 'function') {
          ZitlasWallet.open();
          return;
        }
      } catch (e) {
        console.warn('[MEMBERSHIP] could not open the wallet sheet', e);
      }
      window.location.href = '/pages/profile/profile.html#wallet';
    }

    /* Razorpay-direct Premium purchase. RETAINED and still server-verified —
       it is the path for buying Premium without first funding the wallet, and
       the endpoint it calls is unchanged. It is no longer what the Upgrade
       button reaches first. */
    function _payWithRazorpay(billing) {
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
    }

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

  /* ── Entitlements: one source of truth ────────────────────────────────
     Every quota shown on this page comes from GET /api/entitlements, which
     serves the SAME numbers services/entitlements.py enforces. The page
     deliberately keeps no copy of them: the previous hard-coded table said
     "3 goal resets" and "25 meal swaps" while the backend matrix was 2 and
     70/unlimited, and nothing made that contradiction visible.

     Premium meal swaps render as "Unlimited" because the limit really is a
     null sentinel server-side — not 500, not any number. */
  function fmtLimit(value) {
    if (value === 'unlimited' || value === null || value === undefined) return 'Unlimited';
    return String(value);
  }

  function setText(id, text) {
    var el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  function applyEntitlements(data) {
    if (!data || !data.plans) return;
    var free = (data.plans.free && data.plans.free.limits) || {};
    var prem = (data.plans.premium && data.plans.premium.limits) || {};

    setText('mbCmpGoalFree',   fmtLimit(free.goal_reset));
    setText('mbCmpGoalPrem',   fmtLimit(prem.goal_reset));
    setText('mbCmpSwapFree',   fmtLimit(free.meal_swap));
    setText('mbCmpSwapPrem',   '🔥 ' + fmtLimit(prem.meal_swap));
    setText('mbCmpRecipeFree', fmtLimit(free.recipe));
    setText('mbCmpRecipePrem', fmtLimit(prem.recipe));

    setText('mbPremGoal',   fmtLimit(prem.goal_reset) + ' Goal Set/Resets per week');
    setText('mbPremSwap',   fmtLimit(prem.meal_swap) + ' Meal Swaps');
    setText('mbPremRecipe', fmtLimit(prem.recipe) + ' Recipes per week');

    var price = data.plans.premium && data.plans.premium.priceInr;
    if (price) setText('mbPremiumPrice', '₹' + price);
  }

  function loadEntitlements() {
    if (typeof getIdToken !== 'function') return;
    getIdToken().then(function (token) {
      if (!token) return;
      return fetch('/api/entitlements', {
        headers: { 'Authorization': 'Bearer ' + token }
      }).then(function (r) { return r.ok ? r.json() : null; })
        .then(applyEntitlements);
    }).catch(function (e) {
      // The static placeholders stay put — a failed fetch must not blank
      // the comparison table.
      console.warn('[MEMBERSHIP] entitlements unavailable', e);
    });
  }

  loadEntitlements();

})();
