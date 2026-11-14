// Rules for Prompt 3 (F2, F3, F18): verification uploads in Storage, and
// children, vehicles, verification cases, national ID hashes, the ban list,
// config and the audit log in Firestore. Runs only against the emulators
// (`npm run test:emulator`). Written, not run here (no npm registry in the
// build workspace); CI runs it.
//
// A separate project ID keeps this file's data apart from the other files
// (node --test runs files in parallel).
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

const JPEG = { contentType: "image/jpeg" };
const bytes = (size: number): Uint8Array => new Uint8Array(size).fill(7);
const upload = (ctx: RulesTestContext, path: string, data: Uint8Array = bytes(1024), meta: { contentType?: string } = JPEG) =>
  ctx.storage().ref(path).put(data, meta).then(() => undefined);

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-verification",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc("users/alice").set({ parentId: "ABCD2345", status: "pending", language: "ar", firstName: "Alice" });
    await db.doc("children/k1").set({ ownerUid: "alice", firstName: "Omar", age: 8, grade: "g3", status: "pending", schoolIdChecked: false });
    await db.doc("children/k2").set({ ownerUid: "bob", firstName: "Laila", age: 6, grade: "g1", status: "approved", schoolIdChecked: true });
    await db.doc("vehicles/alice").set({ driverUid: "alice", plate: "123", status: "pending" });
    await db.doc("vehicles/bob").set({ driverUid: "bob", plate: "456", status: "approved" });
    await db.doc("verifications/case1").set({ uid: "alice", status: "awaiting_review", nationalIdHash: "h" });
    await db.doc("nationalIds/h").set({ uid: "alice" });
    await db.doc("bannedIds/b").set({ caseId: "x" });
    await db.doc("config/kyc").set({ fakeResult: "match" });
    await db.doc("auditLog/l1").set({ actorUid: "admin1", action: "verification.view" });
    const storage = ctx.storage();
    await storage.ref("verification/alice/pending/id_front.jpg").put(bytes(10), JPEG).then(() => undefined);
    await storage.ref("verification/alice/cases/case1/selfie.jpg").put(bytes(10), JPEG).then(() => undefined);
    await storage.ref("verification/bob/pending/selfie.jpg").put(bytes(10), JPEG).then(() => undefined);
  });
});

after(async () => {
  await env?.cleanup();
});

const asAlice = (): RulesTestContext => env.authenticatedContext("alice");
const asBob = (): RulesTestContext => env.authenticatedContext("bob", { verified: true });
const asAdmin = (): RulesTestContext => env.authenticatedContext("admin1", { verified: true, admin: true });
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

describe("storage: verification uploads", () => {
  const names = [
    "id_front.jpg",
    "id_back.jpg",
    "selfie.jpg",
    "selfie_turn.jpg",
    "license.jpg",
    "car_license.jpg",
    "school_id_c1.jpg",
    "school_id_c10.jpg",
  ];
  for (const name of names) {
    it(`the owner can upload ${name} to their own pending folder`, async () => {
      await assertSucceeds(upload(asAlice(), `verification/alice/pending/${name}`));
    });
  }

  it("the owner can replace a pending upload (retake)", async () => {
    await assertSucceeds(upload(asAlice(), "verification/alice/pending/id_front.jpg"));
  });

  it("nobody can upload to another parent's folder", async () => {
    await assertFails(upload(asBob(), "verification/alice/pending/id_front.jpg"));
    await assertFails(upload(asAdmin(), "verification/alice/pending/id_front.jpg"));
    await assertFails(upload(signedOut(), "verification/alice/pending/id_front.jpg"));
  });

  it("the owner cannot upload outside pending, or into a case folder", async () => {
    await assertFails(upload(asAlice(), "verification/alice/cases/case1/selfie.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/selfie.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/sub/selfie.jpg"));
    await assertFails(upload(asAlice(), "public/selfie.jpg"));
  });

  it("only known names, JPEG, not empty and under 3 MB", async () => {
    await assertFails(upload(asAlice(), "verification/alice/pending/passport.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/selfie.png"));
    await assertFails(upload(asAlice(), "verification/alice/pending/school_id_C1.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/school_id_.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/school_id_c11.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/school_id_c0.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/school_id_abc123.jpg"));
    await assertFails(upload(asAlice(), "verification/alice/pending/selfie.jpg", bytes(1024), { contentType: "image/png" }));
    await assertFails(upload(asAlice(), "verification/alice/pending/selfie.jpg", bytes(1024), {}));
    await assertFails(upload(asAlice(), "verification/alice/pending/selfie.jpg", bytes(0)));
    await assertFails(upload(asAlice(), "verification/alice/pending/selfie.jpg", bytes(3 * 1024 * 1024)));
    await assertSucceeds(upload(asAlice(), "verification/alice/pending/selfie.jpg", bytes(3 * 1024 * 1024 - 1)));
  });

  it("nobody can read, list or delete verification images, not even the owner or an admin", async () => {
    for (const make of [asAlice, asBob, asAdmin, signedOut]) {
      const storage = make().storage();
      for (const path of [
        "verification/alice/pending/id_front.jpg",
        "verification/alice/cases/case1/selfie.jpg",
        "verification/bob/pending/selfie.jpg",
      ]) {
        await assertFails(storage.ref(path).getDownloadURL());
        await assertFails(storage.ref(path).getMetadata());
        await assertFails(storage.ref(path).delete());
      }
      await assertFails(storage.ref("verification/alice/pending").listAll());
      await assertFails(storage.ref("verification/alice").listAll());
    }
  });
});

