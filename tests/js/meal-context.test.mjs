/**
 * ZITLAS — "What is this meal?" (tests/js/meal-context.test.mjs)
 *
 * Before a meal photo goes to the coach, the athlete says what it is: quick
 * chips (Chicken, Rice, …) and/or their own words via "Other". The answer is
 * stored on the SAME meal_checkins document as `mealContext` and shown to the
 * coach beside the photo.
 *
 * WHAT THESE GUARD
 * ----------------
 *   - the payload is the app's, case for case (mobile/test/meal_context_test.dart
 *     runs the same cases), so either client reads what the other wrote;
 *   - the answer travels through the EXISTING upload, Firestore write and coach
 *     notifications — there is no second upload path;
 *   - a failed upload keeps the sheet and the answer for a one-tap retry;
 *   - the coach's view escapes the text (it is user-written) and check-ins sent
 *     before this step render as they always did.
 *
 * Run:  node tests/js/meal-context.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const DIET = readFileSync(join(ROOT, 'frontend', 'website', 'pages', 'diet', 'diet.js'), 'utf8');
const CW = readFileSync(join(ROOT, 'frontend', 'website', 'components', 'coaching-workspace.js'), 'utf8');
const DART = readFileSync(
  join(ROOT, 'mobile', 'lib', 'features', 'coaching', 'models', 'meal_context.dart'), 'utf8');

/* ── Pull the real functions out of the shipping files ─────────────────── */
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

// Objects made inside a vm context carry that realm's prototypes.
const plain = (v) => JSON.parse(JSON.stringify(v));
const unesc = (s) => s.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const settle = () => new Promise((r) => setImmediate(r));

const CONSTS = DIET.slice(DIET.indexOf('var MEAL_QUICK_ITEMS'), DIET.indexOf('function _pcBuildMealContext'));
const FILE = { name: 'lunch.jpg', type: 'image/jpeg', size: 4096 };
const ANSWER = { items: ['Chicken', 'Rice'], custom: null, description: 'Chicken + Rice', source: 'user' };
const STORAGE_URL = 'https://firebasestorage.googleapis.com/v0/b/zitlas-b8677.firebasestorage.app' +
  '/o/meal_checkins%2Fathlete-1%2F1.jpg?alt=media';

function builder() {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(CONSTS + extractFn(DIET, '_pcBuildMealContext'), ctx);
  return ctx;
}

/* The preview sheet, with just enough DOM for what it touches. */
function preview() {
  const state = { sheetHtml: '', sends: [], retakes: [] };
  const els = {};
  const handlers = {};
  const on = (key, ev, fn) => { (handlers[key] ||= {})[ev] = fn; };
  function el(id) {
    if (!els[id]) {
      let html = '';
      els[id] = {
        id, value: '', hidden: false, textContent: '', style: {}, focused: false,
        addEventListener: (ev, fn) => on(id, ev, fn),
        focus() { this.focused = true; },
        get innerHTML() { return html; },
        set innerHTML(v) { html = v; },
        querySelectorAll(sel) {
          const attr = sel.slice(1, -1); // "[data-pc-meal]" -> "data-pc-meal"
          return [...html.matchAll(new RegExp(attr + '="([^"]*)"', 'g'))].map((m) => {
            const value = unesc(m[1]);
            return { getAttribute: () => value, addEventListener: (ev, fn) => on(attr + '=' + value, ev, fn) };
          });
        },
      };
    }
    return els[id];
  }
  const ctx = {
    console: { log() {} },
    document: { getElementById: el },
    URL: { createObjectURL: () => 'blob:preview', revokeObjectURL() {} },
    _pcOpenSheet: (html) => { state.sheetHtml = html; },
    _pcSendCheckin: (file, meal, url, answer) => state.sends.push(plain(answer)),
    openMealCheckinCamera: (meal, draft) => state.retakes.push({ meal, draft }),
  };
  vm.createContext(ctx);
  vm.runInContext(
    CONSTS + extractFn(DIET, '_pcBuildMealContext') + '\n' +
    extractFn(DIET, 'esc') + '\n' + extractFn(DIET, '_pcOpenCheckinPreview'), ctx);
  const fire = (key, ev = 'click') => {
    assert.ok(handlers[key] && handlers[key][ev], `nothing listens for ${ev} on ${key}`);
    handlers[key][ev]();
  };
  const values = (id, attr) =>
    [...el(id).innerHTML.matchAll(new RegExp(attr + '="([^"]*)"', 'g'))].map((m) => unesc(m[1]));
  return {
    state, el,
    open: (draft) => ctx._pcOpenCheckinPreview(FILE, { meal_name: 'Lunch' }, draft),
    tap: (item) => fire('data-pc-meal=' + item),
    remove: (item) => fire('data-pc-meal-remove=' + item),
    press: (id) => fire(id),
    type: (text) => { el('pcMealOther').value = text; fire('pcMealOther', 'input'); },
    chips: () => values('pcMealChips', 'data-pc-meal'),
    selected: () => values('pcMealSelected', 'data-pc-meal-remove'),
  };
}

