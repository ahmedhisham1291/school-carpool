import type { ChildLite, FlagOutcome, RatingFlag, RatingRecord, TrustAccount, TrustLimitKind, TrustStore, YearChange } from "../../src/trust/flow";
import type { JobStore, UserRow, VehicleRow } from "../../src/trust/jobs";
import { TrustError, type GuardianLink, type GuardianRequest, type TripLike, type TrustSummary } from "../../src/trust/model";
import type { PhoneAccount, PhoneChangeStore, PhoneFiles } from "../../src/trust/phone";
import type { OutboxEvent } from "../../src/notifications/model";
import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";

const clone = <T>(v: T): T => structuredClone(v);

/** In-memory trust store for unit tests (fake data only). */
export class MemoryTrustStore implements TrustStore, JobStore, PhoneChangeStore {
  accounts = new Map<string, TrustAccount & { phone: string | null }>();
  parentIds = new Map<string, string>();
  trips: TripLike[] = [];
  ratings = new Map<string, RatingRecord>();
  summaries = new Map<string, TrustSummary>();
  flagsById = new Map<string, RatingFlag>();
  /** uid -> carpool IDs (approved). */
  carpoolsOf = new Map<string, string[]>();
  children = new Map<string, ChildLite>();
  links = new Map<string, GuardianLink>();
  requests = new Map<string, GuardianRequest>();
  events: OutboxEvent[] = [];
  audits: Array<{ actorUid: string; action: string; target: string }> = [];
  limits = new Map<string, WindowCounter>();
  vehicleRows: VehicleRow[] = [];
  phonesTaken = new Map<string, string>();
  reports: string[] = [];
  phoneChanges: Array<{ uid: string; phone: string }> = [];

  addParent(uid: string, extra: Partial<TrustAccount & { phone: string | null }> = {}): void {
    const parentId = extra.parentId ?? `P${uid.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g, "Z")}ZZZZZZZ`.slice(0, 8);
    this.accounts.set(uid, {
      uid,
      status: "verified",
      firstName: uid.charAt(0).toUpperCase() + uid.slice(1),
      parentId,
      verifiedOn: "2026-01-10",
      yearConfirmed: null,
      yearCheckOverdue: false,
      phone: `+2010000000${this.accounts.size}`,
      ...extra,
    });
    this.parentIds.set(parentId, uid);
  }

  addChild(c: Partial<ChildLite> & { id: string; ownerUid: string }): void {
    this.children.set(c.id, { firstName: c.id, grade: "g3", schoolId: "nile", schoolName: "Nile", status: "approved", ...c });
  }

