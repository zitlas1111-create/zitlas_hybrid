/**
 * ZITLAS — Expert Profile reviews (tests/js/expert-profile-reviews.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * Clicking "View All N Reviews" on an Expert Profile showed a toast reading
 * "All reviews — coming soon". Two separate faults produced that:
 *
 *   1. `initViewAlls()` bound the button's ONLY handler to showToast(...).
 *      There was no fetch, no navigation, no expansion.
 *   2. The profile object was built with `reviews: []` and `reviewCount: 0`
 *      hardcoded, and the page never called the ratings API at all — so the
 *      section underneath the button was empty even before it was pressed.
 *
 * The backend (`GET /api/expert-ratings/expert/{id}`) and the Flutter client
 * were already working; only the website was disconnected.
 *
 * WHAT MUST KEEP BEING TRUE
 * -------------------------
 *   * Reviews come from the PUBLIC API, never from a browser-side Firestore
 *     query — firestore.rules restricts `expert_ratings` reads to the athlete
 *     and the expert because the raw docs carry unconsented photo URLs.
 *   * A ratings outage degrades the section, never the profile.
 *   * No fabricated data: no invented dates, no synthesised rating bars, no
 *     placeholder review count.
 *
 * Run:  node tests/js/expert-profile-reviews.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const SRC = readFileSync(join(WEB, 'pages', 'coaches', 'cprofile.js'), 'utf8');
const HTML = readFileSync(join(WEB, 'pages', 'coaches', 'cprofile.html'), 'utf8');

/* ── Pull the real helpers out of the shipping file ─────────────────────── */
function extractFn(src, name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start !== -1, `${name}() not found — renamed?`);
  let depth = 0, i = src.indexOf('{', start);
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) break;
  }
  return src.slice(start, i + 1);
}

function sandbox() {
  const ctx = { Math, Number, String, Date, isFinite, Array, JSON,
                console: { warn() {}, log() {} } };
  vm.createContext(ctx);
  vm.runInContext(
    SRC.slice(SRC.indexOf('var REVIEW_AVATAR_COLORS'),
              SRC.indexOf('/* GET /api/expert-ratings')) +
    extractFn(SRC, '_adaptReview') + '\n' +
    extractFn(SRC, '_reviewInitials') + '\n' +
    extractFn(SRC, '_reviewDate') + '\n' +
    extractFn(SRC, '_ratingDistribution'), ctx);
  return ctx;
}

