import type { LatLng } from "../maps/geo";
import type { Direction, Rider, RunRecord } from "../schedule/model";

/**
 * Trips (Prompt 10: F15, F16, F20, F29, F33, F34, F35, F38, F41): records
 * and the pure rules. No Firestore here; flow.ts runs them over a
 * [TripStore].
 *
 * Records (only Cloud Functions write them):
 * - trips/{carpoolId}_{runId}: one per run that was started. Driver, car,
 *   one stop per child (first name, parent, state, handover names), the
 *   last point (cleared when tracking stops) and `viewerUids` (the
 *   driver and the parents of the children on THAT run): the only people
 *   firestore.rules lets read it.
 * - trips/{id}/points/{pointId}: live points, every 5 to 10 seconds while
 *   the run is on; same readers. Deleted within 24 hours (tripTick, and a
 *   Firestore TTL on `expiresAt` as a backup).
 * - trips/{id}/eta/{parentUid}: arrival time at that parent's stop; that
 *   parent and the driver only.
 * - tripStops/{id}: the EXACT stop points (homes, school) for the arrival
 *   times. Cloud Functions only.
 * - tripChecks/{id}: the random selfie check of that run (F38); the driver.
 * - handoverAdults/{childId}: adults allowed to receive a child (F29); the
 *   parent. Copied (names and relations only) into the child's stop.
 * - emergencyContacts/{uid}: the parent's saved emergency contact (F20).
 * - carpools/{id}/emergencies/{id}: an emergency alert with its point;
 *   approved members of the carpool. Deleted after 24 hours.
 */

/**
 * active: tracking, the driver works through the stops.
 * handover: every child was dropped; tracking stopped; afternoon
 *   handovers wait for the receiving parent (F34).
 * ended: done (or timed out).
 */
export type TripStatus = "active" | "handover" | "ended";

/**
 * waiting: not picked up yet. arrived: the driver tapped Arrived (morning:
 * at the home; afternoon: at the home with the child on board).
 * onBoard: picked up. dropped: dropped at school (morning) or handed over
 * (afternoon). received: the receiving parent confirmed (afternoon).
 * absent: marked away (F27); not part of the run.
 */
export type StopState = "waiting" | "arrived" | "onBoard" | "dropped" | "received" | "absent";

export interface HandoverAdult {
  name: string;
  relation: Relation;
}

export const RELATIONS = ["mother", "father", "grandparent", "sibling", "relative", "nanny", "other"] as const;
export type Relation = (typeof RELATIONS)[number];

export interface Stop {
  childId: string;
  firstName: string;
  parentUid: string;
  state: StopState;
  /** Arrived taps (F41: a second tap repeats the alert). */
  arrivedCount: number;
  arrivedAtMs: number | null;
  pickedUpAtMs: number | null;
  droppedAtMs: number | null;
  receivedAtMs: number | null;
  /** F34: "child not confirmed" was sent for this stop. */
  notConfirmedAtMs: number | null;
  /** F29: names and relations only (no phone numbers). */
  handover: HandoverAdult[];
}

export interface TripPoint {
  lat: number;
  lng: number;
  /** Metres, km/h and degrees; null when the phone did not give them. */
  accuracy: number | null;
  speed: number | null;
  heading: number | null;
  atMs: number;
}

export interface CarCard {
  model: string;
  color: string;
  plate: string;
}

export type QuickKind = "late" | "gate" | "allIn";
export const QUICK_KINDS: readonly QuickKind[] = ["late", "gate", "allIn"];

export interface TripRecord {
  /** "{carpoolId}_{runId}". */
  id: string;
  carpoolId: string;
  runId: string;
  date: string;
  direction: Direction;
  driverUid: string;
  driverFirstName: string;
  car: CarCard | null;
  status: TripStatus;
  startedAtMs: number;
  /** When tracking stopped (last drop-off, or timeout). */
  trackingEndedAtMs: number | null;
  endedAtMs: number | null;
  endReason: "done" | "timeout" | null;
  /** The driver and the parents of the children on this run. */
  viewerUids: string[];
  /** Child IDs (array-contains queries for handover updates). */
  childIds: string[];
  stops: Stop[];
  /** Exact last point while tracking; null once tracking stopped. */
  last: TripPoint | null;
  lastPointAtMs: number | null;
  /** "location stopped" was sent and no point came since. */
  staleAlertedAtMs: number | null;
  /** sha256 of the upload token (hex); the token itself is never stored. */
  tokenHash: string;
  tokenExpiresAtMs: number;
  lastEtaAtMs: number | null;
  /** Quick messages posted (F35), newest last, at most MAX_MESSAGES. */
  messages: Array<{ kind: QuickKind; atMs: number }>;
  /** Request IDs already applied (offline retries never apply twice). */
  doneRequests: string[];
  updatedAtMs: number;
}

