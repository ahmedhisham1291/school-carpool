import { isGovernorate, isPlaceId, shapeContains, type LatLng, type PlaceArea, type PlaceDistrict } from "./catalog";

/**
 * F46: the structured home address (City -> Area -> District, street,
 * building, optional floor, apartment and landmark) and its pin. Pure
 * logic; the flows are in callables.ts.
 *
 * homes/{uid}.address (owner only, like the exact point):
 *   governorate, placeAreaId, placeAreaNameAr/En, placeDistrictId (or null),
 *   placeDistrictNameAr/En, districtText ("my district isn't listed"),
 *   street, building, floor, apartment, landmark
 * parentLocations/{uid} (the public record) gets governorate, placeAreaId
 * and placeDistrictId only, next to the rounded point (carpool matching
 * can filter by them; spec F46).
 *
 * The app sends IDs and text; the server checks that the area is an active
 * area of that city and the district an active district of that area.
 * The app never writes these documents (firestore.rules).
 */

export interface HomeAddress {
  governorate: string;
  placeAreaId: string;
  placeAreaNameAr: string;
  placeAreaNameEn: string;
  placeDistrictId: string | null;
  placeDistrictNameAr: string;
  placeDistrictNameEn: string;
  districtText: string;
  street: string;
  building: string;
  floor: string;
  apartment: string;
  landmark: string;
}

export type AddressErrorReason =
  | "invalid-request"
  | "invalid-city"
  | "invalid-area"
  | "invalid-district"
  | "invalid-street"
  | "invalid-building"
  | "invalid-extra";

export class AddressError extends Error {
  constructor(readonly reason: AddressErrorReason) {
    super(reason);
    this.name = "AddressError";
  }
}

export const ADDRESS_ERROR_CODES: Record<AddressErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "invalid-city": "invalid-argument",
  "invalid-area": "invalid-argument",
  "invalid-district": "invalid-argument",
  "invalid-street": "invalid-argument",
  "invalid-building": "invalid-argument",
  "invalid-extra": "invalid-argument",
};

