import {
  DEFAULT_RADIUS_KM,
  distanceKm,
  encodeGeohash,
  geohashCoverPrefixes,
  inEgypt,
  isValidPoint,
  jitterFor,
  RADIUS_CHOICES_KM,
  roundToGrid,
  STORED_GEOHASH_PRECISION,
  type LatLng,
} from "./geo";
import { LIMIT_WINDOWS, type MapLimitKind } from "./limits";

/**
 * Home, map settings, driving schools and the nearby parents map
 * (F21, F22, F23, F24). Pure flows over a [MapStore]; Firestore lives in
 * store.ts and the callables in callables.ts.
 *
 * Records:
 * - homes/{uid} (HomeRecord): the EXACT home and the parent's map
 *   settings. Readable by its owner only; written only here.
 * - parentLocations/{uid} (PublicLocation): what the nearby search uses.
 *   Only the ROUNDED point (about 500 m) and a geohash of that rounded
 *   point. Cloud Functions only: the app never reads it.
 * - newParentEvents/{uid}: one "new parent nearby" event per parent,
 *   created when the parent is verified, has a home and a school, and is
 *   shown on the map. Prompt 8 sends it (and must check the parent is
 *   still verified and shown at that time).
 * - mapLimits/{uid}: the rate limits (limits.ts).
 *
 * Exact pickup points for carpools live in
 * carpools/{carpoolId}/pickupPoints/{uid} (Prompt 6 writes them, only when
 * the parent chooses to share; firestore.rules lets only approved members
 * of that carpool read them).
 */

export type MapErrorReason =
  | "invalid-request"
  | "invalid-location"
  | "outside-egypt"
  | "no-account"
  | "suspended"
  | "not-verified"
  | "no-home"
  | "not-your-school"
  | "invalid-school"
  | "too-many-schools"
  | "rate-limited";

export class MapError extends Error {
  constructor(
    readonly reason: MapErrorReason,
    readonly retryAfterMs = 0,
  ) {
    super(reason);
    this.name = "MapError";
  }
}

export const MAP_ERROR_CODES: Record<MapErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "invalid-location": "invalid-argument",
  "outside-egypt": "invalid-argument",
  "no-account": "failed-precondition",
  suspended: "permission-denied",
  "not-verified": "permission-denied",
  "no-home": "failed-precondition",
  "not-your-school": "permission-denied",
  "invalid-school": "invalid-argument",
  "too-many-schools": "invalid-argument",
  "rate-limited": "resource-exhausted",
};

export interface SchoolRef {
  id: string;
  nameAr: string;
  nameEn: string;
}

export interface SchoolInfo extends SchoolRef {
  status: string;
}

/** homes/{uid}: private to its owner. */
export interface HomeRecord {
  /** Exact point, or null before the parent sets a home. */
  location: LatLng | null;
  /** The address the parent picked (Places) or "". Owner only. */
  label: string;
  showOnMap: boolean;
  notifyNewParents: boolean;
  radiusKm: number;
  /** F24: schools the parent can drive to (names kept for the app). */
  drivingSchools: SchoolRef[];
  updatedAtMs: number;
}

/** parentLocations/{uid}: Cloud Functions only. Never an exact point. */
export interface PublicLocation {
  /** Centre of the ~500 m grid cell (roundToGrid). */
  point: LatLng;
  /** Geohash of [point] (the rounded point). */
  geohash: string;
  firstName: string;
  verified: boolean;
  showOnMap: boolean;
  notifyNewParents: boolean;
  radiusKm: number;
  /** Children's schools plus driving schools: what search and alerts match. */
  schoolIds: string[];
  childSchoolIds: string[];
  drivingSchoolIds: string[];
  /** Set once the "new parent nearby" event exists. */
  announced: boolean;
  updatedAtMs: number;
}

export interface NewParentEvent {
  uid: string;
  firstName: string;
  schoolIds: string[];
  point: LatLng;
  geohash: string;
  createdAtMs: number;
  status: "pending";
}

export interface AccountInfo {
  status: string;
  firstName: string;
}