/** Exact stop points (tripStops/{id}); Cloud Functions only. */
export interface TripStops {
  /** Home (or shared pickup point) per parent with a child on the run. */
  homes: Record<string, LatLng>;
  /** The school (or activity place). */
  school: LatLng | null;
}

export interface EtaRecord {
  parentUid: string;
  /** Child ID -> expected arrival (ms) at that child's stop. */
  stops: Record<string, number>;
  updatedAtMs: number;
}

export type SelfieStatus = "none" | "required" | "passed" | "failed" | "error";

export interface TripCheck {
  driverUid: string;
  status: SelfieStatus;
  decidedAtMs: number;
  checkedAtMs: number | null;
}

export interface EmergencyContact {
  name: string;
  /** E.164; never logged in clear. */
  phone: string;
  relation: Relation;
}

export interface TripSettings {
  /** No point for this long: "location stopped" (F15). */
  staleMs: number;
  /** Arrival times at most this often per trip (COST MODE: once a minute). */
  etaIntervalMs: number;
  /** F34: the receiving parent confirms within this time. */
  handoverMs: number;
  /** Share of runs that ask for a selfie first (F38), 0 to 100. */
  selfiePercent: number;
  /** Points closer together than this are dropped (5 to 10 s target). */
  minPointGapMs: number;
}

export const DEFAULT_TRIP_SETTINGS: TripSettings = {
  staleMs: 120_000,
  etaIntervalMs: 60_000,
  handoverMs: 10 * 60_000,
  selfiePercent: 20,
  minPointGapMs: 4_000,
};

function bounded(v: number, min: number, max: number, fallback: number): number {
  return Number.isInteger(v) && v >= min && v <= max ? v : fallback;
}

/** Settings from params; a bad value falls back to the default. */
export function tripSettings(staleSec: number, selfiePercent: number, handoverMin: number): Partial<TripSettings> {
  return {
    staleMs: bounded(staleSec, 30, 900, 120) * 1000,
    selfiePercent: bounded(selfiePercent, 0, 100, 20),
    handoverMs: bounded(handoverMin, 2, 60, 10) * 60_000,
  };
}

/** A run may start from this long before its time ... */
export const START_EARLY_MS = 60 * 60_000;
/** ... until this long after it. */
export const START_LATE_MS = 3 * 60 * 60_000;
/** Tracking stops by itself after this long (a forgotten run). */
export const MAX_TRACKING_MS = 4 * 60 * 60_000;
/** Afternoon handovers are watched this long after tracking stopped. */
export const MAX_HANDOVER_WATCH_MS = 2 * 60 * 60_000;
/** Live points are deleted after this long (well inside 24 hours). */
export const POINT_KEEP_MS = 12 * 60 * 60_000;
/** Emergency alerts (with their point) are deleted after this long. */
export const EMERGENCY_KEEP_MS = 24 * 60 * 60_000;
export const MAX_POINTS_PER_UPLOAD = 50;
export const MAX_MESSAGES = 20;
export const MAX_DONE_REQUESTS = 60;
export const MAX_HANDOVER_ADULTS = 6;
/** The same quick message at most once in this window. */
export const QUICK_GAP_MS = 2 * 60_000;

export type TripErrorReason =
  | "invalid-request"
  | "not-verified"
  | "suspended"
  | "not-found"
  | "not-driver"
  | "not-member"
  | "not-parent"
  | "not-confirmed"
  | "too-early"
  | "too-late"
  | "driving-paused"
  | "selfie-required"
  | "no-reference"
  | "trip-not-active"
  | "wrong-state"
  | "no-contact"
  | "rate-limited";

export const TRIP_ERROR_CODES: Record<TripErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "not-verified": "permission-denied",
  suspended: "permission-denied",
  "not-found": "not-found",
  "not-driver": "permission-denied",
  "not-member": "permission-denied",
  "not-parent": "permission-denied",
  "not-confirmed": "failed-precondition",
  "too-early": "failed-precondition",
  "too-late": "failed-precondition",
  "driving-paused": "failed-precondition",
  "selfie-required": "failed-precondition",
  "no-reference": "failed-precondition",
  "trip-not-active": "failed-precondition",
  "wrong-state": "failed-precondition",
  "no-contact": "failed-precondition",
  "rate-limited": "resource-exhausted",
};

