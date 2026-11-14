import { inEgypt, isValidPoint, type LatLng } from "../maps/geo";

/**
 * Carpools (F5, F6, F25, F26, F31, F32, F36, F39): types, input parsing and
 * the pure rules (seats, driver consent, time windows, "looking for a
 * carpool" matching). No Firestore here; flow.ts uses a CarpoolStore.
 *
 * Records (firestore.rules decides who reads them; only functions write):
 * - carpools/{id}: the public summary. Any verified parent may get it by ID
 *   (search results, invite links); nobody lists the collection.
 * - memberships/{carpoolId}_{uid}: status requested, approved, declined or
 *   left, and the role. Read by its own parent; the rules look it up for
 *   members, consents and pickup points (Prompt 5 shaped this lookup).
 * - carpools/{id}/members/{uid}: approved members with their children's
 *   first names and grades. Read by approved members only.
 * - carpools/{id}/requests/{uid}: open join requests with the children's
 *   first names and grades. Read by the requester and the carpool admin.
 * - carpools/{id}/driverConsents/{parentUid}_{driverUid}: F26. Read by
 *   approved members.
 * - carpools/{id}/pickupPoints/{uid}: the EXACT pickup point a member
 *   chose to share. Approved members only (Prompt 5 rules).
 * - carpoolInvites/{code}, carpoolLimits/{uid}: functions only.
 * - carpoolWanted/{uid}: "Looking for a carpool" posts (F32). The owner
 *   reads their own; others see them only through listCarpoolWanted.
 */

export const DAYS = ["sat", "sun", "mon", "tue", "wed", "thu", "fri"] as const;
export type Day = (typeof DAYS)[number];

/** F36: the fixed list of rules a creator picks from (codes shared with the app). */
export const CARPOOL_RULES = [
  "no_smoking",
  "mothers_only",
  "seat_belts",
  "child_seats",
  "wait_5_min",
  "no_phone",
  "no_food",
  "girls_only",
] as const;
export type CarpoolRule = (typeof CARPOOL_RULES)[number];

export const CONTRIBUTION_PERIODS = ["trip", "week", "month"] as const;
export type ContributionPeriod = (typeof CONTRIBUTION_PERIODS)[number];

export type CarpoolKind = "school" | "activity";
export type MembershipStatus = "requested" | "approved" | "declined" | "left";
export type MemberRole = "admin" | "member";

/** Passenger seats of a car (same cap as submitVerification, Prompt 3). */
export const MAX_SEATS = 8;
export const MAX_CONTRIBUTION_EGP = 10_000;
export const NOTE_MAX = 120;
export const ACTIVITY_NAME_MAX = 60;
export const LABEL_MAX = 120;
/** Times are matched within this many minutes (search and F32 matching). */
export const TIME_WINDOW_MIN = 30;
/** Earliest and latest time a run may be set to. */
export const EARLIEST_MIN = 5 * 60;
export const LATEST_MIN = 22 * 60;
/** Carpools one parent may run as admin, and memberships in all. */
export const MAX_ADMIN_CARPOOLS = 5;
export const MAX_MEMBERSHIPS = 10;
/** F32: families (the poster included) that make a suggestion. */
export const SUGGEST_AT_FAMILIES = 3;
export const WANTED_DAYS = 60;
export const INVITE_DAYS = 14;
export const DEFAULT_ACTIVITY_RADIUS_KM = 5;

export type CarpoolErrorReason =
  | "invalid-request"
  | "no-account"
  | "suspended"
  | "not-verified"
  | "not-found"
  | "closed"
  | "not-your-school"
  | "not-your-child"
  | "wrong-school"
  | "invalid-school"
  | "invalid-area"
  | "no-children"
  | "no-car"
  | "car-expired"
  | "car-too-small"
  | "too-many-children"
  | "no-seats"
  | "already-member"
  | "already-requested"
  | "not-member"
  | "not-admin"
  | "not-requested"
  | "must-accept"
  | "too-many-carpools"
  | "self-consent"
  | "no-home"
  | "invite-invalid"
  | "admin-must-stay"
  | "rate-limited";