const results = [];
function it(name, fn) {
  try { fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── 1. The bug itself is gone ──────────────────────────────────────────── */

it('the "coming soon" toast is no longer the click handler', () => {
  const handlerArea = SRC.slice(SRC.indexOf('function initViewAlls'),
                                SRC.indexOf('function initBottomNav'));
  assert.ok(!/showToast\(\s*['"]All reviews/.test(handlerArea),
    'the View All button still shows the "coming soon" toast');
});

it('the button re-renders the reviews instead', () => {
  const handlerArea = SRC.slice(SRC.indexOf('function initViewAlls'),
                                SRC.indexOf('function initBottomNav'));
  assert.match(handlerArea, /renderReviews\(coach,/);
});

it('reviews are fetched from the public API', () => {
  assert.match(SRC, /fetch\('\/api\/expert-ratings\/expert\/'/);
});

it('the expert id is URL-encoded into the path', () => {
  assert.match(SRC, /encodeURIComponent\(expertId\)/);
});

it('the browser never queries expert_ratings from Firestore', () => {
  // firestore.rules denies this to a profile visitor, and the raw docs carry
  // photo URLs the athlete may not have consented to publishing.
  assert.ok(!/collection\(\s*['"]expert_ratings['"]\s*\)/.test(SRC),
    'a direct Firestore read of expert_ratings was introduced');
});

it('the API is called once per page load, not once per init path', () => {
  // Three _initWithCoach() call sites, one shared promise. A call site that
  // started its own request would fetch the ratings two or three times.
  const sites = SRC.match(/(?<!function )_initWithCoach\([^)]*\)/g) || [];
  assert.equal(sites.length, 3, `expected 3 _initWithCoach call sites, saw ${sites.length}`);
  for (const site of sites) {
    assert.match(site, /reviewsPromise\)$/, `${site} does not share the one request`);
  }
  assert.equal((SRC.match(/_fetchExpertReviews\(/g) || []).length, 3,
    'expected one definition, one call in init(), one defensive fallback');
});

/* ── 2. The API row -> renderer adaptation ──────────────────────────────── */

const API_ROW = {
  reviewId: 'r1',
  rating: 5,
  reviewText: 'Brilliant coach, my lifts went up.',
  verifiedCoaching: true,
  createdAt: new Date(Date.now() - 3 * 86400000).toISOString(),
  athleteName: 'Verified ZITLAS Client',
  beforePhotoUrl: null,
  afterPhotoUrl: null,
};

it('an API row maps onto every field the renderer reads', () => {
  const ctx = sandbox();
  const r = ctx._adaptReview(API_ROW, 0);
  assert.equal(r.name, 'Verified ZITLAS Client');
  assert.equal(r.text, 'Brilliant coach, my lifts went up.');
  assert.equal(r.rating, 5);
  assert.equal(r.initials, 'VZ');
  assert.equal(r.date, '3 days ago');
  assert.ok(r.color, 'the renderer needs an avatar colour');
});

it('initials are derived safely from odd names', () => {
  const ctx = sandbox();
  assert.equal(ctx._reviewInitials('Verified ZITLAS Client'), 'VZ');
  assert.equal(ctx._reviewInitials('Anita'), 'A');
  assert.equal(ctx._reviewInitials('   '), 'ZC');
  assert.equal(ctx._reviewInitials(''), 'ZC');
  assert.equal(ctx._reviewInitials(null), 'ZC');
});

it('a missing or broken review text never becomes "undefined"', () => {
  const ctx = sandbox();
  assert.equal(ctx._adaptReview({ rating: 4 }, 0).text, '');
  assert.equal(ctx._adaptReview({ reviewText: null, rating: 4 }, 0).text, '');
});

it('a missing name falls back to the public display name', () => {
  const ctx = sandbox();
  assert.equal(ctx._adaptReview({ rating: 4 }, 0).name, 'Verified ZITLAS Client');
});

it('a malformed row is dropped rather than rendered', () => {
  const ctx = sandbox();
  assert.equal(ctx._adaptReview(null, 0), null);
  assert.equal(ctx._adaptReview('nonsense', 0), null);
});

it('ratings are clamped into the 0-5 the star renderer expects', () => {
  const ctx = sandbox();
  assert.equal(ctx._adaptReview({ rating: 9 }, 0).rating, 5);
  assert.equal(ctx._adaptReview({ rating: -2 }, 0).rating, 0);
  assert.equal(ctx._adaptReview({ rating: 'x' }, 0).rating, 0);
});

/* ── 3. No invented data ────────────────────────────────────────────────── */

it('an unparseable date renders as nothing, never as a guess', () => {
  const ctx = sandbox();
  assert.equal(ctx._reviewDate(undefined), '');
  assert.equal(ctx._reviewDate(''), '');
  assert.equal(ctx._reviewDate('not-a-date'), '');
});

it('the renderer no longer substitutes a fake "2 weeks ago"', () => {
  assert.ok(!/r\.date \|\| '2 weeks ago'/.test(SRC),
    'a missing timestamp still renders an invented date');
});

it('relative dates read sensibly across the range', () => {
  const ctx = sandbox();
  const ago = (days) => ctx._reviewDate(new Date(Date.now() - days * 86400000).toISOString());
  assert.equal(ago(0), 'today');
  assert.equal(ago(1), 'yesterday');
  assert.equal(ago(4), '4 days ago');
  assert.equal(ago(10), 'a week ago');
  assert.equal(ago(21), '3 weeks ago');
  assert.equal(ago(90), '3 months ago');
  assert.equal(ago(400), 'a year ago');
});

it('the rating bars are measured from the real reviews', () => {
  const ctx = sandbox();
  const dist = ctx._ratingDistribution([
    { rating: 5 }, { rating: 5 }, { rating: 4 }, { rating: 1 },
  ]);
  assert.deepEqual([...dist], [2, 1, 0, 0, 1]);   // 5★,4★,3★,2★,1★
});

it('no reviews means an empty distribution, not a synthesised curve', () => {
  const ctx = sandbox();
  assert.deepEqual([...ctx._ratingDistribution([])], [0, 0, 0, 0, 0]);
  assert.deepEqual([...ctx._ratingDistribution(null)], [0, 0, 0, 0, 0]);
});

it('the 72/18/6/3/1 fabricated split is gone', () => {
  assert.ok(!/total \* 0\.72/.test(SRC),
    'rating bars still invent a distribution from the review count');
});

it('out-of-range ratings do not corrupt the distribution', () => {
  const ctx = sandbox();
  assert.deepEqual([...ctx._ratingDistribution([
    { rating: 0 }, { rating: 9 }, { rating: null }, {}, { rating: 3 },
  ])], [0, 0, 1, 0, 0]);
});

/* ── 4. Failure and empty states ────────────────────────────────────────── */

it('a failed fetch resolves to an empty list rather than rejecting', () => {
  const body = SRC.slice(SRC.indexOf('function _fetchExpertReviews'),
                         SRC.indexOf('/* One API row ->'));
  assert.match(body, /\.catch\(/, 'no catch — a ratings outage would break the page');
  assert.match(body, /return empty;/);
});

it('the fetch cannot hang the page', () => {
  const body = SRC.slice(SRC.indexOf('function _fetchExpertReviews'),
                         SRC.indexOf('/* One API row ->'));
  assert.match(body, /Promise\.race/);
  assert.match(body, /setTimeout/);
});

it('the failure log carries no response body or reviewer detail', () => {
  const body = SRC.slice(SRC.indexOf('function _fetchExpertReviews'),
                         SRC.indexOf('/* One API row ->'));
  const warn = body.slice(body.indexOf('console.warn'));
  assert.ok(!/data|rows|reviewText|athleteName|expertId/.test(warn.split('\n')[0]),
    'the warning line leaks review or request detail');
});

it('the View All button is hidden when there is nothing to expand', () => {
  const handlerArea = SRC.slice(SRC.indexOf('function initViewAlls'),
                                SRC.indexOf('function initBottomNav'));
  assert.match(handlerArea, /all\.length <= REVIEW_PREVIEW_COUNT/);
  assert.match(handlerArea, /btn\.style\.display = 'none'/);
});

/* ── 5. The markup no longer ships a fake number ────────────────────────── */

it('the hardcoded 128 is gone from the button', () => {
  assert.ok(!/reviewTotalCount">128</.test(HTML),
    'the placeholder review count can still flash before the API answers');
});

it('the count span ships empty', () => {
  assert.match(HTML, /id="reviewTotalCount"><\/span>/);
});

it('the button starts hidden so it cannot flash for a review-less expert', () => {
  const btn = HTML.slice(HTML.indexOf('id="viewAllReviews"') - 80,
                         HTML.indexOf('id="viewAllReviews"') + 120);
  assert.match(btn, /display:none/);
});

/* ── report ─────────────────────────────────────────────────────────────── */

let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) { console.log(`  ok  ${name}`); }
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
