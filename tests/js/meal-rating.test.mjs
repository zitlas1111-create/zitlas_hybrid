/**
 * ZITLAS — expert meal rating (tests/js/meal-rating.test.mjs)
 *
 * The expert dashboard is the WEBSITE rendered inside the Flutter WebView
 * (`/expert-dashboard` -> CoachingWebViewScreen), so this file — not Dart —
 * is what an expert actually taps on Android.
 *
 * WHAT THESE GUARD
 * ----------------
 * The rating extends the EXISTING meal review rather than replacing it, and
 * two derived fields must keep being written or unrelated things break:
 *
 *   reaction  -> meal_compliance.dart scores adherence purely off
 *                `reaction.isCompliant`. Stop writing it and every rated meal
 *                silently stops counting toward compliance.
 *   score     -> this file's own "Avg Score" chip reads it on a 1-10 scale.
 *                A 5-star meal must read 10/10, not 5/10.
 *
 * And the notification must fire ONCE: on the first rating, not on every
 * edit. Spamming an athlete each time an expert nudges a star is the failure
 * mode worth pinning.
 *
 * Run:  node tests/js/meal-rating.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const SRC = readFileSync(join(WEB, 'components', 'coaching-workspace.js'), 'utf8');
const CSS = readFileSync(join(WEB, 'assets', 'css', 'coaching-workspace.css'), 'utf8');

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

function sandbox(extra = '') {
  const ctx = { Math, Number, String, JSON, console: { log() {} } };
  vm.createContext(ctx);
  vm.runInContext(
    SRC.slice(SRC.indexOf('var STARS_TO_REACTION'),
              SRC.indexOf('var RATING_DIMENSIONS')) +
    extractFn(SRC, '_cwExistingOverall') + '\n' +
    extractFn(SRC, '_cwIsRated') + '\n' + extra, ctx);
  return ctx;
}

const results = [];
function it(name, fn) {
  try { fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── Reading an existing rating back ───────────────────────────────────── */

it('a star-rated meal reports its overall rating', () => {
  const ctx = sandbox();
  assert.equal(ctx._cwExistingOverall({ overallRating: 4, score: 8 }), 4);
});

it('a meal rated BEFORE the star UI falls back to its 1-10 score', () => {
  const ctx = sandbox();
  // 8/10 was a "great" — it must not show as unrated just because the star
  // field did not exist when it was reviewed.
  assert.equal(ctx._cwExistingOverall({ score: 8 }), 4);
  assert.equal(ctx._cwExistingOverall({ score: 10 }), 5);
  assert.equal(ctx._cwExistingOverall({ score: 1 }), 1);
});

it('an unrated meal reports null, not zero', () => {
  const ctx = sandbox();
  assert.equal(ctx._cwExistingOverall({}), null);
  assert.equal(ctx._cwExistingOverall({ status: 'pending' }), null);
});

it('"rated" requires BOTH a reviewed status and a rating', () => {
  const ctx = sandbox();
  assert.equal(ctx._cwIsRated({ status: 'reviewed', overallRating: 5 }), true);
  assert.equal(ctx._cwIsRated({ status: 'pending', overallRating: 5 }), false);
  assert.equal(ctx._cwIsRated({ status: 'reviewed' }), false,
    'a reviewed meal with no rating must still offer "Rate Meal"');
});

/* ── The derived fields other features depend on ───────────────────────── */

it('every star maps to a reaction compliance understands', () => {
  const ctx = sandbox();
  // The map comes out of a vm context, so its prototype belongs to that
  // realm and deepEqual would fail on identity alone. Compare the values.
  const expected = {
    '5': 'perfect', '4': 'great', '3': 'good',
    '2': 'needs_improvement', '1': 'not_recommended',
  };
  for (const [stars, reaction] of Object.entries(expected)) {
    assert.equal(ctx.STARS_TO_REACTION[stars], reaction,
      `${stars}★ must map to ${reaction}`);
  }
  assert.equal(Object.keys(ctx.STARS_TO_REACTION).length, 5,
    'every star from 1 to 5 must map to a reaction');
});

it('3 stars and up are compliant, below is not', () => {
  // Mirrors MealReaction.isCompliant (score >= 3) in meal_checkin.dart.
  const ctx = sandbox();
  const compliant = { perfect: true, great: true, good: true,
                      needs_improvement: false, not_recommended: false };
  for (const [stars, reaction] of Object.entries(ctx.STARS_TO_REACTION)) {
    assert.equal(compliant[reaction], Number(stars) >= 3,
      `${stars}★ -> ${reaction} landed on the wrong side of compliance`);
  }
});

it('score is written on the 1-10 scale the Avg Score chip reads', () => {
  assert.ok(/score:\s*overall\s*\*\s*2/.test(SRC),
    'a 5-star meal must read 10/10, not 5/10');
});

it('reaction and score are still written at all', () => {
  const save = SRC.slice(SRC.indexOf('function saveCheckinReview'));
  assert.ok(/reaction:\s*STARS_TO_REACTION\[overall\]/.test(save),
    'dropping reaction silently breaks compliance scoring');
  assert.ok(/overallRating:\s*overall/.test(save));
});

/* ── All four dimensions persist ───────────────────────────────────────── */

it('the three optional dimensions are persisted', () => {
  const save = SRC.slice(SRC.indexOf('function saveCheckinReview'));
  for (const f of ['tasteRating', 'presentationRating', 'nutritionRating']) {
    assert.ok(new RegExp(`${f}:\\s*draft\\.${f}`).test(save), `${f} is not saved`);
  }
});

