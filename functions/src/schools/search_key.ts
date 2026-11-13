import type { Firestore } from "firebase-admin/firestore";
import { cairoDate } from "../verification/submission";
import { nextKeyQuota, SECURED_KEY_TTL_SECONDS, searchConfigProblem, searchUserToken, securedSearchKey, type KeyQuota } from "./algolia";

/**
 * The parent's search key (F4): which search the app should use and, for
 * Algolia, a one-hour secured key limited to the schools index and tied
 * to the parent (per-user rate limit), at most MAX_SEARCH_KEYS_PER_DAY a
 * day per parent.
 */

export type SearchKeyErrorReason = "search-misconfigured" | "search-limit";

export class SearchKeyError extends Error {
  constructor(readonly reason: SearchKeyErrorReason) {
    super(reason);
    this.name = "SearchKeyError";
  }
}

export const SEARCH_KEY_ERROR_CODES: Record<SearchKeyErrorReason, string> = {
  "search-misconfigured": "failed-precondition",
  "search-limit": "resource-exhausted",
};

export interface SearchKeyDeps {
  provider: string;
  /** APP_ENV: dev, staging or prod. */
  appEnv: string;
  appId: string;
  parentSearchKey: string;
  indexName: string;
  nowMs: number;
  /** Counts one more key for [uid] today; false when the day's keys are used up. */
  consumeQuota(uid: string, today: string): Promise<boolean>;
  /** Logs and reports a configuration problem (never user data). */
  reportProblem(problem: string): Promise<void>;
}

export type SearchKeyResult =
  | { provider: "fake" }
  | { provider: "algolia"; appId: string; indexName: string; key: string; validUntil: number };

export async function issueSearchKey(deps: SearchKeyDeps, uid: string): Promise<SearchKeyResult> {
  const problem = searchConfigProblem(deps.provider, deps.appEnv);
  if (problem) {
    await deps.reportProblem(problem);
    throw new SearchKeyError("search-misconfigured");
  }
  if (deps.provider === "fake") return { provider: "fake" };
  if (!deps.appId || !deps.parentSearchKey || !deps.indexName) {
    await deps.reportProblem("Algolia is selected but ALGOLIA_APP_ID, ALGOLIA_SEARCH_KEY or ALGOLIA_INDEX is not set.");
    throw new SearchKeyError("search-misconfigured");
  }
  if (!(await deps.consumeQuota(uid, cairoDate(deps.nowMs)))) throw new SearchKeyError("search-limit");
  const validUntil = Math.floor(deps.nowMs / 1000) + SECURED_KEY_TTL_SECONDS;
  return {
    provider: "algolia",
    appId: deps.appId,
    indexName: deps.indexName,
    key: securedSearchKey(deps.parentSearchKey, deps.indexName, validUntil, searchUserToken(uid)),
    validUntil,
  };
}

/** searchKeyLimits/{uid}: the day and the number of keys issued (Cloud Functions only). */
export const SEARCH_KEY_LIMITS_COLLECTION = "searchKeyLimits";

export async function consumeKeyQuotaFirestore(db: Firestore, uid: string, today: string): Promise<boolean> {
  const ref = db.collection(SEARCH_KEY_LIMITS_COLLECTION).doc(uid);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? snap.data() : undefined;
    const current: KeyQuota | null =
      data && typeof data.day === "string" && typeof data.count === "number" ? { day: data.day, count: data.count } : null;
    const next = nextKeyQuota(current, today);
    if (!next) return false;
    tx.set(ref, next);
    return true;
  });
}
