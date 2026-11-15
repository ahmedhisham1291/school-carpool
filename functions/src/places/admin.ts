import { AdminError, docId, record, text } from "../admin_panel/errors";
import type { AdminCaller } from "../admin_panel/guard";
import type { AuditEntry } from "../admin_panel/types";
import { isGovernorate, sortPlaces, type PlaceArea, type PlaceDistrict } from "./catalog";

/**
 * Admin panel "Places" (F14 for F4/F46): City -> Area -> District with
 * counts, add, rename, deactivate and merge areas and districts, move a
 * school to another area, and the queue of districts parents typed
 * ("my district isn't listed"). Every change writes an audit entry (in the
 * same batch as the change, store.ts). Callables in admin_panel/callables.ts
 * require the admin claim and a second factor (access.ts).
 */

export type PlaceKind = "area" | "district";

/** What the panel shows: no outlines (they stay on the server). */
export interface AreaSummary {
  id: string;
  governorate: string;
  nameAr: string;
  nameEn: string;
  source: string;
  hasShape: boolean;
  schoolCount: number;
  addressCount: number;
  active: boolean;
  mergedInto: string | null;
}

export interface DistrictSummary extends AreaSummary {
  areaId: string;
}

export interface PlaceRequestItem {
  id: string;
  areaId: string;
  governorate: string;
  text: string;
  createdAtMs: number;
}

export interface SchoolPlace {
  id: string;
  status: string;
  governorate: string;
  placeAreaId: string;
  placeDistrictId: string | null;
}

export interface PlacesAdminStore {
  newId(kind: PlaceKind): string;
  listAreas(governorate: string): Promise<PlaceArea[]>;
  listDistricts(areaId: string): Promise<PlaceDistrict[]>;
  area(id: string): Promise<PlaceArea | null>;
  district(id: string): Promise<PlaceDistrict | null>;
  /** Creates or renames; a rename also renames the area on its schools. */
  saveArea(area: { id: string; governorate: string; nameAr: string; nameEn: string }, isNew: boolean, audit: AuditEntry): Promise<void>;
  saveDistrict(
    district: { id: string; areaId: string; governorate: string; nameAr: string; nameEn: string; source: string },
    isNew: boolean,
    audit: AuditEntry,
  ): Promise<void>;
  setActive(kind: PlaceKind, id: string, active: boolean, audit: AuditEntry): Promise<void>;
  /** Moves schools, districts (areas only), addresses and counts from [fromId] to [intoId]; returns schools moved. */
  merge(kind: PlaceKind, fromId: string, intoId: string, audit: AuditEntry): Promise<number>;
  school(id: string): Promise<SchoolPlace | null>;
  moveSchool(schoolId: string, from: SchoolPlace, area: PlaceArea, district: PlaceDistrict | null, audit: AuditEntry): Promise<void>;
  listRequests(limit: number): Promise<PlaceRequestItem[]>;
  request(id: string): Promise<(PlaceRequestItem & { uid: string; status: string }) | null>;
  /** Closes the request; with a district, also sets it on the parent's address. */
  resolveRequest(id: string, districtId: string | null, audit: AuditEntry): Promise<void>;
}

export interface PlacesAdminDeps {
  store: PlacesAdminStore;
}

function summary(a: PlaceArea): AreaSummary {
  return {
    id: a.id,
    governorate: a.governorate,
    nameAr: a.nameAr,
    nameEn: a.nameEn,
    source: a.source,
    hasShape: a.rings.length > 0,
    schoolCount: a.schoolCount,
    addressCount: a.addressCount,
    active: a.active,
    mergedInto: a.mergedInto,
  };
}

function districtSummary(d: PlaceDistrict): DistrictSummary {
  return { ...summary({ ...d, level: 0 }), areaId: d.areaId };
}

function names(raw: Record<string, unknown>): { nameAr: string; nameEn: string } {
  try {
    return { nameAr: text(raw.nameAr, 2, 80), nameEn: text(raw.nameEn, 2, 80) };
  } catch {
    throw new AdminError("invalid-request", { field: "name" });
  }
}

function kindOf(v: unknown): PlaceKind {
  if (v === "area" || v === "district") return v;
  throw new AdminError("invalid-request", { field: "kind" });
}

function audit(caller: AdminCaller, ip: string | null, action: string, target: string, details?: AuditEntry["details"]): AuditEntry {
  return { actorUid: caller.uid, action, target, ip, ...(details ? { details } : {}) };
}

