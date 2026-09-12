/**
 * ZITLAS — web push for experts, and a clean logout
 * (tests/js/web-push-expert.test.mjs)
 *
 * WHAT WAS WRONG
 * --------------
 *   1. push-notifications.js was loaded ONLY on the athlete dashboard. An
 *      expert on expert-dashboard.html was never offered push, so no expert
 *      browser was ever registered — production held zero expert devices.
 *   2. It fell back to a uid cached in localStorage before Firebase Auth had
 *      restored the session; that cache can name a PREVIOUS account.
 *   3. Logout: profile.js and expert-dashboard.js terminate Firestore BEFORE
 *      signing out, and the sign-out wrapper's "mark this device signed out"
 *      write then ran against a terminated client and failed silently — the
 *      logged-out account kept receiving notifications in that browser.
 *   4. Every foreground notification used one fixed tag, so each replaced the
 *      last; the service worker's tag did not match the one the FCM SDK used,
 *      so a background notification could appear twice.
 *
 * Run:  node tests/js/web-push-expert.test.mjs
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = join(HERE, '..', '..', 'frontend', 'website');
const read = (...p) => readFileSync(join(WEB, ...p), 'utf8');

const PUSH = read('assets', 'js', 'push-notifications.js');
const CONFIG = read('assets', 'js', 'firebase-config.js');
const SW = read('firebase-messaging-sw.js');
const EXPERT_HTML = read('pages', 'experts', 'expert-dashboard.html');
const ATHLETE_HTML = read('pages', 'dashboard', 'dashboard.html');
const EXPERT_JS = read('pages', 'experts', 'expert-dashboard.js');
const PROFILE_JS = read('pages', 'profile', 'profile.js');

const flush = async (n = 25) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r));
};

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

/* ── A page running the REAL push-notifications.js against fakes ───────── */
function pushEnv({
  path = '/pages/experts/expert-dashboard.html',
  search = '',
  permission = 'granted',
  savedToken = null,
  fcmToken = 'tok_web_new',
  channel = false,
} = {}) {
  const writes = [];
  const store = {
    // A PREVIOUS account's cached identity — must never be used.
    zitlas_firebase_user: JSON.stringify({ uid: 'STALE_PREVIOUS_ACCOUNT' }),
  };
  if (savedToken) store.zitlas_push_token = savedToken;
  const localStorage = {
    getItem: (k) => (Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); },
    removeItem: (k) => { delete store[k]; },
  };

  let authCallback = null;
  const ZitlasAuth = {
    currentUser: null,
    onAuthStateChanged(cb) { authCallback = cb; return () => {}; },
  };
  const ZitlasDB = {
    collection: (c) => ({
      doc: (id) => ({
        set: (data, opts) => { writes.push({ path: `${c}/${id}`, data, opts }); return Promise.resolve(); },
      }),
    }),
  };

  const shown = [];
  let onMessage = null;
  const reg = {
    active: {},
    scope: '/',
    showNotification: (title, opts) => { shown.push({ title, opts }); return Promise.resolve(); },
  };
  const messagingInstance = {
    getToken: () => Promise.resolve(fcmToken),
    onMessage: (cb) => { onMessage = cb; },
  };
  const messaging = () => messagingInstance;
  messaging.isSupported = () => true;

  const overlays = [];
  const document = {
    readyState: 'complete',
    getElementById: (id) =>
      (id === 'pushEnableBtn' || id === 'pushLaterBtn') ? { addEventListener() {} } : null,
    addEventListener() {},
    createElement: () => {
      const el = { addEventListener() {} };
      Object.defineProperty(el, 'innerHTML', { set(v) { overlays.push(v); }, get() { return ''; } });
      return el;
    },
    body: { appendChild() {} },
  };
  const window = { location: { pathname: path, search }, PushManager: function PushManager() {} };
  if (channel) window.ZitlasWebview = {};

  const timers = [];
  const ctx = {
    window, document, localStorage, ZitlasAuth, ZitlasDB,
    navigator: {
      serviceWorker: {
        register: () => Promise.resolve(reg),
        getRegistration: () => Promise.resolve(reg),
      },
    },
    Notification: { permission, requestPermission: () => Promise.resolve(permission) },
    firebase: {
      messaging,
      firestore: {
        FieldValue: {
          arrayUnion: (v) => ({ op: 'arrayUnion', v }),
          arrayRemove: (v) => ({ op: 'arrayRemove', v }),
        },
      },
    },
    console: { log() {}, warn() {} },
    setTimeout: (fn) => { timers.push(fn); return timers.length; },
    setInterval: (fn) => { timers.push(fn); return timers.length; },
    clearInterval() {}, clearTimeout() {},
    Promise, JSON, Date, Math, String, Object, Array, Error,
  };
  vm.createContext(ctx);
  vm.runInContext(PUSH, ctx);

  return {
    writes, store, shown, overlays,
    listensForAuth: () => authCallback !== null,
    signIn(uid) {
      ZitlasAuth.currentUser = { uid };
      if (authCallback) authCallback({ uid });
    },
    runTimers() { while (timers.length) timers.shift()(); },
    foreground: (payload) => onMessage && onMessage(payload),
  };
}