export class CarpoolError extends Error {
  constructor(
    readonly reason: CarpoolErrorReason,
    readonly retryAfterMs = 0,
  ) {
    super(reason);
    this.name = "CarpoolError";
  }
}

export const CARPOOL_ERROR_CODES: Record<CarpoolErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "no-account": "failed-precondition",
  suspended: "permission-denied",
  "not-verified": "permission-denied",
  "not-found": "not-found",
  closed: "failed-precondition",
  "not-your-school": "permission-denied",
  "not-your-child": "permission-denied",
  "wrong-school": "invalid-argument",
  "invalid-school": "invalid-argument",
  "invalid-area": "invalid-argument",
  "no-children": "invalid-argument",
  "no-car": "failed-precondition",
  "car-expired": "failed-precondition",
  "car-too-small": "failed-precondition",
  "too-many-children": "failed-precondition",
  "no-seats": "failed-precondition",
  "already-member": "already-exists",
  "already-requested": "already-exists",
  "not-member": "permission-denied",
  "not-admin": "permission-denied",
  "not-requested": "failed-precondition",
  "must-accept": "failed-precondition",
  "too-many-carpools": "resource-exhausted",
  "self-consent": "invalid-argument",
  "no-home": "failed-precondition",
  "invite-invalid": "not-found",
  "admin-must-stay": "failed-precondition",
  "rate-limited": "resource-exhausted",
};

// --------------------------------------------------------------------------
// Records
// --------------------------------------------------------------------------

export interface Contribution {
  /** Whole Egyptian pounds per child. */
  amount: number;
  period: ContributionPeriod;
  note: string;
}

export interface ActivityPlace {
  name: string;
  /** The place's address as picked (a club or a school of lessons, never a home). */
  label: string;
  /** Rounded to about 500 m: enough to search by distance. */
  point: LatLng;
  geohash: string;
}

export interface CarpoolRecord {
  id: string;
  kind: CarpoolKind;
  schoolId: string | null;
  schoolNameAr: string;
  schoolNameEn: string;
  areaId: string | null;
  areaNameAr: string;
  areaNameEn: string;
  activity: ActivityPlace | null;
  /** "HH:MM" arrival at school (morning) and departure (afternoon), or null. */
  morning: string | null;
  afternoon: string | null;
  days: Day[];
  /** Children the carpool carries per run (never more than a driver's passenger seats). */
  seats: number;
  childrenCount: number;
  memberCount: number;
  rules: CarpoolRule[];
  contribution: Contribution | null;
  creatorUid: string;
  creatorFirstName: string;
  status: "active" | "closed";
  createdAtMs: number;
  updatedAtMs: number;
}

export interface ChildRef {
  id: string;
  firstName: string;
  grade: string;
}

/** What other members need about a driver's car: passenger seats and validity. */
export interface CarInfo {
  seats: number;
  /** The earlier of the license and car license expiry, "YYYY-MM-DD". */
  validUntil: string;
}

export interface MembershipRecord {
  carpoolId: string;
  uid: string;
  status: MembershipStatus;
  role: MemberRole;
  firstName: string;
  children: ChildRef[];
  car: CarInfo | null;
  /** Days the parent can drive (the creator sets them at creation; Prompt 7 for others). */
  drivingDays: Day[];
  acceptedRules: boolean;
  acceptedContribution: boolean;
  requestedAtMs: number;
  decidedAtMs: number | null;
  decidedBy: string | null;
  updatedAtMs: number;
}

/** carpools/{id}/members/{uid}: what approved members see of each other. */
export interface MemberRecord {
  uid: string;
  role: MemberRole;
  firstName: string;
  children: ChildRef[];
  car: CarInfo | null;
  drivingDays: Day[];
  pickupShared: boolean;
  joinedAtMs: number;
}

/** carpools/{id}/requests/{uid}: what the admin sees before deciding. */
export interface RequestRecord {
  uid: string;
  firstName: string;
  children: ChildRef[];
  car: CarInfo | null;
  requestedAtMs: number;
}

