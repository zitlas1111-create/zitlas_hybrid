/*!
 * ZITLAS — Cross-Device Cloud Sync (assets/js/cloud-sync.js)
 *
 * ROOT CAUSE THIS FIXES: goal, assessment/SWOT/calculations, diet plan,
 * workout plan, personal info (name/photo/age/height/weight/etc.), and
 * wallet balance were 100% localStorage — a second device logged into the
 * SAME Firebase account had none of it. Personal Coaching, chat, reviews,
 * notifications, meal check-ins, and certificates were ALREADY correctly
 * Firestore-backed before this file existed and are untouched.
 *
 * STRATEGY: a cache-through mirror, not a rewrite of every read/write call
 * site. Firestore users/{uid} becomes the source of truth for the fields
 * below; localStorage keeps the exact same keys every existing page
 * already reads, so diet.js/weekly-plan.js/dashboard.js/etc. work
 * unmodified once their init is gated behind hydrateOnLoad() and they
 * re-render on the 'zitlas:cloud-sync' event. New/changed data always
 * goes through save() below, which writes localStorage AND Firestore
 * together — so the writing tab updates instantly and every other device
 * gets it the moment its onSnapshot fires.
 *
 * Deliberately NOT synced (matches the spec's own carve-out): theme,
 * tutorial-completion flags, last-opened-tab, and raw device step-counter
 * data (activity-service.js) — a phone's pedometer reading is legitimately
 * device-specific, unlike a user-entered goal or an AI-generated plan.
 *
 * Fields already owned by login.js/streak-service.js/activity-service.js
 * (name, photo, role, roles, expert_status, createdAt, last_login,
 * currentStreak, longestStreak, dailyStepGoal, lastSyncDate) are never
 * touched here — everything below lives under distinct top-level field
 * names on the same users/{uid} doc to avoid any collision.
 */
