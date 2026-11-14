import { GeoPoint, Timestamp, type DocumentData, type DocumentReference, type Firestore, type Transaction } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import { AREAS, SCHOOLS } from "../admin_panel/store";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import { HOMES } from "../maps/store";
import { CHILDREN, VEHICLES } from "../verification/store";
import type { LatLng } from "../maps/geo";
import type { AccountInfo, AreaInfo, CarpoolLimitKind, CarpoolStore, CarpoolTx, ChildInfo, PickupPoint, RunRef, SchoolInfo } from "./flow";
import type { BalanceRecord, ExceptionRecord, RunRecord, ScheduleEvent, SwapRecord } from "../schedule/model";
import {
  BALANCES,
  balanceFromDoc,
  balanceToDoc,
  eventToDoc,
  EXCEPTIONS,
  exceptionFromDoc,
  exceptionToDoc,
  runFromDoc,
  runToDoc,
  SCHEDULE,
  SCHEDULE_EVENTS,
  swapFromDoc,
  SWAPS,
  swapToDoc,
} from "../schedule/store";
import {
  CARPOOL_RULES,
  consentId,
  CONTRIBUTION_PERIODS,
  DAYS,
  membershipId,
  type CarInfo,
  type CarpoolRecord,
  type CarpoolRule,
  type ChildRef,
  type ConsentRecord,
  type Contribution,
  type ContributionPeriod,
  type Day,
  type InviteRecord,
  type MemberRecord,
  type MembershipRecord,
  type MembershipStatus,
  type RequestRecord,
  type VehicleInfo,
  type WantedRecord,
} from "./model";

export const CARPOOLS = "carpools";
export const MEMBERSHIPS = "memberships";
export const MEMBERS = "members";
export const REQUESTS = "requests";
export const DRIVER_CONSENTS = "driverConsents";
export const PICKUP_POINTS = "pickupPoints";
export const CARPOOL_INVITES = "carpoolInvites";
export const CARPOOL_LIMITS = "carpoolLimits";
export const CARPOOL_WANTED = "carpoolWanted";

