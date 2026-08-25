/**
 * ZITLAS — a training plan with exercises must never be rejected as empty
 * (tests/js/training-plan-save.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * modify-workout.js's "Save & Complete Review" guard read `edited.days`:
 *
 *     if (!edited || !edited.days || !edited.days.length) {
 *       showToast('⚠️ Nothing to save — the plan looks empty…');
 *
 * but `collectEdited()` returns `{ weekly_plan: [...] }` — a WORKOUT plan
 * keys its days on `weekly_plan`, and `.days` is never set on it anywhere in
 * the file. The guard was copied verbatim from modify-diet.js, where the
 * collector really does return `{ days: [...] }`, and was never adapted.
 *
 * Consequence: the condition was ALWAYS true. Every training-plan save was
 * refused as empty no matter how much the expert had edited, and no
 * reviewed workout plan could ever reach Firestore. The expert saw their
 * edits on screen and lost every one of them.
 *
 * These tests run the REAL collectEdited() and the REAL guard expression,
 * both extracted from the shipping source, against a stub DOM — so they fail
 * again if either side drifts back apart.
 *
 * Run:  node tests/js/training-plan-save.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const EXPERTS = join(HERE, '..', '..', 'frontend', 'website', 'pages', 'experts');
const WORKOUT_SRC = readFileSync(join(EXPERTS, 'modify-workout.js'), 'utf8');
const DIET_SRC = readFileSync(join(EXPERTS, 'modify-diet.js'), 'utf8');

/* ── Pull the real functions / guard out of the shipping files ─────────── */
function extractFn(src, name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start !== -1, `${name}() not found — did it get renamed?`);
  let depth = 0, i = src.indexOf('{', start);
  const open = i;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) break;
  }
  return src.slice(start, i + 1);
}

/** The literal guard line, so the test breaks if the fix is reverted. */
function extractGuard(src) {
  const m = src.match(/if \(!editedDays \|\| !editedDays\.length\)|if \(!edited \|\| !edited\.days \|\| !edited\.days\.length\)/);
  assert.ok(m, 'the empty-plan guard is gone entirely');
  return m[0];
}

/* ── A DOM with exactly the elements collectEdited() reads ─────────────── */
function stubDocument(dayCount, exercisesPerDay) {
  const val = (v) => ({ value: v });
  const cards = [];
  for (let d = 0; d < dayCount; d++) {
    const rows = [];
    for (let e = 0; e < exercisesPerDay; e++) {
      rows.push({
        querySelector: (sel) =>
          sel === '.mp-ex-name' ? val(`Barbell Squat ${d}-${e}`)
          : sel === '.mp-ex-sets' ? val('4')
          : sel === '.mp-ex-reps' ? val('8-10')
          : null,
      });
    }
    cards.push({
      querySelector: (sel) =>
        sel === '.mp-focus' ? val(`Lower Body ${d}`)
        : sel === '.mp-duration' ? val('55')
        : null,
      querySelectorAll: () => rows,
    });
  }
  return { querySelectorAll: () => cards };
}

function runCollect(dayCount, exercisesPerDay) {
  const ctx = {
    document: stubDocument(dayCount, exercisesPerDay),
    origWeekly: Array.from({ length: dayCount }, (_, i) => ({
      day: `Day ${i + 1}`, focus: 'old', duration_minutes: 30, exercises: [],
    })),
    parseInt, JSON, String,
  };
  vm.createContext(ctx);
  vm.runInContext(extractFn(WORKOUT_SRC, 'collectEdited') + '\nvar __r = collectEdited();', ctx);
  return ctx.__r;
}

/** Evaluate the REAL guard against a collected plan. true = "rejected as empty". */
function guardRejects(edited) {
  const ctx = { edited, __rejected: null };
  vm.createContext(ctx);
  vm.runInContext(
    'var editedDays = edited && (edited.weekly_plan || edited.days);\n' +
    extractGuard(WORKOUT_SRC) + ' { __rejected = true; } else { __rejected = false; }',
    ctx
  );
  return ctx.__rejected;
}

