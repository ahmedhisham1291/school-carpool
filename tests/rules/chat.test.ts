// Rules for Prompt 9 (F8, F9, F10, F13): chat records in Firestore.
//
// What these tests prove:
// - chatRequests: a verified parent reads a request only when they sent it
//   or got it (get, and a list of at most 50 queried by their own uid);
//   another parent, an unverified or signed-out user cannot; nobody writes.
// - chatBlocks: only the blocker reads their blocks; the blocked parent
//   cannot learn they were blocked; nobody writes from the app.
// - chatMutes and chatSettings: the owner reads; nobody writes.
// - chatChannels, chatMemberships, chatLimits, users/{uid}/chatPushes and
//   reports are closed to everyone (Cloud Functions only), admins included.
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
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const verified: TokenOptions = { ...token, verified: true as const };
const unverified: TokenOptions = { ...token };
const adminClaim: TokenOptions = { ...token, verified: true as const, admin: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const signedOut = (): RulesTestContext => env.unauthenticatedContext();
const at = (ms: number) => firebase.firestore.Timestamp.fromMillis(ms);
const T = Date.UTC(2026, 10, 16, 8);

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-chat",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const request = (fromUid: string, toUid: string, status = "pending") => ({
      fromUid,
      toUid,
      fromFirstName: "From",
      toFirstName: "To",
      status,
      cid: null,
      createdAt: at(T),
      updatedAt: at(T),
      expiresAt: at(T + 30 * 86_400_000),
    });
    await db.doc("chatRequests/alice_bob").set(request("alice", "bob"));
    await db.doc("chatRequests/cara_dina").set(request("cara", "dina"));
    await db.doc("chatBlocks/alice_bob").set({ blockerUid: "alice", blockedUid: "bob", blockedFirstName: "Bob", createdAt: at(T) });
    await db.doc("chatMutes/alice_cp_carpool~c-k1").set({ uid: "alice", cid: "cp_carpool:c-k1", muted: true, updatedAt: at(T) });
    await db.doc("chatMutes/bob_cp_carpool~c-k1").set({ uid: "bob", cid: "cp_carpool:c-k1", muted: false, updatedAt: at(T) });
    await db.doc("chatSettings/alice").set({ requestsOff: true, updatedAt: at(T) });
    await db.doc("chatChannels/cp_carpool:c-k1").set({ kind: "carpool", members: ["alice", "bob"] });
    await db.doc("chatMemberships/alice").set({ groups: ["cp_school:s-s1"] });
    await db.doc("chatLimits/alice").set({ requests: { windowStartMs: T, count: 1 } });
    await db.doc("users/alice/chatPushes/chat_m1").set({ type: "chat-message", push: { state: "sent" } });
    await db.doc("reports/r1").set({ reporterId: "alice", targetType: "message", targetId: "m1", reason: "spam", status: "open", context: [] });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("chatRequests", () => {
  it("the sender and the receiver read it; others cannot", async () => {
    await assertSucceeds(as("alice").firestore().doc("chatRequests/alice_bob").get());
    await assertSucceeds(as("bob").firestore().doc("chatRequests/alice_bob").get());
    await assertFails(as("cara").firestore().doc("chatRequests/alice_bob").get());
    await assertFails(as("bob", unverified).firestore().doc("chatRequests/alice_bob").get());
    await assertFails(signedOut().firestore().doc("chatRequests/alice_bob").get());
    await assertFails(as("admin1", adminClaim).firestore().doc("chatRequests/alice_bob").get());
  });
  it("lists only by own uid, at most 50", async () => {
    const db = as("bob").firestore();
    await assertSucceeds(db.collection("chatRequests").where("toUid", "==", "bob").limit(50).get());
    await assertSucceeds(as("alice").firestore().collection("chatRequests").where("fromUid", "==", "alice").limit(20).get());
    await assertFails(db.collection("chatRequests").where("toUid", "==", "bob").limit(51).get());
    await assertFails(db.collection("chatRequests").limit(10).get());
    await assertFails(db.collection("chatRequests").where("toUid", "==", "dina").limit(10).get());
  });
  it("the app cannot create, accept, change or delete a request", async () => {
    const db = as("bob").firestore();
    await assertFails(db.doc("chatRequests/alice_bob").update({ status: "accepted" }));
    await assertFails(db.doc("chatRequests/alice_bob").delete());
    await assertFails(db.doc("chatRequests/bob_cara").set({ fromUid: "bob", toUid: "cara", status: "pending" }));
  });
});

describe("chatBlocks", () => {
  it("only the blocker reads it; the blocked parent cannot learn of it", async () => {
    await assertSucceeds(as("alice").firestore().doc("chatBlocks/alice_bob").get());
    await assertSucceeds(as("alice").firestore().collection("chatBlocks").where("blockerUid", "==", "alice").limit(200).get());
    await assertFails(as("bob").firestore().doc("chatBlocks/alice_bob").get());
    await assertFails(as("bob").firestore().collection("chatBlocks").where("blockedUid", "==", "bob").limit(10).get());
    await assertFails(as("alice").firestore().collection("chatBlocks").where("blockerUid", "==", "alice").limit(201).get());
  });
  it("nobody blocks or unblocks from the app (blockChatUser does)", async () => {
    await assertFails(as("alice").firestore().doc("chatBlocks/alice_bob").delete());
    await assertFails(as("alice").firestore().doc("chatBlocks/alice_cara").set({ blockerUid: "alice", blockedUid: "cara" }));
  });
});

describe("chatMutes and chatSettings", () => {
  it("the owner reads their mute choices and settings", async () => {
    await assertSucceeds(as("alice").firestore().doc("chatMutes/alice_cp_carpool~c-k1").get());
    await assertSucceeds(as("alice").firestore().collection("chatMutes").where("uid", "==", "alice").limit(500).get());
    await assertSucceeds(as("alice").firestore().doc("chatSettings/alice").get());
  });
  it("other parents and unverified users cannot; nobody writes", async () => {
    await assertFails(as("alice").firestore().doc("chatMutes/bob_cp_carpool~c-k1").get());
    await assertFails(as("alice").firestore().collection("chatMutes").where("cid", "==", "cp_carpool:c-k1").limit(10).get());
    await assertFails(as("bob").firestore().doc("chatSettings/alice").get());
    await assertFails(as("alice", unverified).firestore().doc("chatSettings/alice").get());
    await assertFails(as("alice").firestore().doc("chatSettings/alice").set({ requestsOff: false }));
    await assertFails(as("alice").firestore().doc("chatMutes/alice_cp_carpool~c-k1").update({ muted: false }));
  });
});

describe("Functions-only chat records", () => {
  const closed = ["chatChannels/cp_carpool:c-k1", "chatMemberships/alice", "chatLimits/alice", "users/alice/chatPushes/chat_m1", "reports/r1"];
  for (const path of closed) {
    it(`${path} is closed to its member, its owner and an admin`, async () => {
      for (const ctx of [as("alice"), as("bob"), as("admin1", adminClaim)]) {
        const d = ctx.firestore().doc(path);
        await assertFails(d.get());
        await assertFails(d.set({ members: ["alice"] }));
        await assertFails(d.delete());
      }
    });
  }
});