it('only Overall is required', () => {
  const save = SRC.slice(SRC.indexOf('function saveCheckinReview'));
  assert.ok(/if \(!d \|\| !draft \|\| !draft\.overallRating\) return;/.test(save));
  for (const f of ['tasteRating', 'presentationRating', 'nutritionRating']) {
    assert.ok(!new RegExp(`!draft\\.${f}\\)\\s*return`).test(save),
      `${f} must stay optional`);
  }
});

it('Submit is disabled until Overall is chosen', () => {
  assert.ok(/\(!d\.overallRating \? ' disabled' : ''\)/.test(SRC));
});

/* ── The notification must not spam ────────────────────────────────────── */

it('a FIRST rating notifies the athlete', () => {
  const save = SRC.slice(SRC.indexOf('function saveCheckinReview'));
  assert.ok(/if \(!wasEdit\) \{/.test(save));
  const firstBranch = save.slice(save.indexOf('if (!wasEdit) {'),
                                save.indexOf('} else {'));
  assert.ok(/notify\(c\.athleteId/.test(firstBranch), 'no in-app notification');
  assert.ok(/pushMealReview\(c\.checkinId\)/.test(firstBranch), 'no push');
});

it('THE SPAM GUARD: an EDIT does not notify again', () => {
  const save = SRC.slice(SRC.indexOf('function saveCheckinReview'));
  const elseBranch = save.slice(save.indexOf('} else {'));
  assert.ok(!/pushMealReview/.test(elseBranch.slice(0, 400)),
    'editing a rating must not fire a second push');
});

it('reopening an already-rated meal opens in EDIT mode', () => {
  const open = SRC.slice(SRC.indexOf('function openCheckinReviewSheet'),
                         SRC.indexOf('function _cwStarRow'));
  assert.ok(/isEdit:\s*_cwIsRated\(c\)/.test(open),
    'this flag is what stops a retry sending a duplicate notification');
});

it('an existing rating is preloaded for editing', () => {
  const open = SRC.slice(SRC.indexOf('function openCheckinReviewSheet'),
                         SRC.indexOf('function _cwStarRow'));
  for (const f of ['tasteRating', 'presentationRating', 'nutritionRating']) {
    assert.ok(new RegExp(`${f}:\\s*typeof c\\.${f}`).test(open),
      `${f} is not preloaded, so editing would silently clear it`);
  }
  assert.ok(/overallRating:\s*_cwExistingOverall\(c\)/.test(open));
});

/* ── The card call to action ───────────────────────────────────────────── */

it('an unrated meal offers "Rate Meal"', () => {
  assert.ok(/⭐ Rate Meal/.test(SRC));
});

it('a rated meal offers "Edit Rating", never a second rating', () => {
  assert.ok(/rated \? 'Edit Rating' : '⭐ Rate Meal'/.test(SRC));
});

it('the chip shows the REAL value, not a hardcoded one', () => {
  assert.ok(/'Rated ' \+ overall\.toFixed\(1\) \+ '★'/.test(SRC),
    'the rating shown must come from the meal');
  assert.ok(!/Rated 4\.5/.test(SRC), 'a sample value is baked into the UI');
});

it('the athlete does not get a button to rate their own meal', () => {
  const card = SRC.slice(SRC.indexOf('function card(c) {'),
                         SRC.indexOf("if (!S.checkins.length)"));
  assert.ok(/S\.opts\.role === 'coach'\s*\?/.test(card));
});

/* ── No hardcoded identity anywhere ────────────────────────────────────── */

it('no uid, meal id or expert name is hardcoded', () => {
  const region = SRC.slice(SRC.indexOf('EXPERT MEAL RATING'),
                           SRC.indexOf('CHAT TAB'));
  // A Firebase uid baked in would appear as a QUOTED 20+ char alphanumeric
  // run. Bare long identifiers (renderCheckinReviewSheet, ...) are code, not
  // data, so only quoted literals count.
  const quotedLiterals = region.match(/'[A-Za-z0-9]{20,}'/g) || [];
  assert.deepEqual(quotedLiterals, [],
    `a raw uid-looking literal is present: ${quotedLiterals.join(', ')}`);
  assert.ok(/reviewedBy: myName\(\)/.test(region), 'expert name must be derived');
  assert.ok(/c\.athleteId/.test(region), 'the athlete must come from the meal');
});

/* ── Android touch targets ─────────────────────────────────────────────── */

it('stars are real buttons with a 44px touch target', () => {
  assert.ok(/<button type="button" class="cw-star/.test(SRC), 'stars must be buttons');
  const star = CSS.slice(CSS.indexOf('.cw-star {'), CSS.indexOf('.cw-star--on'));
  assert.ok(/min-width:\s*44px/.test(star) && /min-height:\s*44px/.test(star),
    'a 26px glyph is not a tappable target on a phone');
});

it('the modal has an explicit Cancel', () => {
  assert.ok(/id="cwReviewCancel"/.test(SRC));
  assert.ok(/\.cw-cancel-btn/.test(CSS));
});

it('no alert() or prompt() is used', () => {
  const region = SRC.slice(SRC.indexOf('EXPERT MEAL RATING'),
                           SRC.indexOf('CHAT TAB'));
  assert.ok(!/\balert\(|\bprompt\(|\bconfirm\(/.test(region));
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  PASS  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