  async account(uid: string) {
    return clone(this.accounts.get(uid) ?? null);
  }
  async accountByParentId(parentId: string) {
    const uid = this.parentIds.get(parentId);
    return uid ? this.account(uid) : null;
  }
  async finishedTrips(uid: string, sinceDate: string): Promise<TripLike[]> {
    return clone(this.trips.filter((t) => t.status === "ended" && t.date >= sinceDate && (t.driverUid === uid || t.stops.some((s) => s.parentUid === uid))));
  }
  async ratedIn(raterUid: string, month: string): Promise<string[]> {
    return [...this.ratings.values()].filter((r) => r.raterUid === raterUid && r.month === month).map((r) => r.rateeUid);
  }
  async tripRated(raterUid: string, rateeUid: string, tripId: string): Promise<boolean> {
    return [...this.ratings.values()].some((r) => r.raterUid === raterUid && r.rateeUid === rateeUid && r.tripId === tripId);
  }
  async saveRating(r: RatingRecord, update: (s: TrustSummary | null) => TrustSummary, flag: RatingFlag | null): Promise<void> {
    if (this.ratings.has(r.id) || (await this.tripRated(r.raterUid, r.rateeUid, r.tripId))) throw new TrustError("already-rated");
    this.ratings.set(r.id, clone(r));
    this.summaries.set(r.rateeUid, update(clone(this.summaries.get(r.rateeUid) ?? null)));
    if (flag) this.flagsById.set(flag.id, clone(flag));
  }
  async summary(uid: string) {
    return clone(this.summaries.get(uid) ?? null);
  }
  async shareCarpool(a: string, b: string): Promise<boolean> {
    const theirs = this.carpoolsOf.get(b) ?? [];
    return (this.carpoolsOf.get(a) ?? []).some((c) => theirs.includes(c));
  }
  async childrenOf(ownerUid: string): Promise<ChildLite[]> {
    return clone([...this.children.values()].filter((c) => c.ownerUid === ownerUid));
  }
  async approvedChildCount(uid: string): Promise<number> {
    return (await this.childrenOf(uid)).filter((c) => c.status === "approved").length;
  }
  async linksOfChild(childId: string) {
    return clone([...this.links.values()].filter((l) => l.childId === childId));
  }
  async linksAs(uid: string, side: "owner" | "guardian") {
    return clone([...this.links.values()].filter((l) => (side === "owner" ? l.ownerUid : l.guardianUid) === uid));
  }
  async link(id: string) {
    return clone(this.links.get(id) ?? null);
  }
  async guardianRequest(id: string) {
    return clone(this.requests.get(id) ?? null);
  }
  async guardianRequestsAs(uid: string, side: "owner" | "guardian") {
    return clone([...this.requests.values()].filter((r) => (side === "owner" ? r.ownerUid : r.guardianUid) === uid));
  }
  async putGuardianRequest(r: GuardianRequest, notice: OutboxEvent | null, expect?: GuardianRequest["status"] | null): Promise<void> {
    if (expect !== undefined && (this.requests.get(r.id)?.status ?? null) !== expect) throw new TrustError("invalid-state");
    this.requests.set(r.id, clone(r));
    if (notice) this.events.push(notice);
  }
  async decideGuardianRequest(r: GuardianRequest, links: GuardianLink[], notices: OutboxEvent[]): Promise<void> {
    if (this.requests.get(r.id)?.status !== "requested") throw new TrustError("invalid-state");
    this.requests.set(r.id, clone(r));
    for (const l of links) this.links.set(l.id, clone(l));
    this.events.push(...notices);
  }
  async putLink(l: GuardianLink, expect: GuardianLink["status"], notice: OutboxEvent | null): Promise<void> {
    if (this.links.get(l.id)?.status !== expect) throw new TrustError("invalid-state");
    this.links.set(l.id, clone(l));
    if (notice) this.events.push(notice);
  }
  async linksInReview(limit: number) {
    return clone([...this.links.values()].filter((l) => l.status === "review").slice(0, limit));
  }
  async saveYear(uid: string, year: number, changes: YearChange[]): Promise<void> {
    for (const c of changes) {
      const child = this.children.get(c.childId);
      if (!child || child.ownerUid !== uid || child.status !== "approved") throw new TrustError("children-changed");
    }
    for (const c of changes) {
      const child = this.children.get(c.childId) as ChildLite;
      if (c.grade === null) child.status = "left";
      else child.grade = c.grade;
    }
    const a = this.accounts.get(uid);
    if (a) {
      a.yearConfirmed = year;
      a.yearCheckOverdue = false;
    }
    this.audits.push({ actorUid: uid, action: "school-year.confirm", target: `users/${uid}` });
  }
  async flags(status: "open" | "handled", limit: number) {
    return clone([...this.flagsById.values()].filter((f) => f.status === status).slice(0, limit));
  }
  async resolveFlag(id: string, outcome: FlagOutcome): Promise<RatingFlag> {
    const f = this.flagsById.get(id);
    if (!f) throw new TrustError("not-found");
    if (f.status !== "open") throw new TrustError("invalid-state");
    f.status = "handled";
    f.outcome = outcome;
    return clone(f);
  }
  async takeLimit(uid: string, kind: TrustLimitKind, nowMs: number, rule: { windowMs: number; max: number }) {
    const key = `${uid}:${kind}`;
    const r = takeFromWindow(this.limits.get(key), nowMs, rule);
    if (r.allowed) this.limits.set(key, r.next);
    return { allowed: r.allowed, retryAfterMs: r.retryAfterMs };
  }
  async audit(entry: { actorUid: string; action: string; target: string }): Promise<void> {
    this.audits.push({ actorUid: entry.actorUid, action: entry.action, target: entry.target });
  }

  // jobs
  async vehicles(afterUid: string | null, limit: number) {
    const sorted = [...this.vehicleRows].sort((a, b) => a.uid.localeCompare(b.uid)).filter((r) => afterUid === null || r.uid > afterUid);
    const rows = sorted.slice(0, limit);
    return { rows: clone(rows), last: sorted.length > limit ? rows[rows.length - 1].uid : null };
  }
  async verifiedUsers(afterUid: string | null, limit: number) {
    const sorted = [...this.accounts.values()]
      .filter((a) => a.status === "verified")
      .sort((a, b) => a.uid.localeCompare(b.uid))
      .filter((a) => afterUid === null || a.uid > afterUid);
    const rows: UserRow[] = sorted.slice(0, limit).map((a) => ({ uid: a.uid, verifiedOn: a.verifiedOn, yearConfirmed: a.yearConfirmed, yearCheckOverdue: a.yearCheckOverdue }));
    return { rows, last: sorted.length > limit ? rows[rows.length - 1].uid : null };
  }
  async createEvent(e: OutboxEvent): Promise<boolean> {
    if (this.events.some((x) => x.id === e.id)) return false;
    this.events.push(e);
    return true;
  }
  async setYearCheckOverdue(uid: string, overdue: boolean): Promise<void> {
    const a = this.accounts.get(uid);
    if (a) a.yearCheckOverdue = overdue;
  }

  // phone change
  async uidByPhone(phone: string): Promise<string | null> {
    for (const a of this.accounts.values()) if (a.phone === phone) return a.uid;
    return this.phonesTaken.get(phone) ?? null;
  }
  async changePhone(uid: string, phone: string, notice: OutboxEvent): Promise<void> {
    const a = this.accounts.get(uid) as PhoneAccount;
    a.phone = phone;
    this.phoneChanges.push({ uid, phone });
    this.events.push(notice);
  }
  async reportMismatch(uid: string): Promise<void> {
    this.reports.push(uid);
  }
}

export class MemoryFiles implements PhoneFiles {
  files = new Map<string, { data: Buffer; createdMs: number }>();
  deleted: string[] = [];
  async createdMs(path: string) {
    return this.files.get(path)?.createdMs ?? null;
  }
  async read(path: string) {
    const f = this.files.get(path);
    if (!f) throw new Error("missing");
    return f.data;
  }
  async delete(path: string) {
    this.files.delete(path);
    this.deleted.push(path);
  }
  async exists(path: string) {
    return this.files.has(path);
  }
}
