import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { describe, it } from "node:test";
import { liftDrivingPause, removeReportedMember, removeReportedMessage, resolveReport, getReport, type ChatAdminDeps } from "../src/chat/admin";
import {
  answerChatRequest,
  blockChatUser,
  cancelChatRequest,
  DEFAULT_CHAT_LIMITS,
  getChatToken,
  reportChat,
  sendChatRequest,
  setChatMute,
  syncMyChats,
  unblockChatUser,
  updateChatSettings,
  type Caller,
  type ChatDeps,
} from "../src/chat/flow";
import {
  channelRef,
  ChatError,
  cleanNote,
  groupChannelId,
  isMuted,
  LARGE_GROUP_SIZE,
  parseCid,
  privateChannelId,
  type ChannelRecord,
} from "../src/chat/model";
import { retentionDays, runChatRetention } from "../src/chat/retention";
import { createChatServer, FakeChatServer, signJwt, StreamChatServer, verifyWebhookSignature, type FetchLike } from "../src/chat/server";
import { accountFromDoc, chatRelevant, nearestArea, syncAccess, syncCarpoolMember, syncParentGroups } from "../src/chat/sync";
import { handleWebhook } from "../src/chat/webhook";
import { routeFor } from "../src/notifications/catalog";
import { buildPush, buildRecord, eventFromDoc } from "../src/notifications/model";
import { outboxDoc } from "../src/notifications/outbox";
import type { AuditEntry } from "../src/admin_panel/types";
import { FakePauser, MemoryChatStore } from "./helpers/memory_chat";

const T0 = Date.UTC(2026, 10, 16, 8);

function setup() {
  const store = new MemoryChatStore();
  const server = new FakeChatServer();
  const pauser = new FakePauser();
  const clock = { now: T0 };
  const logs: Array<{ message: string; data?: Record<string, unknown> }> = [];
  const deps: ChatDeps = {
    store,
    server,
    now: () => clock.now,
    log: (message, data) => logs.push({ message, data }),
    limits: { ...DEFAULT_CHAT_LIMITS },
    tokenTtlSec: 3600,
    pauser,
  };
  return { store, server, pauser, clock, deps, logs };
}

const me = (uid: string, verifiedClaim = true): Caller => ({ uid, verifiedClaim });

async function rejects(p: Promise<unknown>, reason: string) {
  await assert.rejects(p, (e: unknown) => e instanceof ChatError && e.reason === reason);
}

/** Two verified parents of the same school. */
function twoParents() {
  const s = setup();
  s.store.addParent("alice", { firstName: "Alia" });
  s.store.addParent("bob", { firstName: "Badr" });
  s.store.childSchools.set("alice", ["sch1"]);
  s.store.childSchools.set("bob", ["sch1"]);
  s.store.schools.set("sch1", { id: "sch1", nameAr: "مدرسة", nameEn: "School" });
  return s;
}

describe("channel IDs", () => {
  it("one private channel per pair, whoever asks, without the uids in it", () => {
    const a = privateChannelId("alice", "bob");
    assert.equal(a, privateChannelId("bob", "alice"));
    assert.match(a, /^dm-[0-9a-f]{40}$/);
    assert.ok(!a.includes("alice"));
  });
  it("group IDs and cids round trip; foreign types are refused", () => {
    const ref = channelRef("carpool", groupChannelId("carpool", "k1"));
    assert.equal(ref.cid, "cp_carpool:c-k1");
    assert.deepEqual(parseCid(ref.cid), ref);
    assert.equal(parseCid("messaging:general"), null);
    assert.equal(parseCid("cp_school:../x"), null);
    assert.throws(() => groupChannelId("school", "a/b"));
  });
  it("large school and area groups start muted; small chats do not; a choice wins", () => {
    assert.equal(isMuted("school", LARGE_GROUP_SIZE + 1, null), true);
    assert.equal(isMuted("school", LARGE_GROUP_SIZE, null), false);
    assert.equal(isMuted("carpool", 500, null), false);
    assert.equal(isMuted("school", 500, false), false);
    assert.equal(isMuted("private", 2, true), true);
  });
  it("report notes are one short line without control or bidi characters", () => {
    assert.equal(cleanNote(" a\nb‮ c "), "a b c");
    assert.throws(() => cleanNote("x".repeat(301)));
    assert.throws(() => cleanNote(5));
  });
});

