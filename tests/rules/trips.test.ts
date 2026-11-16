// Rules for Prompt 10 (F15, F16, F20, F29, F33, F34, F38, F41): trips.
//
// What these tests prove:
// - trips/{id} is read only by its driver and the parents of the children
//   on THAT run (viewerUids, verified claim): not other members of the
//   carpool, not a parent whose child is absent, not other carpools,
//   signed-out users or admins.
// - trips/{id}/points are read by the same people and only while the run
//   is tracked (status "active"); after the last drop-off nobody reads them.
// - trips/{id}/eta/{parentUid}: that parent and the driver only.
// - Nobody writes a trip, a point, an arrival time or a check from the app,
//   not even the driver (points come through the tripLocation function).
// - tripStops (exact stop points) and tripLimits are closed to everyone.
// - tripChecks: the run's driver reads its own selfie check.
// - handoverAdults: the child's parent reads the list; emergencyContacts:
//   the parent reads their own; nobody writes either from the app.
// - carpools/{id}/emergencies: approved members of that carpool read.
// - storage: the driver uploads only their own live selfie (JPEG, < 3 MB,
//   verified); nobody reads selfies or driver photos.
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

const TRIP = "trips/k1_2026-11-16_am";
const POINT = `${TRIP}/points/pt1`;
const ETA_BOB = `${TRIP}/eta/bob`;
const ETA_CARA = `${TRIP}/eta/cara`;
const STOPS = "tripStops/k1_2026-11-16_am";
const CHECK = "tripChecks/k1_2026-11-16_am";
const EMERGENCY = "carpools/k1/emergencies/e1";

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-trips",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // k1: alice drives; bob and cara have children on the run; dan's child
    // is absent; erin is a member with no child on it; fay is in k2.
    const member = (carpoolId: string, uid: string, status = "approved") =>
      db.doc(`memberships/${carpoolId}_${uid}`).set({ carpoolId, uid, status, role: "member" });
    for (const uid of ["alice", "bob", "cara", "dan", "erin"]) await member("k1", uid);
    await member("k1", "gus", "left");
    await member("k2", "fay");
    // Fake data only.
    await db.doc(TRIP).set({
      carpoolId: "k1",
      runId: "2026-11-16_am",
      date: "2026-11-16",
      driverUid: "alice",
      status: "active",
      viewerUids: ["alice", "bob", "cara"],
      childIds: ["b1", "c1", "d1"],
      stops: [
        { childId: "b1", firstName: "Kid", parentUid: "bob", state: "waiting", handover: [{ name: "Gran", relation: "grandparent" }] },
        { childId: "c1", firstName: "Kid", parentUid: "cara", state: "waiting", handover: [] },
        { childId: "d1", firstName: "Kid", parentUid: "dan", state: "absent", handover: [] },
      ],
      last: { lat: 30.0, lng: 31.0 },
    });
    await db.doc(POINT).set({ time: 1, accuracy: 5 });
    await db.doc(ETA_BOB).set({ stops: { b1: 1 } });
    await db.doc(ETA_CARA).set({ stops: { c1: 1 } });
    await db.doc(STOPS).set({ homes: {}, school: null });
    await db.doc(CHECK).set({ driverUid: "alice", status: "required" });
    await db.doc("handoverAdults/b1").set({ ownerUid: "bob", adults: [{ name: "Gran", relation: "grandparent", phone: "+201000000000" }] });
    await db.doc("emergencyContacts/alice").set({ name: "Sis", phone: "+201000000001", relation: "sibling" });
    await db.doc(EMERGENCY).set({ carpoolId: "k1", driverUid: "alice", at: 1 });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("trips: only the run's driver and parents read", () => {
  it("the driver and the parents of children on the run read the trip and its live points", async () => {
    for (const uid of ["alice", "bob", "cara"]) {
      await assertSucceeds(as(uid).firestore().doc(TRIP).get());
      await assertSucceeds(as(uid).firestore().doc(POINT).get());
      await assertSucceeds(as(uid).firestore().collection(`${TRIP}/points`).orderBy("time", "desc").limit(20).get());
    }
    // The app's "my trips today" query.
    await assertSucceeds(as("bob").firestore().collection("trips").where("viewerUids", "array-contains", "bob").where("date", "==", "2026-11-16").get());
  });

  it("a parent whose child is not on the run, other members, other carpools and left members see nothing", async () => {
    for (const uid of ["dan", "erin", "fay", "gus", "zed"]) {
      await assertFails(as(uid).firestore().doc(TRIP).get());
      await assertFails(as(uid).firestore().doc(POINT).get());
      await assertFails(as(uid).firestore().collection(`${TRIP}/points`).get());
      await assertFails(as(uid).firestore().doc(ETA_BOB).get());
    }
    await assertFails(as("dan").firestore().collection("trips").where("viewerUids", "array-contains", "bob").get());
    await assertFails(as("dan").firestore().collection("trips").where("carpoolId", "==", "k1").get());
  });

  it("no verified claim, signed out or an admin: nothing", async () => {
    for (const ctx of [as("bob", token), signedOut(), as("admin1", adminClaim)]) {
      await assertFails(ctx.firestore().doc(TRIP).get());
      await assertFails(ctx.firestore().doc(POINT).get());
      await assertFails(ctx.firestore().doc(ETA_BOB).get());
    }
  });

  it("after the last drop-off the points are closed, even to the run's parents", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc(TRIP).update({ status: "handover", last: null });
    });
    for (const uid of ["alice", "bob"]) {
      await assertFails(as(uid).firestore().doc(POINT).get());
      await assertFails(as(uid).firestore().collection(`${TRIP}/points`).get());
      // The stops stay readable (handover confirmations).
      await assertSucceeds(as(uid).firestore().doc(TRIP).get());
    }
  });

  it("arrival times: each parent reads their own, the driver reads all", async () => {
    await assertSucceeds(as("bob").firestore().doc(ETA_BOB).get());
    await assertFails(as("bob").firestore().doc(ETA_CARA).get());
    await assertSucceeds(as("alice").firestore().doc(ETA_BOB).get());
    await assertSucceeds(as("alice").firestore().doc(ETA_CARA).get());
    await assertFails(as("alice").firestore().collection(`${TRIP}/eta`).get());
  });
});

