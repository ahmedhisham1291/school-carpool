import type { OutboxEvent } from "../../src/notifications/model";
import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";
import { blockId, muteId, type BlockRecord, type ChannelRecord, type ChatAccount, type ChatSettings, type MuteRecord, type ReportRecord, type RequestRecord } from "../../src/chat/model";
import type { ChatData, ChatHead, ChatMember, ChatProfile, ChatSummary, LastMessage, MemberPatch, StoredMessage, SummaryPatch } from "../../src/chat/data";
import type { AreaInfo, CarpoolInfo, ChatLimitKind, ChatStore, DrivingPauser, LatLng, SchoolName } from "../../src/chat/store";

const clone = <T>(v: T): T => structuredClone(v);

/** In-memory ChatStore for unit tests. */
export class MemoryChatStore implements ChatStore {
  accounts = new Map<string, ChatAccount>();
  childSchools = new Map<string, string[]>();
  drivingSchools = new Map<string, string[]>();
  points = new Map<string, LatLng>();
  schools = new Map<string, SchoolName>();
  areas: AreaInfo[] = [];
  carpools = new Map<string, CarpoolInfo>();
  /** carpoolId -> approved member uids */
  carpoolMembers = new Map<string, string[]>();
  channels = new Map<string, ChannelRecord>();
  groups = new Map<string, string[]>();
  requests = new Map<string, RequestRecord>();
  blocks = new Map<string, BlockRecord>();
  mutes = new Map<string, MuteRecord>();
  chatSettings = new Map<string, ChatSettings>();
  limits = new Map<string, WindowCounter>();
  reports = new Map<string, ReportRecord>();
  events = new Map<string, OutboxEvent>();
  private nextId = 1;

  /** A verified parent (fake data). */
  addParent(uid: string, extra: Partial<ChatAccount> = {}): ChatAccount {
    const a: ChatAccount = { uid, status: "verified", banned: false, firstName: `Name-${uid}`, parentId: `PID${uid.toUpperCase()}`.slice(0, 8), language: "ar", ...extra };
    this.accounts.set(uid, a);
    return a;
  }