describe("token issuance (only verified, non-suspended parents)", () => {
  it("a verified parent gets a short-lived token; Stream gets first name and parent ID only", async () => {
    const s = twoParents();
    const t = await getChatToken(s.deps, me("alice"));
    assert.equal(t.userId, "alice");
    assert.equal(t.expiresAtMs, T0 + 3600_000);
    assert.equal(t.provider, "fake");
    assert.deepEqual(s.server.users.get("alice"), { id: "alice", name: "Alia", parentId: s.store.accounts.get("alice")?.parentId, language: "ar" });
    assert.deepEqual(Object.keys(s.server.users.get("alice") ?? {}).sort(), ["id", "language", "name", "parentId"]);
  });
  it("an unverified account gets no chat token", async () => {
    const s = setup();
    s.store.addParent("u1", { status: "unverified" });
    await rejects(getChatToken(s.deps, me("u1", false)), "not-verified");
    await rejects(getChatToken(s.deps, me("u1", true)), "not-verified");
    s.store.addParent("u2", { status: "pending" });
    await rejects(getChatToken(s.deps, me("u2")), "not-verified");
    assert.equal(s.server.users.size, 0);
  });
  it("suspended and banned parents get none, even with an old verified claim", async () => {
    const s = setup();
    s.store.addParent("s1", { status: "suspended" });
    s.store.addParent("b1", { banned: true });
    await rejects(getChatToken(s.deps, me("s1")), "suspended");
    await rejects(getChatToken(s.deps, me("b1")), "suspended");
    await rejects(getChatToken(s.deps, me("nobody")), "not-verified");
  });
  it("is rate limited per hour", async () => {
    const s = twoParents();
    s.deps.limits.tokensPerHour = 2;
    await getChatToken(s.deps, me("alice"));
    await getChatToken(s.deps, me("alice"));
    await rejects(getChatToken(s.deps, me("alice")), "rate-limited");
  });
  it("Stream user tokens are HS256 JWTs with user_id, iat and exp", () => {
    const server = new StreamChatServer("key", "secret", (async () => ({ ok: true, status: 200, json: async () => ({}) })) as FetchLike);
    const token = server.createToken("alice", 100, 200);
    const [head, body, sig] = token.split(".");
    assert.deepEqual(JSON.parse(Buffer.from(head, "base64url").toString()), { alg: "HS256", typ: "JWT" });
    assert.deepEqual(JSON.parse(Buffer.from(body, "base64url").toString()), { user_id: "alice", iat: 100, exp: 200 });
    assert.equal(sig, createHmac("sha256", "secret").update(`${head}.${body}`).digest("base64url"));
  });
  it("the fake server is refused in prod; Stream needs key and secret", () => {
    assert.throws(() => createChatServer("fake", "prod", "", "", () => undefined));
    assert.throws(() => createChatServer("stream", "dev", "", "x", () => undefined));
    assert.throws(() => createChatServer("other", "dev", "k", "s", () => undefined));
    assert.equal(createChatServer("fake", "dev", "", "", () => undefined).kind, "fake");
  });
});

describe("Stream REST calls", () => {
  function recording() {
    const calls: Array<{ url: string; method: string; headers: Record<string, string>; body: unknown }> = [];
    const fetchFn: FetchLike = async (url, init) => {
      calls.push({ url, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : undefined });
      return { ok: true, status: 201, json: async () => ({ messages: [] }) };
    };
    return { calls, server: new StreamChatServer("KEY", "SECRET", fetchFn, "https://stream.test") };
  }
  it("server calls are signed with a server JWT and carry the api key; the secret is never sent", async () => {
    const { calls, server } = recording();
    await server.upsertUser({ id: "alice", name: "Alia", parentId: "ABCD2345", language: "ar" });
    const c = calls[0];
    assert.equal(c.url, "https://stream.test/users?api_key=KEY");
    assert.equal(c.headers["stream-auth-type"], "jwt");
    assert.equal(c.headers.Authorization, signJwt({ server: true }, "SECRET"));
    assert.ok(!JSON.stringify(c).includes("SECRET"));
    assert.deepEqual(c.body, { users: { alice: { id: "alice", name: "Alia", parent_id: "ABCD2345", language: "ar", role: "user" } } });
  });
  it("cut-off: revoke tokens and deactivate; channels created by the system user", async () => {
    const { calls, server } = recording();
    await server.revokeTokens("alice", T0);
    await server.deactivateUser("alice");
    await server.ensureChannel("cp_carpool", "c-k1", { nameAr: "أ", nameEn: "A", kind: "carpool", refId: "k1" }, ["alice"]);
    await server.addMembers("cp_carpool", "c-k1", ["bob"]);
    await server.setFrozen("cp_private", "dm-1", true);
    await server.truncateBefore("cp_school", "s-1", T0);
    assert.deepEqual(
      calls.map((c) => `${c.method} ${c.url.replace("https://stream.test", "").split("?")[0]}`),
      [
        "PATCH /users",
        "POST /users/alice/deactivate",
        "POST /channels/cp_carpool/c-k1/query",
        "POST /channels/cp_carpool/c-k1",
        "PATCH /channels/cp_private/dm-1",
        "POST /channels/cp_school/s-1/truncate",
      ],
    );
    assert.deepEqual(calls[0].body, { users: [{ id: "alice", set: { revoke_tokens_issued_before: new Date(T0).toISOString() } }] });
    assert.equal((calls[2].body as { data: { created_by_id: string } }).data.created_by_id, "carpool-system");
    assert.deepEqual((calls[5].body as Record<string, unknown>).hard_delete, true);
  });
  it("a failed call throws with the status (never the body)", async () => {
    const server = new StreamChatServer("K", "S", (async () => ({ ok: false, status: 500, json: async () => ({ code: 4, message: "secret text" }) })) as FetchLike);
    await assert.rejects(server.upsertUser({ id: "a", name: "A", parentId: "P", language: "en" }), (e: Error) => e.message.includes("500") && !e.message.includes("secret text"));
  });
});

