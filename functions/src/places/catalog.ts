import { GOVERNORATES } from "../admin_panel/schools";
import { normalizeText } from "../text/normalize";

/**
 * City -> Area -> District (F4 grouping, F46 addresses). Pure logic, no
 * Firebase: unit tested in test/places.test.ts.
 *
 * City is the governorate (27 codes, admin_panel/schools.ts GOVERNORATES).
 * Firestore (written only by the loader and Cloud Functions; signed-in
 * users read placeAreas and placeDistricts, firestore.rules). The app's
 * documents hold only what the menus need (spec section 9: outlines are
 * server only, address counts are admin only):
 *
 *   placeAreas/{id}      qism / markaz / new city: governorate, nameAr,
 *                        nameEn, centre, schoolCount, active, mergedInto,
 *                        createdAt, updatedAt
 *   placeDistricts/{id}  neighbourhood: areaId, governorate, nameAr,
 *                        nameEn, centre, schoolCount, active, mergedInto
 *   placeInternal/{area_<id> | district_<id>}  Cloud Functions only: kind,
 *                        placeId, areaId (districts), level (OSM
 *                        admin_level, 0 for an admin's), source (osm |
 *                        admin | osm-boundary | osm-place), bbox, rings
 *                        ([{p: [lat, lng, lat, lng, ...]}], simplified
 *                        outer rings, for the server's point-in-polygon),
 *                        addressCount, adminEdited, updatedAt
 *   placeIndex/areas     every active area's id, governorate and bbox (one
 *                        read finds the candidate areas for a point)
 *
 * Documents loaded before the split may still carry the internal fields on
 * the public document; readers fall back to them and the loader moves them
 * (load_schools.ts).
 *   placeRequests/{id}   "my district isn't listed" (F46): uid, areaId,
 *                        governorate, text, status open | done; admins only
 *
 * These are NOT the per-school `areas` of Prompt 6 (an area of one school,
 * used by carpools): owner decision 16 Nov 2026, both kept (DECISIONS.md).
 */

export const PLACE_AREAS = "placeAreas";
export const PLACE_DISTRICTS = "placeDistricts";
export const PLACE_INDEX = "placeIndex";
export const PLACE_INDEX_AREAS = "areas";
export const PLACE_REQUESTS = "placeRequests";
export const PLACE_INTERNAL = "placeInternal";

/** The fields of a place that live in placeInternal (never on the app's documents). */
export const INTERNAL_FIELDS = ["level", "source", "bbox", "rings", "addressCount", "adminEdited"] as const;

/** placeInternal document ID of an area or a district. */
export function internalId(kind: "area" | "district", id: string): string {
  return `${kind}_${id}`;
}

export interface LatLng {
  lat: number;
  lng: number;
}

export interface BBox {
  minLat: number;
  minLng: number;
  maxLat: number;
  maxLng: number;
}

/** One ring as [lat, lng] pairs. */
export type Ring = Array<[number, number]>;

export interface PlaceArea {
  id: string;
  governorate: string;
  nameAr: string;
  nameEn: string;
  level: number;
  source: string;
  centre: LatLng | null;
  bbox: BBox | null;
  rings: Ring[];
  schoolCount: number;
  addressCount: number;
  active: boolean;
  mergedInto: string | null;
  adminEdited: boolean;
}

export interface PlaceDistrict {
  id: string;
  areaId: string;
  governorate: string;
  nameAr: string;
  nameEn: string;
  source: string;
  centre: LatLng | null;
  bbox: BBox | null;
  rings: Ring[];
  schoolCount: number;
  addressCount: number;
  active: boolean;
  mergedInto: string | null;
  adminEdited: boolean;
}

export interface IndexEntry {
  id: string;
  governorate: string;
  bbox: BBox;
}

