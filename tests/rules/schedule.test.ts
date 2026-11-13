// Rules for Prompt 7 (F7, F11, F27, F28, F30, F37): the schedule.
//
// What these tests prove:
// - carpools/{id}/schedule, swaps, exceptions and balances are read by
//   verified approved members of that carpool only: not requested,
//   declined or left members, members of other carpools, forged
//   memberships, parents without the verified claim or signed-out users.
// - Nobody writes them from the app, not even the carpool admin: drivers,
//   confirmations, swaps, absences and exceptions go through Cloud
//   Functions (CLAUDE.md: the app never writes schedule ownership).
// - scheduleEvents (alerts for Prompt 8) are closed to everyone.
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

const RUN = "carpools/k1/schedule/2026-11-15_am";
const SWAP = "carpools/k1/swaps/s1";
const EXCEPTION = "carpools/k1/exceptions/x1";
const BALANCE = "carpools/k1/balances/2026-t1";
const DOCS = [RUN, SWAP, EXCEPTION, BALANCE];
const COLLECTIONS = ["carpools/k1/schedule", "carpools/k1/swaps", "carpools/k1/exceptions", "carpools/k1/balances"];

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-schedule",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // k1: alice admin, bob approved, cara requested, dan declined, erin left. k2: fay admin.
    await db.doc("carpools/k1").set({ kind: "school", schoolId: "nile", seats: 4, status: "active" });
    await db.doc("carpools/k2").set({ kind: "school", schoolId: "nile", seats: 3, status: "active" });
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
    // Fake data only.
    await db.doc(RUN).set({
      carpoolId: "k1",
      date: "2026-11-15",
      direction: "toSchool",
      time: "07:30",
      status: "planned",
      driverUid: "alice",
      riders: [{ id: "b1", firstName: "Kid", parentUid: "bob" }],
      absent: [],
    });
    await db.doc(SWAP).set({ carpoolId: "k1", runId: "2026-11-15_am", requesterUid: "alice", status: "open" });
    await db.doc(EXCEPTION).set({ kind: "noSchool", reason: "holiday", from: "2026-11-19", to: "2026-11-19" });
    await db.doc(BALANCE).set({ termId: "2026-t1", families: { alice: { firstName: "Alice", driven: 2, received: 1 } } });
    await db.doc("scheduleEvents/e1").set({ type: "no-driver", carpoolId: "k1", recipients: ["alice", "bob"] });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("schedule: approved members of the carpool read", () => {
  it("the admin and an approved member read runs, swaps, exceptions and the balance", async () => {
    for (const uid of ["alice", "bob"]) {
      for (const path of DOCS) await assertSucceeds(as(uid).firestore().doc(path).get());
      for (const path of COLLECTIONS) await assertSucceeds(as(uid).firestore().collection(path).get());
    }
    // The app's week query.
    await assertSucceeds(
      as("bob").firestore().collection("carpools/k1/schedule").where("date", ">=", "2026-11-14").where("date", "<=", "2026-11-20").get(),
    );
  });

  it("requested, declined and left members, other carpools and forged memberships read nothing", async () => {
    for (const uid of ["cara", "dan", "erin", "fay", "zed"]) {
      for (const path of DOCS) await assertFails(as(uid).firestore().doc(path).get());
      for (const path of COLLECTIONS) await assertFails(as(uid).firestore().collection(path).get());
    }
  });

  it("an approved member without the verified claim, signed-out users and admins without membership read nothing", async () => {
    for (const path of DOCS) {
      await assertFails(as("bob", token).firestore().doc(path).get());
      await assertFails(signedOut().firestore().doc(path).get());
      await assertFails(as("admin1", adminClaim).firestore().doc(path).get());
    }
  });

  it("leaving removes access at once", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("memberships/k1_bob").update({ status: "left" });
    });
    for (const path of DOCS) await assertFails(as("bob").firestore().doc(path).get());
  });

  it("nobody queries runs across carpools", async () => {
    await assertFails(as("alice").firestore().collectionGroup("schedule").where("driverUid", "==", "alice").get());
  });
});

describe("schedule: only Cloud Functions write", () => {
  it("drivers cannot confirm, swap, take or mark absent by writing", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(RUN).update({ status: "confirmed" }));
    await assertFails(as("bob").firestore().doc(RUN).update({ driverUid: "bob", status: "confirmed" }));
    await assertFails(as("bob").firestore().doc(RUN).update({ riders: [], absent: [{ id: "b1", firstName: "Kid", parentUid: "bob" }] }));
    await assertFails(db.doc("carpools/k1/schedule/2026-11-16_am").set({ carpoolId: "k1", driverUid: "alice", status: "confirmed" }));
    await assertFails(db.doc(RUN).delete());
  });

  it("swaps, exceptions and balances are never written by the app, not even by the admin", async () => {
    const admin = as("alice").firestore();
    await assertFails(admin.doc(SWAP).update({ status: "accepted", acceptedBy: "bob" }));
    await assertFails(as("bob").firestore().doc("carpools/k1/swaps/s2").set({ runId: "2026-11-15_am", status: "open" }));
    await assertFails(admin.doc("carpools/k1/exceptions/x2").set({ kind: "noSchool", from: "2026-11-20", to: "2026-11-20" }));
    await assertFails(admin.doc(EXCEPTION).delete());
    await assertFails(admin.doc(BALANCE).update({ "families.alice.driven": 99 }));
    await assertFails(as("bob").firestore().doc(BALANCE).set({ families: {} }));
  });

  it("schedule events are closed to everyone", async () => {
    for (const ctx of [as("alice"), as("bob"), as("admin1", adminClaim), signedOut()]) {
      await assertFails(ctx.firestore().doc("scheduleEvents/e1").get());
      await assertFails(ctx.firestore().collection("scheduleEvents").where("recipients", "array-contains", "alice").get());
      await assertFails(ctx.firestore().doc("scheduleEvents/e2").set({ type: "no-driver" }));
    }
  });
});
