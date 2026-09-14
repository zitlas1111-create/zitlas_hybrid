/*!
 * ZITLAS — Expert-reviewed diet plans (assets/js/diet-review.js)
 *
 * Shared by every page that touches an expert review:
 *   diet.js / cprofile.js   — the athlete's Accept
 *   modify-diet.js / expert-dashboard.js — the expert's Complete Review
 *
 * 1. LOSSLESS ACCEPT. buildAcceptedStorage() stores the expert's COMPLETE
 *    reviewed plan as `currentDietPlan`. Nothing is rebuilt by matching meal
 *    names, so renamed / added / deleted meals, carbs, fats, timing, notes
 *    and day-level fields all survive. `expertModifications` is kept only for
 *    the "✏️ Modified by Expert" badges: each entry's newMeal IS the reviewed
 *    meal, so both clients' buildEffectivePlan() applying it changes nothing.
 *
 * 2. ONE READING OF REVIEW HISTORY. Records are either the canonical flat
 *    shape (oldFoods/newFoods/oldCalories/…, written by expert-dashboard.js,
 *    the app and — from now on — modify-diet.js) or the older modify-diet.js
 *    shape (oldMeal/newMeal objects). normalizeHistoryEntry() reads both.
 *
 * 3. HONEST SERVER APPLY. applyReviewedDiet() calls POST /api/review/apply and
 *    classifies the answer — applied / planid_mismatch / not_applicable /
 *    auth / forbidden / network / server — so no caller can report success
 *    for something the server did not do.
 */