describe("webhook verification", () => {
  const body = Buffer.from(JSON.stringify({ type: "message.new" }));
  const sign = (b: Buffer, secret: string) => createHmac("sha256", secret).update(b).digest("hex");
  it("accepts Stream's signature of the raw body", () => {
    assert.equal(verifyWebhookSignature(body, sign(body, "s3cret"), "s3cret"), true);
  });
  it("refuses a wrong, missing, malformed or other-secret signature, and an unset secret", () => {
    assert.equal(verifyWebhookSignature(body, sign(body, "other"), "s3cret"), false);
    assert.equal(verifyWebhookSignature(body, undefined, "s3cret"), false);
    assert.equal(verifyWebhookSignature(body, "zz", "s3cret"), false);
    assert.equal(verifyWebhookSignature(body, sign(body, ""), ""), false);
    const changed = Buffer.from(JSON.stringify({ type: "message.new", x: 1 }));
    assert.equal(verifyWebhookSignature(changed, sign(body, "s3cret"), "s3cret"), false);
  });
});

describe("channel membership sync", () => {
  function groupSetup() {
    const s = twoParents();
    s.store.points.set("alice", { lat: 30.05, lng: 31.25 });
    s.store.areas.push({ id: "ar1", schoolId: "sch1", nameAr: "حي", nameEn: "Near", center: { lat: 30.06, lng: 31.25 } });
    s.store.areas.push({ id: "ar2", schoolId: "sch1", nameAr: "بعيد", nameEn: "Far", center: { lat: 30.5, lng: 31.25 } });
    return s;
  }
  it("a verified parent joins their child's school group and the nearest area group", async () => {
    const s = groupSetup();
    const r = await syncParentGroups(s.deps, "alice");
    assert.equal(r.added, 2);
    assert.deepEqual(s.store.groups.get("alice"), ["cp_area:a-ar1", "cp_school:s-sch1"]);
    assert.deepEqual([...(s.server.channels.get("cp_school:s-sch1")?.members ?? [])], ["alice"]);
    assert.equal(s.server.channels.get("cp_school:s-sch1")?.data.nameEn, "School");
    // Bob has no home pin: school group only.
    await syncParentGroups(s.deps, "bob");
    assert.deepEqual(s.store.groups.get("bob"), ["cp_school:s-sch1"]);
    assert.deepEqual(s.store.channels.get("cp_school:s-sch1")?.members, ["alice", "bob"]);
  });
  it("is idempotent: a second run changes nothing on Stream", async () => {
    const s = groupSetup();
    await syncParentGroups(s.deps, "alice");
    const before = s.server.calls.length;
    const r = await syncParentGroups(s.deps, "alice");
    assert.deepEqual(r, { added: 0, removed: 0 });
    assert.equal(s.server.calls.length, before);
  });
  it("a child who left the school, or a parent no longer verified, leaves the groups", async () => {
    const s = groupSetup();
    await syncParentGroups(s.deps, "alice");
    s.store.childSchools.set("alice", []);
    const r = await syncParentGroups(s.deps, "alice");
    assert.equal(r.removed, 2);
    assert.deepEqual(s.store.channels.get("cp_school:s-sch1")?.members, []);
    assert.deepEqual(s.store.groups.get("alice"), []);
  });
  it("only areas within 6 km count, nearest first", () => {
    const areas = [
      { id: "x", schoolId: "s", nameAr: "", nameEn: "", center: { lat: 30.04, lng: 31.25 } },
      { id: "y", schoolId: "s", nameAr: "", nameEn: "", center: { lat: 30.0, lng: 31.25 } },
      { id: "z", schoolId: "s", nameAr: "", nameEn: "", center: null },
    ];
    assert.equal(nearestArea(areas, { lat: 30.05, lng: 31.25 })?.id, "x");
    assert.equal(nearestArea(areas, { lat: 31, lng: 31.25 }), null);
  });
  it("carpool chat follows approved members (Prompt 6 changes)", async () => {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "مدرسة · 07:30", nameEn: "School · 07:30", active: true });
    assert.equal(await syncCarpoolMember(s.deps, "k1", "alice", true), "added");
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", true), "added");
    assert.deepEqual([...(s.server.channels.get("cp_carpool:c-k1")?.members ?? [])].sort(), ["alice", "bob"]);
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", false), "removed");
    assert.deepEqual([...(s.server.channels.get("cp_carpool:c-k1")?.members ?? [])], ["alice"]);
    // Leaving a carpool with no chat creates nothing.
    assert.equal(await syncCarpoolMember(s.deps, "k2", "bob", false), "unchanged");
    assert.equal(s.server.channels.has("cp_carpool:c-k2"), false);
  });
  it("a suspended member is not added; a member an admin removed is never added back", async () => {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    s.store.addParent("sus", { status: "suspended" });
    assert.equal(await syncCarpoolMember(s.deps, "k1", "alice", true), "added");
    assert.equal(await syncCarpoolMember(s.deps, "k1", "sus", true), "unchanged");
    const c = s.store.channels.get("cp_carpool:c-k1") as ChannelRecord;
    s.store.channels.set(c.cid, { ...c, excluded: ["bob"] });
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", true), "excluded");
  });
  it("suspending, banning or deleting removes chat access at once", async () => {
    for (const after of [{ status: "suspended" }, { status: "verified", banned: true }, null]) {
      const s = twoParents();
      await syncParentGroups(s.deps, "alice");
      const before = accountFromDoc("alice", { status: "verified", firstName: "Alia", parentId: "P1" });
      const changed = after === null ? null : accountFromDoc("alice", { firstName: "Alia", parentId: "P1", ...after });
      // The trigger runs after the record changed.
      if (changed) s.store.accounts.set("alice", changed);
      else s.store.accounts.delete("alice");
      const r = await syncAccess(s.deps, "alice", { before, after: changed });
      assert.equal(r, "cut-off");
      assert.ok(s.server.deactivated.has("alice"));
      assert.equal(s.server.revokedBefore.get("alice"), T0 + 1000);
      assert.deepEqual(s.store.channels.get("cp_school:s-sch1")?.members, []);
      // Revoked before deactivated: no new token works even if deactivation lags.
      assert.ok(s.server.calls.indexOf("revoke alice") < s.server.calls.indexOf("deactivate alice"));
    }
  });
  it("verified again: reactivated and put back in groups and carpool chats", async () => {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    s.store.carpoolMembers.set("k1", ["alice"]);
    const r = await syncAccess(s.deps, "alice", {
      before: accountFromDoc("alice", { status: "suspended" }),
      after: accountFromDoc("alice", { status: "verified", firstName: "Alia", parentId: "P1" }),
    });
    assert.equal(r, "restored");
    assert.ok(s.server.calls.includes("reactivate alice"));
    assert.ok(s.server.channels.get("cp_carpool:c-k1")?.members.has("alice"));
    assert.ok(s.server.channels.get("cp_school:s-sch1")?.members.has("alice"));
  });
  it("other user changes (language picked, phone) do nothing unless chat fields change", () => {
    const a = accountFromDoc("a", { status: "verified", firstName: "A", parentId: "P", phone: "+201" });
    const b = accountFromDoc("a", { status: "verified", firstName: "A", parentId: "P", phone: "+202", drivingPaused: true });
    assert.equal(chatRelevant({ before: a, after: b }), false);
    assert.equal(chatRelevant({ before: a, after: accountFromDoc("a", { status: "verified", firstName: "B", parentId: "P" }) }), true);
    assert.equal(chatRelevant({ before: null, after: accountFromDoc("a", { status: "unverified" }) }), true);
  });
  it("syncMyChats joins the caller's chats (rate limited)", async () => {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    s.store.carpoolMembers.set("k1", ["alice"]);
    assert.deepEqual(await syncMyChats(s.deps, me("alice")), { groups: 1, carpools: 1 });
    s.deps.limits.syncsPerHour = 1;
    await rejects(syncMyChats(s.deps, me("alice")), "rate-limited");
  });
});

