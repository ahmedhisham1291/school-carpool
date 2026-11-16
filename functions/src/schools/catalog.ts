import { GOVERNORATES } from "../admin_panel/schools";
import { normalizeText } from "../text/normalize";

/**
 * The schools list (F4): what the import tool produces
 * (tools/import_schools -> build/schools/schools.json), how a run is turned
 * into Firestore writes without ever creating a duplicate, and the record
 * the search index gets.
 *
 * Firestore, schools/{id}:
 *   nameAr, nameEn, searchKeys, kind (school | kindergarten | university), governorate,
 *   city, cityAr, location (GeoPoint or null), status (active |
 *   awaiting_review | merged), source (osm | list_<file> | admin | parent |
 *   seed), sourceId, sourceKeys ("osm:n123", every entry merged into it),
 *   addedBy (only while a parent's "Other" school awaits review),
 *   adminEdited (an admin changed it: the import leaves it alone),
 *   searchHidden (true: kept as a document, so anything pointing at it
 *   still works, but left out of search; set by the loader on the
 *   hand-written sample once a real list is loaded, planSampleHiding),
 *   mergedInto, createdAt, updatedAt, importedAt,
 *   placeAreaId, placeAreaNameAr, placeAreaNameEn, placeDistrictId (City ->
 *   Area -> District, places/catalog.ts; null/"" when unknown).
 */

/**
 * "university" only when the import's university switch is on
 * (data/schools/categories.json; OFF by owner decision, 16 Nov 2026).
 */
export type SchoolKind = "school" | "kindergarten" | "university";

/** Any stored or imported kind -> a SchoolKind ("school" when unknown). */
export function schoolKind(value: unknown): SchoolKind {
  return value === "kindergarten" || value === "university" ? value : "school";
}

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
  /** Area and district (tools/import_schools/places_import.py); "" / null when unknown. */
  placeAreaId?: string;
  placeAreaNameAr?: string;
  placeAreaNameEn?: string;
  placeDistrictId?: string | null;
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
  /** "parent" for a school a parent added; the import's source otherwise. */
  source?: string;
  /** Why the import took it out of the list (planDroppedHiding); "" when it did not. */
  hiddenReason?: string;
  /** For a merged school: the school it was merged into, and "import" when the import did it. */
  mergedInto?: string;
  mergedBy?: string;
  placeAreaId?: string;
  placeAreaNameAr?: string;
  placeAreaNameEn?: string;
  placeDistrictId?: string | null;
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
export function parseImportedSchool(value: unknown): MergedImport {
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
  const kind = schoolKind(raw.kind);
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
    placeAreaId: typeof raw.placeAreaId === "string" && DOC_ID.test(raw.placeAreaId) ? raw.placeAreaId : "",
    placeAreaNameAr: typeof raw.placeAreaNameAr === "string" ? raw.placeAreaNameAr.trim().slice(0, 80) : "",
    placeAreaNameEn: typeof raw.placeAreaNameEn === "string" ? raw.placeAreaNameEn.trim().slice(0, 80) : "",
    placeDistrictId: typeof raw.placeDistrictId === "string" && DOC_ID.test(raw.placeDistrictId) ? raw.placeDistrictId : null,
    ...(Array.isArray(raw.mergedFrom)
      ? { mergedFrom: raw.mergedFrom.filter((x): x is string => typeof x === "string" && DOC_ID.test(x)).slice(0, 200) }
      : {}),
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
    (incoming.placeAreaId ?? "") === (existing.placeAreaId ?? "") &&
    (incoming.placeAreaNameAr ?? "") === (existing.placeAreaNameAr ?? "") &&
    (incoming.placeAreaNameEn ?? "") === (existing.placeAreaNameEn ?? "") &&
    (incoming.placeDistrictId ?? null) === (existing.placeDistrictId ?? null) &&
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
  /** City -> Area (filterOnly facet) and the area's names for the picker. */
  placeAreaId?: string;
  placeAreaNameAr?: string;
  placeAreaNameEn?: string;
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
    kind: schoolKind(data.kind),
    governorate: typeof data.governorate === "string" ? data.governorate : "",
    city: typeof data.city === "string" ? data.city : "",
    cityAr: typeof data.cityAr === "string" ? data.cityAr : "",
  };
  if (typeof data.placeAreaId === "string" && data.placeAreaId) {
    record.placeAreaId = data.placeAreaId;
    record.placeAreaNameAr = typeof data.placeAreaNameAr === "string" ? data.placeAreaNameAr : "";
    record.placeAreaNameEn = typeof data.placeAreaNameEn === "string" ? data.placeAreaNameEn : "";
  }
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

