import { GOVERNORATES } from "../admin_panel/schools";
import { normalizeText } from "../text/normalize";

/**
 * The schools list (F4): what the import tool produces
 * (tools/import_schools -> build/schools/schools.json), how a run is turned
 * into Firestore writes without ever creating a duplicate, and the record
 * the search index gets.
 *
 * Firestore, schools/{id}:
 *   nameAr, nameEn, searchKeys, kind (school | kindergarten), governorate,
 *   city, cityAr, location (GeoPoint or null), status (active |
 *   awaiting_review | merged), source (osm | list_<file> | admin | parent |
 *   seed), sourceId, sourceKeys ("osm:n123", every entry merged into it),
 *   addedBy (only while a parent's "Other" school awaits review),
 *   adminEdited (an admin changed it: the import leaves it alone),
 *   searchHidden (true: kept as a document, so anything pointing at it
 *   still works, but left out of search; set by the loader on the
 *   hand-written sample once a real list is loaded, planSampleHiding),
 *   mergedInto, createdAt, updatedAt, importedAt.
 */

export type SchoolKind = "school" | "kindergarten";

export interface ImportedSchool {
  id: string;
  source: string;
  sourceId: string;
  sourceKeys: string[];
  nameAr: string;
  nameEn: string;
  kind: SchoolKind;
  governorate: string;
  city: string;
  cityAr: string;
  location: { lat: number; lng: number } | null;
}

/** What the loader reads of a school already in Firestore. */
export interface ExistingSchool {
  id: string;
  status: string;
  adminEdited: boolean;
  sourceKeys: string[];
  nameAr: string;
  nameEn: string;
  kind: string;
  governorate: string;
  city: string;
  cityAr: string;
  location: { lat: number; lng: number } | null;
  /** Out of search (sample schools after a real load). */
  searchHidden?: boolean;
}

export type ImportSkipReason = "admin-edited" | "merged" | "not-active" | "same-target";

export interface ImportPlan {
  creates: ImportedSchool[];
  /** The incoming data, written to the existing document [id] (which may differ from incoming.id). */
  updates: Array<{ id: string; school: ImportedSchool }>;
  unchanged: number;
  skipped: Array<{ id: string; reason: ImportSkipReason }>;
  /** Imported before, not in this run (kept: children may point to them). */
  notInInput: string[];
}

const DOC_ID = /^[A-Za-z0-9_-]{1,64}$/;

/** Checks one school from schools.json; throws with the reason when it is not usable. */
export function parseImportedSchool(value: unknown): ImportedSchool {
  const raw = typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
  const str = (key: string, min: number, max: number): string => {
    const v = raw[key];
    if (typeof v !== "string" || v.trim().length < min || v.trim().length > max) {
      throw new Error(`bad ${key} in ${String(raw.id)}`);
    }
    return v.trim();
  };
  const id = str("id", 1, 64);
  if (!DOC_ID.test(id)) throw new Error(`bad id ${id}`);
  const governorate = str("governorate", 1, 40);
  if (!(GOVERNORATES as readonly string[]).includes(governorate)) throw new Error(`bad governorate in ${id}`);
  const kind = raw.kind === "kindergarten" ? "kindergarten" : "school";
  const keys = Array.isArray(raw.sourceKeys) ? raw.sourceKeys.filter((k): k is string => typeof k === "string") : [];
  const loc = raw.location as { lat?: unknown; lng?: unknown } | null | undefined;
  const location =
    loc && typeof loc.lat === "number" && typeof loc.lng === "number" && Number.isFinite(loc.lat) && Number.isFinite(loc.lng)
      ? { lat: loc.lat, lng: loc.lng }
      : null;
  return {
    id,
    source: str("source", 1, 80),
    sourceId: str("sourceId", 1, 120),
    sourceKeys: keys.length > 0 ? [...new Set(keys)].sort() : [`${raw.source}:${raw.sourceId}`],
    nameAr: str("nameAr", 2, 120),
    nameEn: str("nameEn", 2, 120),
    kind,
    governorate,
    city: typeof raw.city === "string" ? raw.city.trim().slice(0, 80) : "",
    cityAr: typeof raw.cityAr === "string" ? raw.cityAr.trim().slice(0, 80) : "",
    location,
  };
}

function sameLocation(a: ImportedSchool["location"], b: ImportedSchool["location"]): boolean {
  if (!a || !b) return a === b;
  return Math.abs(a.lat - b.lat) < 1e-6 && Math.abs(a.lng - b.lng) < 1e-6;
}

function unchanged(incoming: ImportedSchool, existing: ExistingSchool): boolean {
  return (
    incoming.nameAr === existing.nameAr &&
    incoming.nameEn === existing.nameEn &&
    incoming.kind === existing.kind &&
    incoming.governorate === existing.governorate &&
    incoming.city === existing.city &&
    incoming.cityAr === existing.cityAr &&
    sameLocation(incoming.location, existing.location) &&
    incoming.sourceKeys.every((k) => existing.sourceKeys.includes(k))
  );
}

/**
 * Turns one import run into writes. Idempotent: a school is found by its
 * ID or by any of its source keys (so a school whose "primary" entry
 * changes between runs keeps its document), unchanged schools are not
 * written at all, and running the same input twice plans no writes the
 * second time.
 *
 * Schools an admin edited, merged schools and parents' schools are never
 * touched. Nothing is deleted: a school missing from a run is reported.
 */