export interface ConsentRecord {
  carpoolId: string;
  parentUid: string;
  driverUid: string;
  status: "accepted" | "withdrawn";
  acceptedAtMs: number | null;
  withdrawnAtMs: number | null;
  updatedAtMs: number;
}

export function consentId(parentUid: string, driverUid: string): string {
  return `${parentUid}_${driverUid}`;
}

export function membershipId(carpoolId: string, uid: string): string {
  return `${carpoolId}_${uid}`;
}

export interface InviteRecord {
  code: string;
  carpoolId: string;
  createdBy: string;
  createdAtMs: number;
  expiresAtMs: number;
}

export interface WantedRecord {
  uid: string;
  firstName: string;
  schoolId: string;
  schoolNameAr: string;
  schoolNameEn: string;
  areaId: string | null;
  areaNameAr: string;
  areaNameEn: string;
  morning: string | null;
  afternoon: string | null;
  days: Day[];
  childrenCount: number;
  createdAtMs: number;
  expiresAtMs: number;
}

// --------------------------------------------------------------------------
// Small parsers
// --------------------------------------------------------------------------

const DOC_ID = /^[A-Za-z0-9_-]{1,128}$/;
const TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;

export function record(data: unknown): Record<string, unknown> {
  return typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
}

export function docId(value: unknown): string {
  if (typeof value !== "string" || !DOC_ID.test(value)) throw new CarpoolError("invalid-request");
  return value;
}

export function optionalDocId(value: unknown): string | null {
  return value === undefined || value === null || value === "" ? null : docId(value);
}

/** Minutes after midnight of "HH:MM", or null when not a valid time. */
export function minutesOf(time: string | null | undefined): number | null {
  if (typeof time !== "string") return null;
  const m = TIME.exec(time);
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

/** A run time: "HH:MM" between 05:00 and 22:00 in steps of 5 minutes, or null. */
export function parseTime(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string") throw new CarpoolError("invalid-request");
  const min = minutesOf(value);
  if (min === null || min < EARLIEST_MIN || min > LATEST_MIN || min % 5 !== 0) throw new CarpoolError("invalid-request");
  return value;
}

export function parseDays(value: unknown, { allowEmpty = false } = {}): Day[] {
  if (!Array.isArray(value)) throw new CarpoolError("invalid-request");
  const set = new Set<string>();
  for (const d of value) {
    if (typeof d !== "string" || !(DAYS as readonly string[]).includes(d)) throw new CarpoolError("invalid-request");
    set.add(d);
  }
  if (!allowEmpty && set.size === 0) throw new CarpoolError("invalid-request");
  return DAYS.filter((d) => set.has(d));
}

export function parseRules(value: unknown): CarpoolRule[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new CarpoolError("invalid-request");
  const set = new Set<string>();
  for (const r of value) {
    if (typeof r !== "string" || !(CARPOOL_RULES as readonly string[]).includes(r)) throw new CarpoolError("invalid-request");
    set.add(r);
  }
  return CARPOOL_RULES.filter((r) => set.has(r));
}

function cleanText(value: unknown, max: number): string {
  return typeof value === "string" ? value.trim().replace(/\s+/g, " ").slice(0, max) : "";
}

/** F25: optional; whole pounds 1 to 10,000 per child, per trip, week or month. */
export function parseContribution(value: unknown): Contribution | null {
  if (value === undefined || value === null) return null;
  const raw = record(value);
  const amount = raw.amount;
  if (typeof amount !== "number" || !Number.isInteger(amount) || amount < 1 || amount > MAX_CONTRIBUTION_EGP) {
    throw new CarpoolError("invalid-request");
  }
  const period = raw.period;
  if (typeof period !== "string" || !(CONTRIBUTION_PERIODS as readonly string[]).includes(period)) {
    throw new CarpoolError("invalid-request");
  }
  return { amount, period: period as ContributionPeriod, note: cleanText(raw.note, NOTE_MAX) };
}

export function parseIds(value: unknown, max: number): string[] {
  if (!Array.isArray(value) || value.length > max) throw new CarpoolError("invalid-request");
  return [...new Set(value.map(docId))];
}

export interface ActivityInput {
  name: string;
  label: string;
  location: LatLng;
}

export function parseActivity(value: unknown): ActivityInput {
  const raw = record(value);
  const name = cleanText(raw.name, ACTIVITY_NAME_MAX);
  const label = cleanText(raw.label, LABEL_MAX);
  if (name.length < 2 || !isValidPoint(raw.location)) throw new CarpoolError("invalid-request");
  if (!inEgypt(raw.location)) throw new CarpoolError("invalid-request");
  return { name, label, location: raw.location };
}

// --------------------------------------------------------------------------
// Cairo dates
// --------------------------------------------------------------------------

/** "YYYY-MM-DD" in Cairo for [nowMs]. */
export function cairoDate(nowMs: number): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Cairo", year: "numeric", month: "2-digit", day: "2-digit" }).format(
    new Date(nowMs),
  );
}

