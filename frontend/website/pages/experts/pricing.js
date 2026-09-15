/*!
 * ZITLAS — Pricing & Services editor (frontend/pages/experts/pricing.js)
 * Reads/writes experts/{uid}.pricing. Editing here NEVER touches prices
 * already snapshotted onto in-flight review_requests / personal_coach_requests
 * — those keep whatever price was live when the athlete sent the request.
 */
(function () {
  'use strict';

  var FIELDS = {
    dietReviewPrice:    { el: 'prDietPrice',    min: 0, max: 100, def: 49 },
    workoutReviewPrice: { el: 'prWorkoutPrice', min: 0, max: 100, def: 59 },
    bothReviewPrice:    { el: 'prBothPrice',    min: 0, max: 100, def: 99 },
    chatPrice:          { el: 'prChatPrice',    min: 0, max: 200, def: 149 },
    coachingDietPrice:      { el: 'prCoachDiet',     min: 0, max: null, def: 499 },
    coachingTrainingPrice:  { el: 'prCoachTraining', min: 0, max: null, def: 699 },
    coachingCompletePrice:  { el: 'prCoachComplete', min: 0, max: null, def: 999 },
  };

  function $(id) { return document.getElementById(id); }

  function showToast(msg) {
    var t = $('prToast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(showToast._t);
    showToast._t = setTimeout(function () { t.classList.remove('show'); }, 2600);
  }

  function myUid() {
    try {
      if (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) return ZitlasAuth.currentUser.uid;
      var fb = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      return fb && fb.uid;
    } catch (_) { return null; }
  }

  function loadPricing(uid) {
    if (typeof ZitlasDB === 'undefined') return;
    ZitlasDB.collection('experts').doc(uid).get().then(function (snap) {
      var pricing = (snap.exists && snap.data().pricing) || {};
      Object.keys(FIELDS).forEach(function (key) {
        var f = FIELDS[key];
        var input = $(f.el);
        if (!input) return;
        var val = pricing[key];
        input.value = (val !== undefined && val !== null) ? val : f.def;
      });
    }).catch(function (e) { console.warn('[PRICING] load failed', e); });
  }

  function clamp(val, min, max) {
    var n = Math.round(Number(val));
    if (isNaN(n) || n < 0) n = 0;
    if (min !== null && n < min) n = min;
    if (max !== null && n > max) n = max;
    return n;
  }

  function validateAndCollect() {
    var out = {};
    var reviewOk = true;
    var chatOk = true;

    ['dietReviewPrice', 'workoutReviewPrice', 'bothReviewPrice'].forEach(function (key) {
      var f = FIELDS[key];
      var input = $(f.el);
      var raw = input ? Number(input.value) : f.def;
      if (isNaN(raw) || raw < f.min || raw > f.max) reviewOk = false;
      var clamped = clamp(raw, f.min, f.max);
      out[key] = clamped;
      if (input) input.value = clamped;
    });

    var chatField = FIELDS.chatPrice;
    var chatInput = $(chatField.el);
    var chatRaw = chatInput ? Number(chatInput.value) : chatField.def;
    if (isNaN(chatRaw) || chatRaw < chatField.min || chatRaw > chatField.max) chatOk = false;
    out.chatPrice = clamp(chatRaw, chatField.min, chatField.max);
    if (chatInput) chatInput.value = out.chatPrice;

    ['coachingDietPrice', 'coachingTrainingPrice', 'coachingCompletePrice'].forEach(function (key) {
      var f = FIELDS[key];
      var input = $(f.el);
      var raw = input ? Number(input.value) : f.def;
      out[key] = clamp(raw, f.min, f.max); // unlimited upper bound — only floors at 0
      if (input) input.value = out[key];
    });

    var reviewErr = $('prReviewError');
    var chatErr   = $('prChatError');
    if (reviewErr) reviewErr.style.display = reviewOk ? 'none' : '';
    if (chatErr)   chatErr.style.display   = chatOk ? 'none' : '';

    return { ok: reviewOk && chatOk, values: out };
  }

  function savePricing() {
    var uid = myUid();
    if (!uid || typeof ZitlasDB === 'undefined') {
      showToast('Not signed in — could not save.');
      return;
    }
    var result = validateAndCollect();
    if (!result.ok) {
      showToast('Please fix the highlighted prices.');
      return;
    }
    var saveBtn = $('prSaveBtn');
    if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Saving…'; }

    var pricing = Object.assign({}, result.values, { updatedAt: new Date().toISOString() });
    ZitlasDB.collection('experts').doc(uid).set({ pricing: pricing }, { merge: true })
      .then(function () {
        showToast('✅ Pricing saved — new requests will use these prices.');
      })
      .catch(function (e) {
        console.error('[PRICING] save failed', e);
        showToast('Could not save pricing — please try again.');
      })
      .then(function () {
        if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save Pricing'; }
        // This button used to save only the prices below it: program prices
        // typed into the Personal Coaching Program card above were dropped,
        // the expert saw "Pricing saved", and athletes found every program
        // unpriced. Unsaved program prices are now saved too — through their
        // own backend endpoint (program-pricing.js), never a Firestore write.
        var programs = window.ZitlasProgramPricing;
        if (programs && typeof programs.isDirty === 'function' && programs.isDirty()) {
          return programs.save();
        }
      });
  }

  function init() {
    var backBtn = $('prBackBtn');
    if (backBtn) backBtn.addEventListener('click', function () { window.history.back(); });

    var saveBtn = $('prSaveBtn');
    if (saveBtn) saveBtn.addEventListener('click', savePricing);

    // Clamp on blur so the field never visibly holds an out-of-range value.
    Object.keys(FIELDS).forEach(function (key) {
      var f = FIELDS[key];
      var input = $(f.el);
      if (!input) return;
      input.addEventListener('blur', function () {
        if (input.value === '') return;
        input.value = clamp(input.value, f.min, f.max);
      });
    });

    if (typeof ZitlasAuth !== 'undefined') {
      ZitlasAuth.onAuthStateChanged(function (user) {
        if (!user) { window.location.href = '../login/login.html'; return; }
        loadPricing(user.uid);
      });
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