  async account(uid: string) {
    return clone(this.accounts.get(uid) ?? null);
  }
  async childSchoolIds(uid: string) {
    return [...(this.childSchools.get(uid) ?? [])];
  }
  async allSchoolIds(uid: string) {
    return [...new Set([...(this.childSchools.get(uid) ?? []), ...(this.drivingSchools.get(uid) ?? [])])];
  }
  async roundedPoint(uid: string) {
    return clone(this.points.get(uid) ?? null);
  }
  async school(id: string) {
    return clone(this.schools.get(id) ?? null);
  }
  async areasOfSchool(schoolId: string) {
    return clone(this.areas.filter((a) => a.schoolId === schoolId));
  }
  async carpool(id: string) {
    return clone(this.carpools.get(id) ?? null);
  }
  async carpoolMemberUids(carpoolId: string) {
    return [...(this.carpoolMembers.get(carpoolId) ?? [])];
  }
  async carpoolIdsOf(uid: string) {
    return [...this.carpoolMembers.entries()].filter(([, m]) => m.includes(uid)).map(([id]) => id);
  }
  async channel(cid: string) {
    return clone(this.channels.get(cid) ?? null);
  }
  async updateChannel(cid: string, change: (c: ChannelRecord | null) => ChannelRecord | null) {
    const next = change(clone(this.channels.get(cid) ?? null));
    if (next) this.channels.set(cid, clone(next));
    return clone(next);
  }
  async channelsPage(afterCid: string | null, limit: number) {
    const all = [...this.channels.values()].sort((a, b) => (a.cid < b.cid ? -1 : 1));
    return clone(all.filter((c) => afterCid === null || c.cid > afterCid).slice(0, limit));
  }
  async groupsOf(uid: string) {
    return [...(this.groups.get(uid) ?? [])];
  }
  async putGroupsOf(uid: string, cids: string[]) {
    this.groups.set(uid, [...cids]);
  }
  async request(id: string) {
    return clone(this.requests.get(id) ?? null);
  }
  async putRequest(r: RequestRecord) {
    this.requests.set(r.id, clone(r));
  }
  async block(a: string, b: string) {
    return clone(this.blocks.get(blockId(a, b)) ?? null);
  }
  async putBlock(b: BlockRecord) {
    this.blocks.set(blockId(b.blockerUid, b.blockedUid), clone(b));
  }
  async deleteBlock(a: string, b: string) {
    this.blocks.delete(blockId(a, b));
  }
  async blockersOf(uid: string) {
    return [...this.blocks.values()].filter((b) => b.blockedUid === uid).map((b) => b.blockerUid);
  }
  async mute(uid: string, cid: string) {
    return this.mutes.get(muteId(uid, cid))?.muted ?? null;
  }
  async putMute(m: MuteRecord) {
    this.mutes.set(muteId(m.uid, m.cid), clone(m));
  }
  async muteChoices(cid: string) {
    return new Map([...this.mutes.values()].filter((m) => m.cid === cid).map((m) => [m.uid, m.muted] as [string, boolean]));
  }
  async settings(uid: string) {
    return clone(this.chatSettings.get(uid) ?? { requestsOff: false });
  }
  async putSettings(uid: string, s: ChatSettings) {
    this.chatSettings.set(uid, clone(s));
  }
  async takeLimit(uid: string, kind: ChatLimitKind, nowMs: number, rule: { windowMs: number; max: number }) {
    const key = `${uid}|${kind}`;
    const r = takeFromWindow(this.limits.get(key), nowMs, rule);
    if (r.allowed) this.limits.set(key, r.next);
    return { allowed: r.allowed, retryAfterMs: r.retryAfterMs };
  }
  async createReport(r: ReportRecord) {
    if (this.reports.has(r.id)) throw new Error("exists");
    this.reports.set(r.id, clone(r));
  }
  async report(id: string) {
    return clone(this.reports.get(id) ?? null);
  }
  async putReport(r: ReportRecord) {
    this.reports.set(r.id, clone(r));
  }
  newReportId() {
    return `r${this.nextId++}`;
  }
  async createEvent(e: OutboxEvent) {
    if (this.events.has(e.id)) return false;
    this.events.set(e.id, clone(e));
    return true;
  }
}

export class FakePauser implements DrivingPauser {
  paused: Array<{ uid: string; reportId: string }> = [];
  lifted: string[] = [];
  async pause(uid: string, reportId: string) {
    this.paused.push({ uid, reportId });
    return { carpools: 1, runs: 2 };
  }
  async lift(uid: string) {
    this.lifted.push(uid);
  }
}

/** In-memory ChatData (the documents the phone reads) for unit tests. */
export class MemoryChatData implements ChatData {
  profiles = new Map<string, ChatProfile>();
  heads = new Map<string, ChatHead>();
  /** "cid|uid" -> member */
  memberDocs = new Map<string, ChatMember>();
  /** "uid|cid" -> summary */
  summaries = new Map<string, ChatSummary>();
  /** cid -> messages, oldest first */
  messageDocs = new Map<string, StoredMessage[]>();
  deletedPhotos: string[] = [];
  /** Every write, for "nothing changed" checks. */
  writes = 0;

