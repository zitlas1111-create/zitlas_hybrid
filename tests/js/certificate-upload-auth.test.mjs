/**
 * ZITLAS — Certificate upload authentication
 * (tests/js/certificate-upload-auth.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * `POST /api/certificates/verify` became expert-only (routes/certificates.py,
 * `Depends(require_expert)`), but uploadAndVerify() kept calling it as:
 *
 *     fetch('/api/certificates/verify', { method: 'POST', body: fd })
 *
 * with no Authorization header. Every upload died on
 * `401 {"detail":"missing_token"}` at STEP 1 — before _uploadToStorage() and
 * before saveCertificate(). Verified against production: the Storage bucket
 * held ZERO objects under certificates/, and no expert_certificates document
 * had been written since the route was protected. The expert saw a toast
 * reading "missing_token" and reasonably assumed the upload had worked.
 *
 * THE TWO PROPERTIES THAT MUST BOTH HOLD
 * --------------------------------------
 *   1. Authorization: Bearer <Firebase ID token> IS sent.
 *   2. Content-Type is NOT set by hand. The body is FormData, and only the
 *      browser can append the multipart boundary to the header. Setting it
 *      manually — as _adminFetch() does for its JSON payloads — silently
 *      corrupts the upload. That is exactly why this path must NOT reuse
 *      _adminFetch, and #2 is a real regression risk while fixing #1.
 *
 * This test EXECUTES the shipping function against fakes rather than
 * grepping the source, so it fails if the behaviour breaks even when the
 * code still looks right.
 *
 * Run:  node tests/js/certificate-upload-auth.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const SRC = readFileSync(join(WEB, 'assets', 'js', 'certificate-manager.js'), 'utf8');

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

/** Records everything the FormData body was given, so a test can prove the
 *  payload survived the change. */
class FakeFormData {
  constructor() { this.entries = []; }
  append(k, v) { this.entries.push([k, v]); }
}

/**
 * Builds a sandbox holding the REAL uploadAndVerify(), with every collaborator
 * faked. Returns the context plus the captured fetch call.
 *
 * @param {object} opts
 *   user      — the fake ZitlasAuth.currentUser (null to simulate signed-out)
 *   response  — what the faked fetch resolves to
 *   storage   — what the faked _uploadToStorage resolves to
 */
function sandbox(opts = {}) {
  const calls = { fetch: [], storage: [], phases: [] };
  const user = 'user' in opts ? opts.user : {
    getIdToken: () => Promise.resolve('FAKE_FIREBASE_ID_TOKEN'),
  };
  const response = opts.response || {
    ok: true,
    status: 200,
    json: () => Promise.resolve({ accepted: true, verificationScore: 91, verificationStatus: 'verified' }),
  };

  const ctx = {
    Promise, JSON, Error, Object, Array, String, Number,
    console: { log() {}, warn() {}, error() {} },
    FormData: FakeFormData,
    ZitlasAuth: opts.noAuthGlobal ? undefined : { currentUser: user },
    fetch(url, init) { calls.fetch.push({ url, init }); return Promise.resolve(response); },
    _uploadToStorage(expertId, file) {
      calls.storage.push({ expertId, file });
      return Promise.resolve(opts.storage || { url: 'https://firebasestorage.googleapis.com/v0/b/b/o/c?alt=media&token=T', path: 'certificates/e1/x.jpg' });
    },
  };
  if (opts.noAuthGlobal) delete ctx.ZitlasAuth;
  vm.createContext(ctx);
  vm.runInContext(extractFn(SRC, 'uploadAndVerify'), ctx);
  return { ctx, calls };
}

const FILE = { name: 'cert.jpg', type: 'image/jpeg', size: 51234 };

