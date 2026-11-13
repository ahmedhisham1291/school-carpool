import { AdminError, docId, record, text } from "./errors";
import type { AdminCaller } from "./guard";
import type { AreaRecord, GeoPointValue, SchoolRecord, SchoolsStore, SchoolStatus } from "./types";

/**
 * Schools and areas (F4 data, managed in the admin panel, F14), and the
 * queue of schools parents typed under "Other" (status awaiting_review,
 * spec section 9), which an admin approves as new or merges into an
 * existing school. Parents add "Other" schools from Prompt 4B on.
 */

/** Egypt's 27 governorates. Labels are in the ARB files (adminGov_<code>). */
export const GOVERNORATES = [
  "alexandria",
  "aswan",
  "asyut",
  "beheira",
  "beni_suef",
  "cairo",
  "dakahlia",
  "damietta",
  "faiyum",
  "gharbia",
  "giza",
  "ismailia",
  "kafr_el_sheikh",
  "luxor",
  "matruh",
  "minya",
  "monufia",
  "new_valley",
  "north_sinai",
  "port_said",
  "qalyubia",
  "qena",
  "red_sea",
  "sharqia",
  "sohag",
  "south_sinai",
  "suez",
] as const;

/** A box around Egypt: catches swapped or mistyped coordinates. */
export const EGYPT_BOUNDS = { minLat: 21.5, maxLat: 31.8, minLng: 24.5, maxLng: 37.1 };

export interface SchoolsDeps {
  store: SchoolsStore;
  now: () => number;
}

export function parsePoint(value: unknown): GeoPointValue {
  const raw = record(value);
  const lat = raw?.lat;
  const lng = raw?.lng;
  if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng)) {
    throw new AdminError("invalid-request", { field: "location" });
  }
  const b = EGYPT_BOUNDS;
  if (lat < b.minLat || lat > b.maxLat || lng < b.minLng || lng > b.maxLng) {
    throw new AdminError("invalid-request", { field: "location" });
  }
  // About 1 m is plenty for a school gate.
  return { lat: Math.round(lat * 1e5) / 1e5, lng: Math.round(lng * 1e5) / 1e5 };
}

export interface SchoolInput {
  id: string | null;
  nameAr: string;
  nameEn: string;
  governorate: string;
  city: string;
  location: GeoPointValue;
}

export function parseSchool(data: unknown): SchoolInput {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const governorate = raw.governorate;
  if (typeof governorate !== "string" || !(GOVERNORATES as readonly string[]).includes(governorate)) {
    throw new AdminError("invalid-request", { field: "governorate" });
  }
  return {
    id: raw.id === undefined || raw.id === null ? null : docId(raw.id),
    nameAr: field("nameAr", () => text(raw.nameAr, 2, 120)),
    nameEn: field("nameEn", () => text(raw.nameEn, 2, 120)),
    governorate,
    city: field("city", () => text(raw.city, 2, 80)),
    location: parsePoint(raw.location),
  };
}

function field<T>(name: string, read: () => T): T {
  try {
    return read();
  } catch {
    throw new AdminError("invalid-request", { field: name });
  }
}

/** Creates or edits an active school. Merged schools cannot be edited. */
export async function saveSchool(
  deps: SchoolsDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ id: string }> {
  const input = parseSchool(data);
  const existing = input.id ? await deps.store.getSchool(input.id) : undefined;
  if (input.id && !existing) throw new AdminError("not-found");
  if (existing && existing.status !== "active") throw new AdminError("invalid-state");
  const id = existing?.id ?? deps.store.newId("schools");
  const school: SchoolRecord = {
    id,
    nameAr: input.nameAr,
    nameEn: input.nameEn,
    governorate: input.governorate,
    city: input.city,
    location: input.location,
    status: "active",
    source: existing?.source ?? "admin",
    addedBy: existing?.addedBy ?? caller.uid,
    mergedInto: null,
    createdAtMs: existing?.createdAtMs ?? deps.now(),
  };
  await deps.store.saveSchool(school, !existing, {
    actorUid: caller.uid,
    action: existing ? "school.update" : "school.create",
    target: `schools/${id}`,
    ip,
  });
  return { id };
}

