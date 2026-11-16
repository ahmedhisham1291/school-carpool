import { distanceKm, encodeGeohash, geohashCoverPrefixes, RADIUS_CHOICES_KM, roundToGrid, STORED_GEOHASH_PRECISION, type LatLng } from "../maps/geo";
import {
  cairoDate,
  CarpoolError,
  carInfo,
  carProblem,
  consentId,
  DEFAULT_ACTIVITY_RADIUS_KM,
  docId,
  INVITE_DAYS,
  MAX_ADMIN_CARPOOLS,
  MAX_MEMBERSHIPS,
  MAX_SEATS,
  optionalDocId,
  parseActivity,
  parseContribution,
  parseDays,
  parseIds,
  parseRules,
  parseTime,
  record,
  seatsLeft,
  suggestion,
  timesMatch,
  VOLUNTEER_TERMS_VERSION,
  WANTED_DAYS,
  type CarpoolKind,
  type CarpoolRecord,
  type ChildRef,
  type ConsentRecord,
  type Day,
  type InviteRecord,
  type MemberRecord,
  type MembershipRecord,
  type MembershipStatus,
  type RequestRecord,
  type VehicleInfo,
  type WantedRecord,
  type WantedSuggestion,
} from "./model";
import { FeatureOffError } from "../features/model";
import { DEFAULT_DEADLINES, type BalanceRecord, type DeadlineSettings, type ExceptionRecord, type RunRecord, type ScheduleEvent, type SwapRecord } from "../schedule/model";
import { event, releaseAfterLeave, releaseAfterWithdraw } from "../schedule/release";

/**
 * Carpool flows (F5, F6, F25, F26, F31, F32, F36, F39) over a [CarpoolStore].
 * Every membership, ownership and status change happens here, inside one
 * store transaction; the app never writes any of it (firestore.rules).
 * Logs never get names, children or coordinates (callables.ts logs only
 * error messages).
 */

// --------------------------------------------------------------------------
// Store
// --------------------------------------------------------------------------

export interface AccountInfo {
  status: string;
  firstName: string;
}

export interface ChildInfo extends ChildRef {
  schoolId: string;
}

export interface SchoolInfo {
  id: string;
  nameAr: string;
  nameEn: string;
  status: string;
}

export interface AreaInfo {
  id: string;
  schoolId: string;
  nameAr: string;
  nameEn: string;
}

export interface PickupPoint {
  location: LatLng;
  label: string;
}

/** Reads and buffered writes of one transaction (all reads happen first in Firestore). */
export interface CarpoolTx {
  carpool(id: string): Promise<CarpoolRecord | null>;
  membership(carpoolId: string, uid: string): Promise<MembershipRecord | null>;
  /** Approved members (carpools/{id}/members). */
  members(carpoolId: string): Promise<MemberRecord[]>;
  consents(carpoolId: string): Promise<ConsentRecord[]>;
  /** Open join requests (carpools/{id}/requests). */
  requests(carpoolId: string): Promise<RequestRecord[]>;

  putCarpool(c: CarpoolRecord): void;
  putMembership(m: MembershipRecord): void;
  putMember(carpoolId: string, m: MemberRecord): void;
  deleteMember(carpoolId: string, uid: string): void;
  putRequest(carpoolId: string, r: RequestRecord): void;
  deleteRequest(carpoolId: string, uid: string): void;
  putConsent(c: ConsentRecord): void;
  deleteConsent(carpoolId: string, id: string): void;
  /** null deletes the member's pickup point. */
  putPickupPoint(carpoolId: string, uid: string, point: PickupPoint | null): void;

  // Schedule (Prompt 7). A driver's account and car, read in the
  // transaction (members hold only a copy taken when they joined).
  driverAccount(uid: string): Promise<AccountInfo | null>;
  driverVehicle(uid: string): Promise<VehicleInfo | null>;
  // Runs between two Cairo dates, inclusive.
  runs(carpoolId: string, fromDate: string, toDate: string): Promise<RunRecord[]>;
  run(carpoolId: string, runId: string): Promise<RunRecord | null>;
  exceptions(carpoolId: string): Promise<ExceptionRecord[]>;
  swap(carpoolId: string, swapId: string): Promise<SwapRecord | null>;
  balance(carpoolId: string, termId: string): Promise<BalanceRecord | null>;
  putRun(run: RunRecord): void;
  putSwap(swap: SwapRecord): void;
  putException(e: ExceptionRecord): void;
  deleteException(carpoolId: string, id: string): void;
  putBalance(b: BalanceRecord): void;
  addEvent(e: ScheduleEvent): void;
}

/** A run found by the schedule tick. */
export interface RunRef {
  carpoolId: string;
  runId: string;
}

export type CarpoolLimitKind =
  | "creates"
  | "searches"
  | "joinRequests"
  | "invites"
  | "inviteOpens"
  | "wantedSaves"
  | "wantedLists"
  | "plans"
  | "scheduleChanges";

