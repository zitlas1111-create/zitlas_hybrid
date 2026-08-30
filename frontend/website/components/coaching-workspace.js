/*!
 * ZITLAS — Personal Coaching Workspace (components/coaching-workspace.js)
 *
 * One full-screen workspace shared by BOTH sides of an active coaching
 * relationship. Opened via:
 *   ZitlasCoachingWorkspace.open({
 *     role: 'athlete' | 'coach',
 *     athleteId, athleteName, coachId, coachName,
 *     planType ('diet'|'training'|'complete'), planLabel,
 *     startDate, endDate, status, initialTab
 *   })
 *
 * Firestore:
 *   users/{athleteUid} — SINGLE SOURCE OF TRUTH for athlete data
 *     (assessment, survey, goal, calculations, swot, dietPlan,
 *     workoutPlan, precautions, planId — live-mirrored from the athlete's
 *     device by assets/js/cloud-sync.js). The workspace subscribes to it
 *     directly; it never keeps its own copy.
 *   coaching_plans/{athleteUid} — COACH-AUTHORED plans only
 *     { athleteId, athleteName, coachId, coachName, planType,
 *       diet:     { planId, days: [ {day, meals:[{id, name, time, options:[{name, calories, protein, notes}]}]} ] },
 *       dietSelections: { '<day>:<mealId>': optionIndex },
 *       dietUpdatedAt, dietVersion,
 *       training: { planId, days: [ {day, rest, focus, duration, exercises:[{name, sets, reps, duration, rest, notes}]} ] },
 *       trainingUpdatedAt, trainingVersion }
 *     diet.planId / training.planId = the athlete plan generation the
 *     coach authored against; consumers fail-closed on mismatch so a
 *     previous goal's coach plan can never render after a reset.
 *   coaching_plans/{athleteUid}/versions/{id}   — snapshot per save (restore)
 *   coaching_meal_requests/{id}                 — athlete "Ask Expert" per meal
 *   coaching_notifications/{id}                 — cross-side toasts
 *   chat_rooms/{chat_<athleteId>_<coachId>}/messages — SAME collection the
 *     normal chat uses, so history is shared and nothing breaks.
 *
 * Permissions (coach side): planType 'diet' → Diet editable, Training
 * read-only; 'training' → reverse; 'complete' → both. Athlete never edits —
 * they pick among the coach's options and can Ask Expert.
 */
