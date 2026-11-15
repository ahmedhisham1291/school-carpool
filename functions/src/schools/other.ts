import { EGYPT_BOUNDS, GOVERNORATES } from "../admin_panel/schools";
import { normalizeText } from "../text/normalize";

/**
 * "Other" (F4): a parent whose school is not in the list types its name and
 * governorate and may drop a pin. It is saved as a school awaiting review
 * (schools/{id}, status awaiting_review, source "parent", addedBy = the
 * parent), readable only by that parent (firestore.rules) and not in the
 * search index, until an admin approves it or merges it into an existing
 * school in the panel's "New schools" queue (Prompt 4). The parent picks
 * it for their child and carries on meanwhile.
 */

export type OtherSchoolErrorReason =
  | "invalid-name"
  | "invalid-governorate"
  | "invalid-location"
  | "too-many-pending"
  | "no-account"
  | "suspended";

export class OtherSchoolError extends Error {
  constructor(readonly reason: OtherSchoolErrorReason) {
    super(reason);
    this.name = "OtherSchoolError";
  }
}

export const OTHER_SCHOOL_ERROR_CODES: Record<OtherSchoolErrorReason, string> = {
  "invalid-name": "invalid-argument",
  "invalid-governorate": "invalid-argument",
  "invalid-location": "invalid-argument",
  "too-many-pending": "resource-exhausted",
  "no-account": "failed-precondition",
  suspended: "permission-denied",
};

/** A parent has at most this many schools waiting for review (spam guard). */
export const MAX_PENDING_PER_PARENT = 5;

export interface PendingSchool {
  id: string;
  nameAr: string;
  nameEn: string;
  governorate: string;
  location: { lat: number; lng: number } | null;
  addedBy: string;
  createdAtMs: number;
  /** City -> Area -> District of the pin, found on the server (none without a pin). */
  placeAreaId?: string;
  placeAreaNameAr?: string;
  placeAreaNameEn?: string;
  placeDistrictId?: string | null;
}

export interface OtherSchoolsStore {
  newId(): string;
  /** "missing", "suspended" (or banned) or "ok". */
  accountState(uid: string): Promise<"missing" | "suspended" | "ok">;
  pendingOf(uid: string, limit: number): Promise<PendingSchool[]>;
  create(school: PendingSchool): Promise<void>;
}

// Letters of any script, digits, spaces and the punctuation school names use.
const NAME = /^[\p{L}\p{M}\p{N} .,'’()&/-]+$/u;

export interface OtherSchoolInput {
  name: string;
  governorate: string;
  location: { lat: number; lng: number } | null;
}

export function parseOtherSchool(data: unknown): OtherSchoolInput {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  const name = typeof raw.name === "string" ? raw.name.trim().replace(/\s+/g, " ") : "";
  if (name.length < 3 || name.length > 120 || !NAME.test(name) || normalizeText(name).replace(/\s/g, "").length < 3) {
    throw new OtherSchoolError("invalid-name");
  }
  const governorate = raw.governorate;
  if (typeof governorate !== "string" || !(GOVERNORATES as readonly string[]).includes(governorate)) {
    throw new OtherSchoolError("invalid-governorate");
  }
  let location: OtherSchoolInput["location"] = null;
  if (raw.location !== undefined && raw.location !== null) {
    const loc = raw.location as { lat?: unknown; lng?: unknown };
    const { lat, lng } = loc;
    const b = EGYPT_BOUNDS;
    if (
      typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng) ||
      lat < b.minLat || lat > b.maxLat || lng < b.minLng || lng > b.maxLng
    ) {
      throw new OtherSchoolError("invalid-location");
    }
    location = { lat: Math.round(lat * 1e5) / 1e5, lng: Math.round(lng * 1e5) / 1e5 };
  }
  return { name, governorate, location };
}

export interface OtherSchoolResult {
  id: string;
  nameAr: string;
  nameEn: string;
  governorate: string;
  status: "awaiting_review";
}

/**
 * Saves the parent's school for review. The same name in the same
 * governorate typed again by the same parent returns the school already
 * waiting (a retry or a second child never makes two).
 */
export async function addOtherSchool(
  deps: {
    store: OtherSchoolsStore;
    now: () => number;
    /** The area of a pin (places/store.ts); optional so older callers and tests work. */
    placeOf?: (p: { lat: number; lng: number }) => Promise<Pick<PendingSchool, "placeAreaId" | "placeAreaNameAr" | "placeAreaNameEn" | "placeDistrictId">>;
  },
  uid: string,
  data: unknown,
): Promise<OtherSchoolResult> {
  const input = parseOtherSchool(data);
  const state = await deps.store.accountState(uid);
  if (state === "missing") throw new OtherSchoolError("no-account");
  if (state === "suspended") throw new OtherSchoolError("suspended");

  const pending = await deps.store.pendingOf(uid, MAX_PENDING_PER_PARENT + 1);
  const key = normalizeText(input.name);
  const same = pending.find((p) => p.governorate === input.governorate && normalizeText(p.nameAr) === key);
  if (same) return { id: same.id, nameAr: same.nameAr, nameEn: same.nameEn, governorate: same.governorate, status: "awaiting_review" };
  if (pending.length >= MAX_PENDING_PER_PARENT) throw new OtherSchoolError("too-many-pending");

  // One name typed: it stands for both until the admin corrects them.
  const school: PendingSchool = {
    id: deps.store.newId(),
    nameAr: input.name,
    nameEn: input.name,
    governorate: input.governorate,
    location: input.location,
    addedBy: uid,
    createdAtMs: deps.now(),
    ...(input.location && deps.placeOf ? await deps.placeOf(input.location) : {}),
  };
  await deps.store.create(school);
  return { id: school.id, nameAr: school.nameAr, nameEn: school.nameEn, governorate: school.governorate, status: "awaiting_review" };
}