describe("firestore: children", () => {
  it("a parent reads their own children, by document or by owner query", async () => {
    const db = asAlice().firestore();
    await assertSucceeds(db.doc("children/k1").get());
    await assertSucceeds(db.collection("children").where("ownerUid", "==", "alice").get());
  });

  it("nobody reads another parent's children, or lists them all", async () => {
    await assertFails(asAlice().firestore().doc("children/k2").get());
    await assertFails(asAlice().firestore().collection("children").where("ownerUid", "==", "bob").get());
    await assertFails(asAlice().firestore().collection("children").get());
    await assertFails(signedOut().firestore().doc("children/k1").get());
    await assertFails(asAdmin().firestore().doc("children/k1").get());
  });

  it("a parent cannot create, change or delete a child (Cloud Functions do)", async () => {
    const db = asAlice().firestore();
    await assertFails(db.doc("children/k1").update({ status: "approved" }));
    await assertFails(db.doc("children/k1").update({ firstName: "Omar Ali" }));
    await assertFails(db.doc("children/k1").update({ schoolIdChecked: true }));
    await assertFails(db.doc("children/new").set({ ownerUid: "alice", firstName: "X", status: "approved" }));
    await assertFails(db.doc("children/k1").delete());
  });
});

describe("firestore: vehicles", () => {
  it("the owner reads their car; nobody else does; nobody writes", async () => {
    await assertSucceeds(asAlice().firestore().doc("vehicles/alice").get());
    await assertFails(asAlice().firestore().doc("vehicles/bob").get());
    await assertFails(asAlice().firestore().collection("vehicles").get());
    await assertFails(asAlice().firestore().doc("vehicles/alice").update({ status: "approved" }));
    await assertFails(asAlice().firestore().doc("vehicles/alice").set({ driverUid: "alice", status: "approved" }));
    await assertFails(asBob().firestore().doc("vehicles/bob").update({ seats: 9 }));
  });
});

describe("firestore: users verification fields", () => {
  for (const [field, value] of Object.entries({
    status: "verified",
    firstName: "Someone",
    lastName: "Else",
    idExpiry: "2099-01-01",
    verification: { status: "approved" },
    verifiedAt: new Date(),
    claimsUpdatedAt: new Date(),
  })) {
    it(`the owner cannot set ${field}`, async () => {
      await assertFails(asAlice().firestore().doc("users/alice").update({ [field]: value }));
    });
  }
});

describe("firestore: server-only collections", () => {
  // Prompt 13: config/reviewAccess (App Review sign-in) is server-only too.
  const paths = ["verifications/case1", "nationalIds/h", "bannedIds/b", "config/kyc", "config/reviewAccess", "auditLog/l1"];
  for (const path of paths) {
    it(`nobody reads or writes ${path} (an admin claim without two-step sign-in included)`, async () => {
      for (const make of [asAlice, asBob, asAdmin, signedOut]) {
        const doc = make().firestore().doc(path);
        await assertFails(doc.get());
        await assertFails(doc.set({ status: "approved" }));
        await assertFails(doc.update({ status: "approved" }));
        await assertFails(doc.delete());
      }
    });
  }

  it("nobody lists the verification queue directly", async () => {
    await assertFails(asAdmin().firestore().collection("verifications").where("status", "==", "awaiting_review").get());
    await assertFails(asAlice().firestore().collection("verifications").where("uid", "==", "alice").get());
  });
});
