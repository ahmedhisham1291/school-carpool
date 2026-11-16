// Rules for the collections added in Prompt 2 (F1, F44): users, consents,
// parentIds, otpCodes and otpLimits. Runs only against the emulators
// (`npm run test:emulator`). Written, not run here (no npm registry in the
// build workspace); CI runs it.
//
// A separate project ID keeps this file's data apart from deny_all.test.ts
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

const alice = {
  parentId: "ABCD2345",
  status: "unverified",
  role: "parent",
  phone: "+201000000001",
  email: null,
  emailVerified: false,
  language: "ar",
  whatsappOptIn: false,
  termsAcceptedAt: null,
  termsVersion: null,
};

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-users",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc("users/alice").set(alice);
    await db.doc("users/bob").set({ ...alice, parentId: "WXYZ6789", phone: "+201000000002" });
    await db.doc("users/alice/consents/c1").set({ type: "terms", version: "2026-11-13", withdrawnAt: null });
    await db.doc("users/bob/consents/c1").set({ type: "terms", version: "2026-11-13", withdrawnAt: null });
    await db.doc("parentIds/ABCD2345").set({ uid: "alice" });
    await db.doc("otpCodes/p_abc").set({ codeHash: "x", expiresAtMs: 1, attempts: 0 });
    await db.doc("otpLimits/p_abc").set({ sends: 1 });
  });
});

after(async () => {
  await env?.cleanup();
});

// Contexts are made inside each test: `env` exists only after before().
const asAlice = (): RulesTestContext => env.authenticatedContext("alice");
const asAliceVerified = (): RulesTestContext => env.authenticatedContext("alice", { verified: true });
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

describe("users/{uid}", () => {
  it("the owner can read their own record", async () => {
    await assertSucceeds(asAlice().firestore().doc("users/alice").get());
  });

  it("nobody can read another parent's record", async () => {
    await assertFails(asAlice().firestore().doc("users/bob").get());
    await assertFails(asAliceVerified().firestore().doc("users/bob").get());
    await assertFails(signedOut().firestore().doc("users/alice").get());
  });

  it("nobody can list users", async () => {
    await assertFails(asAlice().firestore().collection("users").get());
    await assertFails(asAlice().firestore().collection("users").where("parentId", "==", "WXYZ6789").get());
  });

  it("the owner can change the app language only to ar or en", async () => {
    const doc = asAlice().firestore().doc("users/alice");
    await assertSucceeds(doc.update({ language: "en" }));
    await assertFails(doc.update({ language: "fr" }));
  });

  for (const [field, value] of Object.entries({
    status: "verified",
    parentId: "ZZZZZZZZ",
    role: "admin",
    emailVerified: true,
    email: "someone@example.com",
    phone: "+201099999999",
    termsAcceptedAt: new Date(),
    whatsappOptIn: true,
    // App Review demo accounts (functions/src/auth/review_access.ts): the
    // exemption date and the demo mark are written by the owner's script
    // only; a parent can neither give themselves the exemption nor remove
    // the mark that confines a demo account.
    reviewDemoUntilMs: Date.now() + 24 * 3600 * 1000,
    reviewDemo: false,
    sessionsValidAfter: 0,
    newDeviceCheck: null,
  })) {
    it(`the owner cannot change ${field}`, async () => {
      const doc = asAlice().firestore().doc("users/alice");
      await assertFails(doc.update({ [field]: value }));
      await assertFails(doc.update({ language: "en", [field]: value }));
      await assertFails(doc.set({ ...alice, [field]: value }));
    });
  }

  it("a demo account cannot remove its own demo mark or extend its exemption", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("users/alice").update({ reviewDemo: true, reviewDemoUntilMs: 1 });
    });
    const doc = asAliceVerified().firestore().doc("users/alice");
    // Writing the record without the mark, or without the date, removes it: refused.
    await assertFails(doc.set({ ...alice, reviewDemoUntilMs: 1 }));
    await assertFails(doc.set({ ...alice, reviewDemo: true }));
    await assertFails(doc.update({ reviewDemo: false }));
    await assertFails(doc.update({ reviewDemoUntilMs: Date.now() + 1000 }));
    await assertSucceeds(doc.update({ language: "en" }));
  });

  it("the review access settings (demo phones, code hashes, listed accounts) are closed to every parent", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("config/reviewAccess").set({ enabled: true, phoneKey: "p_x", codeHash: "x", expiresAtMs: 1, demoUids: ["alice"] });
    });
    for (const ctx of [asAlice(), asAliceVerified(), signedOut()]) {
      await assertFails(ctx.firestore().doc("config/reviewAccess").get());
      await assertFails(ctx.firestore().doc("config/reviewAccess").set({ enabled: true }));
      await assertFails(ctx.firestore().doc("config/reviewAccess").update({ demoUids: ["alice", "bob"] }));
    }
  });

  it("a verified-claim user still cannot change their own status", async () => {
    await assertFails(asAliceVerified().firestore().doc("users/alice").update({ status: "verified" }));
  });

  it("a parent cannot create or delete a user record", async () => {
    await assertFails(env.authenticatedContext("carol").firestore().doc("users/carol").set({ ...alice, parentId: "CCCC2222" }));
    await assertFails(asAlice().firestore().doc("users/alice").delete());
  });

  it("nobody can write another parent's record", async () => {
    await assertFails(asAlice().firestore().doc("users/bob").update({ language: "en" }));
    await assertFails(signedOut().firestore().doc("users/bob").update({ language: "en" }));
  });
});

describe("users/{uid}/consents", () => {
  it("the owner can read their consent records", async () => {
    await assertSucceeds(asAlice().firestore().doc("users/alice/consents/c1").get());
    await assertSucceeds(asAlice().firestore().collection("users/alice/consents").get());
  });

  it("nobody can read another parent's consents", async () => {
    await assertFails(asAlice().firestore().doc("users/bob/consents/c1").get());
    await assertFails(signedOut().firestore().collection("users/alice/consents").get());
  });

  it("the app cannot create, edit or delete consent records", async () => {
    const consents = asAlice().firestore().collection("users/alice/consents");
    await assertFails(consents.add({ type: "terms", version: "2026-11-13" }));
    await assertFails(consents.doc("c1").update({ withdrawnAt: new Date() }));
    await assertFails(consents.doc("c1").delete());
  });
});

describe("server-only collections", () => {
  const paths = ["parentIds/ABCD2345", "parentIds/NEWID234", "otpCodes/p_abc", "otpLimits/p_abc"];
  const identities: Array<{ who: string; make: () => RulesTestContext }> = [
    { who: "signed out", make: signedOut },
    { who: "owner (alice)", make: asAlice },
    { who: "admin claim", make: () => env.authenticatedContext("admin1", { verified: true, admin: true }) },
  ];
  for (const { who, make } of identities) {
    for (const path of paths) {
      it(`${who}: cannot read or write ${path}`, async () => {
        const doc = make().firestore().doc(path);
        await assertFails(doc.get());
        await assertFails(doc.set({ uid: "alice" }));
        await assertFails(doc.delete());
      });
    }
    it(`${who}: cannot list parent IDs or codes`, async () => {
      await assertFails(make().firestore().collection("parentIds").get());
      await assertFails(make().firestore().collection("otpCodes").get());
    });
  }
});
