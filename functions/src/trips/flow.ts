import { createHash, timingSafeEqual } from "node:crypto";
import { toEgyptE164 } from "../auth/phone";
import { cairoDate } from "../carpools/model";
import type { LatLng } from "../maps/geo";
import type { NotificationType } from "../notifications/catalog";
import { newEvent, type OutboxEvent } from "../notifications/model";
import { parseRunId, type RunRecord } from "../schedule/model";
import { driverPhotoPath, faceRefPath } from "../verification/submission";
import type { Language } from "../whatsapp/sender";
import {
  acceptPoints,
  allDropped,
  applyAction,
  DEFAULT_TRIP_SETTINGS,
  DRIVER_ACTIONS,
  EMERGENCY_KEEP_MS,
  etaDue,
  etasFrom,
  idOf,
  isStale,
  mapsLink,
  ARRIVED_GAP_MS,
  MAX_ARRIVED_PER_STOP,
  MAX_HANDOVER_ADULTS,
  onBoard,
  MAX_HANDOVER_WATCH_MS,
  MAX_MESSAGES,
  MAX_TRACKING_MS,
  nameOf,
  overdueHandovers,
  parseUpload,
  pendingHandovers,
  pointOf,
  QUICK_GAP_MS,
  QUICK_KINDS,
  record,
  relationOf,
  requestIdOf,
  routeAhead,
  selfieRequired,
  startProblem,
  stopsFor,
  stopTracking,
  TripError,
  tripId,
  viewersOf,
  withRequest,
  type CarCard,
  type DriverAction,
  type EmergencyContact,
  type EtaRecord,
  type HandoverAdult,
  type QuickKind,
  type Relation,
  type Stop,
  type TripCheck,
  type TripPoint,
  type TripRecord,
  type TripSettings,
  type TripStops,
} from "./model";
import type { RoutesProvider } from "./routes";

/**
 * Trip flows (Prompt 10). Every trip write happens here; the app never
 * writes a trip, a point, a stop state or a check (firestore.rules).
 * Logs get counts and reasons only: never names, phone numbers or
 * coordinates (CLAUDE.md, PRIVACY).
 */

// --------------------------------------------------------------------------
// Store and dependencies
// --------------------------------------------------------------------------

export interface TripAccount {
  status: string;
  firstName: string;
  /** F38: a failed selfie check paused this parent's driving. */
  drivingPaused: boolean;
  language: Language;
}

export interface CarpoolPlace {
  kind: "school" | "activity";
  schoolId: string | null;
  activityPoint: LatLng | null;
}

export interface HandoverEntry extends HandoverAdult {
  /** Kept for the parent only; never copied into a trip. */
  phone: string | null;
}

export interface TripReport {
  targetUid: string;
  reason: "selfie-mismatch" | "selfie-error";
  urgent: boolean;
  tripId: string;
}

/** What one mutation of a trip writes (all in one transaction). */
export interface TripChange<T> {
  trip: TripRecord | null;
  events: OutboxEvent[];
  result: T;
  /** Written with a new trip only. */
  stops?: TripStops;
}