export interface CarpoolStore {
  transact<T>(fn: (tx: CarpoolTx) => Promise<T>): Promise<T>;
  newCarpoolId(): string;
  account(uid: string): Promise<AccountInfo | null>;
  /** The parent's approved children. */
  approvedChildren(uid: string): Promise<ChildInfo[]>;
  vehicle(uid: string): Promise<VehicleInfo | null>;
  school(id: string): Promise<SchoolInfo | null>;
  area(id: string): Promise<AreaInfo | null>;
  drivingSchoolIds(uid: string): Promise<string[]>;
  /** The parent's EXACT home (homes/{uid}), or null. */
  home(uid: string): Promise<PickupPoint | null>;
  /** Active school carpools of [schoolId]. */
  schoolCarpools(schoolId: string, limit: number): Promise<CarpoolRecord[]>;
  /** Active activity carpools whose place geohash starts with [prefix]. */
  activityCarpools(prefix: string, limit: number): Promise<CarpoolRecord[]>;
  carpoolsById(ids: string[]): Promise<CarpoolRecord[]>;
  /** Every membership of the parent (any status). */
  membershipsOf(uid: string): Promise<MembershipRecord[]>;
  takeLimit(uid: string, kind: CarpoolLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;
  invite(code: string): Promise<InviteRecord | null>;
  /** false when the code is taken. */
  createInvite(invite: InviteRecord): Promise<boolean>;
  wanted(uid: string): Promise<WantedRecord | null>;
  putWanted(uid: string, w: WantedRecord | null): Promise<void>;
  wantedForSchool(schoolId: string, limit: number): Promise<WantedRecord[]>;
  /** A new random document ID (swaps, exceptions). */
  newId(): string;
  /** Planned or open runs whose confirm-by time has passed (any carpool). */
  dueRuns(nowMs: number, limit: number): Promise<RunRef[]>;
  /** Confirmed runs whose start time has passed (any carpool). */
  finishedRuns(nowMs: number, limit: number): Promise<RunRef[]>;
}

export interface CarpoolLimits {
  createsPerDay: number;
  searchesPerHour: number;
  joinRequestsPerDay: number;
  invitesPerDay: number;
  inviteOpensPerHour: number;
  wantedSavesPerDay: number;
  wantedListsPerHour: number;
  /** Prompt 7: weeks planned per parent a day, and other schedule changes. */
  plansPerDay: number;
  scheduleChangesPerDay: number;
}

export const DEFAULT_CARPOOL_LIMITS: CarpoolLimits = {
  createsPerDay: 3,
  searchesPerHour: 30,
  joinRequestsPerDay: 10,
  invitesPerDay: 20,
  inviteOpensPerHour: 20,
  wantedSavesPerDay: 5,
  wantedListsPerHour: 30,
  plansPerDay: 20,
  scheduleChangesPerDay: 100,
};

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

export interface CarpoolDeps {
  store: CarpoolStore;
  now: () => number;
  limits: CarpoolLimits;
  /** A new random invite code. */
  newCode: () => string;
  /** Start of invite links, for example https://links.example (no slash at the end). */
  linkBase: string;
  /** Prompt 7: confirm-by settings (F28); defaults to DEFAULT_DEADLINES. */
  deadlines?: DeadlineSettings;
  /**
   * The "contributions" feature switch (F25; features/model.ts). Off by
   * default (owner, 16 Nov 2026: no money in the app; rides are free
   * volunteer turns): a new contribution is refused with "feature-off",
   * joining never asks to accept one and searches leave it out. The
   * callables always pass it; unit tests of the feature itself may leave
   * it out (= on).
   */
  contributionsOn?: () => Promise<boolean>;
}

async function contributionsAllowed(deps: CarpoolDeps): Promise<boolean> {
  return deps.contributionsOn ? deps.contributionsOn() : true;
}

export interface Caller {
  uid: string;
  verifiedClaim: boolean;
}

export const SEARCH_MAX_RESULTS = 30;
const SEARCH_QUERY_LIMIT = 100;

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

export async function requireVerified(deps: CarpoolDeps, caller: Caller): Promise<AccountInfo> {
  if (!caller.verifiedClaim) throw new CarpoolError("not-verified");
  const account = await deps.store.account(caller.uid);
  if (!account) throw new CarpoolError("no-account");
  if (account.status === "suspended") throw new CarpoolError("suspended");
  if (account.status !== "verified") throw new CarpoolError("not-verified");
  return account;
}

export async function take(deps: CarpoolDeps, uid: string, kind: CarpoolLimitKind, windowMs: number, max: number): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), { windowMs, max });
  if (!r.allowed) throw new CarpoolError("rate-limited", r.retryAfterMs);
}

/** The caller's own approved children with these IDs (all of them, or an error). */
async function ownChildren(deps: CarpoolDeps, uid: string, ids: string[]): Promise<ChildInfo[]> {
  if (ids.length === 0) throw new CarpoolError("no-children");
  const mine = new Map((await deps.store.approvedChildren(uid)).map((c) => [c.id, c]));
  return ids.map((id) => {
    const c = mine.get(id);
    if (!c) throw new CarpoolError("not-your-child");
    return c;
  });
}

/** Children already in the carpool (members) or asked for (open requests), not counting [exceptUid]'s. */
function childIdsIn(members: MemberRecord[], requests: RequestRecord[], exceptUid: string): Set<string> {
  const ids = new Set<string>();
  for (const m of members) if (m.uid !== exceptUid) for (const c of m.children) ids.add(c.id);
  for (const r of requests) if (r.uid !== exceptUid) for (const c of r.children) ids.add(c.id);
  return ids;
}

function childRefs(children: ChildInfo[]): ChildRef[] {
  return children.map((c) => ({ id: c.id, firstName: c.firstName, grade: c.grade }));
}

/** Children's schools plus driving schools (Prompt 5): the schools whose carpools a parent may see. */
async function mySchoolIds(deps: CarpoolDeps, uid: string): Promise<Set<string>> {
  const [children, driving] = await Promise.all([deps.store.approvedChildren(uid), deps.store.drivingSchoolIds(uid)]);
  return new Set([...children.map((c) => c.schoolId).filter((s) => s.length > 0), ...driving]);
}

async function activeSchool(deps: CarpoolDeps, id: string) {
  const school = await deps.store.school(id);
  if (!school || school.status !== "active") throw new CarpoolError("invalid-school");
  return school;
}