describe("private chat requests", () => {
  it("request then accept opens one private chat with both parents", async () => {
    const s = twoParents();
    const r = await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    assert.deepEqual(r, { id: "alice_bob", status: "pending", cid: null });
    assert.equal(s.store.requests.get("alice_bob")?.fromFirstName, "Alia");
    assert.equal(s.server.channels.size, 0);
    const a = await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: true });
    assert.equal(a.status, "accepted");
    assert.equal(a.cid, `cp_private:${privateChannelId("alice", "bob")}`);
    assert.deepEqual([...(s.server.channels.get(a.cid as string)?.members ?? [])].sort(), ["alice", "bob"]);
    await rejects(sendChatRequest(s.deps, me("bob"), { toUid: "alice" }), "already-connected");
  });
  it("decline, cancel, and only the receiver answers", async () => {
    const s = twoParents();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    await rejects(answerChatRequest(s.deps, me("alice"), { requestId: "alice_bob", accept: true }), "not-found");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "bob" }), "already-pending");
    assert.equal((await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: false })).status, "declined");
    assert.equal(s.server.channels.size, 0);
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    await rejects(cancelChatRequest(s.deps, me("bob"), { requestId: "alice_bob" }), "not-found");
    assert.equal((await cancelChatRequest(s.deps, me("alice"), { requestId: "alice_bob" })).status, "cancelled");
  });
  it("asking someone who already asked you accepts their request", async () => {
    const s = twoParents();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    const r = await sendChatRequest(s.deps, me("bob"), { toUid: "alice" });
    assert.equal(r.status, "accepted");
    assert.equal(r.id, "alice_bob");
  });
  it("daily limit on new requests", async () => {
    const s = twoParents();
    s.deps.limits.requestsPerDay = 2;
    for (const u of ["c1", "c2", "c3"]) {
      s.store.addParent(u);
      s.store.childSchools.set(u, ["sch1"]);
    }
    await sendChatRequest(s.deps, me("alice"), { toUid: "c1" });
    await sendChatRequest(s.deps, me("alice"), { toUid: "c2" });
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "c3" }), "rate-limited");
    s.clock.now += 86_400_000;
    await sendChatRequest(s.deps, me("alice"), { toUid: "c3" });
  });
  it("refused: requests off, no shared school or carpool, unverified target, yourself, unverified caller", async () => {
    const s = twoParents();
    await updateChatSettings(s.deps, me("bob"), { requestsOff: true });
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "bob" }), "requests-off");
    s.store.addParent("far");
    s.store.childSchools.set("far", ["other"]);
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "far" }), "no-shared-school");
    s.store.carpoolMembers.set("k9", ["alice", "far"]);
    assert.equal((await sendChatRequest(s.deps, me("alice"), { toUid: "far" })).status, "pending");
    s.store.addParent("unv", { status: "unverified" });
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "unv" }), "not-found");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "alice" }), "self");
    s.store.addParent("me2", { status: "unverified" });
    await rejects(sendChatRequest(s.deps, me("me2", false), { toUid: "alice" }), "not-verified");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "x/y" }), "invalid-request");
  });
});

