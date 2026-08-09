/*!
 * ZITLAS — Shared Payment Engine (assets/js/payment-service.js)
 *
 * The ONE place money moves for Review Verification, Expert Chat, and
 * Personal Coaching. Money is never deducted when a request is sent —
 * only attemptCharge() below moves money, and it only ever runs when an
 * expert has just pressed Accept.
 *
 * SECURITY: the whole read-check-write sequence runs inside a single
 * Firestore transaction (db.runTransaction). That gives three guarantees
 * for free, which is why nothing here uses a plain get()+then()+update():
 *   - Duplicate deduction is impossible: the transaction re-reads the
 *     request doc fresh, and if paymentStatus is already 'paid' (from an
 *     earlier successful run — a double-click, two tabs, a retried
 *     network call) it short-circuits to a no-op success instead of
 *     charging again.
 *   - Race conditions are impossible: if two attemptCharge() calls run
 *     concurrently (e.g. the athlete's retry-after-recharge fires at the
 *     same moment as the expert's auto-attempt), Firestore serializes them
 *     — the second transaction automatically retries against the first
 *     one's committed result and hits the same 'already paid' short-circuit.
 *   - "Multiple accepts" is covered by callers additionally gating on the
 *     request's own `status` field before calling this at all (see
 *     expert-dashboard.js) — this module only owns the money part.
 */