async function areaOf(deps: CarpoolDeps, schoolId: string, areaId: string | null) {
  if (!areaId) return null;
  const area = await deps.store.area(areaId);
  if (!area || area.schoolId !== schoolId) throw new CarpoolError("invalid-area");
  return area;
}

function activeMembership(m: MembershipRecord | null): boolean {
  return m !== null && (m.status === "approved" || m.status === "requested");
}

export async function requireActiveCarpool(tx: CarpoolTx, carpoolId: string): Promise<CarpoolRecord> {
  const c = await tx.carpool(carpoolId);
  if (!c) throw new CarpoolError("not-found");
  if (c.status !== "active") throw new CarpoolError("closed");
  return c;
}

export async function requireApproved(tx: CarpoolTx, carpoolId: string, uid: string): Promise<MembershipRecord> {
  const m = await tx.membership(carpoolId, uid);
  if (!m || m.status !== "approved") throw new CarpoolError("not-member");
  return m;
}

function memberFrom(m: MembershipRecord, nowMs: number, pickupShared = false): MemberRecord {
  return {
    uid: m.uid,
    role: m.role,
    firstName: m.firstName,
    children: m.children,
    car: m.car,
    drivingDays: m.drivingDays,
    pickupShared,
    joinedAtMs: nowMs,
  };
}

// --------------------------------------------------------------------------
// Create (F5, F25, F36, F39)
// --------------------------------------------------------------------------

export interface CreateInput {
  kind: CarpoolKind;
  schoolId: string | null;
  areaId: string | null;
  activity: ReturnType<typeof parseActivity> | null;
  morning: string | null;
  afternoon: string | null;
  days: Day[];
  driveDays: Day[];
  seats: number;
  childIds: string[];
  rules: ReturnType<typeof parseRules>;
  contribution: ReturnType<typeof parseContribution>;
  /** The volunteer acknowledgement (VOLUNTEER_TERMS_VERSION) was ticked. */
  acceptVolunteer: boolean;
}

export function parseCreate(data: unknown): CreateInput {
  const raw = record(data);
  const kind = raw.kind;
  if (kind !== "school" && kind !== "activity") throw new CarpoolError("invalid-request");
  const morning = parseTime(raw.morning);
  const afternoon = parseTime(raw.afternoon);
  if (!morning && !afternoon) throw new CarpoolError("invalid-request");
  const days = parseDays(raw.days);
  const driveDays = parseDays(raw.driveDays ?? [], { allowEmpty: true });
  if (driveDays.some((d) => !days.includes(d))) throw new CarpoolError("invalid-request");
  const seats = raw.seats;
  if (typeof seats !== "number" || !Number.isInteger(seats) || seats < 1 || seats > MAX_SEATS) throw new CarpoolError("invalid-request");
  return {
    kind,
    schoolId: kind === "school" ? docId(raw.schoolId) : null,
    areaId: kind === "school" ? optionalDocId(raw.areaId) : null,
    activity: kind === "activity" ? parseActivity(raw.activity) : null,
    morning,
    afternoon,
    days,
    driveDays,
    seats,
    childIds: parseIds(raw.childIds, MAX_SEATS),
    rules: parseRules(raw.rules),
    contribution: parseContribution(raw.contribution),
    acceptVolunteer: raw.acceptVolunteer === true,
  };
}

/**
 * Creates a carpool with the caller as its admin and first approved member.
 * The creator drives, so their car must be approved and valid, and the
 * seats offered can never be more than the car's passenger seats; the
 * creator's own children take seats too.
 */
export async function createCarpool(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ carpoolId: string }> {
  const input = parseCreate(data);
  if (input.contribution && !(await contributionsAllowed(deps))) throw new FeatureOffError("contributions");
  const account = await requireVerified(deps, caller);
  if (!input.acceptVolunteer) throw new CarpoolError("must-accept");
  const children = await ownChildren(deps, caller.uid, input.childIds);

  let schoolNameAr = "";
  let schoolNameEn = "";
  let areaNameAr = "";
  let areaNameEn = "";
  if (input.kind === "school") {
    const school = await activeSchool(deps, input.schoolId as string);
    if (children.some((c) => c.schoolId !== school.id)) throw new CarpoolError("wrong-school");
    const area = await areaOf(deps, school.id, input.areaId);
    schoolNameAr = school.nameAr;
    schoolNameEn = school.nameEn;
    areaNameAr = area?.nameAr ?? "";
    areaNameEn = area?.nameEn ?? "";
  }

  const car = carInfo(await deps.store.vehicle(caller.uid));
  const today = cairoDate(deps.now());
  const problem = carProblem(car, today);
  if (problem) throw new CarpoolError(problem);
  if (input.seats > (car as { seats: number }).seats) throw new CarpoolError("car-too-small");
  if (children.length > input.seats) throw new CarpoolError("too-many-children");

  const mine = await deps.store.membershipsOf(caller.uid);
  const active = mine.filter((m) => activeMembership(m));
  if (active.length >= MAX_MEMBERSHIPS) throw new CarpoolError("too-many-carpools");
  if (active.filter((m) => m.status === "approved" && m.role === "admin").length >= MAX_ADMIN_CARPOOLS) {
    throw new CarpoolError("too-many-carpools");
  }
  await take(deps, caller.uid, "creates", DAY, deps.limits.createsPerDay);

  const nowMs = deps.now();
  const id = deps.store.newCarpoolId();
  let activity = null;
  if (input.activity) {
    const point = roundToGrid(input.activity.location);
    activity = { name: input.activity.name, label: input.activity.label, point, geohash: encodeGeohash(point, STORED_GEOHASH_PRECISION) };
  }
  const carpool: CarpoolRecord = {
    id,
    kind: input.kind,
    schoolId: input.schoolId,
    schoolNameAr,
    schoolNameEn,
    areaId: input.areaId,
    areaNameAr,
    areaNameEn,
    activity,
    morning: input.morning,
    afternoon: input.afternoon,
    days: input.days,
    seats: input.seats,
    childrenCount: children.length,
    memberCount: 1,
    rules: input.rules,
    contribution: input.contribution,
    creatorUid: caller.uid,
    creatorFirstName: account.firstName,
    status: "active",
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  };
  const membership: MembershipRecord = {
    carpoolId: id,
    uid: caller.uid,
    status: "approved",
    role: "admin",
    firstName: account.firstName,
    children: childRefs(children),
    car,
    drivingDays: input.driveDays,
    acceptedRules: true,
    acceptedContribution: true,
    volunteerTerms: VOLUNTEER_TERMS_VERSION,
    requestedAtMs: nowMs,
    decidedAtMs: nowMs,
    decidedBy: caller.uid,
    updatedAtMs: nowMs,
  };
  await deps.store.transact(async (tx) => {
    tx.putCarpool(carpool);
    tx.putMembership(membership);
    tx.putMember(id, memberFrom(membership, nowMs));
  });
  return { carpoolId: id };
}

