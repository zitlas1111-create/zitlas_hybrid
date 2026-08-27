/**
 * ZITLAS — Android BACK unwinds the expert workspace one level at a time
 * (tests/js/expert-back-navigation.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * The expert coaching workspace navigates ENTIRELY inside one HTML page.
 * Opening an athlete, switching tab and opening a meal sheet are JS state,
 * and expert-dashboard.js uses `history.replaceState` (never `pushState`) on
 * purpose so tab clicks do not pollute history — its own comment says so.
 *
 * So none of that produces a WebView history entry. `canGoBack()` is false
 * and the URL path never changes, which is why the Flutter host concluded
 * "no history, at root" and treated ONE back press as "leave coaching": from
 * an open meal sheet, Back closed the whole expert section.
 *
 * `window.ZitlasBack.handle()` is the level the host could not see. It
 * unwinds exactly one thing per press, deepest first, and answers 'none' when
 * the page genuinely has nothing left — at which point the host falls through
 * to WebView history and then to the Flutter route stack.
 *
 * Run:  node tests/js/expert-back-navigation.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const SRC = readFileSync(join(WEB, 'components', 'coaching-workspace.js'), 'utf8');
const DASH = readFileSync(join(WEB, 'pages', 'experts', 'expert-dashboard.js'), 'utf8');
const SCREEN = readFileSync(
  join(HERE, '..', '..', 'mobile', 'lib', 'features', 'coaching_webview',
    'coaching_webview_screen.dart'), 'utf8');

/* ── A browser with a real, inspectable sheet backdrop ─────────────────── */
function load() {
  const sheet = {
    _open: false,
    style: {},
    innerHTML: '',
    classList: {
      add(c) { if (c === 'open') sheet._open = true; },
      remove(c) { if (c === 'open') sheet._open = false; },
      contains(c) { return c === 'open' ? sheet._open : false; },
      toggle() {},
    },
    querySelectorAll: () => [],
    querySelector: () => null,
    addEventListener() {},
    setAttribute() {},
    appendChild() {},
  };

  const generic = () => ({
    style: {}, dataset: {}, innerHTML: '', textContent: '', value: '',
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    appendChild() {}, removeChild() {}, remove() {}, insertAdjacentHTML() {},
    addEventListener() {}, removeEventListener() {}, setAttribute() {},
    getAttribute: () => null, focus() {},
    querySelector: () => null, querySelectorAll: () => [],
  });

  const ctx = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: (fn) => { try { fn(); } catch { /* stub */ } return 0; },
    clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    requestAnimationFrame: (fn) => { try { fn(); } catch { /* stub */ } return 0; },
    Date, Math, JSON, String, Number, Boolean, Array, Object, Error, RegExp,
    parseInt, parseFloat, isNaN, encodeURIComponent, decodeURIComponent, Promise,
    document: {
      body: generic(), head: generic(),
      createElement: generic, createTextNode: generic,
      getElementById: (id) => (id === 'cwSheetBackdrop' ? sheet : generic()),
      querySelector: () => generic(), querySelectorAll: () => [],
      addEventListener() {}, removeEventListener() {},
    },
    location: { href: 'https://www.zitlas.com/pages/experts/expert-dashboard.html', search: '' },
    navigator: { userAgent: 'test' },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);
  return { ctx, sheet, back: ctx.window.ZitlasBack, ws: ctx.window.ZitlasCoachingWorkspace };
}

