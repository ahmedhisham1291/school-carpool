// Rules for Prompt 11B (F43, F44): wallet records in Firestore.
//
// What these tests prove (MONEY rules):
// - The app cannot write a balance: wallets/{uid} cannot be created,
//   changed or deleted by its owner, another parent or an admin, and the
//   owner cannot read it either (the balance comes from the partner
//   through the getWallet function).
// - The app cannot write a transfer or its outcome: transfers/{id} and
//   transferResults/{id} cannot be created, changed (status, amount) or
//   deleted by the sender, the receiver or an admin; nobody reads them
//   directly (history comes from listWalletHistory).
// - Counters, the pending list, alerts, config/wallet (limits) and the
//   fake partner's test money are closed too.
// - Parent IDs cannot be read directly (lookups go through the
//   rate-limited lookupParentId function).
//
// Runs only against the emulators. Written, not run here (no npm registry
// in the build workspace); CI runs it.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
  type TokenOptions,
} from "@firebase/rules-unit-testing";
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const verified: TokenOptions = { ...token, verified: true as const };
const unverified: TokenOptions = { ...token };
const adminClaim: TokenOptions = { ...token, verified: true as const, admin: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const at = (ms: number) => firebase.firestore.Timestamp.fromMillis(ms);
const T = Date.UTC(2026, 10, 16, 8);
const TID = "t_0123456789abcdef0123456789abcdef01234567";

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-wallet",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc("wallets/alice").set({ uid: "alice", walletRef: "fw_1", status: "active", balanceCopy: 5000, balanceAt: at(T), openedAt: at(T), updatedAt: at(T) });
    await db.doc(`transfers/${TID}`).set({
      kind: "transfer",
      requestId: "req-0000000000000001",
      uid: "alice",
      fromUid: "alice",
      toUid: "bob",
      parties: ["alice", "bob"],
      fromFirstName: "Alice",
      toFirstName: "Bob",
      amount: 1000,
      currency: "EGP",
      note: "",
      carpoolId: null,
      day: "2026-11-16",
      status: "pending",
      createdAt: at(T),
    });
    await db.doc(`transferResults/${TID}`).set({ status: "done", reason: null, partnerRef: "fp_1", settledAt: at(T) });
    await db.doc(`walletPending/${TID}`).set({ uid: "alice", createdAt: at(T), resends: 0 });
    await db.doc("walletDaily/alice_2026-11-16").set({ uid: "alice", outAmount: 1000, outCount: 1, topUpAmount: 0 });
    await db.doc("walletLimits/alice").set({ lookups: { windowStartMs: T, count: 1 } });
    await db.doc("walletAlerts/a1").set({ kind: "report", uid: "alice", status: "open", createdAt: at(T) });
    await db.doc("config/wallet").set({ perTransferMax: 200000, perDayMax: 500000 });
    await db.doc("fakeWalletAccounts/fw_1").set({ customerRef: "alice", balance: 5000, frozen: false });
    await db.doc(`fakeWalletOps/${TID}`).set({ kind: "transfer", amount: 1000, status: "done" });
    await db.doc("parentIds/ABCD2345").set({ uid: "bob" });
  });
});

after(async () => {
  await env?.cleanup();
});

const identities: Array<{ who: string; make: () => RulesTestContext }> = [
  { who: "the owner / sender (verified)", make: () => as("alice") },
  { who: "the receiver (verified)", make: () => as("bob") },
  { who: "an unverified user", make: () => as("alice", unverified) },
  { who: "an admin", make: () => as("admin1", adminClaim) },
  { who: "signed out", make: () => env.unauthenticatedContext() },
];

describe("the app cannot write a balance", () => {
  for (const { who, make } of identities) {
    it(`${who}: cannot read, set, change or delete wallets/alice`, async () => {
      const d = make().firestore().doc("wallets/alice");
      await assertFails(d.get());
      await assertFails(d.update({ balanceCopy: 999999 }));
      await assertFails(d.update({ status: "active" }));
      await assertFails(d.set({ uid: "alice", balanceCopy: 999999, status: "active" }));
      await assertFails(d.delete());
      await assertFails(make().firestore().doc("wallets/carol").set({ uid: "carol", balanceCopy: 1, status: "active" }));
    });
  }
});

describe("the app cannot write a transfer", () => {
  for (const { who, make } of identities) {
    it(`${who}: cannot create, change, settle or delete a transfer`, async () => {
      const db = make().firestore();
      await assertFails(db.doc(`transfers/${TID}`).get());
      await assertFails(db.collection("transfers").where("parties", "array-contains", "alice").limit(10).get());
      await assertFails(db.doc(`transfers/${TID}`).update({ amount: 1 }));
      await assertFails(db.doc(`transfers/${TID}`).update({ status: "done" }));
      await assertFails(db.doc(`transfers/${TID}`).delete());
      await assertFails(
        db.doc("transfers/t_ffffffffffffffffffffffffffffffffffffffff").set({ kind: "transfer", fromUid: "bob", toUid: "alice", amount: 100000, status: "done" }),
      );
      await assertFails(db.doc(`transferResults/${TID}`).get());
      await assertFails(db.doc(`transferResults/${TID}`).update({ status: "failed" }));
      await assertFails(db.doc(`transferResults/${TID}`).delete());
      await assertFails(db.doc("transferResults/t_ffffffffffffffffffffffffffffffffffffffff").set({ status: "done" }));
    });
  }
});

describe("wallet server records are closed", () => {
  const closed = [
    `walletPending/${TID}`,
    "walletDaily/alice_2026-11-16",
    "walletLimits/alice",
    "walletAlerts/a1",
    "config/wallet",
    "fakeWalletAccounts/fw_1",
    `fakeWalletOps/${TID}`,
    "parentIds/ABCD2345",
  ];
  for (const path of closed) {
    for (const { who, make } of identities) {
      it(`${who}: ${path} is closed`, async () => {
        const d = make().firestore().doc(path);
        await assertFails(d.get());
        await assertFails(d.set({ balance: 999999, count: 0, outAmount: 0, perTransferMax: 99999999 }));
        await assertFails(d.update({ count: 0 }));
        await assertFails(d.delete());
      });
    }
  }
  it("nobody lists the fake partner's accounts, the alerts or the parent IDs", async () => {
    await assertFails(as("alice").firestore().collection("fakeWalletAccounts").limit(10).get());
    await assertFails(as("admin1", adminClaim).firestore().collection("walletAlerts").limit(10).get());
    await assertFails(as("alice").firestore().collection("parentIds").limit(10).get());
  });
});
