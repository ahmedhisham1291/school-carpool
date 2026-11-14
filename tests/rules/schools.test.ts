// Rules for Prompt 4B (F4): the schools list. Signed-in users read active
// schools (lists at most 200 at a time) and only their own "Other" school
// while it awaits review; merged schools and other parents' pending
// schools stay hidden; nobody writes from the app (Cloud Functions only).
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
} from "@firebase/rules-unit-testing";

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const asAlice = (): RulesTestContext => env.authenticatedContext("alice", token);
const asBob = (): RulesTestContext => env.authenticatedContext("bob", { ...token, verified: true });
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-schools",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const base = { nameEn: "School", governorate: "cairo", city: "Maadi", source: "osm" };
    await db.doc("schools/active1").set({ ...base, nameAr: "مدرسة النيل", status: "active", addedBy: null });
    await db.doc("schools/active2").set({ ...base, nameAr: "مدرسة الأهرام", status: "active", governorate: "giza" });
    await db.doc("schools/merged1").set({ ...base, nameAr: "مدرسه النيل", status: "merged", mergedInto: "active1" });
    await db.doc("schools/aliceOther").set({ ...base, nameAr: "مدرسة الزهور", status: "awaiting_review", source: "parent", addedBy: "alice" });
    await db.doc("schools/bobOther").set({ ...base, nameAr: "مدرسة الياسمين", status: "awaiting_review", source: "parent", addedBy: "bob" });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("schools: reading", () => {
  it("a signed-in parent reads an active school and lists active schools", async () => {
    const db = asAlice().firestore();
    await assertSucceeds(db.doc("schools/active1").get());
    await assertSucceeds(db.collection("schools").where("status", "==", "active").limit(200).get());
    await assertSucceeds(
      db.collection("schools").where("status", "==", "active").where("governorate", "==", "giza").limit(50).get(),
    );
  });

  it("lists of active schools are capped at 200 per query", async () => {
    const db = asAlice().firestore();
    await assertFails(db.collection("schools").where("status", "==", "active").limit(201).get());
    await assertFails(db.collection("schools").where("status", "==", "active").get());
  });

  it("a parent sees their own school awaiting review, never another parent's", async () => {
    const alice = asAlice().firestore();
    await assertSucceeds(alice.doc("schools/aliceOther").get());
    await assertSucceeds(
      alice.collection("schools").where("addedBy", "==", "alice").where("status", "==", "awaiting_review").limit(20).get(),
    );
    await assertFails(alice.doc("schools/bobOther").get());
    await assertFails(
      alice.collection("schools").where("addedBy", "==", "bob").where("status", "==", "awaiting_review").limit(20).get(),
    );
    await assertFails(alice.collection("schools").where("status", "==", "awaiting_review").limit(20).get());
    await assertSucceeds(asBob().firestore().doc("schools/bobOther").get());
  });

  it("merged schools are hidden, and a query that could include them is refused", async () => {
    const db = asAlice().firestore();
    await assertFails(db.doc("schools/merged1").get());
    await assertFails(db.collection("schools").limit(50).get());
  });

  it("signed-out visitors read nothing", async () => {
    const db = signedOut().firestore();
    await assertFails(db.doc("schools/active1").get());
    await assertFails(db.collection("schools").where("status", "==", "active").limit(10).get());
  });
});

describe("schools: writing (Cloud Functions only)", () => {
  it("nobody creates, edits or deletes a school from the app, their own pending one included", async () => {
    for (const make of [asAlice, asBob, signedOut]) {
      const db = make().firestore();
      await assertFails(db.collection("schools").add({ nameAr: "مدرسة", nameEn: "School", status: "active" }));
      await assertFails(db.doc("schools/new").set({ nameAr: "مدرسة", status: "awaiting_review", addedBy: "alice" }));
      await assertFails(db.doc("schools/active1").update({ nameEn: "Changed" }));
      await assertFails(db.doc("schools/aliceOther").update({ status: "active" }));
      await assertFails(db.doc("schools/aliceOther").delete());
      await assertFails(db.doc("schools/active1").delete());
    }
  });

  it("areas are readable when signed in since Prompt 6 (carpool areas), never written by the app", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("areas/a1").set({ schoolId: "active1", nameAr: "حي", nameEn: "Area" });
    });
    await assertSucceeds(asAlice().firestore().doc("areas/a1").get());
    await assertFails(asAlice().firestore().doc("areas/a1").set({ schoolId: "active1" }));
    await assertFails(asAlice().firestore().doc("areas/a1").delete());
    await assertFails(signedOut().firestore().doc("areas/a1").get());
  });
});
