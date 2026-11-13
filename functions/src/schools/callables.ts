import * as logger from "firebase-functions/logger";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import {
  ALGOLIA_APP_ID,
  ALGOLIA_INDEX,
  ALGOLIA_SEARCH_KEY,
  ALGOLIA_WRITE_KEY,
  ENFORCE_APP_CHECK,
  REGION,
  SCHOOL_SEARCH_PROVIDER,
} from "../config";
import { reportError } from "../sentry";
import { AlgoliaRestClient, SECURED_KEY_TTL_SECONDS, securedSearchKey } from "./algolia";
import { syncAction } from "./catalog";
import { addOtherSchool as addOtherFlow, OTHER_SCHOOL_ERROR_CODES, OtherSchoolError } from "./other";
import { FirestoreOtherSchoolsStore } from "./store";

/**
 * Schools list functions (F4): the parent's "Other" school, the search key
 * for the app, and the sync from Firestore to the search index.
 */

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
    if (error instanceof OtherSchoolError) {
      throw new HttpsError(OTHER_SCHOOL_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
    }
    // Never the request data (a typed school name is harmless, but the rule is simple).
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

/**
 * Parent: a school missing from the list ("Other").
 * { name, governorate, location?: { lat, lng } } -> { id, nameAr, nameEn, governorate, status }
 */
export const addOtherSchool = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("addOtherSchool", () =>
    addOtherFlow({ store: new FirestoreOtherSchoolsStore(adminDb()), now: () => Date.now() }, requireUid(request), request.data),
  ),
);

/**
 * Parent: a one-hour Algolia key that can only search the schools index.
 * {} -> { provider: "algolia", appId, indexName, key, validUntil } or { provider: "fake" }
 */
export const getSchoolSearchKey = onCall(
  { enforceAppCheck: ENFORCE_APP_CHECK, secrets: [ALGOLIA_SEARCH_KEY] },
  (request) =>
    run("getSchoolSearchKey", async () => {
      requireUid(request);
      if (SCHOOL_SEARCH_PROVIDER.value() !== "algolia") return { provider: "fake" };
      const appId = ALGOLIA_APP_ID.value();
      const parent = ALGOLIA_SEARCH_KEY.value();
      if (!appId || !parent) {
        logger.error("Algolia is selected but ALGOLIA_APP_ID or ALGOLIA_SEARCH_KEY is not set");
        throw new HttpsError("failed-precondition", "School search is not configured.", { reason: "search-misconfigured" });
      }
      const indexName = ALGOLIA_INDEX.value();
      const validUntil = Math.floor(Date.now() / 1000) + SECURED_KEY_TTL_SECONDS;
      return { provider: "algolia", appId, indexName, key: securedSearchKey(parent, indexName, validUntil), validUntil };
    }),
);

/**
 * Keeps the search index in step with schools/{id}: active schools are
 * indexed (names and places only), anything else is removed. Does nothing
 * with the fake provider, and nothing when no indexed field changed.
 */
export const syncSchoolToSearch = onDocumentWritten(
  { document: "schools/{schoolId}", region: REGION, secrets: [ALGOLIA_WRITE_KEY], retry: false },
  async (event) => {
    if (SCHOOL_SEARCH_PROVIDER.value() !== "algolia") return;
    const id = event.params.schoolId;
    const action = syncAction(id, event.data?.before?.data(), event.data?.after?.data());
    if (action.kind === "none") return;
    const client = new AlgoliaRestClient(ALGOLIA_APP_ID.value(), ALGOLIA_WRITE_KEY.value(), ALGOLIA_INDEX.value());
    try {
      if (action.kind === "upsert") await client.save(action.record);
      else await client.remove(id);
    } catch (error) {
      // The reindex script (SETUP.md) repairs anything missed.
      logger.error("school search sync failed", { schoolId: id, message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
  },
);