describe("blocking (F13)", () => {
  it("a blocked parent cannot message the blocker: private chat frozen, requests refused both ways", async () => {
    const s = twoParents();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    const { cid } = await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: true });
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    assert.equal(s.server.channels.get(cid as string)?.frozen, true);
    assert.equal(s.store.channels.get(cid as string)?.frozen, true);
    assert.equal(s.store.blocks.get("bob_alice")?.blockedFirstName, "Alia");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "bob" }), "blocked");
  });
  it("pending requests are cancelled and new ones refused, both directions", async () => {
    const s = twoParents();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    assert.equal(s.store.requests.get("alice_bob")?.status, "cancelled");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "bob" }), "blocked");
    await rejects(sendChatRequest(s.deps, me("bob"), { toUid: "alice" }), "blocked");
  });
  it("the blocker gets no push for the blocked parent's group messages", async () => {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    await syncCarpoolMember(s.deps, "k1", "alice", true);
    await syncCarpoolMember(s.deps, "k1", "bob", true);
    s.store.addParent("cara");
    await syncCarpoolMember(s.deps, "k1", "cara", true);
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    const r = await handleWebhook(s.deps, { type: "message.new", cid: "cp_carpool:c-k1", message: { id: "m1", type: "regular", text: "hi", user: { id: "alice" } } });
    assert.equal(r.recipients, 1);
    assert.deepEqual(s.store.events.get("chat_m1")?.recipients, ["cara"]);
  });
  it("unblock opens the chat again unless the other parent blocked too", async () => {
    const s = twoParents();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    const { cid } = await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: true });
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    await blockChatUser(s.deps, me("alice"), { uid: "bob" });
    await unblockChatUser(s.deps, me("bob"), { uid: "alice" });
    assert.equal(s.server.channels.get(cid as string)?.frozen, true);
    await unblockChatUser(s.deps, me("alice"), { uid: "bob" });
    assert.equal(s.server.channels.get(cid as string)?.frozen, false);
  });
  it("cannot block yourself or an unknown parent", async () => {
    const s = twoParents();
    await rejects(blockChatUser(s.deps, me("alice"), { uid: "alice" }), "self");
    await rejects(blockChatUser(s.deps, me("alice"), { uid: "ghost" }), "not-found");
  });
});