export interface TripStore {
  account(uid: string): Promise<TripAccount | null>;
  run(carpoolId: string, runId: string): Promise<RunRecord | null>;
  /** Runs of [carpoolId] on [date] (both directions). */
  runsOn(carpoolId: string, date: string): Promise<RunRecord[]>;
  carpool(carpoolId: string): Promise<CarpoolPlace | null>;
  isApprovedMember(carpoolId: string, uid: string): Promise<boolean>;
  memberUids(carpoolId: string): Promise<string[]>;
  /** The approved car's model, color and plate, or null. */
  car(uid: string): Promise<CarCard | null>;
  /** F29: names and relations per child. */
  handover(childIds: string[]): Promise<Map<string, HandoverAdult[]>>;
  /** EXACT stop points: shared pickup point, else the home; the school or activity place. */
  stopPoints(carpoolId: string, parentUids: string[], place: CarpoolPlace): Promise<TripStops>;
  trip(id: string): Promise<TripRecord | null>;
  tripStops(id: string): Promise<TripStops | null>;
  /** Reads the trip, applies [fn] and writes its result in ONE transaction. */
  mutateTrip<T>(id: string, fn: (trip: TripRecord | null) => TripChange<T>): Promise<T>;
  addPoints(id: string, points: TripPoint[], expiresAtMs: number): Promise<void>;
  putEtas(id: string, etas: EtaRecord[]): Promise<void>;
  /** Creates the check unless one exists; returns the stored one. */
  ensureCheck(id: string, check: TripCheck): Promise<TripCheck>;
  putCheck(id: string, check: TripCheck): Promise<void>;
  /** Trips being tracked or waiting for handovers. */
  liveTripIds(limit: number): Promise<string[]>;
  /** Live trips with [childId] on them. */
  liveTripsWithChild(childId: string): Promise<string[]>;
  /** Trips [uid] is driving that are still tracked. */
  liveTripsOfDriver(uid: string): Promise<string[]>;
  child(childId: string): Promise<{ ownerUid: string; status: string } | null>;
  handoverEntries(childId: string): Promise<HandoverEntry[]>;
  putHandover(childId: string, ownerUid: string, adults: HandoverEntry[], nowMs: number): Promise<void>;
  emergencyContact(uid: string): Promise<EmergencyContact | null>;
  putEmergencyContact(uid: string, contact: EmergencyContact | null, nowMs: number): Promise<void>;
  /** carpools/{id}/emergencies/{new id}; returns the ID. */
  addEmergency(carpoolId: string, e: { tripId: string; runId: string; driverUid: string; driverFirstName: string; point: LatLng | null; atMs: number; expiresAtMs: number }): Promise<string>;
  addEvents(events: OutboxEvent[]): Promise<void>;
  addReport(report: TripReport, nowMs: number): Promise<void>;
  /** F38: users/{uid}.drivingPaused; schedule assignments treat the car as unusable. */
  pauseDriving(uid: string, nowMs: number, reason: string): Promise<void>;
  /** Deletes live points and emergencies past their time; returns how many. */
  deleteExpired(nowMs: number, limit: number): Promise<number>;
  takeLimit(uid: string, kind: string, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;
}

export interface TripFiles {
  /** Files under [prefix] with their creation time (the selfie sweep). */
  list(prefix: string): Promise<Array<{ path: string; createdMs: number }>>;
  exists(path: string): Promise<boolean>;
  read(path: string): Promise<Buffer>;
  delete(path: string): Promise<void>;
  signedReadUrl(path: string, expiresAtMs: number): Promise<string>;
}

export interface FaceMatcher {
  /** "match", "no_match" or "error" (never throws for a bad face). */
  matchFace(reference: () => Promise<Buffer>, live: () => Promise<Buffer>): Promise<"match" | "no_match" | "error">;
}

export interface ContactNotifier {
  sendTemplate(toE164: string, template: string, language: Language, params: string[], preview: string): Promise<void>;
}

/**
 * F35 (Prompt 9 merged): posts a driver's quick message into the
 * carpool's group chat as a system message. Never the location.
 */
export interface QuickChatPoster {
  post(carpoolId: string, messageId: string, text: string, extra: Record<string, string>): Promise<void>;
}

export interface TripDeps {
  store: TripStore;
  files: TripFiles;
  faces: FaceMatcher;
  routes: RoutesProvider;
  whatsapp: ContactNotifier;
  /** F38: releases every future run [uid] drives (Prompt 7's releaseRun); returns how many. */
  releaseRuns: (uid: string, nowMs: number) => Promise<number>;
  now: () => number;
  /** A new upload token (random, URL safe). */
  newToken: () => string;
  /** Uniform in [0, 100). */
  roll: () => number;
  settings?: Partial<TripSettings>;
  log: (message: string, data?: Record<string, unknown>) => void;
  /** The carpool chat (absent in tests that do not need it). */
  chat?: QuickChatPoster;
}

export interface Caller {
  uid: string;
  verifiedClaim: boolean;
}

/** Storage paths (storage.rules): the driver uploads the live selfie; the photo is kept from verification. */
export { driverPhotoPath };
export const selfiePath = (uid: string, id: string): string => `selfieChecks/${uid}/${id}.jpg`;
/** The identity selfie kept as the face reference when the account was approved (F38). */
export { faceRefPath };
export const EMERGENCY_TEMPLATE = "cp_emergency_contact";

const settingsOf = (deps: TripDeps): TripSettings => ({ ...DEFAULT_TRIP_SETTINGS, ...(deps.settings ?? {}) });

export function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function sameHash(a: string, b: string): boolean {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && x.length > 0 && timingSafeEqual(x, y);
}

async function requireVerified(deps: TripDeps, caller: Caller): Promise<TripAccount> {
  if (!caller.verifiedClaim) throw new TripError("not-verified");
  const account = await deps.store.account(caller.uid);
  if (!account) throw new TripError("not-verified");
  if (account.status === "suspended") throw new TripError("suspended");
  if (account.status !== "verified") throw new TripError("not-verified");
  return account;
}

async function take(deps: TripDeps, uid: string, kind: string, windowMs: number, max: number): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), { windowMs, max });
  if (!r.allowed) throw new TripError("rate-limited");
}

function parseRun(data: unknown): { carpoolId: string; runId: string } {
  const raw = record(data);
  const carpoolId = idOf(raw.carpoolId);
  if (!parseRunId(raw.runId)) throw new TripError("invalid-request");
  return { carpoolId, runId: raw.runId as string };
}

function tripEvent(type: NotificationType, trip: TripRecord, key: string, recipients: string[], nowMs: number, extra: { actorUid?: string | null; childId?: string | null } = {}): OutboxEvent {
  return newEvent(`${type}_${trip.id}_${key}`.slice(0, 700), type, recipients, nowMs, {
    carpoolId: trip.carpoolId,
    runId: trip.runId,
    date: trip.date,
    direction: trip.direction,
    actorUid: extra.actorUid ?? null,
    childId: extra.childId ?? null,
  });
}

const parentsOf = (trip: TripRecord): string[] => trip.viewerUids.filter((u) => u !== trip.driverUid);

// --------------------------------------------------------------------------
// Before the run: selfie check (F38) and start (F15)
// --------------------------------------------------------------------------

export interface PrepareResult {
  tripId: string;
  selfieRequired: boolean;
  selfieStatus: TripCheck["status"];
  active: boolean;
}

/**
 * Who may act on the run before it starts: the verified, not paused,
 * confirmed driver of the run (or the driver of the trip already started).
 * Checked BEFORE any check record is written, so another parent can never
 * block a run or decide its selfie check (review item 2).
 */
async function runForDriver(deps: TripDeps, caller: Caller, data: unknown): Promise<{ carpoolId: string; runId: string; id: string; run: RunRecord; existing: TripRecord | null; nowMs: number }> {
  const account = await requireVerified(deps, caller);
  if (account.drivingPaused) throw new TripError("driving-paused");
  const { carpoolId, runId } = parseRun(data);
  const run = await deps.store.run(carpoolId, runId);
  if (!run) throw new TripError("not-found");
  const nowMs = deps.now();
  const id = tripId(carpoolId, runId);
  const existing = await deps.store.trip(id);
  if (existing) {
    if (existing.driverUid !== caller.uid) throw new TripError("not-driver");
    if (existing.status !== "active") throw new TripError("too-late");
  } else {
    const problem = startProblem(run, caller.uid, nowMs);
    if (problem) throw new TripError(problem);
  }
  return { carpoolId, runId, id, run, existing, nowMs };
}

