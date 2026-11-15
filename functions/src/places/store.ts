import { GeoPoint, type DocumentData, type DocumentSnapshot, type Firestore, type QueryDocumentSnapshot } from "firebase-admin/firestore";
import {
  PLACE_AREAS,
  PLACE_DISTRICTS,
  PLACE_INDEX,
  PLACE_INDEX_AREAS,
  candidates,
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

export function areaFromDoc(id: string, d: DocumentData): PlaceArea {
  return {
    id,
    governorate: str(d.governorate),
    nameAr: str(d.nameAr),
    nameEn: str(d.nameEn),
    level: num(d.level),
    source: str(d.source) || "osm",
    centre: latLng(d.centre),
    bbox: bbox(d.bbox),
    rings: ringsFromDoc(d.rings),
    schoolCount: num(d.schoolCount),
    addressCount: num(d.addressCount),
    active: d.active !== false,
    mergedInto: typeof d.mergedInto === "string" ? d.mergedInto : null,
    adminEdited: d.adminEdited === true,
  };
}

export function districtFromDoc(id: string, d: DocumentData): PlaceDistrict {
  return {
    id,
    areaId: str(d.areaId),
    governorate: str(d.governorate),
    nameAr: str(d.nameAr),
    nameEn: str(d.nameEn),
    source: str(d.source) || "osm",
    centre: latLng(d.centre),
    bbox: bbox(d.bbox),
    rings: ringsFromDoc(d.rings),
    schoolCount: num(d.schoolCount),
    addressCount: num(d.addressCount),
    active: d.active !== false,
    mergedInto: typeof d.mergedInto === "string" ? d.mergedInto : null,
    adminEdited: d.adminEdited === true,
  };
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
 * districts. A cold project without places answers "no area".
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
    const snaps = await this.db.getAll(...ids.map((id) => this.db.collection(PLACE_AREAS).doc(id)));
    const areas: PlaceArea[] = snaps
      .filter((s: DocumentSnapshot) => s.exists)
      .map((s: DocumentSnapshot) => areaFromDoc(s.id, s.data() ?? {}));
    const hit = locate(p, areas, []);
    if (!hit.areaId) return hit;
    const districts = await this.db.collection(PLACE_DISTRICTS).where("areaId", "==", hit.areaId).limit(500).get();
    return locate(
      p,
      areas,
      districts.docs.map((d: QueryDocumentSnapshot) => districtFromDoc(d.id, d.data())),
    );
  }

  async area(id: string): Promise<PlaceArea | null> {
    const snap = await this.db.collection(PLACE_AREAS).doc(id).get();
    return snap.exists ? areaFromDoc(id, snap.data() ?? {}) : null;
  }

  async district(id: string): Promise<PlaceDistrict | null> {
    const snap = await this.db.collection(PLACE_DISTRICTS).doc(id).get();
    return snap.exists ? districtFromDoc(id, snap.data() ?? {}) : null;
  }

  /** Tests and the loader: forget the cached index. */
  static forget(): void {
    FirestorePlaceLocator.index = null;
  }
}