export function planImport(incoming: ImportedSchool[], existing: ExistingSchool[]): ImportPlan {
  const byId = new Map(existing.map((s) => [s.id, s]));
  const byKey = new Map<string, ExistingSchool>();
  for (const s of existing) for (const key of s.sourceKeys) if (!byKey.has(key)) byKey.set(key, s);

  const plan: ImportPlan = { creates: [], updates: [], unchanged: 0, skipped: [], notInInput: [] };
  const targets = new Set<string>();
  for (const school of incoming) {
    const match = byId.get(school.id) ?? school.sourceKeys.map((k) => byKey.get(k)).find((s) => s !== undefined);
    const targetId = match?.id ?? school.id;
    if (targets.has(targetId)) {
      plan.skipped.push({ id: school.id, reason: "same-target" });
      continue;
    }
    targets.add(targetId);
    if (!match) {
      plan.creates.push(school);
    } else if (match.status === "merged") {
      plan.skipped.push({ id: match.id, reason: "merged" });
    } else if (match.status !== "active") {
      plan.skipped.push({ id: match.id, reason: "not-active" });
    } else if (match.adminEdited) {
      plan.skipped.push({ id: match.id, reason: "admin-edited" });
    } else if (unchanged(school, match)) {
      plan.unchanged++;
    } else {
      plan.updates.push({
        id: match.id,
        school: { ...school, sourceKeys: [...new Set([...match.sourceKeys, ...school.sourceKeys])].sort() },
      });
    }
  }
  for (const s of existing) {
    if (s.sourceKeys.length > 0 && !targets.has(s.id)) plan.notInInput.push(s.id);
  }
  return plan;
}

/**
 * The hand-written sample schools (data/schools/sample) to take out of
 * search once a real list is loaded: active schools whose every source
 * key comes from the sample, that the real list does not also contain,
 * that no admin edited and that are not hidden already. They stay as
 * documents (a test child or carpool may point at one); only search stops
 * showing them. Parents' and admins' schools have no sample keys, so they
 * are never picked.
 */
export function planSampleHiding(existing: ExistingSchool[], sampleKeys: Iterable<string>, incoming: ImportedSchool[]): string[] {
  const sample = new Set(sampleKeys);
  const real = new Set(incoming.flatMap((s) => s.sourceKeys));
  const realIds = new Set(incoming.map((s) => s.id));
  return existing
    .filter(
      (s) =>
        s.status === "active" &&
        !s.adminEdited &&
        s.searchHidden !== true &&
        !realIds.has(s.id) &&
        s.sourceKeys.length > 0 &&
        s.sourceKeys.every((k) => sample.has(k) && !real.has(k)),
    )
    .map((s) => s.id)
    .sort();
}

/** Normalized names for matching (Arabic spelling, case, punctuation). */
export function searchKeysFor(nameAr: string, nameEn: string): string[] {
  return [...new Set([normalizeText(nameAr), normalizeText(nameEn)].filter((k) => k.length > 0))];
}

/**
 * The search index record: school names and places only, never anything
 * about a parent (spec section 7: Algolia holds school names and places).
 */
export interface SchoolSearchRecord {
  objectID: string;
  nameAr: string;
  nameEn: string;
  /** Normalized names: "مدرسه" finds "مدرسة", "الدوليه" finds "الدولية". */
  searchKeys: string[];
  kind: SchoolKind;
  governorate: string;
  city: string;
  cityAr: string;
  _geoloc?: { lat: number; lng: number };
}

/** Fields of schools/{id} the index needs (raw Firestore data). */
export function searchRecordFrom(id: string, data: Record<string, unknown> | undefined): SchoolSearchRecord | null {
  if (!data || data.status !== "active" || data.searchHidden === true) return null;
  const nameAr = typeof data.nameAr === "string" ? data.nameAr : "";
  const nameEn = typeof data.nameEn === "string" ? data.nameEn : "";
  if (!nameAr && !nameEn) return null;
  const record: SchoolSearchRecord = {
    objectID: id,
    nameAr,
    nameEn,
    searchKeys: searchKeysFor(nameAr, nameEn),
    kind: data.kind === "kindergarten" ? "kindergarten" : "school",
    governorate: typeof data.governorate === "string" ? data.governorate : "",
    city: typeof data.city === "string" ? data.city : "",
    cityAr: typeof data.cityAr === "string" ? data.cityAr : "",
  };
  const loc = data.location as { latitude?: unknown; longitude?: unknown } | null | undefined;
  if (loc && typeof loc.latitude === "number" && typeof loc.longitude === "number") {
    record._geoloc = { lat: loc.latitude, lng: loc.longitude };
  }
  return record;
}

/**
 * A full sync of the index from every schools/{id} document (the
 * schools:algolia "sync" command): active, not hidden schools are sent,
 * every other document's ID is removed (merged, awaiting review, hidden
 * sample). Works with the Write API key: no clear, no browse.
 */
export function planIndexSync(docs: Array<{ id: string; data: Record<string, unknown> | undefined }>): {
  records: SchoolSearchRecord[];
  remove: string[];
} {
  const records: SchoolSearchRecord[] = [];
  const remove: string[] = [];
  for (const { id, data } of docs) {
    const record = searchRecordFrom(id, data);
    if (record) records.push(record);
    else remove.push(id);
  }
  return { records, remove };
}

export type SyncAction = { kind: "upsert"; record: SchoolSearchRecord } | { kind: "delete" } | { kind: "none" };

/**
 * What a write to schools/{id} means for the index: active schools are in
 * it, every other status (awaiting review, merged) or a deleted document
 * is not. A write that changes nothing the index holds does nothing, so
 * re-imports and admin bookkeeping cost no index operations.
 */
export function syncAction(
  id: string,
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined,
): SyncAction {
  const was = searchRecordFrom(id, before);
  const now = searchRecordFrom(id, after);
  if (!now) return was ? { kind: "delete" } : { kind: "none" };
  if (was && JSON.stringify(was) === JSON.stringify(now)) return { kind: "none" };
  return { kind: "upsert", record: now };
}
