import { distanceKm } from "../maps/geo";
import type { ChatServer } from "./server";
import type { AreaInfo, ChatStore } from "./store";
import {
  AREA_MAX_KM,
  channelRef,
  chatEligible,
  groupChannelId,
  MAX_GROUP_MEMBERS,
  type ChannelRecord,
  type ChannelRef,
  type ChatAccount,
  type ChatKind,
} from "./model";

/**
 * Channel membership (F9, F10), kept in step by Cloud Functions only:
 * - access: a parent who stops being verified, is suspended, banned or
 *   deleted is cut off at once (every member document marked `cut`, which
 *   the rules read on each request); a parent verified again is restored;
 * - school and area groups: every verified parent is in the school group of
 *   each child's school, and in the area group of that school whose center
 *   is nearest their rounded home point (within AREA_MAX_KM);
 * - carpool chat: the carpool's approved members (Prompt 6 changes).
 * Every step is idempotent: a retried trigger does nothing twice.
 */

export interface SyncDeps {
  store: ChatStore;
  server: ChatServer;
  now: () => number;
  log: (message: string, data?: Record<string, unknown>) => void;
}

export interface GroupTarget {
  ref: ChannelRef;
  refId: string;
  schoolId: string;
  nameAr: string;
  nameEn: string;
}

/** Registry record for a new channel. */
export function newChannel(ref: ChannelRef, refId: string | null, schoolId: string | null, nameAr: string, nameEn: string, nowMs: number): ChannelRecord {
  return {
    cid: ref.cid,
    kind: ref.kind,
    refId,
    schoolId,
    nameAr,
    nameEn,
    members: [],
    excluded: [],
    frozen: false,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  };
}

/** Creates the chat when it is new and records [uid] as a member (or not). */
export type MemberOutcome = "added" | "removed" | "unchanged" | "excluded";

export async function setMember(
  deps: SyncDeps,
  ref: ChannelRef,
  init: () => ChannelRecord,
  uid: string,
  member: boolean,
): Promise<MemberOutcome> {
  // Set inside the transaction callback (which may run more than once).
  const state: { outcome: MemberOutcome; created: boolean } = { outcome: "unchanged", created: false };
  const saved = await deps.store.updateChannel(ref.cid, (current) => {
    state.created = current === null;
    const rec = current ?? init();
    const has = rec.members.includes(uid);
    if (member && rec.excluded.includes(uid)) {
      state.outcome = "excluded";
      return state.created ? rec : null;
    }
    if (member === has || (member && rec.members.length >= MAX_GROUP_MEMBERS)) {
      state.outcome = "unchanged";
      return state.created ? rec : null;
    }
    state.outcome = member ? "added" : "removed";
    const members = member ? [...rec.members, uid] : rec.members.filter((u) => u !== uid);
    return { ...rec, members, updatedAtMs: deps.now() };
  });
  if (!saved) return state.outcome;
  const data = { nameAr: saved.nameAr, nameEn: saved.nameEn, kind: ref.kind, refId: saved.refId };
  if (state.created) {
    // New chat: created with its members in one call.
    await deps.server.ensureChannel(ref.type, ref.id, data, saved.members);
    return state.outcome;
  }
  if (state.outcome === "added") {
    await deps.server.ensureChannel(ref.type, ref.id, data, []);
    await deps.server.addMembers(ref.type, ref.id, [uid]);
  } else if (state.outcome === "removed") {
    await deps.server.removeMembers(ref.type, ref.id, [uid]);
  }
  return state.outcome;
}

/** The nearest area of [schoolId] to [point], within AREA_MAX_KM. */
export function nearestArea(areas: AreaInfo[], point: { lat: number; lng: number }): AreaInfo | null {
  let best: AreaInfo | null = null;
  let bestKm = Infinity;
  for (const a of areas) {
    if (!a.center) continue;
    const km = distanceKm(a.center, point);
    if (km <= AREA_MAX_KM && km < bestKm) {
      best = a;
      bestKm = km;
    }
  }
  return best;
}

/** The school and area groups [uid] should be in now (none when not eligible). */
export async function desiredGroups(store: ChatStore, uid: string, account: ChatAccount | null): Promise<GroupTarget[]> {
  if (!chatEligible(account)) return [];
  const out: GroupTarget[] = [];
  const point = await store.roundedPoint(uid);
  for (const schoolId of (await store.childSchoolIds(uid)).slice(0, 10)) {
    const school = await store.school(schoolId);
    if (!school) continue;
    out.push({ ref: channelRef("school", groupChannelId("school", schoolId)), refId: schoolId, schoolId, nameAr: school.nameAr, nameEn: school.nameEn });
    if (!point) continue;
    const area = nearestArea(await store.areasOfSchool(schoolId), point);
    if (area) {
      out.push({ ref: channelRef("area", groupChannelId("area", area.id)), refId: area.id, schoolId, nameAr: area.nameAr, nameEn: area.nameEn });
    }
  }
  return out;
}

