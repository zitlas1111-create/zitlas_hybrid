/* =============================================
   ZITLAS — Weekly Training Plan
   weekly-plan.js

   Reads `zitlas_roadmap` from localStorage and
   renders the full 7-day plan overview page.
   No survey or API calls — pure read + render.
   ============================================= */

(function () {
  'use strict';

  /* ══════════════════════════════════════════
     DAY ACCENT COLOURS
     One colour per day (Mon→Sun). Used only for
     the left accent bar on each day card.
     No hardcoded labels — themes come from the plan.
  ══════════════════════════════════════════ */
  const DAY_COLORS = [
    'var(--success)', /* Day 1 */
    'var(--ai-accent)', /* Day 2 */
    'var(--primary)', /* Day 3 */
    'var(--primary)', /* Day 4 */
    'var(--primary-dark)', /* Day 5 */
    'var(--ai-accent)', /* Day 6 */
    'var(--ai-accent)', /* Day 7 - Recovery */
  ];

  /* Short day-name abbreviations */
  const DAY_SHORT = { Monday:'MON', Tuesday:'TUE', Wednesday:'WED',
                      Thursday:'THU', Friday:'FRI', Saturday:'SAT', Sunday:'SUN' };

  /* ══════════════════════════════════════════
     BOOT
  ══════════════════════════════════════════ */
  function init() {
    /* If a previous run replaced the whole page with the "No Plan Found"
       error state (showError() overwrites #wpPage's innerHTML, destroying
       #wpContent/#wpLoading), and this run — e.g. triggered by a remote
       cloud-sync event once a plan now exists on another device — needs
       to render, restore the original skeleton first so render()'s
       el('wpContent') etc. lookups don't hit null. */
    if (!el('wpContent') && showError._savedHtml) {
      el('wpPage').innerHTML = showError._savedHtml;
    }

    var _nb = document.getElementById('zitlas-navbar');
    if (_nb) document.documentElement.style.setProperty('--nav-height', (window.innerHeight - _nb.getBoundingClientRect().top) + 'px');

    /* Personal Coaching: when an active coach relationship with training
       permission has published a plan, it overrides the AI plan the moment
       its realtime snapshot arrives. */
    initCoachTrainingMode();

    const plan = loadPlan();
    if (!plan || !plan.days || !plan.days.length) {
      if (!_pcActive) showError();
      return;
    }
    if (!_pcActive) render(plan);
  }

  /* ══════════════════════════════════════════
     PERSONAL COACHING MODE
     coaching_plans/{uid}.training → converted into the same shape the AI
     plan uses and fed through the existing transformWorkoutPlan/render
     pipeline. Inert when Firebase isn't loaded or no relationship exists.
  ══════════════════════════════════════════ */
  var _pcRel = null, _pcPlanDoc = null, _pcActive = false;

  function _pcUid() {
    try {
      var fb = JSON.parse(localStorage.getItem('zitlas_firebase_user') || 'null');
      return fb && fb.uid;
    } catch (_) { return null; }
  }
  function _pcShowsCoachPlan() {
    return !!(_pcRel && _pcRel.status === 'active' &&
      (_pcRel.planType === 'training' || _pcRel.planType === 'complete'));
  }

  function initCoachTrainingMode() {
    if (typeof ZitlasDB === 'undefined') return;
    var uid = _pcUid();
    if (!uid) return;
    ZitlasDB.collection('personal_coaching').doc(uid).onSnapshot(function (snap) {
      _pcRel = snap.exists ? snap.data() : null;
      console.log('[WP COACH] relationship:', _pcRel ? _pcRel.status + '/' + _pcRel.planType : 'none');
      if (_pcShowsCoachPlan() && !initCoachTrainingMode._planAttached) {
        initCoachTrainingMode._planAttached = true;
        ZitlasDB.collection('coaching_plans').doc(uid).onSnapshot(function (ps) {
          _pcPlanDoc = ps.exists ? ps.data() : null;
          applyCoachTraining();
        }, function (e) { console.warn('[WP COACH] plan listener error', e); });
      }
      applyCoachTraining();
    }, function (e) { console.warn('[WP COACH] rel listener error', e); });
  }

  /* Goal-identity guard (mirror of diet.js's _pcCoachPlanIsCurrent): a
     coach plan only renders for the plan generation it was authored
     against. Fail-closed — unstamped or mismatched plans never render. */
  function _pcCoachPlanIsCurrent(coachPlan) {
    if (!coachPlan) return false;
    var current = localStorage.getItem('zitlas_plan_id') || null;
    if (!current) return false;
    return coachPlan.planId === current;
  }

  function applyCoachTraining() {
    var tr = _pcPlanDoc && _pcPlanDoc.training;
    if (!_pcShowsCoachPlan() || !tr || !tr.days || !tr.days.length ||
        !_pcCoachPlanIsCurrent(tr)) {
      if (_pcActive) { _pcActive = false; window.location.reload(); }
      return;
    }
    /* Convert coach schema → AI weekly_plan shape, reuse the whole renderer */
    var coachWp = {
      plan_name: '👨‍🏫 Coach Training Plan',
      weekly_plan: tr.days.map(function (d) {
        return {
          day: d.day,
          focus: d.rest ? 'Rest & Recovery' : (d.focus || 'Training Session'),
          duration_minutes: d.duration ? parseInt(d.duration, 10) || null : null,
          exercises: d.rest ? [] : (d.exercises || []).map(function (ex) {
            var parts = [];
            if (ex.reps) parts.push(ex.reps);
            if (ex.duration) parts.push(ex.duration);
            if (ex.rest) parts.push('rest ' + ex.rest);
            return {
              name: ex.name || 'Exercise',
              sets: ex.sets || '',
              reps_or_duration: parts.join(' · '),
              tip: ex.notes || '',
            };
          }),
        };
      }),
    };
    var meta = {
      reviewedBy: _pcPlanDoc.coachName || 'Your Coach',
      reviewedAt: _pcPlanDoc.trainingUpdatedAt
        ? new Date(_pcPlanDoc.trainingUpdatedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
        : '',
    };
    /* If the "No Plan Found" error state replaced the page (athlete had no
       AI plan), restore the original skeleton before rendering. */
    if (!el('wpContent') && showError._savedHtml) {
      el('wpPage').innerHTML = showError._savedHtml;
    }
    _pcActive = true;
    render(transformWorkoutPlan(coachWp, null, meta));
    _pcRenderBanner();
    console.log('[WP COACH] coach training rendered —', coachWp.weekly_plan.length, 'days');
  }

  function _pcRenderBanner() {
    var content = el('wpContent');
    if (!content) return;
    var banner = document.getElementById('pcCoachBanner');
    if (!banner) {
      banner = document.createElement('div');
      banner.id = 'pcCoachBanner';
      banner.className = 'cw-readonly-note';
      banner.style.margin = '0 0 12px';
      content.insertBefore(banner, content.firstChild);
    }
    var coachName = escHtml(_pcPlanDoc.coachName || 'your coach');
    function paint(verification) {
      var badge = (typeof ZitlasBadge !== 'undefined') ? ZitlasBadge.render(verification, { size: 'sm' }) : '';
      banner.innerHTML = _pcRel.status === 'active'
        ? (badge
            ? '👨‍🏫 Your Verified Coach: <b>&nbsp;' + coachName + '</b>' + badge + '&nbsp;— updates appear here instantly.'
            : '👨‍🏫 Training managed by <b>&nbsp;' + coachName + '</b>&nbsp;— updates appear here instantly.')
        : '👨‍🏫 Coaching ended — you’re keeping your coach’s last training plan.';
    }
    paint(null);
    if (typeof ZitlasBadge !== 'undefined' && _pcRel.coachId) {
      ZitlasBadge.fetchVerification(_pcRel.coachId).then(paint);
    }
  }

  /* ══════════════════════════════════════════
     DATA
  ══════════════════════════════════════════ */
  /* Normalise all workout-plan schema variants to an array of day objects */
  function normalizeWorkoutDays(wp) {
    return (wp && (wp.weekly_plan || wp.days || wp.weekly_schedule || wp.workout_days)) || [];
  }

  /* Apply workoutModifications on top of currentWorkoutPlan */
  function buildEffectiveWorkoutPlan(storage) {
    console.log('[BUILD EFFECTIVE WORKOUT] workoutModifications', storage.workoutModifications);
    /* currentWorkoutPlan may be null if accept handler saved before the fix — fall back to originalWorkoutPlan */
    var source = storage.currentWorkoutPlan || storage.originalWorkoutPlan;
    var plan = JSON.parse(JSON.stringify(source));
    var mods = storage.workoutModifications || {};
    var days = normalizeWorkoutDays(plan);
    days.forEach(function(day, idx) {
      var mod = mods[String(idx)];
      if (!mod) return;
      var nw = mod.newWorkout || {};
      if (nw.focus)            { day.focus = nw.focus; day.type = nw.focus; }
      if (nw.duration_minutes) day.duration_minutes = nw.duration_minutes;
      if (nw.exercises)        day.exercises = nw.exercises;
      day._modified   = true;
      day._modifiedBy = mod.modifiedBy;
      day._modifiedAt = mod.modifiedAt;
    });
    return plan;
  }

  /* Returns the newest workout review with workoutChangeHistory.
     NEVER relies on array order — cprofile.js unshifts new reviews so index 0 is newest,
     index -1 is oldest. Always sort by timestamp. No status/accept filter here — the
     normalization uses this to sync to the latest expert edit even before athlete accepts.

     planId-gated (this had NO staleness check at all before, the twin of
     the same fix in day.js): a review carrying a planId must match the
     currently active plan — without this, a freshly regenerated AI
     workout plan could get retroactively re-marked isExpertPlan=true by
     an old coach review purely because its timestamp was newer than the
     brand-new plan's unset reviewedAt. */
  function getLatestWorkoutReview(reviews) {
    var activePlanId = localStorage.getItem('zitlas_plan_id');
    return (reviews || [])
      .filter(function(r) {
        return r.reviewType === 'workout' &&
          r.workoutChangeHistory && r.workoutChangeHistory.length &&
          /* FAIL-CLOSED goal identity: planId required on both sides */
          !!(r.planId && activePlanId && r.planId === activePlanId);
      })
      .sort(function(a, b) {
        var aDate = new Date(a.reviewedAt || a.completedAt || a.createdAt || 0);
        var bDate = new Date(b.reviewedAt || b.completedAt || b.createdAt || 0);
        return bDate - aDate;
      })[0] || null;
  }

  /* Used only for CASE 1 flat-schema migration — requires completion + athlete acceptance. */
  function getCompletedWorkoutReview() {
    const reviews = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
    const activePlanId = localStorage.getItem('zitlas_plan_id');
    const workoutReviews = reviews
      .filter(function(r) {
        return r.reviewType === 'workout' &&
          (r.status === 'completed' || r.status === 'review_completed') &&
          (r.athleteAccepted === true || !!r.acceptedAt) &&
          r.workoutChangeHistory && r.workoutChangeHistory.length > 0 &&
          /* FAIL-CLOSED goal identity */
          !!(r.planId && activePlanId && r.planId === activePlanId);
      })
      .sort(function(a, b) {
        return new Date(b.reviewedAt || b.completedAt || b.acceptedAt || 0) -
               new Date(a.reviewedAt || a.completedAt || a.acceptedAt || 0);
      });
    return workoutReviews[0] || null;
  }

  /* Build new schema storage from a completed workout review and persist it.
     Called when zitlas_workout_plan doesn't yet have workoutModifications (CASE 1 recovery). */
  function _migrateWorkoutPlanFromReview(review, existingWp) {
    var rawPlan = existingWp || null;
    /* Unwrap if existingWp is already in new schema */
    if (rawPlan && (rawPlan.originalWorkoutPlan || rawPlan.currentWorkoutPlan)) {
      rawPlan = rawPlan.currentWorkoutPlan || rawPlan.originalWorkoutPlan;
    }
    var mods = {};
    (review.workoutChangeHistory || []).forEach(function(change) {
      if (change.dayIndex == null) return;
      mods[String(change.dayIndex)] = {
        modified:   true,
        modifiedBy: change.modifiedBy || review.expertName || 'Expert',
        modifiedAt: change.modifiedAt || review.reviewedAt || new Date().toISOString(),
        oldWorkout: change.oldWorkout || null,
        newWorkout: change.newWorkout || null,
      };
    });
    var newStorage = {
      originalWorkoutPlan:  rawPlan || review.planData || null,
      currentWorkoutPlan:   rawPlan || review.planData || null,
      workoutModifications: mods,
      isExpertPlan:         true,
      expertName:           review.expertName || 'Expert',
      reviewedAt:           review.reviewedAt || new Date().toISOString(),
      planId:               review.planId || localStorage.getItem('zitlas_plan_id') || null,
    };
    try {
      localStorage.setItem('zitlas_workout_plan', JSON.stringify(newStorage));
      console.log('[WeeklyPlan] CASE 1 recovery — migrated workout plan from review, mods:', mods);
    } catch (e) {
      console.error('[WeeklyPlan] Migration save failed', e);
    }
    return newStorage;
  }

  function loadPlan() {
    try {
      /* Diagnosis logs */
      var _diagAllRevs = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
      console.log('ALL REVIEWS', _diagAllRevs);
      var _diagWpRaw = JSON.parse(localStorage.getItem('zitlas_workout_plan') || 'null');
      console.log('WORKOUT STORAGE', _diagWpRaw);
      console.log('WORKOUT MODIFICATIONS', _diagWpRaw ? _diagWpRaw.workoutModifications : undefined);
      const _latestReview = getCompletedWorkoutReview();
      console.log('WEEKLY EXPERT REVIEW', _latestReview);

      /* 0. Legacy: Expert-reviewed workout plan via zitlas_expert_review */
      const er           = JSON.parse(localStorage.getItem('zitlas_expert_review') || 'null');
      const activePlanId = localStorage.getItem('zitlas_plan_id');

      /* Load original AI plan for diff computation (let — the goal-identity
         gate below nulls it when the wrapper belongs to a dead goal) */
      let originalWp = JSON.parse(localStorage.getItem('zitlas_workout_plan') || 'null');

      /* ── Normalize new schema so every code path can read .weekly_plan at root ── */
      if (originalWp) {
        /* 1. Lift weekly_plan to root — new schema stores it under originalWorkoutPlan */
        if (!originalWp.weekly_plan && originalWp.originalWorkoutPlan && originalWp.originalWorkoutPlan.weekly_plan) {
          originalWp.weekly_plan = originalWp.originalWorkoutPlan.weekly_plan;
        }
        /* Fallback: also try currentWorkoutPlan */
        if (!originalWp.weekly_plan && originalWp.currentWorkoutPlan && originalWp.currentWorkoutPlan.weekly_plan) {
          originalWp.weekly_plan = originalWp.currentWorkoutPlan.weekly_plan;
        }
        /* 2. Ensure currentWorkoutPlan is never null — fall back to originalWorkoutPlan */
        if (!originalWp.currentWorkoutPlan && originalWp.originalWorkoutPlan) {
          originalWp.currentWorkoutPlan = originalWp.originalWorkoutPlan;
        }
        /* 3. Sync workoutModifications to the NEWEST expert review.
              Runs when storage has no mods (first time) OR when a newer review exists (re-edit).
              Timestamp comparison means array insertion order is irrelevant. */
        var _normRevs = [];
        try { _normRevs = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]'); } catch (_) {}
        var _latestRev = getLatestWorkoutReview(_normRevs);

        console.log('ALL WORKOUT REVIEWS', (_normRevs || [])
          .filter(function(r) { return r.reviewType === 'workout' && r.workoutChangeHistory && r.workoutChangeHistory.length; })
          .map(function(r) {
            var ch = r.workoutChangeHistory;
            return {
              id: r.id, reviewedAt: r.reviewedAt, completedAt: r.completedAt, createdAt: r.createdAt,
              modified: ch && ch[0] && ch[0].newWorkout && ch[0].newWorkout.exercises &&
                        ch[0].newWorkout.exercises[0] && ch[0].newWorkout.exercises[0].name,
            };
          }));
        var _selCh = _latestRev && _latestRev.workoutChangeHistory;
        console.log('SELECTED REVIEW', _latestRev && _latestRev.id,
          _selCh && _selCh[0] && _selCh[0].newWorkout && _selCh[0].newWorkout.exercises &&
          _selCh[0].newWorkout.exercises[0] && _selCh[0].newWorkout.exercises[0].name);

        if (_latestRev) {
          var _storedTs = new Date(originalWp.reviewedAt || 0).getTime();
          var _reviewTs = new Date(_latestRev.reviewedAt || _latestRev.completedAt || _latestRev.createdAt || 0).getTime();
          var _noMods   = !originalWp.workoutModifications || !Object.keys(originalWp.workoutModifications).length;
          if (_noMods || _reviewTs > _storedTs) {
            var _rebuildMods = {};
            _latestRev.workoutChangeHistory.forEach(function(change) {
              if (change.dayIndex == null) return;
              _rebuildMods[String(change.dayIndex)] = {
                modified:   true,
                modifiedBy: change.modifiedBy || _latestRev.expertName || 'Expert',
                modifiedAt: change.modifiedAt || _latestRev.reviewedAt || new Date().toISOString(),
                oldWorkout: change.oldWorkout || null,
                newWorkout: change.newWorkout || null,
              };
            });
            originalWp.workoutModifications = _rebuildMods;
            originalWp.isExpertPlan = true;
            originalWp.expertName   = _latestRev.expertName || 'Expert';
            originalWp.reviewedAt   = _latestRev.reviewedAt || new Date().toISOString();
          }
        }
        /* Persist normalization so subsequent page loads are already clean */
        try { localStorage.setItem('zitlas_workout_plan', JSON.stringify(originalWp)); } catch (_) {}
      }

      console.log('NORMALIZED STORAGE', originalWp);
      console.log('WEEKLY PLAN SOURCE', originalWp ? originalWp.weekly_plan : null);
      console.log('ORIGINAL PLAN SOURCE', originalWp ? (originalWp.originalWorkoutPlan && originalWp.originalWorkoutPlan.weekly_plan) : null);

      if (er && er.status === 'APPROVED' && er.modifiedWorkoutPlan) {
        /* FAIL-CLOSED goal identity — same as day.js/diet.js: the review
           must carry a planId AND match the active plan. Reviews from a
           previous goal (or with no planId) never apply. */
        const planIdValid = !!(er.planId && activePlanId && er.planId === activePlanId);
        console.log('[WeeklyPlan] Expert review planId check — er.planId:', er.planId, '| active:', activePlanId, '| valid:', planIdValid);
        if (planIdValid && normalizeWorkoutDays(er.modifiedWorkoutPlan).length) {
          const expertMeta = {
            reviewedBy: er.reviewedBy || 'Expert',
            reviewedAt: er.reviewedAt
              ? new Date(er.reviewedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
              : '',
            expertId: er.expertId || null,
          };
          console.log('[WeeklyPlan] Loading EXPERT-REVIEWED plan —', normalizeWorkoutDays(er.modifiedWorkoutPlan).length, 'days | reviewer:', expertMeta.reviewedBy);
          const _origForDiff = originalWp && (originalWp.originalWorkoutPlan || originalWp.currentWorkoutPlan)
            ? (originalWp.originalWorkoutPlan || originalWp.currentWorkoutPlan)
            : originalWp;
          return transformWorkoutPlan(er.modifiedWorkoutPlan, _origForDiff, expertMeta);
        }
      }

      /* 1. Sport/roadmap format */
      const raw  = localStorage.getItem('zitlas_roadmap');
      const plan = raw ? JSON.parse(raw) : null;
      if (plan && plan.days && plan.days.length) {
        console.log('[Zitlas] Key read: zitlas_roadmap | Days:', plan.days.length);
        return plan;
      }

      /* 2. Fitness AI plan (or new expert-modified schema) */
      if (originalWp) {
        /* 2a. New schema already has workoutModifications — apply and render.
           GOAL-IDENTITY GATE (same policy as diet.js's validateDietStorage):
             stamped + matching current planId          → render
             stamped + mismatched                       → whole wrapper is a
               previous goal's plan — DELETE it, fall through
             unstamped + expert layer                   → unverifiable expert
               claim — DELETE (this is how stale coach modifications kept
               surviving goal resets)
             unstamped + pure AI content                → adopt: stamp with
               the current planId in place (first-party data) */
        if (originalWp.originalWorkoutPlan || originalWp.currentWorkoutPlan) {
          const hasMods = !!(originalWp.workoutModifications &&
            Object.keys(originalWp.workoutModifications).length > 0);
          const _curPlanId = localStorage.getItem('zitlas_plan_id') || null;
          let _wrapperOk;
          if (originalWp.planId) {
            _wrapperOk = !!(_curPlanId && originalWp.planId === _curPlanId);
          } else if (hasMods || originalWp.isExpertPlan) {
            _wrapperOk = false;
          } else if (_curPlanId) {
            originalWp.planId = _curPlanId;
            try { localStorage.setItem('zitlas_workout_plan', JSON.stringify(originalWp)); } catch (_) {}
            _wrapperOk = true;
          } else {
            _wrapperOk = false;
          }
          if (!_wrapperOk) {
            console.log('[WeeklyPlan] STALE workout wrapper discarded — planId:',
              originalWp.planId || 'missing', '| current:', _curPlanId || 'none');
            try { localStorage.removeItem('zitlas_workout_plan'); } catch (_) {}
            if (typeof ZitlasCloudSync !== 'undefined') ZitlasCloudSync.save('workoutPlan', null);
            originalWp = null;
          } else {
            console.log('[WeeklyPlan] New workout schema detected | hasMods:', hasMods, '| by:', originalWp.expertName);
            const effectivePlan = hasMods
              ? buildEffectiveWorkoutPlan(originalWp)
              : (originalWp.currentWorkoutPlan || originalWp.originalWorkoutPlan);
            const wmMeta = hasMods ? {
              reviewedBy: originalWp.expertName || 'Expert',
              reviewedAt: originalWp.reviewedAt
                ? new Date(originalWp.reviewedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
                : '',
            } : null;
            return transformWorkoutPlan(effectivePlan, originalWp.originalWorkoutPlan, wmMeta);
          }
        }

        /* 2b. Flat schema — check if athlete accepted a workout review that wasn't written (CASE 1 recovery) */
        if (normalizeWorkoutDays(originalWp).length) {
          if (_latestReview) {
            console.log('[WeeklyPlan] CASE 1 recovery: flat schema + accepted review detected. Migrating...');
            const _migratedStorage = _migrateWorkoutPlanFromReview(_latestReview, originalWp);
            const _hasMods = Object.keys(_migratedStorage.workoutModifications).length > 0;
            const _effectivePlan = _hasMods
              ? buildEffectiveWorkoutPlan(_migratedStorage)
              : (_migratedStorage.currentWorkoutPlan || _migratedStorage.originalWorkoutPlan);
            const _wmMeta = _hasMods ? {
              reviewedBy: _migratedStorage.expertName || 'Expert',
              reviewedAt: _migratedStorage.reviewedAt
                ? new Date(_migratedStorage.reviewedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short' })
                : '',
            } : null;
            return transformWorkoutPlan(_effectivePlan, _migratedStorage.originalWorkoutPlan, _wmMeta);
          }
          console.log('[Zitlas] Fallback: zitlas_workout_plan | Days:', normalizeWorkoutDays(originalWp).length);
          return transformWorkoutPlan(originalWp, null, null);
        }
      }

      console.log('[Zitlas] No plan found. Keys:', Object.keys(localStorage).join(', '));
      return null;
    } catch (e) {
      console.error('[Zitlas] Failed to parse plan:', e);
      return null;
    }
  }

  /* originalWp — the raw AI plan (for diff rendering)
     expertMeta  — { reviewedBy, reviewedAt } or null */
  function transformWorkoutPlan(wp, originalWp, expertMeta) {
    const origDays = normalizeWorkoutDays(originalWp || {});

    function iconForType(t) {
      var s = (t || '').toLowerCase();
      if (s.includes('rest'))     return '😴';
      if (s.includes('recovery')) return '🧘';
      if (s.includes('walking'))  return '🚶';
      if (s.includes('cardio'))   return '🏃';
      if (s.includes('upper'))    return '💪';
      if (s.includes('lower'))    return '🦵';
      if (s.includes('hiit'))     return '🔥';
      return '💪';
    }

    return {
      goalLabel:   wp.plan_name || 'Training Plan',
      goal:        'Fitness',
      role:        'Member',
      _expertMeta: expertMeta || null,
      days: normalizeWorkoutDays(wp).map(function (day, i) {
        const origDay    = origDays[i] || {};
        const origTheme  = origDay.focus || origDay.type || '';
        const newTheme   = day.focus || day.type || '';
        /* Only show diff when the day was flagged modified AND both values exist and differ */
        const focusDiff  = !!(day._modified && origTheme && newTheme && origTheme !== newTheme);

        return {
          dayNumber:       i + 1,
          dayName:         day.day || ('Day ' + (i + 1)),
          theme:           newTheme || 'Training Session',
          _originalTheme:  focusDiff ? origTheme : null,
          _expertModified: !!(day._modified),
          _modifiedBy:     day._modifiedBy || null,
          icon:            iconForType(day.focus || day.type),
          totalTime:       day.duration_minutes ? (day.duration_minutes + ' min') : '—',
          date:            day.date || '',
          isToday:         false,
          /* primarySkill uses the workout focus so "Primary" shows the reviewed name */
          primarySkill:    { name: newTheme || '' },
          drills:          (day.exercises || []).map(function (ex) {
            return {
              name:        ex.name || 'Exercise',
              cat:         'Fitness',
              duration:    ex.reps_or_duration || '',
              sets:        String(ex.sets || ''),
              reps:        ex.reps_or_duration || '',
              cue:         ex.tip || day.daily_tip || '',
              target:      ex.reps_or_duration || '',
              instruction: ex.tip || '',
            };
          }),
        };
      }),
    };
  }

  /* ══════════════════════════════════════════
     MAIN RENDER
  ══════════════════════════════════════════ */
  function render(plan) {
    el('wpLoading').style.display = 'none';
    el('wpContent').style.display = 'block';

    renderHero(plan);
    renderContextBar(plan);
    renderWeekProgress(plan);
    renderAnalysis(plan);
    renderDayList(plan);
    renderWeeklyReview(plan);

    /* Every ".wp-expert-badge" div (one per reviewed day) names the SAME
       single reviewer in this legacy one-expert-per-plan system — resolve
       their verification once and append the badge to all of them. */
    var expertId = plan._expertMeta && plan._expertMeta.expertId;
    if (expertId && typeof ZitlasBadge !== 'undefined') {
      ZitlasBadge.fetchVerification(expertId).then(function (v) {
        var badgeHtml = ZitlasBadge.render(v, { size: 'sm' });
        if (!badgeHtml) return;
        document.querySelectorAll('.wp-expert-badge').forEach(function (b) {
          b.insertAdjacentHTML('beforeend', badgeHtml);
        });
      });
    }
  }

  /* ── PLAN CONTEXT BAR ── */
  function renderContextBar(plan) {
    const wrap = el('wpContextBar');
    if (!wrap) return;

    const goalLabel   = plan.goalLabel  || capitalise(plan.goal  || 'Weight Loss');
    const weeklyFocus = plan.weeklyFocus || goalLabel;
    const improvement = plan.expectedImprovement || null;
    const ambition    = capitalise((plan.ambition || '').replace(/_/g, ' ')) || null;
    const accentColor = plan.metaColor || 'var(--primary)';

    const items = [
      { icon: '🎯', label: 'Goal',                value: goalLabel,   always: true  },
      { icon: '🔍', label: 'Weekly Focus',         value: weeklyFocus, always: true  },
      { icon: '📈', label: 'Expected Improvement', value: improvement, always: false },
      { icon: '🏆', label: 'Long-Term Ambition',   value: ambition,    always: false },
    ].filter(r => r.always || r.value);

    wrap.innerHTML = `
      <div class="wp-context" style="--ctx-color: ${accentColor}">
        <div class="wp-context-hd">
          <span class="wp-context-hd-dot"></span>
          <span class="wp-context-hd-title">Your Plan Profile</span>
        </div>
        <div class="wp-context-grid">
          ${items.map(r => `
            <div class="wp-context-item">
              <div class="wp-context-item-hd">
                <span class="wp-context-icon">${r.icon}</span>
                <span class="wp-context-label">${escHtml(r.label)}</span>
              </div>
              <p class="wp-context-value">${escHtml(r.value)}</p>
            </div>`).join('')}
        </div>
      </div>`;
  }

  /* ── WEEK PROGRESS ── */
  function renderWeekProgress(plan) {
    const wrap = el('wpWeekProgress');
    if (!wrap) return;

    const days  = plan.days || [];
    const today = new Date().toISOString().split('T')[0];

    const DAY_NAMES_WP = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
    const todayNameWP  = DAY_NAMES_WP[new Date().getDay()];

    /* Find current day index (0-6) */
    let currentIdx = -1;
    days.forEach(function (d, i) {
      if (d.isToday || d.date === today) currentIdx = i;
    });
    /* Fallback when no dates: match by dayName */
    if (currentIdx === -1) {
      const allPast = days.every(d => d.date && d.date < today);
      if (allPast) {
        currentIdx = 7;
      } else {
        days.forEach(function (d, i) {
          if (!d.date && (d.isToday || d.dayName === todayNameWP)) currentIdx = i;
        });
        if (currentIdx === -1) currentIdx = 0;
      }
    }

    /* Progress % = days before today / 7 */
    const completedCount = days.filter(d => d.date && d.date < today).length;
    const progressPct    = Math.round((completedCount / 7) * 100);

    /* Current day label */
    const currentDay = currentIdx < 7 ? days[currentIdx] : null;
    const currentLabel = currentDay
      ? `Day ${currentDay.dayNumber} — ${currentDay.theme || currentDay.dayName}`
      : 'Week Complete';

    /* Dot indicators */
    const dotsHtml = days.map(function (d, i) {
      let cls = 'wp-prog-dot';
      if (d.date && d.date < today)                                                        cls += ' wp-prog-dot--done';
      else if (d.isToday || d.date === today || (!d.date && d.dayName === todayNameWP)) cls += ' wp-prog-dot--active';
      /* else: upcoming, no modifier */
      return `<span class="${cls}" title="${escHtml(d.theme || 'Day ' + (i+1))}"></span>`;
    }).join('');

    const goalLabel   = plan.goalLabel  || capitalise(plan.goal  || 'Weight Loss');
    const improvement = plan.expectedImprovement || null;
    const accentColor = plan.metaColor || 'var(--primary)';

    wrap.innerHTML = `
      <div class="wp-week-progress" style="--prog-color: ${accentColor}">
        <div class="wp-prog-hd">
          <span class="wp-prog-hd-icon">📊</span>
          <span class="wp-prog-hd-title">Week Progress</span>
          <span class="wp-prog-pct">${progressPct}% complete</span>
        </div>

        <div class="wp-prog-bar-wrap">
          <div class="wp-prog-bar-track">
            <div class="wp-prog-bar-fill" style="width:${progressPct}%"></div>
          </div>
        </div>

        <div class="wp-prog-dots">${dotsHtml}</div>

        <div class="wp-prog-meta">
          <div class="wp-prog-meta-row">
            <span class="wp-prog-meta-label">Selected Goal</span>
            <span class="wp-prog-meta-value">${escHtml(goalLabel)}</span>
          </div>
          ${improvement ? `
          <div class="wp-prog-meta-row">
            <span class="wp-prog-meta-label">Expected Improvement</span>
            <span class="wp-prog-meta-value wp-prog-meta-value--accent">${escHtml(improvement)}</span>
          </div>` : ''}
          <div class="wp-prog-meta-row">
            <span class="wp-prog-meta-label">Current Session</span>
            <span class="wp-prog-meta-value">${escHtml(currentLabel)}</span>
          </div>
        </div>
      </div>`;
  }

  /* ── HERO ── */
  function renderHero(plan) {
    const hero = el('wpHero');
    if (!hero) return;

    const roleLabel = plan.roleLabel  || capitalise(plan.role  || 'Member');
    const goalLabel = plan.goalLabel  || capitalise(plan.goal  || 'Weight Loss');
    const days      = plan.days || [];

    /* Week date range */
    const firstDate = days[0]  ? formatHeroDate(days[0].date)  : '—';
    const lastDate  = days[6]  ? formatHeroDate(days[6].date)  : '—';
    const dateRange = (firstDate !== '—' && lastDate !== '—') ? `${firstDate} – ${lastDate}` : '';

    /* Total training hours */
    const totalMin = days.reduce((acc, d) => {
      const n = parseInt((d.totalTime || '0').replace(/[^0-9]/g, ''), 10) || 0;
      return acc + n;
    }, 0);
    const totalHrs = totalMin > 0 ? (totalMin / 60).toFixed(1) : '—';

    const isAiEnhanced = days.some(d => d.aiEnhanced);
    const ambitionLabel = capitalise((plan.ambition || '').replace(/_/g, ' ')) || 'Peak Performance';

    hero.innerHTML = `
      <div class="wp-hero-eyebrow">
        <span class="wp-hero-badge">${escHtml(roleLabel)}</span>
        ${isAiEnhanced ? '<span class="wp-ai-badge">🤖 AI Enhanced</span>' : ''}
      </div>
      <h1 class="wp-hero-title">Your 7-Day<br><span>Wellness Plan</span></h1>
      ${dateRange ? `<p class="wp-hero-dates">📅 ${escHtml(dateRange)}</p>` : ''}
      <div class="wp-hero-tags">
        <span class="wp-hero-tag">🎯 ${escHtml(goalLabel)}</span>
        <span class="wp-hero-tag">🏆 ${escHtml(ambitionLabel)}</span>
      </div>
      <div class="wp-hero-stats">
        <div class="wp-hero-stat">
          <span class="wp-hero-stat-num">7</span>
          <span class="wp-hero-stat-label">Sessions</span>
        </div>
        <div class="wp-hero-stat">
          <span class="wp-hero-stat-num">${escHtml(totalHrs)}</span>
          <span class="wp-hero-stat-label">Hours</span>
        </div>
        <div class="wp-hero-stat">
          <span class="wp-hero-stat-num">10</span>
          <span class="wp-hero-stat-label">Sections/Day</span>
        </div>
      </div>`;
  }

  /* ── AI ANALYSIS ── */
  function renderAnalysis(plan) {
    const wrap = el('wpAnalysisWrap');
    if (!wrap) return;

    const analysis = plan.analysis;
    if (!analysis) { wrap.innerHTML = ''; return; }

    const rows = [
      { label: 'Skill Gap',         value: analysis.skill_gap         || analysis.skillGap         },
      { label: 'Goal Feasibility',  value: analysis.goal_feasibility  || analysis.goalFeasibility  },
      { label: 'Training Capacity', value: analysis.training_capacity || analysis.trainingCapacity },
    ].filter(r => r.value);

    if (!rows.length) { wrap.innerHTML = ''; return; }

    wrap.innerHTML = `
      <div class="wp-analysis">
        <div class="wp-analysis-hd">
          <span class="wp-analysis-hd-icon">🧠</span>
          <span class="wp-analysis-hd-title">AI Pre-Analysis</span>
        </div>
        <div class="wp-analysis-row">
          ${rows.map(r => `
            <div class="wp-analysis-item">
              <p class="wp-analysis-item-label">${escHtml(r.label)}</p>
              <p class="wp-analysis-item-text">${escHtml(r.value)}</p>
            </div>`).join('')}
        </div>
      </div>`;
  }

  /* ── 7-DAY LIST ── */
  function renderDayList(plan) {
    const list = el('wpDayList');
    if (!list) return;

    const today    = new Date().toISOString().split('T')[0];
    const DAY_NAMES = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
    const todayName = DAY_NAMES[new Date().getDay()];

    list.innerHTML = (plan.days || []).map(function (day, i) {
      console.log('WEEKLY CARD DAY', day);
      const accentColor = DAY_COLORS[i] || DAY_COLORS[0];
      const date        = day.date || '';

      /* ── STATUS ──
         Past day  → Completed
         Today     → In Progress
         Future    → Scheduled
         When no dates, match by dayName instead of defaulting to i===0
      */
      let statusLabel, statusCls;
      if (day.isToday || date === today || (!date && day.dayName === todayName)) {
        statusLabel = 'In Progress';
        statusCls   = 'wp-status-badge--today';
      } else if (date && date < today) {
        statusLabel = 'Completed';
        statusCls   = 'wp-status-badge--done';
      } else {
        statusLabel = 'Scheduled';
        statusCls   = 'wp-status-badge--upcoming';
      }

      /* Short day abbreviation */
      const dayShort  = DAY_SHORT[day.dayName] || (day.dayName || 'DAY').slice(0, 3).toUpperCase();

      /* Formatted date */
      const dateShort = date ? formatCardDate(date) : '';

      /* Primary skill name — from plan data, never hardcoded */
      const primaryName = (day.primarySkill && day.primarySkill.name)
        ? day.primarySkill.name
        : (day.drills && day.drills[0] ? day.drills[0].name : '');
      const primarySnip = primaryName.length > 44
        ? primaryName.slice(0, 41) + '…'
        : primaryName;

      /* Fitness session name */
      const fitnessName = (day.fitnessSession && day.fitnessSession.name)
        ? day.fitnessSession.name
        : '';
      const fitnessSnip = fitnessName.length > 38
        ? fitnessName.slice(0, 35) + '…'
        : fitnessName;

      /* Duration — from plan data */
      const duration = day.totalTime || '—';

      /* Expert badge — shown only on modified days, using per-day modifiedBy when available */
      const _badgeName = day._modifiedBy || (plan._expertMeta && plan._expertMeta.reviewedBy) || 'Expert';
      const expertBadgeHtml = (day._expertModified && plan._expertMeta)
        ? `<div class="wp-expert-badge">✏️ Modified by ${escHtml(_badgeName)}${plan._expertMeta.reviewedAt ? ' · ' + escHtml(plan._expertMeta.reviewedAt) : ''}</div>`
        : '';

      /* Theme HTML — show strikethrough diff when focus changed */
      const themeHtml = day._originalTheme
        ? `<span class="wp-day-theme-del">${escHtml(day._originalTheme)}</span> <span class="wp-day-theme-new">✓ ${escHtml(day.theme)}</span>`
        : escHtml(day.theme || 'Training Session');

      return `
        <div class="wp-day-card${day._expertModified ? ' wp-day-card--reviewed' : ''}" data-day="${i}" role="button" tabindex="0"
             style="--i: ${i}" aria-label="${escHtml(day.theme || 'Day ' + day.dayNumber)}">
          <div class="wp-day-card-inner">

            <div class="wp-day-accent" style="background:${accentColor}"></div>

            <div class="wp-day-body">

              <!-- Row 1: Day name + date + status -->
              <div class="wp-day-row-top">
                <div class="wp-day-label-wrap">
                  <span class="wp-day-name">${escHtml(dayShort)}</span>
                  ${dateShort ? `<span class="wp-day-date">${escHtml(dateShort)}</span>` : ''}
                </div>
                <span class="wp-status-badge ${statusCls}">${statusLabel}</span>
              </div>

              <!-- Expert modified badge -->
              ${expertBadgeHtml}

              <!-- Row 2: Icon + theme (with optional strikethrough diff) + arrow -->
              <div class="wp-day-row-theme">
                <div class="wp-day-theme-wrap">
                  <span class="wp-day-icon">${escHtml(day.icon || '💪')}</span>
                  <span class="wp-day-theme">${themeHtml}</span>
                </div>
                <span class="wp-day-arrow">›</span>
              </div>

              <!-- Row 3: Duration only -->
              <div class="wp-day-row-chips">
                <span class="wp-chip">⏱ ${escHtml(duration)}</span>
              </div>

              <!-- Row 4: Primary — uses workout focus for fitness plans -->
              ${primarySnip ? `
                <p class="wp-day-primary">
                  <strong>Primary:</strong> ${escHtml(primarySnip)}
                </p>` : ''}

              <!-- Row 5: Fitness session (sport plans only) -->
              ${fitnessSnip ? `
                <p class="wp-day-fitness">
                  <strong>Fitness:</strong> ${escHtml(fitnessSnip)}
                </p>` : ''}

            </div>
          </div>
        </div>`;
    }).join('');

    /* Click + keyboard handlers */
    list.querySelectorAll('.wp-day-card').forEach(function (card) {
      const dayIdx = parseInt(card.dataset.day, 10);
      card.addEventListener('click', function () { openDay(dayIdx); });
      card.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          openDay(dayIdx);
        }
      });
    });
  }

  /* ── WEEKLY REVIEW ── */
  function renderWeeklyReview(plan) {
    const wrap   = el('wpReviewWrap');
    if (!wrap) return;

    const review = plan.weeklyReview;
    if (!review) { wrap.innerHTML = ''; return; }

    const items = [
      { icon: '🎯', label: 'Biggest Weakness',       value: review.biggest_weakness       || review.biggestWeakness       },
      { icon: '💪', label: 'Biggest Strength',        value: review.biggest_strength        || review.biggestStrength        },
      { icon: '📈', label: 'Expected Improvement',    value: review.expected_improvement    || review.expectedImprovement    },
      { icon: '✅', label: 'Weekly Success Criteria', value: review.weekly_success_criteria || review.weeklySuccessCriteria  },
    ].filter(r => r.value);

    if (!items.length) { wrap.innerHTML = ''; return; }

    const coachNote = review.coaches_weekly_notes || review.coachesWeeklyNotes;

    const itemsHtml = items.map(r => `
      <div class="wp-review-item">
        <div class="wp-review-item-hd">
          <span class="wp-review-item-icon">${r.icon}</span>
          <span class="wp-review-item-label">${escHtml(r.label)}</span>
        </div>
        <p class="wp-review-item-text">${escHtml(r.value)}</p>
      </div>`).join('');

    const noteHtml = coachNote ? `
      <div class="wp-review-notes">
        <div class="wp-review-notes-hd">
          <span class="wp-review-notes-icon">🧢</span>
          <span class="wp-review-notes-label">Trainer's Weekly Notes</span>
        </div>
        <p class="wp-review-notes-text">${escHtml(coachNote)}</p>
      </div>` : '';

    wrap.innerHTML = `
      <div class="wp-review">
        <div class="wp-review-hd">
          <span class="wp-review-hd-icon">📋</span>
          <span class="wp-review-hd-title">Weekly Review</span>
          <span class="wp-review-hd-sub">End-of-week assessment</span>
        </div>
        <div class="wp-review-grid">
          ${itemsHtml}
        </div>
        ${noteHtml}
      </div>`;
  }

  /* ══════════════════════════════════════════
     ERROR STATE
  ══════════════════════════════════════════ */
  function showError() {
    const page = el('wpPage');
    if (!page) return;
    /* Coach mode may still render after this (its snapshot arrives async) —
       keep the original skeleton so applyCoachTraining can restore it. */
    showError._savedHtml = page.innerHTML;
    page.innerHTML = `
      <div class="wp-error">
        <span class="wp-error-icon">📋</span>
        <h2 class="wp-error-title">No Plan Found</h2>
        <p class="wp-error-sub">Complete the AI Nutrition assessment with Zino to generate your personalised 7-day plan.</p>
        <button class="wp-error-btn" onclick="goToSurvey()">Start with Zino →</button>
        <button class="wp-cta-btn" style="margin-top:12px;" onclick="goBack()">← Back to Dashboard</button>
      </div>`;
  }

  /* ══════════════════════════════════════════
     NAVIGATION
  ══════════════════════════════════════════ */
  function openDay(dayIndex) {
    window.location.href = '../training/day.html?day=' + dayIndex;
  }

  window.goBack = function () {
    window.location.href = '../dashboard.html';
  };

  window.goToSurvey = function () {
    window.location.href = '../ai-coach/ai-coach.html';
  };

  /* ══════════════════════════════════════════
     UTILS
  ══════════════════════════════════════════ */
  function el(id) { return document.getElementById(id); }

  function escHtml(str) {
    return String(str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function capitalise(str) {
    if (!str) return '';
    return str.charAt(0).toUpperCase() + str.slice(1).replace(/_/g, ' ');
  }

  function formatHeroDate(dateStr) {
    if (!dateStr) return '';
    try {
      const d = new Date(dateStr);
      return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' });
    } catch { return dateStr; }
  }

  function formatCardDate(dateStr) {
    if (!dateStr) return '';
    try {
      const d = new Date(dateStr);
      return d.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' });
    } catch { return dateStr; }
  }

  /* ══════════════════════════════════════════
     INIT NAVIGATION BUTTONS
  ══════════════════════════════════════════ */
  function initButtons() {
    const backBtn = el('wpBackBtn');
    if (backBtn) backBtn.addEventListener('click', goBack);

    const dashBtn = el('wpBackToDash');
    if (dashBtn) dashBtn.addEventListener('click', goBack);
  }

  /* ══════════════════════════════════════════
     BOOT
  ══════════════════════════════════════════ */
  /* Cross-device sync: hydrate this device's cache from Firestore before
     the first render, then re-run ONLY init() (never initButtons() again,
     which would double-attach its click handlers) when another device
     changes the workout plan while this page stays open. init() is
     already idempotent — initCoachTrainingMode() guards its own listener
     attach and loadPlan()/render() are pure. */
  function boot() {
    initButtons();
    if (typeof ZitlasAuth === 'undefined' || typeof ZitlasCloudSync === 'undefined') { init(); return; }
    ZitlasAuth.onAuthStateChanged(function (user) {
      if (!user) { init(); return; }
      ZitlasCloudSync.hydrateOnLoad(user.uid).then(function () {
        init();
        ZitlasCloudSync.attachRealtime(user.uid, init);
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