describe("mute and chat push via the webhook", () => {
  async function carpool() {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    await syncCarpoolMember(s.deps, "k1", "alice", true);
    await syncCarpoolMember(s.deps, "k1", "bob", true);
    return s;
  }
  const msg = (id: string, from: string, extra: Record<string, unknown> = {}) => ({
    type: "message.new",
    cid: "cp_carpool:c-k1",
    message: { id, type: "regular", text: "secret words", user: { id: from }, ...extra },
  });
  it("a new message becomes one push-only event for the other members, without the text", async () => {
    const s = await carpool();
    await handleWebhook(s.deps, msg("m1", "alice"));
    const e = s.store.events.get("chat_m1");
    assert.ok(e);
    assert.equal(e.type, "chat-message");
    assert.deepEqual(e.recipients, ["bob"]);
    assert.equal(e.carpoolId, "k1");
    assert.equal(e.chatCid, "cp_carpool:c-k1");
    assert.ok(!JSON.stringify(outboxDoc(e)).includes("secret words"));
    assert.ok(!JSON.stringify(s.logs).includes("secret words"));
  });
  it("the same webhook twice makes one event", async () => {
    const s = await carpool();
    assert.equal((await handleWebhook(s.deps, msg("m1", "alice"))).handled, true);
    assert.equal((await handleWebhook(s.deps, msg("m1", "alice"))).reason, "duplicate");
    assert.equal(s.store.events.size, 1);
  });
  it("muted parents get no push; unmuting brings it back", async () => {
    const s = await carpool();
    assert.deepEqual(await setChatMute(s.deps, me("bob"), { cid: "cp_carpool:c-k1", muted: true }), { muted: true });
    assert.equal(s.server.mutes.get("bob|cp_carpool:c-k1"), true);
    assert.equal((await handleWebhook(s.deps, msg("m1", "alice"))).reason, "nobody");
    await setChatMute(s.deps, me("bob"), { cid: "cp_carpool:c-k1", muted: false });
    await handleWebhook(s.deps, msg("m2", "alice"));
    assert.deepEqual(s.store.events.get("chat_m2")?.recipients, ["bob"]);
  });
  it("only members can mute a chat", async () => {
    const s = await carpool();
    s.store.addParent("out");
    await rejects(setChatMute(s.deps, me("out"), { cid: "cp_carpool:c-k1", muted: true }), "not-member");
    await rejects(setChatMute(s.deps, me("bob"), { cid: "messaging:x", muted: true }), "invalid-request");
  });
  it("large school groups push only to parents who unmuted them", async () => {
    const s = setup();
    s.store.schools.set("s1", { id: "s1", nameAr: "", nameEn: "" });
    for (let i = 0; i <= LARGE_GROUP_SIZE + 1; i += 1) {
      s.store.addParent(`p${i}`);
      s.store.childSchools.set(`p${i}`, ["s1"]);
      await syncParentGroups(s.deps, `p${i}`);
    }
    await setChatMute(s.deps, me("p5"), { cid: "cp_school:s-s1", muted: false });
    await handleWebhook(s.deps, { type: "message.new", cid: "cp_school:s-s1", message: { id: "g1", type: "regular", user: { id: "p1" } } });
    assert.deepEqual(s.store.events.get("chat_g1")?.recipients, ["p5"]);
  });
  it("ignores other events, system and silent messages, non-members, unknown channels and thread replies", async () => {
    const s = await carpool();
    assert.equal((await handleWebhook(s.deps, { type: "message.read" })).reason, "ignored-type");
    assert.equal((await handleWebhook(s.deps, msg("m1", "alice", { type: "system" }))).reason, "not-a-parent-message");
    assert.equal((await handleWebhook(s.deps, msg("m2", "alice", { silent: true }))).reason, "not-a-parent-message");
    assert.equal((await handleWebhook(s.deps, msg("m3", "carpool-system"))).reason, "not-a-parent-message");
    assert.equal((await handleWebhook(s.deps, msg("m4", "stranger"))).reason, "not-member");
    assert.equal((await handleWebhook(s.deps, { ...msg("m5", "alice"), cid: "messaging:x" })).reason, "unknown-channel");
    assert.equal((await handleWebhook(s.deps, msg("m6", "alice", { parent_id: "m0" }))).reason, "thread-reply");
    assert.equal((await handleWebhook(s.deps, msg("bad/id", "alice"))).reason, "bad-message");
    assert.equal(s.store.events.size, 0);
  });
  it("the chat push opens that chat and says only 'new message'", () => {
    const s = setup();
    void s;
    const event = eventFromDoc("chat_m1", { type: "chat-message", recipients: ["bob"], chatCid: "cp_private:dm-abc", actorUid: "alice" }, T0);
    assert.ok(event);
    const record = buildRecord(event, "bob", T0, 0);
    assert.equal(record.route, "/chats/cp_private/dm-abc");
    const push = buildPush(record, "en", { quiet: false, alarm: false });
    assert.equal(push.title, "New message");
    assert.equal(push.body, "You have a new message.");
    assert.deepEqual(Object.keys(push.data).sort(), ["alarm", "alarmAt", "critical", "notificationId", "route", "type"]);
    assert.equal(routeFor({ type: "chat-message", carpoolId: null, chatCid: "bad:../x" }), "/chats");
    assert.equal(routeFor({ type: "chat-message", carpoolId: null }), "/chats");
  });
});

