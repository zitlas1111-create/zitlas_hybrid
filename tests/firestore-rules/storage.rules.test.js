/**
 * ZITLAS — Storage rules: who can reach a meal photo
 * (tests/firestore-rules/storage.rules.test.js)
 *
 * ⚠ NOT YET EXECUTED. The emulator needs a JDK, which was not installed on the
 * machine where this was written, and node_modules here is empty. Every other
 * test shipped with this fix was run; this one was not. Run it yourself with:
 *
 *     cd tests/firestore-rules
 *     npm install
 *     npx firebase emulators:exec --only storage --project zitlas-b8677 \
 *       "npx mocha storage.rules.test.js --timeout 20000"
 *
 * WHAT IT GUARDS
 * --------------
 * The requirement was explicit: an expert must NOT be able to reach another
 * athlete's private meal photo by changing a uid in the URL. Storage rules
 * cannot consult Firestore, so they cannot ask "is this expert assigned to
 * this athlete?" — which is why the read rule is scoped to the owner instead
 * of to any signed-in caller.
 *
 * That does not lock the coach out. Coaches render the download URL stored on
 * the check-in, and a Firebase download URL carries its own access token: it
 * resolves without consulting these rules at all. Path-guessing is what stops
 * working. (No reader in the codebase builds a Storage ref for someone else's
 * photo — backend/tests/test_meal_photo_storage.py keeps that true.)
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const ATHLETE = 'athlete_alice';
const OTHER_ATHLETE = 'athlete_bob';
const EXPERT = 'expert_pratik';

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43, 0x00]);

let testEnv;

function bucketOf(ctx) {
  return ctx.storage();
}

before(async function () {
  this.timeout(30000);
  testEnv = await initializeTestEnvironment({
    projectId: 'zitlas-b8677',
    storage: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'storage.rules'), 'utf8'),
    },
  });
});

after(async () => { if (testEnv) await testEnv.cleanup(); });

beforeEach(async () => { if (testEnv) await testEnv.clearStorage(); });

describe('meal_checkins — the athlete owns the path', () => {
  it('the athlete can upload their own meal photo', async () => {
    const s = bucketOf(testEnv.authenticatedContext(ATHLETE));
    await assertSucceeds(
      s.ref(`meal_checkins/${ATHLETE}/123_abc.jpg`)
        .put(JPEG, { contentType: 'image/jpeg' })
    );
  });

  it('the athlete can read their own meal photo', async () => {
    const s = bucketOf(testEnv.authenticatedContext(ATHLETE));
    await s.ref(`meal_checkins/${ATHLETE}/123_abc.jpg`)
      .put(JPEG, { contentType: 'image/jpeg' });
    await assertSucceeds(s.ref(`meal_checkins/${ATHLETE}/123_abc.jpg`).getDownloadURL());
  });

  it('THE REQUIREMENT: an expert cannot read it by guessing the path', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.storage().ref(`meal_checkins/${ATHLETE}/123_abc.jpg`)
        .put(JPEG, { contentType: 'image/jpeg' });
    });
    const s = bucketOf(testEnv.authenticatedContext(EXPERT));
    await assertFails(s.ref(`meal_checkins/${ATHLETE}/123_abc.jpg`).getDownloadURL());
  });

  it('another athlete cannot read it either', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.storage().ref(`meal_checkins/${ATHLETE}/123_abc.jpg`)
        .put(JPEG, { contentType: 'image/jpeg' });
    });
    const s = bucketOf(testEnv.authenticatedContext(OTHER_ATHLETE));
    await assertFails(s.ref(`meal_checkins/${ATHLETE}/123_abc.jpg`).getDownloadURL());
  });

  it('a signed-out visitor cannot read it', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.storage().ref(`meal_checkins/${ATHLETE}/123_abc.jpg`)
        .put(JPEG, { contentType: 'image/jpeg' });
    });
    const s = bucketOf(testEnv.unauthenticatedContext());
    await assertFails(s.ref(`meal_checkins/${ATHLETE}/123_abc.jpg`).getDownloadURL());
  });

  it('nobody can write into another athlete\'s folder', async () => {
    const s = bucketOf(testEnv.authenticatedContext(EXPERT));
    await assertFails(
      s.ref(`meal_checkins/${ATHLETE}/planted.jpg`)
        .put(JPEG, { contentType: 'image/jpeg' })
    );
  });

  it('a non-image is rejected even from the owner', async () => {
    const s = bucketOf(testEnv.authenticatedContext(ATHLETE));
    await assertFails(
      s.ref(`meal_checkins/${ATHLETE}/payload.pdf`)
        .put(Buffer.from('%PDF-1.4'), { contentType: 'application/pdf' })
    );
  });
});

describe('meal_snaps — AI-only, nobody else is involved', () => {
  it('the athlete can write and read their own', async () => {
    const s = bucketOf(testEnv.authenticatedContext(ATHLETE));
    await assertSucceeds(
      s.ref(`meal_snaps/${ATHLETE}/1.jpg`).put(JPEG, { contentType: 'image/jpeg' })
    );
    await assertSucceeds(s.ref(`meal_snaps/${ATHLETE}/1.jpg`).getDownloadURL());
  });

  it('no one else can read it', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await ctx.storage().ref(`meal_snaps/${ATHLETE}/1.jpg`)
        .put(JPEG, { contentType: 'image/jpeg' });
    });
    const s = bucketOf(testEnv.authenticatedContext(EXPERT));
    await assertFails(s.ref(`meal_snaps/${ATHLETE}/1.jpg`).getDownloadURL());
  });
});

describe('the bucket is not open', () => {
  it('an undeclared path is closed to everyone', async () => {
    const s = bucketOf(testEnv.authenticatedContext(ATHLETE));
    await assertFails(
      s.ref('random_folder/anything.jpg').put(JPEG, { contentType: 'image/jpeg' })
    );
  });

  it('the rules file contains no blanket allow', () => {
    const rules = fs.readFileSync(
      path.join(__dirname, '..', '..', 'storage.rules'), 'utf8');
    assert.ok(!/allow\s+(read|write|read,\s*write)\s*:\s*if\s+true/.test(rules));
  });
});
