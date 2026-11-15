import * as logger from "firebase-functions/logger";
import { HttpsError, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import { adminDb } from "../admin";
import { ENFORCE_APP_CHECK, MAPS_SERVER_KEY, PLACES_PROVIDER } from "../config";
import { mapDeps } from "../maps/callables";
import { inEgypt, isValidPoint } from "../maps/geo";
import { checkPlaceAccount, MAP_ERROR_CODES, MapError, setHome, takePlaceDetails, takePlaceSearch, type MapDeps } from "../maps/parent_map";
import { FakePlacesProvider, GooglePlacesProvider, placeDetails as placeDetailsFlow, type PlacesProvider } from "../maps/places";
import { FirestorePlaceCache } from "../maps/store";
import { gatedCall, sessionCall } from "../privacy/device_gate";
import { reportError } from "../sentry";
import {
  ADDRESS_ERROR_CODES,
  AddressError,
  checkAddress,
  countMoves,
  geocodeQuery,
  parseAddress,
  startPoint,
  type HomeAddress,
} from "./address";
import { PLACE_AREAS, PLACE_DISTRICTS, PLACE_REQUESTS, type LatLng } from "./catalog";
import { FirestorePlaceLocator, type PlaceLocator } from "./store";

/**
 * F46 address functions. The exact point and the street stay in
 * homes/{uid} (owner only); others see the rounded point and the area.
 * Logs never contain coordinates, addresses or typed text (CLAUDE.md).
 */

export interface AddressDeps {
  map: MapDeps;
  places: PlaceLocator;
  /** Moves address counts between areas and districts. */
  moveCounts(moves: ReturnType<typeof countMoves>): Promise<void>;
  /** Opens (or updates) the parent's "district not listed" request; null closes it. */
  districtRequest(uid: string, request: { areaId: string; governorate: string; text: string } | null): Promise<void>;
}

function obj(data: unknown): Record<string, unknown> {
  return typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
}

async function checked(deps: Pick<AddressDeps, "places">, data: unknown): Promise<HomeAddress> {
  const input = parseAddress(data);
  const [area, district] = await Promise.all([
    deps.places.area(input.placeAreaId),
    input.placeDistrictId ? deps.places.district(input.placeDistrictId) : Promise.resolve(null),
  ]);
  return checkAddress(input, area, district);
}

/** A one-line label for the parent's own screens ("12 Road 9, Degla, Maadi"). */
export function addressLabel(a: HomeAddress, language: "ar" | "en" = "ar"): string {
  const pick = (ar: string, en: string) => (language === "ar" ? ar || en : en || ar);
  const district = a.placeDistrictId ? pick(a.placeDistrictNameAr, a.placeDistrictNameEn) : a.districtText;
  return [`${a.building} ${a.street}`.trim(), district, pick(a.placeAreaNameAr, a.placeAreaNameEn)]
    .filter((p) => p.length > 0)
    .join(language === "ar" ? "، " : ", ")
    .slice(0, 200);
}

/**
 * { address, location } -> { approximate } (the rounded point others see).
 * The address is checked against the places; the pin goes through the
 * home flow (Egypt only, moves limited per day).
 */
export async function setHomeAddressFlow(deps: AddressDeps, uid: string, data: unknown): Promise<{ approximate: LatLng }> {
  const raw = obj(data);
  const address = await checked(deps, raw.address);
  const before = (await deps.map.store.home(uid))?.address ?? null;
  const result = await setHome(deps.map, uid, { location: raw.location, label: addressLabel(address) }, address);
  await deps.moveCounts(countMoves(before, address));
  await deps.districtRequest(
    uid,
    address.placeDistrictId ? null : { areaId: address.placeAreaId, governorate: address.governorate, text: address.districtText },
  );
  return result;
}

/** { location } -> { governorate, placeAreaId, placeDistrictId, names } (prefill after "Search instead"). */
export async function placeForPointFlow(
  deps: { places: PlaceLocator },
  data: unknown,
): Promise<{
  governorate: string | null;
  placeAreaId: string | null;
  placeDistrictId: string | null;
}> {
  const location = obj(data).location;
  if (!isValidPoint(location)) throw new MapError("invalid-location");
  if (!inEgypt(location)) throw new MapError("outside-egypt");
  const hit = await deps.places.locate(location);
  return { governorate: hit.governorate, placeAreaId: hit.areaId, placeDistrictId: hit.districtId };
}

/**
 * { address, sessionToken, language } -> { location, approximate }. One
 * address search (and one place details, cached) with the structured
 * address; the parent confirms or moves the pin. When the search finds
 * nothing inside the chosen area, the district's or the area's centre
 * is the start (approximate: true).
 */
export async function geocodeAddressFlow(
  deps: {
    places: PlaceLocator;
    provider: PlacesProvider;
    details: (placeId: string, sessionToken: string, language: "ar" | "en") => Promise<{ location: LatLng }>;
    beforeSearch: () => Promise<void>;
    cityName: (governorate: string, language: "ar" | "en") => string;
  },
  data: unknown,
): Promise<{ location: LatLng | null; approximate: boolean }> {
  const raw = obj(data);
  const language: "ar" | "en" = raw.language === "en" ? "en" : "ar";
  const token = typeof raw.sessionToken === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(raw.sessionToken) ? raw.sessionToken : null;
  if (!token) throw new AddressError("invalid-request");
  const address = await checked(deps, raw.address);
  const [area, district] = await Promise.all([
    deps.places.area(address.placeAreaId),
    address.placeDistrictId ? deps.places.district(address.placeDistrictId) : Promise.resolve(null),
  ]);
  if (!area) throw new AddressError("invalid-area");
  await deps.beforeSearch();
  let found: LatLng | null = null;
  const near = district?.centre ?? area.centre;
  const suggestions = await deps.provider.autocomplete(geocodeQuery(address, language, deps.cityName(address.governorate, language)), token, language, near);
  if (suggestions.length > 0) {
    try {
      found = (await deps.details(suggestions[0].placeId, token, language)).location;
    } catch (error) {
      if (!(error instanceof MapError)) throw error;
    }
  }
  return startPoint(found, area, district);
}

// --------------------------------------------------------------------------
// Firebase
// --------------------------------------------------------------------------

/** City names for the address search (Arabic and English). */
const CITY_NAMES: Record<string, [string, string]> = {
  alexandria: ["الإسكندرية", "Alexandria"], aswan: ["أسوان", "Aswan"], asyut: ["أسيوط", "Asyut"],
  beheira: ["البحيرة", "Beheira"], beni_suef: ["بني سويف", "Beni Suef"], cairo: ["القاهرة", "Cairo"],
  dakahlia: ["الدقهلية", "Dakahlia"], damietta: ["دمياط", "Damietta"], faiyum: ["الفيوم", "Faiyum"],
  gharbia: ["الغربية", "Gharbia"], giza: ["الجيزة", "Giza"], ismailia: ["الإسماعيلية", "Ismailia"],
  kafr_el_sheikh: ["كفر الشيخ", "Kafr El Sheikh"], luxor: ["الأقصر", "Luxor"], matruh: ["مطروح", "Matruh"],
  minya: ["المنيا", "Minya"], monufia: ["المنوفية", "Monufia"], new_valley: ["الوادي الجديد", "New Valley"],
  north_sinai: ["شمال سيناء", "North Sinai"], port_said: ["بورسعيد", "Port Said"], qalyubia: ["القليوبية", "Qalyubia"],
  qena: ["قنا", "Qena"], red_sea: ["البحر الأحمر", "Red Sea"], sharqia: ["الشرقية", "Sharqia"],
  sohag: ["سوهاج", "Sohag"], south_sinai: ["جنوب سيناء", "South Sinai"], suez: ["السويس", "Suez"],
};

export function cityName(governorate: string, language: "ar" | "en"): string {
  const names = CITY_NAMES[governorate];
  return names ? names[language === "ar" ? 0 : 1] : "";
}

class FirestoreAddressSide {
  constructor(private readonly db: Firestore) {}

  async moveCounts(moves: ReturnType<typeof countMoves>): Promise<void> {
    if (moves.length === 0) return;
    const batch = this.db.batch();
    for (const m of moves) {
      batch.set(this.db.collection(m.kind === "area" ? PLACE_AREAS : PLACE_DISTRICTS).doc(m.id), { addressCount: FieldValue.increment(m.by) }, { merge: true });
    }
    await batch.commit();
  }

  /** One request per parent: placeRequests/{uid}. */
  async districtRequest(uid: string, request: { areaId: string; governorate: string; text: string } | null): Promise<void> {
    const ref = this.db.collection(PLACE_REQUESTS).doc(uid);
    if (!request) {
      const snap = await ref.get();
      if (snap.exists && snap.get("status") === "open") await ref.update({ status: "done", resolvedAt: FieldValue.serverTimestamp() });
      return;
    }
    await ref.set({ uid, ...request, status: "open", createdAt: FieldValue.serverTimestamp() });
  }
}

function addressDeps(): AddressDeps {
  const side = new FirestoreAddressSide(adminDb());
  return {
    map: mapDeps(),
    places: new FirestorePlaceLocator(adminDb()),
    moveCounts: (m) => side.moveCounts(m),
    districtRequest: (uid, r) => side.districtRequest(uid, r),
  };
}

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return uid;
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof AddressError) {
      throw new HttpsError(ADDRESS_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
    }
    if (error instanceof MapError) {
      throw new HttpsError(MAP_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, {
        reason: error.reason,
        retryAfterSeconds: Math.ceil(error.retryAfterMs / 1000),
      });
    }
    // Never the request data: it holds an address and coordinates.
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

function placesProvider(): PlacesProvider {
  if (PLACES_PROVIDER.value() !== "google") return new FakePlacesProvider();
  const key = MAPS_SERVER_KEY.value();
  if (!key) throw new HttpsError("failed-precondition", "Address search is not configured.", { reason: "places-misconfigured" });
  return new GooglePlacesProvider(key);
}

/** F46: { address, location } -> { approximate } */
export const setHomeAddress = gatedCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("setHomeAddress", () => setHomeAddressFlow(addressDeps(), requireUid(request), request.data)),
);

