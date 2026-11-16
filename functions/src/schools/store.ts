import {
  FieldValue,
  GeoPoint,
  Timestamp,
  type DocumentData,
  type Firestore,
} from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import { SCHOOLS } from "../admin_panel/store";
import { schoolSearchGrams } from "../admin_panel/school_search";
import { searchKeysFor, type ExistingSchool, type ImportedSchool } from "./catalog";
import type { OtherSchoolsStore, PendingSchool } from "./other";
import { readAll } from "./paged";

function point(value: unknown): { lat: number; lng: number } | null {
  const p = value as { latitude?: unknown; longitude?: unknown } | null | undefined;
  return p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

export class FirestoreOtherSchoolsStore implements OtherSchoolsStore {
  constructor(private readonly db: Firestore) {}

  newId(): string {
    return this.db.collection(SCHOOLS).doc().id;
  }

  async accountState(uid: string): Promise<"missing" | "suspended" | "ok"> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return "missing";
    const data = snap.data() ?? {};
    return data.status === "suspended" || data.banned === true ? "suspended" : "ok";
  }

  async pendingOf(uid: string, limit: number): Promise<PendingSchool[]> {
    const snap = await this.db
      .collection(SCHOOLS)
      .where("addedBy", "==", uid)
      .where("status", "==", "awaiting_review")
      .limit(limit)
      .get();
    return snap.docs.map((doc) => {
      const d = doc.data();
      const created = d.createdAt as { toMillis?: () => number } | undefined;
      return {
        id: doc.id,
        nameAr: text(d.nameAr),
        nameEn: text(d.nameEn),
        governorate: text(d.governorate),
        location: point(d.location),
        addedBy: uid,
        createdAtMs: typeof created?.toMillis === "function" ? created.toMillis() : 0,
      };
    });
  }

  async create(school: PendingSchool): Promise<void> {
    await this.db.collection(SCHOOLS).doc(school.id).create({
      nameAr: school.nameAr,
      nameEn: school.nameEn,
      searchKeys: searchKeysFor(school.nameAr, school.nameEn),
      adminSearchGrams: schoolSearchGrams(school.nameAr, school.nameEn),
      kind: "school",
      governorate: school.governorate,
      city: "",
      cityAr: "",
      location: school.location ? new GeoPoint(school.location.lat, school.location.lng) : null,
      status: "awaiting_review",
      source: "parent",
      sourceId: school.id,
      sourceKeys: [],
      placeAreaId: school.placeAreaId ?? "",
      placeAreaNameAr: school.placeAreaNameAr ?? "",
      placeAreaNameEn: school.placeAreaNameEn ?? "",
      placeDistrictId: school.placeDistrictId ?? null,
      addedBy: school.addedBy,
      mergedInto: null,
      createdAt: Timestamp.fromMillis(school.createdAtMs),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }
}

/** The fields readExistingSchools asks for (no grams, no timestamps). */
export const EXISTING_SCHOOL_FIELDS = [
  "status", "adminEdited", "sourceKeys", "nameAr", "nameEn", "kind", "governorate", "city", "cityAr", "location",
  "searchHidden", "placeAreaId", "placeAreaNameAr", "placeAreaNameEn", "placeDistrictId", "source", "hiddenReason",
] as const;

/**
 * Every school, as the import loader needs it: one read per school (about
 * 20,000 to 30,000 reads per run on staging, inside the free 50,000 a day),
 * read in pages of 1,000 with only the fields above, each page retried (a
 * single large answer ran into Firestore's 300 s deadline, 16 Nov 2026).
 */
export async function readExistingSchools(db: Firestore, pageSize = 1000): Promise<ExistingSchool[]> {
  const docs = await readAll(db, SCHOOLS, { pageSize, select: EXISTING_SCHOOL_FIELDS });
  return docs.map((doc) => existingSchoolFrom(doc.id, doc.data()));
}

export function existingSchoolFrom(id: string, d: DocumentData): ExistingSchool {
  return {
    id,
    status: text(d.status) || "active",
    adminEdited: d.adminEdited === true,
    sourceKeys: Array.isArray(d.sourceKeys) ? d.sourceKeys.filter((k: unknown): k is string => typeof k === "string") : [],
    nameAr: text(d.nameAr),
    nameEn: text(d.nameEn),
    kind: text(d.kind) || "school",
    governorate: text(d.governorate),
    city: text(d.city),
    cityAr: text(d.cityAr),
    location: point(d.location),
    searchHidden: d.searchHidden === true,
    placeAreaId: text(d.placeAreaId),
    placeAreaNameAr: text(d.placeAreaNameAr),
    placeAreaNameEn: text(d.placeAreaNameEn),
    placeDistrictId: typeof d.placeDistrictId === "string" ? d.placeDistrictId : null,
    source: text(d.source),
    hiddenReason: text(d.hiddenReason),
  };
}

/** Fields the import writes. The status is set only when the school is created. */
export function importedFields(school: ImportedSchool, importedAt: Timestamp): DocumentData {
  return {
    nameAr: school.nameAr,
    nameEn: school.nameEn,
    searchKeys: searchKeysFor(school.nameAr, school.nameEn),
    adminSearchGrams: schoolSearchGrams(school.nameAr, school.nameEn),
    kind: school.kind,
    governorate: school.governorate,
    city: school.city,
    cityAr: school.cityAr,
    location: school.location ? new GeoPoint(school.location.lat, school.location.lng) : null,
    sourceKeys: school.sourceKeys,
    placeAreaId: school.placeAreaId ?? "",
    placeAreaNameAr: school.placeAreaNameAr ?? "",
    placeAreaNameEn: school.placeAreaNameEn ?? "",
    placeDistrictId: school.placeDistrictId ?? null,
    importedAt,
    updatedAt: FieldValue.serverTimestamp(),
  };
}

export function newImportedDoc(school: ImportedSchool, importedAt: Timestamp): DocumentData {
  return {
    ...importedFields(school, importedAt),
    status: "active",
    source: school.source,
    sourceId: school.sourceId,
    addedBy: null,
    mergedInto: null,
    createdAt: importedAt,
  };
}