// --- field helpers ----------------------------------------------------------

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function textOrNull(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function ms(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function msOrNull(v: unknown): number | null {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : null;
}

function ts(msValue: number): Timestamp {
  return Timestamp.fromMillis(msValue);
}

function tsOrNull(msValue: number | null): Timestamp | null {
  return msValue === null ? null : Timestamp.fromMillis(msValue);
}

function point(v: unknown): LatLng | null {
  const p = v as { latitude?: unknown; longitude?: unknown } | null | undefined;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
}

function days(v: unknown): Day[] {
  return Array.isArray(v) ? DAYS.filter((d) => v.includes(d)) : [];
}

function rules(v: unknown): CarpoolRule[] {
  return Array.isArray(v) ? CARPOOL_RULES.filter((r) => v.includes(r)) : [];
}

function childRefs(v: unknown): ChildRef[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((x) => (typeof x === "object" && x !== null ? (x as Record<string, unknown>) : {}))
    .filter((x) => typeof x.id === "string")
    .map((x) => ({ id: x.id as string, firstName: text(x.firstName), grade: text(x.grade) }));
}

function car(v: unknown): CarInfo | null {
  const c = v as { seats?: unknown; validUntil?: unknown } | null | undefined;
  return c && typeof c.seats === "number" && typeof c.validUntil === "string" ? { seats: c.seats, validUntil: c.validUntil } : null;
}

function contribution(v: unknown): Contribution | null {
  const c = v as Record<string, unknown> | null | undefined;
  if (!c || typeof c.amount !== "number" || !(CONTRIBUTION_PERIODS as readonly unknown[]).includes(c.period)) return null;
  return { amount: c.amount, period: c.period as ContributionPeriod, note: text(c.note) };
}

const STATUSES: readonly MembershipStatus[] = ["requested", "approved", "declined", "left"];

// --- mapping ----------------------------------------------------------------

export function carpoolFromDoc(id: string, d: DocumentData): CarpoolRecord {
  const a = d.activity as Record<string, unknown> | null | undefined;
  const p = point(a?.point);
  return {
    id,
    kind: d.kind === "activity" ? "activity" : "school",
    schoolId: textOrNull(d.schoolId),
    schoolNameAr: text(d.schoolNameAr),
    schoolNameEn: text(d.schoolNameEn),
    areaId: textOrNull(d.areaId),
    areaNameAr: text(d.areaNameAr),
    areaNameEn: text(d.areaNameEn),
    activity: a && p ? { name: text(a.name), label: text(a.label), point: p, geohash: text(a.geohash) } : null,
    morning: textOrNull(d.morning),
    afternoon: textOrNull(d.afternoon),
    days: days(d.days),
    seats: num(d.seats),
    childrenCount: num(d.childrenCount),
    memberCount: num(d.memberCount),
    rules: rules(d.rules),
    contribution: contribution(d.contribution),
    creatorUid: text(d.creatorUid),
    creatorFirstName: text(d.creatorFirstName),
    status: d.status === "closed" ? "closed" : "active",
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function carpoolToDoc(c: CarpoolRecord): DocumentData {
  return {
    kind: c.kind,
    schoolId: c.schoolId,
    schoolNameAr: c.schoolNameAr,
    schoolNameEn: c.schoolNameEn,
    areaId: c.areaId,
    areaNameAr: c.areaNameAr,
    areaNameEn: c.areaNameEn,
    activity: c.activity
      ? { name: c.activity.name, label: c.activity.label, point: new GeoPoint(c.activity.point.lat, c.activity.point.lng), geohash: c.activity.geohash }
      : null,
    morning: c.morning,
    afternoon: c.afternoon,
    days: c.days,
    seats: c.seats,
    childrenCount: c.childrenCount,
    memberCount: c.memberCount,
    // Free seats (the app shows them; search filters on them).
    seatsLeft: Math.max(0, c.seats - c.childrenCount),
    rules: c.rules,
    contribution: c.contribution,
    creatorUid: c.creatorUid,
    creatorFirstName: c.creatorFirstName,
    status: c.status,
    createdAt: ts(c.createdAtMs),
    updatedAt: ts(c.updatedAtMs),
  };
}

export function membershipFromDoc(d: DocumentData): MembershipRecord {
  return {
    carpoolId: text(d.carpoolId),
    uid: text(d.uid),
    status: STATUSES.includes(d.status) ? d.status : "left",
    role: d.role === "admin" ? "admin" : "member",
    firstName: text(d.firstName),
    children: childRefs(d.children),
    car: car(d.car),
    drivingDays: days(d.drivingDays),
    acceptedRules: d.acceptedRules === true,
    acceptedContribution: d.acceptedContribution === true,
    requestedAtMs: ms(d.requestedAt),
    decidedAtMs: msOrNull(d.decidedAt),
    decidedBy: textOrNull(d.decidedBy),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function membershipToDoc(m: MembershipRecord): DocumentData {
  // carpoolId and uid must match the document ID (firestore.rules checks them).
  return {
    carpoolId: m.carpoolId,
    uid: m.uid,
    status: m.status,
    role: m.role,
    firstName: m.firstName,
    children: m.children,
    car: m.car,
    drivingDays: m.drivingDays,
    acceptedRules: m.acceptedRules,
    acceptedContribution: m.acceptedContribution,
    requestedAt: ts(m.requestedAtMs),
    decidedAt: tsOrNull(m.decidedAtMs),
    decidedBy: m.decidedBy,
    updatedAt: ts(m.updatedAtMs),
  };
}

export function memberFromDoc(uid: string, d: DocumentData): MemberRecord {
  return {
    uid,
    role: d.role === "admin" ? "admin" : "member",
    firstName: text(d.firstName),
    children: childRefs(d.children),
    car: car(d.car),
    drivingDays: days(d.drivingDays),
    pickupShared: d.pickupShared === true,
    joinedAtMs: ms(d.joinedAt),
  };
}

export function memberToDoc(m: MemberRecord): DocumentData {
  return {
    uid: m.uid,
    role: m.role,
    firstName: m.firstName,
    children: m.children,
    car: m.car,
    drivingDays: m.drivingDays,
    pickupShared: m.pickupShared,
    joinedAt: ts(m.joinedAtMs),
  };
}

export function consentFromDoc(d: DocumentData): ConsentRecord {
  return {
    carpoolId: text(d.carpoolId),
    parentUid: text(d.parentUid),
    driverUid: text(d.driverUid),
    status: d.status === "accepted" ? "accepted" : "withdrawn",
    acceptedAtMs: msOrNull(d.acceptedAt),
    withdrawnAtMs: msOrNull(d.withdrawnAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function consentToDoc(c: ConsentRecord): DocumentData {
  return {
    carpoolId: c.carpoolId,
    parentUid: c.parentUid,
    driverUid: c.driverUid,
    status: c.status,
    acceptedAt: tsOrNull(c.acceptedAtMs),
    withdrawnAt: tsOrNull(c.withdrawnAtMs),
    updatedAt: ts(c.updatedAtMs),
  };
}

function requestToDoc(r: RequestRecord): DocumentData {
  return { uid: r.uid, firstName: r.firstName, children: r.children, car: r.car, requestedAt: ts(r.requestedAtMs) };
}

export function wantedFromDoc(uid: string, d: DocumentData): WantedRecord {
  return {
    uid,
    firstName: text(d.firstName),
    schoolId: text(d.schoolId),
    schoolNameAr: text(d.schoolNameAr),
    schoolNameEn: text(d.schoolNameEn),
    areaId: textOrNull(d.areaId),
    areaNameAr: text(d.areaNameAr),
    areaNameEn: text(d.areaNameEn),
    morning: textOrNull(d.morning),
    afternoon: textOrNull(d.afternoon),
    days: days(d.days),
    childrenCount: num(d.childrenCount),
    createdAtMs: ms(d.createdAt),
    expiresAtMs: ms(d.expiresAt),
  };
}

function wantedToDoc(w: WantedRecord): DocumentData {
  return {
    uid: w.uid,
    firstName: w.firstName,
    schoolId: w.schoolId,
    schoolNameAr: w.schoolNameAr,
    schoolNameEn: w.schoolNameEn,
    areaId: w.areaId,
    areaNameAr: w.areaNameAr,
    areaNameEn: w.areaNameEn,
    morning: w.morning,
    afternoon: w.afternoon,
    days: w.days,
    childrenCount: w.childrenCount,
    status: "active",
    createdAt: ts(w.createdAtMs),
    // Also the Firestore TTL field (SETUP.md section 16).
    expiresAt: ts(w.expiresAtMs),
  };
}

// --- transaction --------------------------------------------------------------

/** Reads through the transaction; writes are buffered and applied after the last read. */
class FirestoreCarpoolTx implements CarpoolTx {
  private readonly writes: Array<(tx: Transaction) => void> = [];

  constructor(
    private readonly db: Firestore,
    private readonly tx: Transaction,
  ) {}

  private carpoolRef(id: string): DocumentReference {
    return this.db.collection(CARPOOLS).doc(id);
  }

  async carpool(id: string): Promise<CarpoolRecord | null> {
    const snap = await this.tx.get(this.carpoolRef(id));
    return snap.exists ? carpoolFromDoc(id, snap.data() ?? {}) : null;
  }

  async membership(carpoolId: string, uid: string): Promise<MembershipRecord | null> {
    const snap = await this.tx.get(this.db.collection(MEMBERSHIPS).doc(membershipId(carpoolId, uid)));
    return snap.exists ? membershipFromDoc(snap.data() ?? {}) : null;
  }

  async members(carpoolId: string): Promise<MemberRecord[]> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(MEMBERS).limit(50));
    return snap.docs.map((d) => memberFromDoc(d.id, d.data()));
  }

  async requests(carpoolId: string): Promise<RequestRecord[]> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(REQUESTS).limit(100));
    return snap.docs.map((d) => {
      const x = d.data();
      return { uid: d.id, firstName: text(x.firstName), children: childRefs(x.children), car: car(x.car), requestedAtMs: ms(x.requestedAt) };
    });
  }

  async consents(carpoolId: string): Promise<ConsentRecord[]> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(DRIVER_CONSENTS).limit(500));
    return snap.docs.map((d) => consentFromDoc(d.data()));
  }

  putCarpool(c: CarpoolRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(c.id), carpoolToDoc(c)));
  }

  putMembership(m: MembershipRecord): void {
    this.writes.push((tx) => tx.set(this.db.collection(MEMBERSHIPS).doc(membershipId(m.carpoolId, m.uid)), membershipToDoc(m)));
  }

  putMember(carpoolId: string, m: MemberRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(carpoolId).collection(MEMBERS).doc(m.uid), memberToDoc(m)));
  }

  deleteMember(carpoolId: string, uid: string): void {
    this.writes.push((tx) => tx.delete(this.carpoolRef(carpoolId).collection(MEMBERS).doc(uid)));
  }

  putRequest(carpoolId: string, r: RequestRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(carpoolId).collection(REQUESTS).doc(r.uid), requestToDoc(r)));
  }

  deleteRequest(carpoolId: string, uid: string): void {
    this.writes.push((tx) => tx.delete(this.carpoolRef(carpoolId).collection(REQUESTS).doc(uid)));
  }

  putConsent(c: ConsentRecord): void {
    this.writes.push((tx) =>
      tx.set(this.carpoolRef(c.carpoolId).collection(DRIVER_CONSENTS).doc(consentId(c.parentUid, c.driverUid)), consentToDoc(c)),
    );
  }

  deleteConsent(carpoolId: string, id: string): void {
    this.writes.push((tx) => tx.delete(this.carpoolRef(carpoolId).collection(DRIVER_CONSENTS).doc(id)));
  }

  putPickupPoint(carpoolId: string, uid: string, p: PickupPoint | null): void {
    const ref = this.carpoolRef(carpoolId).collection(PICKUP_POINTS).doc(uid);
    this.writes.push((tx) => {
      if (p) tx.set(ref, { location: new GeoPoint(p.location.lat, p.location.lng), label: p.label, updatedAt: Timestamp.now() });
      else tx.delete(ref);
    });
  }

  // --- schedule (Prompt 7) ---

  async runs(carpoolId: string, fromDate: string, toDate: string): Promise<RunRecord[]> {
    const snap = await this.tx.get(
      this.carpoolRef(carpoolId).collection(SCHEDULE).where("date", ">=", fromDate).where("date", "<=", toDate).limit(200),
    );
    return snap.docs.map((d) => runFromDoc(carpoolId, d.id, d.data()));
  }

  async run(carpoolId: string, runId: string): Promise<RunRecord | null> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(SCHEDULE).doc(runId));
    return snap.exists ? runFromDoc(carpoolId, runId, snap.data() ?? {}) : null;
  }

  async exceptions(carpoolId: string): Promise<ExceptionRecord[]> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(EXCEPTIONS).limit(100));
    return snap.docs.map((d) => exceptionFromDoc(carpoolId, d.id, d.data()));
  }

  async swap(carpoolId: string, swapId: string): Promise<SwapRecord | null> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(SWAPS).doc(swapId));
    return snap.exists ? swapFromDoc(carpoolId, swapId, snap.data() ?? {}) : null;
  }

  async balance(carpoolId: string, termId: string): Promise<BalanceRecord | null> {
    const snap = await this.tx.get(this.carpoolRef(carpoolId).collection(BALANCES).doc(termId));
    return snap.exists ? balanceFromDoc(carpoolId, termId, snap.data() ?? {}) : null;
  }

  putRun(r: RunRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(r.carpoolId).collection(SCHEDULE).doc(r.id), runToDoc(r)));
  }

  putSwap(sw: SwapRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(sw.carpoolId).collection(SWAPS).doc(sw.id), swapToDoc(sw)));
  }

  putException(e: ExceptionRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(e.carpoolId).collection(EXCEPTIONS).doc(e.id), exceptionToDoc(e)));
  }

  deleteException(carpoolId: string, id: string): void {
    this.writes.push((tx) => tx.delete(this.carpoolRef(carpoolId).collection(EXCEPTIONS).doc(id)));
  }

  putBalance(b: BalanceRecord): void {
    this.writes.push((tx) => tx.set(this.carpoolRef(b.carpoolId).collection(BALANCES).doc(b.termId), balanceToDoc(b)));
  }

  addEvent(e: ScheduleEvent): void {
    const ref = this.db.collection(SCHEDULE_EVENTS).doc();
    this.writes.push((tx) => tx.set(ref, eventToDoc(e)));
  }

  commit(): void {
    for (const w of this.writes) w(this.tx);
  }
}