export class TripError extends Error {
  constructor(readonly reason: TripErrorReason) {
    super(reason);
    this.name = "TripError";
  }
}

export function tripId(carpoolId: string, runId: string): string {
  return `${carpoolId}_${runId}`;
}

// --------------------------------------------------------------------------
// Starting (F15)
// --------------------------------------------------------------------------

/**
 * Why [uid] may not start [run] now, or null. Only the confirmed driver
 * (status "confirmed", or "completed" once the schedule tick counted it),
 * from START_EARLY_MS before the run's time to START_LATE_MS after it.
 */
export function startProblem(run: RunRecord, uid: string, nowMs: number): TripErrorReason | null {
  if (run.driverUid !== uid) return "not-driver";
  if (run.status !== "confirmed" && run.status !== "completed") return "not-confirmed";
  if (nowMs < run.startMs - START_EARLY_MS) return "too-early";
  if (nowMs > run.startMs + START_LATE_MS) return "too-late";
  return null;
}

/** The stops of a new trip: riders in pickup-list order, then absent children. */
export function stopsFor(riders: Rider[], absent: Rider[], handover: Map<string, HandoverAdult[]>): Stop[] {
  const stop = (r: Rider, state: StopState): Stop => ({
    childId: r.id,
    firstName: r.firstName,
    parentUid: r.parentUid,
    state,
    arrivedCount: 0,
    arrivedAtMs: null,
    pickedUpAtMs: null,
    droppedAtMs: null,
    receivedAtMs: null,
    notConfirmedAtMs: null,
    handover: handover.get(r.id) ?? [],
  });
  return [...riders.map((r) => stop(r, "waiting")), ...absent.filter((a) => !riders.some((r) => r.id === a.id)).map((a) => stop(a, "absent"))];
}

/** The driver and every parent with a child riding (absent children's parents do not watch). */
export function viewersOf(driverUid: string, stops: Stop[]): string[] {
  return [...new Set([driverUid, ...stops.filter((s) => s.state !== "absent").map((s) => s.parentUid)])].sort();
}

/**
 * F38: whether this run asks for a selfie. [roll] is a uniform random
 * number in [0, 100). Decided once per run and stored, so asking again
 * never re-rolls.
 */
export function selfieRequired(percent: number, roll: number, hasReference: boolean): boolean {
  if (!hasReference) return false;
  const p = Math.max(0, Math.min(100, percent));
  return roll < p;
}

// --------------------------------------------------------------------------
// Driver actions (F16, F41)
// --------------------------------------------------------------------------

export type DriverAction = "arrived" | "pickedUp" | "dropped";
export const DRIVER_ACTIONS: readonly DriverAction[] = ["arrived", "pickedUp", "dropped"];

/**
 * The stop after [action], or null when it does not fit the stop's state.
 * Morning: waiting -> (arrived) -> onBoard -> dropped (at school).
 * Afternoon: waiting -> onBoard (at school) -> (arrived at home) -> dropped
 * (handed over) -> received (by the parent).
 * Arrived may be tapped again (repeats the alert) until the next step.
 */
export function applyAction(stop: Stop, action: DriverAction, direction: Direction, nowMs: number): Stop | null {
  const morning = direction === "toSchool";
  switch (action) {
    case "arrived": {
      const ok = morning ? stop.state === "waiting" || stop.state === "arrived" : stop.state === "onBoard" || stop.state === "arrived";
      if (!ok) return null;
      return { ...stop, state: "arrived", arrivedCount: stop.arrivedCount + 1, arrivedAtMs: nowMs };
    }
    case "pickedUp": {
      const ok = morning ? stop.state === "waiting" || stop.state === "arrived" : stop.state === "waiting";
      if (!ok) return null;
      return { ...stop, state: "onBoard", pickedUpAtMs: nowMs };
    }
    case "dropped": {
      const ok = morning ? stop.state === "onBoard" : stop.state === "onBoard" || stop.state === "arrived";
      if (!ok) return null;
      return { ...stop, state: "dropped", droppedAtMs: nowMs };
    }
  }
}

/** Every riding child is dropped (or received): tracking stops. */
export function allDropped(stops: Stop[]): boolean {
  return stops.every((s) => s.state === "absent" || s.state === "dropped" || s.state === "received");
}

