// Proves that firestore.rules and storage.rules deny everything that no
// prompt has opened yet (Prompt 1). The paths opened in Prompt 2 (a parent's
// own users/{uid} record) are tested in users.test.ts.
// Runs only against the emulators: `npm run test:emulator` (see README.md).
// Written, not run here (no npm registry in the build workspace).
//
// Every later prompt that opens a path adds tests here first (SECURITY rule:
// every rules change comes with emulator tests).
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import {
  assertFails,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";

// The contexts return compat-API instances (firebase/compat), so the compat
// methods are used here; they talk to the same emulators and rules.

// Compiled to tests/rules/lib, so the repo root is three levels up.
const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-rules",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
    storage: { rules: readFileSync(join(root, "storage.rules"), "utf8") },
  });
  // Put real data in place so reads are denied by rules, not by absence.
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc("users/alice").set({ firstName: "Alice", status: "verified" });
    await ctx.firestore().doc("schools/s1").set({ nameEn: "Test school" });
    await ctx.storage().ref("verification/alice/id-front.jpg").putString("fake-image").then(() => undefined);
  });
});

after(async () => {
  await env?.cleanup();
});

// Collections the app will have (spec section 9). Denied for these identities.
const paths = [
  // users/alice is readable by alice since Prompt 2 (users.test.ts).
  "users/bob",
  // Active schools are readable since Prompt 4B (schools.test.ts); s1 has
  // no status, so it stays hidden.
  "schools/s1",
  // areas/{id} and carpools/{id} are readable since Prompt 6
  // (carpools.test.ts); their writes and the carpool subcollections are
  // tested there and below.
  "searchKeyLimits/alice",
  // children/{id} is readable by its owner since Prompt 3
  // (verification.test.ts); c1 does not exist, so every read is denied.
  "children/c1",
  "memberships/m1",
  "carpools/k1/members/bob",
  "carpools/k1/requests/bob",
  "carpools/k1/driverConsents/bob_alice",
  "carpoolInvites/ABCDEFGH23",
  "carpoolLimits/alice",
  "carpoolWanted/bob",
  // Prompt 5 (maps.test.ts): homes/alice is readable by alice only;
  // parentLocations and the rest stay closed to everyone.
  "homes/bob",
  "parentLocations/alice",
  "newParentEvents/alice",
  "mapLimits/alice",
  "placeCache/ar_x",
  "carpools/k1/pickupPoints/bob",
  // Prompt 7 (schedule.test.ts): approved members read these; nobody else.
  "carpools/k1/schedule/2026-11-15_am",
  "carpools/k1/swaps/s1",
  "carpools/k1/exceptions/x1",
  "carpools/k1/balances/2026-t1",
  "scheduleEvents/e1",
  "scheduleEntries/e1",
  "wallets/alice",
  "transfers/t1",
  "auditLog/l1",
  "anything/else",
];

// Identities to test. Contexts are created inside each test: `env` only
// exists after the async before() hook, which runs after the describe
// callbacks have registered the tests.
const users: Array<{ who: string; make: () => RulesTestContext }> = [
  { who: "signed out", make: () => env.unauthenticatedContext() },
  { who: "signed in", make: () => env.authenticatedContext("alice") },
  { who: "verified", make: () => env.authenticatedContext("alice", { verified: true }) },
  {
    who: "admin claim",
    make: () => env.authenticatedContext("admin1", { verified: true, admin: true }),
  },
];

describe("firestore.rules deny everything", () => {
  for (const { who, make } of users) {
    for (const path of paths) {
      it(`${who}: cannot read, create, update or delete ${path}`, async () => {
        const d = make().firestore().doc(path);
        await assertFails(d.get());
        await assertFails(d.set({ status: "verified", role: "admin" }));
        await assertFails(d.update({ status: "verified" }));
        await assertFails(d.delete());
      });
    }
    it(`${who}: cannot list a collection`, async () => {
      await assertFails(make().firestore().collection("users").get());
    });
  }
});

describe("storage.rules deny everything", () => {
  for (const { who, make } of users) {
    it(`${who}: cannot read, upload or delete files`, async () => {
      const storage = make().storage();
      await assertFails(storage.ref("verification/alice/id-front.jpg").getDownloadURL());
      await assertFails(storage.ref("verification/alice/id-front.jpg").getMetadata());
      await assertFails(storage.ref("verification/alice/selfie.jpg").putString("x").then(() => undefined));
      await assertFails(storage.ref("public/anything.txt").putString("x").then(() => undefined));
      await assertFails(storage.ref("verification/alice/id-front.jpg").delete());
    });
  }
});
