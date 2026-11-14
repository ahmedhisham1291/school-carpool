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

// --------------------------------------------------------------------------
// Prompt 12 review: the new-phone gate and signed-out phones, enforced by
// the rules (users/{uid}.newDeviceCheck and sessionsValidAfter, written
// only by Cloud Functions).
// --------------------------------------------------------------------------

const nowSeconds = (): number => Math.floor(Date.now() / 1000);

/** Every child, carpool, schedule, trip and location read Alice's app makes. */
function aliceReads(ctx: RulesTestContext): Array<[string, () => Promise<unknown>]> {
  const db = ctx.firestore();
  return [
    ["children/a1", () => db.doc("children/a1").get()],
    ["children query", () => db.collection("children").where("ownerUid", "==", "alice").get()],
    ["carpools/k1/members", () => db.collection("carpools/k1/members").get()],
    ["carpools/k1/requests/alice", () => db.doc("carpools/k1/requests/alice").get()],
    ["carpools/k1/pickupPoints/alice", () => db.doc("carpools/k1/pickupPoints/alice").get()],
    ["carpools/k1/pickupPoints/carl", () => db.doc("carpools/k1/pickupPoints/carl").get()],
    ["carpools/k1/schedule", () => db.collection("carpools/k1/schedule").get()],
    ["carpools/k1/swaps", () => db.collection("carpools/k1/swaps").get()],
    ["carpools/k1/emergencies", () => db.collection("carpools/k1/emergencies").get()],
    ["trips/t1", () => db.doc("trips/t1").get()],
    ["trips query", () => db.collection("trips").where("viewerUids", "array-contains", "alice").get()],
    ["trips/t1/points", () => db.collection("trips/t1/points").get()],
    ["trips/t1/eta/alice", () => db.doc("trips/t1/eta/alice").get()],
    ["handoverAdults/a1", () => db.doc("handoverAdults/a1").get()],
    ["homes/alice", () => db.doc("homes/alice").get()],
    ["emergencyContacts/alice", () => db.doc("emergencyContacts/alice").get()],
    ["notifications", () => db.collection("users/alice/notifications").limit(20).get()],
    ["chatSettings/alice", () => db.doc("chatSettings/alice").get()],
  ];
}

async function seedAliceCarpool(): Promise<void> {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // Fake data only.
    await db.doc("memberships/k1_alice").set({ carpoolId: "k1", uid: "alice", status: "approved", role: "admin" });
    await db.doc("memberships/k1_carl").set({ carpoolId: "k1", uid: "carl", status: "approved", role: "member" });
    await db.doc("carpools/k1").set({ status: "open", creatorFirstName: "Alice" });
    await db.doc("carpools/k1/members/alice").set({ uid: "alice", children: [{ firstName: "Adam", grade: 3 }] });
    await db.doc("carpools/k1/requests/alice").set({ uid: "alice", children: [{ firstName: "Adam" }] });
    await db.doc("carpools/k1/pickupPoints/alice").set({ lat: 30.1, lng: 31.2 });
    await db.doc("carpools/k1/pickupPoints/carl").set({ lat: 30.2, lng: 31.3 });
    await db.doc("carpools/k1/schedule/r1").set({ driverUid: "carl", riders: [{ firstName: "Adam" }] });
    await db.doc("carpools/k1/swaps/s1").set({ fromUid: "carl" });
    await db.doc("carpools/k1/emergencies/e1").set({ driverUid: "carl" });
    await db.doc("trips/t1").set({ driverUid: "carl", status: "active", viewerUids: ["alice", "carl"], stops: [{ firstName: "Adam" }] });
    await db.doc("trips/t1/points/p1").set({ lat: 30.15, lng: 31.25 });
    await db.doc("trips/t1/eta/alice").set({ minutes: 7 });
    await db.doc("handoverAdults/a1").set({ ownerUid: "alice", adults: [{ name: "Grandma" }] });
    await db.doc("homes/alice").set({ lat: 30.1, lng: 31.2 });
    await db.doc("emergencyContacts/alice").set({ name: "Uncle" });
    await db.doc("users/alice/notifications/n1").set({ title: "Adam was picked up", readAt: null });
    await db.doc("chatSettings/alice").set({ acceptRequests: true });
  });
}

