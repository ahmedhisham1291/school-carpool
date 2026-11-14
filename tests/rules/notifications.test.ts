// Rules for Prompt 8 (F12, F23): notifications.
//
// What these tests prove:
// - users/{uid}/notifications are read only by that parent (get, and a
//   list of at most 100), never by another parent, an admin or a signed-out
//   user.
// - The app can only mark its own notification read: readAt, once, set to
//   the server time. It cannot create, delete, change the type, route,
//   alarm or delivery fields, mark another parent's, or un-read one.
// - notificationSettings/{uid} is read by its owner only; nobody writes it
//   from the app (updateNotificationSettings does).
// - The outbox (notificationEvents), push tokens and limits are closed to
//   everyone. The old Prompt 5 and 7 event collections stay closed.
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
const adminClaim: TokenOptions = { ...token, verified: true as const, admin: true as const };
const as = (uid: string, claims: TokenOptions = verified): RulesTestContext => env.authenticatedContext(uid, claims);
const signedOut = (): RulesTestContext => env.unauthenticatedContext();
const now = () => firebase.firestore.FieldValue.serverTimestamp();

const MINE = "users/alice/notifications/n1";
const READ_ALREADY = "users/alice/notifications/n2";
const BOBS = "users/bob/notifications/n1";

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-notifications",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const record = (extra: Record<string, unknown> = {}) => ({
      type: "no-driver",
      critical: true,
      carpoolId: "k1",
      runId: "2026-11-16_am",
      date: "2026-11-16",
      direction: "toSchool",
      route: "/carpools/k1/schedule",
      createdAt: firebase.firestore.Timestamp.fromMillis(Date.UTC(2026, 10, 15, 8)),
      readAt: null,
      alarmAt: firebase.firestore.Timestamp.fromMillis(Date.UTC(2026, 10, 15, 8, 15)),
      alarmState: "waiting",
      push: { state: "sent", attempts: 1, reason: null },
      whatsapp: null,
      alarm: null,
      ...extra,
    });
    await db.doc("users/alice").set({ status: "verified", language: "ar" });
    await db.doc(MINE).set(record());
    await db.doc(READ_ALREADY).set(record({ readAt: firebase.firestore.Timestamp.fromMillis(Date.UTC(2026, 10, 15, 9)) }));
    await db.doc(BOBS).set(record());
    await db.doc("notificationSettings/alice").set({ whatsapp: { noDriver: true }, quiet: { on: true, from: "22:00", to: "06:00" } });
    await db.doc("notificationSettings/bob").set({ whatsapp: { noDriver: true } });
    await db.doc("notificationEvents/e1").set({ type: "no-driver", recipients: ["alice"], status: "pending" });
    await db.doc("pushTokens/abc").set({ uid: "alice", token: "fake-token", platform: "ios" });
    await db.doc("notificationLimits/alice").set({ devices: { windowStartMs: 0, count: 1 } });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("notifications: only the recipient reads", () => {
  it("alice reads her own, one by one and as the app's list (newest first, 50)", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(MINE).get());
    await assertSucceeds(db.collection("users/alice/notifications").orderBy("createdAt", "desc").limit(50).get());
  });

  it("a list without a limit, or over 100, is refused", async () => {
    const db = as("alice").firestore();
    await assertFails(db.collection("users/alice/notifications").get());
    await assertFails(db.collection("users/alice/notifications").limit(101).get());
  });

  it("works before verification too (the verification result)", async () => {
    await assertSucceeds(as("alice", token).firestore().doc(MINE).get());
  });

  it("another parent, an admin and signed-out users read nothing", async () => {
    for (const ctx of [as("bob"), as("admin1", adminClaim), signedOut()]) {
      await assertFails(ctx.firestore().doc(MINE).get());
      await assertFails(ctx.firestore().collection("users/alice/notifications").limit(10).get());
    }
    await assertFails(as("alice").firestore().doc(BOBS).get());
    await assertFails(as("alice").firestore().collectionGroup("notifications").limit(10).get());
  });
});

describe("notifications: the app may only mark its own read", () => {
  it("alice sets readAt to the server time, once", async () => {
    const db = as("alice").firestore();
    await assertSucceeds(db.doc(MINE).update({ readAt: now() }));
    await assertFails(db.doc(MINE).update({ readAt: now() }));
    await assertFails(db.doc(READ_ALREADY).update({ readAt: null }));
  });

  it("mark all read: a batch of updates to her unread ones", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.firestore().doc("users/alice/notifications/n3").set({ type: "plan-ready", readAt: null, route: "/notifications" });
    });
    const db = as("alice").firestore();
    const batch = db.batch();
    batch.update(db.doc(MINE), { readAt: now() });
    batch.update(db.doc("users/alice/notifications/n3"), { readAt: now() });
    await assertSucceeds(batch.commit());
  });

  it("a client time, other fields or extra fields are refused", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc(MINE).update({ readAt: firebase.firestore.Timestamp.fromMillis(0) }));
    await assertFails(db.doc(MINE).update({ readAt: now(), alarmState: "cancelled" }));
    await assertFails(db.doc(MINE).update({ route: "/admin" }));
    await assertFails(db.doc(MINE).update({ type: "plan-ready" }));
    await assertFails(db.doc(MINE).update({ push: null }));
  });

  it("nobody creates, deletes or marks another parent's", async () => {
    const db = as("alice").firestore();
    await assertFails(db.doc("users/alice/notifications/new").set({ type: "no-driver", readAt: null }));
    await assertFails(db.doc(MINE).delete());
    await assertFails(db.doc(BOBS).update({ readAt: now() }));
    await assertFails(as("admin1", adminClaim).firestore().doc(MINE).update({ readAt: now() }));
    await assertFails(signedOut().firestore().doc(MINE).update({ readAt: now() }));
  });
});

describe("notification settings", () => {
  it("the owner reads hers; nobody else; nobody writes from the app", async () => {
    await assertSucceeds(as("alice").firestore().doc("notificationSettings/alice").get());
    await assertFails(as("alice").firestore().doc("notificationSettings/bob").get());
    await assertFails(as("alice").firestore().collection("notificationSettings").limit(5).get());
    for (const ctx of [as("alice"), as("admin1", adminClaim), signedOut()]) {
      await assertFails(ctx.firestore().doc("notificationSettings/alice").set({ whatsapp: { swaps: true } }));
      await assertFails(ctx.firestore().doc("notificationSettings/alice").update({ "quiet.on": false }));
      await assertFails(ctx.firestore().doc("notificationSettings/alice").delete());
    }
  });

  it("a parent with no settings yet can read the missing document (the app shows the defaults)", async () => {
    await assertSucceeds(as("carl").firestore().doc("notificationSettings/carl").get());
  });
});

describe("outbox, tokens and limits are closed", () => {
  it("to the recipient, admins and signed-out users", async () => {
    for (const ctx of [as("alice"), as("admin1", adminClaim), signedOut()]) {
      for (const path of ["notificationEvents/e1", "pushTokens/abc", "notificationLimits/alice", "scheduleEvents/e1", "newParentEvents/alice"]) {
        await assertFails(ctx.firestore().doc(path).get());
        await assertFails(ctx.firestore().doc(path).set({ status: "pending" }));
        await assertFails(ctx.firestore().doc(path).delete());
      }
      await assertFails(ctx.firestore().collection("notificationEvents").where("recipients", "array-contains", "alice").get());
      await assertFails(ctx.firestore().collection("pushTokens").where("uid", "==", "alice").get());
    }
  });
});
