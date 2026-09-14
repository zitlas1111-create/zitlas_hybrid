/**
 * ZITLAS — expert-reviewed diet plans, website side
 * (tests/js/diet-review.test.mjs)
 *
 * 1. LOSSLESS ACCEPT. tests/fixtures/diet_accept_case.json is the SAME case
 *    mobile/test/diet_accept_parity_test.dart runs against the app: both
 *    clients must store exactly its expected currentDietPlan and
 *    expertModifications, and the website must render that wrapper — which is
 *    what the app writes — with every meal and field intact.
 * 2. ONE READING OF REVIEW HISTORY. tests/fixtures/diet_history_cases.json,
 *    also shared with the app.
 * 3. HONEST APPLY. Every /api/review/apply answer maps to one outcome, and
 *    only applied / planid_mismatch / not_applicable may complete a review.
 * 4. ACCEPT IS SAVED ON THE SERVER. The real saveStrict() (cloud-sync.js)
 *    rejects when the cloud write fails, and both Accept paths wait for it —
 *    and refuse a plan they cannot stamp rather than write one that the next
 *    load would discard.
 *
 * Run:  node tests/js/diet-review.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const WEB = join(ROOT, 'frontend', 'website');
const read = (...p) => readFileSync(join(...p), 'utf8');

const REVIEW_SRC = read(WEB, 'assets', 'js', 'diet-review.js');
const CLOUD_SRC = read(WEB, 'assets', 'js', 'cloud-sync.js');
const DIET_SRC = read(WEB, 'pages', 'diet', 'diet.js');
const CPROFILE_SRC = read(WEB, 'pages', 'coaches', 'cprofile.js');
const ACCEPT = JSON.parse(read(ROOT, 'tests', 'fixtures', 'diet_accept_case.json'));
const HISTORY = JSON.parse(read(ROOT, 'tests', 'fixtures', 'diet_history_cases.json'));

/* Objects made inside a vm context carry that realm's prototypes; compare
   plain copies. */
const clone = (v) => JSON.parse(JSON.stringify(v));

function extractFn(src, name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start !== -1, `${name}() not found — did it get renamed?`);
  let depth = 0, i = src.indexOf('{', start);
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) break;
  }
  return src.slice(start, i + 1);
}

const quiet = { log() {}, warn() {}, error() {} };

const reviewCtx = { window: {}, console: quiet };
vm.createContext(reviewCtx);
vm.runInContext(REVIEW_SRC, reviewCtx);
const R = reviewCtx.window.ZitlasDietReview;

/* The website's real renderer (diet.js buildEffectivePlan), on its own. */
const renderCtx = { console: quiet };
vm.createContext(renderCtx);
vm.runInContext(extractFn(DIET_SRC, '_mealKey') + '\n' + extractFn(DIET_SRC, 'buildEffectivePlan'), renderCtx);
const buildEffectivePlan = (storage) => clone(renderCtx.buildEffectivePlan(clone(storage)));

const accept = (review, opts) => clone(R.buildAcceptedStorage(clone(review),
  Object.assign({ currentPlanId: ACCEPT.livePlanId, nowIso: ACCEPT.nowIso }, opts || {})));

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

/* ── 1. Lossless Accept ───────────────────────────────────────────────── */

it("Accept stores exactly the shared fixture's plan and badges", () => {
  const s = accept(ACCEPT.review);
  assert.deepEqual(s.currentDietPlan, ACCEPT.expected.currentDietPlan);
  assert.deepEqual(s.expertModifications, ACCEPT.expected.expertModifications);
  assert.equal(s.planId, ACCEPT.expected.planId);
  assert.equal(s.isExpertPlan, true);
  assert.equal(s.planSource, 'expert_reviewed');
  assert.deepEqual(s.originalDietPlan, ACCEPT.review.planData);
});

it('renamed, added and deleted meals, macros, timing and notes all survive', () => {
  const s = accept(ACCEPT.review);
  const mon = s.currentDietPlan.days[0];
  assert.deepEqual(mon.meals.map((m) => m.meal_name),
    ['Egg Bhurji Breakfast', 'Lunch', 'Dinner', 'Post-workout']);
  assert.ok(!mon.meals.some((m) => m.meal_name === 'Snack'), 'the deleted meal stays deleted');
  assert.equal(mon.meals[0].carbs_g, 30);
  assert.equal(mon.meals[0].fat_g, 16);
  assert.equal(mon.meals[0].time, '08:00');
  assert.equal(mon.meals[0].notes, 'Swap poha for eggs');
  assert.equal(mon.focus, 'High protein');
  assert.equal(s.currentDietPlan.hydration, '3 litres');
  assert.ok(Array.isArray(s.currentDietPlan.days[1].meals), 'an object of meals is stored as a list');
});

