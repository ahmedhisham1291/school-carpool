import type { OutboxEvent } from "../../src/notifications/model";
import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";
import { blockId, muteId, type BlockRecord, type ChannelRecord, type ChatAccount, type ChatSettings, type MuteRecord, type ReportRecord, type RequestRecord } from "../../src/chat/model";
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
