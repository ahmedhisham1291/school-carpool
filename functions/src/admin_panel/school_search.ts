import { AdminError, DOC_ID, docId, record } from "./errors";
import type { AdminCaller } from "./guard";
import type { AuditEntry, GeoPointValue, SchoolStatus } from "./types";
import { GOVERNORATES } from "./schools";
import { normalizeText } from "../text/normalize";

/**
 * Admin panel: search and filter EVERY school (F14 schools list).
 *
 * Why Firestore and not Algolia: the parent index holds only active,
 * visible schools (hidden sample, awaiting review and merged schools are
 * removed from it), and admins must find all of them. A second "admin"
 * Algolia index would double the records and the sync writes, spend the
 * free plan's 10k searches a month on staff, and still need a Firestore
 * path for dev (fake search). So the panel searches Firestore directly:
 *
 * - Each school carries `adminSearchGrams`: for every word of its
 *   normalized names (text/normalize.ts: ة/ه, ى/ي, أ/إ/آ/ا, diacritics,
 *   case, Arabic-Indic digits), and the word without "ال", the 3-letter
 *   start and three 3-letter picks of its first 4 letters (gramsOfWord). A query asks Firestore
 *   for schools holding ANY of the query words' grams (array-contains-any,
 *   at most 30), together with the equality filters, ordered by name.
 * - The function then checks every candidate in memory: each query word
 *   must start a name word, allowing 1 typo from 4 letters and 2 from 8
 *   (insert, delete, change or swap two letters). A typo in any of the
 *   first four letters still shares a gram with the right spelling.
 * - Without text: equality filters, ordered by name, counted with a
 *   count() aggregation (one read per 1,000 matches).
 *
 * Firestore merges the single-field composite indexes (field + name) for
 * any mix of filters (firestore.indexes.json). If a mix ever needs an
 * index that is missing, the search runs again with only the most
 * selective filter and checks the rest in memory (degraded: count may be
 * a lower bound), and the missing index is reported to Sentry.
 *
 * Cost (docs/COSTS.md): a page reads at most SCAN_CAP schools, plus a
 * rate-limit write and, on a first page, one audit entry.
 */

export const PAGE_SIZE = 50;
/** Candidates read per Firestore query. */
export const SCAN_BATCH = 200;
/** At most this many schools are read for one page (text search and in-memory filters). */
export const SCAN_CAP = 600;
/** Searches per admin per window (a runaway client cannot spend the free reads). */
export const SEARCH_LIMIT = 120;
export const SEARCH_WINDOW_MS = 10 * 60 * 1000;
const MAX_QUERY = 80;
const MAX_GRAMS = 30;

// ---------------------------------------------------------------------------
// Text

/** Words of a name or query, with "ال" removed as an extra form. */
export function searchWords(text: string): string[] {
  const words = new Set<string>();
  for (const word of normalizeText(text).split(" ")) {
    if (word.length === 0) continue;
    words.add(word);
    if (word.startsWith("ال") && word.length >= 4) words.add(word.slice(2));
    if (word.startsWith("وال") && word.length >= 5) words.add(word.slice(3));
  }
  return [...words];
}

/**
 * Keys of a word: its first 3 letters and, from 4 letters, the 3-letter
 * picks of its first 4 letters (letters 1-2-3 without the first, 0-1-3 and
 * 0-2-3). Any one wrong, missing, extra or swapped letter among the first
 * four leaves a key that the right spelling also has.
 */
function gramsOfWord(word: string): string[] {
  if (word.length < 2) return [];
  const grams = [word.slice(0, 3)];
  if (word.length >= 4) grams.push(word.slice(1, 4), word[0] + word[1] + word[3], word[0] + word[2] + word[3]);
  return grams;
}

/** The `adminSearchGrams` field of schools/{id}: written with the names, never from the app. */
export function schoolSearchGrams(nameAr: string, nameEn: string): string[] {
  const grams = new Set<string>();
  for (const word of searchWords(`${nameAr} ${nameEn}`)) for (const g of gramsOfWord(word)) grams.add(g);
  return [...grams].sort();
}

