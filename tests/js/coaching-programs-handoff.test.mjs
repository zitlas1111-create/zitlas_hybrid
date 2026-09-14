/**
 * ZITLAS — Personal Coaching Programs, Phase 1 (tests/js/coaching-programs-handoff.test.mjs)
 *
 * Inside the Flutter app, Personal Coaching starts on the NATIVE Programs
 * screen. cprofile.js's Personal Coach buttons therefore hand the tap to
 * Flutter (`open-programs:<expertId>`) instead of opening the old Diet /
 * Training / Complete plan sheet — but ONLY when the app advertises that
 * screen (`nativePrograms=1`). A normal browser, and an older app build,
 * keep the sheet, so the button can never go dead.
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

it('an older app build (no flag) keeps the existing plan sheet', () => {
  const { handedOff, posted } = handOff({ search: OLDER_APP });
  assert.equal(handedOff, false);
  assert.deepEqual(posted, [], 'nothing may be posted to an app that cannot handle it');
});

it('a normal browser keeps the existing plan sheet', () => {
  const { handedOff, posted } = handOff({ search: '?expertId=coach-9', channel: 'none' });
  assert.equal(handedOff, false);
  assert.deepEqual(posted, []);
});

it('the flag without the app channel (a copied link) keeps the sheet', () => {
  const { handedOff } = handOff({ search: APP_WITH_PROGRAMS, channel: 'none' });
  assert.equal(handedOff, false);
});

it('a failing channel falls back to the sheet rather than a dead button', () => {
  const { handedOff } = handOff({ search: APP_WITH_PROGRAMS, channel: 'throws' });
  assert.equal(handedOff, false);
});

it('only an exact nativePrograms=1 counts', () => {
  assert.equal(handOff({ search: '?webview=1&nativePrograms=10' }).handedOff, false);
  assert.equal(handOff({ search: '?webview=1&nativePrograms=0' }).handedOff, false);
  assert.equal(handOff({ search: '?nativePrograms=1&webview=1' }).handedOff, true);
});

/* ── Where it is wired ────────────────────────────────────────────────── */

const entrySlice = CP.slice(CP.indexOf('/* Entry buttons */'), CP.indexOf('/* Send Coaching Request'));

it('the Personal Coach buttons open Personal Coaching through the hand-off', () => {
  assert.ok(entrySlice.length > 0, 'entry-button block not found');
  assert.match(entrySlice, /openCoachingEntry\(\);/);
  assert.doesNotMatch(entrySlice, /openCoachingSheet\(\);/,
    'the buttons must no longer open the plan sheet directly');
});

it('active coaching and pending requests are still handled first, as before', () => {
  const active = entrySlice.indexOf('_coachingIsActive(_myCoaching)');
  const pending = entrySlice.indexOf('_openRequestFor(coach.id)');
  const entry = entrySlice.indexOf('openCoachingEntry();');
  assert.ok(active !== -1 && pending !== -1 && entry !== -1);
  assert.ok(active < entry && pending < entry,
    'an athlete who is already coaching still reaches their workspace, not Programs');
});

it('openCoachingEntry tries the hand-off before the sheet', () => {
  const body = extractFn(CP, 'openCoachingEntry');
  assert.ok(body.indexOf('_cpHandOffToNativePrograms(coach.id)') < body.indexOf('openCoachingSheet()'));
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