async function registeredAs(uid, opts) {
  const env = pushEnv(opts);
  env.signIn(uid);
  env.runTimers();
  await flush();
  return env;
}

/* ── firebase-config.js's sign-out wrapper, extracted and run on fakes ─── */
function configEnv({ token = 'tok_web', uid = 'expert_1', failWrites = false, terminated = false } = {}) {
  const start = CONFIG.indexOf('(function wrapSignOutForPush(auth) {');
  const endMarker = '})(ZitlasAuth);';
  const end = CONFIG.indexOf(endMarker, start) + endMarker.length;
  assert.ok(start > -1 && end > start, 'wrapSignOutForPush not found');

  const order = [];
  const payloads = {};
  const store = token ? { zitlas_push_token: token } : {};
  const ZitlasAuth = {
    currentUser: uid ? { uid } : null,
    signOut() { order.push('signOut'); return Promise.resolve(); },
  };
  const ZitlasDB = {
    collection(c) {
      // What firestore().terminate() leaves behind: every call throws.
      if (terminated) throw new Error('The client has already been terminated.');
      return {
        doc: (id) => ({
          set: (data) => {
            order.push(`write:${c}/${id}`);
            payloads[`${c}/${id}`] = data;
            return failWrites ? Promise.reject(new Error('offline')) : Promise.resolve();
          },
        }),
      };
    },
  };
  const ctx = {
    ZitlasAuth, ZitlasDB,
    localStorage: { getItem: (k) => (k in store ? store[k] : null) },
    firebase: { firestore: { FieldValue: { arrayRemove: (v) => ({ op: 'arrayRemove', v }) } } },
    console: { log() {}, warn() {} },
    setTimeout, Promise, Date,
  };
  vm.createContext(ctx);
  vm.runInContext(CONFIG.slice(start, end), ctx);
  return { auth: ZitlasAuth, order, payloads };
}