// --------------------------------------------------------------------------
// Search (F5, F6, F36, F39)
// --------------------------------------------------------------------------

export interface CarpoolSummary {
  id: string;
  kind: CarpoolKind;
  schoolId: string | null;
  schoolNameAr: string;
  schoolNameEn: string;
  areaId: string | null;
  areaNameAr: string;
  areaNameEn: string;
  activityName: string;
  activityLabel: string;
  morning: string | null;
  afternoon: string | null;
  days: Day[];
  seats: number;
  seatsLeft: number;
  memberCount: number;
  rules: string[];
  contribution: CarpoolRecord["contribution"];
  creatorFirstName: string;
  /** The caller's membership status in it, or null. */
  myStatus: MembershipStatus | null;
  /** Activity carpools: rounded distance from the caller's area, in km. */
  distanceKm: number | null;
}

export function summaryOf(c: CarpoolRecord, myStatus: MembershipStatus | null, km: number | null): CarpoolSummary {
  return {
    id: c.id,
    kind: c.kind,
    schoolId: c.schoolId,
    schoolNameAr: c.schoolNameAr,
    schoolNameEn: c.schoolNameEn,
    areaId: c.areaId,
    areaNameAr: c.areaNameAr,
    areaNameEn: c.areaNameEn,
    activityName: c.activity?.name ?? "",
    activityLabel: c.activity?.label ?? "",
    morning: c.morning,
    afternoon: c.afternoon,
    days: c.days,
    seats: c.seats,
    seatsLeft: seatsLeft(c),
    memberCount: c.memberCount,
    rules: c.rules,
    contribution: c.contribution,
    creatorFirstName: c.creatorFirstName,
    myStatus,
    distanceKm: km === null ? null : Math.max(1, Math.round(km)),
  };
}

export interface SearchInput {
  kind: CarpoolKind;
  schoolId: string | null;
  areaId: string | null;
  morning: string | null;
  afternoon: string | null;
  radiusKm: number;
  parentUid: string | null;
}

export function parseSearch(data: unknown): SearchInput {
  const raw = record(data);
  const kind = raw.kind ?? "school";
  if (kind !== "school" && kind !== "activity") throw new CarpoolError("invalid-request");
  const radiusKm = raw.radiusKm ?? DEFAULT_ACTIVITY_RADIUS_KM;
  if (!(RADIUS_CHOICES_KM as readonly unknown[]).includes(radiusKm)) throw new CarpoolError("invalid-request");
  return {
    kind,
    schoolId: kind === "school" ? docId(raw.schoolId) : null,
    areaId: kind === "school" ? optionalDocId(raw.areaId) : null,
    morning: parseTime(raw.morning),
    afternoon: parseTime(raw.afternoon),
    radiusKm: radiusKm as number,
    parentUid: optionalDocId(raw.parentUid),
  };
}

/**
 * Carpools with free seats a verified parent can ask to join: school
 * carpools of one of the parent's schools (children's or driving schools),
 * optionally one area and times within 30 minutes; or activity carpools
 * whose place is within the radius of the parent's (rounded) home. With
 * [parentUid] (the nearby map's Join button) only that parent's carpools.
 * Searches are limited per hour.
 */
