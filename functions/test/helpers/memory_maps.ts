import { takeFromWindow, type MapLimitKind, type WindowCounter } from "../../src/maps/limits";
import type {
  AccountInfo,
  HomeRecord,
  MapStore,
  NewParentEvent,
  PublicLocation,
  SchoolInfo,
} from "../../src/maps/parent_map";
import type { PlaceCache, PlaceDetails } from "../../src/maps/places";

/** In-memory MapStore for unit tests. Records every public write. */
export class MemoryMapStore implements MapStore {
  accounts = new Map<string, AccountInfo>();
  children = new Map<string, string[]>();
  schoolList = new Map<string, SchoolInfo>();
  homes = new Map<string, HomeRecord>();
  publics = new Map<string, PublicLocation>();
  events = new Map<string, NewParentEvent>();
  limits = new Map<string, WindowCounter>();
  /** Every public record ever written (to check none held an exact point). */
  publicWrites: PublicLocation[] = [];
  nearbyQueries: Array<{ schoolId: string; prefix: string }> = [];

  async account(uid: string): Promise<AccountInfo | null> {
    return this.accounts.get(uid) ?? null;
  }

  async childSchoolIds(uid: string): Promise<string[]> {
    return [...new Set(this.children.get(uid) ?? [])];
  }

  async schools(ids: string[]): Promise<SchoolInfo[]> {
    return ids.map((id) => this.schoolList.get(id)).filter((s): s is SchoolInfo => s !== undefined);
  }

  async home(uid: string): Promise<HomeRecord | null> {
    const h = this.homes.get(uid);
    return h ? structuredClone(h) : null;
  }

  async saveHome(uid: string, home: HomeRecord): Promise<void> {
    this.homes.set(uid, structuredClone(home));
  }

  async publicLocation(uid: string): Promise<PublicLocation | null> {
    const p = this.publics.get(uid);
    return p ? structuredClone(p) : null;
  }

  async savePublicLocation(uid: string, doc: PublicLocation | null): Promise<void> {
    if (doc) {
      this.publics.set(uid, structuredClone(doc));
      this.publicWrites.push(structuredClone(doc));
    } else {
      this.publics.delete(uid);
    }
  }

  async takeLimit(uid: string, kind: MapLimitKind, nowMs: number, rule: { windowMs: number; max: number }) {
    const key = `${uid}:${kind}`;
    const result = takeFromWindow(this.limits.get(key), nowMs, rule);
    if (result.allowed) this.limits.set(key, result.next);
    return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
  }

  async nearby(schoolId: string, prefix: string, limit: number) {
    this.nearbyQueries.push({ schoolId, prefix });
    // Same filters as the Firestore query.
    return [...this.publics.entries()]
      .filter(([, d]) => d.schoolIds.includes(schoolId) && d.showOnMap && d.verified && d.geohash.startsWith(prefix))
      .sort(([, a], [, b]) => a.geohash.localeCompare(b.geohash))
      .slice(0, limit)
      .map(([uid, doc]) => ({ uid, doc: structuredClone(doc) }));
  }

  async createNewParentEvent(event: NewParentEvent): Promise<boolean> {
    if (this.events.has(event.uid)) return false;
    this.events.set(event.uid, structuredClone(event));
    return true;
  }
}

export class MemoryPlaceCache implements PlaceCache {
  entries = new Map<string, { details: PlaceDetails; expiresAtMs: number }>();

  async get(key: string, nowMs: number): Promise<PlaceDetails | null> {
    const e = this.entries.get(key);
    return e && e.expiresAtMs > nowMs ? e.details : null;
  }

  async put(key: string, details: PlaceDetails, expiresAtMs: number): Promise<void> {
    this.entries.set(key, { details, expiresAtMs });
  }
}