/**
 * The face reference of a driver (F38): the driver photo approved during
 * verification, else the identity selfie kept when the account was
 * approved. A driver without one cannot start a run (review item 6).
 */
export async function faceReference(deps: TripDeps, uid: string): Promise<string | null> {
  for (const path of [driverPhotoPath(uid), faceRefPath(uid)]) {
    if (await deps.files.exists(path)) return path;
  }
  return null;
}

/** The selfie-check record of one run AND one driver: a swap gets a new decision. */
export const checkId = (tripIdValue: string, uid: string): string => `${tripIdValue}_${uid}`;

/** Decides once per run and driver whether a live selfie is needed first (F38). */
async function decideCheck(deps: TripDeps, id: string, uid: string, nowMs: number): Promise<TripCheck> {
  return deps.store.ensureCheck(checkId(id, uid), {
    driverUid: uid,
    status: selfieRequired(settingsOf(deps).selfiePercent, deps.roll(), true) ? "required" : "none",
    decidedAtMs: nowMs,
    checkedAtMs: null,
  });
}

/**
 * The driver opens the start screen. Checks the run like start does, needs
 * a face reference, and decides once per run and driver whether a live
 * selfie is needed first (F38: some runs, at random).
 */
export async function prepareTrip(deps: TripDeps, caller: Caller, data: unknown): Promise<PrepareResult> {
  const { id, existing, nowMs } = await runForDriver(deps, caller, data);
  if (!(await faceReference(deps, caller.uid))) throw new TripError("no-reference");
  const check = await decideCheck(deps, id, caller.uid, nowMs);
  return { tripId: id, selfieRequired: check.status === "required" || check.status === "failed", selfieStatus: check.status, active: existing?.status === "active" };
}

/**
 * F38: the driver took the live selfie (uploaded to selfieChecks/{uid}/{tripId}.jpg).
 * Matched against the driver's face reference (KycProvider's face match).
 * The selfie is deleted on EVERY path, refusals included (review item 3);
 * tripTick also sweeps any left behind. A mismatch pauses the driver's
 * driving days (Prompt 9's pause) and files an urgent report.
 */
export async function submitSelfieCheck(deps: TripDeps, caller: Caller, data: unknown): Promise<{ status: TripCheck["status"] }> {
  const raw = record(data);
  const live = typeof raw.carpoolId === "string" && typeof raw.runId === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(raw.carpoolId) && parseRunId(raw.runId)
    ? selfiePath(caller.uid, tripId(raw.carpoolId, raw.runId))
    : null;
  try {
    return await checkSelfie(deps, caller, data);
  } finally {
    // Never kept (spec section 7: face images only as long as needed).
    if (live) await deps.files.delete(live);
  }
}

async function checkSelfie(deps: TripDeps, caller: Caller, data: unknown): Promise<{ status: TripCheck["status"] }> {
  const { id, nowMs } = await runForDriver(deps, caller, data);
  await take(deps, caller.uid, "selfieChecks", 86_400_000, 10);
  const reference = await faceReference(deps, caller.uid);
  if (!reference) throw new TripError("no-reference");
  const check = await decideCheck(deps, id, caller.uid, nowMs);
  if (check.status === "passed" || check.status === "none" || check.status === "error") return { status: check.status };
  if (check.status === "failed") throw new TripError("driving-paused");
  const live = selfiePath(caller.uid, id);
  if (!(await deps.files.exists(live))) throw new TripError("invalid-request");
  const result = await deps.faces.matchFace(() => deps.files.read(reference), () => deps.files.read(live));
  const key = checkId(id, caller.uid);
  if (result === "match") {
    await deps.store.putCheck(key, { ...check, status: "passed", checkedAtMs: nowMs });
    return { status: "passed" };
  }
  if (result === "error") {
    // The provider could not decide: the run may go on; a person looks later.
    await deps.store.putCheck(key, { ...check, status: "error", checkedAtMs: nowMs });
    await deps.store.addReport({ targetUid: caller.uid, reason: "selfie-error", urgent: false, tripId: id }, nowMs);
    deps.log("selfie check could not decide; report filed");
    return { status: "error" };
  }
  await deps.store.putCheck(key, { ...check, status: "failed", checkedAtMs: nowMs });
  await deps.store.pauseDriving(caller.uid, nowMs, "selfie-mismatch");
  const released = await deps.releaseRuns(caller.uid, nowMs);
  await deps.store.addReport({ targetUid: caller.uid, reason: "selfie-mismatch", urgent: true, tripId: id }, nowMs);
  deps.log("selfie check mismatch: driving paused", { released });
  return { status: "failed" };
}

export interface StartResult {
  tripId: string;
  /** Bearer token for the location uploads of THIS trip only. */
  token: string;
  expiresAtMs: number;
  staleSeconds: number;
}

/**
 * F15: the confirmed driver starts the run (the app has turned live
 * location on first: background permission after the explanation screen).
 * Starting again while the trip is active gives a new token (the app was
 * restarted); the old one stops working.
 */