/**
 * Puts [uid] in the school and area groups they belong to and out of the
 * ones they no longer belong to. Returns the counts.
 */
export async function syncParentGroups(deps: SyncDeps, uid: string): Promise<{ added: number; removed: number }> {
  const account = await deps.store.account(uid);
  const want = await desiredGroups(deps.store, uid, account);
  const had = new Set(await deps.store.groupsOf(uid));
  const wantCids = new Set(want.map((g) => g.ref.cid));
  let added = 0;
  let removed = 0;
  const nowMs = deps.now();
  for (const g of want) {
    const r = await setMember(deps, g.ref, () => newChannel(g.ref, g.refId, g.schoolId, g.nameAr, g.nameEn, nowMs), uid, true);
    if (r === "added") added += 1;
  }
  for (const cid of had) {
    if (wantCids.has(cid)) continue;
    const ref = parseGroupCid(cid);
    if (!ref) continue;
    const r = await setMember(deps, ref, () => newChannel(ref, null, null, "", "", nowMs), uid, false);
    if (r === "removed") removed += 1;
  }
  const next = [...wantCids].sort();
  const prev = [...had].sort();
  if (next.join("|") !== prev.join("|")) await deps.store.putGroupsOf(uid, next, nowMs);
  return { added, removed };
}

function parseGroupCid(cid: string): ChannelRef | null {
  const at = cid.indexOf(":");
  if (at <= 0) return null;
  const id = cid.slice(at + 1);
  const kind: ChatKind | null = id.startsWith("s-") ? "school" : id.startsWith("a-") ? "area" : null;
  return kind ? channelRef(kind, id) : null;
}

/** Carpool chat (F10): [uid] in or out of [carpoolId]'s chat. */
export async function syncCarpoolMember(deps: SyncDeps, carpoolId: string, uid: string, member: boolean): Promise<string> {
  const ref = channelRef("carpool", groupChannelId("carpool", carpoolId));
  const account = member ? await deps.store.account(uid) : null;
  const carpool = member ? await deps.store.carpool(carpoolId) : null;
  const shouldBe = member && chatEligible(account) && !!carpool?.active;
  const nowMs = deps.now();
  const init = () => newChannel(ref, carpoolId, null, carpool?.nameAr ?? "", carpool?.nameEn ?? "", nowMs);
  if (!shouldBe) {
    const existing = await deps.store.channel(ref.cid);
    if (!existing) return "unchanged";
  }
  return setMember(deps, ref, init, uid, shouldBe);
}

/** Every carpool chat of [uid] (after re-verification, and the app's "sync my chats"). */
export async function syncCarpoolsOf(deps: SyncDeps, uid: string): Promise<number> {
  let changed = 0;
  for (const carpoolId of (await deps.store.carpoolIdsOf(uid)).slice(0, 20)) {
    const r = await syncCarpoolMember(deps, carpoolId, uid, true);
    if (r === "added") changed += 1;
  }
  return changed;
}

export interface AccessChange {
  before: ChatAccount | null;
  after: ChatAccount | null;
}

/** Fields of the users/{uid} record that matter to chat. */
export function accountFromDoc(uid: string, d: Record<string, unknown> | undefined): ChatAccount | null {
  if (!d) return null;
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  return {
    uid,
    status: str(d.status) || "unverified",
    banned: d.banned === true,
    firstName: str(d.firstName),
    parentId: str(d.parentId),
    language: d.language === "en" ? "en" : "ar",
  };
}

/** Whether a users/{uid} write changes anything for chat. */
export function chatRelevant(change: AccessChange): boolean {
  const b = change.before;
  const a = change.after;
  if (!b || !a) return b !== a;
  return (
    chatEligible(b) !== chatEligible(a) ||
    (chatEligible(a) && b.firstName !== a.firstName)
  );
}

/**
 * A users/{uid} write. Lost eligibility (suspended, banned, unverified,
 * deleted): cut off in every chat AT ONCE, then the groups are left. Became
 * eligible again: restored, first name saved and the groups and carpool
 * chats synced.
 */
export async function syncAccess(deps: SyncDeps, uid: string, change: AccessChange): Promise<"cut-off" | "restored" | "profile" | "none"> {
  if (!chatRelevant(change)) return "none";
  const wasIn = chatEligible(change.before);
  const isIn = chatEligible(change.after);
  if (wasIn && !isIn) {
    await deps.server.deactivateUser(uid);
    await syncParentGroups(deps, uid);
    deps.log("chat access removed", { reason: change.after ? (change.after.banned ? "banned" : change.after.status) : "deleted" });
    return "cut-off";
  }
  if (!isIn || !change.after) return "none";
  const a = change.after;
  if (!wasIn) {
    await deps.server.reactivateUser(uid);
    await deps.server.upsertUser({ id: uid, name: a.firstName });
    await syncParentGroups(deps, uid);
    await syncCarpoolsOf(deps, uid);
    return "restored";
  }
  await deps.server.upsertUser({ id: uid, name: a.firstName });
  return "profile";
}
