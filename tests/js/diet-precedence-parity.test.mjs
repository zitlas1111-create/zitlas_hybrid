/**
 * ZITLAS — ONE diet precedence rule, website side
 * (tests/js/diet-precedence-parity.test.mjs)
 *
 * Runs EVERY case in tests/fixtures/diet_precedence_cases.json against the
 * website's rule (frontend/website/assets/js/diet-precedence.js). The app
 * runs the SAME file against its own implementation in
 * mobile/test/diet_precedence_parity_test.dart — so for identical Firestore
 * state the two clients cannot choose different diets.
 *
 * Run:  node tests/js/diet-precedence-parity.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const SRC = readFileSync(join(ROOT, 'frontend', 'website', 'assets', 'js', 'diet-precedence.js'), 'utf8');
const FIXTURE = JSON.parse(readFileSync(join(ROOT, 'tests', 'fixtures', 'diet_precedence_cases.json'), 'utf8'));

const clone = (v) => JSON.parse(JSON.stringify(v));

/* "$NAME" -> defs.NAME; {"$ref": "NAME", ...} -> defs.NAME with the rest on top. */
function resolve(v) {
  if (typeof v === 'string' && v.startsWith('$')) {
    const def = FIXTURE.defs[v.slice(1)];
    if (def === undefined) throw new Error('unknown def ' + v);
    return resolve(clone(def));
  }
  if (Array.isArray(v)) return v.map(resolve);
  if (v && typeof v === 'object') {
    let out = {};
    if (v.$ref) {
      const def = FIXTURE.defs[v.$ref];
      if (def === undefined) throw new Error('unknown def ' + v.$ref);
      out = resolve(clone(def));
    }
    for (const [k, x] of Object.entries(v)) if (k !== '$ref') out[k] = resolve(x);
    return out;
  }
  return v;
}

const ctx = { window: {} };
vm.createContext(ctx);
vm.runInContext(SRC, ctx);
const P = ctx.window.ZitlasDietPrecedence;

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

for (const c of FIXTURE.cases) {
  it(c.name, () => assert.equal(P.selectDietSource(resolve(c.state)), c.expected));
}

it('the fixture covers every source and every name is unique', () => {
  const names = FIXTURE.cases.map((c) => c.name);
  assert.equal(new Set(names).size, names.length);
  assert.deepEqual([...new Set(FIXTURE.cases.map((c) => c.expected))].sort(),
    ['ai', 'ai_master', 'coach', 'expert', 'none']);
});

it('a Firestore Timestamp end date is read like an ISO one', () => {
  const state = resolve(FIXTURE.cases[0].state);
  state.relationship.endDate = undefined;
  state.relationship.endDateTs = { toDate: () => new Date('2026-09-13T11:00:00Z') };
  assert.equal(P.selectDietSource(state), 'ai');
  state.relationship.endDateTs = { seconds: Date.parse('2026-09-20T00:00:00Z') / 1000 };
  assert.equal(P.selectDietSource(state), 'coach');
});

it('diet.js uses this rule for the coaching diet and loads it first', () => {
  const DIET = readFileSync(join(ROOT, 'frontend', 'website', 'pages', 'diet', 'diet.js'), 'utf8');
  const HTML = readFileSync(join(ROOT, 'frontend', 'website', 'pages', 'diet', 'diet.html'), 'utf8');
  assert.match(DIET, /ZitlasDietPrecedence\.coachDietActive\(/);
  assert.ok(HTML.indexOf('diet-precedence.js') !== -1 && HTML.indexOf('diet-precedence.js') < HTML.indexOf('diet.js?v='));
});

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