/* _pcSendCheckin with the upload, Firestore and notifications stubbed. */
function sender({ uploadFailures = 0 } = {}) {
  const state = { uploads: [], writes: [], notified: [], pushes: [], toasts: [], closed: 0 };
  const els = {
    pcSendCheckin: { disabled: false, textContent: 'Send to Coach' },
    pcMealError: { textContent: '' },
  };
  let failures = uploadFailures;
  const ctx = {
    console: { log() {}, warn() {}, error() {} },
    document: { getElementById: (id) => els[id] || null },
    URL: { revokeObjectURL() {} },
    ZitlasChatAttach: {
      upload(file, opts) {
        state.uploads.push(plain(opts));
        return failures-- > 0
          ? Promise.reject(new Error('Upload failed — check your connection.'))
          : Promise.resolve(STORAGE_URL);
      },
    },
    _pcEstimateNutrition: () => Promise.resolve(null),
    _pcUid: () => 'athlete-1',
    _pcAthleteName: () => 'Asha',
    _pcRel: { coachId: 'coach-9' },
    _pcTodayName: () => 'Friday',
    ZitlasDB: {
      collection: (name) => ({
        doc: (id) => ({ set: (data) => { state.writes.push({ name, id, data: plain(data) }); return Promise.resolve(); } }),
      }),
    },
    ZitlasNotify: {
      send: (to, n) => state.notified.push({ to, ...plain(n) }),
      pushMealCheckin: (id) => state.pushes.push(id),
    },
    _pcCloseSheet: () => { state.closed++; },
    showToast: (m) => state.toasts.push(m),
  };
  vm.createContext(ctx);
  vm.runInContext(extractFn(DIET, '_pcSendCheckin'), ctx);
  const send = async (answer) => {
    ctx._pcSendCheckin(FILE, { meal_name: 'Lunch' }, 'blob:preview', answer);
    await settle();
    await settle();
  };
  return { state, els, send };
}

function coach() {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(
    extractFn(CW, 'esc') + '\n' + extractFn(CW, '_cwMealDesc') + '\n' + extractFn(CW, '_cwMealDescMarkup'), ctx);
  return ctx;
}

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

/* ── The payload — the SAME cases as mobile/test/meal_context_test.dart ── */

const SHARED = [
  [{ items: ['Chicken', 'Rice'], otherOn: false, custom: '' },
    { items: ['Chicken', 'Rice'], custom: null, description: 'Chicken + Rice', source: 'user' }],
  [{ items: [], otherOn: true, custom: '  Chicken curry with steamed rice  ' },
    { items: [], custom: 'Chicken curry with steamed rice', description: 'Chicken curry with steamed rice', source: 'user' }],
  [{ items: ['Rice', 'rice', 'Dal', 'Rice'], otherOn: true, custom: 'RICE' },
    { items: ['Rice', 'Dal'], custom: 'RICE', description: 'Rice + Dal', source: 'user' }],
  [{ items: ['Paneer'], otherOn: true, custom: "Mom's  Sunday thali — 2 rotis 🍛" },
    { items: ['Paneer'], custom: "Mom's  Sunday thali — 2 rotis 🍛", description: "Paneer + Mom's  Sunday thali — 2 rotis 🍛", source: 'user' }],
  [{ items: ['Dal'], otherOn: false, custom: 'Poha' },
    { items: ['Dal'], custom: null, description: 'Dal', source: 'user' }],
];
for (const [draft, stored] of SHARED) {
  it(`payload → ${JSON.stringify(stored.description)} (same as the app)`, () => {
    const built = builder()._pcBuildMealContext(draft);
    assert.equal(built.error, undefined);
    assert.deepEqual(plain(built.context), stored);
  });
}

it('nothing chosen is refused — never guessed', () => {
  assert.equal(builder()._pcBuildMealContext({ items: [], otherOn: false, custom: '' }).error,
    'Pick what this meal is, or type it in.');
});

it('"Other" with only spaces is refused', () => {
  assert.equal(builder()._pcBuildMealContext({ items: ['Dal'], otherOn: true, custom: '   ' }).error,
    'Enter a meal name, or unselect Other.');
});