const LIST_STATUSES: readonly SchoolStatus[] = ["active", "awaiting_review"];

export async function listSchools(
  deps: SchoolsDeps,
  data: unknown,
): Promise<{ schools: SchoolRecord[]; nextAfterId: string | null }> {
  const raw = record(data) ?? {};
  const status = (raw.status ?? "active") as SchoolStatus;
  if (!LIST_STATUSES.includes(status)) throw new AdminError("invalid-request");
  const governorate = raw.governorate === undefined || raw.governorate === null ? null : raw.governorate;
  if (governorate !== null && !(GOVERNORATES as readonly unknown[]).includes(governorate)) {
    throw new AdminError("invalid-request");
  }
  const afterId = raw.afterId === undefined || raw.afterId === null ? null : docId(raw.afterId);
  const limit = 50;
  const schools = await deps.store.listSchools({ status, governorate: governorate as string | null, afterId, limit });
  return { schools, nextAfterId: schools.length === limit ? schools[schools.length - 1].id : null };
}

export async function getSchool(
  deps: SchoolsDeps,
  data: unknown,
): Promise<{ school: SchoolRecord; areas: AreaRecord[] }> {
  const id = docId(record(data)?.id);
  const school = await deps.store.getSchool(id);
  if (!school) throw new AdminError("not-found");
  return { school, areas: await deps.store.listAreas(id) };
}

export async function saveArea(
  deps: SchoolsDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ id: string }> {
  const raw = record(data);
  if (!raw) throw new AdminError("invalid-request");
  const schoolId = docId(raw.schoolId);
  const nameAr = field("nameAr", () => text(raw.nameAr, 2, 80));
  const nameEn = field("nameEn", () => text(raw.nameEn, 2, 80));
  const center = parsePoint(raw.center);
  const school = await deps.store.getSchool(schoolId);
  if (!school) throw new AdminError("not-found");
  if (school.status !== "active") throw new AdminError("invalid-state");
  const areaId = raw.id === undefined || raw.id === null ? null : docId(raw.id);
  const existing = areaId ? await deps.store.getArea(areaId) : undefined;
  if (areaId && (!existing || existing.schoolId !== schoolId)) throw new AdminError("not-found");
  const id = existing?.id ?? deps.store.newId("areas");
  await deps.store.saveArea({ id, schoolId, nameAr, nameEn, center }, !existing, {
    actorUid: caller.uid,
    action: existing ? "area.update" : "area.create",
    target: `areas/${id}`,
    ip,
  });
  return { id };
}

/**
 * "Other" queue: approve a school a parent typed, after the admin has
 * checked and corrected its names, governorate, city and pin.
 */
export async function approveSchool(
  deps: SchoolsDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ id: string }> {
  const input = parseSchool(data);
  if (!input.id) throw new AdminError("invalid-request");
  const existing = await deps.store.getSchool(input.id);
  if (!existing) throw new AdminError("not-found");
  if (existing.status !== "awaiting_review") throw new AdminError("invalid-state");
  await deps.store.saveSchool(
    { ...existing, ...input, id: existing.id, status: "active", mergedInto: null },
    false,
    { actorUid: caller.uid, action: "school.approve", target: `schools/${existing.id}`, ip },
  );
  return { id: existing.id };
}

/** "Other" queue: the typed school is a duplicate of an active one. */
export async function mergeSchool(
  deps: SchoolsDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<{ id: string; childrenMoved: number }> {
  const raw = record(data);
  const fromId = docId(raw?.schoolId);
  const intoId = docId(raw?.intoId);
  if (fromId === intoId) throw new AdminError("invalid-request");
  const [from, into] = await Promise.all([deps.store.getSchool(fromId), deps.store.getSchool(intoId)]);
  if (!from || !into) throw new AdminError("not-found");
  if (from.status !== "awaiting_review" || into.status !== "active") throw new AdminError("invalid-state");
  const childrenMoved = await deps.store.mergeSchool(fromId, intoId, {
    actorUid: caller.uid,
    action: "school.merge",
    target: `schools/${fromId}`,
    details: { into: intoId },
    ip,
  });
  return { id: intoId, childrenMoved };
}
