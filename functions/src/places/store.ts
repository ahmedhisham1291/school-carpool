import { GeoPoint, type DocumentData, type DocumentSnapshot, type Firestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import {
  PLACE_AREAS,
  PLACE_DISTRICTS,
  PLACE_INDEX,
  PLACE_INDEX_AREAS,
  PLACE_INTERNAL,
  INTERNAL_FIELDS,
  candidates,
  internalId,
  locate,
  ringsFromDoc,
  type BBox,
  type IndexEntry,
  type LatLng,
  type Located,
  type PlaceArea,
  type PlaceDistrict,
} from "./catalog";

/** Firestore reads of the place hierarchy (catalog.ts has the shapes). */

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function latLng(v: unknown): LatLng | null {
  const p = v as { latitude?: unknown; longitude?: unknown } | null | undefined;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
}

function bbox(v: unknown): BBox | null {
  const o = (v ?? {}) as Record<string, unknown>;
  return ["minLat", "minLng", "maxLat", "maxLng"].every((k) => typeof o[k] === "number") ? (o as unknown as BBox) : null;
}

/**
 * A place from its app document [d] and its server-only document [internal]
 * (placeInternal). A document loaded before the split still carries the
 * internal fields itself: they are used when [internal] lacks them.
 */
function internalOf(d: DocumentData, internal: DocumentData | undefined): DocumentData {
  const out: DocumentData = {};
  for (const k of INTERNAL_FIELDS) out[k] = internal && internal[k] !== undefined ? internal[k] : d[k];
  return out;
}

export function areaFromDoc(id: string, d: DocumentData, internal?: DocumentData): PlaceArea {
  const i = internalOf(d, internal);
  return {
    id,
    governorate: str(d.governorate),
    nameAr: str(d.nameAr),
    nameEn: str(d.nameEn),
    level: num(i.level),
    source: str(i.source) || "osm",
    centre: latLng(d.centre),
    bbox: bbox(i.bbox),
    rings: ringsFromDoc(i.rings),
    schoolCount: num(d.schoolCount),
    addressCount: num(i.addressCount),
    active: d.active !== false,
    mergedInto: typeof d.mergedInto === "string" ? d.mergedInto : null,
    adminEdited: i.adminEdited === true,
  };
}

export function districtFromDoc(id: string, d: DocumentData, internal?: DocumentData): PlaceDistrict {
  const i = internalOf(d, internal);
  return {
    id,
    areaId: str(d.areaId),
    governorate: str(d.governorate),
    nameAr: str(d.nameAr),
    nameEn: str(d.nameEn),
    source: str(i.source) || "osm",
    centre: latLng(d.centre),
    bbox: bbox(i.bbox),
    rings: ringsFromDoc(i.rings),
    schoolCount: num(d.schoolCount),
    addressCount: num(i.addressCount),
    active: d.active !== false,
    mergedInto: typeof d.mergedInto === "string" ? d.mergedInto : null,
    adminEdited: i.adminEdited === true,
  };
}

/** The app's document and the server-only document of each place, in one read. */
export async function readPlaces(
  db: Firestore,
  kind: "area" | "district",
  ids: string[],
): Promise<Array<{ id: string; data: DocumentData; internal: DocumentData | undefined }>> {
  if (ids.length === 0) return [];
  const col = db.collection(kind === "area" ? PLACE_AREAS : PLACE_DISTRICTS);
  const snaps = await db.getAll(
    ...ids.map((id) => col.doc(id)),
    ...ids.map((id) => db.collection(PLACE_INTERNAL).doc(internalId(kind, id))),
  );
  const out: Array<{ id: string; data: DocumentData; internal: DocumentData | undefined }> = [];
  ids.forEach((id, n) => {
    const pub = snaps[n];
    const internal = snaps[ids.length + n];
    if (pub.exists) out.push({ id, data: pub.data() ?? {}, internal: internal.exists ? internal.data() : undefined });
  });
  return out;
}

/** Areas (or districts) read with their server-only documents. */
export async function areasWithInternal(db: Firestore, docs: QueryDocumentSnapshot[]): Promise<PlaceArea[]> {
  const internal = await readInternal(db, "area", docs.map((d) => d.id));
  return docs.map((d) => areaFromDoc(d.id, d.data(), internal.get(d.id)));
}

export async function districtsWithInternal(db: Firestore, docs: QueryDocumentSnapshot[]): Promise<PlaceDistrict[]> {
  const internal = await readInternal(db, "district", docs.map((d) => d.id));
  return docs.map((d) => districtFromDoc(d.id, d.data(), internal.get(d.id)));
}

async function readInternal(db: Firestore, kind: "area" | "district", ids: string[]): Promise<Map<string, DocumentData>> {
  const out = new Map<string, DocumentData>();
  if (ids.length === 0) return out;
  const snaps = await db.getAll(...ids.map((id) => db.collection(PLACE_INTERNAL).doc(internalId(kind, id))));
  snaps.forEach((snap: DocumentSnapshot, n: number) => {
    if (snap.exists) out.set(ids[n], snap.data() ?? {});
  });
  return out;
}

export function geoPoint(p: LatLng | null): GeoPoint | null {
  return p ? new GeoPoint(p.lat, p.lng) : null;
}

/** The place fields a school or an address stores for [p] ({} when it is in no area). */
export async function placeOfPoint(
  locator: PlaceLocator,
  p: LatLng,
): Promise<{ placeAreaId?: string; placeAreaNameAr?: string; placeAreaNameEn?: string; placeDistrictId?: string | null }> {
  const hit = await locator.locate(p);
  if (!hit.areaId) return {};
  const area = await locator.area(hit.areaId);
  if (!area) return {};
  return { placeAreaId: area.id, placeAreaNameAr: area.nameAr, placeAreaNameEn: area.nameEn, placeDistrictId: hit.districtId };
}

/** Where a point is. Used by placeForPoint, setHomeAddress and the "Other" school. */
export interface PlaceLocator {
  locate(p: LatLng): Promise<Located>;
  area(id: string): Promise<PlaceArea | null>;
  district(id: string): Promise<PlaceDistrict | null>;
}

/**
 * Reads placeIndex/areas once per instance for INDEX_TTL_MS (one document
 * read), then only the 1 to 3 areas whose box holds the point and their
 * districts, each with its server-only document (outline). A cold project
 * without places answers "no area".
 */
export class FirestorePlaceLocator implements PlaceLocator {
  private static index: { entries: IndexEntry[]; at: number } | null = null;
  static readonly INDEX_TTL_MS = 10 * 60 * 1000;

  constructor(
    private readonly db: Firestore,
    private readonly now: () => number = Date.now,
  ) {}

  private async loadIndex(): Promise<IndexEntry[]> {
    const cached = FirestorePlaceLocator.index;
    if (cached && this.now() - cached.at < FirestorePlaceLocator.INDEX_TTL_MS) return cached.entries;
    const snap = await this.db.collection(PLACE_INDEX).doc(PLACE_INDEX_AREAS).get();
    const raw = snap.exists ? (snap.get("areas") as unknown) : [];
    const entries: IndexEntry[] = Array.isArray(raw)
      ? raw.flatMap((e: unknown) => {
          const o = (e ?? {}) as Record<string, unknown>;
          const b = bbox(o.bbox);
          return typeof o.id === "string" && b ? [{ id: o.id, governorate: str(o.governorate), bbox: b }] : [];
        })
      : [];
    FirestorePlaceLocator.index = { entries, at: this.now() };
    return entries;
  }

  async locate(p: LatLng): Promise<Located> {
    const ids = candidates(await this.loadIndex(), p).slice(0, 10);
    if (ids.length === 0) return { governorate: null, areaId: null, districtId: null };
    const areas: PlaceArea[] = (await readPlaces(this.db, "area", ids)).map((r) => areaFromDoc(r.id, r.data, r.internal));
    const hit = locate(p, areas, []);
    if (!hit.areaId) return hit;
    const districts = await this.db.collection(PLACE_DISTRICTS).where("areaId", "==", hit.areaId).limit(500).get();
    return locate(p, areas, await districtsWithInternal(this.db, districts.docs));
  }

  async area(id: string): Promise<PlaceArea | null> {
    const [r] = await readPlaces(this.db, "area", [id]);
    return r ? areaFromDoc(r.id, r.data, r.internal) : null;
  }

  async district(id: string): Promise<PlaceDistrict | null> {
    const [r] = await readPlaces(this.db, "district", [id]);
    return r ? districtFromDoc(r.id, r.data, r.internal) : null;
  }

  /** Tests and the loader: forget the cached index. */
  static forget(): void {
    FirestorePlaceLocator.index = null;
  }
}
