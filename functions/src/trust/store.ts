import type { Auth } from "firebase-admin/auth";
import { FieldValue, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { PARENT_IDS, USERS } from "../auth/accounts";
import { REPORTS } from "../admin_panel/store";
import { cairoDate } from "../carpools/model";
import { MEMBERSHIPS } from "../carpools/store";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import type { OutboxEvent } from "../notifications/model";
import { NOTIFICATION_EVENTS, outboxDoc } from "../notifications/outbox";
import { TRIPS } from "../trips/store";
import { AUDIT_LOG, CHILDREN, VEHICLES } from "../verification/store";
import { usableVehicle } from "../verification/vehicle";
import { GUARDIAN_LINKS } from "./links";
import type { ChildLite, FlagOutcome, RatingFlag, RatingRecord, TrustAccount, TrustLimitKind, TrustStore, YearChange } from "./flow";
import type { JobStore, UserRow, VehicleRow } from "./jobs";
import { RATING_TAGS, RELATIONS, TrustError, type GuardianLink, type GuardianRequest, type RatingTag, type Relation, type TripLike, type TrustSummary } from "./model";
import type { PhoneAccount, PhoneChangeStore } from "./phone";

/**
 * Firestore side of trust (Prompt 11, F17). Every collection here is
 * closed to the app (firestore.rules: deny by default; deny_all tests):
 *   ratings/{YYYY-MM_rater_ratee}     one rating per pair per month, append-only
 *   trustSummaries/{uid}              count, sum, vouchers
 *   ratingFlags/{ratingId}            low ratings and safety concerns (admin queue)
 *   guardianRequests/{owner_guardian} a parent asks to be linked to the children
 *   guardianLinks/{childId_guardian}  a child shared with another verified parent
 *   trustLimits/{uid}                 rate limits
 */

export const RATINGS = "ratings";
export const TRUST_SUMMARIES = "trustSummaries";
export const RATING_FLAGS = "ratingFlags";
export const GUARDIAN_REQUESTS = "guardianRequests";
export { GUARDIAN_LINKS };
export const TRUST_LIMITS = "trustLimits";

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);
const text = (v: unknown): string => (typeof v === "string" ? v : "");
const millis = (v: unknown): number => (v instanceof Timestamp ? v.toMillis() : typeof v === "number" ? v : 0);
const millisOrNull = (v: unknown): number | null => (v instanceof Timestamp ? v.toMillis() : typeof v === "number" ? v : null);
const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
const tags = (v: unknown): RatingTag[] => strings(v).filter((t): t is RatingTag => (RATING_TAGS as readonly string[]).includes(t));
const relation = (v: unknown): Relation => ((RELATIONS as readonly string[]).includes(text(v)) ? (v as Relation) : "guardian");

function accountFrom(uid: string, d: DocumentData): TrustAccount {
  const verifiedAt = millisOrNull(d.verifiedAt);
  return {
    uid,
    status: d.banned === true ? "suspended" : text(d.status),
    firstName: text(d.firstName),
    parentId: text(d.parentId),
    verifiedOn: verifiedAt === null ? null : cairoDate(verifiedAt),
    yearConfirmed: typeof d.schoolYearConfirmed === "number" ? d.schoolYearConfirmed : null,
    yearCheckOverdue: d.yearCheckOverdue === true,
  };
}

export function linkFromDoc(id: string, d: DocumentData): GuardianLink {
  const status = text(d.status);
  return {
    id,
    childId: text(d.childId),
    childFirstName: text(d.childFirstName),
    ownerUid: text(d.ownerUid),
    ownerFirstName: text(d.ownerFirstName),
    guardianUid: text(d.guardianUid),
    guardianFirstName: text(d.guardianFirstName),
    relation: relation(d.relation),
    status: status === "active" || status === "review" || status === "rejected" ? status : "removed",
    createdAtMs: millis(d.createdAt),
    decidedAtMs: millisOrNull(d.decidedAt),
    decidedBy: typeof d.decidedBy === "string" ? d.decidedBy : null,
    updatedAtMs: millis(d.updatedAt),
  };
}

function linkToDoc(l: GuardianLink): DocumentData {
  return {
    childId: l.childId,
    childFirstName: l.childFirstName,
    ownerUid: l.ownerUid,
    ownerFirstName: l.ownerFirstName,
    guardianUid: l.guardianUid,
    guardianFirstName: l.guardianFirstName,
    relation: l.relation,
    status: l.status,
    createdAt: ts(l.createdAtMs),
    decidedAt: l.decidedAtMs === null ? null : ts(l.decidedAtMs),
    decidedBy: l.decidedBy,
    updatedAt: ts(l.updatedAtMs),
  };
}