// --------------------------------------------------------------------------
// Cars and seats (spec section 6, "Seats")
// --------------------------------------------------------------------------

export interface VehicleInfo {
  status: string;
  seats: number;
  licenseExpiry: string;
  carLicenseExpiry: string;
}

/**
 * The car a parent may drive with, or null when there is none approved.
 * Expired papers keep the car (so members see why) but [carProblem] says so.
 */
export function carInfo(vehicle: VehicleInfo | null): CarInfo | null {
  if (!vehicle || vehicle.status !== "approved" || !Number.isInteger(vehicle.seats) || vehicle.seats < 1) return null;
  const dates = [vehicle.licenseExpiry, vehicle.carLicenseExpiry].filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d)).sort();
  if (dates.length < 2) return null;
  return { seats: Math.min(vehicle.seats, MAX_SEATS), validUntil: dates[0] };
}

export function carProblem(car: CarInfo | null, today: string): "no-car" | "car-expired" | null {
  if (!car) return "no-car";
  return car.validUntil < today ? "car-expired" : null;
}

export function seatsLeft(c: Pick<CarpoolRecord, "seats" | "childrenCount">): number {
  return Math.max(0, c.seats - c.childrenCount);
}

// --------------------------------------------------------------------------
// Driver consent (F26) and driving arrangements
// --------------------------------------------------------------------------

/** Accepted (and not withdrawn) consents as "parent_driver" keys. */
export function acceptedConsents(consents: ConsentRecord[]): Set<string> {
  return new Set(consents.filter((c) => c.status === "accepted").map((c) => consentId(c.parentUid, c.driverUid)));
}

export interface DriverStatus {
  driverUid: string;
  /** True when the driver may carry every child of the carpool today. */
  canDrive: boolean;
  problem: "no-car" | "car-expired" | "car-too-small" | null;
  /** Parents with children in the carpool who have not accepted this driver. */
  waitingFor: string[];
}

/**
 * Can [driver] drive a run with every child of the carpool? Needs a valid
 * approved car with enough passenger seats, and the consent of every other
 * parent with children in the carpool (F26).
 */
export function driverStatus(driver: MemberRecord, members: MemberRecord[], consents: ConsentRecord[], today: string): DriverStatus {
  const accepted = acceptedConsents(consents);
  const waitingFor = members
    .filter((m) => m.uid !== driver.uid && m.children.length > 0 && !accepted.has(consentId(m.uid, driver.uid)))
    .map((m) => m.uid)
    .sort();
  const children = members.reduce((n, m) => n + m.children.length, 0);
  let problem: DriverStatus["problem"] = carProblem(driver.car, today);
  if (!problem && driver.car && children > driver.car.seats) problem = "car-too-small";
  return { driverUid: driver.uid, canDrive: problem === null && waitingFor.length === 0, problem, waitingFor };
}

