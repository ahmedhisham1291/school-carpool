// Rules for Prompt 4 (F14): the audit log is readable only by admins who
// signed in with two steps less than 8 hours ago, whose admin record exists,
// is not disabled and was not revoked after the token, and nobody (admins
// included) writes, edits or deletes it. The panel's other collections are
// closed to everyone. Runs only against the emulators. Written, not run
// here (no npm registry in the build workspace); CI runs it.
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

const nowSeconds = (): number => Math.floor(Date.now() / 1000);

/** Identities. Created inside each test, after before() made `env`. */
const withMfa = (extra: Record<string, unknown> = {}) => ({
  firebase: { sign_in_provider: "password" as const, sign_in_second_factor: "totp" },
  auth_time: nowSeconds() - 60,
  ...extra,
});
const asAdmin = (): RulesTestContext => env.authenticatedContext("admin1", withMfa({ admin: true }));
const asSuperAdmin = (): RulesTestContext => env.authenticatedContext("super1", withMfa({ admin: true, superAdmin: true }));
const asAdminNoMfa = (): RulesTestContext =>
  env.authenticatedContext("admin1", { admin: true, auth_time: nowSeconds() - 60, firebase: { sign_in_provider: "password" } });
const asAdminOldSession = (): RulesTestContext =>
  env.authenticatedContext("admin1", withMfa({ admin: true, auth_time: nowSeconds() - 9 * 60 * 60 }));
const asParent = (): RulesTestContext => env.authenticatedContext("alice", { verified: true });
const asParentWithMfa = (): RulesTestContext => env.authenticatedContext("alice", withMfa({ verified: true }));
const asSuperClaimOnly = (): RulesTestContext => env.authenticatedContext("x", withMfa({ superAdmin: true }));
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-admin",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc("auditLog/l1").set({ actorUid: "admin1", action: "verification.view", target: "verifications/c1", time: new Date() });
    await db.doc("auditLog/l2").set({ actorUid: "admin1", action: "user.suspend", target: "users/alice", time: new Date() });
    await db.doc("admins/admin1").set({ email: "rev@example.com", displayName: "Reviewer", role: "admin", disabled: false });
    await db.doc("admins/super1").set({ email: "super@example.com", displayName: "Super", role: "superAdmin", disabled: false });
    await db.doc("adminLimits/admin1").set({ windowStartMs: 1, count: 1 });
    await db.doc("moderations/m1").set({ uid: "alice", action: "suspend", note: "internal" });
    await db.doc("reports/r1").set({ reporterId: "bob", targetType: "user", targetId: "alice", status: "open" });
    await db.doc("schools/s1").set({ nameAr: "مدرسة", nameEn: "School", status: "active" });
    await db.doc("areas/a1").set({ schoolId: "s1", nameAr: "حي", nameEn: "Area" });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("audit log", () => {
  it("an admin or super admin signed in with two steps reads entries and lists the log", async () => {
    for (const make of [asAdmin, asSuperAdmin]) {
      await assertSucceeds(make().firestore().doc("auditLog/l1").get());
      await assertSucceeds(make().firestore().collection("auditLog").orderBy("time", "desc").get());
    }
  });

  it("nobody writes, edits or deletes an entry, admins included", async () => {
    for (const make of [asAdmin, asSuperAdmin, asParent, signedOut]) {
      const db = make().firestore();
      await assertFails(db.collection("auditLog").add({ actorUid: "admin1", action: "fake" }));
      await assertFails(db.doc("auditLog/new").set({ actorUid: "admin1", action: "fake" }));
      await assertFails(db.doc("auditLog/l1").update({ action: "changed" }));
      await assertFails(db.doc("auditLog/l1").set({ action: "replaced" }));
      await assertFails(db.doc("auditLog/l1").delete());
    }
  });

  it("a disabled admin, a revoked token or a missing admin record loses access at once", async () => {
    const asNoRecord = env.authenticatedContext("ghost", withMfa({ admin: true }));
    await assertFails(asNoRecord.firestore().doc("auditLog/l1").get());

    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("admins/admin1").update({ revokedAt: new Date() });
    });
    // A token issued before revokedAt is refused; one issued after it works.
    const asOldToken = env.authenticatedContext("admin1", withMfa({ admin: true, iat: nowSeconds() - 120 }));
    await assertFails(asOldToken.firestore().doc("auditLog/l1").get());
    const asNewToken = env.authenticatedContext("admin1", withMfa({ admin: true, iat: nowSeconds() + 5 }));
    await assertSucceeds(asNewToken.firestore().doc("auditLog/l1").get());

    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("admins/admin1").update({ disabled: true });
    });
    await assertFails(asNewToken.firestore().doc("auditLog/l1").get());
  });

  it("parents, signed-out visitors and incomplete admin sessions cannot read it", async () => {
    for (const make of [asParent, asParentWithMfa, asSuperClaimOnly, asAdminNoMfa, asAdminOldSession, signedOut]) {
      await assertFails(make().firestore().doc("auditLog/l1").get());
      await assertFails(make().firestore().collection("auditLog").get());
    }
  });
});

describe("admin panel collections are closed (functions only)", () => {
  const paths = ["admins/admin1", "adminLimits/admin1", "moderations/m1", "reports/r1", "schools/s1", "areas/a1"];
  for (const path of paths) {
    it(`nobody reads or writes ${path}, admins with two steps included`, async () => {
      for (const make of [asAdmin, asSuperAdmin, asParent, signedOut]) {
        const doc = make().firestore().doc(path);
        await assertFails(doc.get());
        await assertFails(doc.set({ status: "active", role: "superAdmin" }));
        await assertFails(doc.update({ status: "active" }));
        await assertFails(doc.delete());
      }
    });
  }

  it("a parent cannot make themselves an admin through their user record", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("users/alice").set({ parentId: "ABCD2345", status: "verified", role: "parent", language: "ar" });
    });
    const doc = asParent().firestore().doc("users/alice");
    await assertFails(doc.update({ role: "admin" }));
    await assertFails(doc.update({ admin: true }));
  });

  it("an admin cannot read parents' records, cases or images directly", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("users/alice").set({ parentId: "ABCD2345", status: "verified", language: "ar" });
      await ctx.firestore().doc("verifications/c1").set({ uid: "alice", status: "awaiting_review" });
    });
    await assertFails(asAdmin().firestore().doc("users/alice").get());
    await assertFails(asAdmin().firestore().collection("users").get());
    await assertFails(asAdmin().firestore().doc("verifications/c1").get());
  });
});