/** Words so common in school names that their grams match almost every school. */
const COMMON = new Set([
  "مدرسه", "مدارس", "مدرسة", "روضه", "حضانه", "اكاديميه", "معهد", "مجمع", "رسميه", "تجريبيه", "لغات", "الدوليه", "دوليه",
  "ابتدائيه", "اعداديه", "ثانويه", "بنين", "بنات", "مشتركه", "خاصه", "school", "schools", "international", "language",
  "languages", "academy", "college", "kindergarten", "nursery", "primary", "preparatory", "secondary", "experimental",
  "official", "private", "the", "of", "and", "for", "kg",
]);

export interface QueryPlan {
  /** Normalized query words (each must match). */
  tokens: string[];
  /** Firestore array-contains-any values (at most 30). */
  grams: string[];
}

/** Null when the query has nothing to search for. */
export function planQuery(raw: string): QueryPlan | null {
  const tokens = normalizeText(raw).split(" ").filter((t) => t.length > 0);
  if (tokens.length === 0) return null;
  const searchable = tokens.filter((t) => t.length >= 2);
  // Rare words first: their grams pick few candidates. Common words only when nothing else is typed.
  const rare = searchable.filter((t) => !COMMON.has(t) && !(t.startsWith("ال") && COMMON.has(t.slice(2))));
  const pick = (rare.length > 0 ? rare : searchable).sort((a, b) => b.length - a.length);
  const grams = new Set<string>();
  for (const token of pick) {
    const forms = [token];
    if (token.startsWith("ال") && token.length >= 4) forms.push(token.slice(2));
    for (const form of forms) {
      for (const g of gramsOfWord(form)) if (grams.size < MAX_GRAMS) grams.add(g);
    }
  }
  return { tokens, grams: [...grams] };
}

/** Optimal string alignment distance (insert, delete, change, swap neighbours), stopping above [max]. */
export function editDistance(a: string, b: string, max: number): number {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  let prev2: number[] = [];
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    let best = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let v = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) v = Math.min(v, prev2[j - 2] + 1);
      cur.push(v);
      best = Math.min(best, v);
    }
    if (best > max) return max + 1;
    prev2 = prev;
    prev = cur;
  }
  return prev[b.length];
}

function typosAllowed(token: string): number {
  if (token.length >= 8) return 2;
  if (token.length >= 4) return 1;
  return 0;
}

/** Whether a query word starts [word], with the typos its length allows. */
export function tokenMatchesWord(token: string, word: string): boolean {
  if (word.startsWith(token)) return true;
  const max = typosAllowed(token);
  if (max === 0) return false;
  for (let len = token.length - max; len <= token.length + max; len++) {
    if (len < 1 || len > word.length) continue;
    if (editDistance(token, word.slice(0, len), max) <= max) return true;
  }
  return false;
}

/** Every query word matches some word of the school's names. */
export function matchesQuery(tokens: string[], nameAr: string, nameEn: string): boolean {
  const words = searchWords(`${nameAr} ${nameEn}`);
  return tokens.every((t) => words.some((w) => tokenMatchesWord(t, w)));
}

// ---------------------------------------------------------------------------
// Request

export type StatusFilter = SchoolStatus | null;
/** in_search: shown in the parents' search (not hidden); hidden: taken out of search (sample). */
export type VisibilityFilter = "in_search" | "hidden" | null;
export type SortField = "nameAr" | "nameEn";

export interface SchoolSearchRequest {
  text: string | null;
  plan: QueryPlan | null;
  /** false: only what parents can find (active and in search); the status and visibility filters are ignored. */
  includeAll: boolean;
  status: StatusFilter;
  visibility: VisibilityFilter;
  governorate: string | null;
  placeAreaId: string | null;
  placeDistrictId: string | null;
  source: string | null;
  sort: SortField;
  afterId: string | null;
}

const STATUSES: readonly SchoolStatus[] = ["active", "awaiting_review", "merged"];
const SOURCE = /^[a-z0-9_.-]{1,80}$/;

