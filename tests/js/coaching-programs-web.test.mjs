/**
 * ZITLAS — Personal Coaching Programs on the WEBSITE: the same product as the app
 * (tests/js/coaching-programs-web.test.mjs)
 *
 * assets/js/coaching-programs-flow.js is the website's flow. What this pins:
 *   1. PARITY WITH THE APP, read from the app's own Dart source — the three
 *      programs' copy, every status/result message, every refusal message,
 *      and the price formatting;
 *   2. THE SAME BACKEND RULES — the real controller, against a stand-in for
 *      /api/coaching-programs: restore on open (GET /requests/me), choose an
 *      expert, request (once), expert answers, Pay & Start, a short wallet,
 *      a frozen wallet, failures;
 *   3. THE PAGE only renders what the flow says — it never prices, dates or
 *      calls any other API.
 * The page itself is driven in real Chrome by tests/e2e/coaching_programs/.
 *
 * Run:  node tests/js/coaching-programs-web.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const read = (...p) => readFileSync(join(ROOT, ...p), 'utf8');

const FLOW_SRC = read('frontend', 'website', 'assets', 'js', 'coaching-programs-flow.js');
const PAGE_JS = read('frontend', 'website', 'pages', 'coaching-programs', 'coaching-programs.js');
const PAGE_HTML = read('frontend', 'website', 'pages', 'coaching-programs', 'coaching-programs.html');
const DART_COPY = read('mobile', 'lib', 'features', 'coaching_programs', 'coaching_programs.dart');
const DART_REPO = read('mobile', 'lib', 'features', 'coaching_programs', 'data', 'coaching_programs_repository.dart');
const DART_WALLET = read('mobile', 'lib', 'features', 'payments', 'wallet_freeze.dart');

const quiet = { log() {}, warn() {}, error() {} };
const ctx = { window: {}, console: quiet };
vm.createContext(ctx);
vm.runInContext(FLOW_SRC, ctx);
const F = ctx.window.ZitlasProgramsFlow;
const plain = (v) => JSON.parse(JSON.stringify(v));

/* ── Reading the app's Dart source ────────────────────────────────────── */