/* ── Runner ────────────────────────────────────────────────────────────── */
const results = [];
function it(name, fn) {
  try { fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── The collector's contract ──────────────────────────────────────────── */

it('collectEdited keys a workout plan on weekly_plan', () => {
  const plan = runCollect(7, 4);
  assert.ok(Array.isArray(plan.weekly_plan), 'weekly_plan must be the array of days');
  assert.equal(plan.weekly_plan.length, 7);
  assert.equal(plan.days, undefined,
    'a workout plan has no `days` key — the guard must not look for one');
});

it('it captures the edited exercises, not just the day shells', () => {
  const plan = runCollect(3, 5);
  assert.equal(plan.weekly_plan[0].exercises.length, 5);
  assert.equal(plan.weekly_plan[0].exercises[0].name, 'Barbell Squat 0-0');
  assert.equal(plan.weekly_plan[0].exercises[0].sets, 4);
  assert.equal(plan.weekly_plan[0].exercises[0].reps_or_duration, '8-10');
  assert.equal(plan.weekly_plan[0].focus, 'Lower Body 0');
  assert.equal(plan.weekly_plan[0].duration_minutes, 55);
});

/* ── THE REGRESSION ────────────────────────────────────────────────────── */

it('THE BUG: a 7-day plan full of exercises is NOT rejected as empty', () => {
  assert.equal(guardRejects(runCollect(7, 4)), false,
    'this is the bug: every real training plan was refused as "empty"');
});

it('a single edited day is enough to save', () => {
  assert.equal(guardRejects(runCollect(1, 1)), false);
});

it('a day with no exercises still counts as a plan (rest days are valid)', () => {
  assert.equal(guardRejects(runCollect(7, 0)), false,
    'a rest day has no exercises but the plan is not empty');
});

/* ── The exact production request from the bug report ──────────────────
   review_requests/PR_1787123876700_1_y0i7 (reviewType='workout',
   expertId=qEX2DhZVWXd2LcBb9rwnSXGVQkx1, userId=D4MsIE2viMbNpRqkHTdOmcubNam2).
   Its planData carries `weekly_plan` with 7 days, day[0] holding 8 exercises,
   and NO `days` key anywhere — inspected read-only in Firestore. The device
   log shows the run reached "validating final plan" without the
   "Plan is still loading" toast, which means the 7 .mp-day-card elements had
   rendered and collectEdited() really did return 7 days. The only thing that
   made it "empty" was the guard reading .days. */

it('the REAL failing request (7 days x 8 exercises) saves', () => {
  const plan = runCollect(7, 8);
  assert.equal(plan.weekly_plan.length, 7);
  assert.equal(plan.weekly_plan[0].exercises.length, 8);
  assert.equal(plan.days, undefined, 'production planData has no `days` key');
  assert.equal(guardRejects(plan), false,
    'this exact plan produced code=empty_plan on a real Android device');
});

/* ── The guard must still do its job ───────────────────────────────────── */

it('a genuinely empty plan IS still rejected', () => {
  assert.equal(guardRejects(runCollect(0, 0)), true,
    'the empty-plan protection must survive the fix');
});

it('null / undefined / malformed input is still rejected', () => {
  assert.equal(guardRejects(null), true);
  assert.equal(guardRejects(undefined), true);
  assert.equal(guardRejects({}), true);
  assert.equal(guardRejects({ weekly_plan: [] }), true);
});

it('a legacy plan keyed on days is accepted too', () => {
  assert.equal(guardRejects({ days: [{ day: 'Mon' }] }), false,
    'the plan reader accepts either shape; the guard should not be stricter');
});

/* ── The sibling file must not drift the other way ─────────────────────── */

it('modify-diet.js still validates the key ITS collector returns', () => {
  assert.ok(/return \{ days: days \}/.test(DIET_SRC),
    'diet collector no longer returns { days } — its guard must be updated too');
  assert.ok(/!edited\.days/.test(DIET_SRC),
    'the diet guard must keep checking `days`, which is correct for a diet plan');
});

it('the workout guard no longer checks the diet key', () => {
  assert.ok(!/if \(!edited \|\| !edited\.days \|\| !edited\.days\.length\)/.test(WORKOUT_SRC),
    'the copy-pasted diet guard is back in modify-workout.js');
  assert.ok(/edited\.weekly_plan/.test(WORKOUT_SRC),
    'the workout guard must read weekly_plan');
});

it('buildHistory reads the same key the collector writes', () => {
  assert.ok(/editedPlan\.weekly_plan\.forEach/.test(WORKOUT_SRC),
    'history and validation must agree on where the days live');
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  PASS  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
