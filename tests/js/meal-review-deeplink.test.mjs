/**
 * ZITLAS — a notification tap opens the exact meal, once
 * (tests/js/meal-review-deeplink.test.mjs)
 *
 * WHAT THIS PINS
 * --------------
 * Tapping "your expert reviewed your Lunch" used to land on the Meal Reviews
 * LIST. The notification named one meal and the destination showed twenty, so
 * the user still had to go find it — the trip the notification existed to save.
 *
 * `?cwCheckin=<id>` fixes that, and the timing is the whole difficulty:
 *
 *   open() runs with S.checkins EMPTY. The meal_checkins onSnapshot has not
 *   fired yet, so looking the meal up at open() time can only ever fail. The
 *   id is therefore HELD and consumed from the snapshot handler instead.
 *
 * And that creates the opposite trap. The snapshot handler runs again on every
 * later update — a rating saved, a new meal arriving, any write by either
 * side. If consuming were not strictly one-shot, the sheet would yank itself
 * open again while the user was doing something else, repeatedly, with no way
 * out. Clearing the id BEFORE opening is what makes it fire exactly once.
 *
 * Run:  node tests/js/meal-review-deeplink.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const SRC = readFileSync(join(WEB, 'components', 'coaching-workspace.js'), 'utf8');
const CPROFILE = readFileSync(join(WEB, 'pages', 'coaches', 'cprofile.js'), 'utf8');
const DASH = readFileSync(join(WEB, 'pages', 'experts', 'expert-dashboard.js'), 'utf8');

const results = [];
function it(name, fn) {
  try { fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── The consumer, executed for real ───────────────────────────────────────
   The snapshot handler is buried in a Firestore listener, so rather than
   stand up the whole module we lift the two functions that matter and run
   them against a real state object. They are extracted from the SOURCE, so
   this cannot pass against a file where they no longer exist.            */
function harness() {
  const opened = [];
  const logs = [];

  const consumerSrc = SRC.slice(
    SRC.indexOf('function _cwOpenPendingCheckin()'),
    SRC.indexOf('function openCheckinSheet(c)'),
  );
  assert.ok(consumerSrc.includes('S.pendingCheckinId'),
    '_cwOpenPendingCheckin is gone or renamed — this test is stale');

  const ctx = {
    S: { checkins: [], pendingCheckinId: null },
    openCheckinSheet: (c) => opened.push(c.checkinId),
    console: { log: (m) => logs.push(String(m)), warn() {}, error() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(consumerSrc, ctx);
  return { ctx, opened, logs, run: () => ctx._cwOpenPendingCheckin() };
}

/* ── The timing that broke it ──────────────────────────────────────────── */

it('nothing happens before the meals have loaded', () => {
  const h = harness();
  h.ctx.S.pendingCheckinId = 'MCI_1';
  h.ctx.S.checkins = [];            // open() time: the snapshot has not fired
  h.run();
  assert.deepEqual(h.opened, [],
    'looking the meal up before it loads is why this always failed');
  assert.equal(h.ctx.S.pendingCheckinId, 'MCI_1',
    'the id must be KEPT so the next snapshot can use it');
});

it('THE FIX: the meal opens once its snapshot arrives', () => {
  const h = harness();
  h.ctx.S.pendingCheckinId = 'MCI_1';
  h.run();                                        // empty — held
  h.ctx.S.checkins = [{ checkinId: 'MCI_0' }, { checkinId: 'MCI_1' }];
  h.run();                                        // data — opens
  assert.deepEqual(h.opened, ['MCI_1']);
});

it('it opens the NAMED meal, not the first or newest one', () => {
  const h = harness();
  h.ctx.S.checkins = [{ checkinId: 'MCI_9' }, { checkinId: 'MCI_1' }];
  h.ctx.S.pendingCheckinId = 'MCI_1';
  h.run();
  assert.deepEqual(h.opened, ['MCI_1']);
});

/* ── The opposite trap ─────────────────────────────────────────────────── */

it('THE TRAP: later snapshots do not re-open the sheet', () => {
  const h = harness();
  h.ctx.S.checkins = [{ checkinId: 'MCI_1' }];
  h.ctx.S.pendingCheckinId = 'MCI_1';
  h.run();                                        // the tap
  h.run();                                        // a rating is saved
  h.run();                                        // another meal arrives
  assert.deepEqual(h.opened, ['MCI_1'],
    're-opening on every snapshot would trap the user in the sheet');
});

it('the id is cleared BEFORE opening, not after', () => {
  // If openCheckinSheet threw, an id cleared afterwards would survive and
  // retry on the next snapshot — forever.
  const h = harness();
  h.ctx.openCheckinSheet = () => { throw new Error('render failed'); };
  h.ctx.S.checkins = [{ checkinId: 'MCI_1' }];
  h.ctx.S.pendingCheckinId = 'MCI_1';
  try { h.run(); } catch { /* the throw is the point */ }
  assert.equal(h.ctx.S.pendingCheckinId, null,
    'a failing sheet must not retry on every future snapshot');
});

it('no pending id does nothing at all', () => {
  const h = harness();
  h.ctx.S.checkins = [{ checkinId: 'MCI_1' }];
  h.run();
  assert.deepEqual(h.opened, []);
});

/* ── A meal that is not there ──────────────────────────────────────────── */

it('an unknown meal leaves the user on the tab, not in an error', () => {
  const h = harness();
  h.ctx.S.checkins = [{ checkinId: 'MCI_1' }];
  h.ctx.S.pendingCheckinId = 'MCI_GONE';   // stale id, or an ended coaching
  h.run();
  assert.deepEqual(h.opened, []);
  assert.equal(h.ctx.S.pendingCheckinId, null, 'and it must not keep retrying');
  assert.ok(h.logs.some((l) => l.includes('MCI_GONE')),
    'a silent no-op here is impossible to diagnose from a device log');
});

/* ── The param is threaded end to end ──────────────────────────────────── */

it('open() accepts and holds the id', () => {
  assert.ok(/S\.pendingCheckinId = opts\.initialCheckinId/.test(SRC),
    'open() must hold the id — S.checkins is empty at that moment');
});

it('the snapshot handler is what consumes it', () => {
  const listener = SRC.slice(SRC.indexOf("collection('meal_checkins')"));
  const handler = listener.slice(0, listener.indexOf('var pending ='));
  assert.ok(handler.includes('_cwOpenPendingCheckin()'),
    'consuming anywhere else runs before the data exists');
});

it('both pages read ?cwCheckin= and pass it through', () => {
  assert.ok(/cwCheckin/.test(CPROFILE), 'athlete side never reads the param');
  assert.ok(/initialCheckinId/.test(CPROFILE), 'athlete side never passes it');
  assert.ok(/cwCheckin/.test(DASH), 'expert side never reads the param');
  assert.ok(/initialCheckinId/.test(DASH), 'expert side never passes it');
});

it('the param stays a HINT — Firestore still gates the workspace', () => {
  // A tampered ?cwCheckin= must not become an access path. Both sides
  // re-read personal_coaching and fail closed before anything opens.
  assert.ok(/_coachingWorkspaceFor\(coach\)/.test(CPROFILE),
    'the athlete-side gate is gone');
  assert.ok(/rel\.coachId !== uid \|\| !isActive/.test(DASH),
    'the expert-side ownership + lifecycle gate is gone');
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  PASS  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
