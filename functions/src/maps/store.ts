import { GeoPoint, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import { SCHOOLS } from "../admin_panel/store";
import { CHILDREN } from "../verification/store";
import { DEFAULT_RADIUS_KM, type LatLng } from "./geo";
import { takeFromWindow, type MapLimitKind, type WindowCounter } from "./limits";
import type { AccountInfo, HomeRecord, MapStore, NewParentEvent, PublicLocation, SchoolInfo, SchoolRef } from "./parent_map";
import type { PlaceCache, PlaceDetails } from "./places";

export const HOMES = "homes";
export const PARENT_LOCATIONS = "parentLocations";
export const NEW_PARENT_EVENTS = "newParentEvents";
export const MAP_LIMITS = "mapLimits";
export const PLACE_CACHE = "placeCache";

function point(value: unknown): LatLng | null {
  const p = value as { latitude?: unknown; longitude?: unknown } | null | undefined;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function millis(value: unknown): number {
  const t = value as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
}

function schoolRefs(value: unknown): SchoolRef[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((v) => (typeof v === "object" && v !== null ? (v as Record<string, unknown>) : {}))
    .filter((v) => typeof v.id === "string")
    .map((v) => ({ id: v.id as string, nameAr: text(v.nameAr), nameEn: text(v.nameEn) }));
}

export function homeFromDoc(d: DocumentData): HomeRecord {
  return {
    location: point(d.location),
    label: text(d.label),
    showOnMap: d.showOnMap !== false,
    notifyNewParents: d.notifyNewParents !== false,
    radiusKm: typeof d.radiusKm === "number" ? d.radiusKm : DEFAULT_RADIUS_KM,
    drivingSchools: schoolRefs(d.drivingSchools),
    updatedAtMs: millis(d.updatedAt),
  };
}

export function publicFromDoc(d: DocumentData): PublicLocation | null {
  const p = point(d.point);
  if (!p) return null;
  return {
    point: p,
    geohash: text(d.geohash),
    firstName: text(d.firstName),
    verified: d.verified === true,
    showOnMap: d.showOnMap === true,
    notifyNewParents: d.notifyNewParents === true,
    radiusKm: typeof d.radiusKm === "number" ? d.radiusKm : DEFAULT_RADIUS_KM,
    schoolIds: strings(d.schoolIds),
    childSchoolIds: strings(d.childSchoolIds),
    drivingSchoolIds: strings(d.drivingSchoolIds),
    announced: d.announced === true,
    updatedAtMs: millis(d.updatedAt),
  };
}

export class FirestoreMapStore implements MapStore {
  constructor(private readonly db: Firestore) {}

  async account(uid: string): Promise<AccountInfo | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    const status = d.banned === true ? "suspended" : text(d.status);
    return { status, firstName: text(d.firstName) };
  }

  async childSchoolIds(uid: string): Promise<string[]> {
    const snap = await this.db.collection(CHILDREN).where("ownerUid", "==", uid).get();
    const ids = snap.docs
      .filter((doc) => doc.get("status") === "approved")
      .map((doc) => doc.get("schoolId"))
      .filter((id): id is string => typeof id === "string" && id.length > 0);
    return [...new Set(ids)];
  }

  async schools(ids: string[]): Promise<SchoolInfo[]> {
    if (ids.length === 0) return [];
    const snaps = await this.db.getAll(...ids.map((id) => this.db.collection(SCHOOLS).doc(id)));
    return snaps
      .filter((s) => s.exists)
      .map((s) => {
        const d = s.data() ?? {};
        return { id: s.id, nameAr: text(d.nameAr), nameEn: text(d.nameEn), status: text(d.status) };
      });
  }

  async home(uid: string): Promise<HomeRecord | null> {
    const snap = await this.db.collection(HOMES).doc(uid).get();
    return snap.exists ? homeFromDoc(snap.data() ?? {}) : null;
  }

  async saveHome(uid: string, home: HomeRecord): Promise<void> {
    await this.db.collection(HOMES).doc(uid).set({
      location: home.location ? new GeoPoint(home.location.lat, home.location.lng) : null,
      label: home.label,
      showOnMap: home.showOnMap,
      notifyNewParents: home.notifyNewParents,
      radiusKm: home.radiusKm,
      drivingSchools: home.drivingSchools.map((s) => ({ id: s.id, nameAr: s.nameAr, nameEn: s.nameEn })),
      updatedAt: Timestamp.fromMillis(home.updatedAtMs),
    });
  }

  async publicLocation(uid: string): Promise<PublicLocation | null> {
    const snap = await this.db.collection(PARENT_LOCATIONS).doc(uid).get();
    return snap.exists ? publicFromDoc(snap.data() ?? {}) : null;
  }

  async savePublicLocation(uid: string, doc: PublicLocation | null): Promise<void> {
    const ref = this.db.collection(PARENT_LOCATIONS).doc(uid);
    if (!doc) {
      await ref.delete();
      return;
    }
    await ref.set({
      point: new GeoPoint(doc.point.lat, doc.point.lng),
      geohash: doc.geohash,
      firstName: doc.firstName,
      verified: doc.verified,
      showOnMap: doc.showOnMap,
      notifyNewParents: doc.notifyNewParents,
      radiusKm: doc.radiusKm,
      schoolIds: doc.schoolIds,
      childSchoolIds: doc.childSchoolIds,
      drivingSchoolIds: doc.drivingSchoolIds,
      announced: doc.announced,
      updatedAt: Timestamp.fromMillis(doc.updatedAtMs),
    });
  }

  async takeLimit(
    uid: string,
    kind: MapLimitKind,
    nowMs: number,
    rule: { windowMs: number; max: number },
  ): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(MAP_LIMITS).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const raw = (snap.exists ? snap.get(kind) : undefined) as { windowStartMs?: unknown; count?: unknown } | undefined;
      const current: WindowCounter | undefined =
        raw && typeof raw.windowStartMs === "number" && typeof raw.count === "number"
          ? { windowStartMs: raw.windowStartMs, count: raw.count }
          : undefined;
      const result = takeFromWindow(current, nowMs, rule);
      if (result.allowed) tx.set(ref, { ...(snap.exists ? snap.data() : {}), [kind]: result.next });
      return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
    });
  }

  async nearby(schoolId: string, prefix: string, limit: number): Promise<Array<{ uid: string; doc: PublicLocation }>> {
    // Index: firestore.indexes.json (schoolIds CONTAINS, showOnMap, verified, geohash).
    const snap = await this.db
      .collection(PARENT_LOCATIONS)
      .where("schoolIds", "array-contains", schoolId)
      .where("showOnMap", "==", true)
      .where("verified", "==", true)
      .where("geohash", ">=", prefix)
      .where("geohash", "<=", `${prefix}~`)
      .limit(limit)
      .get();
    const out: Array<{ uid: string; doc: PublicLocation }> = [];
    for (const d of snap.docs) {
      const doc = publicFromDoc(d.data());
      if (doc) out.push({ uid: d.id, doc });
    }
    return out;
  }

  async createNewParentEvent(event: NewParentEvent): Promise<boolean> {
    try {
      await this.db.collection(NEW_PARENT_EVENTS).doc(event.uid).create({
        uid: event.uid,
        firstName: event.firstName,
        schoolIds: event.schoolIds,
        point: new GeoPoint(event.point.lat, event.point.lng),
        geohash: event.geohash,
        status: event.status,
        createdAt: Timestamp.fromMillis(event.createdAtMs),
      });
      return true;
    } catch (error) {
      const code = (error as { code?: unknown }).code;
      if (code === 6 || code === "already-exists") return false;
      throw error;
    }
  }
}

export class FirestorePlaceCache implements PlaceCache {
  constructor(private readonly db: Firestore) {}

  async get(key: string, nowMs: number): Promise<PlaceDetails | null> {
    const snap = await this.db.collection(PLACE_CACHE).doc(key).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    const location = point(d.location);
    if (!location || millis(d.expiresAt) <= nowMs) return null;
    return { placeId: text(d.placeId), label: text(d.label), location };
  }

  async put(key: string, details: PlaceDetails, expiresAtMs: number): Promise<void> {
    // expiresAt doubles as the Firestore TTL field (SETUP.md section 15).
    await this.db.collection(PLACE_CACHE).doc(key).set({
      placeId: details.placeId,
      label: details.label,
      location: new GeoPoint(details.location.lat, details.location.lng),
      expiresAt: Timestamp.fromMillis(expiresAtMs),
    });
  }
}