export async function searchCarpools(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ carpools: CarpoolSummary[] }> {
  const input = parseSearch(data);
  await requireVerified(deps, caller);
  let candidates: Array<{ c: CarpoolRecord; km: number | null }> = [];
  if (input.kind === "school") {
    const schoolId = input.schoolId as string;
    if (!(await mySchoolIds(deps, caller.uid)).has(schoolId)) throw new CarpoolError("not-your-school");
    await take(deps, caller.uid, "searches", HOUR, deps.limits.searchesPerHour);
    candidates = (await deps.store.schoolCarpools(schoolId, SEARCH_QUERY_LIMIT))
      .filter((c) => c.schoolId === schoolId && (!input.areaId || c.areaId === input.areaId))
      .map((c) => ({ c, km: null }));
  } else {
    const home = await deps.store.home(caller.uid);
    if (!home) throw new CarpoolError("no-home");
    await take(deps, caller.uid, "searches", HOUR, deps.limits.searchesPerHour);
    const center = roundToGrid(home.location);
    const seen = new Set<string>();
    for (const prefix of geohashCoverPrefixes(center, input.radiusKm)) {
      for (const c of await deps.store.activityCarpools(prefix, SEARCH_QUERY_LIMIT)) {
        if (seen.has(c.id) || !c.activity) continue;
        seen.add(c.id);
        const km = distanceKm(center, c.activity.point);
        if (km <= input.radiusKm) candidates.push({ c, km });
      }
    }
  }

  const memberships = await deps.store.membershipsOf(caller.uid);
  const myStatus = new Map(memberships.map((m) => [m.carpoolId, m.status]));
  let allowed: Set<string> | null = null;
  if (input.parentUid) {
    allowed = new Set(
      (await deps.store.membershipsOf(input.parentUid)).filter((m) => m.status === "approved").map((m) => m.carpoolId),
    );
  }
  const results = candidates
    .filter(({ c }) => c.status === "active" && timesMatch(c, input))
    .filter(({ c }) => (allowed ? allowed.has(c.id) : true))
    // Full carpools are hidden unless the caller is in them.
    .filter(({ c }) => seatsLeft(c) > 0 || myStatus.has(c.id))
    .sort((a, b) => (a.km ?? 0) - (b.km ?? 0) || b.c.createdAtMs - a.c.createdAtMs)
    .slice(0, SEARCH_MAX_RESULTS);
  const showContribution = await contributionsAllowed(deps);
  return {
    carpools: results.map(({ c, km }) => {
      const summary = summaryOf(c, myStatus.get(c.id) ?? null, km);
      return showContribution ? summary : { ...summary, contribution: null };
    }),
  };
}

// --------------------------------------------------------------------------
// Join requests (F6, F25, F36)
// --------------------------------------------------------------------------

export function parseJoin(data: unknown): { carpoolId: string; childIds: string[]; acceptRules: boolean; acceptContribution: boolean; acceptVolunteer: boolean } {
  const raw = record(data);
  return {
    carpoolId: docId(raw.carpoolId),
    childIds: parseIds(raw.childIds, MAX_SEATS),
    acceptRules: raw.acceptRules === true,
    acceptContribution: raw.acceptContribution === true,
    acceptVolunteer: raw.acceptVolunteer === true,
  };
}

/**
 * Asks to join with the children who would ride. The rules must be
 * accepted, and the contribution too when there is one (F25, F36). The
 * children must fit the free seats. The admin approves or declines.
 */
export async function requestToJoin(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ status: MembershipStatus }> {
  const input = parseJoin(data);
  const contributionsOn = await contributionsAllowed(deps);
  const account = await requireVerified(deps, caller);
  const children = await ownChildren(deps, caller.uid, input.childIds);
  const car = carInfo(await deps.store.vehicle(caller.uid));
  const active = (await deps.store.membershipsOf(caller.uid)).filter((m) => activeMembership(m) && m.carpoolId !== input.carpoolId);
  if (active.length >= MAX_MEMBERSHIPS) throw new CarpoolError("too-many-carpools");
  await take(deps, caller.uid, "joinRequests", DAY, deps.limits.joinRequestsPerDay);

  return deps.store.transact(async (tx) => {
    const carpool = await requireActiveCarpool(tx, input.carpoolId);
    const existing = await tx.membership(input.carpoolId, caller.uid);
    if (existing?.status === "approved") throw new CarpoolError("already-member");
    if (existing?.status === "requested") throw new CarpoolError("already-requested");
    if (carpool.kind === "school" && children.some((c) => c.schoolId !== carpool.schoolId)) throw new CarpoolError("wrong-school");
    // While contributions are off an old contribution is not asked for nor recorded.
    const withContribution = contributionsOn && carpool.contribution !== null;
    if (!input.acceptRules || !input.acceptVolunteer || (withContribution && !input.acceptContribution)) throw new CarpoolError("must-accept");
    const current = await tx.members(input.carpoolId);
    // Prompt 11 (F17): a child linked to both parents (guardian link) is in
    // a carpool once: the other parent may already have brought them.
    const taken = childIdsIn(current, await tx.requests(input.carpoolId), caller.uid);
    if (children.some((c) => taken.has(c.id))) throw new CarpoolError("child-in-carpool");
    if (children.length > seatsLeft(carpool)) throw new CarpoolError("no-seats");
    // Prompt 8: the carpool's admins are told (IDs only; they open the request in the app).
    const admins = current.filter((m) => m.role === "admin").map((m) => m.uid);
    const nowMs = deps.now();
    tx.putMembership({
      carpoolId: input.carpoolId,
      uid: caller.uid,
      status: "requested",
      role: "member",
      firstName: account.firstName,
      children: childRefs(children),
      car,
      drivingDays: [],
      acceptedRules: true,
      acceptedContribution: withContribution,
      volunteerTerms: VOLUNTEER_TERMS_VERSION,
      requestedAtMs: nowMs,
      decidedAtMs: null,
      decidedBy: null,
      updatedAtMs: nowMs,
    });
    tx.putRequest(input.carpoolId, { uid: caller.uid, firstName: account.firstName, children: childRefs(children), car, requestedAtMs: nowMs });
    if (admins.length > 0) tx.addEvent(event("join-requested", input.carpoolId, admins, nowMs, { actorUid: caller.uid }));
    return { status: "requested" as const };
  });
}

/** Takes back an open join request. */
export async function cancelJoinRequest(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ status: MembershipStatus }> {
  const carpoolId = docId(record(data).carpoolId);
  await requireVerified(deps, caller);
  return deps.store.transact(async (tx) => {
    const m = await tx.membership(carpoolId, caller.uid);
    if (!m || m.status !== "requested") throw new CarpoolError("not-requested");
    const nowMs = deps.now();
    tx.putMembership({ ...m, status: "left", decidedAtMs: nowMs, decidedBy: caller.uid, updatedAtMs: nowMs });
    tx.deleteRequest(carpoolId, caller.uid);
    return { status: "left" as const };
  });
}

