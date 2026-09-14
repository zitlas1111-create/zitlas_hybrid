/**
 * ZITLAS — who may change an athlete's diet, and when "done" is true
 * (tests/js/coaching-diet-authority.test.mjs)
 *
 * 1. THE COACHING WORKSPACE saves a coach's diet only through the backend —
 *    POST /api/coaching-plans/{athleteId}/diet with the version the draft
 *    started from. A 409 (another tab/device saved first) stops auto-save,
 *    says the plan was NOT saved, and offers the latest version. The server,
 *    not this page, notifies the athlete after its commit.
 * 2. THE EXPERT DASHBOARD'S Complete Review applies the athlete's plan through
 *    POST /api/review/apply and marks the review completed only after the
 *    server confirmed it — the real _completeDietReview() runs here against
 *    the real assets/js/diet-review.js with a stubbed server.
 * 3. MODIFY-DIET writes history in the canonical flat shape, and completes a
 *    review only on a completable apply outcome.
 *
 * Run:  node tests/js/coaching-diet-authority.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const read = (...p) => readFileSync(join(WEB, ...p), 'utf8');

const WS = read('components', 'coaching-workspace.js');
const DASH = read('pages', 'experts', 'expert-dashboard.js');
const MODIFY = read('pages', 'experts', 'modify-diet.js');
const REVIEW_SRC = read('assets', 'js', 'diet-review.js');

const clone = (v) => JSON.parse(JSON.stringify(v));
const quiet = { log() {}, warn() {}, error() {} };

/** The real function from the shipping file (including an `async` prefix). */
function extractFn(src, name) {
  let start = src.indexOf(`function ${name}(`);
  assert.ok(start !== -1, `${name}() not found — did it get renamed?`);
  if (src.slice(Math.max(0, start - 6), start) === 'async ') start -= 6;
  let depth = 0, i = src.indexOf('{', start);
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) break;
  }
  return src.slice(start, i + 1);
}

function context(globals) {
  const ctx = Object.assign({ console: quiet }, globals);
  vm.createContext(ctx);
  return ctx;
}

const respond = (status, data) => () => Promise.resolve({ status, json: () => Promise.resolve(data) });

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

/* ── 1. Coaching workspace ────────────────────────────────────────────── */

it('the workspace saves through POST /api/coaching-plans/{athlete}/diet with the base version', async () => {
  const calls = [];
  const ctx = context({
    getIdToken: () => Promise.resolve('tok'),
    fetch: (url, init) => { calls.push({ url, init }); return respond(200, { success: true, dietVersion: 8 })(); },
  });
  vm.runInContext(extractFn(WS, '_postCoachDiet'), ctx);

  const r = clone(await ctx._postCoachDiet('athlete 1', { days: [{ day: 'Monday', meals: [] }] }, 7));

  assert.deepEqual(r, { status: 200, data: { success: true, dietVersion: 8 } });
  assert.equal(calls[0].url, '/api/coaching-plans/athlete%201/diet');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers.Authorization, 'Bearer tok');
  assert.deepEqual(JSON.parse(calls[0].init.body),
    { diet: { days: [{ day: 'Monday', meals: [] }] }, baseVersion: 7 });
});

it('the workspace reads a non-JSON error as a status, and refuses to post without auth', async () => {
  const ctx = context({
    getIdToken: () => Promise.resolve('tok'),
    fetch: () => Promise.resolve({ status: 502, json: () => Promise.reject(new SyntaxError('html')) }),
  });
  vm.runInContext(extractFn(WS, '_postCoachDiet'), ctx);
  assert.deepEqual(clone(await ctx._postCoachDiet('a', { days: [] }, 0)), { status: 502, data: {} });

  const noAuth = context({ fetch: () => assert.fail('must not post') });
  vm.runInContext(extractFn(WS, '_postCoachDiet'), noAuth);
  await assert.rejects(noAuth._postCoachDiet('a', { days: [] }, 0), /no_auth/);
});

