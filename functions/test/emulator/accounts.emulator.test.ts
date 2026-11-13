// User record and parent ID creation (F1, F44) on the Firestore and Auth
// emulators. Run: npm run test:emulator --prefix functions inside
// `firebase emulators:exec --only firestore,auth` (CI does this). Skipped
// when the emulators are not running.
import { strict as assert } from "node:assert";
import { after, before, describe, it } from "node:test";
import { deleteApp, initializeApp, type App } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { FirebaseAccountService, PARENT_IDS, USERS, ensureUserRecord } from "../../src/auth/accounts";
import { isParentId } from "../../src/auth/parent_id";

const running = Boolean(process.env.FIRESTORE_EMULATOR_HOST && process.env.FIREBASE_AUTH_EMULATOR_HOST);

function scripted(...sequences: number[][]): (size: number) => Buffer {
  let call = 0;
  return (size) => Buffer.from(sequences[Math.min(call++, sequences.length - 1)].slice(0, size));
}

describe("accounts on the emulators", { skip: running ? false : "emulators not running" }, () => {
  let app: App;
  let db: Firestore;
  const run = `${Date.now()}`;

  before(() => {
    app = initializeApp({ projectId: "demo-school-carpool" }, `accounts-test-${run}`);
    db = getFirestore(app);
  });

  after(async () => {
    await deleteApp(app);
  });

  it("creates an unverified user record and reserves its parent ID in one go", async () => {
    const uid = `u-new-${run}`;
    assert.equal(await ensureUserRecord(db, uid, "+201000000011", "ar"), "unverified");
    const user = (await db.collection(USERS).doc(uid).get()).data();
    assert.ok(user);
    assert.equal(user.status, "unverified");
    assert.equal(user.role, "parent");
    assert.ok(isParentId(user.parentId), String(user.parentId));
    const reserved = await db.collection(PARENT_IDS).doc(user.parentId).get();
    assert.equal(reserved.get("uid"), uid);
  });

  it("keeps the same parent ID when the parent signs in again", async () => {
    const uid = `u-again-${run}`;
    await ensureUserRecord(db, uid, "+201000000012", "ar");
    const first = (await db.collection(USERS).doc(uid).get()).get("parentId");
    await ensureUserRecord(db, uid, "+201000000012", "en");
    const second = (await db.collection(USERS).doc(uid).get()).get("parentId");
    assert.equal(second, first);
    const ids = await db.collection(PARENT_IDS).where("uid", "==", uid).get();
    assert.equal(ids.size, 1);
  });

  it("skips a parent ID that is already reserved", async () => {
    // Bytes 0 map to "22222222", bytes 1 to "33333333".
    await db.collection(PARENT_IDS).doc("22222222").set({ uid: "someone-else" });
    const uid = `u-taken-${run}`;
    await db.collection(PARENT_IDS).doc("33333333").delete();
    await ensureUserRecord(db, uid, "+201000000013", "ar", scripted([0, 0, 0, 0, 0, 0, 0, 0], [1, 1, 1, 1, 1, 1, 1, 1]));
    assert.equal((await db.collection(USERS).doc(uid).get()).get("parentId"), "33333333");
    assert.equal((await db.collection(PARENT_IDS).doc("22222222").get()).get("uid"), "someone-else");
  });

  it("gives 30 parents created at the same time 30 different parent IDs", async () => {
    const uids = Array.from({ length: 30 }, (_, i) => `u-many-${run}-${i}`);
    await Promise.all(uids.map((uid, i) => ensureUserRecord(db, uid, `+2010000${String(i).padStart(5, "0")}`, "ar")));
    const ids = await Promise.all(uids.map(async (uid) => (await db.collection(USERS).doc(uid).get()).get("parentId")));
    assert.equal(new Set(ids).size, 30);
  });

  it("copies a confirmed email on the next sign-in", async () => {
    const uid = `u-email-${run}`;
    await ensureUserRecord(db, uid, "+201000000014", "ar");
    await ensureUserRecord(db, uid, "+201000000014", "ar", undefined, "parent@example.com");
    const user = (await db.collection(USERS).doc(uid).get()).data();
    assert.equal(user?.email, "parent@example.com");
    assert.equal(user?.emailVerified, true);
  });

  it("signs the same number in to the same account and gives a custom token", async () => {
    const accounts = new FirebaseAccountService(getAuth(app), db);
    const phone = `+20115${run.slice(-7)}`;
    const first = await accounts.signInWithPhone(phone, "ar");
    const second = await accounts.signInWithPhone(phone, "en");
    assert.equal(second.uid, first.uid);
    assert.equal(first.suspended, false);
    assert.ok((await accounts.createToken(first.uid)).length > 0);
    const user = (await db.collection(USERS).doc(first.uid).get()).data();
    assert.equal(user?.phone, phone);
    assert.equal(user?.status, "unverified");
  });
});