export async function startTrip(deps: TripDeps, caller: Caller, data: unknown): Promise<StartResult> {
  const account = await requireVerified(deps, caller);
  const { carpoolId, runId, id, run, nowMs } = await runForDriver(deps, caller, data);
  await take(deps, caller.uid, "starts", 86_400_000, 30);
  if (!(await faceReference(deps, caller.uid))) throw new TripError("no-reference");
  // The same decision as prepareTrip, so skipping prepareTrip never skips
  // the selfie check (F38).
  const check = await decideCheck(deps, id, caller.uid, nowMs);
  if (check.status === "required") throw new TripError("selfie-required");
  if (check.status === "failed") throw new TripError("driving-paused");

  const token = deps.newToken();
  const expiresAtMs = nowMs + MAX_TRACKING_MS;
  // Reads outside the transaction (they do not change during a start).
  const place = await deps.store.carpool(carpoolId);
  if (!place) throw new TripError("not-found");
  const handover = await deps.store.handover([...run.riders, ...run.absent].map((r) => r.id));
  const stops = stopsFor(run.riders, run.absent, handover);
  const car = await deps.store.car(caller.uid);
  const stopPoints = await deps.store.stopPoints(carpoolId, [...new Set(run.riders.map((r) => r.parentUid))], place);

  return deps.store.mutateTrip(id, (current) => {
    if (current) {
      if (current.driverUid !== caller.uid) throw new TripError("not-driver");
      if (current.status !== "active") throw new TripError("too-late");
      return {
        trip: { ...current, tokenHash: hashToken(token), tokenExpiresAtMs: current.startedAtMs + MAX_TRACKING_MS, updatedAtMs: nowMs },
        events: [],
        result: { tripId: id, token, expiresAtMs: current.startedAtMs + MAX_TRACKING_MS, staleSeconds: settingsOf(deps).staleMs / 1000 },
      };
    }
    const trip: TripRecord = {
      id,
      carpoolId,
      runId,
      date: run.date,
      direction: run.direction,
      driverUid: caller.uid,
      driverFirstName: account.firstName,
      car,
      status: "active",
      startedAtMs: nowMs,
      trackingEndedAtMs: null,
      endedAtMs: null,
      endReason: null,
      viewerUids: viewersOf(caller.uid, stops),
      childIds: stops.map((s) => s.childId),
      stops,
      last: null,
      lastPointAtMs: null,
      staleAlertedAtMs: null,
      tokenHash: hashToken(token),
      tokenExpiresAtMs: expiresAtMs,
      lastEtaAtMs: null,
      accountCheckedAtMs: nowMs,
      messages: [],
      doneRequests: [],
      updatedAtMs: nowMs,
    };
    const parents = parentsOf(trip);
    return {
      trip,
      stops: stopPoints,
      events: parents.length > 0 ? [tripEvent("trip-started", trip, "start", parents, nowMs, { actorUid: caller.uid })] : [],
      result: { tripId: id, token, expiresAtMs, staleSeconds: settingsOf(deps).staleMs / 1000 },
    };
  });
}

// --------------------------------------------------------------------------
// During the run: stops (F16, F41), quick buttons (F35), emergency (F20)
// --------------------------------------------------------------------------

const EVENT_FOR: Record<DriverAction, NotificationType> = {
  arrived: "driver-arrived",
  pickedUp: "child-picked-up",
  dropped: "child-dropped",
  notComing: "child-not-coming",
};

export interface ActionResult {
  state: Stop["state"];
  status: TripRecord["status"];
  /** False when a retry of a request already applied. */
  applied: boolean;
}

/**
 * The driver taps Arrived, Picked up, Dropped or Not coming for one child. Each tap is
 * a trip event and a notification to that child's parent (Arrived: push
 * with sound and WhatsApp, F41; a second tap repeats it). The last
 * drop-off stops tracking. [requestId] makes an offline retry safe.
 */
export async function tripAction(deps: TripDeps, caller: Caller, data: unknown): Promise<ActionResult> {
  await requireVerified(deps, caller);
  const raw = record(data);
  const { carpoolId, runId } = parseRun(raw);
  const childId = idOf(raw.childId);
  if (!(DRIVER_ACTIONS as readonly unknown[]).includes(raw.action)) throw new TripError("invalid-request");
  const action = raw.action as DriverAction;
  const requestId = requestIdOf(raw.requestId);
  await take(deps, caller.uid, "tripActions", 3_600_000, 300);
  const nowMs = deps.now();
  return deps.store.mutateTrip<ActionResult>(tripId(carpoolId, runId), (trip) => {
    if (!trip) throw new TripError("not-found");
    if (trip.driverUid !== caller.uid) throw new TripError("not-driver");
    const stop = trip.stops.find((s) => s.childId === childId);
    if (!stop) throw new TripError("not-found");
    if (requestId && trip.doneRequests.includes(requestId)) {
      return { trip: null, events: [], result: { state: stop.state, status: trip.status, applied: false } };
    }
    if (trip.status !== "active") throw new TripError("trip-not-active");
    if (action === "arrived" && (stop.state === "arrived" || (trip.direction === "toHome" && stop.state === "onBoard"))) {
      // Per stop: a repeat within 30 s sends nothing; at most 5 alerts (WhatsApp is paid).
      if (stop.arrivedCount >= MAX_ARRIVED_PER_STOP) throw new TripError("rate-limited");
      if (stop.arrivedAtMs !== null && nowMs - stop.arrivedAtMs < ARRIVED_GAP_MS) {
        return { trip: null, events: [], result: { state: stop.state, status: trip.status, applied: false } };
      }
    }
    const next = applyAction(stop, action, trip.direction, nowMs);
    if (!next) throw new TripError("wrong-state");
    let updated: TripRecord = {
      ...trip,
      stops: trip.stops.map((s) => (s.childId === childId ? next : s)),
      doneRequests: withRequest(trip.doneRequests, requestId),
      updatedAtMs: nowMs,
    };
    const key = action === "arrived" ? `${childId}_${next.arrivedCount}` : childId;
    const events = [tripEvent(EVENT_FOR[action], trip, key, [stop.parentUid], nowMs, { actorUid: caller.uid, childId })];
    if (allDropped(updated.stops)) updated = stopTracking(updated, nowMs, "done");
    return { trip: updated, events, result: { state: next.state, status: updated.status, applied: true } };
  });
}