const DOC_ID = /^[A-Za-z0-9_-]{1,64}$/;
export const isPlaceId = (v: unknown): v is string => typeof v === "string" && DOC_ID.test(v);
export const isGovernorate = (v: unknown): v is string => typeof v === "string" && (GOVERNORATES as readonly string[]).includes(v);

// --------------------------------------------------------------------------
// Geometry
// --------------------------------------------------------------------------

export function inBox(p: LatLng, b: BBox | null): boolean {
  return !!b && p.lat >= b.minLat && p.lat <= b.maxLat && p.lng >= b.minLng && p.lng <= b.maxLng;
}

/** Ray casting on one [lat, lng] ring. */
export function ringContains(ring: Ring, p: LatLng): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [yi, xi] = ring[i];
    const [yj, xj] = ring[j];
    if (yi > p.lat !== yj > p.lat && p.lng < ((xj - xi) * (p.lat - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

export function shapeContains(shape: { bbox: BBox | null; rings: Ring[] }, p: LatLng): boolean {
  return inBox(p, shape.bbox) && shape.rings.some((r) => ringContains(r, p));
}

function distanceKm(a: LatLng, b: LatLng): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371.0088 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** A district without a boundary counts for points this close to its centre. */
export const POINT_DISTRICT_KM = 1.5;

export interface Located {
  governorate: string | null;
  areaId: string | null;
  districtId: string | null;
}

/**
 * The area holding [p] (active areas only; the first of [areas] wins, so
 * pass them finest level first) and the district: the boundary holding
 * it, else the nearest named place of that area within POINT_DISTRICT_KM.
 */
export function locate(p: LatLng, areas: PlaceArea[], districts: PlaceDistrict[]): Located {
  const sorted = [...areas].filter((a) => a.active).sort((a, b) => b.level - a.level || a.id.localeCompare(b.id));
  const area = sorted.find((a) => shapeContains(a, p));
  if (!area) return { governorate: null, areaId: null, districtId: null };
  const mine = districts.filter((d) => d.active && d.areaId === area.id);
  const inside = mine.find((d) => d.rings.length > 0 && shapeContains(d, p));
  if (inside) return { governorate: area.governorate, areaId: area.id, districtId: inside.id };
  let best: { id: string; km: number } | null = null;
  for (const d of mine) {
    if (d.rings.length > 0 || !d.centre) continue;
    const km = distanceKm(p, d.centre);
    if (km <= POINT_DISTRICT_KM && (!best || km < best.km)) best = { id: d.id, km };
  }
  return { governorate: area.governorate, areaId: area.id, districtId: best?.id ?? null };
}

/** Candidate area IDs for [p] from the index (bbox only). */
export function candidates(index: IndexEntry[], p: LatLng): string[] {
  return index.filter((e) => inBox(p, e.bbox)).map((e) => e.id);
}

// --------------------------------------------------------------------------
// places.json (tools/import_schools) -> Firestore
// --------------------------------------------------------------------------

export interface ImportedArea {
  id: string;
  governorate: string;
  nameAr: string;
  nameEn: string;
  level: number;
  centre: LatLng | null;
  bbox: BBox | null;
  rings: Ring[];
}

export interface ImportedDistrict {
  id: string;
  areaId: string;
  governorate: string;
  nameAr: string;
  nameEn: string;
  source: string;
  centre: LatLng | null;
  bbox: BBox | null;
  rings: Ring[];
}

export const PLACES_FORMAT = "school-carpool-places/1";
/** Simplified rings keep a document far below Firestore's 1 MiB. */
export const MAX_RING_POINTS = 2000;

function obj(v: unknown): Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

function point(v: unknown): LatLng | null {
  const o = obj(v);
  return typeof o.lat === "number" && typeof o.lng === "number" && Number.isFinite(o.lat) && Number.isFinite(o.lng)
    ? { lat: o.lat, lng: o.lng }
    : null;
}

function bbox(v: unknown): BBox | null {
  const o = obj(v);
  const keys = ["minLat", "minLng", "maxLat", "maxLng"] as const;
  return keys.every((k) => typeof o[k] === "number") ? (o as unknown as BBox) : null;
}

function rings(v: unknown): Ring[] {
  if (!Array.isArray(v)) return [];
  const out: Ring[] = [];
  let total = 0;
  for (const r of v) {
    if (!Array.isArray(r)) continue;
    const ring: Ring = [];
    for (const pair of r) {
      if (Array.isArray(pair) && typeof pair[0] === "number" && typeof pair[1] === "number") ring.push([pair[0], pair[1]]);
    }
    total += ring.length;
    if (ring.length >= 4 && total <= MAX_RING_POINTS) out.push(ring);
  }
  return out;
}

function name(v: unknown): string {
  return typeof v === "string" ? v.trim().replace(/\s+/g, " ").slice(0, 80) : "";
}

export function parsePlacesFile(doc: unknown): { areas: ImportedArea[]; districts: ImportedDistrict[]; refused: number } {
  const d = obj(doc);
  if (d.format !== PLACES_FORMAT) throw new Error("not a places.json");
  let refused = 0;
  const areas: ImportedArea[] = [];
  for (const raw of Array.isArray(d.areas) ? d.areas : []) {
    const a = obj(raw);
    const nameAr = name(a.nameAr);
    if (!isPlaceId(a.id) || !isGovernorate(a.governorate) || nameAr.length < 2) {
      refused++;
      continue;
    }
    areas.push({
      id: a.id,
      governorate: a.governorate,
      nameAr,
      nameEn: name(a.nameEn) || nameAr,
      level: typeof a.level === "number" ? a.level : 0,
      centre: point(a.centre),
      bbox: bbox(a.bbox),
      rings: rings(a.rings),
    });
  }
  const areaIds = new Set(areas.map((a) => a.id));
  const districts: ImportedDistrict[] = [];
  for (const raw of Array.isArray(d.districts) ? d.districts : []) {
    const x = obj(raw);
    const nameAr = name(x.nameAr);
    if (!isPlaceId(x.id) || !isPlaceId(x.areaId) || !areaIds.has(x.areaId) || !isGovernorate(x.governorate) || nameAr.length < 2) {
      refused++;
      continue;
    }
    districts.push({
      id: x.id,
      areaId: x.areaId,
      governorate: x.governorate,
      nameAr,
      nameEn: name(x.nameEn) || nameAr,
      source: typeof x.source === "string" ? x.source.slice(0, 20) : "osm",
      centre: point(x.centre),
      bbox: bbox(x.bbox),
      rings: rings(x.rings),
    });
  }
  return { areas, districts, refused };
}

/** What the loader compares; counts and admin fields are not imported. */
interface Comparable {
  nameAr: string;
  nameEn: string;
  governorate: string;
  centre: LatLng | null;
  rings: Ring[];
}

function sameShape(a: Comparable, b: Comparable): boolean {
  return (
    a.nameAr === b.nameAr &&
    a.nameEn === b.nameEn &&
    a.governorate === b.governorate &&
    JSON.stringify(a.centre) === JSON.stringify(b.centre) &&
    JSON.stringify(a.rings) === JSON.stringify(b.rings)
  );
}

export interface PlacePlan<T> {
  creates: T[];
  updates: T[];
  unchanged: number;
  /** Edited by an admin (or merged): never overwritten by an import. */
  skipped: number;
  /**
   * Imported earlier (source osm or cod), active, not admin-edited, and
   * not in this file: set inactive (never deleted), so a better source
   * replaces them (the OpenStreetMap areas of 16 Nov 2026 -> COD-AB ADM2).
   * Empty when the file would retire more places than it brings (a broken
   * download must not empty the list).
   */
  retires: string[];
}

export const IMPORTED_PLACE_SOURCES = ["osm", "cod", "osm-boundary", "osm-place"] as const;

/** Idempotent: unchanged places are not written, admin edits are kept, nothing is deleted. */
export function planPlaces<
  T extends Comparable & { id: string },
  E extends Comparable & { id: string; adminEdited: boolean; mergedInto: string | null; active?: boolean; source?: string },
>(
  incoming: T[],
  existing: E[],
  extraSame: (a: T, b: E) => boolean = () => true,
): PlacePlan<T> {
  const byId = new Map(existing.map((e) => [e.id, e]));
  const plan: PlacePlan<T> = { creates: [], updates: [], unchanged: 0, skipped: 0, retires: [] };
  for (const p of incoming) {
    const e = byId.get(p.id);
    if (!e) plan.creates.push(p);
    else if (e.adminEdited || e.mergedInto) plan.skipped++;
    else if (sameShape(p, e) && extraSame(p, e)) plan.unchanged++;
    else plan.updates.push(p);
  }
  const incomingIds = new Set(incoming.map((p) => p.id));
  const retires = existing
    .filter(
      (e) =>
        !incomingIds.has(e.id) &&
        e.active !== false &&
        !e.adminEdited &&
        !e.mergedInto &&
        (IMPORTED_PLACE_SOURCES as readonly string[]).includes(e.source ?? "osm"),
    )
    .map((e) => e.id)
    .sort();
  plan.retires = incoming.length >= retires.length ? retires : [];
  return plan;
}

/** Firestore cannot hold nested arrays: each ring becomes { p: [lat, lng, lat, lng, ...] }. */
export function ringsToDoc(rs: Ring[]): Array<{ p: number[] }> {
  return rs.map((r) => ({ p: r.flatMap(([lat, lng]) => [lat, lng]) }));
}

export function ringsFromDoc(v: unknown): Ring[] {
  if (!Array.isArray(v)) return [];
  return v.flatMap((x) => {
    const p = obj(x).p;
    if (!Array.isArray(p)) return [];
    const ring: Ring = [];
    for (let i = 0; i + 1 < p.length; i += 2) {
      if (typeof p[i] === "number" && typeof p[i + 1] === "number") ring.push([p[i] as number, p[i + 1] as number]);
    }
    return ring.length >= 4 ? [ring] : [];
  });
}

/** The index of every active area that has a shape. */
export function buildIndex(areas: Array<{ id: string; governorate: string; bbox: BBox | null; active: boolean; rings: Ring[] }>): IndexEntry[] {
  return areas
    .filter((a) => a.active && a.bbox && a.rings.length > 0)
    .map((a) => ({ id: a.id, governorate: a.governorate, bbox: a.bbox as BBox }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

/**
 * School counts per area and district after an import: the final area of
 * every active school ([finalOf] gives the school's area and district).
 */
export function countSchools(schools: Array<{ areaId: string | null; districtId: string | null }>): {
  areas: Map<string, number>;
  districts: Map<string, number>;
} {
  const areas = new Map<string, number>();
  const districts = new Map<string, number>();
  for (const s of schools) {
    if (s.areaId) areas.set(s.areaId, (areas.get(s.areaId) ?? 0) + 1);
    if (s.districtId) districts.set(s.districtId, (districts.get(s.districtId) ?? 0) + 1);
  }
  return { areas, districts };
}

/** Names sorted Arabic first (the app's lists). */
export function sortPlaces<T extends { nameAr: string }>(items: T[]): T[] {
  return [...items].sort((a, b) => a.nameAr.localeCompare(b.nameAr, "ar"));
}

/** Matching key of a place name ("قسم"/"مركز"/"حي" ignored), as the importer does. */
export function placeKey(text: string): string {
  const skip = new Set(["قسم", "مركز", "حي", "مدينه", "district", "markaz", "qism", "kism", "city", "new"]);
  return normalizeText(text)
    .split(" ")
    .filter((t) => t && !skip.has(t))
    .join(" ");
}
