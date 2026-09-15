/**
 * ZITLAS — Personal Coaching Programs: every way in (tests/js/coaching-programs-handoff.test.mjs)
 *
 * The coach profile's Personal Coach buttons start Personal Coaching on the
 * PROGRAMS flow, on both clients:
 *   * inside the Flutter app (the page advertises `nativePrograms=1`) the tap
 *     is handed to Flutter as `open-programs:<expertId>` — the native screen;
 *   * in a browser (or an older app build without the native screen) it
 *     opens the website's Programs page, /pages/coaching-programs/, with the
 *     same expert — the same programs and the same /api/coaching-programs flow.
 * The old Diet / Training / Complete plan sheet is no longer opened by any
 * entry.
 *
 * Run:  node tests/js/coaching-programs-handoff.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const CP = readFileSync(join(ROOT, 'frontend', 'website', 'pages', 'coaches', 'cprofile.js'), 'utf8');
const WEBVIEW = readFileSync(
  join(ROOT, 'mobile', 'lib', 'features', 'coaching_webview', 'coaching_webview_screen.dart'), 'utf8');
const PROGRAMS = readFileSync(
  join(ROOT, 'mobile', 'lib', 'features', 'coaching_programs', 'coaching_programs.dart'), 'utf8');

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

/* Runs the real _cpHandOffToNativePrograms against a stand-in window. */
function handOff({ search = '', channel = 'ok' } = {}) {
  const posted = [];
  const win = { location: { search } };
  if (channel === 'ok') win.ZitlasWebview = { postMessage: (m) => posted.push(m) };
  if (channel === 'throws') win.ZitlasWebview = { postMessage: () => { throw new Error('channel gone'); } };
  const ctx = { window: win };
  vm.createContext(ctx);
  vm.runInContext(extractFn(CP, '_cpHandOffToNativePrograms'), ctx);
  return { handedOff: ctx._cpHandOffToNativePrograms('coach-9'), posted: [...posted] };
}

/* Runs the real _cpProgramsUrl. */
function programsUrl(expertId) {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(extractFn(CP, '_cpProgramsUrl'), ctx);
  return ctx._cpProgramsUrl(expertId);
}

const APP_WITH_PROGRAMS = '?expertId=coach-9&webview=1&nativePrograms=1';
const OLDER_APP = '?expertId=coach-9&webview=1';

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

/* ── The hand-off itself ──────────────────────────────────────────────── */

it('inside an app that has the Programs screen, the tap goes to Flutter', () => {
  const { handedOff, posted } = handOff({ search: APP_WITH_PROGRAMS });
  assert.equal(handedOff, true);
  assert.deepEqual(posted, ['open-programs:coach-9']);
});

it('an older app build (no flag) is not handed off — it gets the website Programs page', () => {
  const { handedOff, posted } = handOff({ search: OLDER_APP });
  assert.equal(handedOff, false);
  assert.deepEqual(posted, [], 'nothing may be posted to an app that cannot handle it');
});

it('a normal browser is not handed off — it gets the website Programs page', () => {
  const { handedOff, posted } = handOff({ search: '?expertId=coach-9', channel: 'none' });
  assert.equal(handedOff, false);
  assert.deepEqual(posted, []);
});

it('the flag without the app channel (a copied link) is not handed off', () => {
  const { handedOff } = handOff({ search: APP_WITH_PROGRAMS, channel: 'none' });
  assert.equal(handedOff, false);
});

it('a failing channel falls back to the website page rather than a dead button', () => {
  const { handedOff } = handOff({ search: APP_WITH_PROGRAMS, channel: 'throws' });
  assert.equal(handedOff, false);
});

it('only an exact nativePrograms=1 counts', () => {
  assert.equal(handOff({ search: '?webview=1&nativePrograms=10' }).handedOff, false);
  assert.equal(handOff({ search: '?webview=1&nativePrograms=0' }).handedOff, false);
  assert.equal(handOff({ search: '?nativePrograms=1&webview=1' }).handedOff, true);
});

it('the website Programs page carries the same expert', () => {
  assert.equal(programsUrl('coach-9'), '/pages/coaching-programs/coaching-programs.html?expertId=coach-9');
  assert.equal(programsUrl('a b/c'), '/pages/coaching-programs/coaching-programs.html?expertId=a%20b%2Fc');
  assert.equal(programsUrl(''), '/pages/coaching-programs/coaching-programs.html');
});

/* ── Where it is wired ────────────────────────────────────────────────── */

const entrySlice = CP.slice(CP.indexOf('/* Entry buttons */'), CP.indexOf('/* Send Coaching Request'));

it('the Personal Coach buttons open Personal Coaching through the one entry', () => {
  assert.ok(entrySlice.length > 0, 'entry-button block not found');
  assert.match(entrySlice, /openCoachingEntry\(\);/);
  assert.doesNotMatch(entrySlice, /openCoachingSheet\(\);/,
    'the buttons must not open the plan sheet directly');
});

it('active coaching and pending requests are still handled first, as before', () => {
  const active = entrySlice.indexOf('_coachingIsActive(_myCoaching)');
  const pending = entrySlice.indexOf('_openRequestFor(coach.id)');
  const entry = entrySlice.indexOf('openCoachingEntry();');
  assert.ok(active !== -1 && pending !== -1 && entry !== -1);
  assert.ok(active < entry && pending < entry,
    'an athlete who is already coaching still reaches their workspace, not Programs');
});

it('openCoachingEntry: the app hand-off first, otherwise the website Programs page', () => {
  const body = extractFn(CP, 'openCoachingEntry');
  const handoff = body.indexOf('_cpHandOffToNativePrograms(coach.id)');
  const page = body.indexOf('_cpProgramsUrl(coach.id)');
  assert.ok(handoff !== -1 && page !== -1 && handoff < page);
  assert.doesNotMatch(body, /openCoachingSheet\(\)/, 'no entry opens the old plan sheet any more');
});

it('"Continue with Personal Coaching" (trial ended) uses the same entry', () => {
  assert.match(CP, /trialContinuePaidBtn\.addEventListener\('click', openCoachingEntry\)/);
});

it('?action=coach still clicks the Personal Coach button, so it takes the same path', () => {
  assert.match(CP, /action === 'coach'[\s\S]{0,300}getElementById\('personalCoachBtn'\)/);
});

it('the plan sheet itself is untouched (kept for later phases)', () => {
  assert.match(CP, /function openCoachingSheet\(\)/);
});

/* ── The app side agrees ──────────────────────────────────────────────── */

it('the app advertises the Programs screen on the coach-profile URL', () => {
  assert.match(WEBVIEW, /&webview=1&nativePrograms=1/);
});

it('the app listens for the same message the page sends', () => {
  assert.match(PROGRAMS, /kOpenProgramsBridgeMessage = 'open-programs'/);
  assert.match(WEBVIEW, /isOpenProgramsBridgeMessage\(m\)/);
});

/* ── Run ──────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [name, fn] of tests) {
  try {
    await fn();
    console.log('  ✓ ' + name);
  } catch (e) {
    failed++;
    console.log('  ✗ ' + name + '\n      ' + ((e && e.message) || e));
  }
}
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed ? 1 : 0);