/**
 * The admin approves or declines a request. Approving re-checks the seats
 * inside the transaction: the carpool never carries more children than its
 * seats. The requester's car is read again (it may have been approved since).
 */
export async function decideJoinRequest(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ status: MembershipStatus }> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const uid = docId(raw.uid);
  if (typeof raw.approve !== "boolean") throw new CarpoolError("invalid-request");
  const approve = raw.approve;
  await requireVerified(deps, caller);
  const car = approve ? carInfo(await deps.store.vehicle(uid)) : null;
  const requester = approve ? await deps.store.account(uid) : null;
  return deps.store.transact(async (tx) => {
    const carpool = await requireActiveCarpool(tx, carpoolId);
    const admin = await requireApproved(tx, carpoolId, caller.uid);
    if (admin.role !== "admin") throw new CarpoolError("not-admin");
    const m = await tx.membership(carpoolId, uid);
    if (!m || m.status !== "requested") throw new CarpoolError("not-requested");
    const nowMs = deps.now();
    tx.deleteRequest(carpoolId, uid);
    if (!approve) {
      tx.putMembership({ ...m, status: "declined", decidedAtMs: nowMs, decidedBy: caller.uid, updatedAtMs: nowMs });
      tx.addEvent(event("join-declined", carpoolId, [uid], nowMs, { actorUid: caller.uid }));
      return { status: "declined" as const };
    }
    if (!requester || requester.status !== "verified") throw new CarpoolError("not-verified");
    if (carpool.childrenCount + m.children.length > carpool.seats) throw new CarpoolError("no-seats");
    const taken = childIdsIn(await tx.members(carpoolId), [], uid);
    if (m.children.some((c) => taken.has(c.id))) throw new CarpoolError("child-in-carpool");
    const approved: MembershipRecord = { ...m, status: "approved", car, decidedAtMs: nowMs, decidedBy: caller.uid, updatedAtMs: nowMs };
    tx.putMembership(approved);
    tx.putMember(carpoolId, memberFrom(approved, nowMs));
    tx.putCarpool({
      ...carpool,
      childrenCount: carpool.childrenCount + m.children.length,
      memberCount: carpool.memberCount + 1,
      updatedAtMs: nowMs,
    });
    tx.addEvent(event("join-approved", carpoolId, [uid], nowMs, { actorUid: caller.uid }));
    return { status: "approved" as const };
  });
}

/**
 * A member leaves. Their seats free up, their pickup point is deleted and
 * every consent given to them or by them goes (a member who joins again
 * needs fresh consent, F26). The admin can leave only as the last member,
 * which closes the carpool.
 */
export async function leaveCarpool(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ status: MembershipStatus }> {
  const carpoolId = docId(record(data).carpoolId);
  await requireVerified(deps, caller);
  return deps.store.transact(async (tx) => {
    const carpool = await tx.carpool(carpoolId);
    if (!carpool) throw new CarpoolError("not-found");
    const m = await requireApproved(tx, carpoolId, caller.uid);
    const consents = await tx.consents(carpoolId);
    const members = await tx.members(carpoolId);
    if (m.role === "admin" && carpool.memberCount > 1) throw new CarpoolError("admin-must-stay");
    // Closing (the admin leaves last): open requests are declined, so they
    // stop counting toward the requesters' membership limit.
    const open = m.role === "admin" ? await tx.requests(carpoolId) : [];
    const pending = await Promise.all(open.map((r) => tx.membership(carpoolId, r.uid)));
    const nowMs = deps.now();
    open.forEach((r, i) => {
      const p = pending[i];
      if (p && p.status === "requested") {
        tx.putMembership({ ...p, status: "declined", decidedAtMs: nowMs, decidedBy: caller.uid, updatedAtMs: nowMs });
      }
      tx.deleteRequest(carpoolId, r.uid);
    });
    // Prompt 7: their children leave future pickup lists; runs they drove lose their driver.
    await releaseAfterLeave(tx, carpoolId, caller.uid, members, cairoDate(nowMs), nowMs, deps.deadlines ?? DEFAULT_DEADLINES);
    tx.putMembership({ ...m, status: "left", updatedAtMs: nowMs });
    tx.deleteMember(carpoolId, caller.uid);
    tx.putPickupPoint(carpoolId, caller.uid, null);
    for (const c of consents) {
      if (c.parentUid === caller.uid || c.driverUid === caller.uid) tx.deleteConsent(carpoolId, consentId(c.parentUid, c.driverUid));
    }
    tx.putCarpool({
      ...carpool,
      childrenCount: Math.max(0, carpool.childrenCount - m.children.length),
      memberCount: Math.max(0, carpool.memberCount - 1),
      status: m.role === "admin" ? "closed" : carpool.status,
      updatedAtMs: nowMs,
    });
    return { status: "left" as const };
  });
}

/**
 * Prompt 12: the parent's account is deleted (or the server must take the
 * parent out). Like leaveCarpool, but never refused: a pending request is
 * withdrawn; an approved admin hands the carpool to the longest-standing
 * other member (closing it only when nobody is left). Idempotent.
 */
