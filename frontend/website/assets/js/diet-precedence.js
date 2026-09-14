/*!
 * ZITLAS — THE diet precedence rule (assets/js/diet-precedence.js)
 *
 * Which diet is the athlete's current diet? One answer, shared with the app:
 * mobile/lib/features/diet/diet_precedence.dart implements the identical
 * rule, and both are pinned by ONE fixture —
 * tests/fixtures/diet_precedence_cases.json — run by the JS and Dart tests.
 *
 *   1. 'coach'     — the active Personal Coaching diet, when ALL hold:
 *                      relationship status 'active';
 *                      its end date (endDateTs, else endDate) absent or in
 *                        the future;
 *                      it covers diet (planType diet / complete; a free
 *                        trial's null planType is full coverage);
 *                      coaching_plans/{uid}.diet has at least one meal;
 *                      the plan belongs to the current coach (a stored
 *                        coachId that differs from the relationship's is
 *                        a previous coach's leftover);
 *                      NOT (plan planId AND live planId both present AND
 *                        different) — a null planId is allowed.
 *   2. 'expert'    — users/{uid}.dietPlan is an accepted/applied expert-
 *                    reviewed wrapper, stamped with a planId that does not
 *                    contradict the live one (an UNSTAMPED expert layer
 *                    cannot prove which goal it belongs to and is refused).
 *   3. 'ai'        — users/{uid}.dietPlan as the AI plan (wrapper without an
 *                    expert layer, or a legacy flat {days:[...]}).
 *   4. 'ai_master' — users/{uid}.dietPlanMaster, the recovery copy.
 *   5. 'none'.
 *
 * SERVER DATA ONLY. Callers pass Firestore state (live listeners / the
 * hydrated users/{uid} mirror); a localStorage copy is never an input, so a
 * stale cache can never outrank what the server holds. Timestamps are not
 * compared: the relationship decides, which is deterministic across clients
 * and clocks.
 */
(function (root) {
  'use strict';

  var DIET_PLAN_TYPES = { diet: true, complete: true };

  function toDate(v) {
    if (!v) return null;
    if (v instanceof Date) return isNaN(v.getTime()) ? null : v;
    if (typeof v.toDate === 'function') {
      try { var d0 = v.toDate(); return isNaN(d0.getTime()) ? null : d0; } catch (_) { return null; }
    }
    if (typeof v.seconds === 'number') return new Date(v.seconds * 1000);
    if (typeof v === 'string') {
      var d = new Date(v);
      return isNaN(d.getTime()) ? null : d;
    }
    return null;
  }

  function text(v) {
    return (typeof v === 'string' && v.trim()) ? v.trim() : null;
  }

  function mealsOf(day) {
    var m = day && day.meals;
    if (Array.isArray(m)) return m;
    if (m && typeof m === 'object') return Object.keys(m).map(function (k) { return m[k]; });
    return [];
  }

  /* A meal counts when it has a name — the same test both clients' parsers
     apply before rendering a coach meal at all. */
  function countMeals(plan) {
    var days = plan && Array.isArray(plan.days) ? plan.days : [];
    var n = 0;
    days.forEach(function (d) {
      mealsOf(d).forEach(function (meal) {
        if (meal && text(meal.name || meal.meal_name)) n++;
      });
    });
    return n;
  }

  function hasDays(plan) {
    return !!(plan && Array.isArray(plan.days) && plan.days.length);
  }

  /* The plan-id safety rule: only two PRESENT ids that differ disagree. */
  function contradicts(a, b) {
    a = text(a); b = text(b);
    return !!(a && b && a !== b);
  }

  function isWrapper(p) {
    return !!(p && typeof p === 'object' && p.originalDietPlan && p.currentDietPlan);
  }

  function hasExpertLayer(w) {
    if (w.isExpertPlan === true) return true;
    var mods = w.expertModifications;
    if (!mods || typeof mods !== 'object') return false;
    return Object.keys(mods).some(function (k) {
      var v = mods[k];
      return !!(v && typeof v === 'object' && Object.keys(v).length);
    });
  }

  /* Raw Firestore-shaped state -> the handful of facts the rule reads. */
  function normalize(state) {
    state = state || {};
    var rel = state.relationship || null;
    var cp = state.coachingPlan || null;
    var diet = cp && cp.diet;
    var dp = state.dietPlan || null;
    var master = state.dietPlanMaster || null;
    /* Masters are written as {planId, plan: {days}}; tolerate a flat one. */
    var masterPlan = master
      ? (master.plan && Array.isArray(master.plan.days) ? master.plan : master)
      : null;
    var wrapper = isWrapper(dp) ? dp : null;
    return {
      now: toDate(state.now) || new Date(),
      livePlanId: text(state.livePlanId),
      rel: rel ? {
        status: rel.status || null,
        coachId: text(rel.coachId),
        planType: text(rel.planType),
        end: toDate(rel.endDateTs) || toDate(rel.endDate),
      } : null,
      coach: cp ? {
        coachId: text(cp.coachId),
        planId: diet ? text(diet.planId) : null,
        meals: countMeals(diet),
      } : null,
      wrapper: wrapper ? {
        planId: text(wrapper.planId),
        expert: hasExpertLayer(wrapper),
        hasDays: hasDays(wrapper.currentDietPlan) || hasDays(wrapper.originalDietPlan),
      } : null,
      legacyFlat: !wrapper && hasDays(dp),
      master: masterPlan && hasDays(masterPlan) ? { planId: text(master.planId) } : null,
    };
  }

  function coachActiveN(n) {
    var r = n.rel, c = n.coach;
    if (!r || r.status !== 'active') return false;
    if (r.end && r.end.getTime() <= n.now.getTime()) return false;
    if (!DIET_PLAN_TYPES[r.planType || 'complete']) return false;
    if (!c || c.meals < 1) return false;
    if (c.coachId && r.coachId && c.coachId !== r.coachId) return false;
    if (contradicts(c.planId, n.livePlanId)) return false;
    return true;
  }

  /* 'expert' | 'ai' | null — the users/{uid}.dietPlan wrapper's standing. */
  function wrapperVerdictN(n) {
    var w = n.wrapper;
    if (!w || !w.hasDays) return null;
    if (contradicts(w.planId, n.livePlanId)) return null;
    if (w.expert) return w.planId ? 'expert' : null;
    return 'ai';
  }

  function selectDietSource(state) {
    var n = normalize(state);
    if (coachActiveN(n)) return 'coach';
    var verdict = wrapperVerdictN(n);
    if (verdict) return verdict;
    if (n.legacyFlat) return 'ai';
    if (n.master && !contradicts(n.master.planId, n.livePlanId)) return 'ai_master';
    return 'none';
  }

  var api = {
    selectDietSource: selectDietSource,
    coachDietActive: function (state) { return coachActiveN(normalize(state)); },
    wrapperVerdict: function (state) { return wrapperVerdictN(normalize(state)); },
    normalize: normalize,
  };
  root.ZitlasDietPrecedence = api;
})(typeof window !== 'undefined' ? window : this);