/** { governorate } -> { areas } (merged ones left out). */
export async function listAreas(deps: PlacesAdminDeps, data: unknown): Promise<{ areas: AreaSummary[] }> {
  const governorate = record(data)?.governorate;
  if (!isGovernorate(governorate)) throw new AdminError("invalid-request", { field: "governorate" });
  const areas = (await deps.store.listAreas(governorate)).filter((a) => !a.mergedInto);
  return { areas: sortPlaces(areas).map(summary) };
}

/** { areaId } -> { districts } */
export async function listDistricts(deps: PlacesAdminDeps, data: unknown): Promise<{ districts: DistrictSummary[] }> {
  const areaId = docId(record(data)?.areaId);
  const districts = (await deps.store.listDistricts(areaId)).filter((d) => !d.mergedInto);
  return { districts: sortPlaces(districts).map(districtSummary) };
}

/** { id?, governorate, nameAr, nameEn } -> { id } */
export async function saveArea(deps: PlacesAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<{ id: string }> {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const { nameAr, nameEn } = names(raw);
  const id = raw.id === undefined || raw.id === null ? null : docId(raw.id);
  if (id) {
    const existing = await deps.store.area(id);
    if (!existing) throw new AdminError("not-found");
    if (existing.mergedInto) throw new AdminError("invalid-state");
    await deps.store.saveArea({ id, governorate: existing.governorate, nameAr, nameEn }, false, audit(caller, ip, "place.area.rename", `placeAreas/${id}`));
    return { id };
  }
  const governorate = raw.governorate;
  if (!isGovernorate(governorate)) throw new AdminError("invalid-request", { field: "governorate" });
  const newId = deps.store.newId("area");
  await deps.store.saveArea({ id: newId, governorate, nameAr, nameEn }, true, audit(caller, ip, "place.area.create", `placeAreas/${newId}`));
  return { id: newId };
}

/** { id?, areaId, nameAr, nameEn } -> { id } */
export async function saveDistrict(deps: PlacesAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<{ id: string }> {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const { nameAr, nameEn } = names(raw);
  const id = raw.id === undefined || raw.id === null ? null : docId(raw.id);
  if (id) {
    const existing = await deps.store.district(id);
    if (!existing) throw new AdminError("not-found");
    if (existing.mergedInto) throw new AdminError("invalid-state");
    await deps.store.saveDistrict(
      { id, areaId: existing.areaId, governorate: existing.governorate, nameAr, nameEn, source: existing.source },
      false,
      audit(caller, ip, "place.district.rename", `placeDistricts/${id}`),
    );
    return { id };
  }
  const area = await deps.store.area(docId(raw.areaId));
  if (!area) throw new AdminError("not-found");
  if (!area.active || area.mergedInto) throw new AdminError("invalid-state");
  const newId = deps.store.newId("district");
  await deps.store.saveDistrict(
    { id: newId, areaId: area.id, governorate: area.governorate, nameAr, nameEn, source: "admin" },
    true,
    audit(caller, ip, "place.district.create", `placeDistricts/${newId}`, { areaId: area.id }),
  );
  return { id: newId };
}

/** { kind, id, active } -> { id, active } */
export async function setPlaceActive(deps: PlacesAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<{ id: string; active: boolean }> {
  const raw = record(data) ?? {};
  const kind = kindOf(raw.kind);
  const id = docId(raw.id);
  if (typeof raw.active !== "boolean") throw new AdminError("invalid-request", { field: "active" });
  const place = kind === "area" ? await deps.store.area(id) : await deps.store.district(id);
  if (!place) throw new AdminError("not-found");
  if (place.mergedInto) throw new AdminError("invalid-state");
  if (place.active !== raw.active) {
    const collection = kind === "area" ? "placeAreas" : "placeDistricts";
    await deps.store.setActive(kind, id, raw.active, audit(caller, ip, raw.active ? "place.activate" : "place.deactivate", `${collection}/${id}`));
  }
  return { id, active: raw.active };
}

/**
 * { kind, fromId, intoId } -> { id, schoolsMoved }. A duplicate: areas of
 * the same city, districts of the same area. [fromId] is kept as an
 * inactive record pointing at [intoId] (nothing that refers to it breaks).
 */
export async function mergePlaces(deps: PlacesAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<{ id: string; schoolsMoved: number }> {
  const raw = record(data) ?? {};
  const kind = kindOf(raw.kind);
  const fromId = docId(raw.fromId);
  const intoId = docId(raw.intoId);
  if (fromId === intoId) throw new AdminError("invalid-request");
  if (kind === "area") {
    const [from, into] = await Promise.all([deps.store.area(fromId), deps.store.area(intoId)]);
    if (!from || !into) throw new AdminError("not-found");
    if (from.mergedInto || into.mergedInto || !into.active) throw new AdminError("invalid-state");
    if (from.governorate !== into.governorate) throw new AdminError("invalid-request", { field: "governorate" });
  } else {
    const [from, into] = await Promise.all([deps.store.district(fromId), deps.store.district(intoId)]);
    if (!from || !into) throw new AdminError("not-found");
    if (from.mergedInto || into.mergedInto || !into.active) throw new AdminError("invalid-state");
    if (from.areaId !== into.areaId) throw new AdminError("invalid-request", { field: "areaId" });
  }
  const collection = kind === "area" ? "placeAreas" : "placeDistricts";
  const moved = await deps.store.merge(kind, fromId, intoId, audit(caller, ip, "place.merge", `${collection}/${fromId}`, { into: intoId }));
  return { id: intoId, schoolsMoved: moved };
}

/**
 * { schoolId, areaId, districtId? } -> { id }. The import never overwrites
 * the move (the school is marked adminEdited, like any admin edit).
 */
export async function moveSchoolArea(deps: PlacesAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<{ id: string }> {
  const raw = record(data) ?? {};
  const schoolId = docId(raw.schoolId);
  const areaId = docId(raw.areaId);
  const districtId = raw.districtId === undefined || raw.districtId === null ? null : docId(raw.districtId);
  const [school, area, district] = await Promise.all([
    deps.store.school(schoolId),
    deps.store.area(areaId),
    districtId ? deps.store.district(districtId) : Promise.resolve(null),
  ]);
  if (!school || !area || (districtId && !district)) throw new AdminError("not-found");
  if (school.status === "merged" || !area.active || area.mergedInto) throw new AdminError("invalid-state");
  if (area.governorate !== school.governorate) throw new AdminError("invalid-request", { field: "governorate" });
  if (district && (district.areaId !== area.id || !district.active || district.mergedInto)) {
    throw new AdminError("invalid-request", { field: "districtId" });
  }
  await deps.store.moveSchool(
    schoolId,
    school,
    area,
    district,
    audit(caller, ip, "school.move-area", `schools/${schoolId}`, { from: school.placeAreaId || null, into: area.id }),
  );
  return { id: schoolId };
}

/** {} -> { requests } (open "district not listed" requests, oldest first). */
export async function listPlaceRequests(deps: PlacesAdminDeps): Promise<{ requests: PlaceRequestItem[] }> {
  return { requests: await deps.store.listRequests(100) };
}

/**
 * { id, action: "create" | "map" | "dismiss", districtId?, nameAr?, nameEn? }
 * -> { id, districtId }. "create" adds the typed district to the area and
 * puts it on the parent's address; "map" points the address at an existing
 * district of that area; "dismiss" closes the request (the address keeps
 * the typed text).
 */
export async function resolvePlaceRequest(
  deps: PlacesAdminDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ id: string; districtId: string | null }> {
  const raw = record(data) ?? {};
  const id = docId(raw.id);
  const request = await deps.store.request(id);
  if (!request) throw new AdminError("not-found");
  if (request.status !== "open") throw new AdminError("invalid-state");
  let districtId: string | null = null;
  if (raw.action === "create") {
    districtId = (await saveDistrict(deps, caller, { areaId: request.areaId, nameAr: raw.nameAr, nameEn: raw.nameEn }, ip)).id;
  } else if (raw.action === "map") {
    const district = await deps.store.district(docId(raw.districtId));
    if (!district) throw new AdminError("not-found");
    if (district.areaId !== request.areaId || !district.active || district.mergedInto) throw new AdminError("invalid-request", { field: "districtId" });
    districtId = district.id;
  } else if (raw.action !== "dismiss") {
    throw new AdminError("invalid-request", { field: "action" });
  }
  await deps.store.resolveRequest(id, districtId, audit(caller, ip, `place.request.${String(raw.action)}`, `placeRequests/${id}`, { districtId }));
  return { id, districtId };
}