describe("reports (F13)", () => {
  async function withMessages() {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    await syncCarpoolMember(s.deps, "k1", "alice", true);
    await syncCarpoolMember(s.deps, "k1", "bob", true);
    const m = (id: string, from: string, text: string, created: string) => ({ id, text, type: "regular", created_at: created, user: { id: from, name: from === "alice" ? "Alia" : "Badr", parent_id: "PID" + from } });
    s.server.messages.set("cp_carpool:c-k1", [
      m("m1", "alice", "one", "2026-11-16T07:00:00Z"),
      m("m2", "bob", "two", "2026-11-16T07:01:00Z"),
      m("m3", "alice", "three", "2026-11-16T07:02:00Z"),
      m("m4", "bob", "x".repeat(900), "2026-11-16T07:03:00Z"),
      m("m5", "alice", "five", "2026-11-16T07:04:00Z"),
      m("m6", "bob", "six", "2026-11-16T07:05:00Z"),
    ]);
    return s;
  }
  it("a message report keeps the message with a little context only", async () => {
    const s = await withMessages();
    const r = await reportChat(s.deps, me("alice"), { targetType: "message", cid: "cp_carpool:c-k1", messageId: "m4", reason: "harassment", note: " rude " });
    assert.equal(r.urgent, false);
    const rec = s.store.reports.get(r.reportId);
    assert.ok(rec);
    assert.deepEqual(rec.context.map((c) => c.id), ["m2", "m3", "m4", "m5"]);
    assert.equal(rec.context.find((c) => c.reported)?.id, "m4");
    assert.equal(rec.context[2].text.length, 500);
    assert.equal(rec.subjectUid, "bob");
    assert.equal(rec.note, "rude");
    assert.equal(rec.status, "open");
    assert.deepEqual(Object.keys(rec.context[0]).sort(), ["attachment", "authorName", "authorParentId", "authorUid", "createdAtMs", "id", "reported", "text"]);
    assert.equal(s.pauser.paused.length, 0);
  });
  it("an urgent report about a driver pauses their driving days at once", async () => {
    const s = await withMessages();
    const r = await reportChat(s.deps, me("alice"), { targetType: "user", cid: "cp_carpool:c-k1", uid: "bob", reason: "dangerousDriving" });
    assert.equal(r.urgent, true);
    assert.deepEqual(s.pauser.paused, [{ uid: "bob", reportId: r.reportId }]);
    assert.equal(s.store.reports.get(r.reportId)?.pausedDriving, true);
    const c = await reportChat(s.deps, me("bob"), { targetType: "message", cid: "cp_carpool:c-k1", messageId: "m1", reason: "childSafety" });
    assert.equal(c.urgent, true);
    assert.equal(s.pauser.paused[1].uid, "alice");
  });
  it("a group report is kept without pausing anyone", async () => {
    const s = await withMessages();
    const r = await reportChat(s.deps, me("alice"), { targetType: "group", cid: "cp_carpool:c-k1", reason: "childSafety" });
    assert.equal(s.store.reports.get(r.reportId)?.targetId, "cp_carpool:c-k1");
    assert.equal(s.pauser.paused.length, 0);
  });
  it("refused: not a member, unknown message, own message, bad reason, daily limit", async () => {
    const s = await withMessages();
    s.store.addParent("out");
    await rejects(reportChat(s.deps, me("out"), { targetType: "group", cid: "cp_carpool:c-k1", reason: "spam" }), "not-member");
    await rejects(reportChat(s.deps, me("alice"), { targetType: "message", cid: "cp_carpool:c-k1", messageId: "zz", reason: "spam" }), "not-found");
    await rejects(reportChat(s.deps, me("alice"), { targetType: "message", cid: "cp_carpool:c-k1", messageId: "m1", reason: "spam" }), "self");
    await rejects(reportChat(s.deps, me("alice"), { targetType: "user", cid: "cp_carpool:c-k1", uid: "out", reason: "spam" }), "not-found");
    await rejects(reportChat(s.deps, me("alice"), { targetType: "group", cid: "cp_carpool:c-k1", reason: "rude" }), "invalid-request");
    // Three refused reports above were counted (after the membership check).
    s.deps.limits.reportsPerDay = 4;
    await reportChat(s.deps, me("alice"), { targetType: "group", cid: "cp_carpool:c-k1", reason: "spam" });
    await rejects(reportChat(s.deps, me("alice"), { targetType: "group", cid: "cp_carpool:c-k1", reason: "spam" }), "rate-limited");
  });
});