export class FirestoreCarpoolStore implements CarpoolStore {
  constructor(private readonly db: Firestore) {}

  transact<T>(fn: (tx: CarpoolTx) => Promise<T>): Promise<T> {
    return this.db.runTransaction(async (tx) => {
      const ctx = new FirestoreCarpoolTx(this.db, tx);
      const result = await fn(ctx);
      ctx.commit();
      return result;
    });
  }

  newCarpoolId(): string {
    return this.db.collection(CARPOOLS).doc().id;
  }

  async account(uid: string): Promise<AccountInfo | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { status: d.banned === true ? "suspended" : text(d.status), firstName: text(d.firstName) };
  }

  async approvedChildren(uid: string): Promise<ChildInfo[]> {
    const snap = await this.db.collection(CHILDREN).where("ownerUid", "==", uid).get();
    return snap.docs
      .filter((d) => d.get("status") === "approved")
      .map((d) => ({ id: d.id, firstName: text(d.get("firstName")), grade: text(d.get("grade")), schoolId: text(d.get("schoolId")) }));
  }

  async vehicle(uid: string): Promise<VehicleInfo | null> {
    const snap = await this.db.collection(VEHICLES).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { status: text(d.status), seats: num(d.seats), licenseExpiry: text(d.licenseExpiry), carLicenseExpiry: text(d.carLicenseExpiry) };
  }

  async school(id: string): Promise<SchoolInfo | null> {
    const snap = await this.db.collection(SCHOOLS).doc(id).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { id, nameAr: text(d.nameAr), nameEn: text(d.nameEn), status: text(d.status) };
  }

  async area(id: string): Promise<AreaInfo | null> {
    const snap = await this.db.collection(AREAS).doc(id).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { id, schoolId: text(d.schoolId), nameAr: text(d.nameAr), nameEn: text(d.nameEn) };
  }

  async drivingSchoolIds(uid: string): Promise<string[]> {
    const snap = await this.db.collection(HOMES).doc(uid).get();
    const list = snap.exists ? snap.get("drivingSchools") : null;
    return Array.isArray(list) ? list.map((s) => (s as { id?: unknown }).id).filter((id): id is string => typeof id === "string") : [];
  }

  async home(uid: string): Promise<PickupPoint | null> {
    const snap = await this.db.collection(HOMES).doc(uid).get();
    const p = snap.exists ? point(snap.get("location")) : null;
    return p ? { location: p, label: text(snap.get("label")) } : null;
  }

  async schoolCarpools(schoolId: string, limit: number): Promise<CarpoolRecord[]> {
    const snap = await this.db
      .collection(CARPOOLS)
      .where("kind", "==", "school")
      .where("schoolId", "==", schoolId)
      .where("status", "==", "active")
      .limit(limit)
      .get();
    return snap.docs.map((d) => carpoolFromDoc(d.id, d.data()));
  }

  async activityCarpools(prefix: string, limit: number): Promise<CarpoolRecord[]> {
    // Index: firestore.indexes.json (kind, status, activity.geohash).
    const snap = await this.db
      .collection(CARPOOLS)
      .where("kind", "==", "activity")
      .where("status", "==", "active")
      .where("activity.geohash", ">=", prefix)
      .where("activity.geohash", "<=", `${prefix}~`)
      .limit(limit)
      .get();
    return snap.docs.map((d) => carpoolFromDoc(d.id, d.data()));
  }

  async carpoolsById(ids: string[]): Promise<CarpoolRecord[]> {
    if (ids.length === 0) return [];
    const snaps = await this.db.getAll(...ids.map((id) => this.db.collection(CARPOOLS).doc(id)));
    return snaps.filter((s) => s.exists).map((s) => carpoolFromDoc(s.id, s.data() ?? {}));
  }

  async membershipsOf(uid: string): Promise<MembershipRecord[]> {
    const snap = await this.db.collection(MEMBERSHIPS).where("uid", "==", uid).limit(200).get();
    return snap.docs.map((d) => membershipFromDoc(d.data()));
  }

  async takeLimit(
    uid: string,
    kind: CarpoolLimitKind,
    nowMs: number,
    rule: { windowMs: number; max: number },
  ): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(CARPOOL_LIMITS).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const raw = (snap.exists ? snap.get(kind) : undefined) as { windowStartMs?: unknown; count?: unknown } | undefined;
      const current: WindowCounter | undefined =
        raw && typeof raw.windowStartMs === "number" && typeof raw.count === "number"
          ? { windowStartMs: raw.windowStartMs, count: raw.count }
          : undefined;
      const result = takeFromWindow(current, nowMs, rule);
      if (result.allowed) tx.set(ref, { ...(snap.exists ? snap.data() : {}), [kind]: result.next });
      return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
    });
  }

  async invite(code: string): Promise<InviteRecord | null> {
    const snap = await this.db.collection(CARPOOL_INVITES).doc(code).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { code, carpoolId: text(d.carpoolId), createdBy: text(d.createdBy), createdAtMs: ms(d.createdAt), expiresAtMs: ms(d.expiresAt) };
  }

  async createInvite(invite: InviteRecord): Promise<boolean> {
    try {
      await this.db.collection(CARPOOL_INVITES).doc(invite.code).create({
        carpoolId: invite.carpoolId,
        createdBy: invite.createdBy,
        createdAt: ts(invite.createdAtMs),
        // Also the Firestore TTL field (SETUP.md section 16).
        expiresAt: ts(invite.expiresAtMs),
      });
      return true;
    } catch (error) {
      const code = (error as { code?: unknown }).code;
      if (code === 6 || code === "already-exists") return false;
      throw error;
    }
  }

  async wanted(uid: string): Promise<WantedRecord | null> {
    const snap = await this.db.collection(CARPOOL_WANTED).doc(uid).get();
    return snap.exists ? wantedFromDoc(uid, snap.data() ?? {}) : null;
  }

  async putWanted(uid: string, w: WantedRecord | null): Promise<void> {
    const ref = this.db.collection(CARPOOL_WANTED).doc(uid);
    if (w) await ref.set(wantedToDoc(w));
    else await ref.delete();
  }

  async wantedForSchool(schoolId: string, limit: number): Promise<WantedRecord[]> {
    // Index: firestore.indexes.json (schoolId, createdAt descending).
    const snap = await this.db.collection(CARPOOL_WANTED).where("schoolId", "==", schoolId).orderBy("createdAt", "desc").limit(limit).get();
    return snap.docs.map((d) => wantedFromDoc(d.id, d.data()));
  }

  newId(): string {
    return this.db.collection(SCHEDULE_EVENTS).doc().id;
  }

  /** Index: firestore.indexes.json, collection group "schedule" (status, confirmBy). */
  async dueRuns(nowMs: number, limit: number): Promise<RunRef[]> {
    const snap = await this.db
      .collectionGroup(SCHEDULE)
      .where("status", "in", ["planned", "open"])
      .where("confirmBy", "<=", ts(nowMs))
      .limit(limit)
      .get();
    return snap.docs.map((d) => ({ carpoolId: text(d.get("carpoolId")), runId: d.id }));
  }

  /** Index: firestore.indexes.json, collection group "schedule" (status, startAt). */
  async finishedRuns(nowMs: number, limit: number): Promise<RunRef[]> {
    const snap = await this.db.collectionGroup(SCHEDULE).where("status", "==", "confirmed").where("startAt", "<=", ts(nowMs)).limit(limit).get();
    return snap.docs.map((d) => ({ carpoolId: text(d.get("carpoolId")), runId: d.id }));
  }
}