/**
 * Review item 4: the driver ends the run (asked to confirm in the app),
 * for example when the remaining children do not come. Refused while a
 * child is in the car. Children not picked up count as not coming, and
 * their parents are told. Tracking stops at once.
 */
export async function endTrip(deps: TripDeps, caller: Caller, data: unknown): Promise<{ status: TripRecord["status"] }> {
  await requireVerified(deps, caller);
  const { carpoolId, runId } = parseRun(data);
  const nowMs = deps.now();
  return deps.store.mutateTrip<{ status: TripRecord["status"] }>(tripId(carpoolId, runId), (trip) => {
    if (!trip) throw new TripError("not-found");
    if (trip.driverUid !== caller.uid) throw new TripError("not-driver");
    if (trip.status !== "active") return { trip: null, events: [], result: { status: trip.status } };
    if (trip.stops.some((s) => onBoard(s, trip.direction))) throw new TripError("children-on-board");
    const left = trip.stops.filter((s) => s.state === "waiting" || s.state === "arrived");
    const stops = trip.stops.map((s) => (left.includes(s) ? { ...s, state: "absent" as const } : s));
    const updated = stopTracking({ ...trip, stops }, nowMs, "ended");
    const events = left.map((s) => tripEvent("child-not-coming", trip, s.childId, [s.parentUid], nowMs, { actorUid: caller.uid, childId: s.childId }));
    return { trip: updated, events, result: { status: updated.status } };
  });
}

/**
 * Review item 5: tracking of [uid]'s live trips stops at once (sign-out,
 * suspension, ban, deleted account). The upload key stops working, the
 * last point goes, and the run's parents get "location stopped".
 */
export async function endDriverTrips(deps: TripDeps, uid: string, nowMs: number): Promise<number> {
  let ended = 0;
  for (const id of await deps.store.liveTripsOfDriver(uid)) {
    ended += await deps.store.mutateTrip<number>(id, (trip) => {
      if (!trip || trip.status !== "active" || trip.driverUid !== uid) return { trip: null, events: [], result: 0 };
      const parents = parentsOf(trip);
      return {
        trip: stopTracking(trip, nowMs, "revoked"),
        events: parents.length > 0 ? [tripEvent("location-stopped", trip, `revoked_${nowMs}`, parents, nowMs)] : [],
        result: 1,
      };
    });
  }
  return ended;
}

/** The driver signs out: the app calls this first (review item 5). */
export async function stopMyTrips(deps: TripDeps, caller: Caller): Promise<{ ended: number }> {
  if (!caller.uid) throw new TripError("not-verified");
  return { ended: await endDriverTrips(deps, caller.uid, deps.now()) };
}

/** F34: the receiving parent confirms the child arrived home. The driver is told. */
export async function confirmHandover(deps: TripDeps, caller: Caller, data: unknown): Promise<{ status: TripRecord["status"] }> {
  await requireVerified(deps, caller);
  const raw = record(data);
  const { carpoolId, runId } = parseRun(raw);
  const childId = idOf(raw.childId);
  const nowMs = deps.now();
  return deps.store.mutateTrip(tripId(carpoolId, runId), (trip) => {
    if (!trip) throw new TripError("not-found");
    const stop = trip.stops.find((s) => s.childId === childId);
    if (!stop) throw new TripError("not-found");
    if (stop.parentUid !== caller.uid) throw new TripError("not-parent");
    if (stop.state === "received") return { trip: null, events: [], result: { status: trip.status } };
    if (trip.direction !== "toHome" || stop.state !== "dropped") throw new TripError("wrong-state");
    const stops = trip.stops.map((s) => (s.childId === childId ? { ...s, state: "received" as const, receivedAtMs: nowMs } : s));
    let updated: TripRecord = { ...trip, stops, updatedAtMs: nowMs };
    if (updated.status === "handover" && pendingHandovers(updated).length === 0) updated = { ...updated, status: "ended", endedAtMs: nowMs };
    return {
      trip: updated,
      events: [tripEvent("child-received", trip, childId, [trip.driverUid], nowMs, { actorUid: caller.uid, childId })],
      result: { status: updated.status },
    };
  });
}

const QUICK_EVENT: Record<QuickKind, NotificationType> = {
  late: "driver-late",
  gate: "driver-at-gate",
  allIn: "all-children-in",
};

/** The chat text of a quick message: the driver's first name, Arabic and English (members of both languages read it). */
export const QUICK_CHAT_TEXT: Readonly<Record<QuickKind, { ar: string; en: string }>> = {
  late: { ar: "متأخر قليلًا", en: "Running late" },
  gate: { ar: "عند بوابة المدرسة", en: "At the school gate" },
  allIn: { ar: "كل الأطفال في السيارة", en: "All children are in the car" },
};

export function quickChatText(kind: QuickKind, driverFirstName: string): string {
  const t = QUICK_CHAT_TEXT[kind];
  return `${driverFirstName}: ${t.ar} · ${t.en}`;
}

/**
 * F35: one tap tells the parents on the run (no typing) and posts the
 * message into the carpool chat as a system message (Prompt 9). The same
 * message at most once every two minutes. Stored on the trip for the trip
 * screen. The chat message carries no location.
 */
