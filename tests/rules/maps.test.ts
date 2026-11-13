// Rules for Prompt 5 (F21 to F24): homes and maps.
//
// What these tests prove (the app never receives another parent's exact
// coordinates):
// - homes/{uid} (the EXACT home) is readable by its owner only: not by
//   another parent, a verified parent, or a member of the same carpool.
// - parentLocations (rounded points) is closed to every app user, the
//   owner included: only Cloud Functions read it (searchNearbyParents).
// - carpools/{id}/pickupPoints/{uid} (an EXACT pickup point the parent
//   chose to share) is readable only by its owner and by verified parents
//   who are approved members of the same carpool, with seeded memberships
//   (memberships/{carpoolId}_{uid}, created by Cloud Functions in Prompt 6).
// - Nothing here is written by the app.
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
const verified = { ...token, verified: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

// Fake points only.
const EXACT = { latitude: 29.96123, longitude: 31.25671 };
const ROUNDED = { latitude: 29.9625, longitude: 31.2575 };

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-maps",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const uid of ["alice", "bob", "cara", "dan"]) {
      await db.doc(`homes/${uid}`).set({ location: EXACT, label: "Road 9, Maadi", showOnMap: true, notifyNewParents: true, radiusKm: 3, drivingSchools: [] });
      await db.doc(`parentLocations/${uid}`).set({ point: ROUNDED, geohash: "stq4bc5", firstName: uid, verified: true, showOnMap: true, schoolIds: ["nile"] });
    }
    // Carpool k1: alice and bob approved, cara only requested.
    // Carpool k2: dan approved.
    const member = (carpoolId: string, uid: string, status: string) =>
      db.doc(`memberships/${carpoolId}_${uid}`).set({ carpoolId, uid, status, role: "member" });
    await member("k1", "alice", "approved");
    await member("k1", "bob", "approved");
    await member("k1", "cara", "requested");
    await member("k2", "dan", "approved");
    for (const uid of ["alice", "bob", "cara"]) {
      await db.doc(`carpools/k1/pickupPoints/${uid}`).set({ location: EXACT, note: "Gate 2" });
    }
    await db.doc("carpools/k2/pickupPoints/dan").set({ location: EXACT });
    // A forged membership whose fields do not match its ID.
    await db.doc("memberships/k1_dan").set({ carpoolId: "k2", uid: "dan", status: "approved" });
    await db.doc("newParentEvents/alice").set({ uid: "alice", point: ROUNDED, status: "pending" });
    await db.doc("mapLimits/alice").set({ homeMoves: { windowStartMs: 0, count: 1 } });
    await db.doc("placeCache/ar_fake-maadi").set({ placeId: "fake-maadi", location: ROUNDED });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("homes: the exact home is the owner's only", () => {
  it("the owner reads their own home", async () => {
    await assertSucceeds(as("alice").firestore().doc("homes/alice").get());
    await assertSucceeds(as("alice", token).firestore().doc("homes/alice").get());
  });

  it("no other parent reads it: not verified parents, not members of the same carpool, not admins", async () => {
    await assertFails(as("bob").firestore().doc("homes/alice").get());
    await assertFails(as("bob", token).firestore().doc("homes/alice").get());
    await assertFails(as("admin1", { ...verified, admin: true }).firestore().doc("homes/alice").get());
    await assertFails(signedOut().firestore().doc("homes/alice").get());
  });

  it("homes cannot be listed or queried, even for one's own uid", async () => {
    await assertFails(as("alice").firestore().collection("homes").limit(1).get());
    await assertFails(as("alice").firestore().collection("homes").where("showOnMap", "==", true).get());
  });

  it("the app never writes a home (only Cloud Functions do)", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc("homes/alice").set({ location: EXACT }));
    await assertFails(db.doc("homes/alice").update({ showOnMap: false }));
    await assertFails(db.doc("homes/alice").delete());
    await assertFails(as("zed").firestore().doc("homes/zed").set({ location: EXACT }));
  });
});