/* Adjacent Dart string literals, joined — exactly how Dart reads them. */
function dartStrings(expr) {
  const out = [];
  const re = /'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"/g;
  let m;
  while ((m = re.exec(expr))) out.push((m[1] ?? m[2]).replace(/\\(['"$\\])/g, '$1'));
  return out.join('');
}

function dartConst(src, name) {
  const m = src.match(new RegExp(`const (?:\\w+\\s+)?${name}\\s*=\\s*([\\s\\S]*?);\\n`));
  assert.ok(m, `${name} not found in the app source`);
  return dartStrings(m[1]);
}

/* CoachingProgramsRepository.messageFor's `case 'code': return '…';` table. */
function dartCodeMessages() {
  const start = DART_REPO.indexOf('static String messageFor(ApiException e)');
  const body = DART_REPO.slice(start, DART_REPO.indexOf('\n  }\n', start));
  const out = {};
  let pending = [];
  for (const line of body.split('\n')) {
    const c = line.match(/case '(\w+)':/);
    if (c) { pending.push(c[1]); continue; }
    const r = line.match(/return (.+);\s*$/);
    if (r && pending.length) {
      const msg = dartStrings(r[1]);
      pending.forEach((code) => { out[code] = msg; });
      pending = [];
    }
  }
  return out;
}

/* kCoachingPrograms: id, title, durationLabel, description, highlights. */
function dartPrograms() {
  const list = DART_COPY.slice(DART_COPY.indexOf('const kCoachingPrograms'), DART_COPY.indexOf('];', DART_COPY.indexOf('const kCoachingPrograms')));
  return list.split('CoachingProgram(').slice(1).map((block) => ({
    id: dartStrings(block.match(/id:\s*('[^']*')/)[1]),
    title: dartStrings(block.match(/title:\s*('[^']*')/)[1]),
    durationLabel: dartStrings(block.match(/durationLabel:\s*('[^']*')/)[1]),
    description: dartStrings(block.match(/description:\s*('[^']*'|"[^"]*")/)[1]),
    highlights: [...block.match(/highlights:\s*\[([\s\S]*?)\]/)[1].matchAll(/'((?:[^'\\]|\\.)*)'/g)].map((m) => m[1]),
  }));
}

const MESSAGE_TO_DART = {
  unavailable: 'kProgramUnavailable',
  chooseExpertToPrice: 'kProgramChooseExpertToPrice',
  chooseAnotherExpert: 'kProgramChooseAnotherExpert',
  pickExpertTitle: 'kProgramPickExpertTitle',
  noExperts: 'kProgramNoExperts',
  expertsLoadFailed: 'kProgramExpertsLoadFailed',
  expertLoadFailed: 'kProgramExpertLoadFailed',
  requestSent: 'kProgramRequestSent',
  alreadyRequested: 'kProgramAlreadyRequested',
  otherRequestOpen: 'kProgramOtherRequestOpen',
  otherRunning: 'kProgramOtherRunning',
  paymentUnconfirmed: 'kProgramPaymentUnconfirmed',
  pendingTitle: 'kProgramPendingTitle',
  pendingBody: 'kProgramPendingBody',
  acceptedTitle: 'kProgramAcceptedTitle',
  acceptedBody: 'kProgramAcceptedBody',
  payLabel: 'kProgramPayLabel',
  activeTitle: 'kProgramActiveTitle',
  endedTitle: 'kProgramEndedTitle',
  completedTitle: 'kProgramCompletedTitle',
  statusUnknownTitle: 'kProgramStatusUnknownTitle',
  statusUnknownBody: 'kProgramStatusUnknownBody',
  started: 'kProgramStarted',
  alreadyPaid: 'kProgramAlreadyPaid',
  shortfall: 'kProgramShortfallMessage',
  fundsAddedReady: 'kProgramFundsAddedReady',
  fundsAddedShort: 'kProgramFundsAddedShort',
  declinedTitle: 'kProgramDeclinedTitle',
  declinedBody: 'kProgramDeclinedBody',
};

/* ── A stand-in for /api/coaching-programs ────────────────────────────── */

const PRICES = {
  'coach-1': { '10_day': 499900, '1_month': 1299900, '3_month': 3499900 },
  'coach-2': { '10_day': 399900, '1_month': 999900 },
};
const NAMES = { 'coach-1': 'Asha Rao', 'coach-2': 'Vikram Shah' };
const DAYS = { '10_day': 10, '1_month': 30, '3_month': 90 };

function backend(opts = {}) {
  const b = {
    request: opts.request || null,
    calls: [],
    posts: [],
    pays: 0,
    meStatus: 200,
    expertsStatus: 200,
    postAnswer: null,     // [status, body]
    payAnswer: null,      // [status, body]
    offline: false,
  };
  const res = (status, body) => ({ status, json: () => Promise.resolve(body) });
  b.req = (expertId, programId, status, paymentStatus = 'unpaid') => ({
    requestId: 'CPR_1', athleteId: 'me', expertId, expertName: NAMES[expertId], programId,
    programTitle: 'Program', programType: 'diet', durationDays: DAYS[programId],
    pricePaise: PRICES[expertId][programId], currency: 'INR', status, paymentStatus,
    requestedAt: '2026-09-13T06:00:00+00:00',
  });
  b.fetch = (url, init = {}) => {
    const method = init.method || 'GET';
    const path = url.replace(F.API, '');
    b.calls.push(`${method} ${path}`);
    b.lastAuth = init.headers && init.headers.Authorization;
    if (b.offline) return Promise.reject(new TypeError('Failed to fetch'));
    if (method === 'GET' && path === '/requests/me') {
      if (b.meStatus !== 200) return Promise.resolve(res(b.meStatus, { detail: 'firestore_unavailable' }));
      const r = b.request;
      const current = r && (r.status === 'pending_expert_acceptance' || r.status === 'accepted' ||
        (r.status === 'active' && (!r.endsAt || new Date(r.endsAt) > new Date()))) ? r : null;
      return Promise.resolve(res(200, { requests: r ? [r] : [], current }));
    }
    let m = path.match(/^\/programs\/([^/]+)\/experts$/);
    if (method === 'GET' && m) {
      if (b.expertsStatus !== 200) return Promise.resolve(res(b.expertsStatus, { detail: 'firestore_unavailable' }));
      const pid = decodeURIComponent(m[1]);
      return Promise.resolve(res(200, {
        programId: pid,
        experts: Object.keys(PRICES).filter((id) => PRICES[id][pid]).map((id) => ({
          expertId: id, expertName: NAMES[id], specialization: 'Sports Nutritionist',
          expertise: id === 'coach-1' ? ['Fat loss', 'Muscle gain'] : [],
          photoUrl: id === 'coach-2' ? 'https://images.test/v.jpg' : 'javascript:alert(1)',
          pricePaise: PRICES[id][pid],
        })),
      }));
    }
    m = path.match(/^\/experts\/([^/]+)$/);
    if (method === 'GET' && m) {
      const id = decodeURIComponent(m[1]);
      if (!PRICES[id]) return Promise.resolve(res(404, { detail: 'expert_not_found' }));
      return Promise.resolve(res(200, {
        expertId: id, expertName: NAMES[id], currency: 'INR',
        programs: Object.keys(DAYS).map((pid) => ({ programId: pid, pricePaise: PRICES[id][pid] ?? null, available: !!PRICES[id][pid] })),
        request: b.request && b.request.expertId === id ? b.request : null,
      }));
    }
    if (method === 'POST' && path === '/requests') {
      const body = JSON.parse(init.body);
      b.posts.push(body);
      if (b.postAnswer) return Promise.resolve(res(...b.postAnswer));
      b.request = b.req(body.expertId, body.programId, 'pending_expert_acceptance');
      return Promise.resolve(res(200, { success: true, alreadyRequested: false, request: b.request }));
    }
    if (method === 'POST' && path === '/requests/CPR_1/pay') {
      b.pays += 1;
      b.payBody = init.body;
      if (b.payAnswer) return Promise.resolve(res(...b.payAnswer));
      const start = new Date();
      const end = new Date(start.getTime() + b.request.durationDays * 86400000);
      b.request = { ...b.request, status: 'active', paymentStatus: 'paid', startedAt: start.toISOString(),
        endsAt: end.toISOString(), amountPaidPaise: b.request.pricePaise };
      return Promise.resolve(res(200, { success: true, already: false, request: b.request }));
    }
    return Promise.resolve(res(404, { detail: 'not_found' }));
  };
  return b;
}

function controller(b, expertId = null, token = () => Promise.resolve('tok')) {
  return F.createController({ expertId, fetch: b.fetch, getIdToken: token });
}

const tests = [];
const it = (name, fn) => tests.push([name, fn]);

/* ── 1. Parity with the app ───────────────────────────────────────────── */

it('the same three programs, in the same order, with the same words as the app', () => {
  const web = plain(F.PROGRAMS).map(({ image, ...rest }) => rest);
  assert.deepEqual(web, dartPrograms());
  assert.deepEqual(web.map((p) => p.durationLabel), ['10 days', '30 days', '90 days']);
});

it('every status and result message is the app\'s own text', () => {
  for (const [key, dartName] of Object.entries(MESSAGE_TO_DART)) {
    assert.equal(F.MESSAGES[key], dartConst(DART_COPY, dartName), `${key} vs ${dartName}`);
  }
  assert.equal(F.MESSAGES.walletFrozen, dartConst(DART_WALLET, 'kWalletFrozenMessage'));
});

it('every refusal code means the same thing on both clients', () => {
  const dart = dartCodeMessages();
  assert.ok(Object.keys(dart).length >= 12, 'the app table was read');
  assert.deepEqual(plain(F.CODE_MESSAGES), dart);
  assert.equal(F.messageFor(401, { detail: 'invalid_token' }), 'Please sign in again to continue.');
  assert.equal(F.messageFor(403, { detail: 'forbidden' }), 'Please sign in again to continue.');
  assert.equal(F.messageFor(503, null), "Couldn't reach ZITLAS. Please try again in a moment.");
  assert.equal(F.messageFor(0, null), "Couldn't reach ZITLAS. Please try again in a moment.");
  assert.equal(F.messageFor(418, null), 'Could not send your request. Please try again.');
  for (const s of ['Please sign in again to continue.', "Couldn't reach ZITLAS. Please try again in a moment.",
    'Could not send your request. Please try again.']) {
    assert.ok(DART_REPO.includes(s.replace(/'/g, "'")) || DART_REPO.includes(s), s);
  }
});

it('prices are formatted exactly like the app (Indian grouping, paise only when there are any)', () => {
  assert.equal(F.formatPrice(100), '₹1');
  assert.equal(F.formatPrice(49950), '₹499.50');
  assert.equal(F.formatPrice(49905), '₹499.05');
  assert.equal(F.formatPrice(499900), '₹4,999');
  assert.equal(F.formatPrice(10000000), '₹1,00,000');
  assert.equal(F.formatPrice(12345678), '₹1,23,456.78');
});

it('only a positive whole number of paise is a price — never ₹0', () => {
  const offer = F.parseOffer({ programs: [
    { programId: '10_day', pricePaise: 0, available: true },
    { programId: '1_month', pricePaise: -100, available: true },
    { programId: '3_month', pricePaise: 499.5, available: true },
    { programId: 'x', pricePaise: '49900', available: true },
    { programId: 'y', pricePaise: 49900, available: false },
  ] });
  assert.deepEqual(plain(offer.prices), {});
});

it('statuses read like the app: completed is never "pending"; unknown is its own state', () => {
  const r = (status, extra = {}) => F.parseRequest({ requestId: 'r', expertId: 'e', programId: '10_day', status, ...extra });
  assert.equal(r('completed').status, 'completed');
  assert.equal(F.isOpen(r('completed')), false);
  assert.equal(F.isRunning(r('completed'), new Date()), false);
  assert.equal(r('something_new').status, 'unknown');
  assert.equal(F.isOpen(r('accepted')), true, 'accepted is waiting for payment');
  assert.equal(F.awaitingPayment(r('accepted', { paymentStatus: 'payment_required' })), true);
  assert.equal(F.isRunning(r('active', { endsAt: '2000-01-01T00:00:00Z' }), new Date()), false, 'ended');
  assert.equal(F.parseRequest({ status: 'accepted' }), null);
});

it('an expert\'s photo is used only when it is an http(s) URL', () => {
  const [a, v] = F.parseExperts({ experts: [
    { expertId: 'a', expertName: 'A', pricePaise: 100, photoUrl: 'javascript:alert(1)' },
    { expertId: 'v', expertName: 'V', pricePaise: 100, photoUrl: 'https://images.test/v.jpg', expertise: ['Fat loss', ' ', 7] },
  ] });
  assert.equal(a.photoUrl, null);
  assert.equal(v.photoUrl, 'https://images.test/v.jpg');
  assert.deepEqual(plain(v.expertise), ['Fat loss']);
});

/* ── 2. The same rules, the same backend ──────────────────────────────── */

it('opened without an expert: only the current program is asked for, and none means "choose"', async () => {
  const b = backend();
  const c = controller(b);
  await c.load();
  assert.deepEqual(b.calls, ['GET /requests/me']);
  assert.equal(c.state().state, 'ready');
  assert.equal(c.state().expertId, null);
  assert.equal(c.priceFor('10_day'), null);
  assert.equal(b.lastAuth, 'Bearer tok', "the signed-in user's own token");
});

it('a refresh restores the waiting request and its expert from the server', async () => {
  const b = backend();
  b.request = b.req('coach-1', '1_month', 'accepted', 'payment_required');
  const c = controller(b);
  await c.load();
  assert.deepEqual(b.calls, ['GET /requests/me', 'GET /experts/coach-1']);
  assert.equal(c.state().expertId, 'coach-1');
  assert.equal(F.awaitingPayment(c.requestFor('1_month')), true);
});

it('choose an expert: only experts who offer THAT program, at their own price', async () => {
  const b = backend();
  const c = controller(b);
  await c.load();
  const three = plain(await c.expertsFor('3_month'));
  assert.deepEqual(three.map((e) => e.expertId), ['coach-1']);
  assert.equal(three[0].pricePaise, 3499900);
  assert.equal(b.calls.at(-1), 'GET /programs/3_month/experts');
  await c.selectExpert('coach-1');
  assert.equal(c.priceFor('3_month'), 3499900);
  assert.equal(c.state().offer.expertName, 'Asha Rao');
});

it('the request sends ONLY the expert and the program — and two sends at once make one', async () => {
  const b = backend();
  const c = controller(b, 'coach-1');
  await c.load();
  const [a, second] = await Promise.all([c.requestProgram('10_day'), c.requestProgram('10_day')]);
  assert.deepEqual(b.posts, [{ expertId: 'coach-1', programId: '10_day' }]);
  assert.equal(a.ok, true);
  assert.equal(a.message, F.MESSAGES.requestSent);
  assert.equal(second.ok, false, 'the second is refused locally while the first is in flight');
  assert.equal(c.requestFor('10_day').status, 'pending_expert_acceptance');
  assert.ok(c.openRequest(), 'nothing else can start with this expert while it waits');
});

it('a repeat the server answers with the waiting request says so', async () => {
  const b = backend();
  b.postAnswer = [200, { success: true, alreadyRequested: true, request: b.req('coach-1', '10_day', 'pending_expert_acceptance') }];
  const c = controller(b, 'coach-1');
  await c.load();
  assert.equal((await c.requestProgram('10_day')).message, F.MESSAGES.alreadyRequested);
});

for (const [status, detail, says] of [
  [409, { error: 'program_request_exists', programId: '1_month' }, 'You already have a program request with this expert.'],
  [409, 'active_coaching_exists', 'You already have an active personal coach.'],
  [409, 'program_unavailable', "This program isn't available from this expert right now."],
  [401, 'invalid_token', 'Please sign in again to continue.'],
  [503, 'firestore_unavailable', "Couldn't reach ZITLAS. Please try again in a moment."],
]) {
  it(`a refused request (${status} ${JSON.stringify(detail)}) says why — never "Request sent"`, async () => {
    const b = backend();
    b.postAnswer = [status, { detail }];
    const c = controller(b, 'coach-1');
    await c.load();
    const out = await c.requestProgram('10_day');
    assert.equal(out.ok, false);
    assert.equal(out.message, says);
    assert.equal(c.requestFor('10_day'), null);
  });
}

it('a stale page reloads what the server knows after program_request_exists / program_unavailable', async () => {
  const b = backend();
  b.postAnswer = [409, { detail: 'program_unavailable' }];
  const c = controller(b, 'coach-1');
  await c.load();
  await c.requestProgram('10_day');
  assert.deepEqual(b.calls.filter((x) => x === 'GET /experts/coach-1').length, 2);
});

it('no connection, and no session, are told apart', async () => {
  const b = backend();
  const c = controller(b, 'coach-1');
  await c.load();
  b.offline = true;
  assert.equal((await c.requestProgram('10_day')).message, "Couldn't reach ZITLAS. Please try again in a moment.");
  const signedOut = controller(backend(), 'coach-1', () => Promise.reject(new Error('not_signed_in')));
  await signedOut.load();
  assert.equal(signedOut.state().state, 'failed');
  assert.equal(await signedOut.expertsFor('10_day').catch((e) => e.message), 'Please sign in again to continue.');
});

it('the expert list fails honestly, with the app\'s words', async () => {
  const b = backend();
  const c = controller(b);
  b.expertsStatus = 503;
  assert.equal(await c.expertsFor('10_day').catch((e) => e.message), "Couldn't reach ZITLAS. Please try again in a moment.");
  b.expertsStatus = 418;
  assert.equal(await c.expertsFor('10_day').catch((e) => e.message), F.MESSAGES.expertsLoadFailed);
});

it('Pay & Start sends nothing but the request, and the program starts from the server\'s answer', async () => {
  const b = backend();
  b.request = b.req('coach-1', '10_day', 'accepted', 'payment_required');
  const c = controller(b, 'coach-1');
  await c.load();
  const out = await c.payAndStart();
  assert.equal(out.message, F.MESSAGES.started);
  assert.equal(b.payBody, undefined, 'no amount, duration or expert ever leaves the page');
  const r = c.requestFor('10_day');
  assert.equal(r.status, 'active');
  assert.equal(r.amountPaidPaise, 499900);
  assert.equal(Math.round((r.endsAt - r.startedAt) / 86400000), 10, "the server's dates");
  assert.equal((await c.payAndStart()).message, '', 'nothing left to pay — no second call');
  assert.equal(b.pays, 1);
});

it('a repeat the server answers as already paid is not a second charge', async () => {
  const b = backend();
  b.request = b.req('coach-1', '10_day', 'accepted', 'payment_required');
  const paid = { ...b.request, status: 'active', paymentStatus: 'paid', startedAt: new Date().toISOString(),
    endsAt: new Date(Date.now() + 10 * 86400000).toISOString(), amountPaidPaise: 499900 };
  b.payAnswer = [200, { success: true, already: true, request: paid }];
  const c = controller(b, 'coach-1');
  await c.load();
  assert.equal((await c.payAndStart()).message, F.MESSAGES.alreadyPaid);
});

it('a short wallet: Required / Available — nothing charged, no checkout, still payable', async () => {
  const b = backend();
  b.request = b.req('coach-1', '10_day', 'accepted', 'payment_required');
  b.payAnswer = [402, { detail: { error: 'insufficient_wallet_balance', required: 499900, available: 100000 } }];
  const c = controller(b, 'coach-1');
  await c.load();
  const out = await c.payAndStart();
  assert.deepEqual(plain(out), { ok: false, message: '' });
  assert.deepEqual(plain(c.state().shortfall), { requiredPaise: 499900, availablePaise: 100000 });
  assert.equal(F.awaitingPayment(c.requestFor('10_day')), true, 'Pay & Start again after Add Funds');
});

it('a frozen wallet charges nothing and says so in the app\'s words', async () => {
  const b = backend();
  b.request = b.req('coach-1', '10_day', 'accepted', 'payment_required');
  b.payAnswer = [503, { detail: { error: 'wallet_frozen', message: 'frozen' } }];
  const c = controller(b, 'coach-1');
  await c.load();
  assert.equal((await c.payAndStart()).message, F.MESSAGES.walletFrozen);
});

it('a lost or unconfirmed payment answer is never reported as paid', async () => {
  for (const answer of [[500, {}], [200, { success: true, request: { requestId: 'CPR_1', expertId: 'coach-1', programId: '10_day', status: 'accepted', paymentStatus: 'unpaid' } }]]) {
    const b = backend();
    b.request = b.req('coach-1', '10_day', 'accepted', 'payment_required');
    b.payAnswer = answer;
    const c = controller(b, 'coach-1');
    await c.load();
    assert.equal((await c.payAndStart()).message, F.MESSAGES.paymentUnconfirmed);
    assert.ok(b.calls.filter((x) => x === 'GET /experts/coach-1').length >= 2, 'reloads what the server did');
  }
});

it('a refused payment says why (not accepted / no longer payable)', async () => {
  const b = backend();
  b.request = b.req('coach-1', '10_day', 'accepted', 'payment_required');
  b.payAnswer = [409, { detail: { error: 'not_payable', status: 'declined' } }];
  const c = controller(b, 'coach-1');
  await c.load();
  assert.equal((await c.payAndStart()).message, 'This program can no longer be paid for.');
});

/* ── 3. The page renders the flow — nothing more ─────────────────────── */

it('the page loads the shared flow before its own script', () => {
  const flow = PAGE_HTML.indexOf('coaching-programs-flow.js');
  const page = PAGE_HTML.indexOf('src="coaching-programs.js');
  assert.ok(flow !== -1 && page !== -1 && flow < page);
});

it('the page calls no API itself — every request goes through the flow', () => {
  assert.doesNotMatch(PAGE_JS, /\/api\//);
  assert.equal((PAGE_JS.match(/window\.fetch\(/g) || []).length, 1, 'only handed to the flow');
});

it('neither the page nor the flow computes a price or a date', () => {
  for (const src of [PAGE_JS, FLOW_SRC]) {
    assert.doesNotMatch(src, /setDate\(|durationDays\s*\*|86400000/);
  }
});

it('Add Funds is the existing wallet panel — never Razorpay from the page itself', () => {
  assert.match(PAGE_JS, /ZitlasWallet\.openAddFunds\(\)/);
  assert.doesNotMatch(PAGE_JS, /Razorpay|createOrder|\/api\/payment/);
});

it('the placeholder is not on the website either', () => {
  for (const src of [PAGE_JS, FLOW_SRC, PAGE_HTML]) assert.doesNotMatch(src, /coming next/i);
});

/* ── Runner ───────────────────────────────────────────────────────────── */

let failed = 0;
for (const [name, fn] of tests) {
  try {
    await fn();
    console.log('  ✓ ' + name);
  } catch (e) {
    failed++;
    console.log('  ✗ ' + name + '\n    ' + ((e && e.stack) || e));
  }
}
console.log(`\n${tests.length - failed}/${tests.length} passed`);
process.exit(failed ? 1 : 0);
