// Security review (16 Nov 2026, docs/security/threat-model.md): abuse cases
// against the rules in one place. A verified parent who is an approved
// member of one carpool ("mallory", the "predator posing as a parent" of
// the threat model) tries to reach other families' children, homes, exact
// pickup points, live locations, phones and admin data, by direct reads,
// unfiltered lists and collection-group queries. Every attempt must fail;
// the controls (the owner's own reads) must succeed, so a failure is the
// rule, not missing data.
// Runs only against the emulators (CI). Written, not run here (no npm
// registry in the build workspace).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";

const root = join(__dirname, "..", "..", "..");
let env: RulesTestEnvironment;

const nowSeconds = (): number => Math.floor(Date.now() / 1000);
const parent = (uid: string): RulesTestContext => env.authenticatedContext(uid, { verified: true, auth_time: nowSeconds() - 60 });

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-security-review",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of ["alice", "mallory"]) {
      await db.doc(`users/${uid}`).set({ firstName: uid, status: "verified", phone: "+20100000000" });
      await db.doc(`homes/${uid}`).set({ lat: 29.96, lng: 31.25 });
      await db.doc(`emergencyContacts/${uid}`).set({ name: "x", phone: "+20100000001" });
      await db.doc(`users/${uid}/notifications/n1`).set({ type: "trip-started", readAt: null });
    }
    // Alice's child, in carpool k1 (alice approved). Mallory is approved in k2 only.
    await db.doc("children/c1").set({ ownerUid: "alice", firstName: "Laila" });
    await db.doc("handoverAdults/c1").set({ ownerUid: "alice", adults: [{ name: "Aunt", phone: "+20100000002" }] });
    await db.doc("memberships/k1_alice").set({ carpoolId: "k1", uid: "alice", status: "approved", role: "admin" });
    await db.doc("memberships/k2_mallory").set({ carpoolId: "k2", uid: "mallory", status: "approved", role: "admin" });
    await db.doc("memberships/k1_mallory").set({ carpoolId: "k1", uid: "mallory", status: "requested", role: "member" });
    await db.doc("carpools/k1").set({ schoolId: "s1", seats: 4 });
    await db.doc("carpools/k1/members/alice").set({ children: [{ firstName: "Laila" }] });
    await db.doc("carpools/k1/pickupPoints/alice").set({ lat: 29.9601, lng: 31.2501 });
    await db.doc("carpools/k1/schedule/r1").set({ driverUid: "alice" });
    await db.doc("carpools/k2/pickupPoints/mallory").set({ lat: 29.9, lng: 31.2 });
    await db.doc("trips/t1").set({ driverUid: "alice", viewerUids: ["alice"], status: "active", last: { lat: 29.9, lng: 31.2 } });
    await db.doc("trips/t1/points/p1").set({ lat: 29.9, lng: 31.2 });
    await db.doc("trips/t1/eta/alice").set({ stops: [] });
    await db.doc("tripStops/t1").set({ stops: [{ lat: 29.96, lng: 31.25 }] });
    await db.doc("parentLocations/alice").set({ lat: 29.96, lng: 31.25 });
    await db.doc("nationalIds/h1").set({ uid: "alice" });
    await db.doc("verifications/v1").set({ uid: "alice", nationalIdLast4: "1234" });
    await db.doc("auditLog/a1").set({ actorUid: "admin1", action: "photos.view" });
    await db.doc("config/reviewAccess").set({ enabled: true });
    await db.doc("otpCodes/p_x").set({ codeHash: "h" });
    // Real files, so reads are refused by the rules, not by absence.
    const bucket = ctx.storage();
    for (const path of ["verification/alice/pending/id_front.jpg", "faceRefs/alice/selfie.jpg", "exports/alice/export.json"]) {
      await bucket.ref(path).putString("fake").then(() => undefined);
    }
  });
});

after(async () => {
  await env?.cleanup();
});

