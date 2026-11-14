// Rules for Prompt 12: privacy and security hardening.
//
// What these tests prove:
// - Every record Prompt 12 adds (closedAccounts, privacyRequests,
//   securityAlerts, abuseCounters, routeArchives, retentionRuns, mail, and
//   the users/{uid}/devices and users/{uid}/logins subcollections) is
//   closed to everyone, the parent it is about included: the privacy
//   functions read and write them.
// - The app cannot set or clear newDeviceCheck on its own record.
// - Child records stay closed to their own parent while a new-phone check
//   is open, and open again once it is cleared.
// - storage: a verified parent uploads only their own new-phone selfie
//   (deviceChecks/{uid}/selfie.jpg, JPEG, < 3 MB); nobody reads it. The
//   selfie archive, thumbnails, exports and route archives are closed.
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
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

const CLOSED: Array<[string, Record<string, unknown>]> = [
  ["closedAccounts/gone", { parentId: "ABCD2345", failed: [], failedCount: 0, purged: false }],
  ["privacyRequests/r1", { uid: "alice", kind: "export", status: "done" }],
  ["securityAlerts/a1", { uid: "alice", kind: "profiles", count: 30, status: "open" }],
  ["abuseCounters/alice_profiles_1", { uid: "alice", kind: "profiles", count: 3 }],
  ["routeArchives/k1_2026-11-14_am", { driverUid: "alice", path: "routeArchive/2026/k1_2026-11-14_am.json.gz" }],
  ["retentionRuns/2026-11-14", { date: "2026-11-14", failures: [] }],
  ["mail/m1", { to: "parent@example.com", message: { subject: "x", text: "y" } }],
  ["users/alice/devices/s_aaaa", { platform: "ios" }],
  ["users/alice/logins/l1", { deviceKey: "s_aaaa", platform: "ios" }],
];

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-privacy",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // Fake data only.
    await db.doc("users/alice").set({ parentId: "ABCD2345", status: "verified", language: "ar" });
    await db.doc("users/bob").set({ parentId: "EFGH2345", status: "verified", language: "ar", newDeviceCheck: { required: true } });
    await db.doc("children/a1").set({ ownerUid: "alice", firstName: "Adam", status: "approved" });
    await db.doc("children/b1").set({ ownerUid: "bob", firstName: "Bana", status: "approved" });
    for (const [path, data] of CLOSED) await db.doc(path).set(data);
    const storage = ctx.storage();
    for (const path of ["selfieArchive/alice/run_x.jpg", "thumbs/alice/abc.webp", "exports/alice/r1.json", "routeArchive/2026/k1.json.gz", "deviceChecks/alice/selfie.jpg"]) {
      await storage.ref(path).putString("x", "raw", { contentType: "application/octet-stream" });
    }
  });
});

after(async () => {
  await env.cleanup();
});

describe("firestore: Prompt 12 records are closed", () => {
  it("nobody reads or writes them from the app, the parent they are about included", async () => {
    for (const [path, data] of CLOSED) {
      for (const ctx of [as("alice"), as("bob"), signedOut()]) {
        const ref = ctx.firestore().doc(path);
        await assertFails(ref.get());
        await assertFails(ref.set(data));
        await assertFails(ref.delete());
      }
    }
    await assertFails(as("alice").firestore().collection("privacyRequests").where("uid", "==", "alice").get());
    await assertFails(as("alice").firestore().collection("users/alice/devices").get());
  });

  it("a parent cannot set or clear the new-phone check", async () => {
    await assertFails(as("alice").firestore().doc("users/alice").update({ newDeviceCheck: { required: false } }));
    await assertFails(as("bob").firestore().doc("users/bob").update({ newDeviceCheck: null }));
    await assertSucceeds(as("bob").firestore().doc("users/bob").update({ language: "en" }));
  });
});

describe("firestore: child data waits for the new-phone selfie", () => {
  it("open for a parent without a check; closed while the check is open; open again when cleared", async () => {
    await assertSucceeds(as("alice").firestore().doc("children/a1").get());
    await assertSucceeds(as("alice").firestore().collection("children").where("ownerUid", "==", "alice").get());
    await assertFails(as("bob").firestore().doc("children/b1").get());
    await assertFails(as("bob").firestore().collection("children").where("ownerUid", "==", "bob").get());
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("users/bob").update({ newDeviceCheck: null });
    });
    await assertSucceeds(as("bob").firestore().doc("children/b1").get());
  });
});

describe("storage: new-phone selfie and closed Prompt 12 paths", () => {
  const jpeg = { contentType: "image/jpeg" };

  it("a verified parent uploads their own selfie; nobody reads it", async () => {
    const ref = as("bob").storage().ref("deviceChecks/bob/selfie.jpg");
    await assertSucceeds(ref.putString("fake-jpeg", "raw", jpeg).then(() => undefined));
    await assertFails(ref.getDownloadURL());
    await assertFails(ref.delete());
    await assertFails(as("alice").storage().ref("deviceChecks/bob/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("bob", token).storage().ref("deviceChecks/bob/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("bob").storage().ref("deviceChecks/bob/other.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("bob").storage().ref("deviceChecks/bob/selfie.jpg").putString("x", "raw", { contentType: "image/png" }).then(() => undefined));
    await assertFails(signedOut().storage().ref("deviceChecks/bob/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
  });

  it("the selfie archive, thumbnails, exports and route archives are closed, to their owner too", async () => {
    for (const path of ["selfieArchive/alice/run_x.jpg", "thumbs/alice/abc.webp", "exports/alice/r1.json", "routeArchive/2026/k1.json.gz"]) {
      await assertFails(as("alice").storage().ref(path).getDownloadURL());
      await assertFails(as("alice").storage().ref(path).putString("x", "raw", jpeg).then(() => undefined));
      await assertFails(as("alice").storage().ref(path).delete());
    }
  });
});