export async function removeFromCarpool(deps: CarpoolDeps, uid: string, carpoolId: string): Promise<"left" | "closed" | "none"> {
  return deps.store.transact(async (tx) => {
    const carpool = await tx.carpool(carpoolId);
    const m = await tx.membership(carpoolId, uid);
    const nowMs = deps.now();
    if (!carpool || !m || (m.status !== "approved" && m.status !== "requested")) return "none" as const;
    if (m.status === "requested") {
      tx.putMembership({ ...m, status: "left", decidedAtMs: nowMs, decidedBy: uid, updatedAtMs: nowMs });
      tx.deleteRequest(carpoolId, uid);
      return "left" as const;
    }
    const consents = await tx.consents(carpoolId);
    const members = await tx.members(carpoolId);
    const others = members.filter((x) => x.uid !== uid).sort((a, b) => a.joinedAtMs - b.joinedAtMs);
    const closing = others.length === 0;
    const open = closing ? await tx.requests(carpoolId) : [];
    const pending = await Promise.all(open.map((r) => tx.membership(carpoolId, r.uid)));
    const heir = m.role === "admin" && !closing ? others[0] : null;
    const heirMembership = heir ? await tx.membership(carpoolId, heir.uid) : null;
    open.forEach((r, i) => {
      const p = pending[i];
      if (p && p.status === "requested") tx.putMembership({ ...p, status: "declined", decidedAtMs: nowMs, decidedBy: uid, updatedAtMs: nowMs });
      tx.deleteRequest(carpoolId, r.uid);
    });
    await releaseAfterLeave(tx, carpoolId, uid, members, cairoDate(nowMs), nowMs, deps.deadlines ?? DEFAULT_DEADLINES);
    if (heir) {
      tx.putMember(carpoolId, { ...heir, role: "admin" });
      if (heirMembership) tx.putMembership({ ...heirMembership, role: "admin", updatedAtMs: nowMs });
    }
    tx.putMembership({ ...m, status: "left", updatedAtMs: nowMs });
    tx.deleteMember(carpoolId, uid);
    tx.putPickupPoint(carpoolId, uid, null);
    for (const c of consents) {
      if (c.parentUid === uid || c.driverUid === uid) tx.deleteConsent(carpoolId, consentId(c.parentUid, c.driverUid));
    }
    tx.putCarpool({
      ...carpool,
      childrenCount: Math.max(0, carpool.childrenCount - m.children.length),
      memberCount: Math.max(0, carpool.memberCount - 1),
      status: closing ? "closed" : carpool.status,
      updatedAtMs: nowMs,
    });
    return closing ? ("closed" as const) : ("left" as const);
  });
}

// --------------------------------------------------------------------------
// Driver consent (F26)
// --------------------------------------------------------------------------

/**
 * A parent accepts another member as a driver for their children, or
 * withdraws that consent at any time. Only approved members with children
 * in the carpool give consent, and only to another approved member.
 */
export async function setDriverConsent(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<ConsentRecord> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const driverUid = docId(raw.driverUid);
  if (typeof raw.accept !== "boolean") throw new CarpoolError("invalid-request");
  const accept = raw.accept;
  if (driverUid === caller.uid) throw new CarpoolError("self-consent");
  await requireVerified(deps, caller);
  return deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    const parent = await requireApproved(tx, carpoolId, caller.uid);
    if (parent.children.length === 0) throw new CarpoolError("no-children");
    const driver = await tx.membership(carpoolId, driverUid);
    if (!driver || driver.status !== "approved") throw new CarpoolError("not-member");
    const existing = (await tx.consents(carpoolId)).find((c) => c.parentUid === caller.uid && c.driverUid === driverUid);
    const nowMs = deps.now();
    const next: ConsentRecord = accept
      ? { carpoolId, parentUid: caller.uid, driverUid, status: "accepted", acceptedAtMs: nowMs, withdrawnAtMs: null, updatedAtMs: nowMs }
      : {
          carpoolId,
          parentUid: caller.uid,
          driverUid,
          status: "withdrawn",
          acceptedAtMs: existing?.acceptedAtMs ?? null,
          withdrawnAtMs: nowMs,
          updatedAtMs: nowMs,
        };
    tx.putConsent(next);
    if (!accept) {
      // Prompt 7: that driver no longer drives this parent's children on any future run.
      const members = await tx.members(carpoolId);
      await releaseAfterWithdraw(tx, carpoolId, caller.uid, driverUid, members, cairoDate(nowMs), nowMs, deps.deadlines ?? DEFAULT_DEADLINES);
    }
    return next;
  });
}

// --------------------------------------------------------------------------
// Pickup point (spec section 6: exact address only inside the carpool, only if the parent chooses)
// --------------------------------------------------------------------------

/**
 * Shares the member's EXACT home as their pickup point with this carpool
 * (approved members only can read it), or stops sharing.
 */
export async function setPickupSharing(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ shared: boolean }> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  if (typeof raw.share !== "boolean") throw new CarpoolError("invalid-request");
  const share = raw.share;
  await requireVerified(deps, caller);
  const home = share ? await deps.store.home(caller.uid) : null;
  if (share && !home) throw new CarpoolError("no-home");
  return deps.store.transact(async (tx) => {
    const m = await requireApproved(tx, carpoolId, caller.uid);
    const members = await tx.members(carpoolId);
    const mine = members.find((x) => x.uid === caller.uid) ?? memberFrom(m, deps.now());
    tx.putPickupPoint(carpoolId, caller.uid, share ? home : null);
    tx.putMember(carpoolId, { ...mine, pickupShared: share });
    return { shared: share };
  });
}

// --------------------------------------------------------------------------
// Invite links (F31)
// --------------------------------------------------------------------------

export const INVITE_CODE = /^[2-9A-HJ-NP-Z]{10}$/;