async function setAliceRecord(fields: Record<string, unknown>): Promise<void> {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc("users/alice").update(fields);
  });
}

describe("firestore: the new-phone gate and signed-out phones (SIM swap)", () => {
  it("SIM swap: the old phone is out at once; the new phone reads no child, carpool, schedule, trip or location data until the selfie matched", async () => {
    await seedAliceCarpool();
    const oldPhone = (): RulesTestContext => as("alice", { ...verified, auth_time: nowSeconds() - 3600 });
    const newPhone = (): RulesTestContext => as("alice", { ...verified, auth_time: nowSeconds() - 60 });

    // Before: everything Alice may read is open.
    for (const [name, read] of aliceReads(oldPhone())) await assertSucceeds(read()).catch((e) => Promise.reject(new Error(`${name}: ${String(e)}`)));

    // Someone takes over Alice's number and signs in on another phone:
    // verifyCode signed every phone out and opened the new-phone check.
    await setAliceRecord({ sessionsValidAfter: nowSeconds() - 600, newDeviceCheck: { required: true } });

    // The phone signed in before: nothing, its own record included.
    await assertFails(oldPhone().firestore().doc("users/alice").get());
    for (const [name, read] of aliceReads(oldPhone())) await assertFails(read()).catch((e) => Promise.reject(new Error(`old phone ${name}: ${String(e)}`)));

    // The new phone: its own record (to show the selfie screen), nothing else.
    await assertSucceeds(newPhone().firestore().doc("users/alice").get());
    for (const [name, read] of aliceReads(newPhone())) await assertFails(read()).catch((e) => Promise.reject(new Error(`new phone ${name}: ${String(e)}`)));
    // Family links, transfers and wallets are closed to every phone anyway.
    await assertFails(newPhone().firestore().doc("guardianLinks/l1").get());
    await assertFails(newPhone().firestore().doc("wallets/alice").get());
    // The app cannot clear either field itself.
    await assertFails(newPhone().firestore().doc("users/alice").update({ newDeviceCheck: null }));
    await assertFails(newPhone().firestore().doc("users/alice").update({ sessionsValidAfter: 0 }));

    // The selfie matched (confirmNewDevice clears the check): the new phone
    // reads again; the old phone stays out.
    await setAliceRecord({ newDeviceCheck: null });
    for (const [name, read] of aliceReads(newPhone())) await assertSucceeds(read()).catch((e) => Promise.reject(new Error(`after selfie ${name}: ${String(e)}`)));
    await assertFails(oldPhone().firestore().doc("children/a1").get());
    await assertFails(oldPhone().firestore().doc("trips/t1").get());
  });

  it("a phone signed out from the devices screen loses access at once, not when its token expires", async () => {
    await seedAliceCarpool();
    const signedOutPhone = as("alice", { ...verified, auth_time: nowSeconds() - 120 });
    await assertSucceeds(signedOutPhone.firestore().doc("homes/alice").get());
    await setAliceRecord({ sessionsValidAfter: nowSeconds() - 30 });
    await assertFails(signedOutPhone.firestore().doc("homes/alice").get());
    await assertFails(signedOutPhone.firestore().doc("users/alice").get());
    await assertFails(signedOutPhone.firestore().doc("users/alice").update({ language: "en" }));
    await assertFails(signedOutPhone.firestore().collection("memberships").where("uid", "==", "alice").get());
    // The phone that signed it out signs in again with a fresh token.
    const fresh = as("alice", { ...verified, auth_time: nowSeconds() });
    await assertSucceeds(fresh.firestore().doc("homes/alice").get());
    await assertSucceeds(fresh.firestore().collection("memberships").where("uid", "==", "alice").get());
  });
});