/** F46: { location } -> { governorate, placeAreaId, placeDistrictId } */
export const placeForPoint = sessionCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("placeForPoint", async () => {
    const uid = requireUid(request);
    await takePlaceSearch(mapDeps(), uid);
    return placeForPointFlow({ places: new FirestorePlaceLocator(adminDb()) }, request.data);
  }),
);

/** F46: { address, sessionToken, language } -> { location, approximate } */
export const geocodeAddress = sessionCall({ enforceAppCheck: ENFORCE_APP_CHECK, secrets: [MAPS_SERVER_KEY] }, (request) =>
  run("geocodeAddress", async () => {
    const uid = requireUid(request);
    const d = mapDeps();
    await checkPlaceAccount(d, uid);
    const provider = placesProvider();
    return geocodeAddressFlow(
      {
        places: new FirestorePlaceLocator(adminDb()),
        provider,
        beforeSearch: () => takePlaceSearch(d, uid),
        cityName,
        details: (placeId, sessionToken, language) =>
          placeDetailsFlow(
            { provider, cache: new FirestorePlaceCache(adminDb()), now: () => Date.now(), beforeProviderCall: () => takePlaceDetails(d, uid) },
            { placeId, sessionToken, language },
          ),
      },
      request.data,
    );
  }),
);