function optional<T>(value: unknown, check: (v: unknown) => T): T | null {
  return value === undefined || value === null || value === "" ? null : check(value);
}

export function parseSearchRequest(data: unknown): SchoolSearchRequest {
  const raw = record(data ?? {});
  if (!raw) throw new AdminError("invalid-request");
  const q = raw.query;
  if (q !== undefined && q !== null && (typeof q !== "string" || q.length > MAX_QUERY)) {
    throw new AdminError("invalid-request", { field: "query" });
  }
  const text = typeof q === "string" && q.trim().length > 0 ? q.trim() : null;
  const includeAll = raw.includeAll === true;
  const status = optional(raw.status, (v) => {
    if (!(STATUSES as readonly unknown[]).includes(v)) throw new AdminError("invalid-request", { field: "status" });
    return v as SchoolStatus;
  });
  const visibility = optional(raw.visibility, (v) => {
    if (v !== "in_search" && v !== "hidden") throw new AdminError("invalid-request", { field: "visibility" });
    return v as VisibilityFilter;
  });
  const governorate = optional(raw.governorate, (v) => {
    if (!(GOVERNORATES as readonly unknown[]).includes(v)) throw new AdminError("invalid-request", { field: "governorate" });
    return v as string;
  });
  const placeAreaId = optional(raw.placeAreaId, docId);
  const placeDistrictId = optional(raw.placeDistrictId, docId);
  // A district belongs to an area, and an area to a city: no child without its parent.
  if (placeDistrictId && !placeAreaId) throw new AdminError("invalid-request", { field: "placeDistrictId" });
  if (placeAreaId && !governorate) throw new AdminError("invalid-request", { field: "placeAreaId" });
  const source = optional(raw.source, (v) => {
    if (typeof v !== "string" || !SOURCE.test(v)) throw new AdminError("invalid-request", { field: "source" });
    return v;
  });
  const sort = raw.sort === undefined || raw.sort === null || raw.sort === "nameAr" ? "nameAr" : raw.sort === "nameEn" ? "nameEn" : null;
  if (!sort) throw new AdminError("invalid-request", { field: "sort" });
  const afterId = optional(raw.afterId, docId);
  return {
    text,
    plan: text ? planQuery(text) : null,
    includeAll,
    status: includeAll ? status : "active",
    visibility: includeAll ? visibility : "in_search",
    governorate,
    placeAreaId,
    placeDistrictId,
    source,
    sort,
    afterId,
  };
}

// ---------------------------------------------------------------------------
// Store

/** What the store can ask Firestore for (equality filters, plus the grams). */
export interface ServerFilters {
  status?: SchoolStatus;
  governorate?: string;
  placeAreaId?: string;
  placeDistrictId?: string;
  source?: string;
  /** Only schools taken out of search. */
  hiddenOnly?: boolean;
  anyGrams?: string[];
}

export interface SchoolRow {
  id: string;
  nameAr: string;
  nameEn: string;
  governorate: string;
  city: string;
  location: GeoPointValue | null;
  status: SchoolStatus;
  source: string;
  searchHidden: boolean;
  placeAreaId: string;
  placeAreaNameAr: string;
  placeAreaNameEn: string;
  placeDistrictId: string | null;
}

export interface SchoolSearchStore {
  /** Schools matching [filters] in [sort] order (then by ID), after [afterId], at most [limit]. */
  scan(filters: ServerFilters, sort: SortField, afterId: string | null, limit: number): Promise<SchoolRow[]>;
  count(filters: ServerFilters): Promise<number>;
  districtNames(ids: string[]): Promise<Map<string, { nameAr: string; nameEn: string }>>;
  consumeQuota(adminUid: string, nowMs: number, limit: number, windowMs: number): Promise<boolean>;
  audit(entry: AuditEntry): Promise<void>;
}

/** Thrown by a store when Firestore asks for a composite index it does not have. */
export class MissingIndexError extends Error {
  constructor() {
    super("missing index");
    this.name = "MissingIndexError";
  }
}