/** Letters of any script, digits, spaces and the punctuation addresses use. */
const TEXT = /^[\p{L}\p{M}\p{N} .,'’()&/#\-،]+$/u;
/** A building number: digits and letters ("12", "12ب", "B4"), at most 10. */
const BUILDING = /^[\p{L}\p{N}][\p{L}\p{N} /\-]{0,9}$/u;

function clean(value: unknown): string {
  return typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
}

function textOf(value: unknown, min: number, max: number, reason: AddressErrorReason, optional = false): string {
  const v = clean(value);
  if (optional && v === "") return "";
  if (v.length < min || v.length > max || !TEXT.test(v)) throw new AddressError(reason);
  return v;
}

export interface AddressInput {
  governorate: string;
  placeAreaId: string;
  placeDistrictId: string | null;
  districtText: string;
  street: string;
  building: string;
  floor: string;
  apartment: string;
  landmark: string;
}

/** Checks the shape of what the app sent (not yet against the places). */
export function parseAddress(data: unknown): AddressInput {
  const raw = typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : null;
  if (!raw) throw new AddressError("invalid-request");
  if (!isGovernorate(raw.governorate)) throw new AddressError("invalid-city");
  if (!isPlaceId(raw.placeAreaId)) throw new AddressError("invalid-area");
  const districtId = raw.placeDistrictId === undefined || raw.placeDistrictId === null || raw.placeDistrictId === "" ? null : raw.placeDistrictId;
  if (districtId !== null && !isPlaceId(districtId)) throw new AddressError("invalid-district");
  const districtText = districtId === null ? textOf(raw.districtText, 2, 80, "invalid-district") : "";
  const building = clean(raw.building);
  if (!BUILDING.test(building)) throw new AddressError("invalid-building");
  return {
    governorate: raw.governorate,
    placeAreaId: raw.placeAreaId,
    placeDistrictId: districtId as string | null,
    districtText,
    street: textOf(raw.street, 2, 120, "invalid-street"),
    building,
    floor: textOf(raw.floor, 1, 10, "invalid-extra", true),
    apartment: textOf(raw.apartment, 1, 10, "invalid-extra", true),
    landmark: textOf(raw.landmark, 2, 120, "invalid-extra", true),
  };
}

/** The address with the area's and district's names, once they are checked against the places. */
export function checkAddress(input: AddressInput, area: PlaceArea | null, district: PlaceDistrict | null): HomeAddress {
  if (!area || !area.active || area.mergedInto || area.governorate !== input.governorate) throw new AddressError("invalid-area");
  if (input.placeDistrictId !== null) {
    if (!district || !district.active || district.mergedInto || district.areaId !== area.id) throw new AddressError("invalid-district");
  }
  return {
    governorate: input.governorate,
    placeAreaId: area.id,
    placeAreaNameAr: area.nameAr,
    placeAreaNameEn: area.nameEn,
    placeDistrictId: district?.id ?? null,
    placeDistrictNameAr: district?.nameAr ?? "",
    placeDistrictNameEn: district?.nameEn ?? "",
    districtText: input.districtText,
    street: input.street,
    building: input.building,
    floor: input.floor,
    apartment: input.apartment,
    landmark: input.landmark,
  };
}

/**
 * The text sent to address search to find the pin: "building street,
 * district, area, city, Egypt" in the app's language (the city's name comes
 * from [cityName]).
 */
export function geocodeQuery(a: HomeAddress, language: "ar" | "en", cityName: string): string {
  const pick = (ar: string, en: string) => (language === "ar" ? ar || en : en || ar);
  const district = a.placeDistrictId ? pick(a.placeDistrictNameAr, a.placeDistrictNameEn) : a.districtText;
  const parts = [
    `${a.building} ${a.street}`.trim(),
    district,
    pick(a.placeAreaNameAr, a.placeAreaNameEn),
    cityName,
    language === "ar" ? "مصر" : "Egypt",
  ].filter((p) => p.length > 0);
  return parts.join(language === "ar" ? "، " : ", ").slice(0, 100);
}

/**
 * Where the map starts for the parent to confirm: the found point when it
 * lies in the chosen area (or within [slackKm] of its centre, for an area
 * without an outline), else the district's centre, else the area's centre
 * ("approximate": the parent must move the pin).
 */
export function startPoint(
  found: LatLng | null,
  area: PlaceArea,
  district: PlaceDistrict | null,
  slackKm = 3,
): { location: LatLng | null; approximate: boolean } {
  if (found) {
    const inside = area.rings.length > 0 ? shapeContains(area, found) : !!area.centre && km(found, area.centre) <= slackKm;
    if (inside) return { location: found, approximate: false };
  }
  return { location: district?.centre ?? area.centre ?? null, approximate: true };
}

function km(a: LatLng, b: LatLng): number {
  const rad = Math.PI / 180;
  const h =
    Math.sin(((b.lat - a.lat) * rad) / 2) ** 2 +
    Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(((b.lng - a.lng) * rad) / 2) ** 2;
  return 2 * 6371.0088 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Address counts to move when a parent's address changes area or district. */
export function countMoves(
  before: Pick<HomeAddress, "placeAreaId" | "placeDistrictId"> | null,
  after: Pick<HomeAddress, "placeAreaId" | "placeDistrictId">,
): Array<{ kind: "area" | "district"; id: string; by: 1 | -1 }> {
  const out: Array<{ kind: "area" | "district"; id: string; by: 1 | -1 }> = [];
  if (before?.placeAreaId !== after.placeAreaId) {
    if (before?.placeAreaId) out.push({ kind: "area", id: before.placeAreaId, by: -1 });
    out.push({ kind: "area", id: after.placeAreaId, by: 1 });
  }
  if ((before?.placeDistrictId ?? null) !== after.placeDistrictId) {
    if (before?.placeDistrictId) out.push({ kind: "district", id: before.placeDistrictId, by: -1 });
    if (after.placeDistrictId) out.push({ kind: "district", id: after.placeDistrictId, by: 1 });
  }
  return out;
}

/** Reads a stored address (homes/{uid}.address); null when absent or not one. */
export function addressFromDoc(v: unknown): HomeAddress | null {
  const o = typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  if (!o || typeof o.placeAreaId !== "string" || !o.placeAreaId) return null;
  const s = (k: string) => (typeof o[k] === "string" ? (o[k] as string) : "");
  return {
    governorate: s("governorate"),
    placeAreaId: o.placeAreaId,
    placeAreaNameAr: s("placeAreaNameAr"),
    placeAreaNameEn: s("placeAreaNameEn"),
    placeDistrictId: typeof o.placeDistrictId === "string" && o.placeDistrictId ? o.placeDistrictId : null,
    placeDistrictNameAr: s("placeDistrictNameAr"),
    placeDistrictNameEn: s("placeDistrictNameEn"),
    districtText: s("districtText"),
    street: s("street"),
    building: s("building"),
    floor: s("floor"),
    apartment: s("apartment"),
    landmark: s("landmark"),
  };
}
