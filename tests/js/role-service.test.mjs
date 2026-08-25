/**
 * ZITLAS — an approved expert must never be bounced to the athlete app
 * (tests/js/role-service.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * Two pages guarded each other and disagreed about what "expert" means:
 *
 *   dashboard.js        read users/{uid}.roles / expert_status / role —
 *                       CLIENT-WRITABLE fields — and counted 'expert_pending'
 *                       and 'pending' as EXPERT, bouncing those accounts to
 *                       the expert dashboard.
 *   expert-dashboard.js asked GET /api/auth/role but started `isExpert=false`
 *                       and treated a FAILED request identically to a server
 *                       verdict of "not an expert", bouncing to the athlete
 *                       dashboard.
 *
 * So a single flaky /api/auth/role call inside the expert dashboard sent an
 * approved expert to the athlete dashboard, which read their legacy markers
 * and sent them straight back — a redirect ping-pong with the athlete app
 * visible in between. All three approved experts carry those markers in
 * users/{uid} (verified in Firestore: two hold roles:['athlete',
 * 'expert_pending'] + expert_status:'pending', one holds role:'expert'), so
 * every one of them could hit it.
 *
 * assets/js/role-service.js is now the single resolver for both pages and has
 * THREE outcomes. `null` means "could not ask" and is never a redirect.
 *
 * Run:  node tests/js/role-service.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const SRC = readFileSync(join(WEB, 'assets', 'js', 'role-service.js'), 'utf8');

/* ── Load the REAL resolver against a stub browser ─────────────────────── */
function load({ responses, tokenThrows = false }) {
  const calls = { fetches: 0, tokenRefreshForced: null };
  const queue = [...responses];

  const ctx = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: (fn) => fn(),          // collapse the backoff
    Promise, JSON, Error, document: null,
  };
  ctx.window = ctx;
  ctx.fetch = () => {
    calls.fetches += 1;
    const next = queue.length > 1 ? queue.shift() : queue[0];
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
  };
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);

  const user = {
    uid: 'qEX2DhZVWXd2LcBb9rwnSXGVQkx1',
    getIdToken: (force) => {
      calls.tokenRefreshForced = force;
      return tokenThrows
        ? Promise.reject(new Error('token unavailable'))
        : Promise.resolve('id-token');
    },
  };
  return { role: ctx.window.ZitlasRole, user, calls };
}

const jsonOk = (body) => ({
  ok: true, status: 200, json: () => Promise.resolve(body),
});
const status = (code) => ({
  ok: false, status: code, json: () => Promise.resolve({}),
});

const results = [];
async function it(name, fn) {
  try { await fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── The server answered ───────────────────────────────────────────────── */

await it('an approved expert resolves to expert', async () => {
  const { role, user } = load({
    responses: [jsonOk({ role: 'expert', isExpert: true })],
  });
  assert.equal(await role.resolve(user), 'expert');
});

await it('a normal user resolves to user', async () => {
  const { role, user } = load({
    responses: [jsonOk({ role: 'user', isExpert: false })],
  });
  assert.equal(await role.resolve(user), 'user');
});

await it('both halves are required — isExpert alone is not enough', async () => {
  const { role, user } = load({
    responses: [jsonOk({ role: 'user', isExpert: true })],
  });
  assert.equal(await role.resolve(user), 'user');
});

await it('the ID token is force-refreshed', async () => {
  const { role, user, calls } = load({
    responses: [jsonOk({ role: 'expert', isExpert: true })],
  });
  await role.resolve(user);
  assert.equal(calls.tokenRefreshForced, true,
    'a cached token can predate the custom claim being granted');
});

await it('401/403 is a verdict and is not retried', async () => {
  const { role, user, calls } = load({ responses: [status(403)] });
  assert.equal(await role.resolve(user), 'user');
  assert.equal(calls.fetches, 1);
});

/* ── The server did NOT answer — THE REGRESSION ────────────────────────── */

await it('THE BUG: a 502 does not become "user"', async () => {
  const { role, user } = load({ responses: [status(502)] });
  assert.equal(await role.resolve(user), null,
    'null means unresolved; the caller must hold, never redirect');
});

await it('a network error does not become "user"', async () => {
  const { role, user } = load({ responses: [new Error('Failed to fetch')] });
  assert.equal(await role.resolve(user), null);
});

await it('a 200 with an unparseable body (captive portal) is unresolved', async () => {
  const { role, user } = load({
    responses: [{ ok: true, status: 200, json: () => Promise.reject(new Error('bad json')) }],
  });
  assert.equal(await role.resolve(user), null);
});

await it('it retries, and a later success still wins', async () => {
  const { role, user, calls } = load({
    responses: [status(502), status(502), jsonOk({ role: 'expert', isExpert: true })],
  });
  assert.equal(await role.resolve(user), 'expert',
    'a transient blip must not cost an expert their dashboard');
  assert.ok(calls.fetches >= 3);
});

await it('it gives up rather than guessing', async () => {
  const { role, user, calls } = load({ responses: [status(502)] });
  assert.equal(await role.resolve(user), null);
  assert.equal(calls.fetches, role.RETRY_MS.length + 1);
});

await it('a failed token mint is unresolved, not "user"', async () => {
  const { role, user } = load({ responses: [jsonOk({})], tokenThrows: true });
  assert.equal(await role.resolve(user), null);
});

await it('a signed-out caller is unresolved', async () => {
  const { role } = load({ responses: [jsonOk({})] });
  assert.equal(await role.resolve(null), null);
});

/* ── The two guards must agree, and must not read forgeable fields ─────── */

const EXPERT_JS = readFileSync(join(WEB, 'pages', 'experts', 'expert-dashboard.js'), 'utf8');
const DASH_JS = readFileSync(join(WEB, 'pages', 'dashboard', 'dashboard.js'), 'utf8');

await it('the expert dashboard HOLDS instead of bouncing when unresolved', () => {
  assert.ok(/_role === null/.test(EXPERT_JS), 'the unresolved branch is gone');
  const hold = EXPERT_JS.slice(EXPERT_JS.indexOf('_role === null'));
  const untilNextRedirect = hold.slice(0, hold.indexOf('window.location.href'));
  assert.ok(/showUnresolvedNotice/.test(untilNextRedirect),
    'an unresolved role must offer a retry, not a redirect');
});

await it('the athlete dashboard no longer trusts users/{uid} for role', () => {
  assert.ok(!/roles\.includes\('expert_pending'\)/.test(DASH_JS),
    'expert_pending is client-writable and must never authorise');
  assert.ok(!/data\.expert_status === 'pending'/.test(DASH_JS),
    'merely applying must not route anyone to the expert dashboard');
  assert.ok(/ZitlasRole\.resolve\(user\)/.test(DASH_JS));
});

await it('both guards use the SAME resolver', () => {
  assert.ok(/ZitlasRole\.resolve\(/.test(EXPERT_JS));
  assert.ok(/ZitlasRole\.resolve\(/.test(DASH_JS));
});

await it('neither guard reads a role from localStorage or the URL', () => {
  for (const [name, src] of [['expert-dashboard', EXPERT_JS], ['dashboard', DASH_JS]]) {
    const guard = src.slice(Math.max(0, src.indexOf('ZitlasRole.resolve(') - 1500),
                            src.indexOf('ZitlasRole.resolve(') + 1500);
    assert.ok(!/localStorage\.getItem\(['"]zitlas_user_role/.test(guard),
      `${name} reintroduced a cached role`);
    assert.ok(!/[?&]role=/.test(guard), `${name} reads a role from the URL`);
  }
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  PASS  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
