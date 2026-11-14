import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { liftDrivingPause, removeReportedMember, removeReportedMessage, resolveReport, getReport, type ChatAdminDeps } from "../src/chat/admin";
import {
  answerChatRequest,
  blockChatUser,
  cancelChatRequest,
  DEFAULT_CHAT_LIMITS,
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
  MESSAGE_TEXT_MAX,
  parseCid,
  privateChannelId,
  type ChannelRecord,
} from "../src/chat/model";
import { photoPathOk } from "../src/chat/data";
import { chatEventId, DEFAULT_FANOUT_LIMITS, messageFromDoc, onMessageCreated, type FanoutDeps } from "../src/chat/fanout";
import { BLOCKED_TERMS_AR, BLOCKED_TERMS_EN, hasBlockedTerm } from "../src/chat/moderation";
import { createChatServer, FakeChatServer, FirestoreChatServer } from "../src/chat/server";
import { accountFromDoc, chatRelevant, nearestArea, syncAccess, syncCarpoolMember, syncParentGroups } from "../src/chat/sync";
import { routeFor } from "../src/notifications/catalog";
import { buildPush, buildRecord, eventFromDoc } from "../src/notifications/model";
import { outboxDoc } from "../src/notifications/outbox";
import type { AuditEntry } from "../src/admin_panel/types";
import { FakePauser, MemoryChatData, MemoryChatStore } from "./helpers/memory_chat";

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

const CP = "cp_carpool:c-k1";

/** Two verified parents on the Firestore provider (in-memory documents). */
function fsSetup() {
  const s = twoParents();
  const data = new MemoryChatData();
  for (const a of s.store.accounts.values()) data.profiles.set(a.uid, { firstName: a.firstName, parentId: a.parentId });
  const add = s.store.addParent.bind(s.store);
  s.store.addParent = (uid, extra) => {
    const a = add(uid, extra);
    data.profiles.set(uid, { firstName: a.firstName, parentId: a.parentId });
    return a;
  };
  const fs = new FirestoreChatServer(data, () => s.clock.now);
  s.deps.server = fs;
  const fan: FanoutDeps = { store: s.store, data, server: fs, limits: { ...DEFAULT_FANOUT_LIMITS }, now: () => s.clock.now, log: s.deps.log };
  return { ...s, data, fs, fan };
}

/** Alice and Bob in the chat of carpool k1. */
async function fsCarpool() {
  const s = fsSetup();
  s.store.carpools.set("k1", { id: "k1", nameAr: "مدرسة · 07:30", nameEn: "School · 07:30", active: true });
  await syncCarpoolMember(s.deps, "k1", "alice", true);
  await syncCarpoolMember(s.deps, "k1", "bob", true);
  return s;
}