export type ArrangementProblem =
  | { reason: "not-member" }
  | { reason: "no-car" }
  | { reason: "car-expired" }
  | { reason: "no-children" }
  | { reason: "unknown-child"; childId: string }
  | { reason: "too-many-children"; children: number; seats: number }
  | { reason: "no-consent"; parents: string[] };

/**
 * Checks one run: [driverUid] carrying [childIds]. Refuses a run with more
 * children than the car's passenger seats, and any child whose parent has
 * not accepted the driver (or withdrew). The driver's own children need no
 * consent. Prompt 7 calls this before it gives anyone a driving day.
 */
export function checkArrangement(input: {
  driverUid: string;
  childIds: string[];
  members: MemberRecord[];
  consents: ConsentRecord[];
  today: string;
}): ArrangementProblem | null {
  const driver = input.members.find((m) => m.uid === input.driverUid);
  if (!driver) return { reason: "not-member" };
  const car = carProblem(driver.car, input.today);
  if (car) return { reason: car };
  const ids = [...new Set(input.childIds)];
  if (ids.length === 0) return { reason: "no-children" };
  const owner = new Map<string, string>();
  for (const m of input.members) for (const c of m.children) owner.set(c.id, m.uid);
  for (const id of ids) if (!owner.has(id)) return { reason: "unknown-child", childId: id };
  const seats = driver.car?.seats ?? 0;
  if (ids.length > seats) return { reason: "too-many-children", children: ids.length, seats };
  const accepted = acceptedConsents(input.consents);
  const parents = [...new Set(ids.map((id) => owner.get(id) as string))]
    .filter((p) => p !== driver.uid && !accepted.has(consentId(p, driver.uid)))
    .sort();
  return parents.length > 0 ? { reason: "no-consent", parents } : null;
}

// --------------------------------------------------------------------------
// Times and matching
// --------------------------------------------------------------------------

export function withinWindow(a: string | null, b: string | null, windowMin = TIME_WINDOW_MIN): boolean {
  const x = minutesOf(a);
  const y = minutesOf(b);
  return x !== null && y !== null && Math.abs(x - y) <= windowMin;
}

/** Search filter: each wanted time, when given, must be within the window of the carpool's. */
export function timesMatch(carpool: { morning: string | null; afternoon: string | null }, wanted: { morning: string | null; afternoon: string | null }): boolean {
  if (wanted.morning && !withinWindow(carpool.morning, wanted.morning)) return false;
  if (wanted.afternoon && !withinWindow(carpool.afternoon, wanted.afternoon)) return false;
  return true;
}

/**
 * F32: does [other]'s post match [mine]? Same school, the same area when
 * both chose one, at least one shared direction with times within 30
 * minutes (and no direction where both set times that are far apart), and
 * at least one shared day.
 */
export function wantedMatches(mine: WantedRecord, other: WantedRecord): boolean {
  if (mine.uid === other.uid || mine.schoolId !== other.schoolId) return false;
  if (mine.areaId && other.areaId && mine.areaId !== other.areaId) return false;
  let shared = 0;
  for (const dir of ["morning", "afternoon"] as const) {
    const a = mine[dir];
    const b = other[dir];
    if (a && b) {
      if (!withinWindow(a, b)) return false;
      shared++;
    }
  }
  if (shared === 0) return false;
  return mine.days.some((d) => other.days.includes(d));
}

export interface WantedSuggestion {
  /** Families that match, the poster included. */
  families: number;
  areaId: string | null;
  morning: string | null;
  afternoon: string | null;
  /** Days the poster and at least one other family share. */
  days: Day[];
}

/** F32: suggest starting a group when at least three families (me included) match. */
export function suggestion(mine: WantedRecord | null, others: WantedRecord[]): WantedSuggestion | null {
  if (!mine) return null;
  const matches = others.filter((o) => wantedMatches(mine, o));
  if (matches.length + 1 < SUGGEST_AT_FAMILIES) return null;
  const days = DAYS.filter((d) => mine.days.includes(d) && matches.some((m) => m.days.includes(d)));
  return { families: matches.length + 1, areaId: mine.areaId, morning: mine.morning, afternoon: mine.afternoon, days };
}
