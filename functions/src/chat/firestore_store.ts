import { FieldValue, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import { AREAS, REPORTS, SCHOOLS } from "../admin_panel/store";
import { carpoolFromDoc, CARPOOLS, MEMBERS, MEMBERSHIPS } from "../carpools/store";
import type { CarpoolDeps } from "../carpools/flow";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import { NOTIFICATION_EVENTS, outboxDoc } from "../notifications/outbox";
import type { OutboxEvent } from "../notifications/model";
import { pauseDriverRuns } from "../schedule/pause";
import { accountFromDoc } from "./sync";
import {
  blockId,
  CHAT_KINDS,
  isReportReason,
  isReportTarget,
  muteId,
  REQUEST_TTL_DAYS,
  type BlockRecord,
  type ChannelRecord,
  type ChatAccount,
  type ChatKind,
  type ChatSettings,
  type MessageSnapshot,
  type MuteRecord,
  type ReportRecord,
  type RequestRecord,
  type RequestStatus,
} from "./model";
import type { AreaInfo, CarpoolInfo, ChatLimitKind, ChatStore, DrivingPauser, LatLng, SchoolName } from "./store";

/**
 * Chat records in Firestore. Only Cloud Functions write them
 * (firestore.rules): the app reads its own requests, blocks, mutes and
 * settings.
 *
 * - chatChannels/{cid}: our registry of channels and members (Functions only)
 * - chatMemberships/{uid}: school and area groups a parent was put in (Functions only)
 * - chatRequests/{from}_{to}: private chat requests (both parents read; TTL)
 * - chatBlocks/{blocker}_{blocked}: blocks (the blocker reads)
 * - chatMutes/{uid}_{cid}: mute choices (the parent reads)
 * - chatSettings/{uid}: requests on or off (the parent reads)
 * - chatLimits/{uid}: counters (Functions only)
 * - reports/{id}: the admin queue (Prompt 4; admins via Functions only)
 */

export const CHAT_CHANNELS = "chatChannels";
export const CHAT_MEMBERSHIPS = "chatMemberships";
export const CHAT_REQUESTS = "chatRequests";
export const CHAT_BLOCKS = "chatBlocks";
export const CHAT_MUTES = "chatMutes";
export const CHAT_SETTINGS = "chatSettings";
export const CHAT_LIMITS = "chatLimits";
const CHILDREN = "children";
const PARENT_LOCATIONS = "parentLocations";
const DAY = 86_400_000;

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);

function ms(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function strings(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && x.length > 0) : [];
}

function point(v: unknown): LatLng | null {
  const p = v as { latitude?: unknown; longitude?: unknown } | null | undefined;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
}

function isAlreadyExists(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  return code === 6 || code === "already-exists";
}

export function channelToDoc(c: ChannelRecord): DocumentData {
  return {
    kind: c.kind,
    refId: c.refId,
    schoolId: c.schoolId,
    nameAr: c.nameAr,
    nameEn: c.nameEn,
    members: c.members,
    memberCount: c.members.length,
    excluded: c.excluded,
    frozen: c.frozen,
    createdAt: ts(c.createdAtMs),
    updatedAt: ts(c.updatedAtMs),
  };
}

