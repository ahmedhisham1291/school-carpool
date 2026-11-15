import * as logger from "firebase-functions/logger";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
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
import { AlgoliaRestClient } from "./algolia";
import { syncAction } from "./catalog";
import { addOtherSchool as addOtherFlow, OTHER_SCHOOL_ERROR_CODES, OtherSchoolError } from "./other";
import { consumeKeyQuotaFirestore, issueSearchKey, SEARCH_KEY_ERROR_CODES, SearchKeyError } from "./search_key";
import { FirestoreOtherSchoolsStore } from "./store";
import { FirestorePlaceLocator, placeOfPoint } from "../places/store";
import { sessionCall } from "../privacy/device_gate";
import { gramsToWrite } from "../admin_panel/school_search";
import { ADMIN_SEARCH_GRAMS } from "../admin_panel/school_search_store";

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
    if (error instanceof SearchKeyError) {
      throw new HttpsError(SEARCH_KEY_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
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
export const addOtherSchool = sessionCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("addOtherSchool", () =>
    addOtherFlow(
      { store: new FirestoreOtherSchoolsStore(adminDb()), now: () => Date.now(), placeOf: (p) => placeOfPoint(new FirestorePlaceLocator(adminDb()), p) },
      requireUid(request),
      request.data,
    ),
  ),
);

/**
 * Parent: which search to use and, for Algolia, a one-hour key that can
 * only search the schools index and is rate limited per parent (at most
 * MAX_SEARCH_KEYS_PER_DAY keys a day). The fake search is refused in prod.
 * {} -> { provider: "algolia", appId, indexName, key, validUntil } or { provider: "fake" }
 */
export const getSchoolSearchKey = sessionCall(
  { enforceAppCheck: ENFORCE_APP_CHECK, secrets: [ALGOLIA_SEARCH_KEY] },
  (request) =>
    run("getSchoolSearchKey", async () => {
      const uid = requireUid(request);
      const db = adminDb();
      return issueSearchKey(
        {
          provider: SCHOOL_SEARCH_PROVIDER.value(),
          appEnv: process.env.APP_ENV ?? "dev",
          appId: ALGOLIA_APP_ID.value(),
          parentSearchKey: ALGOLIA_SEARCH_KEY.value(),
          indexName: ALGOLIA_INDEX.value(),
          nowMs: Date.now(),
          consumeQuota: (id, today) => consumeKeyQuotaFirestore(db, id, today),
          reportProblem: async (problem) => {
            logger.error(`CONFIGURATION ERROR: ${problem}`);
            await reportError(new Error(problem));
          },
        },
        uid,
      );
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

/**
 * Keeps schools/{id}.adminSearchGrams (admin panel search) in step with the
 * names. Every writer sets the field, so this writes only for a writer that
 * did not (a hand edit in the console, an old script): one write, and the
 * second run of this trigger finds nothing to do. Existing schools are
 * filled once by the schools:admin-grams script (SETUP.md).
 */
export const syncSchoolAdminGrams = onDocumentWritten(
  { document: "schools/{schoolId}", region: REGION, retry: false },
  async (event) => {
    const after = event.data?.after;
    const grams = gramsToWrite(after?.exists ? after.data() : undefined);
    if (!grams || !after) return;
    try {
      await after.ref.update({ [ADMIN_SEARCH_GRAMS]: grams });
    } catch (error) {
      logger.error("school admin grams failed", { schoolId: event.params.schoolId, message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
  },
);