export interface SchoolSearchDeps {
  store: SchoolSearchStore;
  now: () => number;
  /** A missing index (degraded search). Never request data. */
  report: (problem: string) => Promise<void>;
}

/** Every equality filter Firestore can apply. */
export function serverFilters(req: SchoolSearchRequest): ServerFilters {
  const f: ServerFilters = {};
  if (req.status) f.status = req.status;
  // Every place level: a bookmarked area of another city (or district of
  // another area) then matches nothing, and count() agrees with the rows.
  if (req.governorate) f.governorate = req.governorate;
  if (req.placeAreaId) f.placeAreaId = req.placeAreaId;
  if (req.placeDistrictId) f.placeDistrictId = req.placeDistrictId;
  if (req.source) f.source = req.source;
  if (req.visibility === "hidden") f.hiddenOnly = true;
  if (req.plan && req.plan.grams.length > 0) f.anyGrams = req.plan.grams;
  return f;
}

/** One filter only, for when an index is missing: the grams, else the place, else the status. */
export function fallbackFilters(full: ServerFilters): ServerFilters {
  if (full.anyGrams) return { anyGrams: full.anyGrams };
  if (full.placeDistrictId) return { placeDistrictId: full.placeDistrictId };
  if (full.placeAreaId) return { placeAreaId: full.placeAreaId };
  if (full.governorate) return { governorate: full.governorate };
  if (full.hiddenOnly) return { hiddenOnly: true };
  if (full.status) return { status: full.status };
  if (full.source) return { source: full.source };
  return {};
}

/** Every filter of the request, checked in memory on each candidate. */
export function rowMatches(req: SchoolSearchRequest, row: SchoolRow): boolean {
  if (req.status && row.status !== req.status) return false;
  if (req.visibility === "in_search" && row.searchHidden) return false;
  if (req.visibility === "hidden" && !row.searchHidden) return false;
  if (req.governorate && row.governorate !== req.governorate) return false;
  if (req.placeAreaId && row.placeAreaId !== req.placeAreaId) return false;
  if (req.placeDistrictId && row.placeDistrictId !== req.placeDistrictId) return false;
  if (req.source && row.source !== req.source) return false;
  if (req.plan && !matchesQuery(req.plan.tokens, row.nameAr, row.nameEn)) return false;
  return true;
}

export interface SchoolSearchResult {
  schools: Array<SchoolRow & { placeDistrictNameAr: string; placeDistrictNameEn: string }>;
  nextAfterId: string | null;
  /** On the first page: how many schools match (null on later pages or when unknown). */
  total: number | null;
  /** false: [total] is a lower bound (the scan stopped at SCAN_CAP). */
  totalExact: boolean;
  /** true: an index was missing and the search ran with one filter. */
  degraded: boolean;
}

interface ScanOutcome {
  matches: SchoolRow[];
  nextAfterId: string | null;
  /** Matches counted beyond the page (text search, first page). */
  counted: number;
  exhausted: boolean;
}

async function scanPages(
  deps: SchoolSearchDeps,
  req: SchoolSearchRequest,
  filters: ServerFilters,
  countAll: boolean,
): Promise<ScanOutcome> {
  const matches: SchoolRow[] = [];
  let counted = 0;
  let scanned = 0;
  let cursor = req.afterId;
  let lastOnPage: string | null = null;
  let exhausted = false;
  for (;;) {
    const want = Math.min(SCAN_BATCH, SCAN_CAP - scanned);
    if (want <= 0) break;
    const batch = await deps.store.scan(filters, req.sort, cursor, want);
    scanned += batch.length;
    for (const row of batch) {
      cursor = row.id;
      if (!rowMatches(req, row)) continue;
      counted += 1;
      if (matches.length < PAGE_SIZE) {
        matches.push(row);
        lastOnPage = row.id;
      }
    }
    if (batch.length < want) {
      exhausted = true;
      break;
    }
    if (matches.length === PAGE_SIZE && !countAll) break;
  }
  let nextAfterId: string | null;
  if (matches.length < PAGE_SIZE) {
    // Stopped at the cap before the page filled: the next page goes on from the last school read.
    nextAfterId = exhausted ? null : cursor;
  } else {
    // A full page: the next one starts after its last school, unless nothing else matched.
    nextAfterId = exhausted && counted === matches.length ? null : lastOnPage;
  }
  return { matches, nextAfterId, counted, exhausted };
}

