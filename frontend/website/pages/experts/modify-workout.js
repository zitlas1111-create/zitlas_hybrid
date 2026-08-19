(function () {
  'use strict';

  var reviewId = new URLSearchParams(window.location.search).get('reviewId');
  var expert   = null;
  var review   = null;
  var origWeekly = [];  /* original weekly_plan array */

  /* ── Helpers ── */

  function esc(str) {
    return String(str == null ? '' : str)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }

  function getExpert() {
    try { return JSON.parse(sessionStorage.getItem('zitlas_modify_expert') || 'null'); } catch (_) { return null; }
  }

  function getReview(id) {
    try {
      var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
      return all.find(function (r) { return r.id === id; }) || null;
    } catch (_) { return null; }
  }

  function patchReview(id, fields) {
    try {
      var all = JSON.parse(localStorage.getItem('expert_plan_reviews') || '[]');
      var idx = all.findIndex(function (r) { return r.id === id; });
      if (idx !== -1) {
        all[idx] = Object.assign({}, all[idx], fields);
        localStorage.setItem('expert_plan_reviews', JSON.stringify(all));
      }
    } catch (_) {}
  }

  function extractWeekly(planData) {
    if (!planData) return [];
    if (planData.currentWorkoutPlan || planData.originalWorkoutPlan) {
      var inner = planData.currentWorkoutPlan || planData.originalWorkoutPlan;
      return inner.weekly_plan || inner.days || [];
    }
    return planData.weekly_plan || planData.days || [];
  }

  function showToast(msg) {
    var t = document.getElementById('mpToast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('show');
    setTimeout(function () { t.classList.remove('show'); }, 2600);
  }

  /* ── Render ── */

  function renderPlan(weeklyPlan) {
    var body = document.getElementById('mpBody');
    if (!body) return;
    body.innerHTML = '';

    if (!weeklyPlan.length) {
      body.innerHTML = '<p style="padding:24px;text-align:center;color:var(--text-muted)">No workout days found in this review.</p>';
      return;
    }

    weeklyPlan.forEach(function (day, di) {
      var card = document.createElement('div');
      card.className = 'mp-day-card';
      card.dataset.di = di;

      var exRows = (day.exercises || []).map(function (ex) {
        return '<div class="mp-ex-row">' +
          '<input class="mp-input mp-ex-name" placeholder="Exercise name" value="' + esc(ex.name) + '"/>' +
          '<input class="mp-input mp-ex-sets" type="number" min="1" placeholder="Sets" value="' + esc(ex.sets) + '"/>' +
          '<input class="mp-input mp-ex-reps" placeholder="Reps / Duration" value="' + esc(ex.reps_or_duration) + '"/>' +
          '<button class="mp-ex-remove" aria-label="Remove exercise">✕</button>' +
          '</div>';
      }).join('');

      card.innerHTML =
        '<div class="mp-day-label">' + esc(day.day || ('Day ' + (di + 1))) + '</div>' +
        '<div class="mp-field-row">' +
          '<span class="mp-label">Focus</span>' +
          '<input class="mp-input mp-focus" placeholder="e.g. Upper Body" value="' + esc(day.focus) + '"/>' +
        '</div>' +
        '<div class="mp-field-row">' +
          '<span class="mp-label">Duration</span>' +
          '<input class="mp-input mp-input--short mp-duration" type="number" min="1" placeholder="45" value="' + esc(day.duration_minutes) + '"/>' +
          '<span style="font-size:12px;color:var(--text-muted);margin-left:4px">min</span>' +
        '</div>' +
        '<div class="mp-exercises-label">Exercises</div>' +
        '<div class="mp-ex-cols">' +
          '<span class="mp-ex-col-label">Name</span>' +
          '<span class="mp-ex-col-label">Sets</span>' +
          '<span class="mp-ex-col-label">Reps / Duration</span>' +
          '<span></span>' +
        '</div>' +
        '<div class="mp-ex-list">' + exRows + '</div>' +
        '<button class="mp-add-ex">+ Add Exercise</button>';

      /* Remove buttons */
      card.querySelectorAll('.mp-ex-remove').forEach(function (btn) {
        btn.addEventListener('click', function () { btn.closest('.mp-ex-row').remove(); });
      });

      /* Add exercise */
      card.querySelector('.mp-add-ex').addEventListener('click', function () {
        var row = document.createElement('div');
        row.className = 'mp-ex-row';
        row.innerHTML =
          '<input class="mp-input mp-ex-name" placeholder="Exercise name" value=""/>' +
          '<input class="mp-input mp-ex-sets" type="number" min="1" placeholder="Sets" value=""/>' +
          '<input class="mp-input mp-ex-reps" placeholder="Reps / Duration" value=""/>' +
          '<button class="mp-ex-remove" aria-label="Remove exercise">✕</button>';
        row.querySelector('.mp-ex-remove').addEventListener('click', function () { row.remove(); });
        card.querySelector('.mp-ex-list').appendChild(row);
        row.querySelector('.mp-ex-name').focus();
      });

      body.appendChild(card);
    });
  }

  /* ── Collect form → edited plan ── */

  function collectEdited() {
    var days = [];
    document.querySelectorAll('.mp-day-card').forEach(function (card, di) {
      var orig      = origWeekly[di] || {};
      var focus     = (card.querySelector('.mp-focus')    || {}).value    || '';
      var durStr    = (card.querySelector('.mp-duration') || {}).value    || '';
      var exercises = [];
      card.querySelectorAll('.mp-ex-row').forEach(function (row) {
        var name = ((row.querySelector('.mp-ex-name') || {}).value || '').trim();
        var sets = ((row.querySelector('.mp-ex-sets') || {}).value || '').trim();
        var reps = ((row.querySelector('.mp-ex-reps') || {}).value || '').trim();
        if (name) {
          exercises.push({ name: name, sets: sets ? parseInt(sets) : 0, reps_or_duration: reps });
        }
      });
      days.push({
        day:              orig.day || ('Day ' + (di + 1)),
        focus:            focus.trim() || orig.focus || '',
        duration_minutes: durStr ? parseInt(durStr) : (orig.duration_minutes || 0),
        exercises:        exercises,
      });
    });
    return { weekly_plan: days };
  }

  /* ── Build workoutChangeHistory ── */

  function buildHistory(editedPlan, expertName) {
    var history = [];
    editedPlan.weekly_plan.forEach(function (newDay, i) {
      var oldDay  = origWeekly[i] || {};
      var changed = newDay.focus !== (oldDay.focus || '') ||
        String(newDay.duration_minutes) !== String(oldDay.duration_minutes || '') ||
        JSON.stringify(newDay.exercises) !== JSON.stringify(oldDay.exercises || []);
      if (changed) {
        history.push({
          dayIndex:   i,
          dayName:    newDay.day,
          modifiedBy: expertName || 'Expert',
          modifiedAt: new Date().toISOString(),
          oldWorkout: {
            focus:              oldDay.focus || '',
            duration_minutes:   oldDay.duration_minutes || 0,
            exercises:          oldDay.exercises || [],
          },
          newWorkout: {
            focus:              newDay.focus,
            duration_minutes:   newDay.duration_minutes,
            exercises:          newDay.exercises,
          },
        });
      }
    });
    return history;
  }

  /* ── AUTO-APPLY: the reviewed workout becomes the athlete's ACTIVE plan ──
     Mirror of modify-diet.js's applyReviewedDietToAthlete() — Complete
     Review used to update ONLY review_requests/{id}; the athlete's actual
     plan storage (users/{uid}.workoutPlan, the documented single source
     of truth every athlete page hydrates + live-syncs from) was never
     touched, so the athlete kept the old workout forever. Writes the
     standard workout-modification wrapper (identical shape to what the
     athlete-side accept builds), planId-stamped so athlete-side readers
     fail closed if the athlete regenerated their plan meanwhile. */
  function buildAppliedWorkoutWrapper(rev, edited, history, expertName, nowIso) {
    var original = rev.planData || null;
    if (original && (original.originalWorkoutPlan || original.currentWorkoutPlan)) {
      original = original.currentWorkoutPlan || original.originalWorkoutPlan;
    }
    var mods = {};
    (history || []).forEach(function (h) {
      if (h.dayIndex == null) return;
      mods[String(h.dayIndex)] = {
        modified:   true,
        modifiedBy: h.modifiedBy || expertName,
        modifiedAt: h.modifiedAt || nowIso,
        oldWorkout: h.oldWorkout || null,
        newWorkout: h.newWorkout || null,
      };
    });
    return {
      originalWorkoutPlan:  original || edited,
      currentWorkoutPlan:   edited,
      workoutModifications: mods,
      workoutChangeHistory: history || [],
      isExpertPlan:         true,
      expertName:           expertName,
      reviewedAt:           nowIso,
      planId:               rev.planId || null,
    };
  }

  function applyReviewedWorkoutToAthlete(rev, expertName, nowIso) {
    var athleteUid = rev.userId || null;
    var edited     = rev.reviewedWorkoutPlan;
    if (typeof ZitlasDB === 'undefined') return Promise.resolve(false);
    if (!athleteUid) {
      console.warn('[MODIFY-WORKOUT] auto-apply skipped — review has no userId (legacy request)', reviewId);
      return Promise.resolve(false);
    }
    if (!edited || !edited.weekly_plan || !edited.weekly_plan.length) {
      console.warn('[MODIFY-WORKOUT] auto-apply skipped — no reviewedWorkoutPlan days', reviewId);
      return Promise.resolve(false);
    }
    /* APPLY-GATE — same root-cause fix as modify-diet.js: the master
       users/{uid}.workoutPlan may only be overwritten when this review
       provably belongs to the athlete's CURRENT plan generation (both
       planIds present and equal, checked LIVE at complete time). A
       mismatched/unstamped review skips the apply and falls back to the
       planId-gated athlete-side accept flow — the master plan can never
       be destroyed by an expert action. */
    /* Cross-user write (expert → athlete's users/{uid}.workoutPlan) now runs
       SERVER-SIDE via POST /api/review/apply (assigned-expert check + same
       planId apply-gate, Admin SDK). Denied/mismatched → master plan untouched,
       athlete-side accept flow delivers. See modify-diet.js for the rationale. */
    var wrapper = buildAppliedWorkoutWrapper(rev, edited, rev.workoutChangeHistory, expertName, nowIso);
    var auth = (typeof ZitlasAuth !== 'undefined') ? ZitlasAuth : null;
    var user = auth && auth.currentUser;
    if (!user || typeof user.getIdToken !== 'function') return Promise.resolve(false);
    return user.getIdToken().then(function (token) {
      return fetch('/api/review/apply', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ reviewId: rev.reviewId || rev.id, athleteUid: athleteUid,
          planType: 'workout', wrapper: wrapper }),
      });
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        var applied = res.status === 200 && data.success && data.applied === true;
        console.log('[MODIFY-WORKOUT] server apply →', res.status, data);
        return applied;
      });
    }).catch(function (e) {
      console.error('[MODIFY-WORKOUT] server apply failed (master plan untouched)', e);
      return false;
    });
  }

  /* ── Init ── */

  function init() {
    if (!reviewId) {
      document.body.innerHTML = '<p style="padding:32px;color:var(--text-muted)">No review ID in URL.</p>';
      return;
    }

    expert = getExpert();
    review = getReview(reviewId);

    if (!review) {
      document.body.innerHTML = '<p style="padding:32px;color:var(--text-muted)">Review not found.</p>';
      return;
    }

    /* Show athlete name */
    var athleteEl = document.getElementById('mpAthleteName');
    if (athleteEl) athleteEl.textContent = review.athleteName || review.userName || 'Athlete';

    /* Extract original plan */
    origWeekly = extractWeekly(review.planData);

    /* If expert already saved once, show their saved version */
    if (review.reviewedWorkoutPlan && review.reviewedWorkoutPlan.weekly_plan) {
      origWeekly = review.reviewedWorkoutPlan.weekly_plan;
    }

    renderPlan(origWeekly);

    /* Back */
    document.getElementById('mpBack').addEventListener('click', function () {
      window.location.href = 'expert-dashboard.html';
    });

    /* NOTE: this handler is kept deliberately identical in structure to
       modify-diet.js's — same ordering, same guards, same logging — so a
       fix to one is trivially portable to the other. Only the field names
       and the apply-to-athlete helper differ. */
    var completeBtn = document.getElementById('mpComplete');

    /* ── ONE canonical action: Save & Complete Review ─────────────────────
       WHAT WAS WRONG:

       1. TWO BUTTONS, SEQUENTIALLY GATED. Save hid itself and revealed
          Complete (`saveBtn.style.display='none'; completeBtn.style.display=
          'block'`). Save early-returns while the day cards are still
          rendering, so a click during load left Complete permanently
          invisible and the review un-completable.

       2. "STILL PENDING" AFTER CLICKING. The local status was patched to
          'review_completed' BEFORE the Firestore write, and that write's
          failure was caught into a toast. The dashboard's snapshot handler
          treats Firestore as authoritative and rewrites the local cache from
          it — so a failed or skipped Firestore update silently reverted the
          card to `pending`, however many times the expert clicked.

       3. CHAT REDIRECT. On success it stashed `ed_open_chat` in
          sessionStorage and navigated to expert-dashboard.html, which then
          opened the chat.

       NOW: one button, writes in dependency order, each awaited, and the
       review is marked completed ONLY after the plan and the athlete's copy
       are both safely stored. Any failure leaves the status pending and
       re-enables the button. No navigation at all. */
    var isCompletingReview = false;

    function markCompletedUi() {
      completeBtn.disabled = true;
      completeBtn.textContent = 'Review Completed ✓';
      completeBtn.classList.add('mp-btn--done');
    }

    /* STEP 10 — an already-completed review can never be resubmitted. */
    (function () {
      var existing = getReview(reviewId) || review || {};
      if (existing.status === 'review_completed' || existing.status === 'completed') {
        markCompletedUi();
      }
    })();

    completeBtn.addEventListener('click', function () {
      console.log('[REVIEW COMPLETE] button clicked');

      /* STEP 4 — in-flight guard. A second click must never produce a second
         set of completion writes. */
      if (isCompletingReview) {
        console.log('[REVIEW COMPLETE] ignored — already in flight');
        return;
      }
      var current = getReview(reviewId) || review || {};
      if (current.status === 'review_completed' || current.status === 'completed') {
        console.log('[REVIEW COMPLETE] ignored — already completed');
        markCompletedUi();
        return;
      }

      var expertName = (expert && expert.name) || 'Expert';
      var expertId   = (expert && expert.id) || review.expertId || '';
      var nowIso     = new Date().toISOString();

      console.log('[REVIEW COMPLETE] requestId=' + reviewId);
      console.log('[REVIEW COMPLETE] expertId=' + expertId);
      console.log('[REVIEW COMPLETE] userId=' + (review.userId || '(none)'));
      console.log('[REVIEW COMPLETE] reviewType=' +
        (review.reviewType || review.planReviewType || 'workout'));

      console.log('[REVIEW COMPLETE] validating final plan');
      /* renderPlan runs async (after the live-athlete fetch). Collecting
         before the day cards exist would gather an EMPTY plan and overwrite
         the expert's work with nothing. */
      if (!document.querySelector('.mp-day-card')) {
        console.error('[REVIEW COMPLETE] FAILURE operation=validate ' +
                      'code=plan_not_loaded message=day cards not rendered yet');
        showToast('Plan is still loading — one moment…');
        return;
      }
      if (typeof ZitlasDB === 'undefined') {
        console.error('[REVIEW COMPLETE] FAILURE operation=validate ' +
                      'code=no_firestore message=cannot reach the server');
        showToast('⚠️ Unable to complete the review — you appear to be offline.');
        return;
      }

      var edited  = collectEdited();
      var history = buildHistory(edited, expertName);
      if (!edited || !edited.days || !edited.days.length) {
        console.error('[REVIEW COMPLETE] FAILURE operation=validate ' +
                      'code=empty_plan message=collected plan has no days');
        showToast('⚠️ Nothing to save — the plan looks empty. Please reload and retry.');
        return;
      }
      console.log('[REVIEW COMPLETE] validation success');

      isCompletingReview = true;
      completeBtn.disabled = true;
      completeBtn.textContent = 'Saving & Completing…';

      function fail(operation, err) {
        console.error('[REVIEW COMPLETE] FAILURE operation=' + operation +
                      ' code=' + (err && err.code) +
                      ' message=' + (err && err.message));
        /* Status stays pending: it is only ever written in the final step. */
        isCompletingReview = false;
        completeBtn.disabled = false;
        completeBtn.textContent = 'Save & Complete Review';
        showToast('⚠️ Unable to complete the review. Your changes were not ' +
                  'fully saved. Please try again.');
      }

      var docRef = ZitlasDB.collection('review_requests').doc(reviewId);

      /* 1. Expert's edited plan. */
      console.log('[REVIEW COMPLETE] saving expert plan');
      docRef.update({
        reviewedWorkoutPlan:  edited,
        workoutChangeHistory: history,
        savedAt:           nowIso,
      }).then(function () {
        console.log('[REVIEW COMPLETE] expert plan save success');
        /* Local echo only AFTER the server has it. */
        patchReview(reviewId, {
          reviewedWorkoutPlan:  edited,
          workoutChangeHistory: history,
          savedAt:           nowIso,
        });

        /* 2. Athlete's active plan. */
        console.log('[REVIEW COMPLETE] updating athlete plan');
        var fresh = getReview(reviewId) || review;
        return applyReviewedWorkoutToAthlete(fresh, expertName, nowIso);
      }).then(function (applied) {
        console.log('[REVIEW COMPLETE] athlete plan update success applied=' + !!applied);

        /* 3. Status LAST — the review is not completed until the plan and the
              athlete's copy are both stored. */
        console.log('[REVIEW COMPLETE] updating review status');
        return docRef.update({
          status:          'review_completed',
          reviewedAt:      nowIso,
          completedAt:     nowIso,
          expertName:      expertName,
          expertId:        expertId,
          autoApplied:     !!applied,
          autoAppliedAt:   applied ? nowIso : null,
          /* applied -> the plan is already live on the athlete's account, so
             the Accept banner would be redundant. Not applied -> leave it
             false so the athlete's Accept fallback still delivers it. */
          athleteAccepted: !!applied,
        }).then(function () { return applied; });
      }).then(function (applied) {
        console.log('[REVIEW COMPLETE] status update success');
        console.log('[REVIEW COMPLETE] completedAt saved ' + nowIso);
        patchReview(reviewId, {
          status:          'review_completed',
          reviewedAt:      nowIso,
          completedAt:     nowIso,
          expertName:      expertName,
          expertId:        expertId,
          autoApplied:     !!applied,
          athleteAccepted: !!applied,
        });

        /* System message into the coaching chat. Informational only — it does
           NOT navigate anywhere, and a failure here cannot un-complete a
           review that is already safely stored. */
        try {
          var convId = (expert && expert.id) || '';
          var chats  = JSON.parse(localStorage.getItem('zitlas_chats') || '{}');
          if (convId && chats[convId]) {
            chats[convId].messages = chats[convId].messages || [];
            chats[convId].messages.push({
              id:         'sys_complete_' + Date.now(),
              senderType: 'system',
              type:       'review_complete',
              text:       '✅ Review Completed — ' + expertName +
                          ' has finished reviewing your training plan.',
              timestamp:  nowIso,
            });
            localStorage.setItem('zitlas_chats', JSON.stringify(chats));
          }
        } catch (_) {}

        console.log('[REVIEW COMPLETE] SUCCESS');
        markCompletedUi();
        showToast('✓ Review completed successfully.');
        /* STEP 8 — deliberately NO navigation. The expert stays on this review
           and leaves under their own steam. The old flow stashed
           `ed_open_chat` and redirected to the dashboard, which then opened
           the chat. */
      }).catch(function (err) {
        /* One handler for every stage: whichever write rejected, the status
           has not been touched, so the review is still pending and retryable. */
        fail('save_and_complete', err);
      });
    });
  }

  document.addEventListener('DOMContentLoaded', init);
})();