/** An approved member makes a link to share by WhatsApp. */
export async function createInvite(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ code: string; url: string; expiresAtMs: number }> {
  const carpoolId = docId(record(data).carpoolId);
  await requireVerified(deps, caller);
  await deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    await requireApproved(tx, carpoolId, caller.uid);
  });
  await take(deps, caller.uid, "invites", DAY, deps.limits.invitesPerDay);
  const nowMs = deps.now();
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = deps.newCode();
    const invite: InviteRecord = { code, carpoolId, createdBy: caller.uid, createdAtMs: nowMs, expiresAtMs: nowMs + INVITE_DAYS * DAY };
    if (await deps.store.createInvite(invite)) {
      return { code, url: `${deps.linkBase.replace(/\/+$/, "")}/c/${code}`, expiresAtMs: invite.expiresAtMs };
    }
  }
  throw new Error("could not create a free invite code");
}

/**
 * Opens an invite link. The parent must be verified before anything is
 * shown (F31); the answer is only the carpool ID, and joining still needs
 * the admin's approval. Opens are limited per hour, so codes cannot be guessed.
 */
export async function openInvite(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ carpoolId: string }> {
  const raw = record(data).code;
  const code = typeof raw === "string" ? raw.trim().toUpperCase() : "";
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "inviteOpens", HOUR, deps.limits.inviteOpensPerHour);
  if (!INVITE_CODE.test(code)) throw new CarpoolError("invite-invalid");
  const invite = await deps.store.invite(code);
  if (!invite || invite.expiresAtMs <= deps.now()) throw new CarpoolError("invite-invalid");
  const carpool = await deps.store.transact((tx) => tx.carpool(invite.carpoolId));
  if (!carpool || carpool.status !== "active") throw new CarpoolError("invite-invalid");
  return { carpoolId: invite.carpoolId };
}

// --------------------------------------------------------------------------
// Looking for a carpool (F32)
// --------------------------------------------------------------------------

export interface WantedPost {
  id: string;
  firstName: string;
  areaId: string | null;
  areaNameAr: string;
  areaNameEn: string;
  morning: string | null;
  afternoon: string | null;
  days: Day[];
  childrenCount: number;
  mine: boolean;
}

function postOf(w: WantedRecord, callerUid: string): WantedPost {
  return {
    id: w.uid,
    firstName: w.firstName,
    areaId: w.areaId,
    areaNameAr: w.areaNameAr,
    areaNameEn: w.areaNameEn,
    morning: w.morning,
    afternoon: w.afternoon,
    days: w.days,
    childrenCount: w.childrenCount,
    mine: w.uid === callerUid,
  };
}

/** Posts (or replaces) the caller's "Looking for a carpool" for one of their children's schools. */
export async function saveWanted(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<WantedPost> {
  const raw = record(data);
  const schoolId = docId(raw.schoolId);
  const areaId = optionalDocId(raw.areaId);
  const morning = parseTime(raw.morning);
  const afternoon = parseTime(raw.afternoon);
  if (!morning && !afternoon) throw new CarpoolError("invalid-request");
  const days = parseDays(raw.days);
  const childIds = parseIds(raw.childIds, MAX_SEATS);
  const account = await requireVerified(deps, caller);
  const children = await ownChildren(deps, caller.uid, childIds);
  if (children.some((c) => c.schoolId !== schoolId)) throw new CarpoolError("wrong-school");
  const school = await activeSchool(deps, schoolId);
  const area = await areaOf(deps, schoolId, areaId);
  await take(deps, caller.uid, "wantedSaves", DAY, deps.limits.wantedSavesPerDay);
  const nowMs = deps.now();
  const w: WantedRecord = {
    uid: caller.uid,
    firstName: account.firstName,
    schoolId,
    schoolNameAr: school.nameAr,
    schoolNameEn: school.nameEn,
    areaId,
    areaNameAr: area?.nameAr ?? "",
    areaNameEn: area?.nameEn ?? "",
    morning,
    afternoon,
    days,
    childrenCount: children.length,
    createdAtMs: nowMs,
    expiresAtMs: nowMs + WANTED_DAYS * DAY,
  };
  await deps.store.putWanted(caller.uid, w);
  return postOf(w, caller.uid);
}

export async function deleteWanted(deps: CarpoolDeps, caller: Caller): Promise<{ deleted: boolean }> {
  await requireVerified(deps, caller);
  await deps.store.putWanted(caller.uid, null);
  return { deleted: true };
}

/**
 * Posts of verified parents of the same school (and area, when chosen),
 * newest first, and a suggestion to start a group when the caller's post
 * matches at least two other families (F32).
 */
export async function listWanted(
  deps: CarpoolDeps,
  caller: Caller,
  data: unknown,
): Promise<{ posts: WantedPost[]; suggestion: WantedSuggestion | null }> {
  const raw = record(data);
  const schoolId = docId(raw.schoolId);
  const areaId = optionalDocId(raw.areaId);
  await requireVerified(deps, caller);
  if (!(await mySchoolIds(deps, caller.uid)).has(schoolId)) throw new CarpoolError("not-your-school");
  await take(deps, caller.uid, "wantedLists", HOUR, deps.limits.wantedListsPerHour);
  const nowMs = deps.now();
  const all = (await deps.store.wantedForSchool(schoolId, 200)).filter((w) => w.schoolId === schoolId && w.expiresAtMs > nowMs);
  const others = all.filter((w) => w.uid !== caller.uid);
  const mine = all.find((w) => w.uid === caller.uid) ?? null;
  const posts = all
    .filter((w) => !areaId || w.uid === caller.uid || w.areaId === null || w.areaId === areaId)
    .sort((a, b) => b.createdAtMs - a.createdAtMs)
    .slice(0, 50)
    .map((w) => postOf(w, caller.uid));
  return { posts, suggestion: suggestion(mine, others) };
}