it('the website renders the pinned wrapper — what the app writes — unchanged', () => {
  const eff = buildEffectivePlan({
    originalDietPlan: ACCEPT.review.planData,
    currentDietPlan: ACCEPT.expected.currentDietPlan,
    expertModifications: ACCEPT.expected.expertModifications,
    isExpertPlan: true,
    planId: 'plan-live',
  });
  assert.deepEqual(eff.days.map((d) => d.meals.map((m) => m.meal_name)), ACCEPT.expected.effectiveMealNames);
  const mon = eff.days[0].meals;
  assert.equal(mon[0]._expertModified, true);
  assert.equal(mon[1]._expertModified, undefined, 'an unchanged meal gets no badge');
  assert.equal(mon[3]._expertModified, true);
  assert.equal(eff.days[1].meals[1]._expertModified, true);
  /* The badges changed no content. */
  const content = (p) => p.days.map((d) => d.meals.map((m) => ({
    foods: m.foods, calories: m.calories, protein_g: m.protein_g,
    carbs_g: m.carbs_g, fat_g: m.fat_g, time: m.time, notes: m.notes,
  })));
  assert.deepEqual(content(eff), content(ACCEPT.expected.currentDietPlan));
});

it('Accept never mutates the review it was given', () => {
  const review = clone(ACCEPT.review);
  R.buildAcceptedStorage(review, { currentPlanId: ACCEPT.livePlanId });
  assert.deepEqual(review, ACCEPT.review);
});

it('no reviewed plan — nothing to accept', () => {
  assert.equal(R.buildAcceptedStorage({ reviewedDietPlan: null }, {}), null);
  assert.equal(R.buildAcceptedStorage({ reviewedDietPlan: { days: [] } }, {}), null);
});

it('the goal stamp falls back to the live planId, and is absent only when neither has one', () => {
  const noReviewId = Object.assign(clone(ACCEPT.review), { planId: null });
  assert.equal(accept(noReviewId, { currentPlanId: 'plan-x' }).planId, 'plan-x');
  assert.equal(accept(noReviewId, { currentPlanId: null }).planId, null);
});

/* ── 2. Accept is saved on the server ─────────────────────────────────── */

function strictHarness(setImpl, uid = 'athlete-1') {
  const local = new Map();
  const writes = [];
  const ctx = {
    FIELD_MAP: { dietPlan: 'zitlas_diet_plan' },
    SCALAR_FIELD_MAP: {},
    _BACKEND_ONLY_FIELDS: { wallet: true, membership: true },
    localStorage: {
      getItem: (k) => (local.has(k) ? local.get(k) : null),
      setItem: (k, v) => local.set(k, String(v)),
      removeItem: (k) => local.delete(k),
    },
    db: () => ({
      collection: (c) => ({
        doc: (id) => ({
          set: (patch, opts) => { writes.push({ c, id, patch: clone(patch), opts: clone(opts) }); return setImpl(); },
        }),
      }),
    }),
    myUid: () => uid,
  };
  vm.createContext(ctx);
  vm.runInContext(extractFn(CLOUD_SRC, 'saveStrict'), ctx);
  return { saveStrict: ctx.saveStrict, local, writes };
}

it('saveStrict resolves once users/{uid} has the write — local copy first', async () => {
  const h = strictHarness(() => Promise.resolve());
  await h.saveStrict('dietPlan', { planId: 'p', currentDietPlan: { days: [] } });
  assert.equal(JSON.parse(h.local.get('zitlas_diet_plan')).planId, 'p');
  assert.equal(h.writes.length, 1);
  assert.equal(h.writes[0].c, 'users');
  assert.equal(h.writes[0].id, 'athlete-1');
  assert.deepEqual(h.writes[0].opts, { merge: true });
  assert.equal(h.writes[0].patch.dietPlan.planId, 'p');
  assert.ok(h.writes[0].patch.dietPlanUpdatedAt);
});

it('saveStrict REJECTS when the cloud write fails (save() only logs)', async () => {
  const h = strictHarness(() => Promise.reject(new Error('permission-denied')));
  await assert.rejects(h.saveStrict('dietPlan', { planId: 'p' }), /permission-denied/);
});

it('saveStrict rejects when signed out, and for backend-owned fields', async () => {
  await assert.rejects(strictHarness(() => Promise.resolve(), null).saveStrict('dietPlan', {}), /not_signed_in/);
  const h = strictHarness(() => Promise.resolve());
  await assert.rejects(h.saveStrict('wallet', { balance: 1 }), /backend_only_field/);
  assert.equal(h.writes.length, 0);
});