it('the custom name is capped at 200 — the cap itself allowed', () => {
  const b = builder();
  const atCap = 'a'.repeat(200);
  assert.equal(b._pcBuildMealContext({ items: [], otherOn: true, custom: atCap }).context.custom, atCap);
  assert.equal(b._pcBuildMealContext({ items: [], otherOn: true, custom: atCap + 'b' }).error,
    'Keep the meal name within 200 characters.');
});

it('the chips, the cap and the messages are the SAME in the app', () => {
  const b = builder();
  const dartItems = [...DART.match(/const kMealQuickItems = <String>\[([\s\S]*?)\];/)[1].matchAll(/'([^']+)'/g)]
    .map((m) => m[1]);
  assert.deepEqual([...b.MEAL_QUICK_ITEMS], dartItems);
  assert.deepEqual(dartItems,
    ['Biryani', 'Chicken', 'Paratha', 'Rice', 'Dal', 'Eggs', 'Salad', 'Roti', 'Vegetables', 'Paneer']);
  assert.equal(b.MEAL_CUSTOM_MAX, Number(DART.match(/const kMealCustomMaxLength = (\d+);/)[1]));
  for (const msg of ['Pick what this meal is, or type it in.', 'Enter a meal name, or unselect Other.']) {
    assert.ok(DART.includes(msg), `app is missing: ${msg}`);
  }
});

/* ── The confirmation sheet ─────────────────────────────────────────────── */

it('the sheet asks the question and offers every chip plus Other', () => {
  const p = preview();
  p.open();
  const html = p.state.sheetHtml;
  assert.ok(html.includes('What is this meal?'));
  assert.ok(html.includes("Tell your coach what you're eating."));
  assert.ok(html.includes('<img src="blob:preview"'), 'the photo thumbnail');
  assert.ok(html.includes('>Enter meal name</label>'));
  assert.ok(html.includes('maxlength="200"'));
  assert.ok(html.includes('>Change Photo</button>'));
  assert.ok(html.includes('>Send to Coach</button>'));
  assert.deepEqual(p.chips(),
    ['Biryani', 'Chicken', 'Paratha', 'Rice', 'Dal', 'Eggs', 'Salad', 'Roti', 'Vegetables', 'Paneer', 'Other']);
  assert.equal(p.el('pcMealOtherWrap').hidden, true, 'the name field waits for Other');
});

it('several chips at once, never twice, each removable; Other opens the name field', () => {
  const p = preview();
  p.open();
  p.tap('Chicken'); p.tap('Rice'); p.tap('Dal');
  assert.deepEqual(p.selected(), ['Chicken', 'Rice', 'Dal']);
  p.tap('Rice'); // tapping a picked chip again unpicks it
  assert.deepEqual(p.selected(), ['Chicken', 'Dal']);
  p.remove('Dal'); // the × on a selected chip
  assert.deepEqual(p.selected(), ['Chicken']);
  p.tap('Other');
  assert.equal(p.el('pcMealOtherWrap').hidden, false);
  assert.equal(p.el('pcMealOther').focused, true);
  p.press('pcSendCheckin');
  assert.equal(p.el('pcMealError').textContent, 'Enter a meal name, or unselect Other.');
  assert.equal(p.state.sends.length, 0);
});

it('Send validates first — nothing chosen sends nothing', () => {
  const p = preview();
  p.open();
  p.press('pcSendCheckin');
  assert.equal(p.state.sends.length, 0);
  assert.equal(p.el('pcMealError').textContent, 'Pick what this meal is, or type it in.');
});

it('a typed name alone is sent — trimmed, otherwise exact', () => {
  const p = preview();
  p.open();
  p.tap('Other');
  p.type('  Chicken curry with steamed rice  ');
  p.press('pcSendCheckin');
  assert.deepEqual(p.state.sends, [{
    items: [], custom: 'Chicken curry with steamed rice',
    description: 'Chicken curry with steamed rice', source: 'user',
  }]);
});

it('Change Photo re-opens the existing camera with the answer, and the next preview restores it', () => {
  const p = preview();
  p.open();
  p.tap('Chicken');
  p.tap('Other');
  p.type('with raita');
  p.press('pcRetake');
  assert.equal(p.state.sends.length, 0, 'changing the photo sends nothing');
  const { meal, draft } = p.state.retakes[0];
  assert.equal(meal.meal_name, 'Lunch');
  assert.deepEqual(plain(draft), { items: ['Chicken'], otherOn: true, custom: 'with raita' });

  p.open(draft); // what the camera does with the new photo
  assert.deepEqual(p.selected(), ['Chicken']);
  assert.equal(p.el('pcMealOther').value, 'with raita');
  assert.equal(p.el('pcMealOtherWrap').hidden, false);
  p.press('pcSendCheckin');
  assert.equal(p.state.sends[0].description, 'Chicken + with raita');
});