/** What the phone does (the rules allowed it), then the trigger. */
async function send(s: ReturnType<typeof fsSetup>, cid: string, id: string, from: string, m: { kind?: string; text?: string; photoPath?: string; lat?: number; lng?: number }) {
  const kind = m.kind ?? "text";
  await s.data.createMessage(cid, { id, senderUid: from, kind: kind as "text", text: m.text ?? "", photoPath: m.photoPath ?? null, lat: m.lat ?? null, lng: m.lng ?? null, createdAtMs: s.clock.now });
  return onMessageCreated(s.fan, cid, id, { senderUid: from, kind, text: m.text, photoPath: m.photoPath, lat: m.lat, lng: m.lng, createdAt: s.clock.now });
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

describe("chat provider (CHAT_PROVIDER: fake | firestore)", () => {
  it("the fake is refused in prod; an unknown provider (the old 'stream' too) is refused", () => {
    const data = () => new MemoryChatData();
    assert.throws(() => createChatServer("fake", "prod", data, () => undefined));
    assert.throws(() => createChatServer("stream", "dev", data, () => undefined));
    assert.throws(() => createChatServer("other", "dev", data, () => undefined));
    assert.equal(createChatServer("fake", "dev", data, () => undefined).kind, "fake");
    assert.equal(createChatServer("firestore", "prod", data, () => undefined).kind, "firestore");
  });
  it("an unverified, suspended or banned account joins no chat (the rules need a member document)", async () => {
    const s = fsSetup();
    s.store.addParent("u1", { status: "unverified" });
    s.store.addParent("s1", { status: "suspended" });
    s.store.addParent("b1", { banned: true });
    await rejects(syncMyChats(s.deps, me("u1", false)), "not-verified");
    await rejects(syncMyChats(s.deps, me("u1", true)), "not-verified");
    await rejects(syncMyChats(s.deps, me("s1")), "suspended");
    await rejects(syncMyChats(s.deps, me("b1")), "suspended");
    await rejects(syncMyChats(s.deps, me("nobody")), "not-verified");
    assert.equal(s.data.memberDocs.size, 0);
    assert.equal(s.data.summaries.size, 0);
  });
});

describe("Firestore chat: the documents the phone reads", () => {
  it("a carpool chat: head, member documents with first names only, one chat list row each", async () => {
    const s = await fsCarpool();
    const head = s.data.heads.get(CP);
    assert.equal(head?.kind, "carpool");
    assert.equal(head?.memberCount, 2);
    assert.equal(head?.nameEn, "School · 07:30");
    const alice = s.data.memberDocs.get(`${CP}|alice`);
    assert.deepEqual(alice, { uid: "alice", firstName: "Alia", active: true, cut: false, frozen: false, mutedUntilMs: null, joinedAtMs: T0, updatedAtMs: T0 });
    assert.deepEqual(Object.keys(alice ?? {}).sort(), ["active", "cut", "firstName", "frozen", "joinedAtMs", "mutedUntilMs", "uid", "updatedAtMs"]);
    const row = s.data.summaries.get(`bob|${CP}`);
    assert.equal(row?.open, true);
    assert.equal(row?.memberCount, 2);
    assert.equal(row?.unread, 0);
    assert.equal(row?.muted, null);
    assert.equal(row?.otherUid, null, "no other parent on a group row");
  });
  it("a private chat row names the other parent", async () => {
    const s = fsSetup();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    const { cid } = await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: true });
    assert.equal(s.data.summaries.get(`alice|${cid}`)?.otherUid, "bob");
    assert.equal(s.data.summaries.get(`alice|${cid}`)?.otherName, "Badr");
    assert.equal(s.data.summaries.get(`bob|${cid}`)?.otherName, "Alia");
    assert.equal(s.data.heads.get(cid as string)?.memberCount, 2);
  });
  it("a removed member loses access at once: inactive member document, closed row, the name stays for old messages", async () => {
    const s = await fsCarpool();
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", false), "removed");
    const bob = s.data.memberDocs.get(`${CP}|bob`);
    assert.equal(bob?.active, false);
    assert.equal(bob?.firstName, "Badr");
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.open, false);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.last, null);
    assert.equal(s.data.heads.get(CP)?.memberCount, 1);
    assert.equal(s.data.summaries.get(`alice|${CP}`)?.memberCount, 1);
    // Back in: the row opens with fresh counters.
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", true), "added");
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.active, true);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.open, true);
    assert.equal(s.data.heads.get(CP)?.memberCount, 2);
  });
  it("suspending cuts every chat off at once and verifying again restores them", async () => {
    const s = await fsCarpool();
    const before = accountFromDoc("bob", { status: "verified", firstName: "Badr", parentId: "P2" });
    const suspended = accountFromDoc("bob", { status: "suspended", firstName: "Badr", parentId: "P2" });
    s.store.accounts.set("bob", suspended!);
    assert.equal(await syncAccess(s.deps, "bob", { before, after: suspended }), "cut-off");
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.cut, true);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.open, false);
    s.store.accounts.set("bob", before!);
    s.store.carpoolMembers.set("k1", ["alice", "bob"]);
    assert.equal(await syncAccess(s.deps, "bob", { before: suspended, after: before }), "restored");
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.cut, false);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.open, true);
  });
  it("blocking freezes the private chat where the rules read it (both member documents)", async () => {
    const s = fsSetup();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    const { cid } = await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: true });
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    assert.equal(s.data.heads.get(cid as string)?.frozen, true);
    assert.equal(s.data.memberDocs.get(`${cid}|alice`)?.frozen, true);
    assert.equal(s.data.memberDocs.get(`${cid}|bob`)?.frozen, true);
    assert.equal(s.data.summaries.get(`alice|${cid}`)?.frozen, true);
    await unblockChatUser(s.deps, me("bob"), { uid: "alice" });
    assert.equal(s.data.memberDocs.get(`${cid}|alice`)?.frozen, false);
    assert.equal(s.data.heads.get(cid as string)?.frozen, false);
  });
  it("a new first name reaches member documents and the other parent's private row; nothing is written when it is the same", async () => {
    const s = fsSetup();
    await sendChatRequest(s.deps, me("alice"), { toUid: "bob" });
    const { cid } = await answerChatRequest(s.deps, me("bob"), { requestId: "alice_bob", accept: true });
    const writes = s.data.writes;
    await s.fs.upsertUser({ id: "alice", name: "Alia" });
    assert.equal(s.data.writes, writes);
    await s.fs.upsertUser({ id: "alice", name: "A." });
    assert.equal(s.data.memberDocs.get(`${cid}|alice`)?.firstName, "A.");
    assert.equal(s.data.summaries.get(`bob|${cid}`)?.otherName, "A.");
  });
  it("mute is the parent's own choice on their row", async () => {
    const s = await fsCarpool();
    await setChatMute(s.deps, me("bob"), { cid: CP, muted: true });
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.muted, true);
    assert.equal(s.data.summaries.get(`alice|${CP}`)?.muted, null);
  });
  it("is idempotent: syncing again writes nothing", async () => {
    const s = await fsCarpool();
    const writes = s.data.writes;
    assert.equal(await syncCarpoolMember(s.deps, "k1", "alice", true), "unchanged");
    assert.equal(s.data.writes, writes);
  });
  it("system messages (F35) are posted once per ID", async () => {
    const s = await fsCarpool();
    await s.fs.postSystemMessage("cp_carpool", "c-k1", "quick-1", "Badr: running late", { kind: "late" });
    await s.fs.postSystemMessage("cp_carpool", "c-k1", "quick-1", "Badr: running late", { kind: "late" });
    assert.equal(s.data.messageDocs.get(CP)?.length, 1);
    assert.equal(s.data.messageDocs.get(CP)?.[0].senderUid, "carpool-system");
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
  it("is idempotent: a second run changes nothing", async () => {
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
      assert.deepEqual(s.store.channels.get("cp_school:s-sch1")?.members, []);
      // Cut off first, then the groups: access never waits for the group sync.
      assert.ok(s.server.calls.indexOf("deactivate alice") < s.server.calls.findIndex((c) => c.startsWith("removeMembers")));
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
  it("refused requests count toward the daily limit (no free probing of uids)", async () => {
    const s = twoParents();
    s.deps.limits.requestsPerDay = 2;
    s.store.addParent("far");
    s.store.childSchools.set("far", ["other"]);
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "far" }), "no-shared-school");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "ghost" }), "not-found");
    await rejects(sendChatRequest(s.deps, me("alice"), { toUid: "bob" }), "rate-limited");
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
  it("the blocker gets no push for the blocked parent's group messages; the others do", async () => {
    const s = await fsCarpool();
    s.store.addParent("cara");
    await syncCarpoolMember(s.deps, "k1", "cara", true);
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    const r = await send(s, CP, "m1", "alice", { text: "hi" });
    assert.equal(r.recipients, 1);
    assert.deepEqual(s.store.events.get(chatEventId(CP, "m1"))?.recipients, ["cara"]);
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

describe("new message fan-out (the trigger on chats/{cid}/messages/{id})", () => {
  it("small chat: head, unread counters, last message, and one push-only event without the text", async () => {
    const s = await fsCarpool();
    const r = await send(s, CP, "m1", "alice", { text: "secret words" });
    assert.deepEqual(r, { handled: true, recipients: 1, reason: null, removed: false });
    const head = s.data.heads.get(CP);
    assert.equal(head?.seq, 1);
    assert.equal(head?.lastAtMs, T0);
    assert.deepEqual(head?.last, { kind: "text", senderUid: "alice", text: "secret words" });
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.unread, 1);
    assert.equal(s.data.summaries.get(`alice|${CP}`)?.unread, 0, "never your own message");
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.last?.text, "secret words");
    const e = s.store.events.get(chatEventId(CP, "m1"));
    assert.ok(e);
    assert.equal(e.type, "chat-message");
    assert.deepEqual(e.recipients, ["bob"]);
    assert.equal(e.carpoolId, "k1");
    assert.equal(e.chatCid, CP);
    assert.equal(e.actorUid, "alice");
    assert.ok(e.id.startsWith("chat_"));
    assert.ok(!JSON.stringify(outboxDoc(e)).includes("secret words"));
    assert.ok(!JSON.stringify(s.logs).includes("secret words"));
  });
  it("the same trigger twice counts once and makes one event", async () => {
    const s = await fsCarpool();
    await send(s, CP, "m1", "alice", { text: "hi" });
    const again = await onMessageCreated(s.fan, CP, "m1", { senderUid: "alice", kind: "text", text: "hi", createdAt: T0 });
    assert.equal(again.reason, "duplicate");
    assert.equal(s.data.heads.get(CP)?.seq, 1);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.unread, 1);
    assert.equal(s.store.events.size, 1);
  });
  it("the preview is cut short; photos and pins show no text and no coordinates", async () => {
    const s = await fsCarpool();
    await send(s, CP, "m1", "alice", { text: "x".repeat(500) });
    assert.equal(s.data.heads.get(CP)?.last?.text.length, 80);
    await send(s, CP, "m2", "alice", { kind: "location", lat: 30.0444, lng: 31.2357 });
    assert.deepEqual(s.data.heads.get(CP)?.last, { kind: "location", senderUid: "alice", text: "" });
    assert.ok(!JSON.stringify([...s.data.summaries.values()]).includes("31.2357"));
    assert.ok(!JSON.stringify(s.logs).includes("30.0444"));
    await send(s, CP, "m3", "bob", { kind: "photo", photoPath: `chatPhotos/${CP}/bob/m3.webp` });
    assert.equal(s.data.heads.get(CP)?.last?.kind, "photo");
    assert.equal(s.data.heads.get(CP)?.seq, 3);
  });
  it("school groups: one head write, no row per member; the app counts unread from seq", async () => {
    const s = fsSetup();
    await syncParentGroups(s.deps, "alice");
    await syncParentGroups(s.deps, "bob");
    const cid = "cp_school:s-sch1";
    const writes = s.data.writes;
    await send(s, cid, "g1", "alice", { text: "hello" });
    assert.equal(s.data.writes, writes + 1, "the head only");
    assert.equal(s.data.heads.get(cid)?.seq, 1);
    assert.equal(s.data.summaries.get(`bob|${cid}`)?.unread, 0);
    assert.equal(s.data.summaries.get(`bob|${cid}`)?.readSeq, 0);
    assert.deepEqual(s.store.events.get(chatEventId(cid, "g1"))?.recipients, ["bob"]);
  });
  it("photos and the location pin are refused in school and area groups (removed)", async () => {
    const s = fsSetup();
    await syncParentGroups(s.deps, "alice");
    const cid = "cp_school:s-sch1";
    assert.equal((await send(s, cid, "g1", "alice", { kind: "location", lat: 30, lng: 31 })).reason, "bad-location");
    assert.equal((await send(s, cid, "g2", "alice", { kind: "photo", photoPath: `chatPhotos/${cid}/alice/g2.jpg` })).reason, "bad-photo");
    assert.equal(s.data.messageDocs.get(cid)?.length, 0);
    assert.equal(s.data.heads.get(cid)?.seq, 0);
  });
  it("a photo must sit in the sender's own folder of that chat under the message's ID", async () => {
    const s = await fsCarpool();
    assert.equal((await send(s, CP, "m1", "alice", { kind: "photo", photoPath: `chatPhotos/${CP}/bob/m1.jpg` })).reason, "bad-photo");
    assert.equal((await send(s, CP, "m2", "alice", { kind: "photo", photoPath: "verification/bob/cases/c1/id_front.jpg" })).reason, "bad-photo");
    assert.equal((await send(s, CP, "m3", "alice", { kind: "photo", photoPath: `chatPhotos/${CP}/alice/m3.webp` })).removed, false);
    assert.equal(photoPathOk(CP, "alice", "m3", `chatPhotos/${CP}/alice/m3.gif`), false);
  });
  it("too long, empty or malformed messages and messages from non-members are removed", async () => {
    const s = await fsCarpool();
    s.store.addParent("out");
    assert.equal((await send(s, CP, "m1", "out", { text: "hi" })).reason, "not-member");
    assert.equal((await send(s, CP, "m2", "alice", { text: "x".repeat(MESSAGE_TEXT_MAX + 1) })).reason, "bad-text");
    assert.equal((await send(s, CP, "m3", "alice", { text: "" })).reason, "bad-text");
    assert.equal((await send(s, CP, "m4", "alice", { kind: "voice" })).reason, "invalid");
    assert.equal((await onMessageCreated(s.fan, "messaging:x", "m5", { senderUid: "alice", kind: "text", text: "a" })).reason, "unknown-chat");
    assert.equal(s.data.messageDocs.get(CP)?.length, 0);
    assert.equal(s.store.events.size, 0);
    assert.equal(messageFromDoc("bad/id", { senderUid: "a", kind: "text", text: "a" }), null);
  });
  it("sending too fast: the message is removed and the sender cannot write for a while, in every chat", async () => {
    const s = await fsCarpool();
    await syncParentGroups(s.deps, "alice");
    s.fan.limits = { messagesPerMinute: 3, muteMinutes: 10 };
    for (let i = 0; i < 3; i += 1) assert.equal((await send(s, CP, `m${i}`, "alice", { text: "a" })).removed, false);
    const r = await send(s, CP, "m3", "alice", { text: "a" });
    assert.deepEqual(r, { handled: false, recipients: 0, reason: "too-fast", removed: true });
    assert.equal(s.data.memberDocs.get(`${CP}|alice`)?.mutedUntilMs, T0 + 10 * 60_000);
    assert.equal(s.data.memberDocs.get("cp_school:s-sch1|alice")?.mutedUntilMs, T0 + 10 * 60_000);
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.mutedUntilMs, null);
    assert.equal(s.data.messageDocs.get(CP)?.length, 3);
    assert.equal(s.data.heads.get(CP)?.seq, 3);
    // A minute later the window is new.
    s.clock.now = T0 + 61_000;
    assert.equal((await send(s, CP, "m9", "alice", { text: "a" })).removed, false);
  });
  it("blocked terms: the message is removed and nobody is told; never logged", async () => {
    const s = await fsCarpool();
    const r = await send(s, CP, "m1", "alice", { text: "you BITCH!" });
    assert.equal(r.reason, "blocked-term");
    assert.equal(s.data.messageDocs.get(CP)?.length, 0);
    assert.equal(s.store.events.size, 0);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.unread, 0);
    assert.ok(!JSON.stringify(s.logs).toLowerCase().includes("bitch"));
  });
  it("muted parents get no push; unmuting brings it back", async () => {
    const s = await fsCarpool();
    assert.deepEqual(await setChatMute(s.deps, me("bob"), { cid: CP, muted: true }), { muted: true });
    assert.equal((await send(s, CP, "m1", "alice", { text: "a" })).reason, "nobody");
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.unread, 1, "still counted as unread");
    await setChatMute(s.deps, me("bob"), { cid: CP, muted: false });
    await send(s, CP, "m2", "alice", { text: "a" });
    assert.deepEqual(s.store.events.get(chatEventId(CP, "m2"))?.recipients, ["bob"]);
  });
  it("only members can mute a chat", async () => {
    const s = await fsCarpool();
    s.store.addParent("out");
    await rejects(setChatMute(s.deps, me("out"), { cid: CP, muted: true }), "not-member");
    await rejects(setChatMute(s.deps, me("bob"), { cid: "messaging:x", muted: true }), "invalid-request");
  });
  it("the blocker gets no push for the blocked parent's group messages", async () => {
    const s = await fsCarpool();
    await blockChatUser(s.deps, me("bob"), { uid: "alice" });
    assert.equal((await send(s, CP, "m1", "alice", { text: "a" })).reason, "nobody");
    await send(s, CP, "m2", "bob", { text: "a" });
    assert.deepEqual(s.store.events.get(chatEventId(CP, "m2"))?.recipients, ["alice"]);
  });
  it("large school groups push only to parents who unmuted them", async () => {
    const s = fsSetup();
    s.store.schools.set("s1", { id: "s1", nameAr: "", nameEn: "" });
    for (let i = 0; i <= LARGE_GROUP_SIZE + 1; i += 1) {
      s.store.addParent(`p${i}`);
      s.store.childSchools.set(`p${i}`, ["s1"]);
      await syncParentGroups(s.deps, `p${i}`);
    }
    await setChatMute(s.deps, me("p5"), { cid: "cp_school:s-s1", muted: false });
    await send(s, "cp_school:s-s1", "g1", "p1", { text: "a" });
    assert.deepEqual(s.store.events.get(chatEventId("cp_school:s-s1", "g1"))?.recipients, ["p5"]);
    assert.equal(s.data.heads.get("cp_school:s-s1")?.memberCount, LARGE_GROUP_SIZE + 2);
  });
  it("a system message updates the chat list and sends no push", async () => {
    const s = await fsCarpool();
    await s.fs.postSystemMessage("cp_carpool", "c-k1", "quick-1", "Badr: at the gate", {});
    const m = s.data.messageDocs.get(CP)?.[0];
    const r = await onMessageCreated(s.fan, CP, "quick-1", { senderUid: m?.senderUid, kind: "text", text: m?.text, createdAt: T0 });
    assert.equal(r.reason, "system");
    assert.equal(s.data.summaries.get(`alice|${CP}`)?.unread, 1);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.unread, 1);
    assert.equal(s.store.events.size, 0);
  });
  it("the chat push opens that chat and says only 'new message'", () => {
    const event = eventFromDoc(chatEventId("cp_private:dm-abc", "m1"), { type: "chat-message", recipients: ["bob"], chatCid: "cp_private:dm-abc", actorUid: "alice" }, T0);
    assert.ok(event);
    const record = buildRecord(event, "bob", T0, 0);
    assert.equal(record.route, "/chats/cp_private/dm-abc");
    const push = buildPush(record, "en", { quiet: false, alarm: false });
    assert.equal(push.title, "New message");
    assert.equal(push.body, "You have a new message.");
    assert.deepEqual(Object.keys(push.data).sort(), ["alarm", "alarmAt", "critical", "notificationId", "route", "type"]);
    assert.equal(routeFor({ type: "chat-message", carpoolId: null, chatCid: "bad:../x" }), "/chats");
    assert.equal(routeFor({ type: "chat-message", carpoolId: null }), "/chats");
    // Two chats, the same message ID: two events.
    assert.notEqual(chatEventId("cp_private:dm-a", "m1"), chatEventId("cp_private:dm-b", "m1"));
  });
});