describe("parentLocations: rounded points, Cloud Functions only", () => {
  it("nobody reads or lists them from the app, the owner included", async () => {
    for (const ctx of [as("alice"), as("bob"), as("alice", token), signedOut()]) {
      const db = ctx.firestore();
      await assertFails(db.doc("parentLocations/alice").get());
      await assertFails(db.collection("parentLocations").where("schoolIds", "array-contains", "nile").limit(10).get());
      await assertFails(
        db.collection("parentLocations")
          .where("schoolIds", "array-contains", "nile")
          .where("showOnMap", "==", true)
          .where("verified", "==", true)
          .orderBy("geohash")
          .startAt("stq4")
          .endAt("stq4~")
          .get(),
      );
    }
  });

  it("nobody writes them from the app", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc("parentLocations/alice").set({ point: ROUNDED }));
    await assertFails(db.doc("parentLocations/alice").update({ showOnMap: false }));
  });

  it("events, limits and the address cache are closed", async () => {
    const db = as("alice").firestore();
    for (const path of ["newParentEvents/alice", "mapLimits/alice", "placeCache/ar_fake-maadi"]) {
      await assertFails(db.doc(path).get());
      await assertFails(db.doc(path).set({ x: 1 }));
    }
    await assertFails(db.doc("mapLimits/alice").update({ homeMoves: { windowStartMs: 0, count: 0 } }));
  });
});

describe("pickup points: approved members of the same carpool only", () => {
  it("the owner reads their own pickup point", async () => {
    await assertSucceeds(as("cara").firestore().doc("carpools/k1/pickupPoints/cara").get());
  });

  it("an approved member reads another approved member's point in the same carpool", async () => {
    await assertSucceeds(as("alice").firestore().doc("carpools/k1/pickupPoints/bob").get());
    await assertSucceeds(as("bob").firestore().doc("carpools/k1/pickupPoints/alice").get());
  });

  it("a requested (not approved) member reads nothing, and nobody reads a requested member's point", async () => {
    await assertFails(as("cara").firestore().doc("carpools/k1/pickupPoints/alice").get());
    await assertFails(as("alice").firestore().doc("carpools/k1/pickupPoints/cara").get());
  });

  it("an approved member of another carpool reads nothing, even with a forged membership", async () => {
    await assertFails(as("dan").firestore().doc("carpools/k1/pickupPoints/alice").get());
    await assertFails(as("alice").firestore().doc("carpools/k2/pickupPoints/dan").get());
  });

  it("an approved member without the verified claim, or signed out, reads nothing", async () => {
    await assertFails(as("bob", token).firestore().doc("carpools/k1/pickupPoints/alice").get());
    await assertFails(signedOut().firestore().doc("carpools/k1/pickupPoints/alice").get());
  });

  it("a member who left loses access at once", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("memberships/k1_bob").update({ status: "left" });
    });
    await assertFails(as("bob").firestore().doc("carpools/k1/pickupPoints/alice").get());
    await assertFails(as("alice").firestore().doc("carpools/k1/pickupPoints/bob").get());
  });

  it("pickup points cannot be listed and are never written by the app", async () => {
    const db = as("alice").firestore();
    await assertFails(db.collection("carpools/k1/pickupPoints").get());
    await assertFails(db.doc("carpools/k1/pickupPoints/alice").set({ location: EXACT }));
    await assertFails(db.doc("carpools/k1/pickupPoints/alice").delete());
  });

  it("memberships and carpools stay closed to the app until Prompt 6", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc("memberships/k1_alice").get());
    await assertFails(db.doc("memberships/k1_alice").set({ carpoolId: "k1", uid: "alice", status: "approved" }));
    await assertFails(db.doc("memberships/k3_alice").set({ carpoolId: "k3", uid: "alice", status: "approved" }));
    await assertFails(db.doc("carpools/k1").get());
  });
});
