/**
 * ZITLAS — Personal Coaching Programs, Phase 2 — website side
 * (tests/js/coaching-program-pricing.test.mjs)
 *
 *   * pricing.html / program-pricing.js — the expert's 10-Day / 1-Month /
 *     3-Month prices: rupees → integer paise, strict validation, saved ONLY
 *     through PUT /api/coaching-programs/pricing (never a Firestore write);
 *   * expert-dashboard.html / program-requests.js — the expert's program
 *     request list with Accept / Decline through /api/coaching-programs.
 *
 * Run:  node tests/js/coaching-program-pricing.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const EXPERTS = join(ROOT, 'frontend', 'website', 'pages', 'experts');
const read = (name) => readFileSync(join(EXPERTS, name), 'utf8');

const PRICING_JS = read('program-pricing.js');
const PRICING_HTML = read('pricing.html');
const REQUESTS_JS = read('program-requests.js');
const DASH_HTML = read('expert-dashboard.html');
const DASH_JS = read('expert-dashboard.js');

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

/* Source with comments removed — a header that EXPLAINS why a collection is
   not used must not fail a check that the code does not use it. */
const code = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

function load(src, names, globals = {}) {
  const ctx = { ...globals };
  vm.createContext(ctx);
  for (const n of names) vm.runInContext(extractFn(src, n), ctx);
  return ctx;
}

const LIMITS = { minPaise: 100, maxPaise: 5000000 };
const P = load(PRICING_JS, ['paiseToRupeesText', 'parseRupeesToPaise', 'collectProgramPrices'], {
  limits: LIMITS,
  PROGRAMS: [{ id: '10_day' }, { id: '1_month' }, { id: '3_month' }],
});
const R = load(REQUESTS_JS,
  ['escHtml', 'groupIndian', 'formatPaise', 'formatRequestedDate', 'statusLine', 'initialsOf', 'cprCardHtml'],
  { MONTHS: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
    STATUS_PENDING: 'pending_expert_acceptance' });

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

/* ── Expert pricing: rupees in, integer paise out ─────────────────────── */

it('valid rupee amounts become exact integer paise', () => {
  const cases = { '499': 49900, '499.5': 49950, '499.50': 49950, '499.05': 49905,
                  ' 4,999 ': 499900, '1': 100, '50000': 5000000, '0.1': null };
  for (const [raw, paise] of Object.entries(cases)) {
    const r = P.parseRupeesToPaise(raw, LIMITS);
    if (paise === null) { assert.equal(r.ok, false, raw); continue; }
    assert.deepEqual({ ok: r.ok, paise: r.paise }, { ok: true, paise }, raw);
    assert.ok(Number.isInteger(r.paise), raw);
  }
});

it('a blank price means "not offered" — never ₹0', () => {
  for (const raw of ['', '   ', null, undefined]) {
    assert.deepEqual({ ...P.parseRupeesToPaise(raw, LIMITS) }, { ok: true, paise: null }, String(raw));
  }
});

it('zero, negatives, NaN, Infinity, exponents and malformed strings are refused', () => {
  const bad = ['0', '0.00', '-5', '-0', 'abc', 'NaN', 'Infinity', '-Infinity', '1e3', '499.555',
               '.5', '5.', '0x10', '+5', '₹499', '4 99', '499,00.5.1', '9999999999'];
  for (const raw of bad) {
    const r = P.parseRupeesToPaise(raw, LIMITS);
    assert.equal(r.ok, false, raw);
    assert.ok(r.error, raw);
  }
});

it('prices outside the safe payment limits are refused', () => {
  assert.equal(P.parseRupeesToPaise('0.99', LIMITS).ok, false);
  assert.equal(P.parseRupeesToPaise('50000.01', LIMITS).ok, false);
  assert.match(P.parseRupeesToPaise('60000', LIMITS).error, /highest price is ₹50000/);
  assert.match(P.parseRupeesToPaise('0.50', LIMITS).error, /lowest price is ₹1/);
});

it('paise display back as rupees without float error', () => {
  assert.equal(P.paiseToRupeesText(49900), '499');
  assert.equal(P.paiseToRupeesText(49950), '499.50');
  assert.equal(P.paiseToRupeesText(49905), '499.05');
  assert.equal(P.paiseToRupeesText(100), '1');
});