it('409: auto-save stops, the coach is told it was NOT saved, and the editor re-renders', () => {
  const seen = { cancelled: [], status: [], toasts: [], renders: 0 };
  const ctx = context({
    S: { dietConflict: false, tab: 'diet' },
    _cancelAutoSave: (k) => seen.cancelled.push(k),
    _setSaveStatus: (k, s) => seen.status.push([k, s]),
    toast: (m) => seen.toasts.push(m),
    renderDietEditor: () => { seen.renders++; },
  });
  vm.runInContext(extractFn(WS, '_dietConflict'), ctx);

  ctx._dietConflict({ error: 'stale_version', baseVersion: 6, currentVersion: 7 });

  assert.equal(ctx.S.dietConflict, true);
  assert.deepEqual(seen.cancelled, ['diet']);
  assert.deepEqual(seen.status, [['diet', 'conflict']]);
  assert.match(seen.toasts[0], /v7/);
  assert.match(seen.toasts[0], /NOT saved/);
  assert.equal(seen.renders, 1);
});

it('"Load latest version" drops the stale draft and clears the conflict', () => {
  let renders = 0;
  const toasts = [];
  const ctx = context({
    S: { dietConflict: true, dietDraft: { days: [] }, dietDirty: true, dietDraftSeeded: true },
    renderDietEditor: () => { renders++; },
    toast: (m) => toasts.push(m),
  });
  vm.runInContext(extractFn(WS, '_loadLatestDiet'), ctx);

  ctx._loadLatestDiet();

  assert.equal(ctx.S.dietConflict, false);
  assert.equal(ctx.S.dietDraft, null);
  assert.equal(ctx.S.dietDirty, false);
  assert.equal(ctx.S.dietDraftSeeded, false);
  assert.equal(renders, 1);
  assert.equal(toasts.length, 1);
});