function requestFromDoc(id: string, d: DocumentData): GuardianRequest {
  const status = text(d.status);
  return {
    id,
    ownerUid: text(d.ownerUid),
    guardianUid: text(d.guardianUid),
    guardianFirstName: text(d.guardianFirstName),
    relation: relation(d.relation),
    status: status === "requested" || status === "accepted" || status === "declined" ? status : "cancelled",
    createdAtMs: millis(d.createdAt),
    updatedAtMs: millis(d.updatedAt),
  };
}

function requestToDoc(r: GuardianRequest): DocumentData {
  return {
    ownerUid: r.ownerUid,
    guardianUid: r.guardianUid,
    guardianFirstName: r.guardianFirstName,
    relation: r.relation,
    status: r.status,
    createdAt: ts(r.createdAtMs),
    updatedAt: ts(r.updatedAtMs),
  };
}

function flagFromDoc(id: string, d: DocumentData): RatingFlag {
  const outcome = text(d.outcome);
  return {
    id,
    ratingId: text(d.ratingId),
    raterUid: text(d.raterUid),
    rateeUid: text(d.rateeUid),
    stars: typeof d.stars === "number" ? d.stars : 0,
    tags: tags(d.tags),
    carpoolId: text(d.carpoolId),
    status: d.status === "handled" ? "handled" : "open",
    outcome: outcome === "no-issue" || outcome === "contacted" || outcome === "escalated" ? outcome : null,
    createdAtMs: millis(d.createdAt),
  };
}

function summaryFromDoc(d: DocumentData | undefined): TrustSummary | null {
  if (!d) return null;
  return { count: typeof d.count === "number" ? d.count : 0, sum: typeof d.sum === "number" ? d.sum : 0, voucherUids: strings(d.voucherUids) };
}

function isAlreadyExists(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  return code === 6 || code === "already-exists";
}

export class FirestoreTrustStore implements TrustStore, JobStore, PhoneChangeStore {
  constructor(
    private readonly db: Firestore,
    private readonly auth: Auth | null = null,
  ) {}