/** Afternoon drop-offs still waiting for the receiving parent (F34). */
export function pendingHandovers(trip: Pick<TripRecord, "direction" | "stops">): Stop[] {
  return trip.direction === "toHome" ? trip.stops.filter((s) => s.state === "dropped") : [];
}

/** F34: dropped this long ago, not confirmed, not alerted yet. */
export function overdueHandovers(trip: Pick<TripRecord, "direction" | "stops">, nowMs: number, handoverMs: number): Stop[] {
  return pendingHandovers(trip).filter((s) => s.notConfirmedAtMs === null && s.droppedAtMs !== null && nowMs - s.droppedAtMs >= handoverMs);
}

/** Remembers a request ID (bounded list). */
export function withRequest(done: string[], requestId: string | null): string[] {
  if (!requestId) return done;
  return [...done.filter((r) => r !== requestId), requestId].slice(-MAX_DONE_REQUESTS);
}

/** The trip after the last drop-off: tracking stops (and the last point goes). */
export function stopTracking(trip: TripRecord, nowMs: number, reason: "done" | "timeout"): TripRecord {
  const waiting = reason === "done" && pendingHandovers(trip).length > 0;
  return {
    ...trip,
    status: waiting ? "handover" : "ended",
    trackingEndedAtMs: trip.trackingEndedAtMs ?? nowMs,
    endedAtMs: waiting ? null : nowMs,
    endReason: reason,
    last: null,
    // The upload token stops working at once.
    tokenExpiresAtMs: Math.min(trip.tokenExpiresAtMs, nowMs),
    updatedAtMs: nowMs,
  };
}

// --------------------------------------------------------------------------
// Live location (F15)
// --------------------------------------------------------------------------

/** True when "location stopped" should be sent now. */
export function isStale(trip: Pick<TripRecord, "status" | "lastPointAtMs" | "startedAtMs" | "staleAlertedAtMs">, nowMs: number, staleMs: number): boolean {
  if (trip.status !== "active" || trip.staleAlertedAtMs !== null) return false;
  const since = trip.lastPointAtMs ?? trip.startedAtMs;
  return nowMs - since > staleMs;
}

function finite(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

/**
 * Points from one upload of the location plugin. It posts
 * `{ location: {...} }` or `{ location: [...] }` with `coords` and an ISO
 * `timestamp`; plain `{ lat, lng, atMs }` is accepted too (tests, scripts).
 * Bad points are dropped, never trusted.
 */
export function parseUpload(body: unknown): TripPoint[] {
  const root = typeof body === "object" && body !== null ? (body as Record<string, unknown>) : {};
  const raw = root.location ?? root.locations ?? root.points;
  const list = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const out: TripPoint[] = [];
  for (const item of list.slice(0, MAX_POINTS_PER_UPLOAD)) {
    if (typeof item !== "object" || item === null) continue;
    const x = item as Record<string, unknown>;
    const c = (typeof x.coords === "object" && x.coords !== null ? x.coords : x) as Record<string, unknown>;
    const lat = finite(c.latitude ?? c.lat);
    const lng = finite(c.longitude ?? c.lng);
    const atMs = typeof x.timestamp === "string" ? Date.parse(x.timestamp) : finite(x.atMs);
    if (lat === null || lng === null || atMs === null || Number.isNaN(atMs)) continue;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) continue;
    const speedMs = finite(c.speed);
    const accuracy = finite(c.accuracy);
    const heading = finite(c.heading);
    out.push({
      lat,
      lng,
      accuracy: accuracy !== null && accuracy >= 0 ? Math.round(accuracy) : null,
      // The plugin gives m/s; -1 means unknown.
      speed: speedMs !== null && speedMs >= 0 ? Math.round(speedMs * 3.6) : null,
      heading: heading !== null && heading >= 0 && heading <= 360 ? Math.round(heading) : null,
      atMs,
    });
  }
  return out;
}

/**
 * The points to keep, in time order: inside the trip's time (from its
 * start, at most one minute in the future), at least [minGapMs] after the
 * previous kept point, and very inaccurate fixes (over 500 m) dropped.
 */
export function acceptPoints(points: TripPoint[], lastAtMs: number | null, startedAtMs: number, nowMs: number, minGapMs: number): TripPoint[] {
  const sorted = [...points].sort((a, b) => a.atMs - b.atMs);
  const out: TripPoint[] = [];
  let prev = lastAtMs;
  for (const p of sorted) {
    if (p.atMs < startedAtMs - 60_000 || p.atMs > nowMs + 60_000) continue;
    if (p.accuracy !== null && p.accuracy > 500) continue;
    if (prev !== null && p.atMs - prev < minGapMs) continue;
    out.push(p);
    prev = p.atMs;
  }
  return out;
}