const results = [];
function it(name, fn) {
  try { fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── The premise: the page really does create no history ───────────────── */

it('the workspace uses replaceState, never pushState', () => {
  assert.ok(/history\.replaceState/.test(DASH));
  assert.ok(!/history\.pushState/.test(DASH),
    'if this ever pushes history, the host can walk it and this hook is '
    + 'no longer the only way back');
});

/* ── One press, one level ──────────────────────────────────────────────── */

it('the hook exists on the page', () => {
  const { back } = load();
  assert.ok(back && typeof back.handle === 'function');
});

it('with nothing open it answers none, so the host falls through', () => {
  const { back } = load();
  assert.equal(back.handle(), 'none',
    'answering anything else would swallow the press and strand the user');
});

it('THE BUG: an open sheet is closed instead of leaving coaching', () => {
  const { back, sheet } = load();
  sheet.classList.add('open');
  assert.equal(back.handle(), 'sheet');
  assert.equal(sheet.classList.contains('open'), false,
    'the meal sheet must close — this press used to exit the expert section');
});

it('the workspace closes only after the sheet, never both at once', () => {
  const { back, sheet, ctx } = load();
  ctx.window.ZitlasCoachingWorkspace.open({
    athleteId: 'a1', coachId: 'c1', role: 'coach', athleteName: 'A',
  });
  sheet.classList.add('open');

  // press 1 -> the sheet
  assert.equal(back.handle(), 'sheet');
  assert.equal(ctx.window.ZitlasCoachingWorkspace.isOpen(), true,
    'closing the workspace in the same press would skip a level');

  // press 2 -> the workspace
  assert.equal(back.handle(), 'workspace');
  assert.equal(ctx.window.ZitlasCoachingWorkspace.isOpen(), false);

  // press 3 -> nothing left; the host takes over
  assert.equal(back.handle(), 'none');
});

it('an open workspace with no sheet unwinds in one press', () => {
  const { back, ctx } = load();
  ctx.window.ZitlasCoachingWorkspace.open({
    athleteId: 'a1', coachId: 'c1', role: 'coach', athleteName: 'A',
  });
  assert.equal(back.handle(), 'workspace');
  assert.equal(back.handle(), 'none');
});

it('it never loops — repeated presses keep draining, then stop', () => {
  const { back, sheet, ctx } = load();
  ctx.window.ZitlasCoachingWorkspace.open({
    athleteId: 'a1', coachId: 'c1', role: 'coach', athleteName: 'A',
  });
  sheet.classList.add('open');
  const seen = [back.handle(), back.handle(), back.handle(), back.handle()];
  assert.deepEqual(seen, ['sheet', 'workspace', 'none', 'none'],
    'a level that re-opens itself is the Meal -> Athlete -> Meal loop');
});

/* ── A broken handler must not trap the user ───────────────────────────── */

it('a throwing handler is skipped, not fatal', () => {
  const { back } = load();
  back.register(() => { throw new Error('boom'); });
  assert.equal(back.handle(), 'none',
    'a handler that throws must not swallow the press');
});

it('later handlers are asked first', () => {
  const { back } = load();
  back.register(() => 'overlay');
  assert.equal(back.handle(), 'overlay',
    'a layer above the workspace must unwind before the workspace');
});

/* ── The Flutter side asks in the right order ──────────────────────────── */

it('the host tries the page BEFORE WebView history', () => {
  const pageStep = SCREEN.indexOf('_pageHandledBack()');
  const historyStep = SCREEN.indexOf('_controller.canGoBack()');
  const leaveStep = SCREEN.lastIndexOf('_leaveScreen(router)');
  assert.ok(pageStep > 0 && historyStep > 0 && leaveStep > 0);
  assert.ok(pageStep < historyStep,
    'asking history first re-introduces the bug: there is none to walk');
  assert.ok(historyStep < leaveStep, 'leaving must be the last resort');
});

it('a page without the hook falls through rather than trapping', () => {
  assert.ok(/return false;/.test(
    SCREEN.slice(SCREEN.indexOf('Future<bool> _pageHandledBack'),
                 SCREEN.indexOf('/// Leaves this screen safely'))),
    'an older deployed build has no ZitlasBack — Back must still work');
});

/* ── Never the athlete dashboard, never a dead root ────────────────────── */

it('the fallback is role-aware, not a hardcoded /dashboard', () => {
  const leave = SCREEN.slice(SCREEN.indexOf('void _leaveScreen'));
  assert.ok(/resolvedRole == 'expert'/.test(leave),
    'hardcoding /dashboard is how an expert got silently downgraded');
  assert.ok(/isExpert \? '\/expert-dashboard' : '\/dashboard'/.test(leave));
});

it('at the expert root it confirms exit instead of re-entering itself', () => {
  const leave = SCREEN.slice(SCREEN.indexOf('void _leaveScreen'));
  assert.ok(/here == fallback/.test(leave),
    'go() to the route you are already on is why Back looked dead');
  assert.ok(/_confirmExitApp\(\)/.test(leave));
});

it('the exit dialog is latched so presses cannot stack it', () => {
  assert.ok(/_exitDialogOpen \|\| !mounted/.test(SCREEN));
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  PASS  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