  async account(uid: string): Promise<TrustAccount & PhoneAccount | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { ...accountFrom(uid, d), phone: typeof d.phone === "string" ? d.phone : null };
  }

  async accountByParentId(parentId: string): Promise<TrustAccount | null> {
    const ref = await this.db.collection(PARENT_IDS).doc(parentId).get();
    const uid = ref.exists ? text(ref.get("uid")) : "";
    return uid ? this.account(uid) : null;
  }

  async finishedTrips(uid: string, sinceDate: string): Promise<TripLike[]> {
    // Index: trips viewerUids (array-contains), status, date (firestore.indexes.json).
    const snap = await this.db
      .collection(TRIPS)
      .where("viewerUids", "array-contains", uid)
      .where("status", "==", "ended")
      .where("date", ">=", sinceDate)
      .limit(200)
      .get();
    return snap.docs.map((doc) => {
      const d = doc.data();
      const stops = Array.isArray(d.stops) ? (d.stops as Array<Record<string, unknown>>) : [];
      return {
        id: doc.id,
        carpoolId: text(d.carpoolId),
        date: text(d.date),
        status: text(d.status),
        driverUid: text(d.driverUid),
        stops: stops.map((s) => ({ parentUid: text(s.parentUid), state: text(s.state) })),
      };
    });
  }

  async ratedIn(raterUid: string, month: string): Promise<string[]> {
    const snap = await this.db.collection(RATINGS).where("raterUid", "==", raterUid).where("month", "==", month).limit(200).get();
    return snap.docs.map((doc) => text(doc.get("rateeUid")));
  }

  async tripRated(raterUid: string, rateeUid: string, tripId: string): Promise<boolean> {
    const snap = await this.db.collection(RATINGS).where("raterUid", "==", raterUid).where("rateeUid", "==", rateeUid).where("tripId", "==", tripId).limit(1).get();
    return !snap.empty;
  }

  saveRating(r: RatingRecord, update: (s: TrustSummary | null) => TrustSummary, flag: RatingFlag | null): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const ref = this.db.collection(RATINGS).doc(r.id);
      const summaryRef = this.db.collection(TRUST_SUMMARIES).doc(r.rateeUid);
      const sameTrip = this.db.collection(RATINGS).where("raterUid", "==", r.raterUid).where("rateeUid", "==", r.rateeUid).where("tripId", "==", r.tripId).limit(1);
      const [existing, summary, tripDone] = [await tx.get(ref), await tx.get(summaryRef), await tx.get(sameTrip)];
      if (existing.exists || !tripDone.empty) throw new TrustError("already-rated");
      const next = update(summaryFromDoc(summary.exists ? summary.data() : undefined));
      tx.create(ref, {
        month: r.month,
        raterUid: r.raterUid,
        rateeUid: r.rateeUid,
        stars: r.stars,
        tags: r.tags,
        vouch: r.vouch,
        tripId: r.tripId,
        carpoolId: r.carpoolId,
        createdAt: ts(r.createdAtMs),
      });
      tx.set(summaryRef, { count: next.count, sum: next.sum, voucherUids: next.voucherUids, updatedAt: ts(r.createdAtMs) });
      if (flag) {
        tx.create(this.db.collection(RATING_FLAGS).doc(flag.id), {
          ratingId: flag.ratingId,
          raterUid: flag.raterUid,
          rateeUid: flag.rateeUid,
          stars: flag.stars,
          tags: flag.tags,
          carpoolId: flag.carpoolId,
          status: "open",
          outcome: null,
          createdAt: ts(flag.createdAtMs),
        });
      }
    });
  }

  async summary(uid: string): Promise<TrustSummary | null> {
    const snap = await this.db.collection(TRUST_SUMMARIES).doc(uid).get();
    return summaryFromDoc(snap.exists ? snap.data() : undefined);
  }

  async shareCarpool(a: string, b: string): Promise<boolean> {
    const mine = await this.db.collection(MEMBERSHIPS).where("uid", "==", a).where("status", "==", "approved").limit(20).get();
    const ids = mine.docs.map((doc) => text(doc.get("carpoolId"))).filter((id) => id.length > 0);
    if (ids.length === 0) return false;
    const theirs = await this.db.getAll(...ids.map((id) => this.db.collection(MEMBERSHIPS).doc(`${id}_${b}`)));
    return theirs.some((s) => s.exists && s.get("status") === "approved" && s.get("uid") === b);
  }

  async childrenOf(ownerUid: string): Promise<ChildLite[]> {
    const snap = await this.db.collection(CHILDREN).where("ownerUid", "==", ownerUid).limit(20).get();
    return snap.docs.map((doc) => ({
      id: doc.id,
      ownerUid,
      firstName: text(doc.get("firstName")),
      grade: text(doc.get("grade")),
      schoolId: text(doc.get("schoolId")),
      schoolName: text(doc.get("schoolName")),
      status: text(doc.get("status")),
    }));
  }

  async approvedChildCount(uid: string): Promise<number> {
    return (await this.childrenOf(uid)).filter((c) => c.status === "approved").length;
  }

  async linksOfChild(childId: string): Promise<GuardianLink[]> {
    const snap = await this.db.collection(GUARDIAN_LINKS).where("childId", "==", childId).limit(20).get();
    return snap.docs.map((doc) => linkFromDoc(doc.id, doc.data()));
  }

  async linksAs(uid: string, side: "owner" | "guardian"): Promise<GuardianLink[]> {
    const snap = await this.db.collection(GUARDIAN_LINKS).where(side === "owner" ? "ownerUid" : "guardianUid", "==", uid).limit(50).get();
    return snap.docs.map((doc) => linkFromDoc(doc.id, doc.data()));
  }

  async link(id: string): Promise<GuardianLink | null> {
    const snap = await this.db.collection(GUARDIAN_LINKS).doc(id).get();
    return snap.exists ? linkFromDoc(id, snap.data() ?? {}) : null;
  }

  async guardianRequest(id: string): Promise<GuardianRequest | null> {
    const snap = await this.db.collection(GUARDIAN_REQUESTS).doc(id).get();
    return snap.exists ? requestFromDoc(id, snap.data() ?? {}) : null;
  }

  async guardianRequestsAs(uid: string, side: "owner" | "guardian"): Promise<GuardianRequest[]> {
    const snap = await this.db.collection(GUARDIAN_REQUESTS).where(side === "owner" ? "ownerUid" : "guardianUid", "==", uid).limit(50).get();
    return snap.docs.map((doc) => requestFromDoc(doc.id, doc.data()));
  }

  putGuardianRequest(r: GuardianRequest, notice: OutboxEvent | null, expect?: GuardianRequest["status"] | null): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const ref = this.db.collection(GUARDIAN_REQUESTS).doc(r.id);
      const current = await tx.get(ref);
      if (expect !== undefined) {
        const status = current.exists ? text(current.get("status")) : null;
        if (status !== expect) throw new TrustError("invalid-state");
      }
      tx.set(ref, requestToDoc(r));
      if (notice) tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(notice.id), outboxDoc(notice));
    });
  }

  decideGuardianRequest(r: GuardianRequest, links: GuardianLink[], notices: OutboxEvent[]): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const ref = this.db.collection(GUARDIAN_REQUESTS).doc(r.id);
      const current = await tx.get(ref);
      if (!current.exists || current.get("status") !== "requested") throw new TrustError("invalid-state");
      tx.set(ref, requestToDoc(r));
      for (const l of links) tx.set(this.db.collection(GUARDIAN_LINKS).doc(l.id), linkToDoc(l));
      for (const n of notices) tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(n.id), outboxDoc(n));
    });
  }

  putLink(l: GuardianLink, expect: GuardianLink["status"], notice: OutboxEvent | null): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const ref = this.db.collection(GUARDIAN_LINKS).doc(l.id);
      const current = await tx.get(ref);
      if (!current.exists || current.get("status") !== expect) throw new TrustError("invalid-state");
      tx.set(ref, linkToDoc(l));
      if (notice) tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(notice.id), outboxDoc(notice));
    });
  }

  async linksInReview(limit: number): Promise<GuardianLink[]> {
    const snap = await this.db.collection(GUARDIAN_LINKS).where("status", "==", "review").limit(limit).get();
    return snap.docs.map((doc) => linkFromDoc(doc.id, doc.data())).sort((a, b) => a.createdAtMs - b.createdAtMs);
  }

  saveYear(uid: string, year: number, changes: YearChange[], nowMs: number): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const refs = changes.map((c) => this.db.collection(CHILDREN).doc(c.childId));
      const snaps = await Promise.all(refs.map((ref) => tx.get(ref)));
      snaps.forEach((snap) => {
        if (!snap.exists || snap.get("ownerUid") !== uid || snap.get("status") !== "approved") throw new TrustError("children-changed");
      });
      changes.forEach((c, i) => {
        if (c.grade === null) {
          // Left the school: no longer approved, so it leaves maps, chats and pickers.
          tx.update(refs[i], { status: "left", leftAt: ts(nowMs), updatedAt: FieldValue.serverTimestamp() });
        } else {
          tx.update(refs[i], { grade: c.grade, updatedAt: FieldValue.serverTimestamp() });
        }
      });
      tx.update(this.db.collection(USERS).doc(uid), {
        schoolYearConfirmed: year,
        schoolYearConfirmedAt: ts(nowMs),
        yearCheckOverdue: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      tx.create(this.db.collection(AUDIT_LOG).doc(), {
        actorUid: uid,
        action: "school-year.confirm",
        target: `users/${uid}`,
        details: { year, left: changes.filter((c) => c.grade === null).length },
        ip: null,
        time: FieldValue.serverTimestamp(),
      });
    });
  }

  async flags(status: "open" | "handled", limit: number): Promise<RatingFlag[]> {
    const snap = await this.db.collection(RATING_FLAGS).where("status", "==", status).limit(limit).get();
    return snap.docs.map((doc) => flagFromDoc(doc.id, doc.data())).sort((a, b) => b.createdAtMs - a.createdAtMs);
  }

  resolveFlag(id: string, outcome: FlagOutcome, adminUid: string, nowMs: number): Promise<RatingFlag> {
    return this.db.runTransaction(async (tx) => {
      const ref = this.db.collection(RATING_FLAGS).doc(id);
      const snap = await tx.get(ref);
      if (!snap.exists) throw new TrustError("not-found");
      if (snap.get("status") !== "open") throw new TrustError("invalid-state");
      tx.update(ref, { status: "handled", outcome, handledBy: adminUid, handledAt: ts(nowMs) });
      return { ...flagFromDoc(id, snap.data() ?? {}), status: "handled" as const, outcome };
    });
  }

  takeLimit(uid: string, kind: TrustLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(TRUST_LIMITS).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const raw = (snap.exists ? snap.get(kind) : undefined) as { windowStartMs?: unknown; count?: unknown } | undefined;
      const current: WindowCounter | undefined =
        raw && typeof raw.windowStartMs === "number" && typeof raw.count === "number" ? { windowStartMs: raw.windowStartMs, count: raw.count } : undefined;
      const result = takeFromWindow(current, nowMs, rule);
      if (result.allowed) tx.set(ref, { [kind]: result.next }, { merge: true });
      return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
    });
  }

  async audit(entry: { actorUid: string; action: string; target: string; details?: Record<string, unknown>; ip: string | null }): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create({
      actorUid: entry.actorUid,
      action: entry.action,
      target: entry.target,
      details: entry.details ?? null,
      ip: entry.ip,
      time: FieldValue.serverTimestamp(),
    });
  }

  // --- jobs ---

  async vehicles(afterUid: string | null, limit: number): Promise<{ rows: VehicleRow[]; last: string | null }> {
    let q = this.db.collection(VEHICLES).orderBy("__name__").limit(limit);
    if (afterUid) q = q.startAfter(afterUid);
    const snap = await q.get();
    const rows: VehicleRow[] = [];
    for (const doc of snap.docs) {
      const v = usableVehicle(doc.data());
      if (v) rows.push({ uid: doc.id, vehicle: v });
    }
    return { rows, last: snap.docs.length === limit ? snap.docs[snap.docs.length - 1].id : null };
  }

  async verifiedUsers(afterUid: string | null, limit: number): Promise<{ rows: UserRow[]; last: string | null }> {
    let q = this.db.collection(USERS).where("status", "==", "verified").orderBy("__name__").limit(limit);
    if (afterUid) q = q.startAfter(afterUid);
    const snap = await q.get();
    const rows = snap.docs
      .filter((doc) => doc.get("banned") !== true)
      .map((doc) => {
        const a = accountFrom(doc.id, doc.data());
        return { uid: doc.id, verifiedOn: a.verifiedOn, yearConfirmed: a.yearConfirmed, yearCheckOverdue: a.yearCheckOverdue };
      });
    return { rows, last: snap.docs.length === limit ? snap.docs[snap.docs.length - 1].id : null };
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

  async setYearCheckOverdue(uid: string, overdue: boolean): Promise<void> {
    await this.db.collection(USERS).doc(uid).update({ yearCheckOverdue: overdue ? true : FieldValue.delete(), updatedAt: FieldValue.serverTimestamp() });
  }

  // --- phone change ---

  async uidByPhone(phoneE164: string): Promise<string | null> {
    if (!this.auth) throw new Error("auth not configured");
    try {
      return (await this.auth.getUserByPhoneNumber(phoneE164)).uid;
    } catch (error) {
      if ((error as { code?: unknown }).code === "auth/user-not-found") return null;
      throw error;
    }
  }

  async changePhone(uid: string, phoneE164: string, notice: OutboxEvent, nowMs: number): Promise<void> {
    if (!this.auth) throw new Error("auth not configured");
    // Auth first: the number signs in to this account from now on. Fails
    // (phone-number-already-exists) if another account took it meanwhile.
    try {
      await this.auth.updateUser(uid, { phoneNumber: phoneE164 });
    } catch (error) {
      if ((error as { code?: unknown }).code === "auth/phone-number-already-exists") throw new TrustError("phone-taken");
      throw error;
    }
    const batch = this.db.batch();
    batch.update(this.db.collection(USERS).doc(uid), { phone: phoneE164, phoneChangedAt: ts(nowMs), updatedAt: FieldValue.serverTimestamp() });
    batch.set(this.db.collection(NOTIFICATION_EVENTS).doc(notice.id), outboxDoc(notice));
    // Never the number in the audit log.
    batch.create(this.db.collection(AUDIT_LOG).doc(), { actorUid: uid, action: "phone.change", target: `users/${uid}`, ip: null, time: FieldValue.serverTimestamp() });
    await batch.commit();
  }

  async reportMismatch(uid: string, nowMs: number): Promise<void> {
    await this.db.collection(REPORTS).doc().create({
      reporterId: "system",
      targetType: "user",
      targetId: uid,
      reason: "phone-change-mismatch",
      urgent: false,
      status: "open",
      createdAt: ts(nowMs),
    });
  }
}
