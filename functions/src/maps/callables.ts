import * as logger from "firebase-functions/logger";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import {
  ENFORCE_APP_CHECK,
  MAP_DRIVING_SCHOOL_CHANGES_PER_DAY,
  MAP_HOME_MOVES_PER_DAY,
  MAP_NEARBY_SEARCHES_PER_HOUR,
  MAP_PLACE_DETAILS_PER_HOUR,
  MAP_PLACE_SEARCHES_PER_HOUR,
  MAPS_SERVER_KEY,
  PLACES_PROVIDER,
  REGION,
} from "../config";
import { reportError } from "../sentry";
import {
  MAP_ERROR_CODES,
  checkPlaceAccount,
  MapError,
  refreshPublicLocation,
  searchNearby,
  setDrivingSchools as setDrivingSchoolsFlow,
  setHome,
  takePlaceDetails,
  takePlaceSearch,
  updateMapSettings as updateMapSettingsFlow,
  type MapDeps,
} from "./parent_map";
import { autocomplete, FakePlacesProvider, GooglePlacesProvider, placeDetails as placeDetailsFlow, type PlacesProvider } from "./places";
import { mapRefreshNeeded } from "./sync";
import { FirestoreMapStore, FirestorePlaceCache } from "./store";
import { noteAbuse } from "../privacy/abuse_hook";

/**
 * Maps functions (Prompt 5: F21 to F24). The app sends the exact home only
 * to setHome; nothing here ever returns another parent's exact point.
 * Logs never contain coordinates, addresses or search text (CLAUDE.md,
 * PRIVACY).
 */

export function mapDeps(): MapDeps {
  return {
    store: new FirestoreMapStore(adminDb()),
    now: () => Date.now(),
    limits: {
      homeMovesPerDay: MAP_HOME_MOVES_PER_DAY.value(),
      nearbySearchesPerHour: MAP_NEARBY_SEARCHES_PER_HOUR.value(),
      placeSearchesPerHour: MAP_PLACE_SEARCHES_PER_HOUR.value(),
      placeDetailsPerHour: MAP_PLACE_DETAILS_PER_HOUR.value(),
      drivingSchoolChangesPerDay: MAP_DRIVING_SCHOOL_CHANGES_PER_DAY.value(),
    },
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
    if (error instanceof MapError) {
      throw new HttpsError(MAP_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, {
        reason: error.reason,
        retryAfterSeconds: Math.ceil(error.retryAfterMs / 1000),
      });
    }
    // Never the request data: it holds coordinates or typed addresses.
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

/** { location: { lat, lng }, label? } -> { approximate: { lat, lng } } */
export const setHomeLocation = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("setHomeLocation", () => setHome(mapDeps(), requireUid(request), request.data)),
);

/** { showOnMap?, notifyNewParents?, radiusKm? } -> the settings */
export const updateMapSettings = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("updateMapSettings", () => updateMapSettingsFlow(mapDeps(), requireUid(request), request.data)),
);

/** { schoolIds: string[] } -> { schools: [{ id, nameAr, nameEn }] } */
export const setDrivingSchools = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("setDrivingSchools", () => setDrivingSchoolsFlow(mapDeps(), requireUid(request), request.data)),
);

/** { schoolId, radiusKm } -> { schoolId, radiusKm, parents: [{ id, firstName, schoolId, point }] } */
export const searchNearbyParents = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("searchNearbyParents", async () => {
    const uid = requireUid(request);
    // Prompt 12: searching many areas in an hour alerts the admins.
    const q = typeof request.data === "object" && request.data !== null ? (request.data as { schoolId?: unknown; radiusKm?: unknown }) : {};
    await noteAbuse(uid, "areaSearches", `${String(q.schoolId ?? "")}|${String(q.radiusKm ?? "")}`.slice(0, 64));
    return searchNearby(mapDeps(), { uid, verifiedClaim: request.auth?.token?.verified === true }, request.data);
  }),
);

/** { input, sessionToken, language, near? } -> { suggestions: [{ placeId, primary, secondary }] } */
export const placesAutocomplete = onCall({ enforceAppCheck: ENFORCE_APP_CHECK, secrets: [MAPS_SERVER_KEY] }, (request) =>
  run("placesAutocomplete", async () => {
    const d = mapDeps();
    await takePlaceSearch(d, requireUid(request));
    return autocomplete(placesProvider(), request.data);
  }),
);

/**
 * { placeId, sessionToken, language } -> { placeId, label, location }
 * Refused for suspended or banned accounts; cache misses are limited per
 * parent per hour (MAP_PLACE_DETAILS_PER_HOUR) on top of the project's
 * daily Places cap (SETUP 15.4).
 */
export const placeDetails = onCall({ enforceAppCheck: ENFORCE_APP_CHECK, secrets: [MAPS_SERVER_KEY] }, (request) =>
  run("placeDetails", async () => {
    const uid = requireUid(request);
    const d = mapDeps();
    await checkPlaceAccount(d, uid);
    return placeDetailsFlow(
      {
        provider: placesProvider(),
        cache: new FirestorePlaceCache(adminDb()),
        now: () => Date.now(),
        beforeProviderCall: () => takePlaceDetails(d, uid),
      },
      request.data,
    );
  }),
);

export async function refresh(uid: string): Promise<void> {
  try {
    await refreshPublicLocation(mapDeps(), uid);
  } catch (error) {
    // The next change or search rebuilds the record.
    logger.error("parent map refresh failed", { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
  }
}

/**
 * Keeps parentLocations/{uid} in step with the account (verified,
 * suspended, first name) and creates the "new parent nearby" event when a
 * parent with a home is verified.
 */
export const syncMapOnUserWrite = onDocumentWritten({ document: "users/{uid}", region: REGION, retry: false }, async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!mapRefreshNeeded("user", before, after)) return;
  await refresh((event.params as Record<string, string>).uid);
});

/** Children's schools (approved children only) decide whose map a parent is on. */
export const syncMapOnChildWrite = onDocumentWritten({ document: "children/{childId}", region: REGION, retry: false }, async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!mapRefreshNeeded("child", before, after)) return;
  const owners = new Set<string>();
  for (const d of [before, after]) if (typeof d?.ownerUid === "string") owners.add(d.ownerUid);
  for (const uid of owners) await refresh(uid);
});
