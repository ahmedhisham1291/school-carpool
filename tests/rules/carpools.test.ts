// Rules for Prompt 6 (F5, F6, F26, F31, F32): carpools.
//
// What these tests prove:
// - carpools/{id} (public summary) is readable by ID by verified parents
//   only; nobody lists or queries it, and the app writes nothing.
// - memberships: a parent reads only their own; never written by the app.
// - members and driverConsents: approved members of that carpool only
//   (not requested, declined, left, other carpools or forged memberships).
// - requests: the requester and the carpool admin only.
// - pickupPoints: approved members only (also in maps.test.ts).
// - carpoolInvites, carpoolLimits: closed; carpoolWanted: owner only.
// - areas: readable by signed-in parents, never written.
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

// Fake points and names only.
const EXACT = { latitude: 29.96123, longitude: 31.25671 };

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-carpools",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // k1: alice admin, bob approved, cara requested, dan declined, erin left.
    // k2: fay admin.
    await db.doc("carpools/k1").set({ kind: "school", schoolId: "nile", seats: 4, status: "active", creatorFirstName: "Alice" });
    await db.doc("carpools/k2").set({ kind: "school", schoolId: "nile", seats: 3, status: "active", creatorFirstName: "Fay" });
    const member = (carpoolId: string, uid: string, status: string, role = "member") =>
      db.doc(`memberships/${carpoolId}_${uid}`).set({ carpoolId, uid, status, role });
    await member("k1", "alice", "approved", "admin");
    await member("k1", "bob", "approved");
    await member("k1", "cara", "requested");
    await member("k1", "dan", "declined");
    await member("k1", "erin", "left");
    await member("k2", "fay", "approved", "admin");
    // Forged: an approved k2 membership stored under a k1 ID.
    await db.doc("memberships/k1_fay").set({ carpoolId: "k2", uid: "fay", status: "approved", role: "admin" });
    for (const uid of ["alice", "bob"]) {
      await db.doc(`carpools/k1/members/${uid}`).set({ uid, firstName: uid, children: [{ id: `${uid}-c`, firstName: "Kid", grade: "g1" }] });
    }
    await db.doc("carpools/k1/requests/cara").set({ uid: "cara", firstName: "Cara", children: [{ id: "c1", firstName: "Celine", grade: "g5" }] });
    await db.doc("carpools/k1/driverConsents/alice_bob").set({ carpoolId: "k1", parentUid: "alice", driverUid: "bob", status: "accepted" });
    await db.doc("carpools/k1/pickupPoints/bob").set({ location: EXACT, label: "Road 9 (test)" });
    await db.doc("carpools/k2/members/fay").set({ uid: "fay", firstName: "Fay", children: [] });
    await db.doc("carpoolInvites/ABCDEFGH23").set({ carpoolId: "k1", createdBy: "alice" });
    await db.doc("carpoolLimits/alice").set({ searches: { windowStartMs: 0, count: 1 } });
    await db.doc("carpoolWanted/bob").set({ uid: "bob", schoolId: "nile", firstName: "Bob" });
    await db.doc("areas/degla").set({ schoolId: "nile", nameAr: "دجلة", nameEn: "Degla" });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("carpools: public summary by ID for verified parents", () => {
  it("a verified parent reads a carpool by ID, member or not", async () => {
    await assertSucceeds(as("zed").firestore().doc("carpools/k1").get());
    await assertSucceeds(as("alice").firestore().doc("carpools/k1").get());
  });

  it("unverified and signed-out visitors read nothing (F31: verified before seeing anything)", async () => {
    await assertFails(as("zed", token).firestore().doc("carpools/k1").get());
    await assertFails(signedOut().firestore().doc("carpools/k1").get());
  });

  it("nobody lists or queries carpools from the app", async () => {
    await assertFails(as("alice").firestore().collection("carpools").limit(5).get());
    await assertFails(as("alice").firestore().collection("carpools").where("schoolId", "==", "nile").get());
  });

  it("the app never writes a carpool, not even its admin", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc("carpools/k1").update({ seats: 8 }));
    await assertFails(db.doc("carpools/k3").set({ status: "active", creatorUid: "alice" }));
    await assertFails(db.doc("carpools/k1").delete());
  });
});

describe("memberships: own only, written by functions", () => {
  it("a parent reads and lists their own memberships", async () => {
    await assertSucceeds(as("cara").firestore().doc("memberships/k1_cara").get());
    await assertSucceeds(as("alice").firestore().collection("memberships").where("uid", "==", "alice").get());
    await assertSucceeds(as("cara", token).firestore().doc("memberships/k1_cara").get());
  });

  it("nobody reads another parent's membership or lists a carpool's", async () => {
    await assertFails(as("alice").firestore().doc("memberships/k1_bob").get());
    await assertFails(as("alice").firestore().collection("memberships").where("carpoolId", "==", "k1").get());
    await assertFails(signedOut().firestore().doc("memberships/k1_bob").get());
  });

  it("the app cannot request, approve or change a role", async () => {
    const db = as("cara").firestore();
    await assertFails(db.doc("memberships/k1_cara").update({ status: "approved" }));
    await assertFails(db.doc("memberships/k2_cara").set({ carpoolId: "k2", uid: "cara", status: "requested", role: "member" }));
    await assertFails(as("bob").firestore().doc("memberships/k1_bob").update({ role: "admin" }));
    await assertFails(as("alice").firestore().doc("memberships/k1_cara").update({ status: "approved" }));
    await assertFails(as("bob").firestore().doc("memberships/k1_bob").delete());
  });
});