it('diet.js Accept says "saved" only after the server has it, and undoes the local copy on failure', () => {
  const fn = extractFn(DIET_SRC, 'acceptExpertPlan');
  const save = fn.indexOf("ZitlasCloudSync.saveStrict('dietPlan', storage)");
  assert.ok(save > 0, 'Accept persists through saveStrict');
  assert.ok(fn.indexOf("Expert's plan saved") > save, 'the success toast follows the server write');
  assert.match(fn, /localStorage\.setItem\('zitlas_diet_plan', previousRaw\)/);
  assert.match(fn, /ZitlasDietReview\.buildAcceptedStorage\(/, 'lossless builder, not a meal-name rebuild');
});

it('cprofile.js Accept says "applied" only after the server has it, and undoes the local copy on failure', () => {
  const persistAt = CPROFILE_SRC.indexOf('_cpPersistDietStorage(_builtStorage).then(');
  assert.ok(persistAt > 0, 'Accept persists through the server');
  assert.ok(CPROFILE_SRC.indexOf("Expert\\'s plan has been applied", persistAt) > persistAt);
  assert.match(extractFn(CPROFILE_SRC, '_cpPersistDietStorage'), /ZitlasCloudSync\.saveStrict\('dietPlan', storage\)/);
  assert.match(CPROFILE_SRC, /localStorage\.setItem\('zitlas_diet_plan', _prevRaw\)/);
});

it('both Accept paths refuse a plan they cannot stamp (the next load would discard it)', () => {
  assert.match(extractFn(DIET_SRC, 'acceptExpertPlan'), /if \(!storage\.planId\)/);
  assert.match(CPROFILE_SRC, /if \(!_builtStorage\.planId\)/);
});

/* ── 3. Review history ────────────────────────────────────────────────── */

HISTORY.records.forEach((record, i) => {
  it(`history: the ${HISTORY.labels[i]} shape reads like every other`, () => {
    const n = clone(R.normalizeHistoryEntry(clone(record)));
    for (const [k, v] of Object.entries(HISTORY.expected)) assert.deepEqual(n[k], v, k);
  });
});

it('history: a present flat list wins over the nested meal, even when empty', () => {
  const n = R.normalizeHistoryEntry({ mealName: 'Dinner', newFoods: [], newMeal: { foods: ['Something else'] } });
  assert.deepEqual(clone(n.newFoods), []);
});

it('history: a missing list reads as empty, never undefined', () => {
  const n = clone(R.normalizeHistoryEntry({ mealName: 'Dinner' }));
  assert.deepEqual(n.oldFoods, []);
  assert.deepEqual(n.newFoods, []);
});

/* ── 4. Honest server apply ───────────────────────────────────────────── */

const respond = (status, data) => () => Promise.resolve({ status, json: () => Promise.resolve(data) });
const apply = (fetchImpl, extra) => R.applyReviewedDiet(Object.assign({
  reviewId: 'rev_1', athleteUid: 'athlete-1', wrapper: { planId: 'p' },
  getIdToken: () => Promise.resolve('tok'), fetch: fetchImpl,
}, extra || {}));

[
  ['applied',         respond(200, { success: true, applied: true })],
  ['planid_mismatch', respond(200, { success: true, applied: false, reason: 'planid_mismatch' })],
  ['not_applicable',  respond(200, { success: true, applied: false })],
  ['auth',            respond(401, { detail: 'Invalid token' })],
  ['forbidden',       respond(403, { detail: 'not_assigned_expert' })],
  ['server',          respond(500, {})],
  ['server',          respond(200, { success: false })],
  ['server',          () => Promise.resolve({ status: 502, json: () => Promise.reject(new SyntaxError('html')) })],
  ['network',         () => Promise.reject(new TypeError('Failed to fetch'))],
].forEach(([outcome, fetchImpl], i) => {
  it(`apply #${i + 1} -> ${outcome}`, async () => {
    assert.equal((await apply(fetchImpl)).outcome, outcome);
  });
});

it("apply sends the reviewer's token and the complete wrapper", async () => {
  const seen = [];
  await apply((url, init) => { seen.push({ url, init }); return respond(200, { success: true, applied: true })(); });
  assert.equal(seen[0].url, '/api/review/apply');
  assert.equal(seen[0].init.method, 'POST');
  assert.equal(seen[0].init.headers.Authorization, 'Bearer tok');
  assert.deepEqual(JSON.parse(seen[0].init.body),
    { reviewId: 'rev_1', athleteUid: 'athlete-1', planType: 'diet', wrapper: { planId: 'p' } });
});

it('apply: no token is an auth failure; no athlete is not applicable (and nothing is sent)', async () => {
  assert.equal((await apply(respond(200, {}), { getIdToken: () => Promise.reject(new Error('signed out')) })).outcome, 'auth');
  let called = false;
  const out = await apply(() => { called = true; return respond(200, {})(); }, { athleteUid: null });
  assert.equal(out.outcome, 'not_applicable');
  assert.equal(called, false);
});

it('only a live plan or a confirmed Accept fallback may complete a review', () => {
  for (const o of ['applied', 'planid_mismatch', 'not_applicable']) assert.equal(R.isCompletable(o), true, o);
  for (const o of ['auth', 'forbidden', 'network', 'server', undefined]) assert.equal(R.isCompletable(o), false, String(o));
});

it('every failure message says the review was NOT completed', () => {
  for (const o of ['auth', 'forbidden', 'network', 'server']) {
    assert.match(R.APPLY_MESSAGES[o], /NOT completed/, o);
  }
  for (const o of ['applied', 'planid_mismatch', 'not_applicable']) {
    assert.match(R.APPLY_MESSAGES[o], /Review completed/, o);
  }
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