(function (root) {
  'use strict';

  function mealKey(name) {
    return String(name || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_');
  }

  function clone(v) { return v == null ? v : JSON.parse(JSON.stringify(v)); }

  function num(v) {
    if (v === '' || v == null) return null;
    var n = Number(v);
    return isFinite(n) ? n : null;
  }

  function foodsOf(foods) {
    if (!foods) return [];
    if (Array.isArray(foods)) {
      return foods.map(function (f) {
        return typeof f === 'string' ? f : String((f && (f.name || f.item)) || f);
      });
    }
    if (typeof foods === 'string') {
      return foods.split('\n').map(function (s) { return s.trim(); }).filter(Boolean);
    }
    return [];
  }

  function mealsToArray(meals) {
    if (Array.isArray(meals)) return meals;
    if (meals && typeof meals === 'object') {
      return Object.keys(meals).map(function (k) { return meals[k]; });
    }
    return [];
  }

  function unwrapPlan(p) {
    if (p && (p.originalDietPlan || p.currentDietPlan)) return p.currentDietPlan || p.originalDietPlan;
    return p || null;
  }

  /* ── Review history ───────────────────────────────────────────────────── */

  function normalizeHistoryEntry(h) {
    h = h || {};
    var om = (h.oldMeal && typeof h.oldMeal === 'object') ? h.oldMeal : null;
    var nm = (h.newMeal && typeof h.newMeal === 'object') ? h.newMeal : null;
    var dayIndex = h.dayIndex != null ? h.dayIndex : (h.day_index != null ? h.day_index : 0);
    var mealName = h.mealName || h.meal_name || h.name ||
      (nm && (nm.meal_name || nm.name)) || (om && (om.meal_name || om.name)) || 'Meal';
    function pick(flat, snake, meal, field) {
      if (h[flat] != null) return h[flat];
      if (h[snake] != null) return h[snake];
      return meal ? meal[field] : null;
    }
    return {
      dayIndex: Number(dayIndex) || 0,
      mealIndex: h.mealIndex != null ? h.mealIndex : null,
      dayLabel: h.dayLabel || h.dayName || null,
      mealName: mealName,
      mealKey: h.mealKey || mealKey(mealName),
      oldFoods: foodsOf(h.oldFoods || h.old_foods || (om && om.foods)),
      newFoods: foodsOf(h.newFoods || h.new_foods || (nm && nm.foods)),
      oldCalories: num(pick('oldCalories', 'old_calories', om, 'calories')),
      newCalories: num(pick('newCalories', 'new_calories', nm, 'calories')),
      oldProtein: num(pick('oldProtein', 'old_protein', om, 'protein_g')),
      newProtein: num(pick('newProtein', 'new_protein', nm, 'protein_g')),
      reason: h.reason || (nm && nm.notes) || null,
      modifiedBy: h.modifiedBy || h.modified_by || null,
      modifiedAt: h.modifiedAt || h.modified_at || null,
    };
  }

  function normalizeHistory(list) {
    return (Array.isArray(list) ? list : []).map(normalizeHistoryEntry);
  }

  /* ── Lossless Accept ──────────────────────────────────────────────────── */

  function snapshot(meal) {
    return {
      foods: foodsOf(meal && meal.foods),
      calories: meal && meal.calories != null ? meal.calories : null,
      protein_g: meal && meal.protein_g != null ? meal.protein_g : null,
    };
  }

  function findByKey(meals, key) {
    for (var i = 0; i < meals.length; i++) {
      var m = meals[i];
      if (m && (m._mealKey || mealKey(m.meal_name || m.name)) === key) return m;
    }
    return null;
  }

  /* Badges only — see the header. A meal is marked when the expert's editor
     flagged it, or when it differs from (or is absent in) the original. */
  function badgeModifications(reviewed, original, expertName, whenIso) {
    var mods = {};
    (reviewed && reviewed.days || []).forEach(function (day, di) {
      var origDay = original && original.days ? original.days[di] : null;
      var origMeals = origDay ? mealsToArray(origDay.meals) : [];
      mealsToArray(day && day.meals).forEach(function (meal) {
        if (!meal) return;
        var key = meal._mealKey || mealKey(meal.meal_name || meal.name);
        var origMeal = findByKey(origMeals, key);
        var changed = meal._edited === true || (!!original && (!origMeal ||
          JSON.stringify(snapshot(origMeal)) !== JSON.stringify(snapshot(meal))));
        if (!changed) return;
        var dk = String(di);
        mods[dk] = mods[dk] || {};
        mods[dk][key] = {
          modified: true,
          modifiedBy: meal._modifiedBy || expertName,
          modifiedAt: meal._modifiedAt || whenIso,
          oldMeal: origMeal ? snapshot(origMeal) : { foods: [] },
          newMeal: snapshot(meal),
        };
      });
    });
    return mods;
  }

  /* review: a review_requests record (reviewedDietPlan, planData, expert…).
     opts: { originalPlan, currentPlanId, expertNotes, nowIso }.
     Returns the users/{uid}.dietPlan wrapper, or null with no reviewed plan. */
  function buildAcceptedStorage(review, opts) {
    opts = opts || {};
    review = review || {};
    var reviewed = unwrapPlan(review.reviewedDietPlan);
    if (!reviewed || !Array.isArray(reviewed.days) || !reviewed.days.length) return null;
    var current = clone(reviewed);
    current.days = current.days.map(function (d) {
      return Object.assign({}, d, { meals: mealsToArray(d && d.meals) });
    });
    var original = clone(unwrapPlan(opts.originalPlan) || unwrapPlan(review.planData) ||
      unwrapPlan(review.context && review.context.diet_plan)) || null;
    var nowIso = opts.nowIso || new Date().toISOString();
    var expertName = review.expertName || review.expert_name || 'Expert';
    var reviewedAt = review.reviewedAt || nowIso;
    return {
      originalDietPlan:    original || clone(current),
      /* The COMPLETE reviewed plan — the authoritative content. */
      currentDietPlan:     current,
      expertModifications: badgeModifications(current, original, expertName, reviewedAt),
      isExpertPlan:        true,
      expertName:          expertName,
      expertId:            review.expertId || null,
      expertNotes:         review.expertNotes || opts.expertNotes || null,
      reviewedAt:          reviewedAt,
      reviewStatus:        'completed',
      planSource:          'expert_reviewed',
      reviewId:            review.id || review.reviewId || null,
      version:             review.version || 1,
      lastUpdated:         nowIso,
      /* Goal-identity stamp — both clients refuse an expert layer that
         cannot prove which plan generation it belongs to. */
      planId:              review.planId || opts.currentPlanId || null,
      acceptedPlanFormat:  'complete_v1',
    };
  }

  /* ── Honest server apply ──────────────────────────────────────────────── */

  var APPLY_MESSAGES = {
    applied:         "✓ Review completed — the plan is now live on the athlete's account.",
    planid_mismatch: "✓ Review completed. The athlete's plan changed since they asked, " +
                     "so they'll be asked to accept your version.",
    not_applicable:  "✓ Review completed — the athlete will be asked to accept it.",
    auth:            '⚠️ Your session has expired — sign in again. The review was NOT completed.',
    forbidden:       '⚠️ You are not the expert assigned to this review. It was NOT completed.',
    network:         "⚠️ Couldn't reach ZITLAS — the review was NOT completed. " +
                     'Check your connection and retry.',
    server:          "⚠️ The server couldn't apply the plan — the review was NOT completed. Please retry.",
  };

  function classifyApply(status, data) {
    if (status === 200 && data && data.success) {
      if (data.applied === true) return 'applied';
      return data.reason === 'planid_mismatch' ? 'planid_mismatch' : 'not_applicable';
    }
    if (status === 401) return 'auth';
    if (status === 403) return 'forbidden';
    if (!status) return 'network';
    return 'server';
  }

  /* The review may be marked completed only on these outcomes: the plan is
     live, or the server confirmed the athlete's Accept owns delivery. */
  function isCompletable(outcome) {
    return outcome === 'applied' || outcome === 'planid_mismatch' || outcome === 'not_applicable';
  }

  function defaultToken() {
    var auth = root.ZitlasAuth;
    var user = auth && auth.currentUser;
    if (!user || typeof user.getIdToken !== 'function') return Promise.reject(new Error('not_signed_in'));
    return user.getIdToken();
  }

  /* params: {reviewId, athleteUid, wrapper, getIdToken?, fetch?}
     Resolves (never rejects) to {outcome, status, data?}. */
  function applyReviewedDiet(params) {
    params = params || {};
    if (!params.athleteUid || !params.reviewId) {
      return Promise.resolve({ outcome: 'not_applicable', status: null });
    }
    var fetchImpl = params.fetch || (typeof root.fetch === 'function' ? root.fetch.bind(root) : null);
    if (!fetchImpl) return Promise.resolve({ outcome: 'network', status: 0 });
    var tokenFn = params.getIdToken || defaultToken;
    return Promise.resolve().then(tokenFn).then(function (token) {
      return fetchImpl('/api/review/apply', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: JSON.stringify({ reviewId: params.reviewId, athleteUid: params.athleteUid,
                               planType: 'diet', wrapper: params.wrapper }),
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          return { outcome: classifyApply(res.status, data), status: res.status, data: data };
        });
      }, function (e) {
        return { outcome: 'network', status: 0, error: String((e && e.message) || e) };
      });
    }, function () {
      return { outcome: 'auth', status: 401 };
    });
  }

  root.ZitlasDietReview = {
    mealKey: mealKey,
    mealsToArray: mealsToArray,
    normalizeHistoryEntry: normalizeHistoryEntry,
    normalizeHistory: normalizeHistory,
    buildAcceptedStorage: buildAcceptedStorage,
    badgeModifications: badgeModifications,
    applyReviewedDiet: applyReviewedDiet,
    classifyApply: classifyApply,
    isCompletable: isCompletable,
    APPLY_MESSAGES: APPLY_MESSAGES,
  };
})(typeof window !== 'undefined' ? window : this);
