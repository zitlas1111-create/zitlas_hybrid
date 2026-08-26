/**
 * ZITLAS — the meal-photo helpers must be reachable from the sheet renderers
 * (tests/js/workspace-scope.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * `_cwPhotoMarkup` and `_cwWireImageFallbacks` were declared INSIDE
 * `renderCheckins()`. `card()` is nested there too, so the meal LIST rendered
 * perfectly — but `openSheet()`, `openCheckinHistorySheet()` and
 * `renderCheckinReviewSheet()` live at module scope and could not see them.
 * The moment a coach opened a meal, the Android WebView threw:
 *
 *     Uncaught ReferenceError: _cwPhotoMarkup is not defined
 *
 * and the review sheet never rendered — right after a SUCCESSFUL fetch
 * (documentsFound=1), which is what made it look like a data problem.
 *
 * The indentation hid it completely: both helpers sat at two-space indent and
 * looked module-level, because the enclosing function had not closed where it
 * appeared to.
 *
 * WHY THIS IS A RUNTIME TEST. A grep ("is the symbol defined in this file?")
 * passes for a nested declaration — that is exactly the check that missed
 * this. A hand-written scope parser is worse: the first one I wrote here
 * disagreed with itself on this very file. So this EXECUTES the real module
 * against a stub browser and reads the availability line `open()` prints,
 * which is the same line the Android log shows. No parsing, no guessing.
 *
 * Run:  node tests/js/workspace-scope.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const FILE = join(HERE, '..', '..', 'frontend', 'website',
  'components', 'coaching-workspace.js');

/* ── Just enough browser for the module to load and open() to run ──────── */
function runWorkspace(src) {
  const logs = [];
  const el = () => {
    const node = {
      style: {}, dataset: {},
      classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
      children: [], innerHTML: '', textContent: '', value: '',
      appendChild() {}, removeChild() {}, remove() {},
      addEventListener() {}, removeEventListener() {},
      setAttribute() {}, getAttribute: () => null,
      querySelector: () => null, querySelectorAll: () => [],
      insertAdjacentHTML() {}, focus() {}, closest: () => null,
      getBoundingClientRect: () => ({ top: 0, left: 0, width: 0, height: 0 }),
    };
    return node;
  };

  const ctx = {
    console: {
      log: (...a) => logs.push(a.join(' ')),
      warn: () => {}, error: () => {},
    },
    setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    requestAnimationFrame: (fn) => { try { fn(); } catch { /* stub */ } return 0; },
    Date, Math, JSON, String, Number, Boolean, Array, Object, Error, RegExp, parseInt, parseFloat,
    isNaN, encodeURIComponent, decodeURIComponent, Promise,
    document: {
      body: el(), head: el(),
      createElement: el, createTextNode: () => el(),
      getElementById: () => el(),
      querySelector: () => el(), querySelectorAll: () => [],
      addEventListener() {}, removeEventListener() {},
    },
    location: { href: 'https://www.zitlas.com/pages/experts/expert-dashboard.html', search: '' },
    navigator: { userAgent: 'test' },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  };
  ctx.window = ctx;
  ctx.self = ctx;
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return { api: ctx.window.ZitlasCoachingWorkspace, logs, ctx };
}

const results = [];
function it(name, fn) {
  try { fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

const CURRENT = readFileSync(FILE, 'utf8');

/* ── THE REGRESSION ────────────────────────────────────────────────────── */

it('the module loads and exposes open()', () => {
  const { api } = runWorkspace(CURRENT);
  assert.ok(api && typeof api.open === 'function');
});

it('THE BUG: _cwPhotoMarkup is reachable from module scope', () => {
  const { api, logs } = runWorkspace(CURRENT);
  api.open({ athleteId: 'a1', coachId: 'c1', role: 'coach', athleteName: 'A' });
  const line = logs.find((l) => l.includes('[CW PHOTO]'));
  assert.ok(line, 'open() did not report helper availability at all');
  assert.match(line, /_cwPhotoMarkup available=function/,
    'the sheet renderers cannot see it — opening a meal will throw ' +
    'ReferenceError, exactly as the Android log showed');
});

it('_cwWireImageFallbacks is reachable too (openSheet calls it)', () => {
  const { api, logs } = runWorkspace(CURRENT);
  api.open({ athleteId: 'a1', coachId: 'c1', role: 'coach', athleteName: 'A' });
  const line = logs.find((l) => l.includes('[CW PHOTO]'));
  assert.match(line, /_cwWireImageFallbacks available=function/);
});

/* ── Proof the test can actually fail ──────────────────────────────────── */

it('a nested declaration IS caught (mutation of the real file)', () => {
  /* Re-create the original defect: move the two helpers back inside
     renderCheckins by renaming the module-level ones, so the module-scope
     callers see nothing. If this does not fail the availability check, the
     test above proves nothing. */
  const broken = CURRENT
    .replace('function _cwPhotoMarkup(', 'function _cwPhotoMarkupNested(')
    .replace('function _cwWireImageFallbacks(', 'function _cwWireImageFallbacksNested(');
  const { api, logs } = runWorkspace(broken);
  api.open({ athleteId: 'a1', coachId: 'c1', role: 'coach', athleteName: 'A' });
  const line = logs.find((l) => l.includes('[CW PHOTO]'));
  assert.ok(line, 'diagnostic missing from the mutated build');
  assert.match(line, /_cwPhotoMarkup available=undefined/,
    'the availability check failed to notice a missing helper — it is not ' +
    'a real guard');
});

/* ── The diagnostic must survive, it is the field signal ───────────────── */

it('open() prints the availability line the Android log reads', () => {
  assert.ok(/\[CW PHOTO\] _cwPhotoMarkup available=/.test(CURRENT),
    'without this a regression is only visible when a coach taps a meal');
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  PASS  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