it('saveDiet never retries a conflicted draft, sends the base version, and routes 409 to the conflict UI', () => {
  const fn = extractFn(WS, 'saveDiet');
  const guard = fn.indexOf('if (S.dietConflict)');
  const post = fn.indexOf('_postCoachDiet(S.opts.athleteId, draft, baseVersion)');
  assert.ok(guard > 0 && post > guard, 'the conflict guard runs before any request');
  assert.match(fn, /r\.status === 409\) \{ _dietConflict\(/);
  assert.match(fn, /S\.dietBaseVersion = savedVersion/);
  assert.doesNotMatch(fn, /collection\('coaching_plans'\)/, 'no client write of the plan — the server is the authority');
  assert.doesNotMatch(fn, /collection\('versions'\)/);
  assert.match(fn, /if \(pendingReqs\.length\) notify\(/,
    "the diet-updated notification is the server's, after its commit");
});

it('the conflict banner offers the latest version, and a newer stored version drops a clean draft', () => {
  assert.match(WS, /id="cwDietReload"/);
  assert.match(WS, /reloadBtn\.addEventListener\('click', _loadLatestDiet\)/);
  assert.match(WS, /if \(S\.dietDraft && !S\.dietDirty && !S\.saving && _dietVersionOf\(S\.plan\) !== S\.dietBaseVersion\)/);
});

it('the stored diet version is read tolerantly', () => {
  const ctx = context({});
  vm.runInContext(extractFn(WS, '_dietVersionOf'), ctx);
  assert.equal(ctx._dietVersionOf({ dietVersion: 3 }), 3);
  assert.equal(ctx._dietVersionOf({ dietVersion: '4' }), 4, 'the website once stored it as a string');
  assert.equal(ctx._dietVersionOf({ dietVersion: 2.9 }), 2);
  assert.equal(ctx._dietVersionOf({ dietVersion: 'x' }), 0);
  assert.equal(ctx._dietVersionOf({ dietVersion: -2 }), 0);
  assert.equal(ctx._dietVersionOf(null), 0);
});

it("the workspace uses the shared plan-id rule: only two present, different ids disagree", () => {
  const withLive = (planId) => {
    const ctx = context({ athleteCtx: () => ({ planId }) });
    vm.runInContext(extractFn(WS, 'coachDietPlanIsCurrent'), ctx);
    return ctx.coachDietPlanIsCurrent;
  };
  assert.equal(withLive('plan-live')({ planId: null }), true);
  assert.equal(withLive(null)({ planId: 'plan-live' }), true);
  assert.equal(withLive('plan-live')({ planId: 'plan-live' }), true);
  assert.equal(withLive('plan-live')({ planId: 'plan-old' }), false);
  assert.equal(withLive('plan-live')(null), false);
});

/* ── 2. Expert dashboard: Complete Review ─────────────────────────────── */

const EDITED = {
  days: [{
    day: 'Monday',
    meals: [{ meal_name: 'Egg Bhurji', foods: ['2 eggs'], calories: 300, protein_g: 20, carbs_g: 10, time: '08:00', _edited: true }],
  }],
};
const ALL = [{
  id: 'rev_1', userId: 'athlete-1', planId: 'plan-live', reviewType: 'diet',
  planData: { days: [{ day: 'Monday', meals: [{ meal_name: 'Poha', foods: ['Poha'], calories: 350, protein_g: 10 }] }] },
}];
const EXPERT = { id: 'expert-7', name: 'Dr. Meera' };

function dashboard({ fetchImpl = respond(200, { success: true, applied: true }), updateImpl = () => Promise.resolve(), offline = false } = {}) {
  const updates = [];
  const toasts = [];
  const marked = [];
  const posts = [];
  const local = new Map();
  const globals = {
    localStorage: {
      getItem: (k) => (local.has(k) ? local.get(k) : null),
      setItem: (k, v) => local.set(k, v),
      removeItem: (k) => local.delete(k),
    },
    edShowToast: (m) => toasts.push(m),
    buildMealChangeHistory: () => [{ dayIndex: 0, mealName: 'Egg Bhurji' }],
    _markPlanReviewCardCompleted: (card) => marked.push(card),
    ZitlasAuth: { currentUser: { getIdToken: () => Promise.resolve('expert-token') } },
    fetch: (url, init) => { posts.push({ url, body: JSON.parse(init.body), auth: init.headers.Authorization }); return fetchImpl(); },
  };
  if (!offline) {
    globals.ZitlasDB = {
      collection: (c) => ({
        doc: (id) => ({
          update: (patch) => { updates.push({ c, id, patch: clone(patch) }); return updateImpl(updates.length); },
        }),
      }),
    };
  }
  const ctx = context(globals);
  ctx.window = ctx;
  vm.runInContext(REVIEW_SRC, ctx);
  vm.runInContext(extractFn(DASH, '_completeDietReview'), ctx);
  const card = { _editedPlan: clone(EDITED), _saveChangesBtn: { disabled: false, textContent: 'Complete Review' } };
  const run = () => ctx._completeDietReview('rev_1', clone(ALL), 0, card, EXPERT);
  return { ctx, run, card, updates, toasts, marked, posts, messages: ctx.ZitlasDietReview.APPLY_MESSAGES };
}

it('Complete Review: the server applies the plan BEFORE the review is marked completed', async () => {
  const h = dashboard();
  assert.equal(await h.run(), true);

  assert.equal(h.updates.length, 2);
  assert.ok(!('status' in h.updates[0].patch), 'the edit save leaves the status alone');
  assert.deepEqual(h.updates[0].patch.reviewedDietPlan, EDITED);
  assert.equal(h.posts.length, 1);
  assert.equal(h.posts[0].url, '/api/review/apply');
  assert.equal(h.posts[0].auth, 'Bearer expert-token');
  assert.equal(h.posts[0].body.athleteUid, 'athlete-1');
  assert.deepEqual(h.posts[0].body.wrapper.currentDietPlan, EDITED, 'the complete reviewed plan, not a rebuild');
  const status = h.updates[1].patch;
  assert.equal(status.status, 'review_completed');
  assert.equal(status.autoApplied, true);
  assert.equal(status.athleteAccepted, true);
  assert.equal(h.toasts.at(-1), h.messages.applied);
  assert.equal(h.marked.length, 1);
});

it('Complete Review: a planId mismatch completes it for the athlete to Accept', async () => {
  const h = dashboard({ fetchImpl: respond(200, { success: true, applied: false, reason: 'planid_mismatch' }) });
  assert.equal(await h.run(), true);
  const status = h.updates[1].patch;
  assert.equal(status.status, 'review_completed');
  assert.equal(status.autoApplied, false);
  assert.equal(status.athleteAccepted, false, 'the Accept banner must still reach the athlete');
  assert.equal(h.toasts.at(-1), h.messages.planid_mismatch);
});

for (const [label, fetchImpl, outcome] of [
  ['a server error', respond(500, {}), 'server'],
  ['an expired session', respond(401, { detail: 'Invalid token' }), 'auth'],
  ['a wrong expert', respond(403, { detail: 'not_assigned_expert' }), 'forbidden'],
  ['no connection', () => Promise.reject(new TypeError('Failed to fetch')), 'network'],
]) {
  it(`Complete Review: ${label} leaves the review pending and says why`, async () => {
    const h = dashboard({ fetchImpl });
    assert.equal(await h.run(), false);
    assert.equal(h.updates.length, 1, 'only the edit save — the status is never written');
    assert.equal(h.toasts.at(-1), h.messages[outcome]);
    assert.equal(h.marked.length, 0);
    assert.equal(h.card._saveChangesBtn.disabled, false, 'the expert can retry');
    assert.equal(h.card._saveChangesBtn.textContent, 'Complete Review');
  });
}

it('Complete Review: a failed edit save stops before anything is applied', async () => {
  const h = dashboard({ updateImpl: () => Promise.reject(new Error('permission-denied')) });
  assert.equal(await h.run(), false);
  assert.equal(h.posts.length, 0);
  assert.match(h.toasts.at(-1), /NOT received/);
});

it('Complete Review: a failed status write after the apply is reported, not hidden', async () => {
  const h = dashboard({ updateImpl: (n) => (n === 2 ? Promise.reject(new Error('unavailable')) : Promise.resolve()) });
  assert.equal(await h.run(), false);
  assert.match(h.toasts.at(-1), /plan is live/);
  assert.equal(h.marked.length, 0);
});

it('Complete Review: offline, nothing is attempted', async () => {
  const h = dashboard({ offline: true });
  assert.equal(await h.run(), false);
  assert.equal(h.posts.length, 0);
  assert.match(h.toasts.at(-1), /offline/);
});

it('every diet completion path goes through the honest one', () => {
  assert.match(extractFn(DASH, 'savePlanEdits'),
    /if \(!_isWorkoutReview\) return _completeDietReview\(reviewId, all, idx, card, expert\);/);
  assert.match(extractFn(DASH, '_prCompleteReviewFromChat'),
    /savePlanEdits\(review\.id, _prEditCard, expert\)\.then\(function \(done\) \{\s*if \(done\) _prFinishChatCompletion\(/);
  assert.match(DASH, /savePlanEdits\(prId, card, expert\);\s*return;/);
});

/* ── 3. modify-diet.js ────────────────────────────────────────────────── */

it('modify-diet writes history in the canonical flat shape', () => {
  const key = (n) => String(n || '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '_');
  const ctx = context({
    origDays: [{ day: 'Monday', meals: [{ meal_name: 'Breakfast', foods: ['Poha'], calories: 350, protein_g: 10 }] }],
    _mealKeyOf: key,
    getMealsFromDay: (day) => Object.fromEntries((day.meals || []).map((m) => [key(m.meal_name), m])),
    normalizeFoods: (f) => (Array.isArray(f) ? f.map(String) : []),
    mealKeyName: (k) => k,
  });
  vm.runInContext(extractFn(MODIFY, 'buildHistory'), ctx);

  const history = clone(ctx.buildHistory({
    days: [{
      day: 'Monday',
      meals: [
        { meal_name: 'Breakfast', foods: ['2 eggs bhurji'], calories: 380, protein_g: 24, notes: 'More protein', _edited: true },
        { meal_name: 'Lunch', foods: ['Dal'], calories: 500 },
      ],
    }],
  }, 'Dr. Meera'));

  assert.equal(history.length, 1, 'only edited meals are recorded');
  const r = history[0];
  assert.ok(!('oldMeal' in r) && !('newMeal' in r), 'new writes never use the older nested shape');
  assert.deepEqual(
    [r.dayIndex, r.dayLabel, r.mealIndex, r.mealKey, r.mealName],
    [0, 'Monday', 0, 'breakfast', 'Breakfast']);
  assert.deepEqual([r.oldFoods, r.newFoods], [['Poha'], ['2 eggs bhurji']]);
  assert.deepEqual([r.oldCalories, r.newCalories, r.oldProtein, r.newProtein], [350, 380, 10, 24]);
  assert.equal(r.reason, 'More protein');
  assert.equal(r.modifiedBy, 'Dr. Meera');
  assert.ok(r.modifiedAt);
});

it('modify-diet applies the COMPLETE plan server-side, and skips a legacy request without a userId', async () => {
  const posts = [];
  const ctx = context({
    reviewId: 'rev_1',
    getExpertNotes: () => 'Swap poha for eggs',
    ZitlasAuth: { currentUser: { getIdToken: () => Promise.resolve('expert-token') } },
    fetch: (url, init) => { posts.push({ url, body: JSON.parse(init.body) }); return respond(200, { success: true, applied: true })(); },
  });
  ctx.window = ctx;
  vm.runInContext(REVIEW_SRC, ctx);
  vm.runInContext(extractFn(MODIFY, 'buildAppliedDietWrapper') + '\n' + extractFn(MODIFY, 'applyReviewedDietToAthlete'), ctx);

  const legacy = clone(await ctx.applyReviewedDietToAthlete({ id: 'rev_1', reviewedDietPlan: EDITED }, 'Dr. Meera', 'now'));
  assert.equal(legacy.outcome, 'not_applicable');
  assert.equal(posts.length, 0, 'nothing is sent for a legacy request');

  const out = clone(await ctx.applyReviewedDietToAthlete(
    { id: 'rev_1', userId: 'athlete-1', planId: 'plan-live', reviewedDietPlan: EDITED }, 'Dr. Meera', '2026-09-13T09:00:00.000Z'));
  assert.equal(out.outcome, 'applied');
  assert.equal(posts[0].url, '/api/review/apply');
  assert.deepEqual(posts[0].body.wrapper.currentDietPlan, EDITED);
  assert.equal(posts[0].body.wrapper.planId, 'plan-live');
  assert.equal(posts[0].body.wrapper.expertNotes, 'Swap poha for eggs');
});

it('modify-diet completes a review only after a completable apply outcome', () => {
  const start = MODIFY.indexOf('return applyReviewedDietToAthlete(fresh, expertName, nowIso);');
  const gate = MODIFY.indexOf('if (!ZitlasDietReview.isCompletable(outcome))', start);
  const status = MODIFY.indexOf("status:          'review_completed'", start);
  assert.ok(start > 0 && gate > start && status > gate, 'apply, then the gate, then the status write');
  assert.match(MODIFY, /applyErr\.userMessage = ZitlasDietReview\.APPLY_MESSAGES\[outcome\];\s*throw applyErr;/);
  assert.match(MODIFY, /var applied = outcome === 'applied';/);
  assert.match(MODIFY, /autoApplied: {5}!!applied,/);
  assert.match(MODIFY, /showToast\(\(err && err\.userMessage\) \|\|/, 'the failure says exactly why');
});

/* ── Runner ───────────────────────────────────────────────────────────── */

let failed = 0;
for (const [name, fn] of tests) {
  try {
    await fn();
    console.log('  ✓ ' + name);
  } catch (e) {
    failed++;
    console.log('  ✗ ' + name + '\n    ' + ((e && e.stack) || e));
  }
}
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed ? 1 : 0);
