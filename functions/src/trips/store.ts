import { FieldValue, GeoPoint, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import { REPORTS, SCHOOLS } from "../admin_panel/store";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import { HOMES } from "../maps/store";
import type { LatLng } from "../maps/geo";
import { CARPOOLS, MEMBERS, MEMBERSHIPS, PICKUP_POINTS } from "../carpools/store";
import { membershipId } from "../carpools/model";
import { NOTIFICATION_EVENTS, outboxDoc } from "../notifications/outbox";
import type { OutboxEvent } from "../notifications/model";
import { runFromDoc, SCHEDULE } from "../schedule/store";
import type { RunRecord } from "../schedule/model";
import { asLanguage } from "../whatsapp/sender";
import { CHILDREN, VEHICLES } from "../verification/store";
import { usableVehicle } from "../verification/vehicle";
import type { CarpoolPlace, HandoverEntry, TripAccount, TripChange, TripReport, TripStore } from "./flow";
import {
  QUICK_KINDS,
  RELATIONS,
  type CarCard,
  type EmergencyContact,
  type EtaRecord,
  type HandoverAdult,
  type QuickKind,
  type Relation,
  type SelfieStatus,
  type Stop,
  type StopState,
  type TripCheck,
  type TripPoint,
  type TripRecord,
  type TripStops,
} from "./model";

/** Firestore mapping of the trip records (Prompt 10). Only Cloud Functions write them. */

export const TRIPS = "trips";
export const POINTS = "points";
export const ETA = "eta";
export const TRIP_STOPS = "tripStops";
export const TRIP_CHECKS = "tripChecks";
export const HANDOVER_ADULTS = "handoverAdults";
export const EMERGENCY_CONTACTS = "emergencyContacts";
export const EMERGENCIES = "emergencies";
export const TRIP_LIMITS = "tripLimits";

const text = (v: unknown): string => (typeof v === "string" ? v : "");
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const numOrNull = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const ms = (v: unknown): number => {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
};
const msOrNull = (v: unknown): number | null => {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : null;
};
const ts = (value: number): Timestamp => Timestamp.fromMillis(value);
const tsOrNull = (value: number | null): Timestamp | null => (value === null ? null : Timestamp.fromMillis(value));
const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);

function point(v: unknown): LatLng | null {
  const p = v as { latitude?: unknown; longitude?: unknown } | null | undefined;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
}

const STOP_STATES: readonly StopState[] = ["waiting", "arrived", "onBoard", "dropped", "received", "absent"];

function relation(v: unknown): Relation {
  return (RELATIONS as readonly unknown[]).includes(v) ? (v as Relation) : "other";
}

function adults(v: unknown): HandoverAdult[] {
  return Array.isArray(v)
    ? v.map((a) => (typeof a === "object" && a !== null ? (a as Record<string, unknown>) : {})).map((a) => ({ name: text(a.name), relation: relation(a.relation) }))
    : [];
}

function stopFrom(v: Record<string, unknown>): Stop {
  return {
    childId: text(v.childId),
    firstName: text(v.firstName),
    parentUid: text(v.parentUid),
    state: (STOP_STATES as readonly unknown[]).includes(v.state) ? (v.state as StopState) : "waiting",
    arrivedCount: num(v.arrivedCount),
    arrivedAtMs: msOrNull(v.arrivedAt),
    pickedUpAtMs: msOrNull(v.pickedUpAt),
    droppedAtMs: msOrNull(v.droppedAt),
    receivedAtMs: msOrNull(v.receivedAt),
    notConfirmedAtMs: msOrNull(v.notConfirmedAt),
    handover: adults(v.handover),
  };
}

function stopTo(s: Stop): DocumentData {
  return {
    childId: s.childId,
    firstName: s.firstName,
    parentUid: s.parentUid,
    state: s.state,
    arrivedCount: s.arrivedCount,
    arrivedAt: tsOrNull(s.arrivedAtMs),
    pickedUpAt: tsOrNull(s.pickedUpAtMs),
    droppedAt: tsOrNull(s.droppedAtMs),
    receivedAt: tsOrNull(s.receivedAtMs),
    notConfirmedAt: tsOrNull(s.notConfirmedAtMs),
    handover: s.handover.map((a) => ({ name: a.name, relation: a.relation })),
  };
}