describe("members: approved members of the same carpool only", () => {
  it("approved members read and list members (children's first names and grades)", async () => {
    await assertSucceeds(as("bob").firestore().collection("carpools/k1/members").get());
    await assertSucceeds(as("alice").firestore().doc("carpools/k1/members/bob").get());
  });

  it("requested, declined, left, other carpools and forged memberships read nothing", async () => {
    for (const uid of ["cara", "dan", "erin", "fay", "zed"]) {
      await assertFails(as(uid).firestore().collection("carpools/k1/members").get());
      await assertFails(as(uid).firestore().doc("carpools/k1/members/alice").get());
    }
  });

  it("an approved member without the verified claim reads nothing", async () => {
    await assertFails(as("bob", token).firestore().collection("carpools/k1/members").get());
  });

  it("losing approval removes access at once", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("memberships/k1_bob").update({ status: "left" });
    });
    await assertFails(as("bob").firestore().collection("carpools/k1/members").get());
  });

  it("the app never writes members", async () => {
    await assertFails(as("alice").firestore().doc("carpools/k1/members/cara").set({ uid: "cara" }));
    await assertFails(as("bob").firestore().doc("carpools/k1/members/bob").update({ role: "admin" }));
    await assertFails(as("alice").firestore().doc("carpools/k1/members/bob").delete());
  });
});

describe("requests: the requester and the admin only", () => {
  it("the admin lists and reads requests; the requester reads their own", async () => {
    await assertSucceeds(as("alice").firestore().collection("carpools/k1/requests").get());
    await assertSucceeds(as("alice").firestore().doc("carpools/k1/requests/cara").get());
    await assertSucceeds(as("cara").firestore().doc("carpools/k1/requests/cara").get());
  });

  it("other members, other carpools' admins and a forged admin read nothing", async () => {
    await assertFails(as("bob").firestore().collection("carpools/k1/requests").get());
    await assertFails(as("bob").firestore().doc("carpools/k1/requests/cara").get());
    await assertFails(as("fay").firestore().collection("carpools/k1/requests").get());
    await assertFails(as("dan").firestore().doc("carpools/k1/requests/cara").get());
    await assertFails(as("cara").firestore().collection("carpools/k1/requests").get());
  });

  it("the admin without the verified claim reads nothing; nobody writes requests", async () => {
    await assertFails(as("alice", token).firestore().collection("carpools/k1/requests").get());
    await assertFails(as("cara").firestore().doc("carpools/k1/requests/cara").set({ uid: "cara" }));
    await assertFails(as("alice").firestore().doc("carpools/k1/requests/cara").delete());
  });
});

describe("driver consents (F26): approved members read, functions write", () => {
  it("approved members read consents", async () => {
    await assertSucceeds(as("bob").firestore().collection("carpools/k1/driverConsents").get());
    await assertSucceeds(as("alice").firestore().doc("carpools/k1/driverConsents/alice_bob").get());
  });

  it("others read nothing", async () => {
    for (const uid of ["cara", "erin", "fay"]) {
      await assertFails(as(uid).firestore().collection("carpools/k1/driverConsents").get());
    }
  });

  it("nobody gives or withdraws consent by writing directly", async () => {
    const db = as("bob").firestore();
    await assertFails(db.doc("carpools/k1/driverConsents/bob_alice").set({ carpoolId: "k1", parentUid: "bob", driverUid: "alice", status: "accepted" }));
    await assertFails(as("alice").firestore().doc("carpools/k1/driverConsents/alice_bob").update({ status: "withdrawn" }));
    await assertFails(as("alice").firestore().doc("carpools/k1/driverConsents/alice_bob").delete());
  });
});

describe("pickup points: exact, approved members only", () => {
  it("approved members read a shared point; nobody else does", async () => {
    await assertSucceeds(as("alice").firestore().doc("carpools/k1/pickupPoints/bob").get());
    await assertSucceeds(as("bob").firestore().doc("carpools/k1/pickupPoints/bob").get());
    for (const uid of ["cara", "dan", "erin", "fay", "zed"]) {
      await assertFails(as(uid).firestore().doc("carpools/k1/pickupPoints/bob").get());
    }
    await assertFails(as("alice").firestore().collection("carpools/k1/pickupPoints").get());
    await assertFails(as("bob").firestore().doc("carpools/k1/pickupPoints/bob").set({ location: EXACT }));
  });
});

describe("invites, limits, looking-for posts and areas", () => {
  it("invites and limits are closed to everyone", async () => {
    for (const path of ["carpoolInvites/ABCDEFGH23", "carpoolLimits/alice"]) {
      await assertFails(as("alice").firestore().doc(path).get());
      await assertFails(as("alice").firestore().doc(path).set({ x: 1 }));
    }
    await assertFails(as("alice").firestore().collection("carpoolInvites").limit(1).get());
  });

  it("a looking-for post is read by its owner only and never written by the app", async () => {
    await assertSucceeds(as("bob").firestore().doc("carpoolWanted/bob").get());
    await assertFails(as("alice").firestore().doc("carpoolWanted/bob").get());
    await assertFails(as("alice").firestore().collection("carpoolWanted").where("schoolId", "==", "nile").get());
    await assertFails(as("bob").firestore().doc("carpoolWanted/bob").set({ schoolId: "nile" }));
  });

  it("signed-in parents read areas (at most 200 at a time); nobody writes them", async () => {
    await assertSucceeds(as("alice", token).firestore().doc("areas/degla").get());
    await assertSucceeds(as("alice").firestore().collection("areas").where("schoolId", "==", "nile").limit(200).get());
    await assertFails(as("alice").firestore().collection("areas").where("schoolId", "==", "nile").get());
    await assertFails(signedOut().firestore().doc("areas/degla").get());
    await assertFails(as("alice").firestore().doc("areas/degla").update({ nameEn: "X" }));
  });
});