it('the camera hands the carried answer to the new preview', () => {
  assert.match(extractFn(DIET, 'openMealCheckinCamera'), /_pcOpenCheckinPreview\(f, meal, draft\)/);
});

/* ── Sending: the EXISTING path ─────────────────────────────────────────── */

it('the answer rides the SAME upload and the SAME meal_checkins write', async () => {
  const { state, send } = sender();
  await send(ANSWER);

  assert.deepEqual(state.uploads, [{ pathPrefix: 'meal_checkins', requireDurable: true }]);
  const checkins = state.writes.filter((w) => w.name === 'meal_checkins');
  assert.equal(checkins.length, 1);
  const doc = checkins[0].data;
  assert.deepEqual(doc.mealContext, ANSWER);
  assert.equal(checkins[0].id, doc.checkinId);
  assert.equal(doc.imageUrl, STORAGE_URL);
  assert.equal(doc.status, 'pending');
  assert.equal(doc.athleteId, 'athlete-1');
  assert.equal(doc.coachId, 'coach-9');
  assert.equal(doc.mealName, 'Lunch');
  assert.equal(doc.mealType, 'lunch');
  // The coach is told exactly as before.
  assert.equal(state.writes.filter((w) => w.name === 'coaching_notifications').length, 1);
  assert.equal(state.notified.length, 1);
  assert.deepEqual(state.pushes, [doc.checkinId]);
  assert.equal(state.closed, 1);
  assert.deepEqual(state.toasts, ['✅ Sent to your coach for review.']);
});

it('a check-in sent without an answer keeps its old shape', async () => {
  const { state, send } = sender();
  await send(undefined);
  const doc = state.writes.find((w) => w.name === 'meal_checkins').data;
  assert.equal('mealContext' in doc, false);
});

it('a failed upload writes nothing and keeps the sheet — the retry sends the same answer', async () => {
  const { state, els, send } = sender({ uploadFailures: 1 });
  await send(ANSWER);
  assert.equal(state.writes.length, 0);
  assert.equal(state.closed, 0, 'the sheet — and the answer on it — stays open');
  assert.equal(els.pcSendCheckin.disabled, false);
  assert.equal(els.pcSendCheckin.textContent, 'Send to Coach');
  assert.match(els.pcMealError.textContent, /Upload failed/);

  await send(ANSWER);
  const checkins = state.writes.filter((w) => w.name === 'meal_checkins');
  assert.equal(checkins.length, 1);
  assert.deepEqual(checkins[0].data.mealContext, ANSWER);
  assert.equal(state.closed, 1);
});

/* ── The coach's view ───────────────────────────────────────────────────── */

it('the answer is on the review card and in both review sheets', () => {
  // openCheckinReviewSheet only seeds the rating draft; renderCheckinReviewSheet
  // builds that sheet's markup.
  for (const fn of ['renderCheckins', 'renderCheckinReviewSheet', 'openCheckinHistorySheet']) {
    assert.match(extractFn(CW, fn), /_cwMealDescMarkup\(c\)/, fn);
  }
});

it('user-written text is escaped — never markup', () => {
  const html = coach()._cwMealDescMarkup({ mealContext: { description: '<img src=x onerror=alert(1)> & "chai"' } });
  assert.ok(!html.includes('<img'), html);
  assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt; &amp; &quot;chai&quot;'), html);
});

it('reads either client\'s payload — description first, items + custom otherwise', () => {
  const c = coach();
  assert.equal(c._cwMealDesc({ mealContext: ANSWER }), 'Chicken + Rice');
  assert.equal(c._cwMealDesc({ mealContext: { items: [' Dal '], custom: 'jeera rice' } }), 'Dal + jeera rice');
});

it('old check-ins and malformed values add nothing to the card', () => {
  const c = coach();
  for (const doc of [{}, { mealName: 'Lunch' }, { mealContext: null }, { mealContext: 'Chicken' },
    { mealContext: { items: 'Chicken' } }, { mealContext: { items: ['  ', 5] } }]) {
    assert.equal(c._cwMealDescMarkup(doc), '', JSON.stringify(doc));
  }
});

/* ── Run ────────────────────────────────────────────────────────────────── */
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