describe("admin: reports queue actions", () => {
  async function adminSetup() {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    await syncCarpoolMember(s.deps, "k1", "alice", true);
    await syncCarpoolMember(s.deps, "k1", "bob", true);
    s.server.messages.set("cp_carpool:c-k1", [{ id: "m1", text: "bad", type: "regular", user: { id: "bob", name: "Badr", parent_id: "P" } }]);
    const audit: AuditEntry[] = [];
    const deps: ChatAdminDeps = { ...s.deps, audit: async (e) => void audit.push(e) };
    const { reportId } = await reportChat(s.deps, me("alice"), { targetType: "message", cid: "cp_carpool:c-k1", messageId: "m1", reason: "childSafety" });
    return { ...s, adminDeps: deps, audit, reportId };
  }
  const admin = { uid: "adm1", role: "admin" as const };
  it("opening a report is logged and shows only the kept context", async () => {
    const s = await adminSetup();
    const v = await getReport(s.adminDeps, admin, { reportId: s.reportId }, "1.2.3.4");
    assert.equal(v.context.length, 1);
    assert.equal(v.context[0].text, "bad");
    assert.equal(s.audit[0].action, "report.view");
    assert.ok(!JSON.stringify(s.audit).includes("bad"));
  });
  it("remove the message: deleted on Stream, report closed, audited", async () => {
    const s = await adminSetup();
    const v = await removeReportedMessage(s.adminDeps, admin, { reportId: s.reportId }, null);
    assert.deepEqual(s.server.deleted, ["m1"]);
    assert.equal(v.status, "handled");
    assert.equal(v.outcome, "message-removed");
    assert.equal(s.audit.at(-1)?.action, "chat.removeMessage");
  });
  it("remove the member: out of that chat and never added back", async () => {
    const s = await adminSetup();
    await removeReportedMember(s.adminDeps, admin, { reportId: s.reportId }, null);
    assert.ok(!s.server.channels.get("cp_carpool:c-k1")?.members.has("bob"));
    assert.deepEqual(s.store.channels.get("cp_carpool:c-k1")?.excluded, ["bob"]);
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", true), "excluded");
  });
  it("resolve with an outcome; lift the driving pause", async () => {
    const s = await adminSetup();
    await assert.rejects(resolveReport(s.adminDeps, admin, { reportId: s.reportId, outcome: "whatever" }, null));
    assert.equal((await resolveReport(s.adminDeps, admin, { reportId: s.reportId, outcome: "warned" }, null)).outcome, "warned");
    const v = await liftDrivingPause(s.adminDeps, admin, { reportId: s.reportId }, null);
    assert.deepEqual(s.pauser.lifted, ["bob"]);
    assert.equal(v.pausedDriving, false);
    await assert.rejects(liftDrivingPause(s.adminDeps, admin, { reportId: s.reportId }, null));
    await assert.rejects(getReport(s.adminDeps, admin, { reportId: "../x" }, null));
  });
});

describe("retention", () => {
  it("every registered channel loses messages older than the period", async () => {
    const s = twoParents();
    await syncParentGroups(s.deps, "alice");
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    await syncCarpoolMember(s.deps, "k1", "alice", true);
    const r = await runChatRetention(s.deps, 180, 1);
    assert.deepEqual(r, { channels: 2, failed: 0 });
    assert.deepEqual(
      s.server.truncated.map((t) => t.cid).sort(),
      ["cp_carpool:c-k1", "cp_school:s-sch1"],
    );
    assert.ok(s.server.truncated.every((t) => t.beforeMs === T0 - 180 * 86_400_000));
  });
  it("odd periods fall back to 180 days; failures are counted, not fatal", async () => {
    assert.equal(retentionDays(5), 180);
    assert.equal(retentionDays(365), 365);
    assert.equal(retentionDays(10_000), 180);
    const s = twoParents();
    await syncParentGroups(s.deps, "alice");
    s.server.failing = true;
    assert.deepEqual(await runChatRetention(s.deps, 90), { channels: 0, failed: 1 });
  });
});