describe("security review: another family's data", () => {
  it("controls: alice reads her own child, home and pickup point", async () => {
    const db = parent("alice").firestore();
    await assertSucceeds(db.doc("children/c1").get());
    await assertSucceeds(db.doc("homes/alice").get());
    await assertSucceeds(db.doc("carpools/k1/pickupPoints/alice").get());
    await assertSucceeds(db.doc("trips/t1").get());
  });

  it("mallory cannot read alice's child, handover adults, home, emergency contact, record or notifications", async () => {
    const db = parent("mallory").firestore();
    for (const path of ["children/c1", "handoverAdults/c1", "homes/alice", "emergencyContacts/alice", "users/alice", "users/alice/notifications/n1"]) {
      await assertFails(db.doc(path).get());
    }
  });

  it("unfiltered lists are refused (no sweeping children, trips, memberships or homes)", async () => {
    const db = parent("mallory").firestore();
    await assertFails(db.collection("children").get());
    await assertFails(db.collection("children").where("ownerUid", "==", "alice").get());
    await assertFails(db.collection("trips").get());
    await assertFails(db.collection("memberships").get());
    await assertFails(db.collection("homes").get());
    await assertFails(db.collection("users").get());
  });

  it("a pending join request does not open the carpool's members, schedule or exact pickup points", async () => {
    const db = parent("mallory").firestore();
    await assertFails(db.doc("carpools/k1/members/alice").get());
    await assertFails(db.collection("carpools/k1/members").get());
    await assertFails(db.doc("carpools/k1/pickupPoints/alice").get());
    await assertFails(db.collection("carpools/k1/schedule").get());
  });

  it("live location: no trip, point or arrival time of a run mallory is not on; exact stops never", async () => {
    const db = parent("mallory").firestore();
    await assertFails(db.doc("trips/t1").get());
    await assertFails(db.doc("trips/t1/points/p1").get());
    await assertFails(db.collection("trips/t1/points").get());
    await assertFails(db.doc("trips/t1/eta/alice").get());
    await assertFails(db.doc("tripStops/t1").get());
    await assertFails(parent("alice").firestore().doc("tripStops/t1").get());
    await assertFails(db.doc("parentLocations/alice").get());
  });

  it("collection-group queries reach nothing (no {path=**} rule opens a subcollection)", async () => {
    const db = parent("mallory").firestore();
    for (const group of ["pickupPoints", "members", "requests", "points", "eta", "schedule", "notifications", "consents", "devices", "logins", "chatPushes", "emergencies"]) {
      await assertFails(db.collectionGroup(group).get());
    }
    // Not even filtered to her own documents.
    await assertFails(db.collectionGroup("pickupPoints").where("uid", "==", "mallory").get());
  });
});

describe("security review: server-only data", () => {
  it("national IDs, cases, the audit log, review access and sign-in codes are closed to parents", async () => {
    const db = parent("mallory").firestore();
    for (const path of ["nationalIds/h1", "verifications/v1", "auditLog/a1", "config/reviewAccess", "otpCodes/p_x"]) {
      await assertFails(db.doc(path).get());
    }
  });

  it("a parent cannot write a protected field on their own record (status, role, verification)", async () => {
    const db = parent("mallory").firestore();
    await assertFails(db.doc("users/mallory").update({ status: "verified" }));
    await assertFails(db.doc("users/mallory").update({ reviewDemo: true }));
    await assertFails(db.doc("users/mallory").update({ newDeviceCheck: null }));
    await assertFails(db.doc("users/mallory").update({ sessionsValidAfter: 0 }));
    await assertFails(db.doc("memberships/k1_mallory").update({ status: "approved" }));
    await assertFails(db.doc("config/features").set({ wallet: true, settleUp: true }));
  });

  it("forged claims in a custom-token-like identity open nothing admin", async () => {
    // A parent token with admin: true but no TOTP and no admin record.
    const forged = env.authenticatedContext("mallory", { admin: true, superAdmin: true, verified: true, auth_time: nowSeconds() - 60 });
    await assertFails(forged.firestore().doc("auditLog/a1").get());
    await assertFails(forged.firestore().collection("auditLog").get());
  });
});

describe("security review: Storage", () => {
  it("nobody reads another parent's (or their own) ID images", async () => {
    const mallory = parent("mallory").storage();
    await assertFails(mallory.ref("verification/alice/pending/id_front.jpg").getDownloadURL());
    await assertFails(mallory.ref("faceRefs/alice/selfie.jpg").getDownloadURL());
    await assertFails(mallory.ref("exports/alice/export.json").getDownloadURL());
    await assertFails(parent("alice").storage().ref("verification/alice/pending/id_front.jpg").getDownloadURL());
  });

  it("no upload into another parent's folder, no other file names, no non-JPEG, nothing over 3 MB", async () => {
    const mallory = parent("mallory").storage();
    const jpeg = (size: number) => new Uint8Array(size);
    await assertFails(mallory.ref("verification/alice/pending/selfie.jpg").put(jpeg(10), { contentType: "image/jpeg" }));
    await assertFails(mallory.ref("verification/mallory/pending/evil.html").put(jpeg(10), { contentType: "text/html" }));
    await assertFails(mallory.ref("verification/mallory/pending/selfie.jpg").put(jpeg(10), { contentType: "image/svg+xml" }));
    await assertFails(mallory.ref("verification/mallory/pending/selfie.jpg").put(jpeg(3 * 1024 * 1024), { contentType: "image/jpeg" }));
    await assertSucceeds(mallory.ref("verification/mallory/pending/selfie.jpg").put(jpeg(10), { contentType: "image/jpeg" }));
  });
});
