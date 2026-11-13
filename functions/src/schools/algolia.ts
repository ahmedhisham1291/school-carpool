import { createHash, createHmac } from "node:crypto";
import type { SchoolSearchRecord } from "./catalog";

/**
 * Algolia over its REST API with Node's fetch (no client package). Used
 * only from Cloud Functions and the admin scripts: the write key never
 * leaves the server. The app gets a short-lived secured key derived from
 * a search-only key and limited to the schools index (securedSearchKey).
 *
 * COST MODE: Algolia Build (free) plan. Writes happen only when a school's
 * indexed fields change (catalog.syncAction); a full reindex is a script
 * the owner runs by hand.
 */

export interface SearchIndexWriter {
  save(record: SchoolSearchRecord): Promise<void>;
  remove(objectID: string): Promise<void>;
}

/** Index settings: Arabic and English, typo tolerant, filter by governorate. */
export const SCHOOL_INDEX_SETTINGS = {
  searchableAttributes: ["nameAr,nameEn", "searchKeys", "city,cityAr"],
  attributesForFaceting: ["filterOnly(governorate)", "filterOnly(kind)"],
  queryLanguages: ["ar", "en"],
  indexLanguages: ["ar", "en"],
  ignorePlurals: ["ar", "en"],
  removeStopWords: false,
  typoTolerance: true,
  minWordSizefor1Typo: 3,
  minWordSizefor2Typos: 7,
  // Only what the picker shows; nothing else ever reaches the phone.
  attributesToRetrieve: ["nameAr", "nameEn", "governorate", "city", "cityAr", "kind"],
  attributesToHighlight: [],
  hitsPerPage: 20,
  paginationLimitedTo: 100,
} as const;

/**
 * Restrictions to set on the parent search-only key (SETUP.md 14.4). The
 * secured keys carry a userToken, so Algolia applies the hourly limit PER
 * USER, not per IP address (Egyptian mobile networks put many people
 * behind one address). 100 an hour is far more than a parent needs
 * (2 to 4 requests per school search) and, with the daily key cap below,
 * keeps one account from using up the free month.
 */
export const SEARCH_KEY_LIMITS = { maxHitsPerQuery: 20, maxQueriesPerIPPerHour: 100 } as const;

/** One hour: the app asks for a new key when it expires. */
export const SECURED_KEY_TTL_SECONDS = 3600;

/**
 * Keys per parent per day (Cairo date). With 100 searches per key-hour,
 * one account can make at most 600 search requests a day. A normal
 * session needs one key.
 */
export const MAX_SEARCH_KEYS_PER_DAY = 6;

/**
 * The userToken Algolia counts searches by: a hash of the uid, so Algolia
 * never sees our user IDs (spec section 7: it holds school names and
 * places only). Letters and digits only, as Algolia requires.
 */
export function searchUserToken(uid: string): string {
  return createHash("sha256").update(`school-search:${uid}`).digest("hex").slice(0, 32);
}

/**
 * A secured API key (Algolia's documented scheme): base64 of the hex
 * HMAC-SHA256 of the query parameters, keyed with the parent search-only
 * key, followed by those parameters. The parameters limit the key to
 * [indexName] until [validUntil] (Unix seconds) and tie it to [userToken]
 * (per-user rate limit); the app cannot change them without the parent key.
 */
export function securedSearchKey(parentSearchKey: string, indexName: string, validUntil: number, userToken: string): string {
  const params = new URLSearchParams({
    restrictIndices: indexName,
    validUntil: String(validUntil),
    userToken,
  }).toString();
  const hmac = createHmac("sha256", parentSearchKey).update(params).digest("hex");
  return Buffer.from(hmac + params).toString("base64");
}

/** Daily key count of one parent (searchKeyLimits/{uid}). */
export interface KeyQuota {
  day: string;
  count: number;
}

/** The quota after one more key, or null when today's keys are used up. */
export function nextKeyQuota(current: KeyQuota | null, today: string, max: number = MAX_SEARCH_KEYS_PER_DAY): KeyQuota | null {
  const count = current && current.day === today ? current.count : 0;
  return count >= max ? null : { day: today, count: count + 1 };
}

/**
 * Why the configured search cannot serve this project, or null. The fake
 * search is for the emulators and test projects; in prod it would quietly
 * search only the first 200 schools, so it is refused (and reported).
 */
export function searchConfigProblem(provider: string, appEnv: string): string | null {
  if (provider !== "fake" && provider !== "algolia") return `SCHOOL_SEARCH_PROVIDER "${provider}" is unknown (use fake or algolia).`;
  if (provider === "fake" && appEnv === "prod") {
    return "SCHOOL_SEARCH_PROVIDER=fake is not allowed in prod: set up Algolia (SETUP.md 14.4).";
  }
  return null;
}

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  status: number;
  text(): Promise<string>;
}>;

export class AlgoliaRestClient implements SearchIndexWriter {
  constructor(
    private readonly appId: string,
    private readonly apiKey: string,
    private readonly indexName: string,
    private readonly fetchFn: Fetch = fetch as unknown as Fetch,
  ) {}

  private url(path: string): string {
    return `https://${this.appId}.algolia.net/1/indexes/${encodeURIComponent(this.indexName)}${path}`;
  }

  private async call(method: string, path: string, body?: unknown): Promise<void> {
    const response = await this.fetchFn(this.url(path), {
      method,
      headers: {
        "X-Algolia-Application-Id": this.appId,
        "X-Algolia-API-Key": this.apiKey,
        "Content-Type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    // 404 on delete: already gone.
    if (!response.ok && !(method === "DELETE" && response.status === 404)) {
      // The body is Algolia's error message, never school or parent data of ours.
      throw new Error(`Algolia ${method} failed with ${response.status}`);
    }
  }

  save(record: SchoolSearchRecord): Promise<void> {
    return this.call("PUT", `/${encodeURIComponent(record.objectID)}`, record);
  }

  remove(objectID: string): Promise<void> {
    return this.call("DELETE", `/${encodeURIComponent(objectID)}`);
  }

  /** Up to 1000 records per call (admin reindex script). */
  saveMany(records: SchoolSearchRecord[]): Promise<void> {
    return this.call("POST", "/batch", { requests: records.map((body) => ({ action: "updateObject", body })) });
  }

  setSettings(): Promise<void> {
    return this.call("PUT", "/settings", SCHOOL_INDEX_SETTINGS);
  }

  clear(): Promise<void> {
    return this.call("POST", "/clear");
  }
}