export interface MapStore {
  account(uid: string): Promise<AccountInfo | null>;
  /** Distinct school IDs of the parent's approved children. */
  childSchoolIds(uid: string): Promise<string[]>;
  schools(ids: string[]): Promise<SchoolInfo[]>;
  home(uid: string): Promise<HomeRecord | null>;
  saveHome(uid: string, home: HomeRecord): Promise<void>;
  publicLocation(uid: string): Promise<PublicLocation | null>;
  /** null deletes the record. */
  savePublicLocation(uid: string, doc: PublicLocation | null): Promise<void>;
  /** Takes one from the parent's counter, atomically. */
  takeLimit(uid: string, kind: MapLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;
  /** Public records with [schoolId] whose geohash starts with [prefix]. */
  nearby(schoolId: string, prefix: string, limit: number): Promise<Array<{ uid: string; doc: PublicLocation }>>;
  /** false when the parent's event already exists. */
  createNewParentEvent(event: NewParentEvent): Promise<boolean>;
}

export interface MapLimits {
  homeMovesPerDay: number;
  nearbySearchesPerHour: number;
  placeSearchesPerHour: number;
  drivingSchoolChangesPerDay: number;
}

export const DEFAULT_MAP_LIMITS: MapLimits = {
  homeMovesPerDay: 4,
  nearbySearchesPerHour: 30,
  placeSearchesPerHour: 60,
  drivingSchoolChangesPerDay: 10,
};

export interface MapDeps {
  store: MapStore;
  now: () => number;
  limits: MapLimits;
}

/** F24: at most this many driving schools. */
export const MAX_DRIVING_SCHOOLS = 5;

/** Results per geohash range query, and in all. */
export const NEARBY_PER_RANGE = 50;
export const NEARBY_MAX_RESULTS = 100;

/** A move shorter than this (a re-save of the same pin) is not counted. */
export const SAME_PLACE_KM = 0.02;

const LABEL_MAX = 200;
const DOC_ID = /^[A-Za-z0-9_-]{1,128}$/;

export function defaultHome(nowMs: number): HomeRecord {
  return {
    location: null,
    label: "",
    showOnMap: true,
    notifyNewParents: true,
    radiusKm: DEFAULT_RADIUS_KM,
    drivingSchools: [],
    updatedAtMs: nowMs,
  };
}

function record(data: unknown): Record<string, unknown> {
  return typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
}

async function requireAccount(store: MapStore, uid: string): Promise<AccountInfo> {
  const account = await store.account(uid);
  if (!account) throw new MapError("no-account");
  if (account.status === "suspended") throw new MapError("suspended");
  return account;
}

async function take(deps: MapDeps, uid: string, kind: MapLimitKind, max: number): Promise<void> {
  const result = await deps.store.takeLimit(uid, kind, deps.now(), { windowMs: LIMIT_WINDOWS[kind], max });
  if (!result.allowed) throw new MapError("rate-limited", result.retryAfterMs);
}

// --------------------------------------------------------------------------
// Public record
// --------------------------------------------------------------------------

/**
 * The public record for a parent, or null when there is nothing to show
 * (no home yet). Only the rounded point leaves this function.
 */
export function buildPublicLocation(
  home: HomeRecord,
  account: AccountInfo,
  childSchoolIds: string[],
  previous: PublicLocation | null,
  nowMs: number,
): PublicLocation | null {
  if (!home.location) return null;
  const point = roundToGrid(home.location);
  const drivingSchoolIds = home.drivingSchools.map((s) => s.id);
  const childIds = [...new Set(childSchoolIds)].sort();
  return {
    point,
    geohash: encodeGeohash(point, STORED_GEOHASH_PRECISION),
    firstName: account.firstName,
    verified: account.status === "verified",
    showOnMap: home.showOnMap,
    notifyNewParents: home.notifyNewParents,
    radiusKm: home.radiusKm,
    schoolIds: [...new Set([...childIds, ...drivingSchoolIds])].sort(),
    childSchoolIds: childIds,
    drivingSchoolIds,
    announced: previous?.announced ?? false,
    updatedAtMs: nowMs,
  };
}

function samePublic(a: PublicLocation | null, b: PublicLocation | null): boolean {
  if (a === null || b === null) return a === b;
  const strip = (d: PublicLocation) => JSON.stringify({ ...d, updatedAtMs: 0 });
  return strip(a) === strip(b);
}

/**
 * Rebuilds parentLocations/{uid} from the home, the account and the
 * children, and creates the "new parent nearby" event the first time the
 * parent is verified, has a home and a school, and is shown on the map.
 * Called after every change and by the users/children triggers.
 */
export async function refreshPublicLocation(deps: MapDeps, uid: string): Promise<PublicLocation | null> {
  const { store } = deps;
  const [home, account, previous] = await Promise.all([store.home(uid), store.account(uid), store.publicLocation(uid)]);
  if (!home?.location || !account) {
    if (previous) await store.savePublicLocation(uid, null);
    return null;
  }
  const nowMs = deps.now();
  const next = buildPublicLocation(home, account, await store.childSchoolIds(uid), previous, nowMs);
  if (next && !next.announced && next.verified && next.showOnMap && next.schoolIds.length > 0) {
    await store.createNewParentEvent({
      uid,
      firstName: next.firstName,
      schoolIds: next.schoolIds,
      point: next.point,
      geohash: next.geohash,
      createdAtMs: nowMs,
      status: "pending",
    });
    next.announced = true;
  }
  if (!samePublic(previous, next)) await store.savePublicLocation(uid, next);
  return next;
}

// --------------------------------------------------------------------------
// Home (F21)
// --------------------------------------------------------------------------

export interface SetHomeInput {
  location: LatLng;
  label: string;
}

export function parseSetHome(data: unknown): SetHomeInput {
  const raw = record(data);
  const location = raw.location;
  if (!isValidPoint(location)) throw new MapError("invalid-location");
  if (!inEgypt(location)) throw new MapError("outside-egypt");
  const label = typeof raw.label === "string" ? raw.label.trim().replace(/\s+/g, " ").slice(0, LABEL_MAX) : "";
  // About 1 m is plenty for a home pin.
  return { location: { lat: Math.round(location.lat * 1e5) / 1e5, lng: Math.round(location.lng * 1e5) / 1e5 }, label };
}

/**
 * Saves the parent's home. The exact point stays in homes/{uid}; the
 * public record gets the rounded point. Moves are limited per day; saving
 * the same place again (or only the address text) is not counted.
 * Returns the rounded point others will see.
 */
export async function setHome(deps: MapDeps, uid: string, data: unknown): Promise<{ approximate: LatLng }> {
  const input = parseSetHome(data);
  await requireAccount(deps.store, uid);
  const existing = await deps.store.home(uid);
  const moved = !existing?.location || distanceKm(existing.location, input.location) > SAME_PLACE_KM;
  if (moved) await take(deps, uid, "homeMoves", deps.limits.homeMovesPerDay);
  const home: HomeRecord = {
    ...(existing ?? defaultHome(deps.now())),
    location: input.location,
    label: input.label,
    updatedAtMs: deps.now(),
  };
  await deps.store.saveHome(uid, home);
  await refreshPublicLocation(deps, uid);
  return { approximate: roundToGrid(input.location) };
}

// --------------------------------------------------------------------------
// Settings (spec section 6: map visibility and new-parent alerts)
// --------------------------------------------------------------------------

export interface MapSettings {
  showOnMap: boolean;
  notifyNewParents: boolean;
  radiusKm: number;
}

export function parseMapSettings(data: unknown): Partial<MapSettings> {
  const raw = record(data);
  const out: Partial<MapSettings> = {};
  if (raw.showOnMap !== undefined) {
    if (typeof raw.showOnMap !== "boolean") throw new MapError("invalid-request");
    out.showOnMap = raw.showOnMap;
  }
  if (raw.notifyNewParents !== undefined) {
    if (typeof raw.notifyNewParents !== "boolean") throw new MapError("invalid-request");
    out.notifyNewParents = raw.notifyNewParents;
  }
  if (raw.radiusKm !== undefined) {
    if (!(RADIUS_CHOICES_KM as readonly unknown[]).includes(raw.radiusKm)) throw new MapError("invalid-request");
    out.radiusKm = raw.radiusKm as number;
  }
  if (Object.keys(out).length === 0) throw new MapError("invalid-request");
  return out;
}

/** Hide me from the map, new-parent alerts on or off, search radius. */
export async function updateMapSettings(deps: MapDeps, uid: string, data: unknown): Promise<MapSettings> {
  const patch = parseMapSettings(data);
  await requireAccount(deps.store, uid);
  const existing = (await deps.store.home(uid)) ?? defaultHome(deps.now());
  const home: HomeRecord = { ...existing, ...patch, updatedAtMs: deps.now() };
  await deps.store.saveHome(uid, home);
  await refreshPublicLocation(deps, uid);
  return { showOnMap: home.showOnMap, notifyNewParents: home.notifyNewParents, radiusKm: home.radiusKm };
}

// --------------------------------------------------------------------------
// Driving schools (F24)
// --------------------------------------------------------------------------

export function parseDrivingSchools(data: unknown): string[] {
  const ids = record(data).schoolIds;
  if (!Array.isArray(ids) || ids.some((id) => typeof id !== "string" || !DOC_ID.test(id))) {
    throw new MapError("invalid-request");
  }
  const unique = [...new Set(ids as string[])];
  if (unique.length > MAX_DRIVING_SCHOOLS) throw new MapError("too-many-schools");
  return unique;
}

/**
 * Replaces the parent's driving schools. Only active schools. Changes are
 * limited per day: the schools decide whose map a parent may search, so
 * changing them freely would let someone sweep many schools.
 */
export async function setDrivingSchools(deps: MapDeps, uid: string, data: unknown): Promise<{ schools: SchoolRef[] }> {
  const ids = parseDrivingSchools(data);
  await requireAccount(deps.store, uid);
  const found = ids.length === 0 ? [] : await deps.store.schools(ids);
  const byId = new Map(found.map((s) => [s.id, s]));
  const schools: SchoolRef[] = ids.map((id) => {
    const s = byId.get(id);
    if (!s || s.status !== "active") throw new MapError("invalid-school");
    return { id: s.id, nameAr: s.nameAr, nameEn: s.nameEn };
  });
  const existing = (await deps.store.home(uid)) ?? defaultHome(deps.now());
  const same = JSON.stringify(existing.drivingSchools.map((s) => s.id)) === JSON.stringify(ids);
  if (!same) await take(deps, uid, "drivingSchoolChanges", deps.limits.drivingSchoolChangesPerDay);
  await deps.store.saveHome(uid, { ...existing, drivingSchools: schools, updatedAtMs: deps.now() });
  await refreshPublicLocation(deps, uid);
  return { schools };
}

// --------------------------------------------------------------------------
// Nearby parents (F22)
// --------------------------------------------------------------------------

export interface NearbyParent {
  /** The parent's uid (for Message and Join in later prompts). */
  id: string;
  firstName: string;
  schoolId: string;
  /** Rounded (~500 m) point plus a fixed offset. Never the exact home. */
  point: LatLng;
}

export interface NearbyResult {
  schoolId: string;
  radiusKm: number;
  parents: NearbyParent[];
}

export function parseNearby(data: unknown): { schoolId: string; radiusKm: number } {
  const raw = record(data);
  const schoolId = raw.schoolId;
  if (typeof schoolId !== "string" || !DOC_ID.test(schoolId)) throw new MapError("invalid-request");
  const radiusKm = raw.radiusKm ?? DEFAULT_RADIUS_KM;
  if (!(RADIUS_CHOICES_KM as readonly unknown[]).includes(radiusKm)) throw new MapError("invalid-request");
  return { schoolId, radiusKm: radiusKm as number };
}

/**
 * Verified parents of one of the caller's schools within the radius of the
 * caller's own (rounded) home. The centre is always the caller's home,
 * which moves only a few times a day, and the school must be one of the
 * caller's: nobody can sweep the map. Searches are limited per hour.
 *
 * Hidden parents, unverified or suspended parents and the caller are left
 * out. Points are rounded again (defence in depth) and offset per parent.
 */
export async function searchNearby(
  deps: MapDeps,
  caller: { uid: string; verifiedClaim: boolean },
  data: unknown,
): Promise<NearbyResult> {
  const { schoolId, radiusKm } = parseNearby(data);
  if (!caller.verifiedClaim) throw new MapError("not-verified");
  const account = await requireAccount(deps.store, caller.uid);
  if (account.status !== "verified") throw new MapError("not-verified");
  const mine = await refreshPublicLocation(deps, caller.uid);
  if (!mine) throw new MapError("no-home");
  if (!mine.schoolIds.includes(schoolId)) throw new MapError("not-your-school");
  await take(deps, caller.uid, "nearbySearches", deps.limits.nearbySearchesPerHour);

  const center = mine.point;
  const seen = new Set<string>([caller.uid]);
  const found: Array<{ uid: string; doc: PublicLocation; km: number }> = [];
  for (const prefix of geohashCoverPrefixes(center, radiusKm)) {
    for (const hit of await deps.store.nearby(schoolId, prefix, NEARBY_PER_RANGE)) {
      if (seen.has(hit.uid)) continue;
      seen.add(hit.uid);
      const d = hit.doc;
      if (!d.verified || !d.showOnMap || !d.schoolIds.includes(schoolId) || !isValidPoint(d.point)) continue;
      const km = distanceKm(center, d.point);
      if (km <= radiusKm) found.push({ uid: hit.uid, doc: d, km });
    }
  }
  found.sort((a, b) => a.km - b.km || a.uid.localeCompare(b.uid));
  return {
    schoolId,
    radiusKm,
    parents: found.slice(0, NEARBY_MAX_RESULTS).map(({ uid, doc }) => ({
      id: uid,
      firstName: doc.firstName,
      schoolId,
      point: jitterFor(uid, roundToGrid(doc.point)),
    })),
  };
}

/** Place searches (address autocomplete) share the maps limits. */
export async function takePlaceSearch(deps: MapDeps, uid: string): Promise<void> {
  await requireAccount(deps.store, uid);
  await take(deps, uid, "placeSearches", deps.limits.placeSearchesPerHour);
}
