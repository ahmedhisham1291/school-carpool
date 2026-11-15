import { GeoPoint, type DocumentData, type Firestore, type Query } from "firebase-admin/firestore";
import { errorCode } from "../auth/accounts";
import { PLACE_DISTRICTS } from "../places/catalog";
import {
  MissingIndexError,
  type SchoolRow,
  type SchoolSearchStore,
  type ServerFilters,
  type SortField,
} from "./school_search";
import { ADMIN_LIMITS, AUDIT_LOG, auditDoc, SCHOOLS } from "./store";
import type { AuditEntry, SchoolStatus } from "./types";

/** The field adminSearchSchools matches on (school_search.ts schoolSearchGrams). */
export const ADMIN_SEARCH_GRAMS = "adminSearchGrams";

/** Fields a list row needs: nothing else is read over the wire. */
const ROW_FIELDS = [
  "nameAr",
  "nameEn",
  "governorate",
  "city",
  "location",
  "status",
  "source",
  "searchHidden",
  "placeAreaId",
  "placeAreaNameAr",
  "placeAreaNameEn",
  "placeDistrictId",
];

function textOf(value: unknown): string {
  return typeof value === "string" ? value : "";
}

export function rowFromDoc(id: string, d: DocumentData): SchoolRow {
  const s = d.status;
  const loc = d.location;
  return {
    id,
    nameAr: textOf(d.nameAr),
    nameEn: textOf(d.nameEn),
    governorate: textOf(d.governorate),
    city: textOf(d.city),
    location: loc instanceof GeoPoint ? { lat: loc.latitude, lng: loc.longitude } : null,
    status: s === "awaiting_review" || s === "merged" ? (s as SchoolStatus) : "active",
    source: textOf(d.source) || "admin",
    searchHidden: d.searchHidden === true,
    placeAreaId: textOf(d.placeAreaId),
    placeAreaNameAr: textOf(d.placeAreaNameAr),
    placeAreaNameEn: textOf(d.placeAreaNameEn),
    placeDistrictId: typeof d.placeDistrictId === "string" && d.placeDistrictId ? d.placeDistrictId : null,
  };
}

/** FAILED_PRECONDITION: "The query requires an index". */
function isMissingIndex(error: unknown): boolean {
  const code = errorCode(error);
  return code === "9" || code === "failed-precondition" || code === "FAILED_PRECONDITION";
}

export class FirestoreSchoolSearchStore implements SchoolSearchStore {
  constructor(private readonly db: Firestore) {}

  private filtered(f: ServerFilters): Query {
    let q: Query = this.db.collection(SCHOOLS);
    if (f.status) q = q.where("status", "==", f.status);
    if (f.governorate) q = q.where("governorate", "==", f.governorate);
    if (f.placeAreaId) q = q.where("placeAreaId", "==", f.placeAreaId);
    if (f.placeDistrictId) q = q.where("placeDistrictId", "==", f.placeDistrictId);
    if (f.source) q = q.where("source", "==", f.source);
    if (f.hiddenOnly) q = q.where("searchHidden", "==", true);
    if (f.anyGrams && f.anyGrams.length > 0) q = q.where(ADMIN_SEARCH_GRAMS, "array-contains-any", f.anyGrams);
    return q;
  }

  async scan(filters: ServerFilters, sort: SortField, afterId: string | null, limit: number): Promise<SchoolRow[]> {
    let q = this.filtered(filters).orderBy(sort).select(...ROW_FIELDS);
    try {
      if (afterId) {
        // Cursor: the name and ID of the last school read (one read).
        const last = await this.db.collection(SCHOOLS).doc(afterId).get();
        if (last.exists) q = q.startAfter(last);
      }
      const snap = await q.limit(limit).get();
      return snap.docs.map((doc) => rowFromDoc(doc.id, doc.data()));
    } catch (error) {
      if (isMissingIndex(error)) throw new MissingIndexError();
      throw error;
    }
  }

  async count(filters: ServerFilters): Promise<number> {
    try {
      const snap = await this.filtered(filters).count().get();
      return snap.data().count;
    } catch (error) {
      if (isMissingIndex(error)) throw new MissingIndexError();
      throw error;
    }
  }

  async districtNames(ids: string[]): Promise<Map<string, { nameAr: string; nameEn: string }>> {
    const snaps = await this.db.getAll(...ids.map((id) => this.db.collection(PLACE_DISTRICTS).doc(id)));
    const names = new Map<string, { nameAr: string; nameEn: string }>();
    for (const snap of snaps) {
      if (snap.exists) names.set(snap.id, { nameAr: textOf(snap.get("nameAr")), nameEn: textOf(snap.get("nameEn")) });
    }
    return names;
  }

  /** Same window counter as the user search, in its own document. */
  consumeQuota(adminUid: string, nowMs: number, limit: number, windowMs: number): Promise<boolean> {
    const ref = this.db.collection(ADMIN_LIMITS).doc(`schools_${adminUid}`);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const start = typeof snap.get("windowStartMs") === "number" ? (snap.get("windowStartMs") as number) : 0;
      const count = typeof snap.get("count") === "number" ? (snap.get("count") as number) : 0;
      if (nowMs - start >= windowMs) {
        tx.set(ref, { windowStartMs: nowMs, count: 1 });
        return true;
      }
      if (count >= limit) return false;
      tx.set(ref, { windowStartMs: start, count: count + 1 });
      return true;
    });
  }

  async audit(entry: AuditEntry): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create(auditDoc(entry));
  }
}