function pointFrom(v: unknown): TripPoint | null {
  const p = typeof v === "object" && v !== null ? (v as Record<string, unknown>) : null;
  const at = p ? point(p.location) : null;
  if (!p || !at) return null;
  return { lat: at.lat, lng: at.lng, accuracy: numOrNull(p.accuracy), speed: numOrNull(p.speed), heading: numOrNull(p.heading), atMs: ms(p.time) };
}

function pointTo(p: TripPoint): DocumentData {
  return { location: new GeoPoint(p.lat, p.lng), accuracy: p.accuracy, speed: p.speed, heading: p.heading, time: ts(p.atMs) };
}

export function tripFromDoc(id: string, d: DocumentData): TripRecord {
  const car = d.car as Record<string, unknown> | null | undefined;
  const status = d.status === "handover" || d.status === "ended" ? d.status : "active";
  return {
    id,
    carpoolId: text(d.carpoolId),
    runId: text(d.runId),
    date: text(d.date),
    direction: d.direction === "toHome" ? "toHome" : "toSchool",
    driverUid: text(d.driverUid),
    driverFirstName: text(d.driverFirstName),
    car: car ? { model: text(car.model), color: text(car.color), plate: text(car.plate) } : null,
    status,
    startedAtMs: ms(d.startedAt),
    trackingEndedAtMs: msOrNull(d.trackingEndedAt),
    endedAtMs: msOrNull(d.endedAt),
    endReason: d.endReason === "done" || d.endReason === "ended" || d.endReason === "timeout" || d.endReason === "revoked" ? d.endReason : null,
    viewerUids: strings(d.viewerUids),
    childIds: strings(d.childIds),
    stops: Array.isArray(d.stops) ? d.stops.map((s: unknown) => stopFrom(typeof s === "object" && s !== null ? (s as Record<string, unknown>) : {})) : [],
    last: pointFrom(d.last),
    lastPointAtMs: msOrNull(d.lastPointAt),
    staleAlertedAtMs: msOrNull(d.staleAlertedAt),
    tokenHash: text(d.tokenHash),
    tokenExpiresAtMs: ms(d.tokenExpiresAt),
    lastEtaAtMs: msOrNull(d.lastEtaAt),
    accountCheckedAtMs: msOrNull(d.accountCheckedAt),
    messages: Array.isArray(d.messages)
      ? d.messages
          .map((m: unknown) => (typeof m === "object" && m !== null ? (m as Record<string, unknown>) : {}))
          .filter((m: Record<string, unknown>) => (QUICK_KINDS as readonly unknown[]).includes(m.kind))
          .map((m: Record<string, unknown>) => ({ kind: m.kind as QuickKind, atMs: ms(m.at) }))
      : [],
    doneRequests: strings(d.doneRequests),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function tripToDoc(t: TripRecord): DocumentData {
  return {
    carpoolId: t.carpoolId,
    runId: t.runId,
    date: t.date,
    direction: t.direction,
    driverUid: t.driverUid,
    driverFirstName: t.driverFirstName,
    car: t.car,
    status: t.status,
    startedAt: ts(t.startedAtMs),
    trackingEndedAt: tsOrNull(t.trackingEndedAtMs),
    endedAt: tsOrNull(t.endedAtMs),
    endReason: t.endReason,
    // firestore.rules: only these people read the trip and its points.
    viewerUids: t.viewerUids,
    childIds: t.childIds,
    stops: t.stops.map(stopTo),
    last: t.last ? pointTo(t.last) : null,
    lastPointAt: tsOrNull(t.lastPointAtMs),
    staleAlertedAt: tsOrNull(t.staleAlertedAtMs),
    tokenHash: t.tokenHash,
    tokenExpiresAt: ts(t.tokenExpiresAtMs),
    lastEtaAt: tsOrNull(t.lastEtaAtMs),
    accountCheckedAt: tsOrNull(t.accountCheckedAtMs),
    messages: t.messages.map((m) => ({ kind: m.kind, at: ts(m.atMs) })),
    doneRequests: t.doneRequests,
    updatedAt: ts(t.updatedAtMs),
  };
}

function stopsToDoc(s: TripStops): DocumentData {
  const homes: Record<string, GeoPoint> = {};
  for (const [uid, p] of Object.entries(s.homes)) homes[uid] = new GeoPoint(p.lat, p.lng);
  return { homes, school: s.school ? new GeoPoint(s.school.lat, s.school.lng) : null };
}

function stopsFromDoc(d: DocumentData): TripStops {
  const homes: Record<string, LatLng> = {};
  const raw = typeof d.homes === "object" && d.homes !== null ? (d.homes as Record<string, unknown>) : {};
  for (const [uid, v] of Object.entries(raw)) {
    const p = point(v);
    if (p) homes[uid] = p;
  }
  return { homes, school: point(d.school) };
}

const SELFIE: readonly SelfieStatus[] = ["none", "required", "passed", "failed", "error"];

function checkFrom(d: DocumentData): TripCheck {
  return {
    driverUid: text(d.driverUid),
    status: (SELFIE as readonly unknown[]).includes(d.status) ? (d.status as SelfieStatus) : "required",
    decidedAtMs: ms(d.decidedAt),
    checkedAtMs: msOrNull(d.checkedAt),
  };
}

function checkTo(c: TripCheck): DocumentData {
  return { driverUid: c.driverUid, status: c.status, decidedAt: ts(c.decidedAtMs), checkedAt: tsOrNull(c.checkedAtMs) };
}

export class FirestoreTripStore implements TripStore {
  constructor(private readonly db: Firestore) {}

  async account(uid: string): Promise<TripAccount | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return {
      status: d.banned === true ? "suspended" : text(d.status),
      firstName: text(d.firstName),
      drivingPaused: d.drivingPaused != null && d.drivingPaused !== false,
      language: asLanguage(d.language),
    };
  }

  async run(carpoolId: string, runId: string): Promise<RunRecord | null> {
    const snap = await this.db.collection(CARPOOLS).doc(carpoolId).collection(SCHEDULE).doc(runId).get();
    return snap.exists ? runFromDoc(carpoolId, runId, snap.data() ?? {}) : null;
  }

  async runsOn(carpoolId: string, date: string): Promise<RunRecord[]> {
    const ids = [`${date}_am`, `${date}_pm`];
    const col = this.db.collection(CARPOOLS).doc(carpoolId).collection(SCHEDULE);
    const snaps = await this.db.getAll(...ids.map((id) => col.doc(id)));
    return snaps.filter((s) => s.exists).map((s) => runFromDoc(carpoolId, s.id, s.data() ?? {}));
  }

  async carpool(carpoolId: string): Promise<CarpoolPlace | null> {
    const snap = await this.db.collection(CARPOOLS).doc(carpoolId).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    const activity = d.activity as Record<string, unknown> | null | undefined;
    return { kind: d.kind === "activity" ? "activity" : "school", schoolId: typeof d.schoolId === "string" ? d.schoolId : null, activityPoint: point(activity?.point) };
  }

  async isApprovedMember(carpoolId: string, uid: string): Promise<boolean> {
    const snap = await this.db.collection(MEMBERSHIPS).doc(membershipId(carpoolId, uid)).get();
    return snap.exists && snap.get("status") === "approved" && snap.get("carpoolId") === carpoolId && snap.get("uid") === uid;
  }

  async memberUids(carpoolId: string): Promise<string[]> {
    const snap = await this.db.collection(CARPOOLS).doc(carpoolId).collection(MEMBERS).limit(50).get();
    return snap.docs.map((d) => d.id);
  }

  async car(uid: string): Promise<CarCard | null> {
    const snap = await this.db.collection(VEHICLES).doc(uid).get();
    // Prompt 11: a renewal of the same car waiting for review keeps the approved car.
    const v = snap.exists ? usableVehicle(snap.data()) : null;
    if (!v || v.status !== "approved") return null;
    return { model: v.model, color: v.color, plate: v.plate };
  }

  async handover(childIds: string[]): Promise<Map<string, HandoverAdult[]>> {
    const out = new Map<string, HandoverAdult[]>();
    if (childIds.length === 0) return out;
    const snaps = await this.db.getAll(...childIds.map((id) => this.db.collection(HANDOVER_ADULTS).doc(id)));
    for (const s of snaps) if (s.exists) out.set(s.id, adults(s.get("adults")));
    return out;
  }

  async stopPoints(carpoolId: string, parentUids: string[], place: CarpoolPlace): Promise<TripStops> {
    const homes: Record<string, LatLng> = {};
    for (const uid of parentUids) {
      const shared = await this.db.collection(CARPOOLS).doc(carpoolId).collection(PICKUP_POINTS).doc(uid).get();
      const p = shared.exists ? point(shared.get("location")) : null;
      const home = p ? null : await this.db.collection(HOMES).doc(uid).get();
      const h = p ?? (home && home.exists ? point(home.get("location")) : null);
      if (h) homes[uid] = h;
    }
    let school: LatLng | null = place.activityPoint;
    if (place.kind === "school" && place.schoolId) {
      const s = await this.db.collection(SCHOOLS).doc(place.schoolId).get();
      school = s.exists ? point(s.get("location")) : null;
    }
    return { homes, school };
  }

  async trip(id: string): Promise<TripRecord | null> {
    const snap = await this.db.collection(TRIPS).doc(id).get();
    return snap.exists ? tripFromDoc(id, snap.data() ?? {}) : null;
  }

  async tripStops(id: string): Promise<TripStops | null> {
    const snap = await this.db.collection(TRIP_STOPS).doc(id).get();
    return snap.exists ? stopsFromDoc(snap.data() ?? {}) : null;
  }

  mutateTrip<T>(id: string, fn: (trip: TripRecord | null) => TripChange<T>): Promise<T> {
    const ref = this.db.collection(TRIPS).doc(id);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const change = fn(snap.exists ? tripFromDoc(id, snap.data() ?? {}) : null);
      if (change.trip) tx.set(ref, tripToDoc(change.trip));
      if (change.stops) {
        // Deleted with the trip's live data (expiresAt; TTL and tripTick).
        tx.set(this.db.collection(TRIP_STOPS).doc(id), { ...stopsToDoc(change.stops), expiresAt: ts(this.now() + 12 * 3_600_000) });
      }
      for (const e of change.events) tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(e.id), outboxDoc(e));
      return change.result;
    });
  }

  private now(): number {
    return Date.now();
  }

  async addPoints(id: string, points: TripPoint[], expiresAtMs: number): Promise<void> {
    const batch = this.db.batch();
    const col = this.db.collection(TRIPS).doc(id).collection(POINTS);
    // Also the Firestore TTL field; tripTick deletes them first.
    for (const p of points) batch.create(col.doc(), { ...pointTo(p), expiresAt: ts(expiresAtMs) });
    await batch.commit();
  }

  async putEtas(id: string, etas: EtaRecord[]): Promise<void> {
    if (etas.length === 0) return;
    const batch = this.db.batch();
    for (const e of etas) {
      const stops: Record<string, Timestamp> = {};
      for (const [childId, at] of Object.entries(e.stops)) stops[childId] = ts(at);
      batch.set(this.db.collection(TRIPS).doc(id).collection(ETA).doc(e.parentUid), { stops, updatedAt: ts(e.updatedAtMs), expiresAt: ts(e.updatedAtMs + 12 * 3_600_000) });
    }
    await batch.commit();
  }

  ensureCheck(id: string, check: TripCheck): Promise<TripCheck> {
    const ref = this.db.collection(TRIP_CHECKS).doc(id);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.exists) return checkFrom(snap.data() ?? {});
      tx.create(ref, { ...checkTo(check), expiresAt: ts(check.decidedAtMs + 30 * 86_400_000) });
      return check;
    });
  }

  async putCheck(id: string, check: TripCheck): Promise<void> {
    await this.db.collection(TRIP_CHECKS).doc(id).set({ ...checkTo(check), expiresAt: ts(check.decidedAtMs + 30 * 86_400_000) });
  }

  async liveTripIds(limit: number): Promise<string[]> {
    const snap = await this.db.collection(TRIPS).where("status", "in", ["active", "handover"]).limit(limit).get();
    return snap.docs.map((d) => d.id);
  }

  async liveTripsWithChild(childId: string): Promise<string[]> {
    // Index: firestore.indexes.json (childIds array-contains, status).
    const snap = await this.db.collection(TRIPS).where("childIds", "array-contains", childId).where("status", "in", ["active", "handover"]).limit(10).get();
    return snap.docs.map((d) => d.id);
  }

  async liveTripsOfDriver(uid: string): Promise<string[]> {
    const snap = await this.db.collection(TRIPS).where("driverUid", "==", uid).where("status", "==", "active").limit(10).get();
    return snap.docs.map((d) => d.id);
  }

  async child(childId: string): Promise<{ ownerUid: string; status: string } | null> {
    const snap = await this.db.collection(CHILDREN).doc(childId).get();
    return snap.exists ? { ownerUid: text(snap.get("ownerUid")), status: text(snap.get("status")) } : null;
  }

  async handoverEntries(childId: string): Promise<HandoverEntry[]> {
    const snap = await this.db.collection(HANDOVER_ADULTS).doc(childId).get();
    const list = snap.exists ? snap.get("adults") : null;
    return Array.isArray(list)
      ? list.map((a: Record<string, unknown>) => ({ name: text(a.name), relation: relation(a.relation), phone: typeof a.phone === "string" ? a.phone : null }))
      : [];
  }

  async putHandover(childId: string, ownerUid: string, list: HandoverEntry[], nowMs: number): Promise<void> {
    await this.db.collection(HANDOVER_ADULTS).doc(childId).set({ ownerUid, adults: list, updatedAt: ts(nowMs) });
  }

  async emergencyContact(uid: string): Promise<EmergencyContact | null> {
    const snap = await this.db.collection(EMERGENCY_CONTACTS).doc(uid).get();
    if (!snap.exists || typeof snap.get("phone") !== "string") return null;
    return { name: text(snap.get("name")), phone: text(snap.get("phone")), relation: relation(snap.get("relation")) };
  }

  async putEmergencyContact(uid: string, contact: EmergencyContact | null, nowMs: number): Promise<void> {
    const ref = this.db.collection(EMERGENCY_CONTACTS).doc(uid);
    if (contact) await ref.set({ ...contact, updatedAt: ts(nowMs) });
    else await ref.delete();
  }

  async addEmergency(
    carpoolId: string,
    e: { tripId: string; runId: string; driverUid: string; driverFirstName: string; point: LatLng | null; atMs: number; expiresAtMs: number },
  ): Promise<string> {
    const ref = this.db.collection(CARPOOLS).doc(carpoolId).collection(EMERGENCIES).doc();
    await ref.create({
      carpoolId,
      tripId: e.tripId,
      runId: e.runId,
      driverUid: e.driverUid,
      driverFirstName: e.driverFirstName,
      location: e.point ? new GeoPoint(e.point.lat, e.point.lng) : null,
      at: ts(e.atMs),
      expiresAt: ts(e.expiresAtMs),
    });
    return ref.id;
  }

  async addEvents(events: OutboxEvent[]): Promise<void> {
    const batch = this.db.batch();
    for (const e of events) batch.set(this.db.collection(NOTIFICATION_EVENTS).doc(e.id), outboxDoc(e));
    await batch.commit();
  }

  async addReport(report: TripReport, nowMs: number): Promise<void> {
    // The admin panel's reports queue (Prompt 4); "system" as the reporter.
    await this.db.collection(REPORTS).doc().create({
      reporterId: "system",
      targetType: "user",
      targetId: report.targetUid,
      reason: report.reason,
      urgent: report.urgent,
      tripId: report.tripId,
      status: "open",
      createdAt: ts(nowMs),
    });
  }

  async pauseDriving(uid: string, nowMs: number, reason: string): Promise<void> {
    // Same fields as Prompt 9's urgent-report pause, so the admin's "lift" clears it.
    await this.db.collection(USERS).doc(uid).update({
      drivingPaused: true,
      drivingPausedAt: ts(nowMs),
      drivingPauseReason: reason,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  async deleteExpired(nowMs: number, limit: number): Promise<number> {
    let deleted = 0;
    // Index: collection group "points" and "emergencies" on expiresAt (firestore.indexes.json).
    for (const group of [POINTS, EMERGENCIES, ETA]) {
      const snap = await this.db.collectionGroup(group).where("expiresAt", "<=", ts(nowMs)).limit(limit).get();
      if (snap.empty) continue;
      const batch = this.db.batch();
      for (const d of snap.docs) batch.delete(d.ref);
      await batch.commit();
      deleted += snap.size;
    }
    const stops = await this.db.collection(TRIP_STOPS).where("expiresAt", "<=", ts(nowMs)).limit(limit).get();
    if (!stops.empty) {
      const batch = this.db.batch();
      for (const d of stops.docs) batch.delete(d.ref);
      await batch.commit();
      deleted += stops.size;
    }
    return deleted;
  }

  async takeLimit(uid: string, kind: string, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(TRIP_LIMITS).doc(uid);
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
}