(function (win) {
  'use strict';

  var DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  var DEFAULT_MEALS = ['Breakfast', 'Lunch', 'Snacks', 'Dinner'];
  var MEAL_EMOJI = { breakfast: '🍳', lunch: '🍛', snacks: '🍎', snack: '🍎', dinner: '🥗' };

  var S = {
    open: false,
    opts: null,
    plan: null,            /* coaching_plans doc data (coach-authored plans) */
    planLoaded: false,     /* first coaching_plans snapshot has arrived */
    athlete: null,         /* normalized users/{athleteId} doc — the SINGLE
                              source of truth for assessment, goal, AI plans,
                              calculations, medical data. Live-mirrored from
                              the athlete's device by cloud-sync.js. */
    athleteLoaded: false,  /* first users/{athleteId} snapshot has arrived */
    loadError: null,       /* set the moment ANY subscribeAll() listener denies/
                              errors, or the initial load never resolves within
                              LOAD_TIMEOUT_MS — renderTab() shows this instead of
                              dispatching to a tab, so the workspace can never be
                              stuck on "Loading…" forever (see subscribeAll,
                              _reportLoadError, retryLoad). */
    loadTimeoutId: null,
    tab: 'overview',
    dayIdx: 0,             /* viewer/editor selected day */
    unsubs: [],
    dietDraft: null, dietDirty: false, dietDraftSeeded: false, dietEditGen: 0,
    trainDraft: null, trainDirty: false, trainDraftSeeded: false, trainEditGen: 0,
    mealReqs: [],
    checkins: [],
    reviewDraft: null,   /* { reaction, score, comment } while the review sheet is open */
    workoutCheckins: [],
    workoutReviewDraft: null,   /* { score, comment } while the workout review sheet is open */
    chatMsgs: [],
    saving: false,
  };

  /* Debounced auto-save timers, keyed by 'diet'/'training' — separate from
     S so a retryLoad()/open() reset never leaves a stale timer pointing at
     a torn-down workspace. See scheduleAutoSave/_flushPendingSave below. */
  var AUTO_SAVE_DEBOUNCE_MS = 800;
  var _autoSaveTimers = { diet: null, training: null };

  var REACTION_LABEL = {
    perfect: '🟢 Perfect', great: '🟢 Great', good: '🟡 Good',
    needs_improvement: '🟠 Needs Improvement', not_recommended: '🔴 Not Recommended',
  };
  var DEFAULT_MEAL_TYPES = ['breakfast', 'lunch', 'dinner', 'snacks'];

  /* ── tiny helpers ── */
  function db()  { return (typeof ZitlasDB !== 'undefined') ? ZitlasDB : null; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function $(id) { return document.getElementById(id); }
  function myUid() {
    var o = S.opts;
    return o ? (o.role === 'coach' ? o.coachId : o.athleteId) : null;
  }
  function otherUid() {
    var o = S.opts;
    return o ? (o.role === 'coach' ? o.athleteId : o.coachId) : null;
  }
  function myName() {
    var o = S.opts;
    return o ? (o.role === 'coach' ? o.coachName : o.athleteName) : '';
  }
  function chatId() {
    return 'chat_' + S.opts.athleteId + '_' + S.opts.coachId;
  }
  function canEditDiet() {
    return S.opts && S.opts.role === 'coach' && S.opts.status === 'active' &&
      (S.opts.planType === 'diet' || S.opts.planType === 'complete');
  }
  function canEditTraining() {
    return S.opts && S.opts.role === 'coach' && S.opts.status === 'active' &&
      (S.opts.planType === 'training' || S.opts.planType === 'complete');
  }

  /* ── auto-save (debounced) ──
     markDirty() calls scheduleAutoSave(type) on every keystroke; the timer
     is reset each time so a save only actually fires ~800ms after the coach
     stops typing. _flushPendingSave() is used by navigation (switchTab,
     close) to save immediately instead of waiting out the debounce — it
     never blocks the caller, the write just continues in the background. */
  function scheduleAutoSave(type) {
    clearTimeout(_autoSaveTimers[type]);
    _autoSaveTimers[type] = setTimeout(function () {
      _autoSaveTimers[type] = null;
      if (type === 'diet') saveDiet(true); else saveTraining(true);
    }, AUTO_SAVE_DEBOUNCE_MS);
  }
  function _cancelAutoSave(type) {
    clearTimeout(_autoSaveTimers[type]);
    _autoSaveTimers[type] = null;
  }
  function _flushPendingSave(type) {
    _cancelAutoSave(type);
    var dirty = type === 'diet' ? S.dietDirty : S.trainDirty;
    if (!dirty) return;
    if (type === 'diet') saveDiet(true); else saveTraining(true);
  }
  /* States: saving | saved | error | locked. The span sits in the save-bar
     next to the Save button (see renderDietEditor/renderTrainingEditor); a
     manual save leaves it blank since the button text itself already says
     "Saving…"/"Saved ✓" in that path. */
  function _setSaveStatus(type, state) {
    var el = $(type === 'diet' ? 'cwDietSaveStatus' : 'cwTrainSaveStatus');
    if (!el) return;
    var label = {
      saving: 'Saving…', saved: '✓ Saved',
      error: '⚠ Save failed — retrying…', locked: '🔒 Coaching ended',
    }[state] || '';
    el.textContent = label;
    el.className = 'cw-save-status cw-save-status--' + state;
  }
  function fmtDate(iso) {
    try { return new Date(iso).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }); }
    catch (_) { return ''; }
  }
  function fmtTime(iso) {
    try { return new Date(iso).toLocaleTimeString('en-IN', { hour: 'numeric', minute: '2-digit' }); }
    catch (_) { return ''; }
  }
  function daysLeft() {
    if (!S.opts || !S.opts.endDate) return null;
    return Math.max(0, Math.ceil((new Date(S.opts.endDate) - new Date()) / 86400000));
  }
  function newId(prefix) {
    return prefix + '_' + Date.now() + '_' + Math.random().toString(36).slice(2, 6);
  }
  function todayIdx() {
    var n = new Date().getDay(); /* 0=Sun */
    return n === 0 ? 6 : n - 1;
  }

  var _toastEl = null, _toastTimer = null;
  function toast(msg, ms) {
    if (!_toastEl) {
      _toastEl = document.createElement('div');
      _toastEl.className = 'cw-toast';
      document.body.appendChild(_toastEl);
    }
    _toastEl.textContent = msg;
    _toastEl.classList.add('show');
    clearTimeout(_toastTimer);
    _toastTimer = setTimeout(function () { _toastEl.classList.remove('show'); }, ms || 3000);
  }

  /* ══════════════════════════════════════════════
     NOTIFICATIONS — coaching_notifications
     Written by either side; the recipient's device toasts unread ones
     and marks them read. attachNotifications() can also be called by a
     host page so toasts arrive without the workspace being open.
  ══════════════════════════════════════════════ */
  function notify(toId, text, type) {
    var d = db();
    if (!d || !toId) return;
    var id = newId('CN');
    d.collection('coaching_notifications').doc(id).set({
      id: id, toId: toId,
      fromId: myUid() || '', fromName: myName() || '',
      text: text, type: type || 'info',
      createdAt: new Date().toISOString(), read: false,
    }).catch(function (e) { console.warn('[CW] notify failed', e); });

    /* Mirror into the unified Notification Center — additive, the toast
       above is untouched. Category/navigation are derived from the
       coaching-specific `type`; for 'chat' the recipient's role decides
       whether tapping opens the athlete's coach profile or the expert
       dashboard, since the same event fires in both directions. */
    if (typeof ZitlasNotify !== 'undefined' && S.opts) {
      var toIsAthlete = toId === S.opts.athleteId;
      var category =
        type === 'diet_update'     ? 'diet' :
        type === 'training_update' ? 'training' :
        type === 'meal_reviewed'   ? 'meal_snap' :
        type === 'meal_request'    ? 'expert' :
        type === 'chat'            ? 'chat' : 'expert';
      var action =
        type === 'diet_update'     ? 'diet' :
        type === 'training_update' ? 'training' :
        type === 'meal_reviewed'   ? 'diet' :
        (toIsAthlete ? 'chat' : 'expert_dashboard');
      var actionId = toIsAthlete ? S.opts.coachId : null;
      ZitlasNotify.send(toId, { title: text, category: category, type: type, action: action, actionId: actionId });
    }
  }

  var _notifAttachedFor = null;
  function attachNotifications(uid, toastFn) {
    var d = db();
    if (!d || !uid || _notifAttachedFor === uid) return;
    _notifAttachedFor = uid;
    var show = toastFn || toast;
    d.collection('coaching_notifications')
      .where('toId', '==', uid)
      .onSnapshot(function (snap) {
        var unread = snap.docs
          .map(function (x) { return x.data(); })
          .filter(function (n) { return n && n.read === false; })
          .sort(function (a, b) { return (a.createdAt || '') < (b.createdAt || '') ? -1 : 1; });
        unread.slice(-3).forEach(function (n, i) {
          setTimeout(function () { show(n.text); }, i * 1200);
        });
        unread.forEach(function (n) {
          d.collection('coaching_notifications').doc(n.id)
            .update({ read: true }).catch(function () {});
        });
      }, function (e) { console.warn('[CW] notifications listener error', e); });
  }

  /* ══════════════════════════════════════════════
     DOM SHELL (injected once)
  ══════════════════════════════════════════════ */
  var _domReady = false;
  function ensureDom() {
    if (_domReady) return;
    _domReady = true;
    var el = document.createElement('div');
    el.className = 'cw-overlay';
    el.id = 'cwOverlay';
    el.innerHTML =
      '<header class="cw-header">' +
        '<div class="cw-hdr-row">' +
          '<button class="cw-back" id="cwBack" aria-label="Close">' +
            '<svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/></svg>' +
          '</button>' +
          '<div class="cw-avatar" id="cwAvatar">A</div>' +
          '<div class="cw-hdr-info">' +
            '<div class="cw-hdr-name-row">' +
              '<span class="cw-hdr-name" id="cwName">—</span><span id="cwNameBadge"></span>' +
            '</div>' +
            '<span class="cw-hdr-sub"><span class="cw-live-dot"></span><span id="cwSubline">Active coaching</span></span>' +
          '</div>' +
          '<span class="cw-plan-chip" id="cwPlanChip">—</span>' +
        '</div>' +
        '<div class="cw-summary" id="cwSummary"></div>' +
      '</header>' +
      '<div class="cw-med-banner" id="cwMedBanner" style="display:none"></div>' +
      '<nav class="cw-tabs" id="cwTabs">' +
        '<button class="cw-tab active" data-cw-tab="overview">📋 Overview</button>' +
        '<button class="cw-tab" data-cw-tab="diet">🥗 Diet<span class="cw-tab-badge" id="cwDietBadge" style="display:none">0</span></button>' +
        '<button class="cw-tab" data-cw-tab="training">💪 Training</button>' +
        '<button class="cw-tab" data-cw-tab="checkins">🍽 Meal Reviews<span class="cw-tab-badge" id="cwCheckinBadge" style="display:none">0</span></button>' +
        '<button class="cw-tab" data-cw-tab="weekly">📊 Weekly</button>' +
        '<button class="cw-tab" data-cw-tab="chat">💬 Chat</button>' +
      '</nav>' +
      '<main class="cw-body" id="cwBody"></main>';
    document.body.appendChild(el);

    $('cwBack').addEventListener('click', close);
    el.querySelectorAll('[data-cw-tab]').forEach(function (t) {
      t.addEventListener('click', function () { switchTab(t.dataset.cwTab); });
    });

    /* Bottom sheet host (option picker / ask expert / history) */
    var sheet = document.createElement('div');
    sheet.className = 'cw-sheet-backdrop';
    sheet.id = 'cwSheetBackdrop';
    sheet.innerHTML = '<div class="cw-sheet" id="cwSheet"></div>';
    document.body.appendChild(sheet);
    sheet.addEventListener('click', function (e) { if (e.target === sheet) closeSheet(); });
  }

  function openSheet(html) {
    var bd = $('cwSheetBackdrop');
    $('cwSheet').innerHTML = html;
    /* Centrally, so every sheet that shows a meal photo is covered — the two
       review sheets marked their images data-cw-photo but never wired the
       handler, so an unreachable photo still rendered a broken-image glyph
       once the coach opened it. */
    _cwWireImageFallbacks($('cwSheet'));
    bd.style.display = 'flex';
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { bd.classList.add('open'); });
    });
  }
  function closeSheet() {
    var bd = $('cwSheetBackdrop');
    if (!bd) return;
    bd.classList.remove('open');
    setTimeout(function () { bd.style.display = 'none'; }, 200);
  }

  /* ══════════════════════════════════════════════
     OPEN / CLOSE
  ══════════════════════════════════════════════ */
  function open(opts) {
    if (!opts || !opts.athleteId || !opts.coachId) {
      console.warn('[CW] open() missing athleteId/coachId', opts);
      return;
    }
    /* These two are called from openSheet() and the two check-in sheets,
       which live at module scope. They were once nested inside
       renderCheckins(), which made the meal LIST work while opening any meal
       threw `_cwPhotoMarkup is not defined`. Reported here so a regression is
       visible in the Android WebView log rather than only at the moment a
       coach taps a meal. */
    console.log('[CW PHOTO] _cwPhotoMarkup available=' + typeof _cwPhotoMarkup +
      ' _cwWireImageFallbacks available=' + typeof _cwWireImageFallbacks);
    ensureDom();
    S.opts = opts;
    S.tab = opts.initialTab || 'overview';
    /* A notification tap names ONE meal, not just the tab. Held until the
       meal_checkins snapshot arrives (S.checkins is empty right now — the
       listener below has not fired yet), then consumed exactly once by
       _cwOpenPendingCheckin. One-shot so it cannot re-open the sheet every
       time a later snapshot lands, which would trap the user in it. */
    S.pendingCheckinId = opts.initialCheckinId || null;
    S.dayIdx = todayIdx();
    S.dietDraft = null; S.dietDirty = false; S.dietDraftSeeded = false; S.dietEditGen = 0;
    S.trainDraft = null; S.trainDirty = false; S.trainDraftSeeded = false; S.trainEditGen = 0;
    S.plan = null; S.planLoaded = false; S.mealReqs = []; S.chatMsgs = [];
    S.athlete = null; S.athleteLoaded = false;
    S.loadError = null;
    S.open = true;

    console.log('[CW] open', opts.role, 'athlete:', opts.athleteId, 'coach:', opts.coachId, 'plan:', opts.planType);

    renderHeader();
    var overlay = $('cwOverlay');
    overlay.style.display = 'flex';
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { overlay.classList.add('open'); });
    });
    document.body.style.overflow = 'hidden';
    var navbar = document.getElementById('zitlas-navbar');
    if (navbar) navbar.style.display = 'none';

    switchTab(S.tab, true);
    subscribeAll();
    armLoadTimeout();
    attachNotifications(myUid());
  }

  /* Safety net for the failure mode this workspace used to have no
     recovery from: a Firestore onSnapshot listener that neither succeeds
     NOR calls its error callback within a reasonable window (offline
     persistence queuing a read indefinitely, ZitlasDB not yet defined at
     open() time, etc.). Without this, S.athleteLoaded simply never becomes
     true and the workspace is stuck on "Loading user data…" forever
     with no visible error at all. 12s is generous for a live Firestore
     read; a genuine permission-denied error (the common real-world case)
     fires in well under a second and is handled immediately by
     _reportLoadError below — this timeout only ever fires for the
     "nothing happened at all" case. */
  var LOAD_TIMEOUT_MS = 12000;
  function armLoadTimeout() {
    clearTimeout(S.loadTimeoutId);
    S.loadTimeoutId = setTimeout(function () {
      if (S.open && !S.athleteLoaded) {
        console.warn('[CW] athlete data did not load within', LOAD_TIMEOUT_MS, 'ms — showing error state');
        _reportLoadError('timeout', new Error('load timed out'));
      }
    }, LOAD_TIMEOUT_MS);
  }

  /* The ONE place that turns any subscribeAll() failure into a visible,
     resolvable UI state (renderTab() checks S.loadError first — see
     below) instead of leaving the caller's own "Loading…" branch stuck
     forever. First error wins: once shown, later listener errors are still
     logged (for diagnosis) but don't overwrite the message the user is
     already looking at. */
  function _reportLoadError(context, err) {
    clearTimeout(S.loadTimeoutId);
    if (S.loadError) return;
    S.loadError = 'Unable to load user data. Please try again.';
    console.error('[CW] load error (' + context + '):', err);
    renderTab();
  }

  /* "Retry" button action — clears the error, drops the stale listeners,
     and re-subscribes exactly as open() originally did. */
  function retryLoad() {
    S.unsubs.forEach(function (u) { try { u(); } catch (_) {} });
    S.unsubs = [];
    S.plan = null; S.planLoaded = false;
    S.athlete = null; S.athleteLoaded = false;
    S.loadError = null;
    renderTab();
    subscribeAll();
    armLoadTimeout();
  }

  function close() {
    /* Flush rather than ask — an edit in flight is saved in the background,
       not discarded behind a confirm() dialog (see plan: "do not ask are
       you sure if data can be auto-saved"). */
    _flushPendingSave('diet');
    _flushPendingSave('training');
    var onClose = S.opts && S.opts.onClose;
    S.open = false;
    clearTimeout(S.loadTimeoutId);
    S.unsubs.forEach(function (u) { try { u(); } catch (_) {} });
    S.unsubs = [];
    var overlay = $('cwOverlay');
    if (overlay) {
      overlay.classList.remove('open');
      setTimeout(function () { overlay.style.display = 'none'; }, 220);
    }
    closeSheet();
    document.body.style.overflow = '';
    var navbar = document.getElementById('zitlas-navbar');
    if (navbar) navbar.style.display = '';
    if (typeof onClose === 'function') onClose();
  }

  function switchTab(tab, force) {
    if (S.tab === tab && !force) return;
    if (S.tab === 'diet' && tab !== 'diet') _flushPendingSave('diet');
    if (S.tab === 'training' && tab !== 'training') _flushPendingSave('training');
    S.tab = tab;
    var tabsEl = $('cwTabs');
    if (tabsEl) tabsEl.querySelectorAll('[data-cw-tab]').forEach(function (t) {
      t.classList.toggle('active', t.dataset.cwTab === tab);
    });
    var body = $('cwBody');
    body.classList.toggle('cw-body--chat', tab === 'chat');
    renderTab();
    if (S.opts && typeof S.opts.onTabChange === 'function') S.opts.onTabChange(tab);
  }

  /* ══════════════════════════════════════════════
     FIRESTORE SUBSCRIPTIONS
  ══════════════════════════════════════════════ */
  function subscribeAll() {
    var d = db();
    if (!d) {
      toast('Connection unavailable');
      _reportLoadError('firestore-unavailable', new Error('ZitlasDB is undefined'));
      return;
    }

    /* SINGLE SOURCE OF TRUTH — the athlete's users/{uid} doc, which
       cloud-sync.js live-mirrors from the athlete's device on every plan
       generation, assessment, and Goal Reset. The workspace used to read
       a one-shot "athleteContext" COPY published into coaching_plans,
       which went stale the moment the athlete changed anything (the
       phantom-diabetes / stale-plan bug class). Now assessment, goal,
       AI plans, calculations and medical data are always live. */
    S.unsubs.push(d.collection('users').doc(S.opts.athleteId)
      .onSnapshot(function (snap) {
        S.athlete = _normalizeAthleteDoc(snap.exists ? snap.data() : null);
        S.athleteLoaded = true;
        console.log('[CW] athlete snapshot — planId:', S.athlete && S.athlete.planId,
          '| goal:', S.athlete && S.athlete.goal && S.athlete.goal.type);
        renderHeader();
        if (S.tab === 'diet' && !S.dietDirty) renderTab();
        else if (S.tab === 'training' && !S.trainDirty) renderTab();
        else if (S.tab === 'overview' || S.tab === 'chat') renderTab();
      }, function (e) {
        console.warn('[CW] athlete listener error', e);
        _reportLoadError('users/' + S.opts.athleteId, e);
      }));

    S.unsubs.push(d.collection('coaching_plans').doc(S.opts.athleteId)
      .onSnapshot(function (snap) {
        S.plan = snap.exists ? snap.data() : null;
        S.planLoaded = true;
        var _sd = S.plan && S.plan.diet, _st = S.plan && S.plan.training;
        console.log('[CW] plan snapshot — diet days:',
          _sd && _sd.days ? _sd.days.length : 0,
          '| training days:',
          _st && _st.days ? _st.days.length : 0);
        /* RELOAD RESULT. A coach plan is only shown when it carries the
           athlete's CURRENT planId (coachPlanIsCurrent), so "saved but not
           showing" and "never saved" look identical without this. */
        console.log('[CW TRAINING RELOAD] athleteId=' + S.opts.athleteId +
          ' savedPlanId=' + (_st && _st.planId) +
          ' athletePlanId=' + (athleteCtx().planId) +
          ' current=' + (_st ? coachPlanIsCurrent(_st) : false) +
          ' trainingUpdatedAt=' + (S.plan && S.plan.trainingUpdatedAt) +
          ' trainingVersion=' + (S.plan && S.plan.trainingVersion));
        renderHeader();
        /* Never clobber an editor mid-edit; viewers always refresh */
        if (S.tab === 'diet' && !S.dietDirty) renderTab();
        else if (S.tab === 'training' && !S.trainDirty) renderTab();
        else if (S.tab === 'overview') renderTab();
      }, function (e) {
        console.warn('[CW] plan listener error', e);
        _reportLoadError('coaching_plans/' + S.opts.athleteId, e);
      }));

    /* coachId pinned as a query filter — coaching_meal_requests' read rule is
       also (athleteId == uid || coachId == uid), so the coach's athleteId-only
       query was denied wholesale. See the meal_checkins note below. */
    S.unsubs.push(d.collection('coaching_meal_requests')
      .where('athleteId', '==', S.opts.athleteId)
      .where('coachId', '==', S.opts.coachId)
      .onSnapshot(function (snap) {
        S.mealReqs = snap.docs.map(function (x) { return x.data(); })
          .filter(function (r) { return r.coachId === S.opts.coachId; });
        var pending = S.mealReqs.filter(function (r) { return r.status === 'pending'; }).length;
        var badge = $('cwDietBadge');
        if (badge && S.opts.role === 'coach') {
          badge.textContent = pending;
          badge.style.display = pending > 0 ? 'flex' : 'none';
        }
        if (S.tab === 'diet' && !S.dietDirty) renderTab();
      }, function (e) { console.warn('[CW] meal requests listener error', e); }));

    if (S.opts.role === 'coach') {
      console.log('[COACH AUTH] firebaseUid=' + ((typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) ? ZitlasAuth.currentUser.uid : null) +
        ' expertId=' + S.opts.coachId + ' role=coach' +
        ' | opening workspace for athleteId=' + S.opts.athleteId);
    }
    /* BOTH athleteId AND coachId are QUERY filters, not client-side filters.
       Security Rules are not filters: firestore.rules grants a non-athlete
       reader `resource.data.coachId == request.auth.uid && isActiveCoachOf(
       resource.data.athleteId)`, and Firestore validates a query against its
       POTENTIAL result set, statically, from the query's own constraints. A
       query filtered only by athleteId can therefore never be proven safe for
       the coach (their uid != athleteId, and coachId is unconstrained), so the
       WHOLE listener failed with permission-denied and the coach's Meal
       Reviews tab stayed permanently empty even though the athlete's snap was
       written correctly. Pinning coachId satisfies the rule's coach clause;
       pinning athleteId also resolves the isActiveCoachOf() lookup path. The
       athlete role still satisfies the athlete clause via the athleteId
       filter, so one query shape serves both roles.
       Two equality filters need no composite index (zigzag merge join). */
    S.unsubs.push(d.collection('meal_checkins')
      .where('athleteId', '==', S.opts.athleteId)
      .where('coachId', '==', S.opts.coachId)
      .onSnapshot(function (snap) {
        var rawDocs = snap.docs.map(function (x) { return x.data(); });
        S.checkins = rawDocs
          .filter(function (c) { return c.coachId === S.opts.coachId; })
          .sort(function (a, b) { return (b.timestamp || '') < (a.timestamp || '') ? -1 : 1; });
        _cwOpenPendingCheckin();
        var pending = S.checkins.filter(function (c) { return c.status === 'pending'; }).length;
        if (S.opts.role === 'coach') {
          // documentsFound = what the QUERY returned (athleteId match only,
          // before the coachId filter) — reviewsReturned = what's left after
          // filtering to THIS coach. If documentsFound > 0 but reviewsReturned
          // is 0, the meal_checkins doc's OWN coachId does not match this
          // coach's uid (a DATA mismatch, not a permission/rules issue) — the
          // mismatched coachId values are logged below to make that visible
          // without needing direct database access.
          console.log('[COACH MEAL REVIEW LOAD] authenticatedCoachUid=' +
            ((typeof ZitlasAuth !== 'undefined' && ZitlasAuth.currentUser) ? ZitlasAuth.currentUser.uid : null) +
            ' expertId=' + S.opts.coachId + ' coachId=' + S.opts.coachId +
            ' athleteId=' + S.opts.athleteId + ' coachingId=' + S.opts.athleteId +
            ' endpoint=(direct Firestore onSnapshot, no REST endpoint)' +
            ' responseStatus=SUCCESS recordsReturned=' + S.checkins.length);
          console.log('[COACH_MEAL_REVIEW_FETCH] coachId=' + S.opts.coachId +
            ' athleteId=' + S.opts.athleteId +
            ' query=meal_checkins.where(athleteId==' + S.opts.athleteId + ')' +
            ' documentsFound=' + rawDocs.length +
            ' reviewsReturned=' + S.checkins.length + ' pending=' + pending);
          if (rawDocs.length > 0 && S.checkins.length === 0) {
            console.warn('[COACH_MEAL_REVIEW_FETCH] MISMATCH — query found documents for this athlete, ' +
              'but NONE have coachId matching this coach. Document coachIds present: ' +
              JSON.stringify(rawDocs.map(function (c) { return c.coachId; })));
          }
        }
        var badge = $('cwCheckinBadge');
        if (badge && S.opts.role === 'coach') {
          badge.textContent = pending;
          badge.style.display = pending > 0 ? 'flex' : 'none';
        }
        if (S.tab === 'checkins') renderCheckins();
      }, function (e) {
        console.warn('[CW] meal checkins listener error', e);
        if (S.opts.role === 'coach') {
          // The listener's error callback fires ONLY on a genuine query-level
          // failure (permission-denied from Security Rules) — this is
          // distinct from the zero-results case above, which is a successful
          // query that simply matched nothing (or got filtered client-side).
          console.error('[COACH MEAL REVIEW LOAD] responseStatus=DENIED (permission-denied, not zero-results) ' +
            'expertId=' + S.opts.coachId + ' coachId=' + S.opts.coachId + ' athleteId=' + S.opts.athleteId, e);
          console.error('[COACH_MEAL_REVIEW_FETCH] DENIED (permission-denied, not zero-results) coachId=' +
            S.opts.coachId + ' athleteId=' + S.opts.athleteId, e);
        }
      }));

    /* coachId pinned as a query filter for the same rules reason as
       meal_checkins above — workout_checkins carries the identical read rule. */
    S.unsubs.push(d.collection('workout_checkins')
      .where('athleteId', '==', S.opts.athleteId)
      .where('coachId', '==', S.opts.coachId)
      .onSnapshot(function (snap) {
        S.workoutCheckins = snap.docs.map(function (x) { return x.data(); })
          .filter(function (c) { return c.coachId === S.opts.coachId; })
          .sort(function (a, b) { return (b.timestamp || '') < (a.timestamp || '') ? -1 : 1; });
        if (S.tab === 'training' && !S.trainDirty) renderTab();
      }, function (e) { console.warn('[CW] workout checkins listener error', e); }));

    S.unsubs.push(d.collection('chat_rooms').doc(chatId()).collection('messages')
      .orderBy('timestamp')
      .onSnapshot(function (snap) {
        S.chatMsgs = snap.docs.map(function (x) { return x.data(); })
          .filter(function (m) { return m && m.type !== 'review_packet'; });
        if (S.tab === 'chat') renderChatMsgs();
      }, function (e) { console.warn('[CW] chat listener error', e); }));

    /* Live relationship status — the ONLY thing that ever changes S.opts
       after open(). canEditDiet()/canEditTraining()/renderHeader()/
       renderChatShell() already branch correctly on S.opts.status; without
       this listener those branches are frozen at whatever status the
       workspace was opened with, so a mid-session expiry (the 15-min sweep,
       or the athlete/coach ending it from elsewhere) never takes effect
       until the page is reloaded. firestore.rules grants read on this doc
       to the athlete OR the matching coachId regardless of status, so the
       listener survives the active->expired/ended transition itself. */
    S.unsubs.push(d.collection('personal_coaching').doc(S.opts.athleteId)
      .onSnapshot(function (snap) {
        if (!snap.exists || !S.opts) return;
        var rel = snap.data();
        var wasActive = S.opts.status === 'active';
        S.opts.status = rel.status;
        S.opts.endDate = rel.endDate || S.opts.endDate;
        S.opts.coachingType = rel.coachingType || S.opts.coachingType;
        S.opts.trialDurationDays = rel.trialDurationDays || S.opts.trialDurationDays;
        if (wasActive && rel.status !== 'active') {
          var hadUnsaved = S.dietDirty || S.trainDirty;
          _cancelAutoSave('diet');
          _cancelAutoSave('training');
          console.log('[CW] relationship left active mid-session — status now', rel.status);
          toast(hadUnsaved
            ? '⚠ This coaching relationship has ended. Unsaved changes could not be saved.'
            : 'This coaching relationship has ended.');
          renderHeader();
          renderTab();
        }
      }, function (e) { console.warn('[CW] relationship listener error', e); }));
  }

  /* Normalizes the raw users/{uid} doc (cloud-sync.js field names) into
     the ctx shape the workspace consumes. Null when the athlete has no
     synced data (brand-new account or freshly reset goal). The expert-
     modification wrapper schema is unwrapped to the flat plan. */
  function _normalizeAthleteDoc(data) {
    if (!data) return null;
    var diet = data.dietPlan || null;
    if (diet && (diet.currentDietPlan || diet.originalDietPlan)) {
      diet = diet.currentDietPlan || diet.originalDietPlan;
    }
    var workout = data.workoutPlan || null;
    if (workout && (workout.currentWorkoutPlan || workout.originalWorkoutPlan)) {
      workout = workout.currentWorkoutPlan || workout.originalWorkoutPlan;
    }
    return {
      assessment:   data.assessment || null,
      calculations: data.calculations || null,
      swot:         data.swot || null,
      survey:       data.survey || null,
      goal:         data.goal || null,
      precautions:  data.precautions || null,
      diet_plan:    diet,
      workout_plan: workout,
      planId:       data.planId || null,
      syncedAt:     data.planGeneratedAt || data.goalUpdatedAt || data.assessmentUpdatedAt || null,
    };
  }
  /* Every consumer goes through this — {} when nothing has synced yet. */
  function athleteCtx() { return S.athlete || {}; }
  /* Goal-identity check for coach-authored plans: valid ONLY when stamped
     with the athlete's CURRENT planId. Fail-closed — a plan authored for
     a previous goal (or before stamping existed) is treated as absent,
     so the coach can never view or keep editing a previous goal's plan. */
  function coachPlanIsCurrent(p) {
    var aid = athleteCtx().planId;
    return !!(p && aid && p.planId === aid);
  }

  /* ══════════════════════════════════════════════
     MEDICAL PROFILE — single source for every medical surface in the
     workspace (sticky banner, Overview card, Diet/Training guidance,
     pinned chat summary). Data comes from the athlete-published context:
     free-text medical_conditions + the deterministic rules-engine output
     (services/medical_conditions.py) stored under precautions.directives.
  ══════════════════════════════════════════════ */
  var _MED_NEGATIVE = ['', 'none', 'no', 'nil', 'n/a', 'na', 'nothing'];
  function medInfo() {
    var ctx = athleteCtx();
    var a = ctx.assessment || ctx.survey || {};
    var raw = a.medical_conditions || '';
    var has = raw && _MED_NEGATIVE.indexOf(String(raw).trim().toLowerCase()) === -1;
    var prec = ctx.precautions || {};
    var dir = prec.directives || null;
    var meta = (dir && dir.conditions_meta) || null;
    if (has && !meta) {
      /* Context published before the severity engine existed — conservative
         frontend fallback so critical keywords still surface red. */
      var lower = String(raw).toLowerCase();
      var sev = /heart|cardiac|diabet|hypertension|high blood pressure|high bp/.test(lower)
        ? 'critical' : 'moderate';
      meta = [{ key: 'raw', label: raw.trim(), severity: sev }];
    }
    var rank = { minor: 1, moderate: 2, critical: 3 };
    var overall = (dir && dir.overall_severity) ||
      (meta ? meta.reduce(function (w, m) { return rank[m.severity] > rank[w] ? m.severity : w; }, 'minor') : null);
    return {
      has: !!has, raw: raw,
      meta: meta || [], severity: overall,
      precautions: prec.precautions || (dir && dir.warning_rules) || [],
      exerciseRules: (dir && dir.exercise_rules) || [],
      dietRules: (dir && dir.diet_rules) || [],
      recoveryRules: (dir && dir.recovery_rules) || [],
    };
  }
  function medBadges(med) {
    if (!med.has) return '<span class="cw-med-badge cw-med-badge--healthy">🟢 No medical conditions reported.</span>';
    var icon = { critical: '🔴', moderate: '🟠', minor: '🟢' };
    return med.meta.map(function (m) {
      return '<span class="cw-med-badge cw-med-badge--' + m.severity + '">' +
        icon[m.severity] + ' ' + esc(m.label) + '</span>';
    }).join('');
  }
  /* Condition-specific guidance strip for the Diet / Training editors */
  function medGuidanceBanner(kind) {
    var med = medInfo();
    var rules = kind === 'diet' ? med.dietRules : med.exerciseRules;
    if (!med.has) return '';
    var names = med.meta.map(function (m) { return m.label; }).join(', ') || med.raw;
    if (!rules.length) {
      return '<div class="cw-req-banner">🏥 <b>' + esc(names) + '</b> — adapt this plan to the condition; ' +
        'detailed AI guidance appears after the user regenerates their assessment.</div>';
    }
    return '<div class="cw-req-banner">🏥 <b>Medical ' + (kind === 'diet' ? 'diet' : 'workout') +
      ' guidance — ' + esc(names) + ':</b><br>' +
      rules.slice(0, 6).map(function (r) { return '• ' + esc(r); }).join('<br>') +
      '</div>';
  }

  function renderMedBanner() {
    var banner = $('cwMedBanner');
    if (!banner) return;
    var med = medInfo();
    if (!med.has) { banner.style.display = 'none'; return; }
    banner.className = 'cw-med-banner cw-med-banner--' + (med.severity || 'moderate');
    banner.innerHTML = '⚠ User has ' +
      esc(med.meta.map(function (m) { return m.label; }).join(', ') || med.raw) +
      (med.exerciseRules.length ? ' — ' + esc(med.exerciseRules[0]) : '') +
      ' <span style="font-weight:600">(see Overview → Medical Profile)</span>';
    banner.style.display = 'block';
  }

  /* ══════════════════════════════════════════════
     HEADER
  ══════════════════════════════════════════════ */
  function renderHeader() {
    if (!S.opts) return;
    var showName = S.opts.role === 'coach' ? (S.opts.athleteName || 'Athlete') : (S.opts.coachName || 'Coach');
    $('cwName').textContent = showName;
    /* Only the athlete's view of their COACH can show the badge — a
       coach viewing their athlete never sees one (athletes aren't
       verified experts). S.opts.coachVerification is passed in by the
       opener (cprofile.js), same shape as everywhere else. */
    var nameBadgeEl = $('cwNameBadge');
    if (nameBadgeEl) {
      nameBadgeEl.innerHTML = (S.opts.role !== 'coach' && typeof ZitlasBadge !== 'undefined')
        ? ZitlasBadge.render(S.opts.coachVerification, { size: 'sm' }) : '';
    }
    $('cwAvatar').textContent = showName.split(/\s+/).map(function (w) { return w[0] || ''; })
      .slice(0, 2).join('').toUpperCase() || 'A';
    $('cwPlanChip').textContent = S.opts.planLabel || S.opts.planType || 'Coaching';
    var dl = daysLeft();
    var isTrial = S.opts.coachingType === 'FREE_TRIAL';
    $('cwSubline').textContent = S.opts.status === 'active'
      ? ((isTrial ? 'FREE TRIAL' : 'Active coaching') + (dl !== null ? ' · ' + dl + ' days left' : ''))
      : (isTrial ? 'Free trial ended' : 'Coaching ended');

    var ctx = athleteCtx();
    var c = ctx.calculations || {};
    var goal = ctx.goal || {};
    var items = [];
    if (goal.type) items.push({ v: String(goal.type).replace(/_/g, ' '), l: 'Goal' });
    var a = ctx.assessment || ctx.survey || {};
    if (a.weight_kg) items.push({ v: a.weight_kg + ' kg', l: 'Weight' });
    if (c.bmi) items.push({ v: parseFloat(c.bmi).toFixed(1), l: 'BMI' });
    if (dl !== null) items.push({ v: dl + 'd', l: 'Remaining' });
    /* Chips only count coach plans authored for the CURRENT goal */
    var dietDays = S.plan && coachPlanIsCurrent(S.plan.diet) && S.plan.diet.days ? S.plan.diet.days.length : 0;
    var trainDays = S.plan && coachPlanIsCurrent(S.plan.training) && S.plan.training.days ? S.plan.training.days.length : 0;
    items.push({ v: dietDays ? dietDays + ' days' : '—', l: 'Coach Diet' });
    items.push({ v: trainDays ? trainDays + ' days' : '—', l: 'Coach Training' });

    $('cwSummary').innerHTML = items.map(function (it) {
      return '<div class="cw-sum-item"><span class="cw-sum-val">' + esc(it.v) +
        '</span><span class="cw-sum-lbl">' + esc(it.l) + '</span></div>';
    }).join('');

    renderMedBanner();
  }

  /* ══════════════════════════════════════════════
     TAB ROUTER
  ══════════════════════════════════════════════ */
  function renderTab() {
    if (!S.open) return;
    if (S.loadError) { renderLoadError(); return; }
    if (S.tab === 'overview')      renderOverview();
    else if (S.tab === 'diet')     renderDiet();
    else if (S.tab === 'training') renderTraining();
    else if (S.tab === 'checkins') renderCheckins();
    else if (S.tab === 'weekly')   renderWeeklyReview();
    else if (S.tab === 'chat')     renderChatShell();
  }

  /* The one error UI every load-failure path (see _reportLoadError) routes
     through — replaces whichever tab was active with a single, honest,
     actionable state instead of leaving any tab silently stuck. */
  function renderLoadError() {
    var body = $('cwBody');
    if (!body) return;
    body.innerHTML =
      '<div class="cw-card"><div class="cw-empty">' +
        '<span class="cw-empty-icon">⚠️</span>' +
        esc(S.loadError) +
        '<div class="cw-save-bar" style="position:static;background:none">' +
          '<button class="cw-save-btn" id="cwRetryLoad">Retry</button>' +
        '</div>' +
      '</div></div>';
    var btn = $('cwRetryLoad');
    if (btn) btn.addEventListener('click', retryLoad);
  }

  /* ══════════════════════════════════════════════
     OVERVIEW — everything ZITLAS AI already knows
  ══════════════════════════════════════════════ */
  function kv(label, val) {
    if (val === null || val === undefined || val === '' ) return '';
    return '<div class="cw-kv-row"><span>' + esc(label) + '</span><b>' + esc(val) + '</b></div>';
  }
  function cap(s) {
    s = String(s == null ? '' : s).replace(/_/g, ' ');
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
  }

  function renderOverview() {
    var body = $('cwBody');
    var ctx = S.athlete;
    if (!ctx || (!ctx.assessment && !ctx.calculations && !ctx.survey)) {
      body.innerHTML =
        '<div class="cw-card"><div class="cw-empty">' +
          '<span class="cw-empty-icon">📡</span>' +
          (!S.athleteLoaded
            ? 'Loading user data…'
            : (S.opts.role === 'coach'
              ? 'This user has no active goal yet.<br>Their profile fills in automatically the moment they complete an assessment.'
              : 'You don’t have an active goal yet.<br>Complete your assessment on the AI Coach page and this fills in automatically.')) +
        '</div></div>';
      return;
    }
    var a = ctx.assessment || ctx.survey || {};
    var sv = ctx.survey || {};
    var c = ctx.calculations || {};
    var g = ctx.goal || {};
    var swot = ctx.swot || null;

    var metrics = [];
    function metric(v, l) { if (v !== undefined && v !== null && v !== '') metrics.push({ v: v, l: l }); }
    metric(c.bmi ? parseFloat(c.bmi).toFixed(1) : null, 'BMI');
    metric(c.bmi_category, 'Category');
    metric(c.bmr_kcal ? Math.round(c.bmr_kcal) + ' kcal' : null, 'BMR');
    metric(c.tdee_kcal ? Math.round(c.tdee_kcal) + ' kcal' : null, 'TDEE');
    metric(c.weight_loss_calories_kcal ? c.weight_loss_calories_kcal + ' kcal' : (c.target_calories_kcal ? c.target_calories_kcal + ' kcal' : null), 'Target Cal');
    metric(c.protein_target_g ? c.protein_target_g + ' g' : null, 'Protein');
    metric(c.water_target_l ? c.water_target_l + ' L' : (c.water_liters ? c.water_liters + ' L' : null), 'Water');
    metric(c.daily_steps || c.steps_target, 'Steps');

    var progress = '';
    if (g.current_value && g.target_value) {
      progress = g.current_value + ' → ' + g.target_value;
    }

    var html =
      '<div class="cw-card"><p class="cw-card-title">👤 User Profile</p>' +
        kv('Name', S.opts.athleteName) +
        kv('Age', a.age) +
        kv('Gender', cap(a.gender)) +
        kv('Height', a.height_cm ? a.height_cm + ' cm' : null) +
        kv('Weight', a.weight_kg ? a.weight_kg + ' kg' : null) +
        kv('Goal Weight', a.goal_weight_kg ? a.goal_weight_kg + ' kg' : null) +
      '</div>';

    if (metrics.length) {
      html += '<div class="cw-card"><p class="cw-card-title">📊 AI Fitness Metrics</p>' +
        '<div class="cw-metric-grid">' + metrics.map(function (m) {
          return '<div class="cw-metric"><span class="cw-metric-val">' + esc(m.v) +
            '</span><span class="cw-metric-lbl">' + esc(m.l) + '</span></div>';
        }).join('') + '</div></div>';
    }

    /* 🚶 Live Activity & Steps — reads users/{athleteId}/activity (the day
       documents activity-service.js syncs from the athlete's device) and
       subscribes to today's doc so the coach sees new steps in real time. */
    html += '<div class="cw-card"><p class="cw-card-title">🚶 Activity &amp; Steps</p>' +
      '<div id="cwActivityCard"><div class="cw-empty" style="padding:8px 0">Loading step data…</div></div></div>';

    /* 🏥 Medical Profile — directly below AI Fitness Metrics. Severity
       badges + precautions + AI coaching notes come from the deterministic
       backend rules engine, never the LLM. The assessment captures medical
       info as ONE free-text answer, so allergies/disabilities/medications
       only appear if the athlete typed them there — never invented. */
    var med = medInfo();
    html += '<div class="cw-card"' +
      (med.has && med.severity === 'critical' ? ' style="border:1.5px solid rgba(229,72,77,0.4)"' : '') +
      '><p class="cw-card-title">🏥 Medical Profile</p>' +
      '<div style="margin-bottom:' + (med.has ? '10px' : '0') + '">' + medBadges(med) + '</div>';
    if (med.has) {
      html +=
        '<span class="cw-score-label">Medical Conditions (as reported)</span>' +
        '<p style="font-size:13.5px;font-weight:700;color:var(--text,#1E293B);margin:0 0 10px">' + esc(med.raw) + '</p>' +
        '<p style="font-size:11.5px;color:var(--text-sec,#94A3B8);margin:0 0 10px">Allergies, disabilities, injuries or medications appear above only if the user mentioned them in their assessment answer.</p>' +
        (med.precautions.length
          ? '<span class="cw-score-label">Today’s Precautions</span><ul class="cw-med-list" style="margin-bottom:10px">' +
              med.precautions.map(function (p) { return '<li>' + esc(p) + '</li>'; }).join('') + '</ul>'
          : '') +
        (med.exerciseRules.length
          ? '<span class="cw-score-label">AI Coaching Notes</span><ul class="cw-med-list">' +
              med.exerciseRules.slice(0, 6).map(function (r) { return '<li>' + esc(r) + '</li>'; }).join('') + '</ul>'
          : '');
    }
    html += '</div>';

    if (g.type || progress) {
      html += '<div class="cw-card"><p class="cw-card-title">🎯 Current Goal</p>' +
        kv('Goal', cap(g.type)) +
        kv('Progress', progress) +
        kv('Target Date', g.end_date ? fmtDate(g.end_date) : null) +
        kv('Assessment Score', a.score || a.assessment_score) +
      '</div>';
    }

    if (swot && (swot.strengths || swot.weaknesses || swot.opportunities || swot.threats)) {
      function quad(cls, title, arr) {
        if (!arr || !arr.length) return '';
        return '<div class="cw-swot-quad cw-swot-quad--' + cls + '"><h4>' + title + '</h4><ul>' +
          arr.slice(0, 4).map(function (x) { return '<li>' + esc(typeof x === 'string' ? x : (x.point || x.text || JSON.stringify(x))) + '</li>'; }).join('') +
          '</ul></div>';
      }
      html += '<div class="cw-card"><p class="cw-card-title">🧭 AI SWOT Analysis</p><div class="cw-swot-grid">' +
        quad('s', 'Strengths', swot.strengths) +
        quad('w', 'Weaknesses', swot.weaknesses) +
        quad('o', 'Opportunities', swot.opportunities) +
        quad('t', 'Threats', swot.threats) +
        '</div></div>';
    }

    var lifestyle =
      kv('Health Conditions', Array.isArray(a.health_conditions) ? a.health_conditions.join(', ') : a.health_conditions) +
      kv('Food Preference', cap(a.diet_preference || a.food_preference || sv.diet_preference)) +
      kv('Workout Preference', cap(a.workout_preference || sv.workout_preference)) +
      kv('Activity Level', cap(a.activity_level)) +
      kv('Stress Level', cap(a.stress_level || sv.stress_level)) +
      kv('Sleep', a.sleep_hours ? a.sleep_hours + ' hrs' : cap(a.sleep_quality || sv.sleep_quality));
    if (lifestyle) {
      html += '<div class="cw-card"><p class="cw-card-title">🌿 Lifestyle</p>' + lifestyle + '</div>';
    }

    html += '<div class="cw-card"><p class="cw-card-title">🤖 Data Source</p>' +
      '<div class="cw-empty" style="padding:6px 0 2px">Generated by ZITLAS AI — live from the user’s profile' +
      (ctx.syncedAt ? ' (plan generated ' + esc(fmtDate(ctx.syncedAt)) + ')' : '') +
      '. Always the latest assessment — the coach never needs to re-ask these questions.</div></div>';

    body.innerHTML = html;
    loadActivityCard();
  }

  /* ── 🚶 Activity & Steps card (Overview tab) ──
     Fetches the athlete's last 30 archived day docs + today's live doc.
     Rendered async so a slow/offline Firestore never blocks the Overview. */
  function loadActivityCard() {
    var mount = $('cwActivityCard');
    var d = db();
    if (!mount) return;
    if (!d || !S.opts || !S.opts.athleteId) {
      mount.innerHTML = '<div class="cw-empty" style="padding:8px 0">Step data unavailable.</div>';
      return;
    }
    var todayStr = new Date().getFullYear() + '-' +
      String(new Date().getMonth() + 1).padStart(2, '0') + '-' +
      String(new Date().getDate()).padStart(2, '0');

    function renderCard(days, goal) {
      var el = $('cwActivityCard');
      if (!el) return; /* user switched tabs */
      if (!days.length) {
        el.innerHTML = '<div class="cw-empty" style="padding:8px 0">No step data synced yet.<br>' +
          'It appears automatically once the user opens their dashboard with step tracking on.</div>';
        return;
      }
      var byDate = {};
      days.forEach(function (r) { byDate[r.date] = r; });
      var today = byDate[todayStr] || null;
      var past = days.filter(function (r) { return r.date !== todayStr; });

      function avg(list) {
        if (!list.length) return 0;
        return Math.round(list.reduce(function (s, r) { return s + (r.steps || 0); }, 0) / list.length);
      }
      var avg7  = avg(past.slice(0, 7));
      var avg30 = avg(past.slice(0, 30));
      var prev7 = avg(past.slice(7, 14));
      var trend = (avg7 && prev7) ? (avg7 > prev7 * 1.05 ? '📈 Improving' : (avg7 < prev7 * 0.95 ? '📉 Declining' : '➡️ Steady')) : '—';
      var missed = past.slice(0, 30).filter(function (r) { return !r.goalCompleted; }).length;
      var todaySteps = today ? (today.steps || 0) : 0;
      var todayGoal = (today && today.goalEffective) || goal || 10000;
      var pctToday = todayGoal > 0 ? Math.min(100, Math.round((todaySteps / todayGoal) * 100)) : 100;
      var recovery = !!(today && today.recoveryMode);

      /* Mini 7-day bar strip (pure CSS heights) */
      var last7 = days.slice(0, 7).reverse();
      var maxSteps = Math.max.apply(null, last7.map(function (r) { return r.steps || 1; }).concat([1]));
      var bars = last7.map(function (r) {
        var h = Math.max(8, Math.round(((r.steps || 0) / maxSteps) * 42));
        var done = r.goalCompleted;
        return '<div title="' + esc(r.date + ': ' + (r.steps || 0).toLocaleString() + ' steps') + '"' +
          ' style="width:16px;height:' + h + 'px;border-radius:5px 5px 2px 2px;' +
          'background:' + (done ? 'linear-gradient(180deg,#234B35,#E07A15)' : 'rgba(148,163,184,0.4)') + '"></div>';
      }).join('');

      el.innerHTML =
        '<div class="cw-kv-row"><span>Today’s Steps</span><b id="cwActToday">' + todaySteps.toLocaleString() +
          ' <span style="font-weight:600;color:var(--text-sec,#94A3B8)">/ ' + todayGoal.toLocaleString() +
          ' (' + pctToday + '%)</span></b></div>' +
        (recovery
          ? '<div class="cw-kv-row"><span>Status</span><b style="color:#0EA5E9">🛟 Recovery Mode — goal reduced</b></div>'
          : '') +
        '<div class="cw-kv-row"><span>7-Day Average</span><b>' + avg7.toLocaleString() + '</b></div>' +
        '<div class="cw-kv-row"><span>30-Day Average</span><b>' + avg30.toLocaleString() + '</b></div>' +
        '<div class="cw-kv-row"><span>Current Goal</span><b>' + (goal || 10000).toLocaleString() + ' steps</b></div>' +
        '<div class="cw-kv-row"><span>Missed Goal Days (30d)</span><b>' + missed + '</b></div>' +
        '<div class="cw-kv-row"><span>Trend</span><b>' + trend + '</b></div>' +
        '<div style="display:flex;align-items:flex-end;gap:6px;height:46px;margin-top:10px">' + bars + '</div>';
    }

    var userRef = d.collection('users').doc(S.opts.athleteId);
    Promise.all([
      userRef.get().catch(function () { return null; }),
      userRef.collection('activity').orderBy('date', 'desc').limit(30).get().catch(function () { return null; }),
    ]).then(function (res) {
      var goal = (res[0] && res[0].exists && res[0].data().dailyStepGoal) || 10000;
      var days = [];
      if (res[1]) res[1].forEach(function (doc) { days.push(doc.data()); });
      renderCard(days, goal);

      /* Live: today's doc updates the card the moment the user's
         device syncs new steps — no refresh on the coach's side. */
      S.unsubs.push(userRef.collection('activity').doc(todayStr).onSnapshot(function (snap) {
        if (!snap.exists) return;
        var fresh = snap.data();
        var rest = days.filter(function (r) { return r.date !== todayStr; });
        rest.unshift(fresh);
        days = rest;
        renderCard(days, goal);
      }, function () {}));
    });
  }

  /* ══════════════════════════════════════════════
     DIET TAB
  ══════════════════════════════════════════════ */
  function emptyDietWeek() {
    return {
      days: DAYS.map(function (d) {
        return { day: d, meals: DEFAULT_MEALS.map(function (m) {
          return { id: newId('meal'), name: m, time: '', options: [{ name: '', calories: '', protein: '', notes: '' }] };
        }) };
      }),
    };
  }

  /* Prefill the editor from the athlete's LATEST AI diet (live users doc) */
  function dietFromAiPlan() {
    var ai = athleteCtx().diet_plan;
    var aiDays = ai && ai.days;
    if (!aiDays || !aiDays.length) return null;
    return {
      days: DAYS.map(function (d, i) {
        var src = aiDays[i % aiDays.length] || {};
        var meals = (src.meals || []).map(function (m) {
          return {
            id: newId('meal'),
            name: m.meal_name || 'Meal',
            time: m.time || '',
            options: [{
              name: (m.foods || []).join(', '),
              calories: m.calories || '', protein: m.protein_g || '',
              notes: m.purpose || '',
            }],
          };
        });
        if (!meals.length) meals = DEFAULT_MEALS.map(function (mn) {
          return { id: newId('meal'), name: mn, time: '', options: [{ name: '', calories: '', protein: '', notes: '' }] };
        });
        return { day: d, meals: meals };
      }),
    };
  }

  function dayPillsHtml(days, activeIdx, pendingByDay) {
    return '<div class="cw-day-pills">' + days.map(function (d, i) {
      return '<button class="cw-day-pill' + (i === activeIdx ? ' active' : '') + '" data-cw-day="' + i + '">' +
        esc((d.day || '').slice(0, 3)) +
        (pendingByDay && pendingByDay[d.day] ? '<span class="cw-day-dot"></span>' : '') +
        '</button>';
    }).join('') + '</div>';
  }
  function wireDayPills(container, cb) {
    container.querySelectorAll('[data-cw-day]').forEach(function (p) {
      p.addEventListener('click', function () {
        S.dayIdx = parseInt(p.dataset.cwDay, 10) || 0;
        cb();
      });
    });
  }

  function renderDiet() {
    if (canEditDiet()) renderDietEditor();
    else renderDietViewer();
  }

  /* ── athlete / read-only coach view ── */
  function renderDietViewer() {
    var body = $('cwBody');
    var diet = S.plan && coachPlanIsCurrent(S.plan.diet) ? S.plan.diet : null;
    var readonlyNote = (S.opts.role === 'coach' && !canEditDiet())
      ? '<div class="cw-readonly-note">🔒 Diet is read-only on the ' + esc(S.opts.planLabel || 'current') + ' plan.</div>'
      : '';
    if (!diet || !diet.days || !diet.days.length) {
      body.innerHTML = readonlyNote +
        '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">🥗</span>' +
        (S.opts.role === 'athlete'
          ? 'Your coach hasn’t published a diet plan yet.<br>You’ll be notified the moment it’s ready.'
          : 'No coach diet plan yet.') +
        '</div></div>';
      return;
    }
    if (S.dayIdx >= diet.days.length) S.dayIdx = 0;
    var day = diet.days[S.dayIdx];
    var selections = (S.plan && S.plan.dietSelections) || {};
    var pending = {};
    S.mealReqs.forEach(function (r) {
      if (r.status === 'pending') pending[r.day + ':' + r.mealId] = true;
    });

    var mealsHtml = (day.meals || []).map(function (m) {
      var selKey = day.day + ':' + m.id;
      var selIdx = Math.min(selections[selKey] || 0, Math.max(0, (m.options || []).length - 1));
      var opt = (m.options || [])[selIdx] || {};
      var macros = [];
      if (opt.calories) macros.push(opt.calories + ' kcal');
      if (opt.protein) macros.push(opt.protein + 'g protein');
      var emoji = MEAL_EMOJI[(m.name || '').toLowerCase()] || '🍽️';
      var optCount = (m.options || []).filter(function (o) { return o && o.name; }).length;
      var isPending = pending[selKey];
      return '<div class="cw-meal-card">' +
        '<div class="cw-meal-head">' +
          '<span>' + emoji + '</span>' +
          '<span class="cw-meal-name">' + esc(m.name || 'Meal') + '</span>' +
          (isPending ? '<span class="cw-meal-pending">⏳ Asked expert</span>' : '') +
          (m.time ? '<span class="cw-meal-time">' + esc(m.time) + '</span>' : '') +
        '</div>' +
        '<p class="cw-meal-food">' + esc(opt.name || '—') + '</p>' +
        (macros.length ? '<p class="cw-meal-macros">' + esc(macros.join(' · ')) + '</p>' : '') +
        (opt.notes ? '<p class="cw-meal-notes">' + esc(opt.notes) + '</p>' : '') +
        (S.opts.role === 'athlete' && S.opts.status === 'active'
          ? '<div class="cw-meal-actions">' +
              '<button class="cw-meal-btn cw-meal-btn--swap" data-cw-swap="' + esc(m.id) + '">🔄 Swap Meal <span class="cw-opt-count">(' + optCount + ' options)</span></button>' +
              '<button class="cw-meal-btn cw-meal-btn--ask" data-cw-ask="' + esc(m.id) + '">💬 Ask Expert</button>' +
            '</div>'
          : '') +
        '</div>';
    }).join('');

    body.innerHTML = readonlyNote + dayPillsHtml(diet.days, S.dayIdx) +
      (mealsHtml || '<div class="cw-card"><div class="cw-empty">No meals for this day.</div></div>');

    wireDayPills(body, renderDietViewer);
    body.querySelectorAll('[data-cw-swap]').forEach(function (b) {
      b.addEventListener('click', function () { openSwapSheet(day, b.dataset.cwSwap); });
    });
    body.querySelectorAll('[data-cw-ask]').forEach(function (b) {
      b.addEventListener('click', function () { openAskSheet(day, b.dataset.cwAsk); });
    });
  }

  /* Athlete swap: pick among the coach's predefined options ONLY.
     The global food dataset is never queried here. */
  function openSwapSheet(day, mealId) {
    var meal = (day.meals || []).find(function (m) { return m.id === mealId; });
    if (!meal) return;
    var selections = (S.plan && S.plan.dietSelections) || {};
    var selKey = day.day + ':' + meal.id;
    var selIdx = selections[selKey] || 0;
    var opts = (meal.options || []).filter(function (o) { return o && o.name; });
    if (!opts.length) { toast('Your coach hasn’t added alternatives for this meal yet — use Ask Expert.'); return; }

    openSheet(
      '<p class="cw-sheet-title">Swap ' + esc(meal.name || 'Meal') + '</p>' +
      '<p class="cw-sheet-sub">' + esc(day.day) + ' — choose one of your coach’s options. These are the only alternatives while coaching is active.</p>' +
      opts.map(function (o, i) {
        var meta = [];
        if (o.calories) meta.push(o.calories + ' kcal');
        if (o.protein) meta.push(o.protein + 'g protein');
        return '<button class="cw-opt-choice' + (i === selIdx ? ' selected' : '') + '" data-cw-pick="' + i + '">' +
          '<span class="cw-opt-choice-label">Option ' + (i + 1) + (i === selIdx ? ' · current' : '') + '</span>' +
          '<span class="cw-opt-choice-name">' + esc(o.name) + '</span>' +
          (meta.length || o.notes
            ? '<span class="cw-opt-choice-meta">' + esc(meta.join(' · ')) + (o.notes ? (meta.length ? ' · ' : '') + esc(o.notes) : '') + '</span>'
            : '') +
          '</button>';
      }).join('')
    );
    $('cwSheet').querySelectorAll('[data-cw-pick]').forEach(function (b) {
      b.addEventListener('click', function () {
        var idx = parseInt(b.dataset.cwPick, 10) || 0;
        var d = db();
        if (!d) return;
        /* set+merge (not update) — the key contains ':' which is illegal in
           a string field path but fine as a map key under merge. */
        var sel = {};
        sel[selKey] = idx;
        d.collection('coaching_plans').doc(S.opts.athleteId).set({ dietSelections: sel }, { merge: true })
          .then(function () {
            closeSheet();
            toast('✅ ' + (meal.name || 'Meal') + ' swapped to Option ' + (idx + 1));
          })
          .catch(function (e) { console.warn('[CW] swap failed', e); toast('Swap failed — try again.'); });
      });
    });
  }

  /* Athlete "Ask Expert" — request alternatives for one specific meal */
  function openAskSheet(day, mealId) {
    var meal = (day.meals || []).find(function (m) { return m.id === mealId; });
    if (!meal) return;
    var already = S.mealReqs.some(function (r) {
      return r.status === 'pending' && r.day === day.day && r.mealId === meal.id;
    });
    if (already) { toast('You’ve already asked about this meal — your coach will reply soon.'); return; }

    openSheet(
      '<p class="cw-sheet-title">Ask Expert — ' + esc(meal.name || 'Meal') + '</p>' +
      '<p class="cw-sheet-sub">' + esc(day.day) + ' — your coach will be notified and can reply with new options for this meal.</p>' +
      '<textarea class="cw-textarea" id="cwAskNote" rows="3" placeholder="Optional note (e.g. “I don’t have these ingredients”)"></textarea>' +
      '<div class="cw-save-bar" style="position:static;background:none;padding-top:14px">' +
        '<button class="cw-ghost-btn" id="cwAskCancel">Cancel</button>' +
        '<button class="cw-save-btn" id="cwAskSend">Send Request</button>' +
      '</div>'
    );
    $('cwAskCancel').addEventListener('click', closeSheet);
    $('cwAskSend').addEventListener('click', function () {
      var d = db();
      if (!d) return;
      var id = newId('CMR');
      var req = {
        requestId: id,
        athleteId: S.opts.athleteId, athleteName: S.opts.athleteName || 'Athlete',
        coachId: S.opts.coachId,
        day: day.day, mealId: meal.id, mealName: meal.name || 'Meal',
        note: ($('cwAskNote') && $('cwAskNote').value.trim()) || '',
        status: 'pending', createdAt: new Date().toISOString(),
      };
      console.log('[CW] ask-expert request', req);
      d.collection('coaching_meal_requests').doc(id).set(req)
        .then(function () {
          notify(S.opts.coachId, '🍽 ' + req.athleteName + ' requested alternatives for ' + req.day + ' ' + req.mealName + '.', 'meal_request');
          closeSheet();
          toast('📨 Request sent — your coach will reply with new options.');
        })
        .catch(function (e) { console.warn('[CW] ask failed', e); toast('Could not send — try again.'); });
    });
  }

  /* ── coach diet editor ── */
  function ensureDietDraft() {
    var remote = S.plan && S.plan.diet;
    /* A remote coach plan only counts when authored for the athlete's
       CURRENT goal — a stale plan (previous goal / pre-reset) is treated
       as absent so the coach re-seeds from the LATEST AI plan instead of
       continuing to edit a dead goal's plan. Old versions stay in the
       versions history. */
    var hasRemote = !!(remote && remote.days && remote.days.length && coachPlanIsCurrent(remote));
    /* A saved coach plan always beats an unsaved auto-seed (e.g. saved
       from another device between snapshots). */
    if (S.dietDraft && S.dietDraftSeeded && !S.dietDirty && hasRemote) S.dietDraft = null;
    if (S.dietDraft) return;
    if (hasRemote) {
      S.dietDraft = JSON.parse(JSON.stringify(remote));
      S.dietDraftSeeded = false;
      return;
    }
    /* No (current) coach plan — auto-preload the athlete's AI-generated
       diet so the coach edits the real plan, never a blank template.
       Template is the fallback ONLY when the AI plan genuinely doesn't
       exist. */
    var ai = dietFromAiPlan();
    if (ai) { S.dietDraft = ai; S.dietDraftSeeded = true; }
  }

  function renderDietEditor() {
    var body = $('cwBody');
    ensureDietDraft();

    if (!S.dietDraft) {
      if (!S.planLoaded || !S.athleteLoaded) {
        body.innerHTML = '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">🥗</span>Loading the user’s plan…</div></div>';
        return;
      }
      body.innerHTML =
        '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">🥗</span>' +
          'This user has no AI diet plan yet (they may not have completed their assessment). ' +
          'You can still design their week from a template — every meal can have up to 3 options they can swap between.' +
        '</div>' +
        '<div class="cw-save-bar" style="position:static;background:none">' +
          '<button class="cw-save-btn" id="cwDietBlank">Start with template</button>' +
        '</div></div>';
      $('cwDietBlank').addEventListener('click', function () {
        S.dietDraft = emptyDietWeek(); S.dietDraftSeeded = false;
        S.dietDirty = true; renderDietEditor();
      });
      return;
    }

    if (S.dayIdx >= S.dietDraft.days.length) S.dayIdx = 0;
    var day = S.dietDraft.days[S.dayIdx];
    var pendingByDay = {};
    var dayReqs = [];
    S.mealReqs.forEach(function (r) {
      if (r.status !== 'pending') return;
      pendingByDay[r.day] = true;
      if (r.day === day.day) dayReqs.push(r);
    });

    var reqBanner = dayReqs.length
      ? '<div class="cw-req-banner">🔔 ' + dayReqs.map(function (r) {
          return esc(r.athleteName || 'Athlete') + ' asked for alternatives to <b>' + esc(r.mealName) + '</b>' +
            (r.note ? ' — “' + esc(r.note) + '”' : '');
        }).join('<br>') + '<br>Update the options below and save — they’ll be marked replied automatically.</div>'
      : '';

    var mealsHtml = (day.meals || []).map(function (m, mi) {
      var optsHtml = (m.options || []).map(function (o, oi) {
        return '<div class="cw-opt-block">' +
          '<div class="cw-opt-block-head"><span class="cw-opt-label">Option ' + (oi + 1) + '</span>' +
            ((m.options.length > 1)
              ? '<button class="cw-icon-btn cw-icon-btn--danger" data-cw-del-opt="' + mi + ':' + oi + '" aria-label="Remove option">✕</button>'
              : '') +
          '</div>' +
          '<div class="cw-ed-row"><textarea class="cw-textarea" rows="1" placeholder="Meal / foods (e.g. Poha with peanuts + buttermilk)" data-cw-opt="' + mi + ':' + oi + ':name">' + esc(o.name || '') + '</textarea></div>' +
          '<div class="cw-ed-row">' +
            '<input class="cw-input cw-input--sm" inputmode="numeric" placeholder="kcal" value="' + esc(o.calories || '') + '" data-cw-opt="' + mi + ':' + oi + ':calories">' +
            '<input class="cw-input cw-input--sm" inputmode="numeric" placeholder="protein g" value="' + esc(o.protein || '') + '" data-cw-opt="' + mi + ':' + oi + ':protein">' +
            '<input class="cw-input" placeholder="Notes / instructions" value="' + esc(o.notes || '') + '" data-cw-opt="' + mi + ':' + oi + ':notes">' +
          '</div>' +
        '</div>';
      }).join('');
      return '<div class="cw-ed-meal">' +
        '<div class="cw-ed-meal-head">' +
          '<input class="cw-input" placeholder="Meal name" value="' + esc(m.name || '') + '" data-cw-meal="' + mi + ':name">' +
          '<input class="cw-input cw-input--sm" placeholder="Time" value="' + esc(m.time || '') + '" data-cw-meal="' + mi + ':time">' +
          '<button class="cw-icon-btn cw-icon-btn--danger" data-cw-del-meal="' + mi + '" aria-label="Remove meal">🗑</button>' +
        '</div>' +
        optsHtml +
        ((m.options || []).length < 3
          ? '<button class="cw-add-btn" style="margin-bottom:0" data-cw-add-opt="' + mi + '">+ Add option ' + ((m.options || []).length + 1) + ' of 3</button>'
          : '') +
        '</div>';
    }).join('');

    var seededNote = (S.dietDraftSeeded && !S.dietDirty)
      ? '<div class="cw-req-banner">🤖 Preloaded from the user’s AI-generated diet plan — review, adjust anything, then Save to publish your version.</div>'
      : '';

    body.innerHTML =
      dayPillsHtml(S.dietDraft.days, S.dayIdx, pendingByDay) +
      seededNote +
      medGuidanceBanner('diet') +
      reqBanner +
      mealsHtml +
      '<button class="cw-add-btn" id="cwAddMeal">+ Add custom meal to ' + esc(day.day) + '</button>' +
      '<div class="cw-save-bar">' +
        '<button class="cw-ghost-btn" id="cwDietHistory">🕘 History</button>' +
        '<span class="cw-save-status" id="cwDietSaveStatus"></span>' +
        '<button class="cw-save-btn" id="cwDietSave"' + ((S.dietDirty || S.dietDraftSeeded) ? '' : ' disabled') + '>' +
          ((S.dietDirty || S.dietDraftSeeded) ? 'Save Diet Plan' : 'Saved ✓') + '</button>' +
      '</div>';

    wireDayPills(body, renderDietEditor);

    function markDirty() {
      if (!S.dietDirty) {
        S.dietDirty = true;
        var sb = $('cwDietSave');
        if (sb) { sb.disabled = false; sb.textContent = 'Save Diet Plan'; }
      }
      /* Bumped on EVERY keystroke, not just the dirty transition — saveDiet
         compares this against the generation it started with, so a save
         that was already in flight when the coach typed again never
         blanks out the dirty flag for an edit it didn't actually capture. */
      S.dietEditGen++;
      scheduleAutoSave('diet');
    }
    body.querySelectorAll('[data-cw-meal]').forEach(function (inp) {
      inp.addEventListener('input', function () {
        var p = inp.dataset.cwMeal.split(':');
        day.meals[+p[0]][p[1]] = inp.value;
        markDirty();
      });
    });
    body.querySelectorAll('[data-cw-opt]').forEach(function (inp) {
      inp.addEventListener('input', function () {
        var p = inp.dataset.cwOpt.split(':');
        day.meals[+p[0]].options[+p[1]][p[2]] = inp.value;
        markDirty();
      });
    });
    body.querySelectorAll('[data-cw-add-opt]').forEach(function (b) {
      b.addEventListener('click', function () {
        var m = day.meals[+b.dataset.cwAddOpt];
        if (m.options.length < 3) m.options.push({ name: '', calories: '', protein: '', notes: '' });
        markDirty(); renderDietEditor();
      });
    });
    body.querySelectorAll('[data-cw-del-opt]').forEach(function (b) {
      b.addEventListener('click', function () {
        var p = b.dataset.cwDelOpt.split(':');
        day.meals[+p[0]].options.splice(+p[1], 1);
        markDirty(); renderDietEditor();
      });
    });
    body.querySelectorAll('[data-cw-del-meal]').forEach(function (b) {
      b.addEventListener('click', function () {
        day.meals.splice(+b.dataset.cwDelMeal, 1);
        markDirty(); renderDietEditor();
      });
    });
    $('cwAddMeal').addEventListener('click', function () {
      day.meals.push({ id: newId('meal'), name: '', time: '', options: [{ name: '', calories: '', protein: '', notes: '' }] });
      markDirty(); renderDietEditor();
    });
    /* NOT `addEventListener('click', saveX)` — that hands the click Event in
       as `isAuto`, and an Event is truthy. A manual save then took the
       auto-save branch: no "Saving…" on the button, and on failure it
       silently rescheduled a retry instead of surfacing the error, so a save
       that never landed looked like nothing had happened at all. */
    $('cwDietSave').addEventListener('click', function () { saveDiet(false); });
    $('cwDietHistory').addEventListener('click', function () { openHistory('diet'); });
  }

  function saveDiet(isAuto) {
    if (!S.dietDraft) return;
    if (!canEditDiet()) { _setSaveStatus('diet', 'locked'); return; }
    if (S.saving) {
      /* Another save (diet or training — S.saving is a single shared
         single-flight guard) is already in flight. Don't drop this change:
         re-arm the debounce so it's retried once the current save clears. */
      if (isAuto) scheduleAutoSave('diet');
      return;
    }
    var d = db();
    if (!d) { toast('Connection unavailable'); return; }
    S.saving = true;
    var btn = $('cwDietSave');
    if (!isAuto && btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
    _setSaveStatus('diet', 'saving');

    var now = new Date().toISOString();
    var docRef = d.collection('coaching_plans').doc(S.opts.athleteId);
    var pendingReqs = S.mealReqs.filter(function (r) { return r.status === 'pending'; });
    var draft = S.dietDraft;
    /* Snapshot the edit generation at save-start. dietDraft is mutated
       IN PLACE by every keystroke, so object identity can't tell us
       whether new edits landed while this save's transaction was still
       round-tripping — the generation counter can. Only clear dietDirty if
       nothing changed since we started; otherwise the coach's newest
       keystrokes would be reported as "Saved" when they haven't actually
       reached Firestore yet. */
    var startGen = S.dietEditGen;

    /* Goal-identity stamp: this plan belongs to the athlete's CURRENT
       plan generation. Consumers (diet.js, this workspace) fail-closed
       on mismatch, so it silently retires if the athlete resets. */
    draft.planId = athleteCtx().planId || null;

    var savedVersion;
    /* Version bump moved inside the transaction — reads the LIVE server
       document instead of the locally cached S.plan, which could be stale
       by the time this fires (debounced auto-save makes overlapping saves
       a normal occurrence, not just a rare double-click). */
    d.runTransaction(function (tx) {
      return tx.get(docRef).then(function (snap) {
        var cur = snap.exists ? snap.data() : {};
        savedVersion = (cur.dietVersion || 0) + 1;
        tx.set(docRef, {
          athleteId: S.opts.athleteId, athleteName: S.opts.athleteName || 'Athlete',
          coachId: S.opts.coachId, coachName: S.opts.coachName || 'Coach',
          planType: S.opts.planType || 'complete',
          diet: draft, dietUpdatedAt: now, dietVersion: savedVersion,
        }, { merge: true });
      });
    }).then(function () {
      /* Version snapshot for history / restore */
      return docRef.collection('versions').doc('diet_' + Date.now()).set({
        type: 'diet', data: draft, version: savedVersion,
        savedAt: now, savedBy: S.opts.coachName || 'Coach',
      });
    }).then(function () {
      /* Resolve any pending Ask-Expert requests — the athlete just got new options */
      pendingReqs.forEach(function (r) {
        d.collection('coaching_meal_requests').doc(r.requestId)
          .update({ status: 'replied', repliedAt: now }).catch(function () {});
      });
      notify(S.opts.athleteId,
        pendingReqs.length
          ? '✅ Your coach replied with new meal options.'
          : '🥗 ' + (S.opts.coachName || 'Your coach') + ' updated your diet plan.',
        'diet_update');
      var stillCurrent = S.dietEditGen === startGen;
      if (stillCurrent) { S.dietDirty = false; S.dietDraftSeeded = false; }
      S.saving = false;
      console.log('[CW] diet saved v' + savedVersion + (isAuto ? ' (auto)' : '') +
        (stillCurrent ? '' : ' (newer edits pending)'));
      if (stillCurrent) _setSaveStatus('diet', 'saved');
      if (isAuto) {
        /* No renderDietEditor() here — a full re-render replaces
           #cwBody.innerHTML and would steal focus/cursor out from under the
           coach if they've resumed typing elsewhere by the time this
           debounced round-trip resolves. Only the manual-click path
           re-renders. If a newer edit landed mid-save (stillCurrent is
           false), the button/status are left exactly as that newer
           markDirty() call already set them — its own scheduleAutoSave
           timer is independent and still pending, so nothing is dropped. */
        if (stillCurrent && btn) { btn.disabled = true; btn.textContent = 'Saved ✓'; }
      } else {
        toast('✅ Diet plan published to ' + (S.opts.athleteName || 'the athlete'));
        renderDietEditor();
      }
    }).catch(function (e) {
      S.saving = false;
      console.error('[CW] diet save failed', e);
      _setSaveStatus('diet', 'error');
      if (isAuto) {
        if (canEditDiet()) scheduleAutoSave('diet');
      } else {
        toast('Save failed — please try again.');
        if (btn) { btn.disabled = false; btn.textContent = 'Save Diet Plan'; }
      }
    });
  }

  /* ══════════════════════════════════════════════
     TRAINING TAB
  ══════════════════════════════════════════════ */
  function emptyTrainingWeek() {
    return {
      days: DAYS.map(function (d, i) {
        return { day: d, rest: i === 6, focus: '', duration: '', exercises: [] };
      }),
    };
  }
  function trainingFromAiPlan() {
    var wp = athleteCtx().workout_plan;
    var aiDays = wp && (wp.weekly_plan || wp.days || wp.weekly_schedule || wp.workout_days);
    if (!aiDays || !aiDays.length) return null;
    return {
      days: DAYS.map(function (d, i) {
        var src = aiDays[i % aiDays.length] || {};
        var focus = src.focus || src.type || '';
        return {
          day: d,
          rest: /rest/i.test(focus),
          focus: focus,
          duration: src.duration_minutes ? String(src.duration_minutes) : '',
          exercises: (src.exercises || []).map(function (ex) {
            return { name: ex.name || '', sets: ex.sets ? String(ex.sets) : '',
              reps: ex.reps_or_duration || '', duration: '', rest: '', notes: ex.tip || '' };
          }),
        };
      }),
    };
  }

  function renderTraining() {
    if (canEditTraining()) renderTrainingEditor();
    else renderTrainingViewer();
    _appendWorkoutReviews();
  }

  /* Workout-day review — parity with the Meal Reviews tab's meal_checkins
     flow (day.js's "Send Workout to Coach"), appended to whichever
     Training render ran above rather than a separate nav tab, to keep the
     workspace's nav simple. */
  function _appendWorkoutReviews() {
    var body = $('cwBody');
    if (!body || !S.workoutCheckins.length) return; /* nothing sent yet — don't clutter the tab */

    var wrap = document.createElement('div');
    wrap.className = 'cw-workout-reviews';
    wrap.innerHTML = '<p class="cw-review-sec-title">💪 Workout Check-ins</p>' +
      S.workoutCheckins.map(function (c) {
        var statusCls = c.status === 'reviewed' ? 'cw-review-status--done' : 'cw-review-status--pending';
        var statusTxt = c.status === 'reviewed' ? (c.score != null ? c.score + '/10' : 'Reviewed') : 'Pending';
        return '<div class="cw-review-card" data-cw-workout-review="' + esc(c.checkinId) + '">' +
          '<div class="cw-review-info">' +
            '<span class="cw-review-title">' + esc(c.day) + ' — ' + esc(c.focus || 'Training') + '</span>' +
            '<span class="cw-review-sub">' + esc(fmtTime(c.timestamp)) + ' · ' + ((c.exercises || []).length) + ' exercises</span>' +
          '</div>' +
          '<span class="cw-review-status ' + statusCls + '">' + esc(statusTxt) + '</span>' +
        '</div>';
      }).join('');
    body.appendChild(wrap);

    wrap.querySelectorAll('[data-cw-workout-review]').forEach(function (el) {
      el.addEventListener('click', function () {
        var c = S.workoutCheckins.find(function (x) { return x.checkinId === el.dataset.cwWorkoutReview; });
        if (c) openWorkoutCheckinSheet(c);
      });
    });
  }

  function _exerciseListHtml(exercises) {
    return '<div class="cw-workout-ex-list">' + (exercises || []).map(function (ex) {
      var meta = [ex.sets, ex.reps].filter(Boolean).join(' × ');
      return '<div class="cw-workout-ex-row">' + esc(ex.name || '') +
        (meta ? ' <span class="cw-workout-ex-meta">' + esc(meta) + '</span>' : '') + '</div>';
    }).join('') + '</div>';
  }

  function openWorkoutCheckinSheet(c) {
    if (S.opts.role === 'coach') openWorkoutReviewSheet(c);
    else openWorkoutHistorySheet(c);
  }

  /* Athlete: read-only — see the exercises sent + coach's score/comment */
  function openWorkoutHistorySheet(c) {
    var body =
      '<p class="cw-sheet-title">' + esc(c.day) + ' — ' + esc(c.focus || 'Training') + '</p>' +
      _exerciseListHtml(c.exercises) +
      (c.status === 'reviewed'
        ? '<div class="pc-checkin-feedback">' +
            (c.score != null ? '<span class="pc-checkin-score">' + esc(c.score) + '/10</span>' : '') +
            (c.comment ? '<p class="pc-checkin-comment">' + esc(c.comment) + '</p>' : '') +
          '</div>'
        : '<div class="pc-checkin-pending">⏳ Waiting for your coach’s review</div>');
    openSheet(body);
  }

  /* Coach: score 1-10 (required) + optional comment */
  function openWorkoutReviewSheet(c) {
    S.workoutReviewDraft = { score: c.score || null, comment: c.comment || '' };
    renderWorkoutReviewSheet(c);
  }

  function renderWorkoutReviewSheet(c) {
    var d = S.workoutReviewDraft;
    openSheet(
      '<p class="cw-sheet-title">' + esc(c.day) + ' — ' + esc(c.athleteName || 'Athlete') + '</p>' +
      '<p class="cw-sheet-sub">' + esc(c.focus || 'Training') + ' · ' + esc(fmtTime(c.timestamp)) + '</p>' +
      _exerciseListHtml(c.exercises) +
      '<span class="cw-score-label">Workout Score (required)</span>' +
      '<div class="cw-score-grid">' + [1,2,3,4,5,6,7,8,9,10].map(function (n) {
        return '<button class="cw-score-btn' + (d.score === n ? ' selected' : '') + '" data-cw-wscore="' + n + '">' + n + '</button>';
      }).join('') + '</div>' +
      '<textarea class="cw-textarea" id="cwWorkoutReviewComment" rows="2" placeholder="Optional comment">' + esc(d.comment || '') + '</textarea>' +
      '<div class="cw-save-bar" style="position:static;background:none;padding-top:12px">' +
        '<button class="cw-save-btn" id="cwWorkoutReviewSave"' + (!d.score ? ' disabled' : '') + '>Save Review</button>' +
      '</div>'
    );
    var sheet = $('cwSheet');
    sheet.querySelectorAll('[data-cw-wscore]').forEach(function (b) {
      b.addEventListener('click', function () { S.workoutReviewDraft.score = parseInt(b.dataset.cwWscore, 10); renderWorkoutReviewSheet(c); });
    });
    var commentEl = $('cwWorkoutReviewComment');
    if (commentEl) commentEl.addEventListener('input', function () { S.workoutReviewDraft.comment = commentEl.value; });
    var saveBtn = $('cwWorkoutReviewSave');
    if (saveBtn) saveBtn.addEventListener('click', function () { saveWorkoutCheckinReview(c); });
  }

  function saveWorkoutCheckinReview(c) {
    var d = db();
    if (!d || !S.workoutReviewDraft || !S.workoutReviewDraft.score) return;
    var btn = $('cwWorkoutReviewSave');
    if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
    var now = new Date().toISOString();
    d.collection('workout_checkins').doc(c.checkinId).update({
      status: 'reviewed', score: S.workoutReviewDraft.score, comment: S.workoutReviewDraft.comment || null,
      reviewedAt: now, reviewedBy: S.opts.coachName || 'Coach',
    }).then(function () {
      closeSheet();
      notify(c.athleteId, '💪 Your coach reviewed ' + c.day + "'s workout: " + S.workoutReviewDraft.score + '/10', 'workout_review');
      toast('✅ Review saved');
    }).catch(function (e) { console.warn('[CW] workout review save failed', e); toast('Save failed — try again.'); });
  }

  /* ══════════════════════════════════════════════
     WEEKLY REVIEW — computed ON-DEMAND when this tab opens (not a
     precomputed scheduled job): queries the past 7 days of meal_checkins /
     workout_checkins / users/{athleteId}/activity live, then persists the
     computed numbers + the coach's written feedback to
     weekly_reviews/{athleteId}_{weekStartDate} so the feedback survives
     the coach navigating away. Chosen over a scheduled job because a
     week's worth of one user's data is trivial to query live, it's
     always fresh, and it avoids a third backend scheduler job.
     ══════════════════════════════════════════════ */
  function _weekStartDate() {
    /* Most recent Sunday, local time — "Every Sunday" per the spec. */
    var d = new Date();
    d.setDate(d.getDate() - d.getDay());
    d.setHours(0, 0, 0, 0);
    return d;
  }
  function _dateKey(d) {
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  function renderWeeklyReview() {
    var body = $('cwBody');
    body.innerHTML = '<div class="cw-empty"><span class="cw-empty-icon">📊</span>Loading this week…</div>';
    var d = db();
    if (!d) return;

    var weekStart = _weekStartDate();
    var weekStartKey = _dateKey(weekStart);
    var weekEnd = new Date(weekStart.getTime() + 7 * 86400000);
    var docId = S.opts.athleteId + '_' + weekStartKey;

    Promise.all([
      /* coachId pinned for the same Security-Rules reason as the listeners —
         without it this whole Promise.all rejected for the coach. */
      d.collection('meal_checkins')
        .where('athleteId', '==', S.opts.athleteId)
        .where('coachId', '==', S.opts.coachId).get(),
      d.collection('workout_checkins')
        .where('athleteId', '==', S.opts.athleteId)
        .where('coachId', '==', S.opts.coachId).get(),
      d.collection('users').doc(S.opts.athleteId).collection('activity')
        .where('date', '>=', weekStartKey).where('date', '<', _dateKey(weekEnd)).get(),
      d.collection('users').doc(S.opts.athleteId).collection('weight_log')
        .orderBy('date', 'desc').limit(14).get(),
      d.collection('weekly_reviews').doc(docId).get(),
    ]).then(function (results) {
      var mealSnap = results[0], workoutSnap = results[1], activitySnap = results[2],
          weightSnap = results[3], existingSnap = results[4];

      function inWeek(iso) {
        if (!iso) return false;
        var t = new Date(iso);
        return t >= weekStart && t < weekEnd;
      }

      var meals = mealSnap.docs.map(function (x) { return x.data(); })
        .filter(function (c) { return c.coachId === S.opts.coachId && inWeek(c.timestamp); });
      var workouts = workoutSnap.docs.map(function (x) { return x.data(); })
        .filter(function (c) { return c.coachId === S.opts.coachId && inWeek(c.timestamp); });
      var activityDays = activitySnap.docs.map(function (x) { return x.data(); });

      var mealDaysActive = {};
      meals.forEach(function (c) { mealDaysActive[c.day] = true; });
      var mealsFollowedPct = Math.round((Object.keys(mealDaysActive).length / 7) * 100);

      var workoutDaysActive = {};
      workouts.forEach(function (c) { workoutDaysActive[c.day] = true; });
      activityDays.forEach(function (a) { if (a.workoutCompleted) workoutDaysActive[a.date] = true; });
      var workoutPct = Math.round((Object.keys(workoutDaysActive).length / 7) * 100);

      var sleepVals = activityDays.map(function (a) { return a.sleepHours; }).filter(function (v) { return v != null; });
      var sleepAvg = sleepVals.length ? Math.round((sleepVals.reduce(function (a,b) { return a+b; }, 0) / sleepVals.length) * 10) / 10 : null;

      var waterPcts = activityDays.filter(function (a) { return a.waterGoalMl; })
        .map(function (a) { return Math.min(100, Math.round((a.waterMl / a.waterGoalMl) * 100)); });
      var waterAvg = waterPcts.length ? Math.round(waterPcts.reduce(function (a,b) { return a+b; }, 0) / waterPcts.length) : null;

      var stepPcts = activityDays.filter(function (a) { return a.goalEffective || a.goal; })
        .map(function (a) { return Math.min(100, Math.round((a.steps / (a.goalEffective || a.goal)) * 100)); });
      var stepsAvg = stepPcts.length ? Math.round(stepPcts.reduce(function (a,b) { return a+b; }, 0) / stepPcts.length) : null;

      var weights = weightSnap.docs.map(function (x) { return x.data(); });
      var weightDelta = null;
      if (weights.length >= 2) {
        var latest = weights[0].weightKg;
        var oldest = weights[weights.length - 1].weightKg;
        weightDelta = Math.round((latest - oldest) * 10) / 10;
      }

      var existing = existingSnap.exists ? existingSnap.data() : null;

      _renderWeeklyReviewBody({
        docId: docId, weekStart: weekStart, weekEnd: new Date(weekEnd.getTime() - 86400000),
        mealsFollowedPct: mealsFollowedPct, workoutPct: workoutPct,
        sleepAvg: sleepAvg, waterAvg: waterAvg, stepsAvg: stepsAvg, weightDelta: weightDelta,
        feedback: existing ? existing.coachFeedback : '',
      });
    }).catch(function (e) {
      console.warn('[CW] weekly review load failed', e);
      body.innerHTML = '<div class="cw-empty"><span class="cw-empty-icon">⚠️</span>Could not load this week — try again.</div>';
    });
  }

  function _renderWeeklyReviewBody(w) {
    var body = $('cwBody');
    var fmtRange = w.weekStart.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) + ' – ' +
      w.weekEnd.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' });

    function stat(label, val, suffix) {
      return '<div class="cw-week-stat"><span class="cw-week-stat-label">' + esc(label) + '</span>' +
        '<span class="cw-week-stat-val">' + (val == null ? '—' : esc(val) + (suffix || '')) + '</span></div>';
    }

    var feedbackBlock = S.opts.role === 'coach'
      ? '<textarea class="cw-textarea" id="cwWeeklyFeedback" rows="4" placeholder="Write this week\'s feedback for your user…">' + esc(w.feedback || '') + '</textarea>' +
        '<div class="cw-save-bar" style="position:static;background:none;padding-top:10px">' +
          '<button class="cw-save-btn" id="cwWeeklyFeedbackSave">Save Feedback</button>' +
        '</div>'
      : (w.feedback
          ? '<p class="cw-review-sec-title">Coach Feedback</p><p class="tp-workout-comment">' + esc(w.feedback) + '</p>'
          : '<div class="cw-empty" style="padding:20px"><span class="cw-empty-icon">📝</span>Your coach hasn\'t written this week\'s feedback yet.</div>');

    body.innerHTML =
      '<p class="cw-sheet-sub" style="margin:0 0 12px">' + esc(fmtRange) + '</p>' +
      '<div class="cw-week-stats-grid">' +
        stat('Meals Followed', w.mealsFollowedPct, '%') +
        stat('Workout', w.workoutPct, '%') +
        stat('Sleep', w.sleepAvg, ' hrs') +
        stat('Water', w.waterAvg, '%') +
        stat('Steps', w.stepsAvg, '%') +
        stat('Weight', w.weightDelta == null ? null : (w.weightDelta > 0 ? '+' : '') + w.weightDelta, ' kg') +
      '</div>' +
      feedbackBlock;

    var saveBtn = $('cwWeeklyFeedbackSave');
    if (saveBtn) saveBtn.addEventListener('click', function () { _saveWeeklyFeedback(w.docId); });
  }

  function _saveWeeklyFeedback(docId) {
    var d = db();
    var textEl = $('cwWeeklyFeedback');
    if (!d || !textEl) return;
    var btn = $('cwWeeklyFeedbackSave');
    if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
    d.collection('weekly_reviews').doc(docId).set({
      athleteId: S.opts.athleteId, coachId: S.opts.coachId,
      coachFeedback: textEl.value, feedbackUpdatedAt: new Date().toISOString(),
    }, { merge: true }).then(function () {
      notify(S.opts.athleteId, '📊 Your coach shared this week\'s feedback.', 'weekly_review');
      toast('✅ Feedback saved');
    }).catch(function (e) {
      console.warn('[CW] weekly feedback save failed', e);
      toast('Save failed — try again.');
      if (btn) { btn.disabled = false; btn.textContent = 'Save Feedback'; }
    });
  }

  function renderTrainingViewer() {
    var body = $('cwBody');
    var tr = S.plan && coachPlanIsCurrent(S.plan.training) ? S.plan.training : null;
    var readonlyNote = (S.opts.role === 'coach' && !canEditTraining())
      ? '<div class="cw-readonly-note">🔒 Training is read-only on the ' + esc(S.opts.planLabel || 'current') + ' plan.</div>'
      : '';
    if (!tr || !tr.days || !tr.days.length) {
      body.innerHTML = readonlyNote +
        '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">💪</span>' +
        (S.opts.role === 'athlete'
          ? 'Your coach hasn’t published a training plan yet.<br>You’ll be notified the moment it’s ready.'
          : 'No coach training plan yet.') +
        '</div></div>';
      return;
    }
    if (S.dayIdx >= tr.days.length) S.dayIdx = 0;
    var day = tr.days[S.dayIdx];

    var content;
    if (day.rest) {
      content = '<div class="cw-card"><div class="cw-rest-day">😴 Rest & Recovery Day' +
        (day.focus ? '<br><span style="font-size:12px;font-weight:600">' + esc(day.focus) + '</span>' : '') +
        '</div></div>';
    } else {
      var exHtml = (day.exercises || []).map(function (ex, i) {
        var meta = [];
        if (ex.sets) meta.push(ex.sets + ' sets');
        if (ex.reps) meta.push(ex.reps);
        if (ex.duration) meta.push(ex.duration);
        if (ex.rest) meta.push('rest ' + ex.rest);
        return '<div class="cw-ex-row"><span class="cw-ex-num">' + (i + 1) + '</span>' +
          '<div class="cw-ex-info"><span class="cw-ex-name">' + esc(ex.name || 'Exercise') + '</span>' +
          (meta.length ? '<span class="cw-ex-meta">' + esc(meta.join(' · ')) + '</span>' : '') +
          (ex.notes ? '<span class="cw-ex-notes">' + esc(ex.notes) + '</span>' : '') +
          '</div></div>';
      }).join('');
      content = '<div class="cw-card">' +
        '<p class="cw-card-title">' + esc(day.focus || 'Training Session') +
          (day.duration ? ' <span style="font-weight:600;color:#94A3B8;font-size:11px">· ' + esc(day.duration) + ' min</span>' : '') +
        '</p>' +
        (exHtml || '<div class="cw-empty" style="padding:12px">No exercises added for this day.</div>') +
        '</div>';
    }

    body.innerHTML = readonlyNote + dayPillsHtml(tr.days, S.dayIdx) + content;
    wireDayPills(body, renderTrainingViewer);
  }

  function ensureTrainDraft() {
    var remote = S.plan && S.plan.training;
    /* Same goal-identity rule as the diet draft: stale coach plans are
       treated as absent so the coach always works against the athlete's
       CURRENT goal. */
    var hasRemote = !!(remote && remote.days && remote.days.length && coachPlanIsCurrent(remote));
    /* A saved coach plan always beats an unsaved auto-seed */
    if (S.trainDraft && S.trainDraftSeeded && !S.trainDirty && hasRemote) S.trainDraft = null;
    if (S.trainDraft) return;
    if (hasRemote) {
      S.trainDraft = JSON.parse(JSON.stringify(remote));
      S.trainDraftSeeded = false;
      return;
    }
    /* No (current) coach plan — auto-preload the athlete's AI-generated
       workout so the coach edits the real plan, never a blank template. */
    var ai = trainingFromAiPlan();
    if (ai) { S.trainDraft = ai; S.trainDraftSeeded = true; }
  }

  function renderTrainingEditor() {
    var body = $('cwBody');
    ensureTrainDraft();

    if (!S.trainDraft) {
      if (!S.planLoaded || !S.athleteLoaded) {
        body.innerHTML = '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">💪</span>Loading the user’s plan…</div></div>';
        return;
      }
      body.innerHTML =
        '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">💪</span>' +
          'This user has no AI workout plan yet (they may not have completed their assessment). ' +
          'You can still build their full week from a template — exercises, sets, reps, duration and rest.' +
        '</div>' +
        '<div class="cw-save-bar" style="position:static;background:none">' +
          '<button class="cw-save-btn" id="cwTrainBlank">Start with template</button>' +
        '</div></div>';
      $('cwTrainBlank').addEventListener('click', function () {
        S.trainDraft = emptyTrainingWeek(); S.trainDraftSeeded = false;
        S.trainDirty = true; renderTrainingEditor();
      });
      return;
    }

    if (S.dayIdx >= S.trainDraft.days.length) S.dayIdx = 0;
    var day = S.trainDraft.days[S.dayIdx];

    var exHtml = (day.exercises || []).map(function (ex, i) {
      return '<div class="cw-ed-meal">' +
        '<div class="cw-ed-meal-head">' +
          '<span class="cw-ex-num">' + (i + 1) + '</span>' +
          '<input class="cw-input" placeholder="Exercise name" value="' + esc(ex.name || '') + '" data-cw-ex="' + i + ':name">' +
          '<button class="cw-icon-btn" data-cw-ex-up="' + i + '" aria-label="Move up"' + (i === 0 ? ' disabled' : '') + '>↑</button>' +
          '<button class="cw-icon-btn" data-cw-ex-dn="' + i + '" aria-label="Move down"' + (i === day.exercises.length - 1 ? ' disabled' : '') + '>↓</button>' +
          '<button class="cw-icon-btn cw-icon-btn--danger" data-cw-ex-del="' + i + '" aria-label="Delete">✕</button>' +
        '</div>' +
        '<div class="cw-ed-row">' +
          '<input class="cw-input cw-input--sm" placeholder="Sets" value="' + esc(ex.sets || '') + '" data-cw-ex="' + i + ':sets">' +
          '<input class="cw-input cw-input--sm" placeholder="Reps" value="' + esc(ex.reps || '') + '" data-cw-ex="' + i + ':reps">' +
          '<input class="cw-input cw-input--sm" placeholder="Duration" value="' + esc(ex.duration || '') + '" data-cw-ex="' + i + ':duration">' +
          '<input class="cw-input cw-input--sm" placeholder="Rest" value="' + esc(ex.rest || '') + '" data-cw-ex="' + i + ':rest">' +
        '</div>' +
        '<div class="cw-ed-row" style="margin-bottom:0">' +
          '<input class="cw-input" placeholder="Notes / form cue" value="' + esc(ex.notes || '') + '" data-cw-ex="' + i + ':notes">' +
        '</div>' +
      '</div>';
    }).join('');

    var seededNote = (S.trainDraftSeeded && !S.trainDirty)
      ? '<div class="cw-req-banner">🤖 Preloaded from the user’s AI-generated workout plan — review, adjust anything, then Save to publish your version.</div>'
      : '';

    body.innerHTML =
      dayPillsHtml(S.trainDraft.days, S.dayIdx) +
      seededNote +
      medGuidanceBanner('workout') +
      '<div class="cw-ed-meal">' +
        '<div class="cw-ed-row" style="margin-bottom:0">' +
          '<input class="cw-input" placeholder="Day focus (e.g. Upper Body Strength)" value="' + esc(day.focus || '') + '" id="cwDayFocus">' +
          '<input class="cw-input cw-input--sm" inputmode="numeric" placeholder="Minutes" value="' + esc(day.duration || '') + '" id="cwDayDuration">' +
          '<button class="cw-ghost-btn" style="padding:9px 12px;font-size:12px;white-space:nowrap" id="cwRestToggle">' + (day.rest ? '😴 Rest day ✓' : 'Mark rest day') + '</button>' +
        '</div>' +
      '</div>' +
      (day.rest ? '<div class="cw-readonly-note">😴 Marked as a rest day — exercises below are ignored.</div>' : '') +
      exHtml +
      '<button class="cw-add-btn" id="cwAddEx">+ Add exercise</button>' +
      '<div class="cw-save-bar">' +
        '<button class="cw-ghost-btn" id="cwTrainHistory">🕘 History</button>' +
        '<span class="cw-save-status" id="cwTrainSaveStatus"></span>' +
        '<button class="cw-save-btn" id="cwTrainSave"' + ((S.trainDirty || S.trainDraftSeeded) ? '' : ' disabled') + '>' +
          ((S.trainDirty || S.trainDraftSeeded) ? 'Save Training Plan' : 'Saved ✓') + '</button>' +
      '</div>';

    wireDayPills(body, renderTrainingEditor);

    function markDirty() {
      if (!S.trainDirty) {
        S.trainDirty = true;
        var sb = $('cwTrainSave');
        if (sb) { sb.disabled = false; sb.textContent = 'Save Training Plan'; }
      }
      S.trainEditGen++;
      scheduleAutoSave('training');
    }
    $('cwDayFocus').addEventListener('input', function (e) { day.focus = e.target.value; markDirty(); });
    $('cwDayDuration').addEventListener('input', function (e) { day.duration = e.target.value; markDirty(); });
    $('cwRestToggle').addEventListener('click', function () {
      day.rest = !day.rest; markDirty(); renderTrainingEditor();
    });
    body.querySelectorAll('[data-cw-ex]').forEach(function (inp) {
      inp.addEventListener('input', function () {
        var p = inp.dataset.cwEx.split(':');
        day.exercises[+p[0]][p[1]] = inp.value;
        markDirty();
      });
    });
    body.querySelectorAll('[data-cw-ex-up]').forEach(function (b) {
      b.addEventListener('click', function () {
        var i = +b.dataset.cwExUp;
        if (i > 0) {
          var t = day.exercises[i - 1]; day.exercises[i - 1] = day.exercises[i]; day.exercises[i] = t;
          markDirty(); renderTrainingEditor();
        }
      });
    });
    body.querySelectorAll('[data-cw-ex-dn]').forEach(function (b) {
      b.addEventListener('click', function () {
        var i = +b.dataset.cwExDn;
        if (i < day.exercises.length - 1) {
          var t = day.exercises[i + 1]; day.exercises[i + 1] = day.exercises[i]; day.exercises[i] = t;
          markDirty(); renderTrainingEditor();
        }
      });
    });
    body.querySelectorAll('[data-cw-ex-del]').forEach(function (b) {
      b.addEventListener('click', function () {
        day.exercises.splice(+b.dataset.cwExDel, 1);
        markDirty(); renderTrainingEditor();
      });
    });
    $('cwAddEx').addEventListener('click', function () {
      day.exercises.push({ name: '', sets: '', reps: '', duration: '', rest: '', notes: '' });
      markDirty(); renderTrainingEditor();
    });
    $('cwTrainSave').addEventListener('click', function () { saveTraining(false); });
    $('cwTrainHistory').addEventListener('click', function () { openHistory('training'); });
  }

  function saveTraining(isAuto) {
    if (!S.trainDraft) return;
    if (!canEditTraining()) { _setSaveStatus('training', 'locked'); return; }
    if (S.saving) {
      if (isAuto) scheduleAutoSave('training');
      return;
    }
    var d = db();
    if (!d) { toast('Connection unavailable'); return; }
    S.saving = true;
    var btn = $('cwTrainSave');
    if (!isAuto && btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
    _setSaveStatus('training', 'saving');

    var now = new Date().toISOString();
    var docRef = d.collection('coaching_plans').doc(S.opts.athleteId);
    var draft = S.trainDraft;
    /* Same edit-generation guard as saveDiet() — see its comment. */
    var startGen = S.trainEditGen;

    /* Goal-identity stamp — same contract as saveDiet() */
    draft.planId = athleteCtx().planId || null;

    /* WHAT IS ACTUALLY BEING SAVED. `coaching_plans/{uid}.training` was
       reported empty in the field; these lines say whether the collector
       produced days at all, so an empty save is distinguishable from a
       failed one without guessing. */
    var _tDays = (draft && draft.days) || [];
    console.log('[CW TRAINING SAVE] athleteId=' + S.opts.athleteId +
      ' planId=' + draft.planId +
      ' dayCount=' + _tDays.length +
      ' dayKeys=' + JSON.stringify(_tDays.map(function (x) { return x && x.day; })) +
      ' withExercises=' + _tDays.filter(function (x) {
        return x && x.exercises && x.exercises.length; }).length +
      ' auto=' + !!isAuto);
    if (!_tDays.length) {
      console.warn('[CW TRAINING SAVE] the collected plan has NO days — ' +
        'saving it would blank the coach plan');
    }

    var savedVersion;
    d.runTransaction(function (tx) {
      return tx.get(docRef).then(function (snap) {
        var cur = snap.exists ? snap.data() : {};
        savedVersion = (cur.trainingVersion || 0) + 1;
        tx.set(docRef, {
          athleteId: S.opts.athleteId, athleteName: S.opts.athleteName || 'Athlete',
          coachId: S.opts.coachId, coachName: S.opts.coachName || 'Coach',
          planType: S.opts.planType || 'complete',
          training: draft, trainingUpdatedAt: now, trainingVersion: savedVersion,
        }, { merge: true });
      });
    }).then(function () {
      return docRef.collection('versions').doc('training_' + Date.now()).set({
        type: 'training', data: draft, version: savedVersion,
        savedAt: now, savedBy: S.opts.coachName || 'Coach',
      });
    }).then(function () {
      notify(S.opts.athleteId, '💪 ' + (S.opts.coachName || 'Your coach') + ' updated your workout plan.', 'training_update');
      var stillCurrent = S.trainEditGen === startGen;
      if (stillCurrent) { S.trainDirty = false; S.trainDraftSeeded = false; }
      S.saving = false;
      console.log('[CW] training saved v' + savedVersion + (isAuto ? ' (auto)' : '') +
        (stillCurrent ? '' : ' (newer edits pending)'));
      if (stillCurrent) _setSaveStatus('training', 'saved');
      if (isAuto) {
        if (stillCurrent && btn) { btn.disabled = true; btn.textContent = 'Saved ✓'; }
      } else {
        toast('✅ Training plan published to ' + (S.opts.athleteName || 'the athlete'));
        renderTrainingEditor();
      }
    }).catch(function (e) {
      S.saving = false;
      console.error('[CW] training save failed', e);
      _setSaveStatus('training', 'error');
      if (isAuto) {
        if (canEditTraining()) scheduleAutoSave('training');
      } else {
        toast('Save failed — please try again.');
        if (btn) { btn.disabled = false; btn.textContent = 'Save Training Plan'; }
      }
    });
  }

  /* ══════════════════════════════════════════════
     VERSION HISTORY (diet + training)
  ══════════════════════════════════════════════ */
  function openHistory(type) {
    var d = db();
    if (!d) return;
    openSheet('<p class="cw-sheet-title">🕘 ' + (type === 'diet' ? 'Diet' : 'Training') + ' Versions</p>' +
      '<p class="cw-sheet-sub">Loading…</p>');
    d.collection('coaching_plans').doc(S.opts.athleteId).collection('versions')
      .where('type', '==', type).get()
      .then(function (snap) {
        var vers = snap.docs.map(function (x) { return x.data(); })
          .sort(function (a, b) { return (b.savedAt || '') < (a.savedAt || '') ? -1 : 1; });
        var canRestore = type === 'diet' ? canEditDiet() : canEditTraining();
        var rows = vers.length ? vers.map(function (v, i) {
          return '<div class="cw-ver-row">' +
            '<div class="cw-ver-info">' +
              '<span class="cw-ver-date">v' + esc(String(v.version || '?')) + ' · ' + esc(fmtDate(v.savedAt)) + ' ' + esc(fmtTime(v.savedAt)) + '</span>' +
              '<span class="cw-ver-by">by ' + esc(v.savedBy || 'Coach') + '</span>' +
            '</div>' +
            (canRestore && i > 0 ? '<button class="cw-ver-restore" data-cw-restore="' + i + '">Restore</button>' : '') +
            (i === 0 ? '<span class="cw-opt-count">current</span>' : '') +
            '</div>';
        }).join('') : '<p class="cw-sheet-sub">No saved versions yet — every save creates one.</p>';
        openSheet('<p class="cw-sheet-title">🕘 ' + (type === 'diet' ? 'Diet' : 'Training') + ' Versions</p>' +
          '<p class="cw-sheet-sub">Every coach save is snapshotted. Restoring loads that version into the editor — save to publish it.</p>' + rows);
        $('cwSheet').querySelectorAll('[data-cw-restore]').forEach(function (b) {
          b.addEventListener('click', function () {
            var v = vers[+b.dataset.cwRestore];
            if (!v || !v.data) return;
            if (type === 'diet') { S.dietDraft = JSON.parse(JSON.stringify(v.data)); S.dietDirty = true; }
            else { S.trainDraft = JSON.parse(JSON.stringify(v.data)); S.trainDirty = true; }
            closeSheet();
            toast('Version v' + (v.version || '?') + ' loaded — press Save to publish.');
            renderTab();
          });
        });
      })
      .catch(function (e) {
        console.warn('[CW] history load failed', e);
        openSheet('<p class="cw-sheet-title">🕘 Versions</p><p class="cw-sheet-sub">Could not load history — try again.</p>');
      });
  }

  /* ══════════════════════════════════════════════
     MEAL REVIEWS TAB — Daily Meal Compliance
     meal_checkins/{id}: athlete submits a photo per meal (from the Diet
     page's 📸 Send Meal to Coach button); the coach reacts + scores (1-10,
     required) + optionally comments. Coach sees a review queue; athlete
     sees their submission history read-only. Today's coverage strip and
     the score total are both computed live from real submissions —
     nothing here is fabricated when data is missing.
  ══════════════════════════════════════════════ */
  function _todayName() {
    return ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'][new Date().getDay()];
  }

  /* MODULE SCOPE, deliberately. Both of these used to sit INSIDE
     renderCheckins(). card() is nested there too so the meal LIST
     rendered fine — but openSheet(), openCheckinHistorySheet() and
     renderCheckinReviewSheet() live at module scope and could not see
     them, so opening any meal threw
     `Uncaught ReferenceError: _cwPhotoMarkup is not defined` and the
     sheet never rendered. The indentation hid it: the enclosing
     function had not closed where it appeared to. */
  /* A meal photo that cannot load must say so, not render a broken-image
     glyph the coach has to interpret.

     WHY THIS HAPPENS AT ALL: Firebase Storage was never provisioned for this
     project (zero buckets), so every photo upload silently fell back to
     `POST /api/chat/upload`, which writes to the container's EPHEMERAL disk.
     Those files vanish on the next deploy, leaving `meal_checkins.imageUrl`
     pointing at a permanent 404. This handler does not fix that — provisioning
     the bucket does — it just stops the coach seeing a broken icon with no
     explanation. A photo whose URL still resolves is untouched and still
     renders normally.

     Kept as a data-attribute + delegated listener rather than an inline
     onerror so nothing has to be interpolated into markup. */
  function _cwWireImageFallbacks(root) {
    (root || document).querySelectorAll('img[data-cw-photo]').forEach(function (img) {
      if (img._cwWired) return;
      img._cwWired = true;
      img.addEventListener('error', function () {
        var note = document.createElement('div');
        /* Keep the image's OWN size class (cw-review-thumb in the list,
           cw-review-img-lg in the sheet) — hardcoding the thumb class here
           shrank the enlarged view down to list-thumbnail size. */
        note.className = (img.className || 'cw-review-thumb') + ' cw-review-thumb--missing';
        note.setAttribute('role', 'img');
        note.setAttribute('aria-label', 'Meal photo unavailable');
        note.textContent = '🖼';
        note.title = 'Photo unavailable — it was not stored permanently.';
        if (img.parentNode) img.parentNode.replaceChild(note, img);
      });
    });
  }

  /* THREE DISTINCT STATES, never conflated:
       a URL that loads      -> the photo
       a URL that 404s       -> "Photo unavailable" (above) — the athlete DID
                                submit one; it was lost to ephemeral storage
       no URL at all         -> "No photo submitted" (here)
     Rendering `src=""` for the third case made it fire the error handler and
     report a lost photo where none was ever sent. */
  function _cwPhotoMarkup(url, cls, alt) {
    if (!url || !String(url).trim()) {
      return '<div class="' + cls + ' cw-review-thumb--empty" role="img" ' +
        'aria-label="No photo submitted" title="No photo submitted">' +
        'No photo submitted</div>';
    }
    return '<img class="' + cls + '" data-cw-photo src="' + esc(url) +
      '" alt="' + esc(alt || 'meal') + '">';
  }

  function renderCheckins() {
    var body = $('cwBody');
    var today = _todayName();
    var todays = S.checkins.filter(function (c) { return c.day === today; });
    var earlier = S.checkins.filter(function (c) { return c.day !== today; });

    var coverage = '<div class="cw-coverage-row">' + DEFAULT_MEAL_TYPES.map(function (mt) {
      var has = todays.some(function (c) { return c.mealType === mt; });
      return '<div class="cw-coverage-chip ' + (has ? 'done' : 'missing') + '">' +
        (has ? '✅' : '❌') + ' ' + cap(mt) + '</div>';
    }).join('') + '</div>';

    var reviewedToday = todays.filter(function (c) { return c.status === 'reviewed' && c.score != null; });
    var scoreLine = '';
    if (reviewedToday.length) {
      var sum = reviewedToday.reduce(function (s, c) { return s + c.score; }, 0);
      var max = reviewedToday.length * 10;
      scoreLine = '<div class="cw-daily-score"><span>Today’s Meal Score</span><b>' +
        sum + '/' + max + ' · ' + Math.round((sum / max) * 100) + '%</b></div>';
    }

    /* Compliance stats — computed from REAL reviewed check-ins only.
       Rendered only once at least one review exists (never a fake 0). */
    var reviewed = S.checkins.filter(function (c) { return c.status === 'reviewed' && c.score != null; });
    var statsRow = '';
    if (reviewed.length) {
      var all = reviewed.map(function (c) { return c.score; });
      var avg = all.reduce(function (s, v) { return s + v; }, 0) / all.length;
      var weekAgo = Date.now() - 7 * 86400000;
      var week = reviewed.filter(function (c) { return new Date(c.timestamp) >= weekAgo; })
        .map(function (c) { return c.score; });
      var weekAvg = week.length ? week.reduce(function (s, v) { return s + v; }, 0) / week.length : null;
      /* Submission streak: consecutive calendar days (ending today) with ≥1 check-in */
      var daySet = {};
      S.checkins.forEach(function (c) {
        if (c.timestamp) daySet[new Date(c.timestamp).toDateString()] = true;
      });
      var streak = 0;
      for (var di = 0; ; di++) {
        var d0 = new Date(); d0.setDate(d0.getDate() - di);
        if (daySet[d0.toDateString()]) streak++;
        else if (di === 0) continue; /* today may not be submitted yet */
        else break;
      }
      statsRow = '<div class="cw-stats-row">' +
        '<div class="cw-stat-chip"><b>' + (Math.round(avg * 10) / 10) + '/10</b><span>Avg Score</span></div>' +
        '<div class="cw-stat-chip"><b>' + (weekAvg !== null ? Math.round(weekAvg * 10) + '%' : '—') + '</b><span>Weekly Score</span></div>' +
        '<div class="cw-stat-chip"><b>' + (streak ? '🔥 ' + streak + 'd' : '—') + '</b><span>Check-in Streak</span></div>' +
        '<div class="cw-stat-chip"><b>' + Math.max.apply(null, all) + '</b><span>Highest</span></div>' +
        '<div class="cw-stat-chip"><b>' + Math.min.apply(null, all) + '</b><span>Lowest</span></div>' +
        '<div class="cw-stat-chip"><b>' + reviewed.length + '</b><span>Reviewed</span></div>' +
        '</div>';
    }



    function card(c) {
      var rated = _cwIsRated(c);
      var overall = _cwExistingOverall(c);
      var statusCls = rated ? 'cw-review-status--done' : 'cw-review-status--pending';
      /* The real value, never a placeholder. One decimal so a future
         half-star average still reads correctly. */
      var statusTxt = rated ? ('Rated ' + overall.toFixed(1) + '★') : 'Pending';

      /* The expert always gets an explicit call to action; the athlete sees
         the verdict, not a button to rate their own meal. */
      var cta = S.opts.role === 'coach'
        ? '<button type="button" class="cw-rate-cta' + (rated ? ' cw-rate-cta--edit' : '') + '" ' +
            'data-cw-rate="' + esc(c.checkinId) + '">' +
            (rated ? 'Edit Rating' : '⭐ Rate Meal') +
          '</button>'
        : '';

      return '<div class="cw-review-card" data-cw-review="' + esc(c.checkinId) + '">' +
        _cwPhotoMarkup(c.imageUrl, 'cw-review-thumb', c.mealName) +
        '<div class="cw-review-info">' +
          '<span class="cw-review-title">' + esc(cap(c.mealType)) + ' — ' + esc(c.mealName || '') + '</span>' +
          '<span class="cw-review-sub">' + esc(c.day) + ' · ' + esc(fmtTime(c.timestamp)) +
            (S.opts.role === 'coach' ? '' : (c.reaction ? ' · ' + esc(REACTION_LABEL[c.reaction] || '') : '')) +
          '</span>' +
          cta +
        '</div>' +
        '<span class="cw-review-status ' + statusCls + '">' + esc(statusTxt) + '</span>' +
      '</div>';
    }

    if (!S.checkins.length) {
      body.innerHTML = coverage +
        '<div class="cw-card"><div class="cw-empty"><span class="cw-empty-icon">🍽️</span>' +
        (S.opts.role === 'coach'
          ? 'No meal check-ins yet. They’ll appear here the moment the user sends one from their Diet page.'
          : 'Send a meal photo from your Diet page to get your coach’s feedback here.') +
        '</div></div>';
      return;
    }

    body.innerHTML = coverage + statsRow + scoreLine +
      (todays.length ? '<p class="cw-review-sec-title">Today</p>' + todays.map(card).join('') : '') +
      (earlier.length ? '<p class="cw-review-sec-title">Earlier</p>' + earlier.map(card).join('') : '');

    _cwWireImageFallbacks(body);

    body.querySelectorAll('[data-cw-review]').forEach(function (el) {
      el.addEventListener('click', function () {
        var c = S.checkins.find(function (x) { return x.checkinId === el.dataset.cwReview; });
        if (c) openCheckinSheet(c);
      });
    });

    /* The Rate/Edit button opens the same sheet. stopPropagation so the card's
       own handler does not also fire — one tap must open one sheet. */
    body.querySelectorAll('[data-cw-rate]').forEach(function (btn) {
      btn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        var c = S.checkins.find(function (x) { return x.checkinId === btn.dataset.cwRate; });
        if (c) openCheckinReviewSheet(c);
      });
    });
  }

  /* Opens the one meal a notification pointed at, once its data has loaded.

     Deliberately driven off the snapshot rather than called from open():
     S.checkins is empty at open() time, so looking the meal up there always
     failed and the user landed on the list. Clearing S.pendingCheckinId
     BEFORE opening makes this strictly one-shot — a later snapshot (a rating
     saved, a new meal arriving) must not yank the sheet open again.

     A meal that is not in the list is not an error: the id may be stale, or
     belong to a relationship that has since ended. The user simply stays on
     the Meal Reviews tab, which is where they wanted to be anyway. */
  function _cwOpenPendingCheckin() {
    var wanted = S.pendingCheckinId;
    if (!wanted) return;

    /* An EMPTY list is not an answer. A fresh onSnapshot listener can deliver
       a cached, empty result before the server's, and giving up on that first
       firing would clear the id moments before the real data arrives — the
       meal would then never open, which is the exact failure this whole
       mechanism exists to avoid. Keep holding; the next snapshot decides. */
    if (!S.checkins.length) return;

    var c = S.checkins.find(function (x) { return x.checkinId === wanted; });
    if (!c) {
      /* The list is populated and the meal is not in it: a stale id, or a
         relationship that has since ended. Not an error — the user stays on
         the Meal Reviews tab, which is where they were headed anyway. */
      console.log('[CW] pending meal ' + wanted + ' not in this list — staying on the tab');
      S.pendingCheckinId = null;
      return;
    }
    /* Cleared BEFORE opening, so a sheet that throws cannot leave the id set
       and retry on every future snapshot. */
    S.pendingCheckinId = null;
    console.log('[CW] opening meal review from notification mealId=' + wanted);
    openCheckinSheet(c);
  }

  function openCheckinSheet(c) {
    if (S.opts.role === 'coach') openCheckinReviewSheet(c);
    else openCheckinHistorySheet(c);
  }

  /* Athlete: read-only — see the photo + coach's reaction/score/comment */
  function openCheckinHistorySheet(c) {
    var body =
      '<p class="cw-sheet-title">' + esc(cap(c.mealType)) + ' — ' + esc(c.day) + '</p>' +
      _cwPhotoMarkup(c.imageUrl, 'cw-review-img-lg', c.mealName) +
      (c.status === 'reviewed'
        ? '<div class="pc-checkin-feedback">' +
            '<span class="pc-checkin-reaction">' + esc(REACTION_LABEL[c.reaction] || 'Reviewed') + '</span>' +
            (c.score != null ? '<span class="pc-checkin-score">' + esc(c.score) + '/10</span>' : '') +
            (c.comment ? '<p class="pc-checkin-comment">' + esc(c.comment) + '</p>' : '') +
          '</div>'
        : '<div class="pc-checkin-pending">⏳ Waiting for your coach’s review</div>');
    openSheet(body);
  }

  /* ══════════════════════════════════════════════
     EXPERT MEAL RATING
     Overall (required, 1-5 stars) + three optional dimensions + comment.

     `reaction` and `score` are STILL WRITTEN, derived from Overall. They are
     not legacy baggage: meal_compliance.dart scores adherence purely off
     `reaction.isCompliant`, and this file's own "Avg Score" chip reads
     `score` on a 1-10 scale. Dropping either would silently break compliance
     maths and the stats row for every meal rated from here.
  ══════════════════════════════════════════════ */

  /* Overall 1-5 -> the reaction ids compliance already understands. */
  var STARS_TO_REACTION = {
    5: 'perfect', 4: 'great', 3: 'good',
    2: 'needs_improvement', 1: 'not_recommended',
  };

  var RATING_DIMENSIONS = [
    { key: 'overallRating',      label: 'Overall',            required: true  },
    { key: 'tasteRating',        label: 'Taste',              required: false },
    { key: 'presentationRating', label: 'Presentation',       required: false },
    { key: 'nutritionRating',    label: 'Nutrition / Quality', required: false },
  ];

  /* The rating an expert has already given, if any. Older records predate the
     star fields and only carry `score` (1-10), so fall back to that rather
     than showing a rated meal as unrated. */
  function _cwExistingOverall(c) {
    if (typeof c.overallRating === 'number') return c.overallRating;
    if (typeof c.score === 'number') return Math.max(1, Math.min(5, Math.round(c.score / 2)));
    return null;
  }
  function _cwIsRated(c) {
    return c.status === 'reviewed' && _cwExistingOverall(c) !== null;
  }

  function openCheckinReviewSheet(c) {
    S.reviewDraft = {
      overallRating:      _cwExistingOverall(c),
      tasteRating:        typeof c.tasteRating === 'number' ? c.tasteRating : null,
      presentationRating: typeof c.presentationRating === 'number' ? c.presentationRating : null,
      nutritionRating:    typeof c.nutritionRating === 'number' ? c.nutritionRating : null,
      comment:            c.comment || '',
      /* Editing an ALREADY-reviewed meal must not fire a second "your meal
         was rated" push. See saveCheckinReview. */
      isEdit:             _cwIsRated(c),
    };
    renderCheckinReviewSheet(c);
  }

  /* One row of five stars. Buttons, not spans: they must be reachable by
     keyboard and give Android a real 44px touch target. */
  function _cwStarRow(dim, value) {
    var stars = '';
    for (var n = 1; n <= 5; n++) {
      stars +=
        '<button type="button" class="cw-star' + (value >= n ? ' cw-star--on' : '') + '" ' +
          'data-cw-star="' + dim.key + '" data-cw-star-value="' + n + '" ' +
          'aria-label="' + esc(dim.label) + ': ' + n + ' of 5" ' +
          'aria-pressed="' + (value === n ? 'true' : 'false') + '">★</button>';
    }
    return '<div class="cw-rate-row">' +
      '<span class="cw-score-label">' + esc(dim.label) +
        (dim.required ? ' <b class="cw-req">(required)</b>' : ' <span class="cw-opt">(optional)</span>') +
      '</span>' +
      '<div class="cw-star-row">' + stars +
        (value ? '<button type="button" class="cw-star-clear" data-cw-star-clear="' + dim.key +
                 '" aria-label="Clear ' + esc(dim.label) + '">Clear</button>' : '') +
      '</div></div>';
  }

  function renderCheckinReviewSheet(c) {
    var d = S.reviewDraft;
    openSheet(
      '<p class="cw-sheet-title">' + esc(cap(c.mealType)) + ' — ' + esc(c.athleteName || 'Athlete') + '</p>' +
      '<p class="cw-sheet-sub">' + esc(c.day) + ' · ' + esc(fmtTime(c.timestamp)) + '</p>' +
      _cwPhotoMarkup(c.imageUrl, 'cw-review-img-lg', c.mealName) +
      RATING_DIMENSIONS.map(function (dim) {
        return _cwStarRow(dim, d[dim.key]);
      }).join('') +
      '<textarea class="cw-textarea" id="cwReviewComment" rows="3" ' +
        'placeholder="Feedback for ' + esc(c.athleteName || 'the athlete') + ' (optional)">' +
        esc(d.comment || '') + '</textarea>' +
      '<div class="cw-save-bar" style="position:static;background:none;padding-top:12px">' +
        '<button class="cw-cancel-btn" id="cwReviewCancel" type="button">Cancel</button>' +
        '<button class="cw-save-btn" id="cwReviewSave"' + (!d.overallRating ? ' disabled' : '') + '>' +
          (d.isEdit ? 'Update Rating' : 'Submit Rating') + '</button>' +
      '</div>'
    );
    var sheet = $('cwSheet');
    sheet.querySelectorAll('[data-cw-star]').forEach(function (b) {
      b.addEventListener('click', function () {
        S.reviewDraft[b.dataset.cwStar] = parseInt(b.dataset.cwStarValue, 10);
        renderCheckinReviewSheet(c);
      });
    });
    sheet.querySelectorAll('[data-cw-star-clear]').forEach(function (b) {
      b.addEventListener('click', function () {
        /* Overall is required, so clearing it just disables Save rather than
           being forbidden — the expert can still change their mind. */
        S.reviewDraft[b.dataset.cwStarClear] = null;
        renderCheckinReviewSheet(c);
      });
    });
    var commentEl = $('cwReviewComment');
    if (commentEl) commentEl.addEventListener('input', function () { S.reviewDraft.comment = commentEl.value; });
    var cancelBtn = $('cwReviewCancel');
    if (cancelBtn) cancelBtn.addEventListener('click', function () { S.reviewDraft = null; closeSheet(); });
    var saveBtn = $('cwReviewSave');
    if (saveBtn) saveBtn.addEventListener('click', function () { saveCheckinReview(c); });
  }

  function saveCheckinReview(c) {
    var d = db();
    var draft = S.reviewDraft;
    /* Overall is the ONLY required dimension. */
    if (!d || !draft || !draft.overallRating) return;

    var btn = $('cwReviewSave');
    var wasEdit = !!draft.isEdit;
    if (btn) { btn.disabled = true; btn.textContent = wasEdit ? 'Updating…' : 'Saving…'; }

    var now = new Date().toISOString();
    var overall = draft.overallRating;
    var payload = {
      status: 'reviewed',
      /* Derived, and deliberately still written — see the block comment above
         RATING_DIMENSIONS. reaction drives compliance; score drives the
         "Avg Score" chip on a 1-10 scale, so a 5-star meal is 10/10. */
      reaction: STARS_TO_REACTION[overall],
      score: overall * 2,
      overallRating: overall,
      tasteRating: draft.tasteRating || null,
      presentationRating: draft.presentationRating || null,
      nutritionRating: draft.nutritionRating || null,
      comment: (draft.comment || '').trim() || null,
      reviewedAt: now,
      reviewedBy: myName() || 'Coach',
    };

    console.log('[MEAL_RATING_SAVE] mealId=' + c.checkinId +
      ' athleteId=' + c.athleteId +
      ' overall=' + overall + ' taste=' + payload.tasteRating +
      ' presentation=' + payload.presentationRating +
      ' nutrition=' + payload.nutritionRating +
      ' isEdit=' + wasEdit);

    d.collection('meal_checkins').doc(c.checkinId).update(payload).then(function () {
      console.log('[MEAL_RATING_SAVE] persisted mealId=' + c.checkinId);

      /* NOTIFY ONLY ON THE FIRST RATING. Editing must not spam the athlete —
         the rating they already saw simply changes in place. A retry of the
         same submit is covered by the same flag, because the document is
         `reviewed` by then and the sheet reopens in edit mode. */
      if (!wasEdit) {
        notify(c.athleteId,
          '⭐ ' + (payload.reviewedBy) + ' rated your ' + cap(c.mealType) + ' ' + overall + '⭐',
          'meal_reviewed');
        /* Push, so it lands on the lock screen with the app closed. The
           backend re-reads the check-in, verifies this caller is its coach,
           and derives the athlete from the document — the client never says
           who to notify. */
        if (typeof ZitlasNotify !== 'undefined' && ZitlasNotify.pushMealReview) {
          ZitlasNotify.pushMealReview(c.checkinId);
        }
      } else {
        console.log('[MEAL_RATING_SAVE] edit — notification deliberately suppressed');
      }

      S.reviewDraft = null;
      closeSheet();
      toast(wasEdit
        ? '✅ Rating updated'
        : '✅ Rated ' + overall + '⭐ — sent to ' + (c.athleteName || 'the athlete'));
    }).catch(function (e) {
      console.error('[MEAL_RATING_SAVE] FAILED mealId=' + c.checkinId, e);
      toast('Could not save the rating — try again.');
      if (btn) {
        btn.disabled = false;
        btn.textContent = wasEdit ? 'Update Rating' : 'Submit Rating';
      }
    });
  }

  /* ══════════════════════════════════════════════
     CHAT TAB — same chat_rooms collection as normal chat
  ══════════════════════════════════════════════ */
  function renderChatShell() {
    var body = $('cwBody');
    var locked = S.opts.status !== 'active';

    /* Coach-side pinned athlete summary — always visible above the thread */
    var pin = '';
    if (S.opts.role === 'coach') {
      var med = medInfo();
      var ctx = athleteCtx();
      var a2 = ctx.assessment || ctx.survey || {};
      var c2 = ctx.calculations || {};
      var g2 = ctx.goal || {};
      var bits = [];
      bits.push(med.has
        ? '🏥 <b>' + esc(med.meta.map(function (m) { return m.label; }).join(', ') || med.raw) + '</b>'
        : '🟢 No medical conditions reported.');
      if (g2.type) bits.push(esc(cap(g2.type)) + ' goal');
      if (c2.bmi) bits.push('BMI ' + esc(parseFloat(c2.bmi).toFixed(1)));
      if (a2.living_situation) bits.push(esc(cap(a2.living_situation)));
      pin = '<div class="cw-chat-pin">📌 <b>User Summary</b> — ' + bits.join(' · ') + '</div>';
    }

    body.innerHTML =
      pin +
      '<div class="cw-chat-msgs" id="cwChatMsgs"></div>' +
      (locked
        ? '<div class="cw-chat-locked">🔒 Personal Coaching Ended</div>'
        : '<div class="cw-chat-bar">' +
            '<button class="cw-chat-attach" id="cwAttach" aria-label="Attach image">' +
              '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66L9.41 16.73a2 2 0 0 1-2.83-2.83l7.07-7.07"/></svg>' +
            '</button>' +
            '<input type="file" id="cwFile" accept="image/jpeg,image/png,image/webp" style="display:none">' +
            '<textarea class="cw-chat-input" id="cwChatInput" rows="1" placeholder="Message…"></textarea>' +
            '<button class="cw-chat-send" id="cwSend" aria-label="Send">' +
              '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>' +
            '</button>' +
          '</div>');
    renderChatMsgs();

    if (locked) return;
    $('cwSend').addEventListener('click', sendChat);
    $('cwChatInput').addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
    });
    var attach = $('cwAttach'), file = $('cwFile');
    if (typeof ZitlasChatAttach === 'undefined') {
      attach.style.display = 'none';
    } else {
      attach.addEventListener('click', function () { file.click(); });
      file.addEventListener('change', function () {
        var f = file.files && file.files[0];
        file.value = '';
        if (!f) return;
        ZitlasChatAttach.upload(f)
          .then(function (url) { sendChatMessage('', url); })
          .catch(function (e) { toast(e && e.message ? e.message : 'Image upload failed.'); });
      });
    }
  }

  function renderChatMsgs() {
    var wrap = $('cwChatMsgs');
    if (!wrap) return;
    var mySender = S.opts.role === 'coach' ? 'expert' : 'athlete';
    wrap.innerHTML = S.chatMsgs.length ? S.chatMsgs.map(function (m) {
      var mine = m.senderType === mySender;
      return '<div class="cw-bubble ' + (mine ? 'cw-bubble--me' : 'cw-bubble--them') + '">' +
        (m.imageUrl ? '<img src="' + esc(m.imageUrl) + '" alt="attachment" data-cw-img="' + esc(m.imageUrl) + '">' : '') +
        (m.text ? esc(m.text) : '') +
        '<span class="cw-bubble-ts">' + esc(fmtTime(m.timestamp)) + '</span>' +
        '</div>';
    }).join('') : '<div class="cw-empty"><span class="cw-empty-icon">💬</span>Unlimited coaching chat — say hello!</div>';
    wrap.querySelectorAll('[data-cw-img]').forEach(function (img) {
      img.addEventListener('click', function () {
        if (typeof ZitlasChatAttach !== 'undefined' && ZitlasChatAttach.openViewer) {
          ZitlasChatAttach.openViewer(img.dataset.cwImg);
        }
      });
    });
    wrap.scrollTop = wrap.scrollHeight;
  }

  function sendChat() {
    var input = $('cwChatInput');
    var text = (input && input.value || '').trim();
    if (!text) return;
    input.value = '';
    sendChatMessage(text, null);
  }

  /* Same message + room-doc shape the normal chat writes, so both existing
     chat surfaces receive workspace messages (and vice versa). */
  function sendChatMessage(text, imageUrl) {
    var d = db();
    if (!d) { toast('Connection unavailable'); return; }
    var msg = {
      id: newId('msg'),
      conversationId: chatId(),
      senderId: myUid(),
      senderType: S.opts.role === 'coach' ? 'expert' : 'athlete',
      text: text || '',
      type: imageUrl ? 'image' : 'text',
      imageUrl: imageUrl || null,
      timestamp: new Date().toISOString(),
    };
    var roomDoc = {
      participants: [S.opts.athleteId, S.opts.coachId],
      athleteId: S.opts.athleteId, athleteName: S.opts.athleteName || 'Athlete',
      expertId: S.opts.coachId, expertName: S.opts.coachName || 'Coach',
      lastMessage: text || '📷 Photo',
      lastMessageAt: msg.timestamp,
    };
    d.collection('chat_rooms').doc(chatId()).set(roomDoc, { merge: true })
      .then(function () {
        return d.collection('chat_rooms').doc(chatId()).collection('messages').doc(msg.id).set(msg);
      })
      .then(function () {
        notify(otherUid(), '💬 New message from ' + (myName() || 'your coaching partner') + '.', 'chat');
        // Real FCM push so the message reaches a backgrounded/closed app and a
        // locked phone — notify() above only writes the in-app document. The
        // backend derives the recipient from the chat room itself.
        if (typeof ZitlasNotify !== 'undefined' && ZitlasNotify.pushChat) {
          ZitlasNotify.pushChat(chatId(), text || '📷 Photo');
        }
      })
      .catch(function (e) { console.error('[CW] chat send failed', e); toast('Message failed to send.'); });
  }

  /* ══════════════════════════════════════════════
     EXPORT
  ══════════════════════════════════════════════ */
  /* ══════════════════════════════════════════════
     ANDROID BACK — the level the app could not see
     ══════════════════════════════════════════════
     The coaching workspace navigates ENTIRELY inside one HTML page: opening
     an athlete, switching tab and opening a meal sheet are JS state, and
     expert-dashboard.js deliberately uses history.replaceState (never
     pushState) so tab clicks do not pollute history.

     So the WebView has NO history entries for any of it: canGoBack() is
     false and the path never changes. The Flutter host therefore saw "no
     history, at root" and treated ONE back press as "leave the coaching
     surface" — from a meal sheet, Back closed the entire expert section.

     `ZitlasBack.handle()` gives the host the missing step. It returns the
     level it consumed, or 'none' when the page genuinely has nothing left to
     unwind, at which point the host falls through to WebView history, then
     to the Flutter route stack. Deepest level first, one per press. */
  win.ZitlasBack = win.ZitlasBack || {
    _handlers: [],
    /* Later registrations are asked FIRST, so a page layered on top of the
       workspace unwinds before the workspace does. */
    register: function (fn) { this._handlers.push(fn); },
    handle: function () {
      for (var i = this._handlers.length - 1; i >= 0; i--) {
        try {
          var consumed = this._handlers[i]();
          if (consumed && consumed !== 'none') return String(consumed);
        } catch (e) {
          /* A throwing handler must not trap the user on the screen. */
          if (win.console) console.warn('[BACK] handler failed', e);
        }
      }
      return 'none';
    },
  };

  win.ZitlasBack.register(function () {
    /* 1. A sheet is the deepest level — meal review, versions, swap, ask. */
    var bd = document.getElementById('cwSheetBackdrop');
    if (bd && bd.classList.contains('open')) {
      closeSheet();
      return 'sheet';
    }
    /* 2. Then the workspace itself, back to the roster underneath. */
    if (S.open) {
      close();
      return 'workspace';
    }
    return 'none';
  });

  win.ZitlasCoachingWorkspace = {
    open: open,
    close: close,
    attachNotifications: attachNotifications,
    isOpen: function () { return S.open; },
  };
})(window);