describe("trips: only Cloud Functions write", () => {
  it("the driver cannot write points, stops or the trip", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(`${TRIP}/points/pt2`).set({ time: 2, accuracy: 5 }));
    await assertFails(db.collection(`${TRIP}/points`).add({ time: 2 }));
    await assertFails(db.doc(TRIP).update({ "last.lat": 31 }));
    await assertFails(db.doc(TRIP).update({ status: "ended" }));
    await assertFails(db.doc("trips/k1_2026-11-17_am").set({ driverUid: "alice", viewerUids: ["alice"], status: "active" }));
    await assertFails(db.doc(ETA_BOB).set({ stops: {} }));
    await assertFails(db.doc(CHECK).update({ status: "passed" }));
  });

  it("parents cannot mark a child received or add themselves as viewers", async () => {
    await assertFails(as("bob").firestore().doc(TRIP).update({ stops: [] }));
    await assertFails(as("dan").firestore().doc(TRIP).update({ viewerUids: ["alice", "bob", "cara", "dan"] }));
  });

  it("exact stop points and limits are closed to everyone", async () => {
    for (const ctx of [as("alice"), as("bob"), as("admin1", adminClaim), signedOut()]) {
      await assertFails(ctx.firestore().doc(STOPS).get());
      await assertFails(ctx.firestore().doc("tripLimits/alice").get());
    }
  });
});

describe("trips: checks, handover list, emergency contact and emergencies", () => {
  it("the selfie check: its driver only", async () => {
    await assertSucceeds(as("alice").firestore().doc(CHECK).get());
    await assertFails(as("bob").firestore().doc(CHECK).get());
    await assertFails(as("alice", token).firestore().doc(CHECK).get());
  });

  it("the handover list: the child's parent only; nobody writes it", async () => {
    await assertSucceeds(as("bob").firestore().doc("handoverAdults/b1").get());
    await assertFails(as("alice").firestore().doc("handoverAdults/b1").get());
    await assertFails(as("cara").firestore().doc("handoverAdults/b1").get());
    await assertFails(as("bob").firestore().doc("handoverAdults/b1").set({ ownerUid: "bob", adults: [] }));
    await assertFails(as("bob").firestore().collection("handoverAdults").where("ownerUid", "==", "alice").get());
  });

  it("the emergency contact: its owner only; nobody writes it", async () => {
    await assertSucceeds(as("alice").firestore().doc("emergencyContacts/alice").get());
    await assertFails(as("bob").firestore().doc("emergencyContacts/alice").get());
    await assertFails(as("alice").firestore().doc("emergencyContacts/alice").set({ name: "X", phone: "+201000000002" }));
    // R6: the contact's answer and link token are written by the server only; nobody lists contacts by token.
    await assertFails(as("alice").firestore().doc("emergencyContacts/alice").update({ status: "confirmed" }));
    await assertFails(as("alice").firestore().collection("emergencyContacts").where("token", "==", "a".repeat(64)).get());
  });

  it("emergencies: approved members of the carpool (also those without a child on the run)", async () => {
    for (const uid of ["alice", "bob", "dan", "erin"]) await assertSucceeds(as(uid).firestore().doc(EMERGENCY).get());
    for (const uid of ["fay", "gus", "zed"]) await assertFails(as(uid).firestore().doc(EMERGENCY).get());
    await assertFails(as("erin", token).firestore().doc(EMERGENCY).get());
    await assertFails(as("alice").firestore().doc("carpools/k1/emergencies/e2").set({ driverUid: "alice" }));
  });
});

describe("storage: live selfies and driver photos", () => {
  const jpeg = { contentType: "image/jpeg" };

  it("the driver uploads their own live selfie; nobody reads it", async () => {
    const ref = as("alice").storage().ref("selfieChecks/alice/k1_2026-11-16_am.jpg");
    await assertSucceeds(ref.putString("fake-jpeg", "raw", jpeg).then(() => undefined));
    await assertFails(ref.getDownloadURL());
    await assertFails(as("bob").storage().ref("selfieChecks/alice/k1_2026-11-16_am.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("alice", token).storage().ref("selfieChecks/alice/k1_2026-11-16_am.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("alice").storage().ref("selfieChecks/alice/x.png").putString("x", "raw", { contentType: "image/png" }).then(() => undefined));
    // Only a run's name (no other images under this folder).
    await assertFails(as("alice").storage().ref("selfieChecks/alice/holiday.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("bob").storage().ref("faceRefs/alice/selfie.jpg").getDownloadURL());
    await assertFails(as("alice").storage().ref("faceRefs/alice/selfie.jpg").putString("x", "raw", jpeg).then(() => undefined));
  });

  it("the driver photo is uploaded only as part of verification and never read by the app", async () => {
    await assertSucceeds(as("alice", token).storage().ref("verification/alice/pending/driver_photo.jpg").putString("fake-jpeg", "raw", jpeg).then(() => undefined));
    await assertFails(as("alice").storage().ref("driverPhotos/alice/photo.jpg").putString("x", "raw", jpeg).then(() => undefined));
    await assertFails(as("bob").storage().ref("driverPhotos/alice/photo.jpg").getDownloadURL());
  });
});