/** The fields searchRecordFrom reads: the only ones the index sync asks Firestore for. */
export const SEARCH_RECORD_FIELDS = [
  "status", "searchHidden", "nameAr", "nameEn", "kind", "governorate", "city", "cityAr",
  "placeAreaId", "placeAreaNameAr", "placeAreaNameEn", "location",
] as const;

/**
 * A to-do line when the index holds more records than [warnAt] (default
 * 8,000, the coordinator's line; Algolia's free plan allows 50,000 records
 * and 10,000 searches a month, read 16 Nov 2026), else null.
 */
export function recordWarning(records: number, warnAt = 8000): string | null {
  if (records <= warnAt) return null;
  return `index holds ${records} records (warning line ${warnAt}): check the Algolia plan's record and search limits (docs/COSTS.md); the owner accepted a paid plan if needed`;
}

/** What the loader does about duplicates the import merged (tools/import_schools/dedupe.py). */
export interface AutoMergePlan {
  /** Existing schools taken out of the list: status "merged", mergedInto [into]. Never deleted. */
  hide: Array<{ id: string; into: string }>;
  /** Incoming schools not written because an admin-edited school keeps their group. */
  cancelled: string[];
  /** Admin-edited schools in a group that were left alone (two edited schools are never merged). */
  editedKept: string[];
  /** Parents' schools that look like an imported one (never merged automatically; shown for an admin). */
  parentLookalikes: Array<{ id: string; like: string }>;
}

export interface MergedImport extends ImportedSchool {
  /** IDs of the import's entries merged into this one. */
  mergedFrom?: string[];
}

function km(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const r = 6371;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos((a.lat * Math.PI) / 180) * Math.cos((b.lat * Math.PI) / 180) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(h));
}

/**
 * Applies the import's merges to schools already in Firestore. For each
 * incoming school with mergedFrom, the documents of the merged entries
 * (by ID, or whose every source key is now the incoming school's) are
 * hidden into the document the incoming school is written to. Rules:
 * - nothing is deleted; a hidden school gets status "merged" + mergedInto
 *   (search drops it, children and carpools follow mergedInto);
 * - an admin-edited school is never hidden: if one is in the group it is
 *   the survivor (the incoming write is cancelled, the others are hidden
 *   into it); two admin-edited schools in a group are both left alone;
 * - parents' schools (source "parent") are never merged, only listed when
 *   one has the same name as an imported school within 500 m.
 * [plan] (from planImport) is changed in place when a write is cancelled.
 */
export function planAutoMerges(incoming: MergedImport[], existing: ExistingSchool[], plan: ImportPlan): AutoMergePlan {
  const out: AutoMergePlan = { hide: [], cancelled: [], editedKept: [], parentLookalikes: [] };
  const byId = new Map(existing.map((s) => [s.id, s]));
  const byKey = new Map<string, ExistingSchool>();
  for (const s of existing) for (const key of s.sourceKeys) if (!byKey.has(key)) byKey.set(key, s);
  const hidden = new Set<string>();
  const targetOf = (school: ImportedSchool): string => {
    const update = plan.updates.find((u) => u.school.id === school.id);
    if (update) return update.id;
    const match = byId.get(school.id) ?? school.sourceKeys.map((k) => byKey.get(k)).find((s) => s !== undefined);
    return match?.id ?? school.id;
  };
  const imported = (s: ExistingSchool) => s.source !== "parent" && s.status === "active";
  // Merged by an earlier import into another school: re-pointed when this run's group has another survivor.
  const importMerged = (s: ExistingSchool) => s.source !== "parent" && s.status === "merged" && s.mergedBy === "import" && !s.adminEdited;
  for (const school of incoming) {
    const from = new Set(school.mergedFrom ?? []);
    if (from.size === 0) continue;
    const keys = new Set(school.sourceKeys);
    const target = targetOf(school);
    const members = existing.filter(
      (s) =>
        s.id !== target &&
        !hidden.has(s.id) &&
        (imported(s) || importMerged(s)) &&
        (from.has(s.id) || (s.sourceKeys.length > 0 && s.sourceKeys.every((k) => keys.has(k)))),
    );
    if (members.length === 0) continue;
    const targetDoc = byId.get(target);
    const edited = [targetDoc, ...members].filter((s): s is ExistingSchool => s !== undefined && s.adminEdited && imported(s));
    let survivor = target;
    if (edited.length > 0 && !(targetDoc && targetDoc.adminEdited)) {
      survivor = edited[0].id;
      // The import's write would make a second copy next to the edited one.
      plan.creates = plan.creates.filter((c) => c.id !== school.id);
      plan.updates = plan.updates.filter((u) => u.school.id !== school.id);
      out.cancelled.push(school.id);
      if (targetDoc && imported(targetDoc) && !targetDoc.adminEdited) {
        out.hide.push({ id: targetDoc.id, into: survivor });
        hidden.add(targetDoc.id);
      }
    }
    for (const m of members) {
      if (m.id === survivor) continue;
      if (importMerged(m) && m.mergedInto === survivor) continue; // already so
      if (m.adminEdited) {
        out.editedKept.push(m.id);
        continue;
      }
      out.hide.push({ id: m.id, into: survivor });
      hidden.add(m.id);
    }
  }
  // Parents' schools: same normalised name as an imported school within 500 m.
  const byName = new Map<string, MergedImport[]>();
  for (const s of incoming) for (const k of searchKeysFor(s.nameAr, s.nameEn)) byName.set(k, [...(byName.get(k) ?? []), s]);
  for (const p of existing) {
    if (p.source !== "parent" || !p.location || p.status === "merged") continue;
    const like = searchKeysFor(p.nameAr, p.nameEn)
      .flatMap((k) => byName.get(k) ?? [])
      .find((s) => s.location && km(s.location, p.location as { lat: number; lng: number }) <= 0.5);
    if (like) out.parentLookalikes.push({ id: p.id, like: like.id });
  }
  out.hide.sort((a, b) => a.id.localeCompare(b.id));
  return out;
}