it('the three programs are validated together, per field', () => {
  const ok = P.collectProgramPrices({ '10_day': '499', '1_month': '', '3_month': '2999.50' }, LIMITS);
  assert.equal(ok.ok, true);
  assert.deepEqual({ ...ok.prices }, { '10_day': 49900, '1_month': null, '3_month': 299950 });

  const bad = P.collectProgramPrices({ '10_day': '0', '1_month': '999', '3_month': 'abc' }, LIMITS);
  assert.equal(bad.ok, false);
  assert.deepEqual(Object.keys(bad.errors).sort(), ['10_day', '3_month']);
});

it('the pricing card is on the expert Pricing & Services page', () => {
  assert.match(PRICING_HTML, /id="prProgramCard"/);
  assert.match(PRICING_HTML, /Personal Coaching Program Pricing/);
  for (const id of ['prProgram10Day', 'prProgram1Month', 'prProgram3Month']) {
    const input = PRICING_HTML.match(new RegExp(`<input[^>]*id="${id}"[^>]*>`));
    assert.ok(input, id);
    assert.match(input[0], /type="text"/, `${id}: raw text, so "abc" is caught, not silently blanked`);
    assert.match(input[0], /inputmode="decimal"/, id);
    assert.doesNotMatch(input[0], /value="/, `${id}: no hard-coded price`);
  }
  assert.match(PRICING_HTML, /id="prProgramSaveBtn"[^>]*>Save Pricing</);
  assert.ok(PRICING_HTML.indexOf('src="pricing.js"') < PRICING_HTML.indexOf('src="program-pricing.js'));
});

it('program prices are saved through the backend, never written to Firestore', () => {
  assert.match(PRICING_JS, /'\/api\/coaching-programs\/pricing'/);
  assert.match(PRICING_JS, /method === 'GET' \? '\/api\/coaching-programs\/pricing\/me'/);
  assert.match(PRICING_JS, /'Authorization': 'Bearer ' \+ token/);
  assert.match(PRICING_JS, /api\('PUT', \{ prices: result\.prices \}\)/);
  assert.doesNotMatch(PRICING_JS, /ZitlasDB/);
  assert.doesNotMatch(PRICING_JS, /\bdef\s*:\s*\d/, 'no default prices');
});

/* ── Expert request list ───────────────────────────────────────────────── */

const REQ = {
  requestId: 'CPR_1', athleteName: 'Asha Rao', programId: '10_day', programTitle: '10-Day Program',
  durationDays: 10, pricePaise: 499900, currency: 'INR',
  status: 'pending_expert_acceptance', paymentStatus: 'unpaid',
  requestedAt: '2026-09-13T12:00:00+00:00',
};

it('prices use Indian grouping and never show ₹0', () => {
  assert.equal(R.formatPaise(499900), '₹4,999');
  assert.equal(R.formatPaise(12345678), '₹1,23,456.78');
  assert.equal(R.formatPaise(49950), '₹499.50');
  for (const bad of [0, -100, null, undefined, NaN, 1.5, '499']) {
    assert.equal(R.formatPaise(bad), '—', String(bad));
  }
});

it('a pending request shows athlete, program, duration, price, date and both actions', () => {
  const html = R.cprCardHtml(REQ);
  for (const text of ['Asha Rao', '10-Day Program', '10 days', '₹4,999', 'Requested 13 Sep 2026',
                      'Awaiting your response']) {
    assert.ok(html.includes(text), text);
  }
  assert.match(html, /class="erc-btn erc-btn--primary cpr-accept"[^>]*>Accept</);
  assert.match(html, /class="erc-btn erc-btn--secondary cpr-decline"[^>]*>Decline</);
});

it('accepted and declined requests show their status and no actions', () => {
  const accepted = R.cprCardHtml({ ...REQ, status: 'accepted' });
  assert.match(accepted, /Accepted — payment pending/);
  assert.doesNotMatch(accepted, /cpr-accept|cpr-decline/);
  const declined = R.cprCardHtml({ ...REQ, status: 'declined' });
  assert.match(declined, /Declined/);
  assert.doesNotMatch(declined, /cpr-accept|cpr-decline/);
});

it('a paid program shows as active until its end date, with no actions', () => {
  const html = R.cprCardHtml({ ...REQ, status: 'active', paymentStatus: 'paid',
                              endsAt: '2026-09-23T12:00:00+00:00' });
  assert.match(html, /Paid — program active until 23 Sep 2026/);
  assert.doesNotMatch(html, /cpr-accept|cpr-decline/);
});

it('athlete-supplied text is escaped', () => {
  const html = R.cprCardHtml({ ...REQ, athleteName: '<img src=x onerror=alert(1)>', programTitle: '"><b>x' });
  assert.doesNotMatch(html, /<img|<b>/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
});

/* Runs the real file against a stand-in DOM: list → Accept → the right
   endpoint, with the expert's token, and a refresh afterwards. */
it('Accept calls the program endpoint with the expert\'s token, then refreshes', async () => {
  const calls = [];
  const mkBtn = (kind) => ({ kind, disabled: false, handlers: {},
    addEventListener(t, fn) { this.handlers[t] = fn; } });
  const cards = [];
  const el = (extra = {}) => ({ style: {}, textContent: '', addEventListener() {}, ...extra });
  const nodes = {
    cprBlock: el(),
    cprEmpty: el(),
    cprPendingCount: el(),
    cprRefresh: el(),
    cprRequestList: el({ querySelectorAll: () => [], appendChild: (c) => cards.push(c) }),
  };
  const document = {
    readyState: 'complete',
    getElementById: (id) => nodes[id] || null,
    querySelector: () => null,
    createElement: () => {
      const card = { style: {}, attrs: {}, buttons: [], _html: '',
        setAttribute(k, v) { this.attrs[k] = v; },
        set innerHTML(h) {
          this._html = h;
          this.buttons = ['accept', 'decline'].filter((k) => h.includes('cpr-' + k)).map(mkBtn);
        },
        get innerHTML() { return this._html; },
        querySelector(sel) { return this.buttons.find((b) => sel === '.cpr-' + b.kind) || null; },
        querySelectorAll(sel) { return sel === 'button' ? this.buttons : []; },
        remove() {} };
      return card;
    },
  };
  let list = [REQ];
  const toasts = [];
  const ctx = {
    document, window: {}, console: { log() {}, warn() {}, error() {} },
    getIdToken: async () => 'TOKEN',
    edShowToast: (m) => toasts.push(m),
    fetch: async (url, opts) => {
      calls.push({ url, method: opts.method, auth: opts.headers.Authorization });
      if (url.endsWith('/accept')) {
        list = [{ ...REQ, status: 'accepted' }];
        return { status: 200, json: async () => ({ success: true,
          message: 'Program request accepted. Payment is pending.' }) };
      }
      return { status: 200, json: async () => ({ requests: list, pendingCount: 1 }) };
    },
  };
  vm.createContext(ctx);
  vm.runInContext(REQUESTS_JS, ctx);
  const flush = () => new Promise((r) => setTimeout(r, 0));

  await ctx.window.ZitlasProgramRequests.refresh();
  assert.deepEqual(calls[0], { url: '/api/coaching-programs/requests/expert', method: 'GET', auth: 'Bearer TOKEN' });
  assert.equal(cards.length, 1);
  assert.equal(nodes.cprPendingCount.textContent, 1);

  cards[0].querySelector('.cpr-accept').handlers.click();
  for (let i = 0; i < 10; i++) await flush();
  assert.deepEqual(calls[1], { url: '/api/coaching-programs/requests/CPR_1/accept', method: 'POST', auth: 'Bearer TOKEN' });
  assert.deepEqual(toasts, ['Program request accepted. Payment is pending.']);
  assert.equal(calls[2].url, '/api/coaching-programs/requests/expert', 'the list refreshes');
  assert.equal(cards.at(-1).buttons.length, 0, 'an accepted request has no actions left');
});

it('the request list never touches Firestore or the old coaching endpoints', () => {
  assert.doesNotMatch(code(REQUESTS_JS), /ZitlasDB|personal_coach_requests|\/api\/coaching\/(accept|reject|request)/);
  assert.match(REQUESTS_JS, /'\/api\/coaching-programs\/requests\/' \+ encodeURIComponent\(id\) \+ '\/' \+ decision/);
});

it('the section sits inside Personal Coaching on the expert dashboard', () => {
  const start = DASH_HTML.indexOf('id="sectionCoaching"');
  const end = DASH_HTML.indexOf('id="sectionChats"');
  const block = DASH_HTML.indexOf('id="cprBlock"');
  assert.ok(start !== -1 && start < block && block < end);
  assert.match(DASH_HTML, /Personal Coaching Program Requests/);
  assert.ok(DASH_HTML.indexOf('src="expert-dashboard.js') < DASH_HTML.indexOf('src="program-requests.js'));
});

it('the existing Personal Coaching inbox is unchanged', () => {
  assert.match(DASH_HTML, /id="pcRequestList"/);
  assert.match(DASH_JS, /var endpoint = newStatus === 'accepted' \? '\/api\/coaching\/accept' : '\/api\/coaching\/reject';/);
  assert.match(DASH_JS, /ZitlasDB\.collection\('personal_coach_requests'\)/);
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