(function (win) {
  'use strict';

  var FIELD_MAP = {
    goal:         'zitlas_goal',
    assessment:   'zitlas_assessment',
    survey:       'zitlas_survey',
    calculations: 'zitlas_calculations',
    swot:         'zitlas_swot',
    dietPlan:     'zitlas_diet_plan',
    workoutPlan:  'zitlas_workout_plan',
    roadmap:      'zitlas_roadmap',
    precautions:  'zitlas_precautions',
    personalInfo: 'zitlas_personal_info',
    wallet:       'zitlas_wallet',
    location:     'zitlas_location', /* Geo-Aware Food Intelligence — optional */
    membership:   'zitlas_membership', /* Premium plan — read AUTHORITATIVELY from
                                          users/{uid}.membership by payment flows
                                          (platform charges are ₹0 for premium) and
                                          the backend coaching request (priority
                                          queue flag). Identity-scoped: NOT in
                                          GOAL_SCOPED_FIELDS, survives Goal Reset. */
    planMeta:     null, /* virtual — see planGeneratedAt/planId below */
  };
  /* Small standalone string/number fields that don't warrant a whole
     localStorage JSON blob of their own. */
  var SCALAR_FIELD_MAP = {
    planGeneratedAt: 'zitlas_plan_generated_at',
    planId:          'zitlas_plan_id',
    /* Zino product-tour completion — PER-USER, cross-device. Lives on
       users/{uid} so the tour shows exactly once per ACCOUNT lifetime:
       logout/login, device changes, and cache clears can't resurrect it
       (the localStorage copy alone is wiped by the Account Guard on
       every logout/switch, which is precisely why a local-only flag
       made the tour reappear for every returning user). Deliberately
       NOT goal-scoped — a Goal Reset must not replay the tour. */
    zinoTourCompleted: 'zitlas_zino_tutorial_completed',
  };

  function db() { return (typeof ZitlasDB !== 'undefined') ? ZitlasDB : null; }
  function myUid() {
    if (typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) return ZitlasAuth.currentUser.uid;
    try {
      var fb = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      if (fb && fb.uid) return fb.uid;
    } catch (_) {}
    return null;
  }

  /* personalInfo carries the base64 profile photo. Historically the photo
     was device-local (an uncompressed camera photo as base64 can exceed
     Firestore's 1 MiB document cap), which meant two devices on the same
     account showed different avatars. Now the photo is canvas-compressed
     to a small thumbnail (compressImage below, ~20-60 KB) and synced like
     every other personalInfo field, with PHOTO_SYNC_MAX_CHARS as the
     safety valve: anything larger stays local-only exactly as before.
     Applying a cloud copy still MERGES on top of the existing local
     object — so a device holding a legacy oversized local photo keeps it
     until the migration below replaces it with the compressed copy. */
  var MERGE_ON_APPLY = { personalInfo: true };
  var PHOTO_SYNC_MAX_CHARS = 180000; /* ~135 KB binary — well under 1 MiB
                                        even alongside diet/workout plans
                                        on the same users/{uid} doc */

  /* ── Shared avatar compressor ──
     dataUrl -> downscaled JPEG data URL (max maxPx on the longest side).
     White background flatten so transparent PNGs don't turn black. */
  function compressImage(dataUrl, maxPx, quality) {
    maxPx = maxPx || 512;
    quality = quality || 0.8;
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () {
        try {
          var scale = Math.min(1, maxPx / Math.max(img.width, img.height));
          var w = Math.max(1, Math.round(img.width * scale));
          var h = Math.max(1, Math.round(img.height * scale));
          var canvas = document.createElement('canvas');
          canvas.width = w; canvas.height = h;
          var ctx = canvas.getContext('2d');
          ctx.fillStyle = '#fff';
          ctx.fillRect(0, 0, w, h);
          ctx.drawImage(img, 0, 0, w, h);
          resolve(canvas.toDataURL('image/jpeg', quality));
        } catch (e) { reject(e); }
      };
      img.onerror = function () { reject(new Error('image decode failed')); };
      img.src = dataUrl;
    });
  }

  /* ── One-time migration: push this device's existing local photo up ──
     Runs after every hydrate. If this device has a photo the cloud doesn't,
     compress it (legacy full-size uploads) and sync it, so a photo uploaded
     BEFORE this feature existed reaches the user's other devices without
     them having to re-upload. Deep-merge patch touches ONLY the photo key
     (Firestore set+merge merges nested maps), never other personalInfo. */
  function _maybePushLocalPhoto(cloudData) {
    try {
      var local = JSON.parse(localStorage.getItem('zitlas_personal_info') || '{}') || {};
      var localPhoto = local.photo;
      if (!localPhoto || typeof localPhoto !== 'string' || localPhoto.indexOf('data:') !== 0) return;
      var cloudPhoto = cloudData && cloudData.personalInfo && cloudData.personalInfo.photo;
      if (cloudPhoto) return; /* cloud already has one — nothing to migrate */

      var push = function (photo) {
        var d = db(); var uid = myUid();
        if (!d || !uid) return;
        d.collection('users').doc(uid)
          .set({ personalInfo: { photo: photo } }, { merge: true })
          .then(function () { console.log('[CLOUD SYNC] local profile photo migrated to cloud (' + photo.length + ' chars)'); })
          .catch(function (e) { console.warn('[CLOUD SYNC] photo migration failed', e); });
      };

      if (localPhoto.length <= PHOTO_SYNC_MAX_CHARS) {
        push(localPhoto);
      } else {
        compressImage(localPhoto, 512, 0.8).then(function (small) {
          if (small.length > PHOTO_SYNC_MAX_CHARS) return; /* pathological — keep local-only */
          /* Replace the oversized local copy too, so localStorage stops
             carrying a multi-MB string this device re-parses on every read */
          local.photo = small;
          try { localStorage.setItem('zitlas_personal_info', JSON.stringify(local)); } catch (_) {}
          push(small);
        }).catch(function (e) { console.warn('[CLOUD SYNC] photo compression failed — staying local-only', e); });
      }
    } catch (_) {}
  }

  function _applyField(cloudKey, lsKey, cloudValue) {
    /* Cloud null = the field was cleared (Goal Reset). REMOVE the local
       key rather than mirroring the null, so a reset performed on any
       device (or a hydrate racing a reset) actually deletes stale state
       here instead of restoring it — the exact resurrection bug where
       hydrateOnLoad() used to undo clearAllGoalData() on the next page
       load. */
    if (cloudValue === null) {
      var had = localStorage.getItem(lsKey) !== null;
      if (had) localStorage.removeItem(lsKey);
      return had;
    }
    if (MERGE_ON_APPLY[cloudKey]) {
      var existing = {};
      try { existing = JSON.parse(localStorage.getItem(lsKey) || '{}') || {}; } catch (_) {}
      var merged = Object.assign({}, existing, cloudValue);
      var mergedStr = JSON.stringify(merged);
      var changed = JSON.stringify(existing) !== mergedStr;
      if (changed) localStorage.setItem(lsKey, mergedStr);
      return changed;
    }
    var newStr = JSON.stringify(cloudValue);
    var changed = localStorage.getItem(lsKey) !== newStr;
    if (changed) localStorage.setItem(lsKey, newStr);
    return changed;
  }

  var _hydratedFor = null;
  var _realtimeAttachedFor = null;

  /* One-shot fetch, resolved BEFORE a page's own init() reads localStorage,
     so the very first render already has this device's latest cloud data
     instead of flashing stale/empty local state. */
  /* Multiple independent modules on the same page (wallet.js + the page's
     own boot()) each call this — memoize the in-flight/completed promise
     per uid so that only ONE Firestore read happens per page load. */
  var _hydratePromise = null;
  var _hydratePromiseFor = null;
  function hydrateOnLoad(uid) {
    uid = uid || myUid();
    var d = db();
    if (!uid || !d) return Promise.resolve(false);
    if (_hydratePromiseFor === uid && _hydratePromise) return _hydratePromise;
    _hydratePromiseFor = uid;
    _hydratePromise = d.collection('users').doc(uid).get().then(function (snap) {
      var data = snap.exists ? snap.data() : null;
      if (data) {
        _applySnapshot(data);
        _hydratedFor = uid;
      }
      /* Photo migration runs even when the doc doesn't exist yet — a photo
         uploaded on this device before first cloud write still syncs up. */
      _maybePushLocalPhoto(data || {});
      return !!data;
    }).catch(function (e) {
      console.warn('[CLOUD SYNC] hydrate failed — continuing with local cache', e);
      return false;
    });
    return _hydratePromise;
  }

  function _applySnapshot(data) {
    Object.keys(FIELD_MAP).forEach(function (cloudKey) {
      var lsKey = FIELD_MAP[cloudKey];
      if (!lsKey || data[cloudKey] === undefined) return;
      try { _applyField(cloudKey, lsKey, data[cloudKey]); } catch (_) {}
    });
    Object.keys(SCALAR_FIELD_MAP).forEach(function (cloudKey) {
      var lsKey = SCALAR_FIELD_MAP[cloudKey];
      if (data[cloudKey] === undefined) return;
      try {
        if (data[cloudKey] === null) localStorage.removeItem(lsKey);
        else localStorage.setItem(lsKey, String(data[cloudKey]));
      } catch (_) {}
    });
  }

  /* Realtime — call once per page. Fires `cb()` (with no args) whenever
     THIS device's local cache actually changed, so the page can re-run
     its own render function. Deliberately skips re-render on the very
     first snapshot when it matches what hydrateOnLoad() already applied,
     to avoid a redundant double-render on page open. */
  /* Independent modules on the SAME page (wallet.js, dashboard.js,
     notification-center.js, etc.) each call attachRealtime() with their
     own callback — only ONE underlying Firestore listener is ever opened
     per uid per page; every registered callback fires off that single
     snapshot. */
  var _subscribers = [];
  function attachRealtime(uid, cb) {
    uid = uid || myUid();
    var d = db();
    if (!uid || !d) return function () {};
    if (typeof cb === 'function') _subscribers.push(cb);
    if (_realtimeAttachedFor === uid) return function () {};
    _realtimeAttachedFor = uid;

    return d.collection('users').doc(uid).onSnapshot(function (snap) {
      if (!snap.exists) return;
      var data = snap.data();
      var changed = false;
      Object.keys(FIELD_MAP).forEach(function (cloudKey) {
        var lsKey = FIELD_MAP[cloudKey];
        if (!lsKey || data[cloudKey] === undefined) return;
        if (_applyField(cloudKey, lsKey, data[cloudKey])) changed = true;
      });
      Object.keys(SCALAR_FIELD_MAP).forEach(function (cloudKey) {
        var lsKey = SCALAR_FIELD_MAP[cloudKey];
        if (data[cloudKey] === undefined) return;
        try {
          if (data[cloudKey] === null) {
            if (localStorage.getItem(lsKey) !== null) { localStorage.removeItem(lsKey); changed = true; }
          } else if (localStorage.getItem(lsKey) !== String(data[cloudKey])) {
            localStorage.setItem(lsKey, String(data[cloudKey])); changed = true;
          }
        } catch (_) {}
      });
      if (changed) {
        console.log('[CLOUD SYNC] remote change applied —', _subscribers.length, 'subscriber(s) re-rendering');
        try { win.dispatchEvent(new CustomEvent('zitlas:cloud-sync')); } catch (_) {}
        _subscribers.forEach(function (fn) {
          try { fn(); } catch (e) { console.error('[CLOUD SYNC] subscriber threw', e); }
        });
      }
    }, function (e) { console.warn('[CLOUD SYNC] realtime listener error', e); });
  }

  /* Fields on users/{uid} that the CLIENT may READ (hydrate) but must NEVER
     WRITE — production Security Rules make them backend-authoritative
     (FIRESTORE_SECURITY_AUDIT.md V2): wallet balance is credited/debited only
     by routes/payment.py, and premium membership is activated only by
     /api/payment/membership/verify. A client cloud write here would be denied
     by rules AND is a self-credit / self-upgrade hole, so save*/
  var _BACKEND_ONLY_FIELDS = { wallet: true, membership: true };

  /* The ONE function every feature should call instead of a bare
     localStorage.setItem for anything in FIELD_MAP/SCALAR_FIELD_MAP.
     Writes local first (so the calling tab is instant), then Firestore. */
  function save(cloudKey, value) {
    var lsKey = FIELD_MAP[cloudKey] || SCALAR_FIELD_MAP[cloudKey];
    if (lsKey) {
      try {
        /* null = cleared — remove the local key (matching _applyField's
           treatment of cloud nulls) instead of storing the string "null" */
        if (value === null) localStorage.removeItem(lsKey);
        else localStorage.setItem(lsKey, typeof value === 'string' && SCALAR_FIELD_MAP[cloudKey]
          ? value : JSON.stringify(value));
      } catch (_) {}
    }
    /* Backend-only fields: local cache above is fine (instant UI), but never
       push to the cloud — the backend owns them. Hydrate/realtime still READ
       them into local. */
    if (_BACKEND_ONLY_FIELDS[cloudKey]) return Promise.resolve();
    var d = db();
    var uid = myUid();
    if (!d || !uid) return Promise.resolve();
    var patch = {};
    patch[cloudKey] = value;
    patch[cloudKey + 'UpdatedAt'] = new Date().toISOString();
    return d.collection('users').doc(uid).set(patch, { merge: true })
      .catch(function (e) { console.warn('[CLOUD SYNC] save failed for', cloudKey, e); });
  }

  /* save(), but the returned promise REJECTS when the cloud write fails
     (save() only logs). For the few writes whose success the user is told
     about — accepting an expert's plan — where "saved" must mean the server
     has it, not just this device's cache. */
  function saveStrict(cloudKey, value) {
    var lsKey = FIELD_MAP[cloudKey] || SCALAR_FIELD_MAP[cloudKey];
    if (lsKey) {
      try {
        if (value === null) localStorage.removeItem(lsKey);
        else localStorage.setItem(lsKey, typeof value === 'string' && SCALAR_FIELD_MAP[cloudKey]
          ? value : JSON.stringify(value));
      } catch (_) {}
    }
    if (_BACKEND_ONLY_FIELDS[cloudKey]) return Promise.reject(new Error('backend_only_field'));
    var d = db();
    var uid = myUid();
    if (!d || !uid) return Promise.reject(new Error('not_signed_in'));
    var patch = {};
    patch[cloudKey] = value;
    patch[cloudKey + 'UpdatedAt'] = new Date().toISOString();
    return d.collection('users').doc(uid).set(patch, { merge: true });
  }

  /* Cloud-only write — skips the local mirror entirely. For callers (like
     the personal-info form) that already persist their own localStorage
     copy with fields (e.g. a photo) deliberately excluded from the cloud
     copy; letting save() touch localStorage here would immediately
     overwrite that fuller local object with the stripped-down one. */
  function saveCloudOnly(cloudKey, value) {
    if (_BACKEND_ONLY_FIELDS[cloudKey]) {
      /* No-op: wallet/membership are backend-authoritative (see save()). */
      return Promise.resolve();
    }
    var d = db();
    var uid = myUid();
    if (!d || !uid) return Promise.resolve();
    var patch = {};
    patch[cloudKey] = value;
    patch[cloudKey + 'UpdatedAt'] = new Date().toISOString();
    return d.collection('users').doc(uid).set(patch, { merge: true })
      .catch(function (e) { console.warn('[CLOUD SYNC] saveCloudOnly failed for', cloudKey, e); });
  }

  /* Like save(), but for writing several fields in ONE network round-trip —
     used right after AI plan generation, which touches 5-7 fields at once. */
  function saveBulk(fields) {
    Object.keys(fields).forEach(function (cloudKey) {
      var lsKey = FIELD_MAP[cloudKey] || SCALAR_FIELD_MAP[cloudKey];
      if (!lsKey) return;
      var value = fields[cloudKey];
      try {
        if (value === null) localStorage.removeItem(lsKey);
        else localStorage.setItem(lsKey, typeof value === 'string' && SCALAR_FIELD_MAP[cloudKey]
          ? value : JSON.stringify(value));
      } catch (_) {}
    });
    var d = db();
    var uid = myUid();
    if (!d || !uid) return Promise.resolve();
    var patch = {};
    var now = new Date().toISOString();
    Object.keys(fields).forEach(function (cloudKey) {
      /* Skip backend-only fields in the CLOUD patch (local cache above still
         happened). wallet/membership are never client-written. */
      if (_BACKEND_ONLY_FIELDS[cloudKey]) return;
      patch[cloudKey] = fields[cloudKey];
      patch[cloudKey + 'UpdatedAt'] = now;
    });
    if (!Object.keys(patch).length) return Promise.resolve();
    return d.collection('users').doc(uid).set(patch, { merge: true })
      .catch(function (e) { console.warn('[CLOUD SYNC] saveBulk failed', e); });
  }

  /* ── GOAL RESET (the architectural half) ──
     Every goal-scoped field is nulled on users/{uid} AND removed locally,
     in one atomic write. Cloud null is the canonical "cleared" marker:
     _applyField/_applySnapshot translate it into localStorage.removeItem
     on EVERY device, so a reset done here propagates everywhere and can
     never be resurrected by the next hydrateOnLoad(). Identity and money
     (personalInfo, wallet, location) deliberately survive — resetting a
     goal is not deleting an account. */
  var GOAL_SCOPED_FIELDS = [
    'goal', 'assessment', 'survey', 'calculations', 'swot',
    'dietPlan', 'workoutPlan', 'roadmap', 'precautions',
    'planGeneratedAt', 'planId',
    /* Immutable per-generation master snapshots (ai-coach.js saveBulk) —
       cloud-only recovery copies; goal-scoped, so a reset clears them. */
    'dietPlanMaster', 'workoutPlanMaster',
  ];
  function clearGoalData() {
    /* Local first — the resetting tab is consistent immediately */
    GOAL_SCOPED_FIELDS.forEach(function (cloudKey) {
      var lsKey = FIELD_MAP[cloudKey] || SCALAR_FIELD_MAP[cloudKey];
      if (lsKey) { try { localStorage.removeItem(lsKey); } catch (_) {} }
    });
    var d = db();
    var uid = myUid();
    if (!d || !uid) return Promise.resolve();
    var patch = {};
    var now = new Date().toISOString();
    GOAL_SCOPED_FIELDS.forEach(function (cloudKey) {
      patch[cloudKey] = null;
      patch[cloudKey + 'UpdatedAt'] = now;
    });
    patch.goalResetAt = now;
    return d.collection('users').doc(uid).set(patch, { merge: true })
      .then(function () { console.log('[CLOUD SYNC] goal-scoped cloud data cleared (reset)'); })
      .catch(function (e) { console.warn('[CLOUD SYNC] clearGoalData failed', e); });
  }

  /* Convenience: hydrate then boot the page's normal init, then attach
     realtime pointed at the same init function so it just re-runs on any
     remote change. Falls back to calling initFn immediately (local-only)
     when there's no session yet — never blocks a logged-out/guest page. */
  function bootWithSync(initFn) {
    if (typeof ZitlasAuth === 'undefined') { initFn(); return; }
    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user) { initFn(); return; }
      hydrateOnLoad(user.uid).then(function () {
        initFn();
        attachRealtime(user.uid, initFn);
      });
    });
  }

  win.ZitlasCloudSync = {
    hydrateOnLoad: hydrateOnLoad,
    attachRealtime: attachRealtime,
    save: save,
    saveStrict: saveStrict,
    saveCloudOnly: saveCloudOnly,
    saveBulk: saveBulk,
    clearGoalData: clearGoalData,
    bootWithSync: bootWithSync,
    myUid: myUid,
    compressImage: compressImage,
    PHOTO_SYNC_MAX_CHARS: PHOTO_SYNC_MAX_CHARS,
  };
})(window);