/**
 * Imported schools the import now drops (schools.json "dropped": a name not
 * in Arabic or English, a tutoring centre, ...): taken out of the list
 * (searchHidden + hiddenReason; never deleted). Only active, imported, not
 * admin-edited schools whose EVERY source key is dropped and that no
 * incoming school still claims; parents' schools are never touched.
 */
export function planDroppedHiding(
  dropped: Array<{ key: string; reason: string }>,
  existing: ExistingSchool[],
  incoming: ImportedSchool[],
): Array<{ id: string; reason: string }> {
  const reasonOf = new Map(dropped.map((d) => [d.key, d.reason]));
  const claimed = new Set(incoming.flatMap((s) => s.sourceKeys));
  const incomingIds = new Set(incoming.map((s) => s.id));
  return existing
    .filter(
      (s) =>
        s.status === "active" &&
        !s.adminEdited &&
        s.source !== "parent" &&
        s.searchHidden !== true &&
        !incomingIds.has(s.id) &&
        s.sourceKeys.length > 0 &&
        s.sourceKeys.every((k) => reasonOf.has(k) && !claimed.has(k)),
    )
    .map((s) => ({ id: s.id, reason: reasonOf.get(s.sourceKeys[0]) ?? "dropped" }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

/**
 * Schools an earlier import merged (status "merged", mergedBy "import") that
 * this run keeps as a school of their own (the rules changed, or a review
 * "separate" row): back to "active", so a merge is never final. Admin
 * merges, admin-edited and parents' schools are never touched.
 */
export function planUnmerge(existing: ExistingSchool[], incoming: MergedImport[]): string[] {
  const ids = new Set(incoming.map((s) => s.id));
  const mergedAway = new Set(incoming.flatMap((s) => s.mergedFrom ?? []));
  return existing
    .filter((s) => s.status === "merged" && s.mergedBy === "import" && !s.adminEdited && s.source !== "parent" && ids.has(s.id) && !mergedAway.has(s.id))
    .map((s) => s.id)
    .sort();
}

/** Schools the import hid earlier that the rules keep again (a name repaired): back in the list. */
export function planUnhide(existing: ExistingSchool[], incoming: ImportedSchool[]): string[] {
  const claimed = new Set(incoming.flatMap((s) => s.sourceKeys));
  const ids = new Set(incoming.map((s) => s.id));
  return existing
    .filter((s) => s.hiddenReason && s.searchHidden === true && !s.adminEdited && (ids.has(s.id) || s.sourceKeys.some((k) => claimed.has(k))))
    .map((s) => s.id)
    .sort();
}

export function parseDropped(value: unknown): Array<{ key: string; reason: string }> {
  if (!Array.isArray(value)) return [];
  return value.flatMap((x) => {
    const o = typeof x === "object" && x !== null ? (x as Record<string, unknown>) : {};
    return typeof o.key === "string" && typeof o.reason === "string" ? [{ key: o.key.slice(0, 120), reason: o.reason.slice(0, 40) }] : [];
  });
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