describe("reports (F13)", () => {
  async function withMessages() {
    const s = twoParents();
    s.store.carpools.set("k1", { id: "k1", nameAr: "", nameEn: "", active: true });
    await syncCarpoolMember(s.deps, "k1", "alice", true);
    await syncCarpoolMember(s.deps, "k1", "bob", true);
    const m = (id: string, from: string, text: string, created: string) => ({ id, text, uid: from, name: from === "alice" ? "Alia" : "Badr", parentId: "PID" + from, createdAtMs: Date.parse(created) });
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
    s.server.messages.set("cp_carpool:c-k1", [{ id: "m1", text: "bad", uid: "bob", name: "Badr", parentId: "P" }]);
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
  it("remove the message: deleted, report closed, audited", async () => {
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

describe("reports and admin removal on Firestore data", () => {
  async function chatWithMessages() {
    const s = await fsCarpool();
    const texts = ["one", "two", "three", "x".repeat(900), "five", "six"];
    for (let i = 0; i < texts.length; i += 1) {
      s.clock.now = T0 + i * 61_000;
      await send(s, CP, `m${i + 1}`, i % 2 === 0 ? "alice" : "bob", { text: texts[i] });
    }
    return s;
  }
  it("a message report reads the message with a little context from Firestore; names come from our records", async () => {
    const s = await chatWithMessages();
    await send(s, CP, "p1", "bob", { kind: "photo", photoPath: `chatPhotos/${CP}/bob/p1.webp` });
    const r = await reportChat(s.deps, me("alice"), { targetType: "message", cid: CP, messageId: "m4", reason: "harassment" });
    const rec = s.store.reports.get(r.reportId);
    assert.ok(rec);
    assert.deepEqual(rec.context.map((c) => c.id), ["m2", "m3", "m4", "m5"]);
    assert.equal(rec.context[2].reported, true);
    assert.equal(rec.context[2].text.length, 500);
    assert.equal(rec.context[2].authorName, "Badr");
    assert.equal(rec.context[2].authorParentId, s.store.accounts.get("bob")?.parentId);
    assert.equal(rec.subjectUid, "bob");
    // A photo report keeps the kind, never the photo or its path.
    const p = await reportChat(s.deps, me("alice"), { targetType: "message", cid: CP, messageId: "p1", reason: "inappropriate" });
    const photo = s.store.reports.get(p.reportId)?.context.find((c) => c.reported);
    assert.equal(photo?.attachment, "image");
    assert.ok(!JSON.stringify(s.store.reports.get(p.reportId)).includes("chatPhotos/"));
  });
  it("admin removes the reported message: gone for everyone, its photo too, and the chat list stops showing it", async () => {
    const s = await chatWithMessages();
    await send(s, CP, "p1", "bob", { kind: "photo", photoPath: `chatPhotos/${CP}/bob/p1.webp` });
    const audit: AuditEntry[] = [];
    const adminDeps: ChatAdminDeps = { ...s.deps, audit: async (e) => void audit.push(e) };
    const { reportId } = await reportChat(s.deps, me("alice"), { targetType: "message", cid: CP, messageId: "p1", reason: "inappropriate" });
    const v = await removeReportedMessage(adminDeps, { uid: "adm1", role: "admin" }, { reportId }, null);
    assert.equal(v.outcome, "message-removed");
    assert.equal(await s.data.message(CP, "p1"), null);
    assert.deepEqual(s.data.deletedPhotos, [`chatPhotos/${CP}/bob/p1.webp`]);
    assert.deepEqual(s.data.heads.get(CP)?.last, { kind: "deleted", senderUid: "bob", text: "" });
    assert.equal(s.data.summaries.get(`alice|${CP}`)?.last?.kind, "deleted");
    assert.equal(audit.at(-1)?.action, "chat.removeMessage");
    // Removing an older message leaves the last message alone.
    const older = await reportChat(s.deps, me("alice"), { targetType: "message", cid: CP, messageId: "m2", reason: "spam" });
    await removeReportedMessage(adminDeps, { uid: "adm1", role: "admin" }, { reportId: older.reportId }, null);
    assert.equal(s.data.heads.get(CP)?.last?.kind, "deleted");
    assert.equal(s.data.messageDocs.get(CP)?.some((m) => m.id === "m2"), false);
  });
  it("admin removes the member: inactive in the rules at once and never added back", async () => {
    const s = await chatWithMessages();
    const adminDeps: ChatAdminDeps = { ...s.deps, audit: async () => undefined };
    const { reportId } = await reportChat(s.deps, me("alice"), { targetType: "user", cid: CP, uid: "bob", reason: "harassment" });
    await removeReportedMember(adminDeps, { uid: "adm1", role: "admin" }, { reportId }, null);
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.active, false);
    assert.equal(s.data.summaries.get(`bob|${CP}`)?.open, false);
    assert.equal(await syncCarpoolMember(s.deps, "k1", "bob", true), "excluded");
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.active, false);
  });
});

describe("retention, deletion and export (life of the chat + 1 year, run by retentionDaily)", () => {
  it("the export holds the parent's own messages only, newest first, with their own pin and photo path", async () => {
    const s = await fsCarpool();
    await send(s, CP, "m1", "alice", { text: "hello" });
    s.clock.now = T0 + 1000;
    await send(s, CP, "m2", "bob", { text: "hi" });
    s.clock.now = T0 + 2000;
    await send(s, CP, "m3", "alice", { kind: "location", lat: 30.01, lng: 31.02 });
    const mine = await s.fs.userMessages("alice", 10);
    assert.deepEqual(mine.map((m) => m.id), ["m3", "m1"]);
    assert.deepEqual(mine[0].location, { lat: 30.01, lng: 31.02 });
    assert.equal(mine[1].text, "hello");
    assert.equal(mine[1].cid, CP);
    assert.equal(mine[1].createdAt, new Date(T0).toISOString());
    assert.ok(!JSON.stringify(mine).includes("hi"));
  });
  it("a deleted parent shows as an initial; a year later their messages, photos and chat list go, the others stay", async () => {
    const s = await fsCarpool();
    await send(s, CP, "m1", "alice", { text: "hello" });
    await send(s, CP, "m2", "bob", { text: "hi" });
    await send(s, CP, "m3", "alice", { kind: "photo", photoPath: `chatPhotos/${CP}/alice/m3.webp` });
    // Account deletion, chat step: cut off, name becomes an initial.
    await s.fs.deactivateUser("alice");
    await s.fs.upsertUser({ id: "alice", name: "A." });
    assert.equal(s.data.memberDocs.get(`${CP}|alice`)?.cut, true);
    assert.equal(s.data.memberDocs.get(`${CP}|alice`)?.firstName, "A.");
    assert.equal(s.data.messageDocs.get(CP)?.length, 3, "kept for the year");
    // Purge step, 1 year after closure.
    await s.fs.deleteUser("alice");
    assert.deepEqual(s.data.messageDocs.get(CP)?.map((m) => m.id), ["m2"]);
    assert.deepEqual(s.data.deletedPhotos, [`chatPhotos/${CP}/alice/m3.webp`]);
    assert.equal(s.data.summaries.has(`alice|${CP}`), false);
    assert.equal(s.data.summaries.has(`bob|${CP}`), true);
  });
  it("an ended chat is deleted with its messages, photos, members and chat list rows", async () => {
    const s = await fsCarpool();
    await send(s, CP, "m1", "alice", { kind: "photo", photoPath: `chatPhotos/${CP}/alice/m1.jpg` });
    await s.fs.setFrozen("cp_carpool", "c-k1", true);
    assert.equal(s.data.memberDocs.get(`${CP}|bob`)?.frozen, true);
    await s.fs.deleteChannel("cp_carpool", "c-k1");
    assert.equal(s.data.heads.has(CP), false);
    assert.equal(s.data.messageDocs.has(CP), false);
    assert.equal([...s.data.memberDocs.keys()].length, 0);
    assert.equal([...s.data.summaries.keys()].length, 0);
    assert.deepEqual(s.data.deletedPhotos, [`chatPhotos/${CP}/alice/m1.jpg`]);
  });
});

describe("blocked terms", () => {
  it("Arabic and English lists; whole words and phrases, any case, Arabic letter forms", () => {
    assert.ok(BLOCKED_TERMS_AR.length >= 10 && BLOCKED_TERMS_AR.every((w) => /[؀-ۿ]/.test(w)));
    assert.ok(BLOCKED_TERMS_EN.length >= 10 && BLOCKED_TERMS_EN.every((w) => /^[a-z ]+$/.test(w)));
    assert.equal(hasBlockedTerm("Go KILL   yourself now"), true);
    assert.equal(hasBlockedTerm("what a Bitch."), true);
    assert.equal(hasBlockedTerm("the class starts at 8"), false);
    assert.equal(hasBlockedTerm("Dickens wrote it"), false);
    assert.equal(hasBlockedTerm(`يا ${BLOCKED_TERMS_AR[1]} يا`), true);
    assert.equal(hasBlockedTerm("صباح الخير"), false);
    assert.equal(hasBlockedTerm(""), false);
  });
});
