/**
 * ZITLAS — meal photos must never persist an ephemeral URL
 * (tests/js/meal-photo-durability.test.mjs)
 *
 * THE BUG THIS PINS
 * -----------------
 * `chat-attachments.js` uploaded to Firebase Storage and, on ANY failure,
 * silently fell back to `POST /api/chat/upload`, which writes to the
 * container's EPHEMERAL disk. The returned `/uploads/chat/…` URL was then
 * written into `meal_checkins.imageUrl` and kept forever.
 *
 * Firebase Storage was never provisioned on zitlas-b8677 (the CLI answers
 * "Firebase Storage has not been set up"; the API lists zero buckets), so the
 * fallback fired EVERY time. All ten production check-ins stored an
 * `/uploads/chat/…` URL and all ten now return 404 to the nutritionist —
 * while the athlete had been told "Sent to your coach for review."
 *
 * `opts.requireDurable` removes the fallback for persisted photos. These
 * tests prove it: with it, a Storage failure is a hard error and the backend
 * is NEVER contacted; without it, chat attachments keep falling back exactly
 * as before.
 *
 * Zero dependencies on purpose — the emulator harness in
 * tests/firestore-rules needs Java, which is not installed on every machine.
 *
 * Run:  node tests/js/meal-photo-durability.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = readFileSync(
  join(HERE, '..', '..', 'frontend', 'website', 'assets', 'js', 'chat-attachments.js'),
  'utf8'
);

/* ── A browser, in as few lines as the file actually needs ─────────────── */
function loadModule({ storage = 'ok' } = {}) {
  const calls = { backendUploads: 0, storagePaths: [] };

  const ctx = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout, clearTimeout, Promise, Math, Date, JSON, Error,
    encodeURIComponent,
    FormData: class { append() {} },
  };
  ctx.window = ctx;

  // FileReader / Image / canvas — just enough for compress() to resolve.
  ctx.FileReader = class {
    readAsDataURL() {
      queueMicrotask(() => this.onload({ target: { result: 'data:image/jpeg;base64,AAAA' } }));
    }
  };
  ctx.Image = class {
    constructor() { this.naturalWidth = 800; this.naturalHeight = 600; }
    set src(_v) { queueMicrotask(() => this.onload()); }
  };
  ctx.document = {
    createElement: () => ({
      getContext: () => ({ drawImage() {} }),
      toBlob: (cb) => queueMicrotask(() => cb({ size: 4096, type: 'image/jpeg' })),
    }),
    body: { appendChild() {} },
    addEventListener() {},
  };

  // Firebase Storage — present-and-working, present-and-failing, or absent.
  if (storage !== 'absent') {
    ctx.ZitlasStorage = {
      ref: () => ({
        child: (path) => {
          calls.storagePaths.push(path);
          return {
            put: () => storage === 'ok'
              ? Promise.resolve()
              : Promise.reject(Object.assign(new Error('denied'), { code: 'storage/unauthorized' })),
            getDownloadURL: () => Promise.resolve(
              'https://firebasestorage.googleapis.com/v0/b/zitlas-b8677.firebasestorage.app/o/' +
              encodeURIComponent(path) + '?alt=media&token=deadbeef'
            ),
          };
        },
      }),
    };
  }
  ctx.ZitlasAuth = { currentUser: { uid: 'athlete1' } };

  // The ephemeral backend. Every call here is a potential data-loss event.
  ctx.fetch = () => {
    calls.backendUploads += 1;
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve({ success: true, url: '/uploads/chat/ephemeral.jpg' }),
    });
  };

  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);
  return { attach: ctx.window.ZitlasChatAttach, calls };
}

const photo = { type: 'image/jpeg', size: 2048, name: 'lunch.jpg' };

/* ── Tiny runner ───────────────────────────────────────────────────────── */
const results = [];
async function it(name, fn) {
  try { await fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}
async function rejects(p) {
  try { await p; return null; } catch (e) { return e; }
}

/* ── A meal photo: durable or nothing ──────────────────────────────────── */

await it('a meal photo that reaches Storage returns the durable URL', async () => {
  const { attach, calls } = loadModule({ storage: 'ok' });
  const url = await attach.upload(photo, { pathPrefix: 'meal_checkins', requireDurable: true });
  assert.match(url, /^https:\/\/firebasestorage\.googleapis\.com\//,
    'the persisted URL must point at Firebase Storage');
  assert.doesNotMatch(url, /\/uploads\//, 'must never be an ephemeral backend path');
  assert.equal(calls.backendUploads, 0, 'the backend must not be touched at all');
});

await it('it is stored under meal_checkins/{uid}/ so the rules apply', async () => {
  const { attach, calls } = loadModule({ storage: 'ok' });
  await attach.upload(photo, { pathPrefix: 'meal_checkins', requireDurable: true });
  assert.equal(calls.storagePaths.length, 1);
  assert.match(calls.storagePaths[0], /^meal_checkins\/athlete1\//,
    'storage.rules key off this path — a different shape silently bypasses them');
});

await it('THE REGRESSION: a Storage failure must NOT fall back to ephemeral disk', async () => {
  const { attach, calls } = loadModule({ storage: 'fails' });
  const err = await rejects(attach.upload(photo, { pathPrefix: 'meal_checkins', requireDurable: true }));
  assert.ok(err, 'the upload must reject, not resolve with an ephemeral URL');
  assert.equal(calls.backendUploads, 0,
    'this is the whole bug: falling back here is what wrote 10 dead URLs to Firestore');
});

await it('...and the athlete is told the photo was NOT saved', async () => {
  const { attach } = loadModule({ storage: 'fails' });
  const err = await rejects(attach.upload(photo, { pathPrefix: 'meal_checkins', requireDurable: true }));
  assert.equal(err.message, attach.DURABLE_UPLOAD_FAILED);
  assert.match(err.message, /NOT saved/,
    'silence or a vague "try again" is what let the athlete believe it worked');
});

await it('Storage missing from the page is also a hard failure', async () => {
  const { attach, calls } = loadModule({ storage: 'absent' });
  const err = await rejects(attach.upload(photo, { pathPrefix: 'meal_checkins', requireDurable: true }));
  assert.equal(err.message, attach.DURABLE_UPLOAD_FAILED);
  assert.equal(calls.backendUploads, 0);
});

await it('the AI-only snap log is held to the same standard', async () => {
  const { attach, calls } = loadModule({ storage: 'fails' });
  const err = await rejects(attach.upload(photo, { pathPrefix: 'meal_snaps', requireDurable: true }));
  assert.ok(err);
  assert.equal(calls.backendUploads, 0, 'meal_snap_logs.imageUrl is persisted too');
});

/* ── Chat attachments are deliberately untouched ───────────────────────── */

await it('chat still falls back when Storage fails', async () => {
  const { attach, calls } = loadModule({ storage: 'fails' });
  const url = await attach.upload(photo);
  assert.equal(url, '/uploads/chat/ephemeral.jpg');
  assert.equal(calls.backendUploads, 1,
    'chat images are read immediately, not persisted as long-lived references — '
    + 'breaking that fallback was explicitly out of scope');
});

await it('chat prefers Storage when it is available', async () => {
  const { attach, calls } = loadModule({ storage: 'ok' });
  const url = await attach.upload(photo);
  assert.match(url, /firebasestorage\.googleapis\.com/);
  assert.equal(calls.backendUploads, 0);
});

/* ── Report ────────────────────────────────────────────────────────────── */
let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) { console.log(`  PASS  ${name}`); }
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
