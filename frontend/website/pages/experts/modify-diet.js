(function () {
  'use strict';

  var reviewId   = new URLSearchParams(window.location.search).get('reviewId');
  var expert     = null;
  var review     = null;
  var origDays   = [];   /* original plan days array */

  var MEAL_KEYS   = ['breakfast', 'morning_snack', 'lunch', 'afternoon_snack', 'dinner', 'snacks'];
  var MEAL_EMOJIS = { breakfast: '🌅', morning_snack: '🍎', lunch: '☀️', afternoon_snack: '🥜', dinner: '🌙', snacks: '🍌' };

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

  function extractDays(planData) {
    if (!planData) return [];
    if (planData.originalDietPlan || planData.currentDietPlan) {
      var inner = planData.currentDietPlan || planData.originalDietPlan;
      return inner.days || [];
    }
    return planData.days || [];
  }

  function normalizeFoods(foods) {
    if (!foods) return [];
    if (Array.isArray(foods)) return foods.map(function (f) { return typeof f === 'string' ? f : (f.name || f.item || String(f)); });
    if (typeof foods === 'string') return foods.split('\n').filter(Boolean);
    return [];
  }

  function mealKeyName(key) {
    return key.replace(/_/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); });
  }

  /* ── AUTO-APPLY: the reviewed plan becomes the athlete's ACTIVE plan ──
     ROOT CAUSE this closes: Complete Review used to update ONLY
     review_requests/{id} — a review inbox document. Nothing ever wrote the
     reviewed meals into the athlete's actual plan storage, so the expert
     saw "Review Sent to User" while the athlete's diet page kept
     rendering the old plan forever (unless they manually pressed the
     Accept banner, which itself only worked when the review synced AND
     the banner was noticed).

     Target: users/{athleteUid}.dietPlan — the documented single source of
     truth for the athlete's plan (docs/GOAL_LIFECYCLE_ARCHITECTURE.md
     Rule 1). Every athlete page hydrates from it on load AND live-updates
     from it via ZitlasCloudSync.attachRealtime, with or without any
     coaching relationship. Deliberately NOT coaching_plans/{uid}: that
     collection is the Personal Coaching plan (different meal schema —
     options[], not foods[]) and only renders while a coaching
     relationship exists — writing reviews there would corrupt the coach
     pipeline and silently no-op for every athlete without a coach.

     The written value is the standard expert-modification wrapper —
     identical shape to what the athlete's own Accept button builds — so
     every existing reader (buildEffectivePlan, planId fail-closed
     validation, expert badges, swap flow) works unchanged. */
  function buildAppliedDietWrapper(rev, edited, history, expertName, nowIso) {
    var original = rev.planData || null;
    if (original && (original.originalDietPlan || original.currentDietPlan)) {
      original = original.currentDietPlan || original.originalDietPlan;
    }
    var mods = {};
    (history || []).forEach(function (h) {
      var dk = String(h.dayIndex != null ? h.dayIndex : 0);
      var mk = h.mealKey || _mealKeyOf(h.mealName);
      if (!mods[dk]) mods[dk] = {};
      mods[dk][mk] = {
        modified:   true,
        modifiedBy: h.modifiedBy || expertName,
        modifiedAt: h.modifiedAt || nowIso,
        oldMeal: {
          foods:     normalizeFoods(h.oldMeal && h.oldMeal.foods),
          calories:  (h.oldMeal && h.oldMeal.calories)  || null,
          protein_g: (h.oldMeal && h.oldMeal.protein_g) || null,
        },
        newMeal: {
          foods:     normalizeFoods(h.newMeal && h.newMeal.foods),
          calories:  (h.newMeal && h.newMeal.calories)  || null,
          protein_g: (h.newMeal && h.newMeal.protein_g) || null,
        },
      };
    });
    return {
      originalDietPlan:    original || edited,
      /* currentDietPlan carries the expert's edits baked in — content is
         correct even for a meal the change-history diff missed; applying
         mods on top of it is idempotent and only adds the ✏️ badges. */
      currentDietPlan:     edited,
      expertModifications: mods,
      isExpertPlan:        true,
      expertName:          expertName,
      expertId:            rev.expertId || null,
      expertNotes:         getExpertNotes() || null,
      reviewedAt:          nowIso,
      /* Explicit review metadata on the single source of truth — every
         consumer can answer "whose plan is this and what state is it in"
         from this one document alone. */
      reviewStatus:        'completed',
      planSource:          'expert_reviewed',
      reviewId:            rev.id || null,
      version:             (rev.version || 1),
      lastUpdated:         nowIso,
      /* Goal-identity stamp — athlete-side readers fail closed on this,
         so a review completed after the athlete regenerated their plan
         retires silently instead of resurrecting a dead goal's plan. */
      planId:              rev.planId || null,
    };
  }

  function applyReviewedDietToAthlete(rev, expertName, nowIso) {
    var athleteUid = rev.userId || null;
    var edited     = rev.reviewedDietPlan;
    if (typeof ZitlasDB === 'undefined') return Promise.resolve(false);
    if (!athleteUid) {
      /* Legacy request created before userId stamping — can't address the
         athlete's user doc. The review itself still syncs; the athlete
         can accept it from their Diet page banner. */
      console.warn('[MODIFY-DIET] auto-apply skipped — review has no userId (legacy request)', reviewId);
      return Promise.resolve(false);
    }
    if (!edited || !edited.days || !edited.days.length) {
      console.warn('[MODIFY-DIET] auto-apply skipped — no reviewedDietPlan days', reviewId);
      return Promise.resolve(false);
    }
    /* ══ APPLY-GATE (root-cause fix for "diet plan disappears") ══
       Auto-apply may run ONLY when this review provably belongs to the
       athlete's CURRENT plan generation: both planIds present AND equal,
       verified against the athlete's LIVE users/{uid} doc at THIS moment
       (not the page-load snapshot — the athlete may have regenerated
       while the expert was editing).

       Without this gate, completing an OLD request (or one created with
       planId:null before the athlete's device had hydrated) OVERWROTE
       users/{uid}.dietPlan — the master copy — with a wrapper the
       athlete-side validator then judged stale and DELETED, leaving the
       user with "No Plan Yet" as if they never generated anything.

       Skipping is always safe: athleteAccepted stays false, so the
       athlete-side Accept-banner fallback owns delivery — and that path
       is itself planId-gated, so a current-goal review still surfaces
       while a dead-goal review simply never renders. The master plan is
       untouched either way. */
    /* Auto-apply is a CROSS-USER write (expert → athlete's users/{uid}.dietPlan),
       which production Security Rules deny (users writes are owner-only). It now
       runs SERVER-SIDE via POST /api/review/apply, which re-verifies (from the
       stored review_requests doc) that the caller is the assigned expert AND
       enforces the SAME planId apply-gate before writing via the Admin SDK. If
       it can't apply (planId mismatch, or backend/Firestore unavailable), the
       master plan is left untouched and the planId-gated athlete-side accept
       flow owns delivery — exactly the prior fallback contract. */
    var wrapper = buildAppliedDietWrapper(rev, edited, rev.mealChangeHistory, expertName, nowIso);
    var auth = (typeof ZitlasAuth !== 'undefined') ? ZitlasAuth : null;
    var user = auth && auth.currentUser;
    if (!user || typeof user.getIdToken !== 'function') return Promise.resolve(false);
    return user.getIdToken().then(function (token) {
      return fetch('/api/review/apply', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ reviewId: rev.reviewId || rev.id, athleteUid: athleteUid,
          planType: 'diet', wrapper: wrapper }),
      });
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        var applied = res.status === 200 && data.success && data.applied === true;
        console.log('[MODIFY-DIET] server apply →', res.status, data);
        return applied;
      });
    }).catch(function (e) {
      console.error('[MODIFY-DIET] server apply failed (master plan untouched)', e);
      return false;
    });
  }

  /* Mirrors diet.js's _mealKey() exactly — must produce identical keys so
     the athlete-side accept flow can match meals by key. */
  function _mealKeyOf(name) {
    return (name || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_');
  }

  function showToast(msg) {
    var t = document.getElementById('mpToast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('show');
    setTimeout(function () { t.classList.remove('show'); }, 2600);
  }

  /* ── Render ── */

  function getMealsFromDay(day) {
    /* Canonical schema (AI plan + expert-dashboard.js editor) stores
       days[].meals as an ARRAY of meal objects, not an object keyed by
       meal name. Normalize to a keyed object here for internal
       rendering/diffing regardless of which shape the source data is in —
       older reviews saved before this fix may still be object-shaped. */
    var meals = day.meals || day;
    if (Array.isArray(meals)) {
      var keyed = {};
      meals.forEach(function (m) {
        keyed[m._mealKey || _mealKeyOf(m.meal_name || m.name)] = m;
      });
      return keyed;
    }
    return meals;
  }

  /* ── Athlete context panel ──
     Renders everything the ZITLAS assessment knows about this athlete so
     the expert reviews the plan in context (who is this person, what's
     their goal, what are their restrictions/targets) instead of editing
     meals blind. Data comes from the snapshot the request itself carries:
     profileBasics + assessmentData (paid cprofile flow) or context
     (diet-page flow) — older requests that predate those fields simply
     render fewer rows. NOTE: deliberately NOT class mp-day-card —
     collectEdited() iterates .mp-day-card and must never see this. */
  function _ctxRow(label, value) {
    if (value == null || value === '' || (Array.isArray(value) && !value.length)) return '';
    var v = Array.isArray(value) ? value.join(', ') : String(value);
    return '<div class="mp-ctx-row"><span class="mp-ctx-label">' + esc(label) + '</span>' +
           '<span class="mp-ctx-value">' + esc(v) + '</span></div>';
  }
  function _ctxSection(title, rowsHtml) {
    if (!rowsHtml) return '';
    return '<div class="mp-ctx-section"><p class="mp-ctx-title">' + esc(title) + '</p>' + rowsHtml + '</div>';
  }
  function _pick(obj, keys) {
    if (!obj) return null;
    for (var i = 0; i < keys.length; i++) {
      var v = obj[keys[i]];
      if (v != null && v !== '') return v;
    }
    return null;
  }

  function buildContextPanel(review, live) {
    /* SOURCE OF TRUTH: the athlete's LIVE users/{uid} doc (fetched in
       init) — the expert reviews who the athlete is NOW. The snapshot
       the request carried (assessmentData/context/profileBasics) is the
       fallback for legacy requests or offline reads. */
    var ad   = review.assessmentData || {};
    var ctx  = review.context || {};
    var assess = (live && live.assessment) || ad.assessment || ctx.assessment || {};
    var p    = Object.assign({}, review.profileBasics || {}, assess);
    var calc = (live && live.calculations) || ad.calculations || ctx.calculations || {};
    var goal = (live && live.goal) || review.goal || {};

    var userRows =
      _ctxRow('Name',   review.athleteName || review.userName || review.athlete_name) +
      _ctxRow('Age',    p.age) +
      _ctxRow('Gender', p.gender) +
      _ctxRow('Height', p.height_cm ? p.height_cm + ' cm' : null) +
      _ctxRow('Weight', p.weight_kg ? p.weight_kg + ' kg' : null) +
      _ctxRow('Goal Weight', p.goal_weight_kg ? p.goal_weight_kg + ' kg' : null) +
      _ctxRow('Occupation', _pick(p, ['occupation', 'living_situation']));

    var goalRows =
      _ctxRow('Goal', goal.type || _pick(p, ['fitness_goal', 'transformation_goal'])) +
      _ctxRow('Current → Target', (goal.currentVal != null && goal.targetVal != null)
        ? goal.currentVal + ' → ' + goal.targetVal + ' ' + (goal.unit || '') : null) +
      _ctxRow('Duration', p.goal_duration_months ? p.goal_duration_months + ' months' : null) +
      _ctxRow('Target Body Fat', p.target_body_fat_pct ? p.target_body_fat_pct + '%' : null) +
      _ctxRow('Biggest Struggle', p.biggest_struggle);

    var assessRows =
      _ctxRow('Activity Level',  p.activity_level) +
      _ctxRow('Fitness Level',   p.fitness_level) +
      _ctxRow('Diet Preference', p.diet_preference) +
      _ctxRow('Workout Preference', p.workout_preference) +
      _ctxRow('Available Time',  p.available_time) +
      _ctxRow('Sleep',  _pick(p, ['sleep_hours', 'sleep', 'sleepHours'])) +
      _ctxRow('Stress Level', p.stress_level) +
      _ctxRow('Budget', _pick(p, ['budget', 'daily_budget'])) +
      _ctxRow('⚕️ Medical Conditions', _pick(p, ['medical_conditions', 'health_conditions']) || 'None reported');

    var targetRows =
      _ctxRow('BMI',  _pick(calc, ['bmi'])) +
      _ctxRow('BMR',  _pick(calc, ['bmr']) ? _pick(calc, ['bmr']) + ' kcal' : null) +
      _ctxRow('TDEE', _pick(calc, ['tdee']) ? _pick(calc, ['tdee']) + ' kcal' : null) +
      _ctxRow('Calorie Target', _pick(calc, ['daily_calories', 'calorie_target', 'target_calories', 'calories'])) +
      _ctxRow('Protein Target', _pick(calc, ['protein_target', 'protein_g', 'daily_protein', 'protein'])) +
      _ctxRow('Water Target',   _pick(calc, ['water_liters', 'water_target', 'hydration_liters'])) +
      _ctxRow('Steps Target',   _pick(calc, ['daily_steps', 'steps_target', 'steps']));

    var html =
      _ctxSection('👤 User Information', userRows) +
      _ctxSection('🎯 Goal Summary', goalRows) +
      _ctxSection('📋 Assessment Summary', assessRows) +
      _ctxSection('🧮 Nutrition Targets', targetRows);
    if (!html) return null;

    var panel = document.createElement('div');
    panel.className = 'mp-ctx-panel';
    panel.innerHTML =
      '<div class="mp-ctx-head">' +
        '<span>User Profile &amp; Assessment</span>' +
        '<button class="mp-ctx-toggle" id="mpCtxToggle" type="button">Hide</button>' +
      '</div>' +
      '<div class="mp-ctx-body" id="mpCtxBody">' + html + '</div>';
    panel.querySelector('#mpCtxToggle').addEventListener('click', function () {
      var b = panel.querySelector('#mpCtxBody');
      var hidden = b.style.display === 'none';
      b.style.display = hidden ? '' : 'none';
      this.textContent = hidden ? 'Hide' : 'Show';
    });
    return panel;
  }

  function buildNotesPanel(review) {
    var wrap = document.createElement('div');
    wrap.className = 'mp-notes-panel';
    wrap.innerHTML =
      '<p class="mp-ctx-title">📝 Review Notes for the User</p>' +
      '<textarea class="mp-notes-input" id="mpNotes" rows="3" ' +
        'placeholder="Optional — explain your changes, add guidance (the user sees this with the reviewed plan)…"></textarea>';
    wrap.querySelector('#mpNotes').value = review.expertNotes || '';
    return wrap;
  }
  function getExpertNotes() {
    var el = document.getElementById('mpNotes');
    return el ? el.value.trim() : '';
  }

  function renderPlan(days) {
    var body = document.getElementById('mpBody');
    if (!body) return;
    body.innerHTML = '';

    if (!days.length) {
      body.innerHTML = '<p style="padding:24px;text-align:center;color:var(--text-muted)">No diet days found in this review.</p>';
      return;
    }

    days.forEach(function (day, di) {
      var card = document.createElement('div');
      card.className = 'mp-day-card';
      card.dataset.di = di;

      var dayLabel = day.day || day.date || ('Day ' + (di + 1));
      var meals    = getMealsFromDay(day);

      var mealsHtml = '';
      var mealKeysInDay = MEAL_KEYS.filter(function (k) { return meals[k]; });
      /* Fallback: if no standard keys found, gather any key that looks like a meal */
      if (!mealKeysInDay.length) {
        mealKeysInDay = Object.keys(meals).filter(function (k) { return meals[k] && typeof meals[k] === 'object' && !Array.isArray(meals[k]); });
      }

      mealKeysInDay.forEach(function (mealKey, mi) {
        var meal  = meals[mealKey] || {};
        var emoji = MEAL_EMOJIS[mealKey] || '🍽️';
        var name  = meal.meal_name || mealKeyName(mealKey);
        var foods = normalizeFoods(meal.foods);

        var foodRows = foods.map(function (food) {
          return '<div class="mp-food-row">' +
            '<input class="mp-food-input" placeholder="Food item" value="' + esc(food) + '"/>' +
            '<button class="mp-food-remove" aria-label="Remove">✕</button>' +
            '</div>';
        }).join('');

        mealsHtml +=
          '<div class="mp-meal-block" data-meal-key="' + esc(mealKey) + '">' +
            '<div class="mp-meal-header">' +
              '<span class="mp-meal-emoji">' + emoji + '</span>' +
              '<input class="mp-meal-name-input" data-field="meal_name" placeholder="Meal name" value="' + esc(name) + '"/>' +
            '</div>' +
            '<div class="mp-foods-list">' + foodRows + '</div>' +
            '<button class="mp-add-food">+ Add food</button>' +
            (mi < mealKeysInDay.length - 1 ? '<div class="mp-meal-divider"></div>' : '') +
          '</div>';
      });

      card.innerHTML = '<div class="mp-day-label">' + esc(dayLabel) + '</div>' + mealsHtml;

      /* Wire remove food buttons */
      card.querySelectorAll('.mp-food-remove').forEach(function (btn) {
        btn.addEventListener('click', function () { btn.closest('.mp-food-row').remove(); });
      });

      /* Wire add food buttons */
      card.querySelectorAll('.mp-add-food').forEach(function (addBtn) {
        addBtn.addEventListener('click', function () {
          var row = document.createElement('div');
          row.className = 'mp-food-row';
          row.innerHTML =
            '<input class="mp-food-input" placeholder="Food item" value=""/>' +
            '<button class="mp-food-remove" aria-label="Remove">✕</button>';
          row.querySelector('.mp-food-remove').addEventListener('click', function () { row.remove(); });
          addBtn.closest('.mp-meal-block').querySelector('.mp-foods-list').appendChild(row);
          row.querySelector('.mp-food-input').focus();
        });
      });

      body.appendChild(card);
    });
  }

  /* ── Collect form → edited plan ── */

  function collectEdited() {
    var days = [];
    document.querySelectorAll('.mp-day-card').forEach(function (card, di) {
      var origDay = origDays[di] || {};
      var dayLabel = origDay.day || origDay.date || ('Day ' + (di + 1));
      var origMeals = getMealsFromDay(origDay);
      var meals = {};

      card.querySelectorAll('.mp-meal-block').forEach(function (block) {
        var mealKey = block.dataset.mealKey;
        if (!mealKey) return;
        var nameInput = block.querySelector('[data-field="meal_name"]');
        var mealName  = nameInput ? nameInput.value.trim() : mealKeyName(mealKey);
        var origMeal  = origMeals[mealKey] || {};
        var foods     = [];
        block.querySelectorAll('.mp-food-input').forEach(function (inp) {
          var v = inp.value.trim();
          if (v) foods.push(v);
        });

        var edited = JSON.stringify(foods) !== JSON.stringify(normalizeFoods(origMeal.foods)) ||
                     mealName !== (origMeal.meal_name || mealKeyName(mealKey));

        meals[mealKey] = Object.assign({}, origMeal, {
          meal_name: mealName,
          foods:     foods,
          _mealKey:  mealKey,
          _edited:   edited ? true : undefined,
        });
        if (!edited) delete meals[mealKey]._edited;
      });

      /* Canonical schema: days[].meals is an ARRAY (matches the AI-generated
         plan and expert-dashboard.js's editor) — not an object keyed by
         meal name. This is what the athlete-side acceptExpertPlan() and
         _buildDietStorageFromReview() expect; saving an object here was
         the root cause of the "(revDay.meals || []).forEach is not a
         function" crash on accept. */
      var mealsArray = Object.keys(meals).map(function (k) { return meals[k]; });
      days.push(Object.assign({}, origDay, { day: dayLabel, meals: mealsArray }));
    });
    return { days: days };
  }

  /* ── Build mealChangeHistory ── */

  function buildHistory(editedPlan, expertName) {
    var history = [];
    editedPlan.days.forEach(function (newDay, di) {
      var origDay     = origDays[di] || {};
      var origMeals   = getMealsFromDay(origDay);
      var newMealsArr = Array.isArray(newDay.meals) ? newDay.meals : [];

      newMealsArr.forEach(function (newMeal) {
        if (!newMeal._edited) return;
        var mealKey  = newMeal._mealKey || _mealKeyOf(newMeal.meal_name);
        var origMeal = origMeals[mealKey] || {};
        history.push({
          dayIndex:   di,
          dayName:    newDay.day || ('Day ' + (di + 1)),
          mealKey:    mealKey,
          mealName:   newMeal.meal_name || mealKeyName(mealKey),
          modifiedBy: expertName || 'Expert',
          modifiedAt: new Date().toISOString(),
          oldMeal:    origMeal,
          newMeal:    newMeal,
        });
      });
    });
    return history;
  }

  /* ── Live athlete data ──
     users/{uid} is the documented single source of truth for the
     athlete's plan + assessment. The expert reviews the user's
     CURRENT state, not the snapshot frozen into the request at submit
     time — the snapshot remains only as (a) an immutable record of what
     was submitted and (b) the fallback for legacy requests without a
     userId or when the fetch fails. One-shot get(), deliberately not a
     live listener: the plan must not mutate under the expert mid-edit. */
  function _fetchLiveAthlete(rev) {
    if (typeof ZitlasDB === 'undefined' || !rev.userId) return Promise.resolve(null);
    return ZitlasDB.collection('users').doc(rev.userId).get()
      .then(function (snap) {
        var data = snap.exists ? snap.data() : null;
        console.log('[MODIFY-DIET] live athlete data', data ? 'loaded from users/' + rev.userId : 'not found — using request snapshot');
        return data;
      })
      .catch(function (e) {
        console.warn('[MODIFY-DIET] live athlete fetch failed — using request snapshot', e);
        return null;
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

    var athleteEl = document.getElementById('mpAthleteName');
    if (athleteEl) athleteEl.textContent = review.athleteName || review.userName || 'Athlete';

    _fetchLiveAthlete(review).then(function (live) {
      /* Plan-to-edit priority:
         1. reviewedDietPlan — the expert's own saved work-in-progress
            always wins (never discard their edits).
         2. the athlete's LIVE current plan (users/{uid}.dietPlan,
            unwrapped) — what the athlete is actually eating today.
         3. the request's planData snapshot — legacy fallback. */
      if (review.reviewedDietPlan && review.reviewedDietPlan.days) {
        origDays = review.reviewedDietPlan.days;
      } else {
        var liveDays = live ? extractDays(live.dietPlan) : [];
        origDays = liveDays.length ? liveDays : extractDays(review.planData);
      }

      renderPlan(origDays);

      /* Athlete context above the plan, Review Notes below it — both inside
         the scroll container, both outside collectEdited()'s .mp-day-card
         query so plan collection is untouched. */
      var _mpBody = document.getElementById('mpBody');
      if (_mpBody) {
        var _ctxPanel = buildContextPanel(review, live);
        if (_ctxPanel) _mpBody.insertBefore(_ctxPanel, _mpBody.firstChild);
        _mpBody.appendChild(buildNotesPanel(review));
      }
    });

    document.getElementById('mpBack').addEventListener('click', function () {
      window.location.href = 'expert-dashboard.html';
    });

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
        (review.reviewType || review.planReviewType || 'diet'));

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
      var notes   = getExpertNotes();
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
        reviewedDietPlan:  edited,
        mealChangeHistory: history,
        expertNotes:       notes,
        savedAt:           nowIso,
      }).then(function () {
        console.log('[REVIEW COMPLETE] expert plan save success');
        /* Local echo only AFTER the server has it. */
        patchReview(reviewId, {
          reviewedDietPlan:  edited,
          mealChangeHistory: history,
          expertNotes:       notes,
          savedAt:           nowIso,
        });

        /* 2. Athlete's active plan. */
        console.log('[REVIEW COMPLETE] updating athlete plan');
        var fresh = getReview(reviewId) || review;
        return applyReviewedDietToAthlete(fresh, expertName, nowIso);
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
          expertNotes:     notes,
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
                          ' has finished reviewing your diet plan.',
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
