// Rules for the pilot feature switches (config/features) and Settle up by
// InstaPay (F45: settleUps, settleUpAddresses, settleUpLimits).
//
// What these tests prove:
// - config/features: a signed-in parent (verified or not) may read that one
//   document; nobody writes it from an app (parents, admins); it cannot be
//   listed; every other settings document stays closed (config/wallet,
//   config/kyc, config/settleUp); signed out reads nothing; a signed-out
//   phone (sessionsValidAfter) reads nothing.
// - settleUps/{id}: only its two parties read it (get and their own list
//   query); a third parent of the same carpool, an unverified stranger, an
//   admin and a signed-out client read nothing; a parent who was taken out
//   of `parties` (deleted account) no longer reads it; nobody creates,
//   changes (status, amount, parties, history) or deletes a record from an
//   app: the history is append-only because only Cloud Functions write.
// - settleUpAddresses/{uid}: nobody reads or writes an InstaPay address
//   directly, the owner included (it is shown only through functions).
// - settleUpLimits/{uid}: closed.
// - Collection-group queries on settleUpAddresses, settleUpLimits and
//   settleUps are refused for everyone (no recursive rule opens them).
// - A phone waiting for the new-phone check reads no settle-up record.
//
// Runs only against the emulators. Written, not run here (no npm registry
// in the build workspace); CI runs it.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
  type TokenOptions,
} from "@firebase/rules-unit-testing";
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const verified: TokenOptions = { ...token, verified: true as const };
const unverified: TokenOptions = { ...token };
const adminClaim: TokenOptions = { ...token, verified: true as const, admin: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const at = (ms: number) => firebase.firestore.Timestamp.fromMillis(ms);
const T = Date.UTC(2026, 10, 16, 8);
const SID = "s_0123456789abcdef0123456789abcdef01234567";
const GONE = "s_1123456789abcdef0123456789abcdef01234567";

function settleUp(parties: string[], over: Record<string, unknown> = {}) {
  return {
    requestId: "req-0000000000000001",
    createdBy: "payee",
    payeeUid: "alice",
    payerUid: "bob",
    payeeFirstName: "Alice",
    payerFirstName: "Bob",
    parties,
    carpoolId: "k1",
    amount: 15000,
    currency: "EGP",
    reason: "contribution",
    note: "",
    status: "open",
    finished: false,
    notReceived: 0,
    reportedBy: [],
    events: [{ type: "requested", by: "payee", at: at(T) }],
    createdAt: at(T),
    updatedAt: at(T),
    closedAt: null,
    keptUntilMs: null,
    ...over,
  };
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-features",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc("config/features").set({ wallet: false, ratingsAndVouching: false, yearlyChecks: false, settleUp: true });
    await db.doc("config/wallet").set({ perTransferMax: 200000 });
    await db.doc("config/kyc").set({ fakeResult: "match" });
    await db.doc("config/settleUp").set({ maxAmount: 500000 });
    await db.doc(`settleUps/${SID}`).set(settleUp(["alice", "bob"]));
    // Bob deleted his account: he is "deleted" and out of the parties.
    await db.doc(`settleUps/${GONE}`).set(settleUp(["alice"], { payerUid: "deleted", payerFirstName: "B.", status: "cancelled", finished: true }));
    await db.doc("settleUpAddresses/alice").set({ uid: "alice", address: "alice.test@instapay", updatedAt: at(T) });
    await db.doc("settleUpLimits/alice").set({ requests: { windowStartMs: T, count: 1 } });
    await db.doc("users/dave").set({ parentId: "DAVE2345", status: "verified", language: "ar", newDeviceCheck: { required: true } });
    await db.doc(`settleUps/s_dave`).set(settleUp(["alice", "dave"], { payerUid: "dave", payerFirstName: "Dave" }));
    await db.doc("users/erin").set({ parentId: "ERIN2345", status: "verified", language: "ar", sessionsValidAfter: Math.floor(Date.now() / 1000) + 3600 });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("config/features (pilot feature switches)", () => {
  it("a signed-in parent reads it, verified or not", async () => {
    await assertSucceeds(as("alice").firestore().doc("config/features").get());
    await assertSucceeds(as("newbie", unverified).firestore().doc("config/features").get());
  });

  it("signed out reads nothing; a phone that was signed out reads nothing", async () => {
    await assertFails(env.unauthenticatedContext().firestore().doc("config/features").get());
    await assertFails(as("erin").firestore().doc("config/features").get());
  });

  for (const [who, make] of [
    ["a parent", () => as("alice")],
    ["an unverified parent", () => as("alice", unverified)],
    ["an admin", () => as("admin1", adminClaim)],
    ["signed out", () => env.unauthenticatedContext()],
  ] as Array<[string, () => RulesTestContext]>) {
    it(`${who}: cannot turn a feature on or off, create or delete the document`, async () => {
      const d = make().firestore().doc("config/features");
      await assertFails(d.update({ wallet: true }));
      await assertFails(d.set({ wallet: true, ratingsAndVouching: true, yearlyChecks: true, settleUp: true }));
      await assertFails(d.set({ wallet: true }, { merge: true }));
      await assertFails(d.delete());
    });
  }

  it("the settings collection cannot be listed and every other settings document stays closed", async () => {
    const db = as("alice").firestore();
    await assertFails(db.collection("config").get());
    await assertFails(db.doc("config/wallet").get());
    await assertFails(db.doc("config/kyc").get());
    await assertFails(db.doc("config/settleUp").get());
    await assertFails(db.doc("config/settleUp").set({ maxAmount: 99999999 }));
    await assertFails(db.doc("config/other").set({ x: 1 }));
    await assertFails(as("admin1", adminClaim).firestore().doc("config/settleUp").get());
  });
});

describe("settleUps: read by the two parties only", () => {
  it("the payee and the payer read the record and list their own", async () => {
    await assertSucceeds(as("alice").firestore().doc(`settleUps/${SID}`).get());
    await assertSucceeds(as("bob").firestore().doc(`settleUps/${SID}`).get());
    await assertSucceeds(as("alice").firestore().collection("settleUps").where("parties", "array-contains", "alice").limit(50).get());
    await assertSucceeds(as("bob").firestore().collection("settleUps").where("parties", "array-contains", "bob").orderBy("updatedAt", "desc").limit(50).get());
  });

  it("nobody else reads it: another parent, an unverified stranger, an admin, signed out", async () => {
    for (const ctx of [as("cara"), as("stranger", unverified), as("admin1", adminClaim), env.unauthenticatedContext()]) {
      await assertFails(ctx.firestore().doc(`settleUps/${SID}`).get());
    }
    // Listing someone else's records, or everything, is refused.
    await assertFails(as("cara").firestore().collection("settleUps").where("parties", "array-contains", "alice").limit(50).get());
    await assertFails(as("cara").firestore().collection("settleUps").limit(50).get());
    await assertFails(as("alice").firestore().collection("settleUps").limit(50).get());
    await assertFails(as("alice").firestore().collection("settleUps").where("payeeUid", "==", "alice").limit(50).get());
  });

  it("a deleted parent's uid is out of the parties: the other parent still reads, the old uid does not", async () => {
    await assertSucceeds(as("alice").firestore().doc(`settleUps/${GONE}`).get());
    await assertFails(as("bob").firestore().doc(`settleUps/${GONE}`).get());
    await assertFails(as("deleted").firestore().doc(`settleUps/${GONE}`).get());
  });

  it("a phone waiting for the new-phone check reads no record", async () => {
    await assertFails(as("dave").firestore().doc("settleUps/s_dave").get());
    await assertSucceeds(as("alice").firestore().doc("settleUps/s_dave").get());
  });
});

describe("settleUps: the app never writes a record (append-only history)", () => {
  for (const [who, make] of [
    ["the payee", () => as("alice")],
    ["the payer", () => as("bob")],
    ["another parent", () => as("cara")],
    ["an admin", () => as("admin1", adminClaim)],
    ["signed out", () => env.unauthenticatedContext()],
  ] as Array<[string, () => RulesTestContext]>) {
    it(`${who}: cannot create, change or delete`, async () => {
      const db = make().firestore();
      const d = db.doc(`settleUps/${SID}`);
      await assertFails(d.update({ status: "closed" }));
      await assertFails(d.update({ status: "paid" }));
      await assertFails(d.update({ amount: 1 }));
      await assertFails(d.update({ parties: ["alice", "bob", "cara"] }));
      await assertFails(d.update({ events: [] }));
      await assertFails(d.update({ notReceived: 0, reportedBy: [] }));
      await assertFails(d.update({ note: "changed" }));
      await assertFails(d.set(settleUp(["alice", "bob"], { status: "closed" })));
      await assertFails(d.delete());
      await assertFails(db.doc("settleUps/s_new").set(settleUp(["alice", "bob"])));
      await assertFails(db.collection("settleUps").add(settleUp(["cara", "bob"], { payeeUid: "cara" })));
    });
  }
});

describe("settleUpAddresses: the InstaPay address is private", () => {
  for (const [who, make] of [
    ["the owner", () => as("alice")],
    ["the payer of an open request from the owner", () => as("bob")],
    ["another parent", () => as("cara")],
    ["an admin", () => as("admin1", adminClaim)],
    ["signed out", () => env.unauthenticatedContext()],
  ] as Array<[string, () => RulesTestContext]>) {
    it(`${who}: cannot read, list, set, change or delete an address`, async () => {
      const db = make().firestore();
      await assertFails(db.doc("settleUpAddresses/alice").get());
      await assertFails(db.collection("settleUpAddresses").limit(10).get());
      await assertFails(db.collection("settleUpAddresses").where("uid", "==", "alice").get());
      await assertFails(db.doc("settleUpAddresses/alice").set({ uid: "alice", address: "thief.test@instapay" }));
      await assertFails(db.doc("settleUpAddresses/alice").update({ address: "thief.test@instapay" }));
      await assertFails(db.doc("settleUpAddresses/alice").delete());
      await assertFails(db.doc("settleUpAddresses/bob").set({ uid: "bob", address: "bob.test@instapay" }));
    });
  }

  it("collection-group reads cannot reach an address or another parent's records", async () => {
    for (const ctx of [as("alice"), as("bob"), as("cara"), as("stranger", unverified), as("admin1", adminClaim), env.unauthenticatedContext()]) {
      const db = ctx.firestore();
      await assertFails(db.collectionGroup("settleUpAddresses").limit(10).get());
      await assertFails(db.collectionGroup("settleUpAddresses").where("uid", "==", "alice").get());
      await assertFails(db.collectionGroup("settleUpLimits").limit(10).get());
      // Records: a collection-group query is refused even for a party (the
      // rule is on the top-level collection only), so no query shape reads
      // records the caller is not in.
      await assertFails(db.collectionGroup("settleUps").limit(10).get());
      await assertFails(db.collectionGroup("settleUps").where("parties", "array-contains", "alice").get());
      await assertFails(db.collectionGroup("settleUps").where("payeeUid", "==", "alice").get());
    }
  });

  it("the counters are closed too", async () => {
    await assertFails(as("alice").firestore().doc("settleUpLimits/alice").get());
    await assertFails(as("alice").firestore().doc("settleUpLimits/alice").set({ requests: { windowStartMs: 0, count: 0 } }));
    await assertFails(as("alice").firestore().doc("settleUpLimits/alice").delete());
  });
});