export function channelFromDoc(cid: string, d: DocumentData): ChannelRecord | null {
  const kind = d.kind as ChatKind;
  if (!(CHAT_KINDS as readonly string[]).includes(kind)) return null;
  return {
    cid,
    kind,
    refId: text(d.refId) || null,
    schoolId: text(d.schoolId) || null,
    nameAr: text(d.nameAr),
    nameEn: text(d.nameEn),
    members: strings(d.members),
    excluded: strings(d.excluded),
    frozen: d.frozen === true,
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function requestToDoc(r: RequestRecord): DocumentData {
  return {
    fromUid: r.fromUid,
    toUid: r.toUid,
    fromFirstName: r.fromFirstName,
    toFirstName: r.toFirstName,
    status: r.status,
    cid: r.cid,
    createdAt: ts(r.createdAtMs),
    updatedAt: ts(r.updatedAtMs),
    // Firestore TTL (SETUP.md section 19).
    expiresAt: ts(r.updatedAtMs + REQUEST_TTL_DAYS * DAY),
  };
}

export function requestFromDoc(id: string, d: DocumentData): RequestRecord {
  const status = text(d.status);
  return {
    id,
    fromUid: text(d.fromUid),
    toUid: text(d.toUid),
    fromFirstName: text(d.fromFirstName),
    toFirstName: text(d.toFirstName),
    status: (["pending", "accepted", "declined", "cancelled"].includes(status) ? status : "cancelled") as RequestStatus,
    cid: text(d.cid) || null,
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

function snapshotToDoc(m: MessageSnapshot): DocumentData {
  return { ...m, createdAt: ts(m.createdAtMs) };
}

export function reportToDoc(r: ReportRecord): DocumentData {
  return {
    // Prompt 4's list reads these.
    reporterId: r.reporterUid,
    targetType: r.targetType,
    targetId: r.targetId,
    reason: r.reason,
    status: r.status,
    createdAt: ts(r.createdAtMs),
    // Prompt 9.
    source: "chat",
    subjectUid: r.subjectUid,
    cid: r.cid,
    kind: r.kind,
    note: r.note,
    urgent: r.urgent,
    context: r.context.map(snapshotToDoc),
    pausedDriving: r.pausedDriving,
    outcome: r.outcome,
    handledBy: r.handledBy,
    handledAt: r.handledAtMs === null ? null : ts(r.handledAtMs),
  };
}

export function reportFromDoc(id: string, d: DocumentData): ReportRecord | null {
  if (!isReportTarget(d.targetType) || !isReportReason(d.reason)) return null;
  const kind = d.kind as ChatKind;
  const context = Array.isArray(d.context) ? (d.context as DocumentData[]) : [];
  return {
    id,
    reporterUid: text(d.reporterId),
    targetType: d.targetType,
    targetId: text(d.targetId),
    subjectUid: text(d.subjectUid) || null,
    cid: text(d.cid),
    kind: (CHAT_KINDS as readonly string[]).includes(kind) ? kind : "private",
    reason: d.reason,
    note: text(d.note),
    urgent: d.urgent === true,
    status: d.status === "handled" ? "handled" : "open",
    context: context.map((c) => ({
      id: text(c.id),
      authorUid: text(c.authorUid),
      authorName: text(c.authorName),
      authorParentId: text(c.authorParentId),
      text: text(c.text),
      attachment: text(c.attachment) || null,
      createdAtMs: ms(c.createdAt),
      reported: c.reported === true,
    })),
    pausedDriving: d.pausedDriving === true,
    outcome: text(d.outcome) || null,
    handledBy: text(d.handledBy) || null,
    createdAtMs: ms(d.createdAt),
    handledAtMs: d.handledAt ? ms(d.handledAt) : null,
  };
}

export class FirestoreChatStore implements ChatStore {
  constructor(private readonly db: Firestore) {}

  async account(uid: string): Promise<ChatAccount | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    return snap.exists ? accountFromDoc(uid, snap.data()) : null;
  }

  async childSchoolIds(uid: string): Promise<string[]> {
    const snap = await this.db.collection(CHILDREN).where("ownerUid", "==", uid).limit(20).get();
    const ids = snap.docs.filter((d) => d.get("status") === "approved").map((d) => text(d.get("schoolId")));
    return [...new Set(ids.filter((id) => id.length > 0))];
  }

  async allSchoolIds(uid: string): Promise<string[]> {
    const snap = await this.db.collection(PARENT_LOCATIONS).doc(uid).get();
    const fromMap = snap.exists ? strings(snap.get("schoolIds")) : [];
    return [...new Set([...fromMap, ...(await this.childSchoolIds(uid))])];
  }

  async roundedPoint(uid: string): Promise<LatLng | null> {
    const snap = await this.db.collection(PARENT_LOCATIONS).doc(uid).get();
    return snap.exists ? point(snap.get("point")) : null;
  }

  async school(id: string): Promise<SchoolName | null> {
    const snap = await this.db.collection(SCHOOLS).doc(id).get();
    if (!snap.exists || snap.get("status") !== "active") return null;
    return { id, nameAr: text(snap.get("nameAr")), nameEn: text(snap.get("nameEn")) };
  }

  async areasOfSchool(schoolId: string): Promise<AreaInfo[]> {
    const snap = await this.db.collection(AREAS).where("schoolId", "==", schoolId).limit(200).get();
    return snap.docs.map((d) => ({
      id: d.id,
      schoolId,
      nameAr: text(d.get("nameAr")),
      nameEn: text(d.get("nameEn")),
      center: point(d.get("center")),
    }));
  }

  async carpool(id: string): Promise<CarpoolInfo | null> {
    const snap = await this.db.collection(CARPOOLS).doc(id).get();
    if (!snap.exists) return null;
    const c = carpoolFromDoc(id, snap.data() ?? {});
    const place = c.activity?.name;
    const time = c.morning ?? c.afternoon ?? "";
    const suffix = time ? ` · ${time}` : "";
    return {
      id,
      nameAr: (place || c.schoolNameAr || c.schoolNameEn) + suffix,
      nameEn: (place || c.schoolNameEn || c.schoolNameAr) + suffix,
      active: c.status === "active",
    };
  }

  async carpoolMemberUids(carpoolId: string): Promise<string[]> {
    const snap = await this.db.collection(CARPOOLS).doc(carpoolId).collection(MEMBERS).limit(50).get();
    return snap.docs.map((d) => d.id);
  }

  async carpoolIdsOf(uid: string): Promise<string[]> {
    const snap = await this.db.collection(MEMBERSHIPS).where("uid", "==", uid).limit(200).get();
    return snap.docs.filter((d) => d.get("status") === "approved").map((d) => text(d.get("carpoolId"))).filter((id) => id.length > 0);
  }

  async channel(cid: string): Promise<ChannelRecord | null> {
    const snap = await this.db.collection(CHAT_CHANNELS).doc(cid).get();
    return snap.exists ? channelFromDoc(cid, snap.data() ?? {}) : null;
  }

  updateChannel(cid: string, change: (current: ChannelRecord | null) => ChannelRecord | null): Promise<ChannelRecord | null> {
    const ref = this.db.collection(CHAT_CHANNELS).doc(cid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const current = snap.exists ? channelFromDoc(cid, snap.data() ?? {}) : null;
      const next = change(current);
      if (next) tx.set(ref, channelToDoc(next));
      return next;
    });
  }

  async channelsPage(afterCid: string | null, limit: number): Promise<ChannelRecord[]> {
    let query = this.db.collection(CHAT_CHANNELS).orderBy("__name__").limit(limit);
    if (afterCid) {
      const last = await this.db.collection(CHAT_CHANNELS).doc(afterCid).get();
      if (last.exists) query = query.startAfter(last);
    }
    const snap = await query.get();
    return snap.docs.map((d) => channelFromDoc(d.id, d.data())).filter((c): c is ChannelRecord => c !== null);
  }

  async groupsOf(uid: string): Promise<string[]> {
    const snap = await this.db.collection(CHAT_MEMBERSHIPS).doc(uid).get();
    return snap.exists ? strings(snap.get("groups")) : [];
  }

  async putGroupsOf(uid: string, cids: string[], nowMs: number): Promise<void> {
    await this.db.collection(CHAT_MEMBERSHIPS).doc(uid).set({ groups: cids, updatedAt: ts(nowMs) });
  }

  async request(id: string): Promise<RequestRecord | null> {
    const snap = await this.db.collection(CHAT_REQUESTS).doc(id).get();
    return snap.exists ? requestFromDoc(id, snap.data() ?? {}) : null;
  }

  async putRequest(r: RequestRecord): Promise<void> {
    await this.db.collection(CHAT_REQUESTS).doc(r.id).set(requestToDoc(r));
  }

  async block(blockerUid: string, blockedUid: string): Promise<BlockRecord | null> {
    const snap = await this.db.collection(CHAT_BLOCKS).doc(blockId(blockerUid, blockedUid)).get();
    if (!snap.exists) return null;
    return { blockerUid, blockedUid, blockedFirstName: text(snap.get("blockedFirstName")), createdAtMs: ms(snap.get("createdAt")) };
  }

  async putBlock(b: BlockRecord): Promise<void> {
    await this.db.collection(CHAT_BLOCKS).doc(blockId(b.blockerUid, b.blockedUid)).set({
      blockerUid: b.blockerUid,
      blockedUid: b.blockedUid,
      blockedFirstName: b.blockedFirstName,
      createdAt: ts(b.createdAtMs),
    });
  }

  async deleteBlock(blockerUid: string, blockedUid: string): Promise<void> {
    await this.db.collection(CHAT_BLOCKS).doc(blockId(blockerUid, blockedUid)).delete();
  }

  async blockersOf(uid: string): Promise<string[]> {
    const snap = await this.db.collection(CHAT_BLOCKS).where("blockedUid", "==", uid).limit(500).get();
    return snap.docs.map((d) => text(d.get("blockerUid"))).filter((u) => u.length > 0);
  }

  async mute(uid: string, cid: string): Promise<boolean | null> {
    const snap = await this.db.collection(CHAT_MUTES).doc(muteId(uid, cid)).get();
    return snap.exists && typeof snap.get("muted") === "boolean" ? (snap.get("muted") as boolean) : null;
  }

  async putMute(m: MuteRecord): Promise<void> {
    await this.db.collection(CHAT_MUTES).doc(muteId(m.uid, m.cid)).set({ uid: m.uid, cid: m.cid, muted: m.muted, updatedAt: ts(m.updatedAtMs) });
  }

  async muteChoices(cid: string): Promise<Map<string, boolean>> {
    const snap = await this.db.collection(CHAT_MUTES).where("cid", "==", cid).limit(5_000).get();
    const out = new Map<string, boolean>();
    for (const d of snap.docs) {
      const uid = text(d.get("uid"));
      if (uid && typeof d.get("muted") === "boolean") out.set(uid, d.get("muted") as boolean);
    }
    return out;
  }

  async settings(uid: string): Promise<ChatSettings> {
    const snap = await this.db.collection(CHAT_SETTINGS).doc(uid).get();
    return { requestsOff: snap.exists && snap.get("requestsOff") === true };
  }

  async putSettings(uid: string, s: ChatSettings, nowMs: number): Promise<void> {
    await this.db.collection(CHAT_SETTINGS).doc(uid).set({ requestsOff: s.requestsOff, updatedAt: ts(nowMs) });
  }

  takeLimit(uid: string, kind: ChatLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(CHAT_LIMITS).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const raw = (snap.exists ? snap.get(kind) : undefined) as { windowStartMs?: unknown; count?: unknown } | undefined;
      const current: WindowCounter | undefined =
        raw && typeof raw.windowStartMs === "number" && typeof raw.count === "number" ? { windowStartMs: raw.windowStartMs, count: raw.count } : undefined;
      const result = takeFromWindow(current, nowMs, rule);
      if (result.allowed) tx.set(ref, { ...(snap.exists ? snap.data() : {}), [kind]: result.next });
      return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
    });
  }

  async createReport(r: ReportRecord): Promise<void> {
    await this.db.collection(REPORTS).doc(r.id).create(reportToDoc(r));
  }

  async report(id: string): Promise<ReportRecord | null> {
    const snap = await this.db.collection(REPORTS).doc(id).get();
    return snap.exists ? reportFromDoc(id, snap.data() ?? {}) : null;
  }

  async putReport(r: ReportRecord): Promise<void> {
    await this.db.collection(REPORTS).doc(r.id).set(reportToDoc(r));
  }

  newReportId(): string {
    return this.db.collection(REPORTS).doc().id;
  }

  async createEvent(e: OutboxEvent): Promise<boolean> {
    try {
      await this.db.collection(NOTIFICATION_EVENTS).doc(e.id).create(outboxDoc(e));
      return true;
    } catch (error) {
      if (isAlreadyExists(error)) return false;
      throw error;
    }
  }
}

/**
 * Urgent reports: marks the parent's record (`drivingPaused`, read by the
 * schedule as "cannot drive") and frees their runs (Prompt 7 release).
 */
export class FirestoreDrivingPauser implements DrivingPauser {
  constructor(
    private readonly db: Firestore,
    private readonly carpoolDeps: () => CarpoolDeps,
  ) {}

  async pause(uid: string, reportId: string): Promise<{ carpools: number; runs: number }> {
    await this.db.collection(USERS).doc(uid).update({
      drivingPaused: true,
      drivingPausedAt: FieldValue.serverTimestamp(),
      drivingPauseReportId: reportId,
    });
    return pauseDriverRuns(this.carpoolDeps(), uid);
  }

  async lift(uid: string): Promise<void> {
    await this.db.collection(USERS).doc(uid).update({
      drivingPaused: FieldValue.delete(),
      drivingPausedAt: FieldValue.delete(),
      drivingPauseReportId: FieldValue.delete(),
    });
  }
}