const results = [];
async function it(name, fn) {
  try { await fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── 1. The fix itself ──────────────────────────────────────────────────── */

await it('the upload sends Authorization: Bearer <Firebase ID token>', async () => {
  const { ctx, calls } = sandbox();
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.equal(calls.fetch.length, 1, 'expected exactly one verify request');
  const { init } = calls.fetch[0];
  assert.ok(init.headers, 'no headers sent at all — this is the original bug');
  assert.equal(init.headers.Authorization, 'Bearer FAKE_FIREBASE_ID_TOKEN');
});

await it('the token comes from the signed-in user, not a literal', async () => {
  const { ctx, calls } = sandbox({
    user: { getIdToken: () => Promise.resolve('TOKEN_FROM_ZITLASAUTH') },
  });
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.equal(calls.fetch[0].init.headers.Authorization, 'Bearer TOKEN_FROM_ZITLASAUTH');
});

await it('a token resolved asynchronously is still awaited', async () => {
  const { ctx, calls } = sandbox({
    user: { getIdToken: () => new Promise((r) => setTimeout(() => r('LATE'), 5)) },
  });
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.equal(calls.fetch[0].init.headers.Authorization, 'Bearer LATE');
});

/* ── 2. Content-Type must NOT be set by hand ────────────────────────────── */

await it('Content-Type is never set manually', async () => {
  const { ctx, calls } = sandbox();
  await ctx.uploadAndVerify('expert-1', FILE);
  const keys = Object.keys(calls.fetch[0].init.headers).map((k) => k.toLowerCase());
  assert.ok(!keys.includes('content-type'),
    'a manual Content-Type strips the multipart boundary and breaks the upload');
});

await it('Authorization is the ONLY header sent', async () => {
  const { ctx, calls } = sandbox();
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.deepEqual(Object.keys(calls.fetch[0].init.headers), ['Authorization']);
});

await it('this path does not reuse the JSON helper _adminFetch', () => {
  // Comments stripped first — the function's own comment explains why it
  // does NOT use _adminFetch, and that mention is not a call.
  const code = extractFn(SRC, 'uploadAndVerify')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/gm, '');
  assert.ok(!/_adminFetch\s*\(/.test(code),
    '_adminFetch sets Content-Type: application/json — fatal for a FormData body');
});

/* ── 3. The payload is unchanged ────────────────────────────────────────── */

await it('the body is still the FormData instance', async () => {
  const { ctx, calls } = sandbox();
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.ok(calls.fetch[0].init.body instanceof FakeFormData);
});

await it('expertId and file are still appended, unchanged', async () => {
  const { ctx, calls } = sandbox();
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.deepEqual(calls.fetch[0].init.body.entries, [['expertId', 'expert-1'], ['file', FILE]]);
});

await it('the method and URL are unchanged', async () => {
  const { ctx, calls } = sandbox();
  await ctx.uploadAndVerify('expert-1', FILE);
  assert.equal(calls.fetch[0].url, '/api/certificates/verify');
  assert.equal(calls.fetch[0].init.method, 'POST');
});

/* ── 4. Signed-out is refused before any request ────────────────────────── */

await it('a signed-out expert gets a readable error, not a 401', async () => {
  const { ctx, calls } = sandbox({ user: null });
  await assert.rejects(ctx.uploadAndVerify('expert-1', FILE),
    /Please sign in again to upload a certificate\./);
  assert.equal(calls.fetch.length, 0, 'no pointless unauthenticated request');
});

await it('a user object without getIdToken is refused too', async () => {
  const { ctx, calls } = sandbox({ user: { uid: 'x' } });
  await assert.rejects(ctx.uploadAndVerify('expert-1', FILE), /Please sign in again/);
  assert.equal(calls.fetch.length, 0);
});

await it('a missing ZitlasAuth global does not throw a ReferenceError', async () => {
  const { ctx } = sandbox({ noAuthGlobal: true });
  await assert.rejects(ctx.uploadAndVerify('expert-1', FILE), /Please sign in again/);
});

/* ── 5. Everything downstream is preserved ──────────────────────────────── */

await it('a 401 still surfaces the backend detail verbatim', async () => {
  const { ctx } = sandbox({
    response: { ok: false, status: 401, json: () => Promise.resolve({ detail: 'missing_token' }) },
  });
  await assert.rejects(ctx.uploadAndVerify('expert-1', FILE), /missing_token/);
});

await it('a non-JSON error body still falls back to the status line', async () => {
  const { ctx } = sandbox({
    response: { ok: false, status: 502, json: () => Promise.reject(new Error('not json')) },
  });
  await assert.rejects(ctx.uploadAndVerify('expert-1', FILE), /Verification failed \(502\)/);
});

await it('an AI rejection still short-circuits before Storage', async () => {
  const { ctx, calls } = sandbox({
    response: { ok: true, status: 200, json: () => Promise.resolve({ accepted: false, reason: 'Not a certificate.' }) },
  });
  const result = await ctx.uploadAndVerify('expert-1', FILE);
  assert.equal(result.accepted, false);
  assert.equal(calls.storage.length, 0, 'a rejected file must never reach Storage');
});

await it('an accepted file is uploaded and stamped with the Storage result', async () => {
  const { ctx, calls } = sandbox();
  const result = await ctx.uploadAndVerify('expert-1', FILE);
  assert.equal(calls.storage.length, 1);
  assert.deepEqual(calls.storage[0], { expertId: 'expert-1', file: FILE });
  assert.match(result.certificateUrl, /^https:\/\/firebasestorage\.googleapis\.com\//);
  assert.equal(result.storagePath, 'certificates/e1/x.jpg');
  assert.equal(result.storageProvider, 'firebase-storage');
});

await it('the phase callback still advances verifying -> uploading', async () => {
  const { ctx } = sandbox();
  const phases = [];
  await ctx.uploadAndVerify('expert-1', FILE, (p) => phases.push(p));
  assert.deepEqual(phases, ['verifying', 'uploading']);
});

await it('a throwing phase callback still cannot break the upload', async () => {
  const { ctx } = sandbox();
  const result = await ctx.uploadAndVerify('expert-1', FILE, () => { throw new Error('UI blew up'); });
  assert.equal(result.storageProvider, 'firebase-storage');
});

/* ── report ─────────────────────────────────────────────────────────────── */

let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) { console.log(`  ok  ${name}`); }
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