export async function quickMessage(deps: TripDeps, caller: Caller, data: unknown): Promise<{ posted: boolean }> {
  await requireVerified(deps, caller);
  const raw = record(data);
  const { carpoolId, runId } = parseRun(raw);
  if (!(QUICK_KINDS as readonly unknown[]).includes(raw.kind)) throw new TripError("invalid-request");
  const kind = raw.kind as QuickKind;
  const requestId = requestIdOf(raw.requestId);
  const nowMs = deps.now();
  const result = await deps.store.mutateTrip<{ posted: boolean; trip: TripRecord | null }>(tripId(carpoolId, runId), (trip) => {
    if (!trip) throw new TripError("not-found");
    if (trip.driverUid !== caller.uid) throw new TripError("not-driver");
    if (trip.status !== "active") throw new TripError("trip-not-active");
    if (requestId && trip.doneRequests.includes(requestId)) return { trip: null, events: [], result: { posted: false, trip: null } };
    const recent = trip.messages.some((m) => m.kind === kind && nowMs - m.atMs < QUICK_GAP_MS);
    if (recent) return { trip: null, events: [], result: { posted: false, trip: null } };
    const parents = parentsOf(trip);
    const updated: TripRecord = {
      ...trip,
      messages: [...trip.messages, { kind, atMs: nowMs }].slice(-MAX_MESSAGES),
      doneRequests: withRequest(trip.doneRequests, requestId),
      updatedAtMs: nowMs,
    };
    return {
      trip: updated,
      events: parents.length > 0 ? [tripEvent(QUICK_EVENT[kind], trip, `${kind}_${nowMs}`, parents, nowMs, { actorUid: caller.uid })] : [],
      result: { posted: true, trip },
    };
  });
  const trip = result.trip;
  if (result.posted && trip && deps.chat) {
    try {
      // Fixed ID: a retried call never posts twice.
      await deps.chat.post(carpoolId, `quick-${trip.id}-${kind}-${nowMs}`.slice(0, 255), quickChatText(kind, trip.driverFirstName), {
        quick_kind: kind,
        run_id: runId,
      });
    } catch (error) {
      // The parents were told by push already; the chat line is a bonus.
      deps.log("quick message not posted to chat", { message: error instanceof Error ? error.message : "unknown" });
    }
  }
  return { posted: result.posted };
}

/**
 * F20: one tap alerts every member of the carpool (critical: alarm and
 * WhatsApp) and the driver's saved emergency contact by WhatsApp, with the
 * location (the phone's point, else the trip's last point). The point goes
 * to the emergency record (members, 24 hours) and the contact's message
 * only: never to the push text or the logs.
 */
export async function emergency(deps: TripDeps, caller: Caller, data: unknown): Promise<{ emergencyId: string; contactSent: boolean; members: number }> {
  const account = await requireVerified(deps, caller);
  const raw = record(data);
  const { carpoolId, runId } = parseRun(raw);
  await take(deps, caller.uid, "emergencies", 3_600_000, 5);
  const nowMs = deps.now();
  const id = tripId(carpoolId, runId);
  const trip = await deps.store.trip(id);
  if (!trip) throw new TripError("not-found");
  if (trip.driverUid !== caller.uid) throw new TripError("not-driver");
  // During the run, or up to 30 minutes after its end (non-blocking 7).
  if (trip.status === "ended" && nowMs - (trip.endedAtMs ?? 0) > 30 * 60_000) throw new TripError("trip-not-active");
  const point = pointOf(raw.point) ?? (trip.last ? { lat: trip.last.lat, lng: trip.last.lng } : null);
  const emergencyId = await deps.store.addEmergency(carpoolId, {
    tripId: id,
    runId,
    driverUid: caller.uid,
    driverFirstName: trip.driverFirstName,
    point,
    atMs: nowMs,
    expiresAtMs: nowMs + EMERGENCY_KEEP_MS,
  });
  const members = (await deps.store.memberUids(carpoolId)).filter((u) => u !== caller.uid);
  await deps.store.addEvents([
    newEvent(`emergency_${emergencyId}`, "emergency", members, nowMs, {
      carpoolId,
      runId,
      date: trip.date,
      direction: trip.direction,
      actorUid: caller.uid,
    }),
  ]);
  let contactSent = false;
  const contact = await deps.store.emergencyContact(caller.uid);
  if (contact) {
    const where = point ? mapsLink(point) : account.language === "ar" ? "غير معروف" : "unknown";
    try {
      // Template body: "{{1}} pressed the emergency button during a school run. Location: {{2}}".
      await deps.whatsapp.sendTemplate(contact.phone, EMERGENCY_TEMPLATE, account.language, [account.firstName, where], "emergency alert to the saved contact");
      contactSent = true;
    } catch (error) {
      deps.log("emergency contact message failed", { message: error instanceof Error ? error.message : "unknown" });
    }
  }
  deps.log("emergency alert", { members: members.length, contact: contact !== null, contactSent, withPoint: point !== null });
  return { emergencyId, contactSent, members: members.length };
}

// --------------------------------------------------------------------------
// Live points (F15) and arrival times
// --------------------------------------------------------------------------

/** How often an upload re-reads the driver's account. */
export const ACCOUNT_CHECK_MS = 60_000;

export interface UploadResult {
  /** HTTP status for the location plugin: 200 kept, 401 bad token, 410 the run is over. */
  status: 200 | 400 | 401 | 410;
  accepted: number;
}

/**
 * One upload from the phone's location plugin (HTTPS, Bearer token of
 * this trip). Only the trip's own token works, only while it tracks.
 * Writes the points (deleted within 24 hours), the trip's last point and,
 * at most once a minute, the arrival times (one Routes request for every
 * stop ahead).
 */
