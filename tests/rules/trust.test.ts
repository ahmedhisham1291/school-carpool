// Rules for Prompt 11 (F17): trust and yearly checks.
//
// What these tests prove:
// - ratings, trustSummaries, ratingFlags, guardianRequests, guardianLinks
//   and trustLimits are closed to everyone, the parents named in them
//   included (the trust functions read and write them).
// - A parent linked to another parent's child (guardian link) still cannot
//   read that child's record directly; children stay readable by their
//   own parent only (Prompt 3).
// - Users cannot set the yearly-check fields on their own record.
// - storage: a verified parent uploads only their own phone-change selfie
//   (selfie.jpg, JPEG, < 3 MB); nobody reads it.
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

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const verified: TokenOptions = { ...token, verified: true as const };
const adminClaim: TokenOptions = { ...token, verified: true as const, admin: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

const CLOSED: Array<[string, Record<string, unknown>]> = [
  ["ratings/2026-11_alice_bob", { raterUid: "alice", rateeUid: "bob", stars: 5, month: "2026-11" }],
  ["trustSummaries/bob", { count: 1, sum: 5, voucherUids: ["alice"] }],
  ["ratingFlags/2026-11_alice_bob", { raterUid: "alice", rateeUid: "bob", status: "open" }],
  ["guardianRequests/bob_dina", { ownerUid: "bob", guardianUid: "dina", status: "requested" }],
  ["guardianLinks/b1_dina", { childId: "b1", ownerUid: "bob", guardianUid: "dina", status: "active" }],
  ["trustLimits/alice", { ratings: { windowStartMs: 1, count: 1 } }],
];

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-trust",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // Fake data only.
    for (const [path, data] of CLOSED) await db.doc(path).set(data);
    await db.doc("children/b1").set({ ownerUid: "bob", firstName: "Bassel", status: "approved" });
    await db.doc("users/dina").set({ status: "verified", language: "ar" });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("trust records are Functions only", () => {
  for (const [path, data] of CLOSED) {
    it(`nobody reads or writes ${path}`, async () => {
      for (const ctx of [as("alice"), as("bob"), as("dina"), as("admin1", adminClaim), signedOut()]) {
        const d = ctx.firestore().doc(path);
        await assertFails(d.get());
        await assertFails(d.set(data));
        await assertFails(d.update({ status: "active" }));
        await assertFails(d.delete());
      }
    });
  }

  it("parents cannot list ratings or links about themselves", async () => {
    await assertFails(as("bob").firestore().collection("ratings").where("rateeUid", "==", "bob").get());
    await assertFails(as("dina").firestore().collection("guardianLinks").where("guardianUid", "==", "dina").get());
    await assertFails(as("bob").firestore().collection("guardianRequests").where("ownerUid", "==", "bob").get());
  });

  it("a linked parent does not read the child record; the child's parent does", async () => {
    await assertSucceeds(as("bob").firestore().doc("children/b1").get());
    await assertFails(as("dina").firestore().doc("children/b1").get());
    await assertFails(as("dina").firestore().doc("children/b1").update({ status: "left" }));
  });

  it("a parent cannot confirm the school year or clear the overdue mark on their own record", async () => {
    const me = as("dina").firestore().doc("users/dina");
    await assertFails(me.update({ schoolYearConfirmed: 2027 }));
    await assertFails(me.update({ yearCheckOverdue: false }));
    await assertFails(me.update({ phone: "+201099999999" }));
    await assertSucceeds(me.update({ language: "en" }));
  });
});

describe("storage: phone-change selfies", () => {
  const jpeg = { contentType: "image/jpeg" };

  it("a verified parent uploads their own selfie; nobody reads it", async () => {
    const ref = as("alice").storage().ref("phoneChecks/alice/selfie.jpg");
    await assertSucceeds(ref.putString("fake-jpeg", "raw", jpeg).then(() => undefined));
    await assertFails(ref.getDownloadURL());
    await assertFails(ref.delete());
    await assertFails(as("bob").storage().ref("phoneChecks/alice/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("alice", token).storage().ref("phoneChecks/alice/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("alice").storage().ref("phoneChecks/alice/other.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("alice").storage().ref("phoneChecks/alice/selfie.jpg").putString("x", "raw", { contentType: "image/png" }).then(() => undefined));
    await assertFails(signedOut().storage().ref("phoneChecks/alice/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
  });
});