(function (win) {
  'use strict';

  // Single configurable point — ZITLAS's cut of every payment.
  var PLATFORM_FEE_PERCENT = 0.20;

  /* ══════════════════════════════════════════════════════════════════
     CLIENT TRIAL MODE — coach payments disabled, Premium untouched.
     The SINGLE switch lives in backend/trial_config.py; this module
     mirrors it via GET /api/system/trial-mode (fetched once per page
     load, cached in localStorage so later loads know synchronously).
     While true:
       - attemptCharge() (reviews / expert chat / any coach service
         charged through it) grants access at ₹0 — no wallet deduction,
         no insufficient-balance path, request advances exactly as paid
       - showLowBalancePopup() is a no-op (its only callers are coach
         service flows; wallet RECHARGE UI lives in wallet.js and stays)
     Premium plan payments and Razorpay wallet recharge NEVER route
     through this module's charge path, so they keep working normally.
  ══════════════════════════════════════════════════════════════════ */
  var _TRIAL_LS_KEY = 'zitlas_trial_mode';
  var _trialMode = (function () {
    try { return localStorage.getItem(_TRIAL_LS_KEY) === 'true'; } catch (_) { return false; }
  })();
  (function _refreshTrialFlag() {
    try {
      fetch('/api/system/trial-mode').then(function (r) { return r.ok ? r.json() : null; })
        .then(function (data) {
          if (!data) return;
          /* effectiveFree = CLIENT_TRIAL_MODE or PLATFORM_CHARGES_FREE
             (the PERMANENT monetization policy: all expert services are
             free for every user; only the Premium subscription is paid).
             Older backends without the field fall back to the trial
             flag alone. */
          var eff = (typeof data.effectiveFree === 'boolean')
            ? data.effectiveFree
            : (typeof data.clientTrialMode === 'boolean' ? data.clientTrialMode : null);
          if (eff === null) return;
          _trialMode = eff;
          try { localStorage.setItem(_TRIAL_LS_KEY, String(_trialMode)); } catch (_) {}
          console.log('[PAYMENT] platform-free policy =', _trialMode,
            _trialMode ? '— all expert services are FREE (subscription-only monetization)' : '');
        })
        .catch(function () { /* offline/unreachable — keep cached value */ });
    } catch (_) {}
  })();
  function isTrialMode() { return _trialMode; }

  /* PREMIUM MEMBERSHIP — local, synchronous read of THIS device's user
     (zitlas_membership, cloud-synced via users/{uid}.membership). For UI
     display decisions only (price labels, "FREE with Premium" chips).
     The MONEY decision never trusts this: attemptCharge() re-reads the
     paying athlete's membership from their users/{uid} doc inside the
     transaction, because charges can execute on the expert's device. */
  /* Shared premium predicate — plan + active + not past expiry. Used for
     both the local UI read below and the in-transaction authoritative
     check inside attemptCharge (which passes the membership object from
     the athlete's users/{uid} doc). */
  function _membershipIsPremium(m) {
    if (!m || m.plan !== 'premium' || m.active === false) return false;
    if (m.premium_expiry_date) {
      try { if (new Date(m.premium_expiry_date) <= new Date()) return false; } catch (_) {}
    }
    return true;
  }

  function isPremiumMember() {
    try {
      return _membershipIsPremium(JSON.parse(localStorage.getItem('zitlas_membership') || 'null'));
    } catch (_) { return false; }
  }

  function _defaultWallet() {
    return { balance: 0, total_added: 0, total_spent: 0, transactions: [] };
  }

  function _newTxnId() {
    return 'txn_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8);
  }

  /**
   * attemptCharge({
   *   userId, expertId, amount, serviceType, serviceLabel, expertName,
   *   requestCollection, requestId,
   *   onSuccessUpdate,       // fields merged onto the request ONLY when payment succeeds
   *                          // (e.g. {status:'in_progress', chatUnlocked:true}) — never
   *                          // applied on the insufficient-balance path, so a request can
   *                          // never advance to an active/serving state without payment.
   *   notifyUser: {title, message}, notifyExpert: {title, message},
   * }) -> Promise<{success, alreadyPaid?, error?, balance?, shortfall?, required?,
   *                transactionId?, walletBefore?, walletAfter?, platformFee?, expertAmount?}>
   */
  function attemptCharge(opts) {
    var userId    = opts.userId;
    var requestId = opts.requestId;
    var reqColl   = opts.requestCollection;
    if (!userId || !requestId || !reqColl) {
      return Promise.resolve({ success: false, error: 'missing_params' });
    }

    /* SERVER-AUTHORITATIVE CHARGE (was a client-side Firestore transaction).
       The wallet lives in users/{uid}.wallet and is no longer client-writable
       under production Security Rules (FIRESTORE_SECURITY_AUDIT.md V2), so the
       balance check + debit + wallet_transactions audit record + request
       advance now happen in backend/routes/payment.py POST /charge, where the
       Admin SDK bypasses rules and the amount/free-policy can't be tampered
       with. The ₹0 platform-charge policy (CLIENT_TRIAL_MODE /
       PLATFORM_CHARGES_FREE / Premium) is re-applied there, not trusted from
       here. Return shape is unchanged so every caller keeps working:
       {success, alreadyPaid?, error?, balance?, required?, shortfall?,
        transactionId?, walletBefore?, walletAfter?}. */
    var auth = win.ZitlasAuth;
    var user = auth && auth.currentUser;
    if (!user || typeof user.getIdToken !== 'function') {
      return Promise.resolve({ success: false, error: 'not_signed_in' });
    }

    return user.getIdToken().then(function (token) {
      return fetch('/api/payment/charge', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          athleteUid: userId,
          requestCollection: reqColl,
          requestId: requestId,
          amount: Math.max(0, Number(opts.amount) || 0),
          serviceType: opts.serviceType || 'unknown',
          serviceLabel: opts.serviceLabel || null,
          expertId: opts.expertId || null,
          expertName: opts.expertName || null,
          onSuccessUpdate: opts.onSuccessUpdate || {},
          /* "Both" bundle sibling — mirrored to the paid outcome SERVER-SIDE
             (no client paymentStatus write). */
          siblingRequestId: opts.siblingRequestId || null,
        }),
      });
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        return { status: res.status, data: data || {} };
      });
    }).then(function (r) {
      /* Backend returns 200 for both success AND the graceful
         insufficient-balance outcome ({success:false, shortfall,...}); a
         non-200 is an auth/config/server error surfaced via `detail`. */
      if (r.status !== 200) {
        return { success: false, error: (r.data && r.data.detail) || ('charge_failed_' + r.status) };
      }
      var out = r.data || {};
      if (out.success && !out.alreadyPaid && typeof win.ZitlasNotify !== 'undefined') {
        if (opts.notifyUser) {
          win.ZitlasNotify.send(userId, Object.assign({ category: 'payment', type: 'service_payment' }, opts.notifyUser));
        }
        if (opts.notifyExpert && opts.expertId) {
          win.ZitlasNotify.send(opts.expertId, Object.assign({ category: 'payment', type: 'service_payment' }, opts.notifyExpert));
        }
      }
      return out;
    }).catch(function (err) {
      console.error('[PAYMENT] attemptCharge (server) failed', err);
      return { success: false, error: (err && err.message) || 'transaction_failed' };
    });
  }

  /**
   * creditWallet(opts) -> Promise<{success:false, error:'client_credit_disabled'}>
   *
   * DISABLED — client-side wallet crediting is a self-credit hole
   * (FIRESTORE_SECURITY_AUDIT.md V2) and is blocked by production Security
   * Rules (users/{uid}.wallet is backend-only). The ONLY legitimate way money
   * enters a wallet is Razorpay → POST /api/payment/verify, which credits the
   * balance server-side after an HMAC signature check (see wallet.js
   * creditFunds()/_verifyAndCreditWallet). This stub is retained so any stray
   * caller fails loudly and safely instead of throwing. Grepped: the only
   * caller was ZitlasWallet.credit(), which has no real callers itself.
   */
  function creditWallet(opts) {
    console.warn('[PAYMENT] creditWallet is disabled — wallet credit is server-only ' +
                 '(Razorpay → /api/payment/verify). Ignoring client credit request for uid=' +
                 (opts && opts.userId));
    return Promise.resolve({ success: false, error: 'client_credit_disabled' });
  }

  /* ══════════════════════════════════════════
     LOW BALANCE POPUP — shared, self-injecting
  ══════════════════════════════════════════ */

  var _cssInjected = false;
  function _injectCss() {
    if (_cssInjected) return;
    _cssInjected = true;
    var style = document.createElement('style');
    style.textContent =
      '.zpay-overlay{position:fixed;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;' +
        'justify-content:center;z-index:99999;opacity:0;transition:opacity .2s;padding:20px;box-sizing:border-box;}' +
      '.zpay-overlay.open{opacity:1;}' +
      '.zpay-card{background:var(--bg-card,#fff);border-radius:20px;padding:24px 22px;max-width:340px;width:100%;' +
        'text-align:center;transform:translateY(12px) scale(.97);transition:transform .2s;box-shadow:0 20px 60px rgba(0,0,0,.3);}' +
      '.zpay-overlay.open .zpay-card{transform:translateY(0) scale(1);}' +
      '.zpay-icon{font-size:40px;margin-bottom:8px;}' +
      '.zpay-title{font-size:17px;font-weight:800;color:var(--text-primary,#1E293B);margin-bottom:6px;}' +
      '.zpay-sub{font-size:13.5px;color:var(--text-secondary,#64748B);line-height:1.5;margin-bottom:16px;}' +
      '.zpay-row{display:flex;justify-content:space-between;font-size:13.5px;padding:8px 0;' +
        'border-top:1px solid var(--border,rgba(0,0,0,.08));color:var(--text-primary,#1E293B);}' +
      '.zpay-row span:last-child{font-weight:700;}' +
      '.zpay-btn{width:100%;padding:12px;border-radius:12px;font-size:14px;font-weight:700;margin-top:10px;' +
        'border:none;cursor:pointer;}' +
      '.zpay-btn--primary{background:linear-gradient(90deg,#16A34A,#15803D);color:#000;}' +
      '.zpay-btn--secondary{background:var(--bg-card-light,#F1F5F9);color:var(--text-secondary,#64748B);}';
    document.head.appendChild(style);
  }

  function showLowBalancePopup(opts) {
    /* CLIENT TRIAL MODE — every caller of this popup is a coach-service
       payment gate (coaching request, review/chat charge retry). During
       the trial those services are free, so a "recharge to continue"
       prompt must never appear. Wallet recharge itself stays available
       via the wallet panel (components/wallet.js), which doesn't come
       through here. */
    if (isTrialMode()) {
      console.log('[PAYMENT] CLIENT_TRIAL_MODE — low-balance popup suppressed (coach services are free)');
      return;
    }
    _injectCss();
    var balance   = Number(opts.balance || 0);
    var required  = Number(opts.required || 0);
    var shortfall = Math.max(0, required - balance);
    /* Audit requirement: never let a ₹0 balance look like "your wallet is
       empty" when it actually means "your wallet has never synced to the
       server" — those are different problems with different fixes (the
       first needs money, the second needs a page reload / re-login). */
    var syncNote = (opts.walletDocStatus === 'user_doc_missing' || opts.walletDocStatus === 'wallet_field_missing')
      ? '<p class="zpay-sub" style="color:#B35900;font-weight:700;">⚠️ Your wallet hasn\'t synced to the server yet. If you\'ve added funds before, try reloading this page — your balance shown elsewhere may be a stale local copy.</p>'
      : '';

    var existing = document.getElementById('zpayLowBalanceOverlay');
    if (existing) existing.remove();

    var overlay = document.createElement('div');
    overlay.id = 'zpayLowBalanceOverlay';
    overlay.className = 'zpay-overlay';
    overlay.innerHTML =
      '<div class="zpay-card">' +
        '<div class="zpay-icon">💰</div>' +
        '<h3 class="zpay-title">Insufficient Wallet Balance</h3>' +
        '<p class="zpay-sub">You need &#8377;' + shortfall.toLocaleString('en-IN') + ' more to start this service.</p>' +
        syncNote +
        '<div class="zpay-row"><span>Current Balance</span><span>&#8377;' + balance.toLocaleString('en-IN') + '</span></div>' +
        '<div class="zpay-row"><span>Required</span><span>&#8377;' + required.toLocaleString('en-IN') + '</span></div>' +
        '<button class="zpay-btn zpay-btn--primary" id="zpayRechargeBtn" type="button">Recharge Wallet</button>' +
        '<button class="zpay-btn zpay-btn--secondary" id="zpayCancelBtn" type="button">Cancel</button>' +
      '</div>';
    document.body.appendChild(overlay);
    requestAnimationFrame(function () { overlay.classList.add('open'); });

    function close() {
      overlay.classList.remove('open');
      setTimeout(function () { overlay.remove(); }, 200);
    }
    overlay.querySelector('#zpayCancelBtn').addEventListener('click', function () {
      close();
      if (opts.onCancel) opts.onCancel();
    });
    overlay.querySelector('#zpayRechargeBtn').addEventListener('click', function () {
      close();
      if (opts.onRecharge) { opts.onRecharge(); return; }
      if (win.ZitlasWallet && typeof win.ZitlasWallet.openAddFunds === 'function') {
        win.ZitlasWallet.openAddFunds();
      } else if (win.ZitlasWallet && typeof win.ZitlasWallet.openPanel === 'function') {
        win.ZitlasWallet.openPanel();
      }
    });
    overlay.addEventListener('click', function (e) { if (e.target === overlay) { close(); if (opts.onCancel) opts.onCancel(); } });
  }

  win.ZitlasPayment = {
    PLATFORM_FEE_PERCENT: PLATFORM_FEE_PERCENT,
    attemptCharge: attemptCharge,
    creditWallet: creditWallet,
    showLowBalancePopup: showLowBalancePopup,
    /* true while the client trial is on (backend/trial_config.py) —
       coach services are free; Premium + wallet recharge unaffected. */
    isTrialMode: isTrialMode,
    /* true when THIS device's user is a Premium member — UI display only;
       the charge itself re-verifies from the athlete's users/{uid} doc. */
    isPremiumMember: isPremiumMember,
  };
})(window);