export async function uploadPoints(deps: TripDeps, id: unknown, token: unknown, body: unknown): Promise<UploadResult> {
  if (typeof id !== "string" || !/^[A-Za-z0-9_-]{1,200}$/.test(id) || typeof token !== "string" || token.length < 20 || token.length > 200) {
    return { status: 401, accepted: 0 };
  }
  const nowMs = deps.now();
  const s = settingsOf(deps);
  const parsed = parseUpload(body);
  const outcome = await deps.store.mutateTrip<{ status: UploadResult["status"]; points: TripPoint[]; trip: TripRecord | null; checkUid: string | null }>(id, (trip) => {
    if (!trip || !sameHash(trip.tokenHash, hashToken(token))) return { trip: null, events: [], result: { status: 401, points: [], trip: null, checkUid: null } };
    if (trip.status !== "active" || nowMs > trip.tokenExpiresAtMs) return { trip: null, events: [], result: { status: 410, points: [], trip: null, checkUid: null } };
    // Review item 5: the driver's account is read again at most once a minute.
    const checkDue = trip.accountCheckedAtMs === null || nowMs - trip.accountCheckedAtMs >= ACCOUNT_CHECK_MS;
    const checkUid = checkDue ? trip.driverUid : null;
    const points = acceptPoints(parsed, trip.lastPointAtMs, trip.startedAtMs, nowMs, s.minPointGapMs);
    if (points.length === 0) {
      return { trip: checkDue ? { ...trip, accountCheckedAtMs: nowMs } : null, events: [], result: { status: 200, points, trip: null, checkUid } };
    }
    const last = points[points.length - 1];
    const eta = etaDue(trip.lastEtaAtMs, nowMs, s.etaIntervalMs);
    const updated: TripRecord = {
      ...trip,
      last,
      lastPointAtMs: last.atMs,
      staleAlertedAtMs: null,
      lastEtaAtMs: eta ? nowMs : trip.lastEtaAtMs,
      accountCheckedAtMs: checkDue ? nowMs : trip.accountCheckedAtMs,
      updatedAtMs: nowMs,
    };
    return { trip: updated, events: [], result: { status: 200, points, trip: eta ? updated : null, checkUid } };
  });
  if (outcome.status !== 200) return { status: outcome.status, accepted: 0 };
  if (outcome.checkUid) {
    const account = await deps.store.account(outcome.checkUid);
    if (!account || account.status !== "verified") {
      // Suspended, banned or deleted: tracking stops and the key dies.
      await endDriverTrips(deps, outcome.checkUid, nowMs);
      return { status: 410, accepted: 0 };
    }
  }
  if (outcome.points.length > 0) await deps.store.addPoints(id, outcome.points, nowMs + 12 * 3_600_000);
  if (outcome.trip) await refreshEtas(deps, outcome.trip, nowMs);
  return { status: 200, accepted: outcome.points.length };
}

/** One Routes request for every stop ahead; failures only skip this minute. */
export async function refreshEtas(deps: TripDeps, trip: TripRecord, nowMs: number): Promise<number> {
  if (!trip.last) return 0;
  const stops = await deps.store.tripStops(trip.id);
  if (!stops) return 0;
  const ahead = routeAhead(trip, stops).slice(0, 25);
  if (ahead.length === 0) return 0;
  let legs: number[];
  try {
    legs = await deps.routes.legs({ lat: trip.last.lat, lng: trip.last.lng }, ahead.map((w) => w.point));
  } catch (error) {
    deps.log("arrival times failed", { message: error instanceof Error ? error.message : "unknown" });
    return 0;
  }
  const byParent = etasFrom(ahead, legs, nowMs);
  const records: EtaRecord[] = [...byParent.entries()].map(([parentUid, s]) => ({ parentUid, stops: s, updatedAtMs: nowMs }));
  await deps.store.putEtas(trip.id, records);
  return records.length;
}

// --------------------------------------------------------------------------
// Tick: location stopped (F15), handover not confirmed (F34), cleanup
// --------------------------------------------------------------------------

/** A live selfie never stays longer than this (normally deleted at once). */
export const SELFIE_KEEP_MS = 60 * 60_000;

export interface TickResult {
  stale: number;
  notConfirmed: number;
  ended: number;
  deleted: number;
}

/**
 * Every minute (Africa/Cairo, minInstances 0): "location stopped" to the
 * run's parents and driver when no point came for the stale time; "child
 * not confirmed" (critical, F34) to the receiving parent and the driver 10
 * minutes after an afternoon drop-off nobody confirmed; tracking stops
 * after 4 hours; handovers are watched 2 hours after tracking stopped;
 * live points and emergencies past their time are deleted (within 24
 * hours, spec section 7).
 */
export async function runTripTick(deps: TripDeps, limit = 200): Promise<TickResult> {
  const nowMs = deps.now();
  const s = settingsOf(deps);
  const out: TickResult = { stale: 0, notConfirmed: 0, ended: 0, deleted: 0 };
  for (const id of await deps.store.liveTripIds(limit)) {
    const r = await deps.store.mutateTrip(id, (trip) => {
      const none = { trip: null, events: [], result: { stale: 0, notConfirmed: 0, ended: 0 } };
      if (!trip || trip.status === "ended") return none;
      let updated = trip;
      const events: OutboxEvent[] = [];
      let stale = 0;
      let ended = 0;
      if (isStale(trip, nowMs, s.staleMs)) {
        events.push(tripEvent("location-stopped", trip, String(nowMs), trip.viewerUids, nowMs));
        updated = { ...updated, staleAlertedAtMs: nowMs, updatedAtMs: nowMs };
        stale = 1;
      }
      const overdue = overdueHandovers(updated, nowMs, s.handoverMs);
      for (const stop of overdue) {
        events.push(tripEvent("child-not-confirmed", trip, stop.childId, [stop.parentUid, trip.driverUid], nowMs, { childId: stop.childId }));
      }
      if (overdue.length > 0) {
        const ids = new Set(overdue.map((x) => x.childId));
        updated = { ...updated, stops: updated.stops.map((x) => (ids.has(x.childId) ? { ...x, notConfirmedAtMs: nowMs } : x)), updatedAtMs: nowMs };
      }
      if (updated.status === "active" && nowMs - updated.startedAtMs > MAX_TRACKING_MS) {
        updated = stopTracking(updated, nowMs, "timeout");
        ended = 1;
      } else if (updated.status === "handover") {
        const watchedOut = updated.trackingEndedAtMs !== null && nowMs - updated.trackingEndedAtMs > MAX_HANDOVER_WATCH_MS;
        const allAlerted = pendingHandovers(updated).every((x) => x.notConfirmedAtMs !== null);
        if (watchedOut && allAlerted) {
          updated = { ...updated, status: "ended", endedAtMs: nowMs, updatedAtMs: nowMs };
          ended = 1;
        }
      }
      if (updated === trip) return none;
      return { trip: updated, events, result: { stale, notConfirmed: overdue.length, ended } };
    });
    out.stale += r.stale;
    out.notConfirmed += r.notConfirmed;
    out.ended += r.ended;
  }
  out.deleted = await deps.store.deleteExpired(nowMs, 500);
  // Review item 3: live selfies left by a failed or abandoned check.
  for (const f of await deps.files.list("selfieChecks/")) {
    if (nowMs - f.createdMs > SELFIE_KEEP_MS) {
      await deps.files.delete(f.path);
      out.deleted += 1;
    }
  }
  return out;
}