/* ── The service worker, run on fakes ───────────────────────────────────── */
function swEnv() {
  let handler = null;
  const shown = [];
  const ctx = {
    importScripts() {},
    firebase: {
      initializeApp() {},
      messaging: () => ({ onBackgroundMessage: (cb) => { handler = cb; } }),
    },
    self: {
      registration: { showNotification: (t, o) => { shown.push({ t, o }); return Promise.resolve(); } },
      addEventListener() {},
    },
    clients: {},
    console: { log() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(SW, ctx);
  return { deliver: (p) => handler(p), shown };
}

const results = [];
async function it(name, fn) {
  try { await fn(); results.push([true, name]); }
  catch (e) { results.push([false, name, e]); }
}

/* ── 1. Experts get web push ────────────────────────────────────────────── */

await it('the expert dashboard loads the push module, its SDK and its styles', () => {
  assert.match(EXPERT_HTML, /firebase-messaging-compat\.js/);
  assert.match(EXPERT_HTML, /assets\/js\/push-notifications\.js/);
  assert.match(EXPERT_HTML, /assets\/css\/push-notifications\.css/);
  // The SCRIPT TAGS, not the first mention — a comment in <head> names the
  // file too.
  assert.ok(EXPERT_HTML.indexOf('src="../../assets/js/push-notifications.js')
      > EXPERT_HTML.indexOf('src="../../assets/js/firebase-config.js'),
    'push-notifications.js needs ZitlasAuth, which firebase-config.js defines');
});

await it('an expert page registers the device for the SIGNED-IN expert', async () => {
  const env = await registeredAs('expert_1');
  const row = env.writes.find((w) => w.path === 'device_tokens/tok_web_new');
  assert.ok(row, 'no device_tokens row was written for the expert');
  assert.equal(row.data.uid, 'expert_1');
  assert.equal(row.data.enabled, true);
  assert.equal(row.data.loggedIn, true);
  assert.equal(row.data.platform, 'web');
  const arr = env.writes.find((w) => w.path === 'users/expert_1');
  assert.equal(arr.data.pushTokens.op, 'arrayUnion');
  assert.equal(arr.data.pushTokens.v, 'tok_web_new');
});

await it('nothing is registered before Firebase Auth restores the session', async () => {
  const env = pushEnv();
  env.runTimers();
  await flush();
  assert.equal(env.writes.length, 0);
  assert.ok(env.listensForAuth(), 'it must wait on onAuthStateChanged');
});

await it("a previous account's cached uid is never used", async () => {
  const env = await registeredAs('expert_1');
  assert.ok(!env.writes.some((w) => JSON.stringify(w).includes('STALE_PREVIOUS_ACCOUNT')));
});

await it('it stays out of the ZITLAS app WebView (?webview=1)', async () => {
  const env = await registeredAs('expert_1', { search: '?webview=1' });
  assert.equal(env.writes.length, 0);
  assert.equal(env.listensForAuth(), false);
});

await it('it stays out of the WebView when only the app channel is present', async () => {
  const env = await registeredAs('expert_1', { channel: true });
  assert.equal(env.writes.length, 0);
});

await it('experts are asked in expert terms', async () => {
  const env = await registeredAs('expert_1', { permission: 'default' });
  const html = env.overlays.join('');
  assert.match(html, /Never miss a client/);
  assert.doesNotMatch(html, /your expert reviews your plan/);
});

/* ── 2. Athletes are unchanged ──────────────────────────────────────────── */

await it('the athlete dashboard still loads the push module', () => {
  assert.match(ATHLETE_HTML, /assets\/js\/push-notifications\.js/);
});

await it('athletes are still registered on the athlete dashboard', async () => {
  const env = await registeredAs('athlete_1', { path: '/pages/dashboard/dashboard.html' });
  assert.equal(env.writes.find((w) => w.path === 'device_tokens/tok_web_new').data.uid, 'athlete_1');
});

await it('athletes keep their own wording', async () => {
  const env = await registeredAs('athlete_1', { permission: 'default', path: '/pages/dashboard/dashboard.html' });
  assert.match(env.overlays.join(''), /Stay in the loop/);
});

/* ── 3. Token rotation ──────────────────────────────────────────────────── */

await it('a rotated token retires the previous one', async () => {
  const env = await registeredAs('expert_1', { savedToken: 'tok_web_old', fcmToken: 'tok_web_new' });
  const old = env.writes.find((w) => w.path === 'device_tokens/tok_web_old');
  assert.ok(old, 'the previous token was left enabled');
  assert.equal(old.data.enabled, false);
  assert.ok(old.data.retiredAt);
  const removed = env.writes.find((w) => w.path === 'users/expert_1'
    && w.data.pushTokens && w.data.pushTokens.op === 'arrayRemove');
  assert.equal(removed.data.pushTokens.v, 'tok_web_old');
  assert.equal(env.store.zitlas_push_token, 'tok_web_new');
});

await it('an unchanged token retires nothing', async () => {
  const env = await registeredAs('expert_1', { savedToken: 'tok_same', fcmToken: 'tok_same' });
  assert.ok(!env.writes.some((w) => w.data.enabled === false));
});

/* ── 4. Logout ──────────────────────────────────────────────────────────── */

await it('signing out marks this browser signed out BEFORE the session ends', async () => {
  const { auth, order, payloads } = configEnv();
  await auth.signOut();
  assert.deepEqual([...order], ['write:device_tokens/tok_web', 'write:users/expert_1', 'signOut']);
  assert.equal(payloads['device_tokens/tok_web'].enabled, false);
  assert.equal(payloads['device_tokens/tok_web'].loggedIn, false);
  assert.equal(payloads['users/expert_1'].pushTokens.op, 'arrayRemove');
});

await it('an early release is not repeated by signOut()', async () => {
  const { auth, order } = configEnv();
  assert.equal(await auth.releasePushSession(), true);
  await auth.signOut();
  assert.deepEqual([...order], ['write:device_tokens/tok_web', 'write:users/expert_1', 'signOut']);
});

await it('a failed release still signs out', async () => {
  const { auth, order } = configEnv({ failWrites: true });
  await auth.signOut();
  assert.ok(order.includes('signOut'));
});

await it('a TERMINATED Firestore client still signs out (it used to throw first)', async () => {
  const { auth, order } = configEnv({ terminated: true });
  await auth.signOut();
  assert.deepEqual([...order], ['signOut']);
});

await it('with nothing registered it just signs out', async () => {
  const { auth, order } = configEnv({ token: null });
  await auth.signOut();
  assert.deepEqual([...order], ['signOut']);
});

await it('the expert logout releases the push session BEFORE terminating Firestore', () => {
  const body = EXPERT_JS.slice(EXPERT_JS.indexOf('async function logout()'));
  const release = body.indexOf('releasePushSession');
  const terminate = body.indexOf('.terminate()');
  assert.ok(release > -1 && terminate > -1 && release < terminate,
    'after terminate() the release write can no longer run');
});

await it('the athlete logout does the same', () => {
  const body = PROFILE_JS.slice(PROFILE_JS.indexOf("confirmBtn.textContent = 'Logging out…'"));
  const release = body.indexOf('releasePushSession');
  const terminate = body.indexOf('.terminate()');
  assert.ok(release > -1 && terminate > -1 && release < terminate);
});

/* ── 5. Notifications neither stack nor overwrite each other ───────────── */

await it('two foreground notifications stay two', async () => {
  const env = await registeredAs('expert_1');
  env.foreground({ notification: { title: 'A', body: 'a' }, data: { notificationId: 'n1' } });
  env.foreground({ notification: { title: 'B', body: 'b' }, data: { notificationId: 'n2' } });
  await flush();
  assert.equal(env.shown.length, 2);
  assert.equal(env.shown[0].opts.tag, 'zitlas-n1');
  assert.equal(env.shown[1].opts.tag, 'zitlas-n2');
});

await it('the service worker tags each event', () => {
  const sw = swEnv();
  sw.deliver({ notification: { title: 'T', body: 'B' }, data: { notificationId: 'n1' } });
  sw.deliver({ data: { title: 'Coach', body: 'hi', chatId: 'room_1' } });
  assert.equal(sw.shown[0].o.tag, 'zitlas-n1');
  assert.equal(sw.shown[0].o.renotify, false);
  assert.equal(sw.shown[1].o.tag, 'zitlas-chat-room_1');
  assert.equal(sw.shown[1].o.renotify, true);
  assert.equal(sw.shown[1].t, 'Coach');
});

await it('page, service worker and backend use ONE tag rule', () => {
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(`${extractFn(PUSH, 'zitlasTag')}; var page = zitlasTag;`, ctx);
  vm.runInContext(`${extractFn(SW, 'zitlasTag')}; var worker = zitlasTag;`, ctx);
  // The same expectations backend/tests/test_notification_reliability.py pins
  // for push_service.web_tag().
  const cases = [
    [{ notificationId: 'n1' }, 'zitlas-n1'],
    [{ eventId: 'E1', notificationId: 'n1' }, 'zitlas-E1'],
    [{ chatId: 'room_1' }, 'zitlas-chat-room_1'],
    [{ type: 'coaching_accepted' }, 'zitlas-coaching_accepted'],
    [{}, 'zitlas-general'],
  ];
  for (const [data, expected] of cases) {
    assert.equal(ctx.page(data), expected, `page: ${JSON.stringify(data)}`);
    assert.equal(ctx.worker(data), expected, `worker: ${JSON.stringify(data)}`);
  }
});

/* ── report ─────────────────────────────────────────────────────────────── */

let failed = 0;
for (const [ok, name, err] of results) {
  if (ok) console.log(`  ok  ${name}`);
  else { failed++; console.log(`  FAIL  ${name}\n        ${err && err.message}`); }
}
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
