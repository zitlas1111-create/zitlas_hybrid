/**
 * ZITLAS — the website's Meal Swap result shows no calorie tracking
 * (tests/js/diet-swap-calorie-free.test.mjs)
 *
 * The swap result card used to render 🔥 kcal / 💪 protein / "kcal saved"
 * chips. Calorie tracking is not part of the current diet experience, so the
 * card shows the dish, its foods and why it works — the numbers stay on the
 * swap object the backend returns, they are just not displayed.
 *
 * Runs the REAL renderSwapResult() from diet.js against a stub card.
 *
 * Run:  node tests/js/diet-swap-calorie-free.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const DIET_SRC = readFileSync(
  join(HERE, '..', '..', 'frontend', 'website', 'pages', 'diet', 'diet.js'), 'utf8');

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

const RENDER_SRC = extractFn(DIET_SRC, 'renderSwapResult');

const card = { innerHTML: '' };
const ctx = {
  document: { getElementById: (id) => (id === 'swapResultCard' ? card : null) },
  _swapMealName: 'Breakfast',
};
vm.createContext(ctx);
vm.runInContext(
  `${extractFn(DIET_SRC, 'esc')}\n${RENDER_SRC}\nthis.renderSwapResult = renderSwapResult;`, ctx);

let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failed++;
    console.log(`  ✗ ${name}\n    ${e.message}`);
  }
}

// The exact card from the report: "149 kcal · 6.2g P · 8.2g C · 13.0g F".
const SWAP = {
  swap: {
    name: 'Moong Dal Chilla',
    foods: ['Moong Dal Chilla (2 pieces)', 'Mint Chutney'],
    reason: 'A vegetarian breakfast dish — genuinely high in protein.',
    calories: 149, protein: 6.2, carbs: 8.2, fat: 13.0, calories_saved: 52,
  },
};

console.log('diet-swap-calorie-free');

test('the swap card shows the dish, its foods and why it works', () => {
  ctx.renderSwapResult(SWAP);
  assert.match(card.innerHTML, /Moong Dal Chilla/);
  assert.match(card.innerHTML, /Mint Chutney/);
  assert.match(card.innerHTML, /genuinely high in protein/);
});

test('the swap card shows no calories, macros or "kcal saved"', () => {
  ctx.renderSwapResult(SWAP);
  const html = card.innerHTML;
  assert.doesNotMatch(html, /kcal/i);
  assert.doesNotMatch(html, /\b149\b/);
  assert.doesNotMatch(html, /6\.2\s*g|8\.2\s*g|13(\.0)?\s*g/);
  assert.doesNotMatch(html, /swap-result-macros/);
  assert.doesNotMatch(html, /🔥|💪/);
});

test('renderSwapResult never reads the calorie/macro fields', () => {
  for (const field of ['swap.calories', 'swap.protein', 'swap.carbs', 'swap.fat', 'calories_saved']) {
    assert.ok(!RENDER_SRC.includes(field), `renderSwapResult still reads ${field}`);
  }
});

test('no swap still shows the no-result message', () => {
  ctx.renderSwapResult({});
  assert.match(card.innerHTML, /No suitable alternative found/);
});

if (failed) {
  console.log(`\n${failed} FAILED`);
  process.exitCode = 1;
} else {
  console.log('\nALL PASSED');
}