// --------------------------------------------------------------------------
// Data entry: handover list (F29), emergency contact (F20), driver card (F33)
// --------------------------------------------------------------------------

/**
 * F29: the parent sets the adults allowed to receive one child (names,
 * relation, optional phone for their own reference). The driver sees the
 * names and relations on each live trip with that child at once.
 */
export async function saveHandoverAdults(deps: TripDeps, caller: Caller, data: unknown): Promise<{ adults: number }> {
  await requireVerified(deps, caller);
  const raw = record(data);
  const childId = idOf(raw.childId);
  if (!Array.isArray(raw.adults) || raw.adults.length > MAX_HANDOVER_ADULTS) throw new TripError("invalid-request");
  const adults: HandoverEntry[] = raw.adults.map((a) => {
    const x = record(a);
    const phone = x.phone === undefined || x.phone === null || x.phone === "" ? null : toEgyptE164(x.phone);
    if (x.phone !== undefined && x.phone !== null && x.phone !== "" && phone === null) throw new TripError("invalid-request");
    return { name: nameOf(x.name), relation: relationOf(x.relation), phone };
  });
  await take(deps, caller.uid, "handover", 86_400_000, 50);
  const child = await deps.store.child(childId);
  if (!child || child.ownerUid !== caller.uid) throw new TripError("not-parent");
  const nowMs = deps.now();
  await deps.store.putHandover(childId, caller.uid, adults, nowMs);
  const names: HandoverAdult[] = adults.map((a) => ({ name: a.name, relation: a.relation }));
  for (const id of await deps.store.liveTripsWithChild(childId)) {
    await deps.store.mutateTrip(id, (trip) => {
      if (!trip || trip.status === "ended") return { trip: null, events: [], result: null };
      return { trip: { ...trip, stops: trip.stops.map((s) => (s.childId === childId ? { ...s, handover: names } : s)), updatedAtMs: nowMs }, events: [], result: null };
    });
  }
  return { adults: adults.length };
}

/** The parent's own list, for the edit screen. */
export async function getHandoverAdults(deps: TripDeps, caller: Caller, data: unknown): Promise<{ adults: HandoverEntry[] }> {
  await requireVerified(deps, caller);
  const childId = idOf(record(data).childId);
  const child = await deps.store.child(childId);
  if (!child || child.ownerUid !== caller.uid) throw new TripError("not-parent");
  return { adults: await deps.store.handoverEntries(childId) };
}

/** F20: { name, phone, relation } saves; { clear: true } removes. */
export async function setEmergencyContact(deps: TripDeps, caller: Caller, data: unknown): Promise<{ saved: boolean }> {
  await requireVerified(deps, caller);
  const raw = record(data);
  await take(deps, caller.uid, "emergencyContact", 86_400_000, 20);
  if (raw.clear === true) {
    await deps.store.putEmergencyContact(caller.uid, null, deps.now());
    return { saved: false };
  }
  const phone = toEgyptE164(raw.phone);
  if (!phone) throw new TripError("invalid-request");
  const relation: Relation = relationOf(raw.relation);
  await deps.store.putEmergencyContact(caller.uid, { name: nameOf(raw.name), phone, relation }, deps.now());
  return { saved: true };
}

export interface DriverCard {
  runId: string;
  direction: RunRecord["direction"];
  time: string;
  driverFirstName: string;
  car: CarCard | null;
  /** A 15-minute link to the photo approved during verification, or null. */
  photoUrl: string | null;
}

/**
 * F33: today's driver card for each of today's runs with a confirmed
 * driver: first name, photo, car model, color and plate. Approved members
 * of that carpool only, and only for today (Cairo date).
 */
export async function todayDriverCards(deps: TripDeps, caller: Caller, data: unknown): Promise<{ date: string; cards: DriverCard[] }> {
  await requireVerified(deps, caller);
  const carpoolId = idOf(record(data).carpoolId);
  if (!(await deps.store.isApprovedMember(carpoolId, caller.uid))) throw new TripError("not-member");
  await take(deps, caller.uid, "driverCards", 3_600_000, 60);
  const nowMs = deps.now();
  const date = cairoDate(nowMs);
  const runs = (await deps.store.runsOn(carpoolId, date)).filter((r) => r.driverUid && (r.status === "confirmed" || r.status === "completed"));
  const cards: DriverCard[] = [];
  for (const run of runs.sort((a, b) => a.startMs - b.startMs)) {
    const uid = run.driverUid as string;
    const path = driverPhotoPath(uid);
    const photoUrl = (await deps.files.exists(path)) ? await deps.files.signedReadUrl(path, nowMs + 15 * 60_000) : null;
    cards.push({ runId: run.id, direction: run.direction, time: run.time, driverFirstName: run.driverFirstName, car: await deps.store.car(uid), photoUrl });
  }
  return { date, cards };
}