/**
 * { query?, includeAll?, status?, visibility?, governorate?, placeAreaId?,
 *   placeDistrictId?, source?, sort?: nameAr | nameEn, afterId? }
 * -> { schools, nextAfterId, total, totalExact, degraded }
 */
export async function searchSchools(
  deps: SchoolSearchDeps,
  caller: AdminCaller,
  data: unknown,
  ip: string | null,
): Promise<SchoolSearchResult> {
  const req = parseSearchRequest(data);
  const allowed = await deps.store.consumeQuota(caller.uid, deps.now(), SEARCH_LIMIT, SEARCH_WINDOW_MS);
  if (!allowed) throw new AdminError("rate-limited");

  const firstPage = req.afterId === null;
  const full = serverFilters(req);
  let filters = full;
  let degraded = false;
  let outcome: ScanOutcome;
  // Text: the first page goes on reading (up to SCAN_CAP) to count every match.
  try {
    outcome = await scanPages(deps, req, filters, firstPage && req.plan !== null);
  } catch (error) {
    if (!(error instanceof MissingIndexError)) throw error;
    degraded = true;
    filters = fallbackFilters(full);
    await deps.report(`adminSearchSchools: missing Firestore index for filters ${Object.keys(full).sort().join("+")}`);
    outcome = await scanPages(deps, req, filters, firstPage);
  }

  let total: number | null = null;
  let totalExact = false;
  if (firstPage) {
    if (req.plan) {
      total = outcome.counted;
      totalExact = outcome.exhausted;
    } else if (!degraded) {
      // Equality filters only: an exact count() aggregation, minus the hidden ones when they are left out.
      total = await deps.store.count(filters);
      if (req.visibility === "in_search") total -= await deps.store.count({ ...filters, hiddenOnly: true });
      totalExact = true;
    } else {
      total = outcome.counted;
      totalExact = outcome.exhausted;
    }
  }

  const districtIds = [...new Set(outcome.matches.map((s) => s.placeDistrictId).filter((id): id is string => !!id && DOC_ID.test(id)))];
  const names = districtIds.length > 0 ? await deps.store.districtNames(districtIds) : new Map<string, { nameAr: string; nameEn: string }>();

  if (firstPage) {
    await deps.store.audit({
      actorUid: caller.uid,
      action: "school.search",
      target: "schools",
      // Kinds of filters only: never the typed text.
      details: {
        text: req.text !== null,
        filters: Object.keys(full).filter((k) => k !== "anyGrams").sort().join(","),
        includeAll: req.includeAll,
        results: total ?? outcome.matches.length,
        degraded,
      },
      ip,
    });
  }

  return {
    schools: outcome.matches.map((s) => {
      const d = s.placeDistrictId ? names.get(s.placeDistrictId) : undefined;
      return { ...s, placeDistrictNameAr: d?.nameAr ?? "", placeDistrictNameEn: d?.nameEn ?? "" };
    }),
    nextAfterId: outcome.nextAfterId,
    total,
    totalExact,
    degraded,
  };
}

/**
 * The grams to write to a school after a write, or null when they are
 * right already (or the school was deleted). Every writer sets them; the
 * syncSchoolAdminGrams trigger repairs any writer that did not.
 */
export function gramsToWrite(after: Record<string, unknown> | undefined): string[] | null {
  if (!after) return null;
  const want = schoolSearchGrams(typeof after.nameAr === "string" ? after.nameAr : "", typeof after.nameEn === "string" ? after.nameEn : "");
  const have = after.adminSearchGrams;
  if (Array.isArray(have) && have.length === want.length && have.every((g, i) => g === want[i])) return null;
  return want;
}