// --------------------------------------------------------------------------
// Arrival times (Routes, COST MODE)
// --------------------------------------------------------------------------

/** True when the trip may ask Routes again: at most once per [intervalMs] (one call covers every stop). */
export function etaDue(lastEtaAtMs: number | null, nowMs: number, intervalMs: number): boolean {
  return lastEtaAtMs === null || nowMs - lastEtaAtMs >= intervalMs;
}

export interface Waypoint {
  /** Children whose arrival time this waypoint gives, with their parent. */
  children: Array<{ childId: string; parentUid: string }>;
  point: LatLng;
}

/**
 * The route still ahead, in pickup-list order. Morning: the homes of
 * children not picked up yet, then the school (the arrival time of every
 * child on board). Afternoon: the homes of children on board (not dropped
 * yet). Children at the same point share one waypoint.
 */
export function routeAhead(trip: Pick<TripRecord, "direction" | "stops" | "status">, stops: TripStops): Waypoint[] {
  if (trip.status !== "active") return [];
  const out: Waypoint[] = [];
  const add = (s: Stop, point: LatLng | undefined | null) => {
    if (!point) return;
    const same = out.find((w) => w.point.lat === point.lat && w.point.lng === point.lng);
    if (same) same.children.push({ childId: s.childId, parentUid: s.parentUid });
    else out.push({ children: [{ childId: s.childId, parentUid: s.parentUid }], point });
  };
  if (trip.direction === "toSchool") {
    const toPick = trip.stops.filter((s) => s.state === "waiting" || s.state === "arrived");
    for (const s of toPick) add(s, stops.homes[s.parentUid]);
    const onBoard = trip.stops.filter((s) => s.state === "onBoard");
    if (stops.school && (onBoard.length > 0 || toPick.length > 0)) {
      out.push({ children: onBoard.map((s) => ({ childId: s.childId, parentUid: s.parentUid })), point: stops.school });
    }
  } else {
    for (const s of trip.stops) if (s.state === "onBoard" || s.state === "arrived") add(s, stops.homes[s.parentUid]);
  }
  return out;
}

/**
 * Arrival time per parent and child from the route's leg durations
 * (seconds, one per waypoint, cumulative from [nowMs]). Morning children
 * still to be picked up get their home's time (the parent sends them
 * down); children on board get the school's.
 */
export function etasFrom(waypoints: Waypoint[], legSeconds: number[], nowMs: number): Map<string, Record<string, number>> {
  const out = new Map<string, Record<string, number>>();
  let t = nowMs;
  waypoints.forEach((w, i) => {
    t += Math.max(0, Math.round(legSeconds[i] ?? 0)) * 1000;
    for (const c of w.children) {
      const rec = out.get(c.parentUid) ?? {};
      rec[c.childId] = t;
      out.set(c.parentUid, rec);
    }
  });
  return out;
}

// --------------------------------------------------------------------------
// Input
// --------------------------------------------------------------------------

const DOC_ID = /^[A-Za-z0-9_-]{1,128}$/;
const REQUEST_ID = /^[A-Za-z0-9_-]{8,64}$/;
const NAME = /^[\p{L}\p{M}][\p{L}\p{M} .'’-]{0,38}[\p{L}\p{M}.]$/u;

export function record(data: unknown): Record<string, unknown> {
  return typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
}

export function idOf(value: unknown): string {
  if (typeof value !== "string" || !DOC_ID.test(value)) throw new TripError("invalid-request");
  return value;
}

export function requestIdOf(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !REQUEST_ID.test(value)) throw new TripError("invalid-request");
  return value;
}

export function nameOf(value: unknown): string {
  const v = typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
  if (!NAME.test(v)) throw new TripError("invalid-request");
  return v;
}

export function relationOf(value: unknown): Relation {
  if (!(RELATIONS as readonly unknown[]).includes(value)) throw new TripError("invalid-request");
  return value as Relation;
}

export function pointOf(value: unknown): LatLng | null {
  const p = record(value);
  const lat = finite(p.lat);
  const lng = finite(p.lng);
  if (lat === null || lng === null || lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return { lat, lng };
}

/** A Google Maps link to [p] for the emergency contact (rounded to about 1 m). */
export function mapsLink(p: LatLng): string {
  return `https://maps.google.com/?q=${p.lat.toFixed(5)},${p.lng.toFixed(5)}`;
}