  async profile(uid: string) {
    return clone(this.profiles.get(uid) ?? null);
  }
  async head(cid: string) {
    return clone(this.heads.get(cid) ?? null);
  }
  async updateHead(cid: string, change: (c: ChatHead | null) => ChatHead | null) {
    const next = change(clone(this.heads.get(cid) ?? null));
    if (next) {
      this.heads.set(cid, clone(next));
      this.writes += 1;
    }
    return clone(next);
  }
  async member(cid: string, uid: string) {
    return clone(this.memberDocs.get(`${cid}|${uid}`) ?? null);
  }
  async putMember(cid: string, m: ChatMember) {
    this.memberDocs.set(`${cid}|${m.uid}`, clone(m));
    this.writes += 1;
  }
  async patchMember(cid: string, uid: string, patch: MemberPatch, nowMs: number) {
    const m = this.memberDocs.get(`${cid}|${uid}`);
    if (!m) return;
    this.memberDocs.set(`${cid}|${uid}`, { ...m, ...clone(patch), updatedAtMs: nowMs });
    this.writes += 1;
  }
  async members(cid: string, limit: number) {
    return clone([...this.memberDocs.entries()].filter(([k]) => k.startsWith(`${cid}|`)).map(([, m]) => m).slice(0, limit));
  }
  async chatsOf(uid: string, limit: number) {
    return [...this.memberDocs.keys()].filter((k) => k.endsWith(`|${uid}`)).map((k) => k.slice(0, k.length - uid.length - 1)).slice(0, limit);
  }
  async summary(uid: string, cid: string) {
    return clone(this.summaries.get(`${uid}|${cid}`) ?? null);
  }
  async putSummary(uid: string, s: ChatSummary) {
    this.summaries.set(`${uid}|${s.cid}`, clone(s));
    this.writes += 1;
  }
  async patchSummary(uid: string, cid: string, patch: SummaryPatch, nowMs: number) {
    const s = this.summaries.get(`${uid}|${cid}`);
    if (!s) return;
    this.summaries.set(`${uid}|${cid}`, { ...s, ...clone(patch), updatedAtMs: nowMs });
    this.writes += 1;
  }
  async deleteSummary(uid: string, cid: string) {
    this.summaries.delete(`${uid}|${cid}`);
  }
  async noteMessage(cid: string, uids: string[], senderUid: string, last: LastMessage, lastAtMs: number) {
    for (const uid of uids) {
      const s = this.summaries.get(`${uid}|${cid}`);
      if (!s) continue;
      this.summaries.set(`${uid}|${cid}`, { ...s, last: clone(last), lastAtMs, unread: s.unread + (uid === senderUid ? 0 : 1) });
      this.writes += 1;
    }
  }
  private list(cid: string): StoredMessage[] {
    return this.messageDocs.get(cid) ?? [];
  }
  async message(cid: string, id: string) {
    return clone(this.list(cid).find((m) => m.id === id) ?? null);
  }
  async messagesAround(cid: string, id: string, before: number, after: number) {
    const all = this.list(cid);
    const i = all.findIndex((m) => m.id === id);
    return i < 0 ? [] : clone(all.slice(Math.max(0, i - before), i + after + 1));
  }
  async latestMessage(cid: string) {
    const all = this.list(cid);
    return clone(all[all.length - 1] ?? null);
  }
  async createMessage(cid: string, m: StoredMessage) {
    if (this.list(cid).some((x) => x.id === m.id)) return false;
    this.messageDocs.set(cid, [...this.list(cid), clone(m)]);
    return true;
  }
  async deleteMessage(cid: string, id: string) {
    const found = this.list(cid).find((m) => m.id === id) ?? null;
    if (!found) return null;
    this.messageDocs.set(cid, this.list(cid).filter((m) => m.id !== id));
    if (found.photoPath) this.deletedPhotos.push(found.photoPath);
    return clone(found);
  }
  async messagesBy(uid: string, limit: number) {
    const out: Array<StoredMessage & { cid: string }> = [];
    for (const [cid, list] of this.messageDocs) for (const m of list) if (m.senderUid === uid) out.push({ ...clone(m), cid });
    return out.sort((a, b) => b.createdAtMs - a.createdAtMs).slice(0, limit);
  }
  async deleteMessagesBy(uid: string, limit: number) {
    let n = 0;
    for (const [cid, list] of this.messageDocs) {
      for (const m of list) {
        if (m.senderUid !== uid || n >= limit) continue;
        await this.deleteMessage(cid, m.id);
        n += 1;
      }
    }
    return n;
  }
  async deleteChat(cid: string) {
    for (const m of this.list(cid)) if (m.photoPath) this.deletedPhotos.push(m.photoPath);
    this.messageDocs.delete(cid);
    this.heads.delete(cid);
    for (const k of [...this.memberDocs.keys()]) {
      if (!k.startsWith(`${cid}|`)) continue;
      this.summaries.delete(`${k.slice(cid.length + 1)}|${cid}`);
      this.memberDocs.delete(k);
    }
  }
}
