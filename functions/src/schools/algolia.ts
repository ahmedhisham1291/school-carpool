import { createHmac } from "node:crypto";
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

/** Search-only key restrictions to set on the parent key (SETUP.md): limits abuse. */
export const SEARCH_KEY_LIMITS = { maxHitsPerQuery: 20, maxQueriesPerIPPerHour: 2000 } as const;

/** One hour: the app asks for a new key when it expires. */
export const SECURED_KEY_TTL_SECONDS = 3600;

/**
 * A secured API key (Algolia's documented scheme): base64 of the
 * hex HMAC-SHA256 of the query parameters, keyed with the parent
 * search-only key, followed by those parameters. The parameters limit the
 * key to [indexName] until [validUntil] (Unix seconds); Algolia refuses
 * anything else, and the app cannot change them without the parent key.
 */
export function securedSearchKey(parentSearchKey: string, indexName: string, validUntil: number): string {
  const params = new URLSearchParams({ restrictIndices: indexName, validUntil: String(validUntil) }).toString();
  const hmac = createHmac("sha256", parentSearchKey).update(params).digest("hex");
  return Buffer.from(hmac + params).toString("base64");
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
