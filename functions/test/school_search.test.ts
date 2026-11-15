// Admin panel schools search (F14): adminSearchSchools.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { AdminError, type AdminErrorReason } from "../src/admin_panel/errors";
import type { AdminCaller } from "../src/admin_panel/guard";
import {
  editDistance,
  fallbackFilters,
  gramsToWrite,
  matchesQuery,
  MissingIndexError,
  PAGE_SIZE,
  parseSearchRequest,
  planQuery,
  SCAN_CAP,
  schoolSearchGrams,
  searchSchools,
  serverFilters,
  tokenMatchesWord,
  type SchoolRow,
  type SchoolSearchDeps,
  type SchoolSearchStore,
  type ServerFilters,
  type SortField,
} from "../src/admin_panel/school_search";
import type { AuditEntry } from "../src/admin_panel/types";

const ADMIN: AdminCaller = { uid: "admin1", role: "admin" };
const expectReason = (reason: AdminErrorReason) => (error: unknown) =>
  error instanceof AdminError && error.reason === reason;

function row(id: string, over: Partial<SchoolRow> = {}): SchoolRow & { grams: string[] } {
  const base: SchoolRow = {
    id,
    nameAr: `مدرسة ${id}`,
    nameEn: `School ${id}`,
    governorate: "cairo",
    city: "",
    location: null,
    status: "active",
    source: "osm",
    searchHidden: false,
    placeAreaId: "",
    placeAreaNameAr: "",
    placeAreaNameEn: "",
    placeDistrictId: null,
    ...over,
  };
  return { ...base, grams: schoolSearchGrams(base.nameAr, base.nameEn) };
}

/** Firestore stand-in: equality filters and array-contains-any, ordered by name then ID. */
class MemorySearchStore implements SchoolSearchStore {
  readonly audits: AuditEntry[] = [];
  readonly scans: ServerFilters[] = [];
  reads = 0;
  quota = 0;
  quotaLimitHit = false;
  /** Firestore without the merged indexes: more than one filter fails. */
  oneFilterOnly = false;
  readonly districts = new Map([["d1", { nameAr: "دجلة", nameEn: "Degla" }]]);

  constructor(readonly rows: Array<SchoolRow & { grams: string[] }>) {}

  private match(f: ServerFilters) {
    if (this.oneFilterOnly && Object.keys(f).length > 1) throw new MissingIndexError();
    return this.rows.filter(
      (r) =>
        (!f.status || r.status === f.status) &&
        (!f.governorate || r.governorate === f.governorate) &&
        (!f.placeAreaId || r.placeAreaId === f.placeAreaId) &&
        (!f.placeDistrictId || r.placeDistrictId === f.placeDistrictId) &&
        (!f.source || r.source === f.source) &&
        (!f.hiddenOnly || r.searchHidden) &&
        (!f.anyGrams || f.anyGrams.some((g) => r.grams.includes(g))),
    );
  }

  async scan(f: ServerFilters, sort: SortField, afterId: string | null, limit: number) {
    this.scans.push(f);
    const all = this.match(f).sort((a, b) => (a[sort] < b[sort] ? -1 : a[sort] > b[sort] ? 1 : a.id < b.id ? -1 : 1));
    const start = afterId ? all.findIndex((r) => r.id === afterId) + 1 : 0;
    const out = all.slice(start, start + limit).map(({ grams: _g, ...r }) => r);
    this.reads += out.length;
    return out;
  }

  async count(f: ServerFilters) {
    return this.match(f).length;
  }

  async districtNames(ids: string[]) {
    return new Map([...this.districts].filter(([id]) => ids.includes(id)));
  }

  async consumeQuota() {
    this.quota += 1;
    return !this.quotaLimitHit;
  }

  async audit(entry: AuditEntry) {
    this.audits.push(entry);
  }
}

function deps(store: MemorySearchStore, reports: string[] = []): SchoolSearchDeps {
  return { store, now: () => 1_000, report: async (p) => void reports.push(p) };
}

const SCHOOLS = [
  row("s1", { nameAr: "مدرسة النصر للغات", nameEn: "El Nasr Language School", placeAreaId: "a1", placeDistrictId: "d1" }),
  row("s2", { nameAr: "مدرسة الزهراء الدولية", nameEn: "Al Zahraa International School", placeAreaId: "a1" }),
  row("s3", { nameAr: "روضة الأمل", nameEn: "Al Amal Kindergarten", governorate: "giza", placeAreaId: "a9" }),
  row("s4", { nameAr: "مدرسة سان فاتيما", nameEn: "Saint Fatima School", status: "awaiting_review", source: "parent" }),
  row("s5", { nameAr: "مدرسة العينة", nameEn: "Sample School", searchHidden: true, source: "list_sample" }),
  row("s6", { nameAr: "مدرسة قديمة", nameEn: "Old School", status: "merged" }),
];

describe("school search: text", () => {
  it("grams cover the word starts, the second-letter start and the word without ال", () => {
    const grams = schoolSearchGrams("مدرسة النصر", "Nasr School");
    for (const g of ["مدر", "درس", "الن", "لنص", "نصر", "nas", "asr", "sch"]) assert.ok(grams.includes(g), g);
    assert.deepEqual(grams, [...grams].sort());
  });

  it("Arabic spelling variants match: ة/ه, ى/ي, أ/إ/ا, diacritics", () => {
    assert.ok(matchesQuery(planQuery("مدرسه الزهراء الدوليه")!.tokens, "مدرسة الزهراء الدولية", ""));
    assert.ok(matchesQuery(planQuery("الامل")!.tokens, "روضة الأمل", ""));
    assert.ok(matchesQuery(planQuery("إسلامي")!.tokens, "مدرسة اسلامى", ""));
    assert.ok(matchesQuery(planQuery("مَدْرَسَة")!.tokens, "مدرسة النور", ""));
    assert.ok(matchesQuery(planQuery("نصر")!.tokens, "مدرسة النصر", ""), "without ال");
  });

  it("small typos are tolerated by word length; short words must match exactly", () => {
    assert.equal(editDistance("fatima", "fatmia", 2), 1, "swap");
    assert.ok(tokenMatchesWord("fatma", "fatima"), "missing letter");
    assert.ok(tokenMatchesWord("intrnational", "international"));
    assert.ok(tokenMatchesWord("zahra", "zahraa"));
    assert.ok(!tokenMatchesWord("abc", "abd"), "3 letters: no typo");
    assert.ok(!tokenMatchesWord("nasr", "zamalek"));
    assert.ok(tokenMatchesWord("lang", "language"), "prefix");
  });

  it("query grams prefer rare words and stay within Firestore's 30", () => {
    const plan = planQuery("مدرسة النصر")!;
    assert.ok(plan.grams.includes("نصر"));
    assert.ok(!plan.grams.includes("مدر"), "the common word is matched in memory only");
    assert.ok(planQuery("مدرسة")!.grams.includes("مدر"), "a common word alone is still searched");
    assert.ok(planQuery("a b c d e f g h i j k l m n o p q r s t u v w x y z aa bb cc dd ee ff gg hh ii jj kk ll")!.grams.length <= 30);
    assert.equal(planQuery("  ،، "), null);
  });

  it("finds a school by Arabic or English name, with typos and variants", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const ids = async (query: string, extra: object = {}) =>
      (await searchSchools(deps(store), ADMIN, { query, ...extra }, null)).schools.map((s) => s.id);
    assert.deepEqual(await ids("النصر"), ["s1"]);
    assert.deepEqual(await ids("nasr"), ["s1"]);
    assert.deepEqual(await ids("Zahra internatonal"), ["s2"]);
    assert.deepEqual(await ids("مدرسه الزهراء"), ["s2"]);
    assert.deepEqual(await ids("Bnasr"), ["s1"], "a wrong first letter is found through the second gram");
    assert.deepEqual(await ids("fatima"), [], "awaiting review: not without includeAll");
    assert.deepEqual(await ids("fatima", { includeAll: true }), ["s4"]);
  });
});

describe("school search: filters", () => {
  it("by default shows what parents can find: active and not hidden", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const res = await searchSchools(deps(store), ADMIN, {}, null);
    assert.deepEqual(res.schools.map((s) => s.id).sort(), ["s1", "s2", "s3"]);
    assert.equal(res.total, 3);
    assert.equal(res.totalExact, true);
    assert.equal(res.nextAfterId, null);
  });

  it("includeAll shows hidden, sample, unapproved and merged schools; status and visibility narrow it", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const ids = async (data: object) => (await searchSchools(deps(store), ADMIN, data, null)).schools.map((s) => s.id).sort();
    assert.deepEqual(await ids({ includeAll: true }), ["s1", "s2", "s3", "s4", "s5", "s6"]);
    assert.deepEqual(await ids({ includeAll: true, status: "awaiting_review" }), ["s4"]);
    assert.deepEqual(await ids({ includeAll: true, visibility: "hidden" }), ["s5"]);
    assert.deepEqual(await ids({ includeAll: true, visibility: "in_search", status: "active" }), ["s1", "s2", "s3"]);
    assert.deepEqual(await ids({ includeAll: true, source: "parent" }), ["s4"]);
    // Without includeAll the status and visibility filters are ignored.
    assert.deepEqual(await ids({ status: "merged", visibility: "hidden" }), ["s1", "s2", "s3"]);
  });

  it("City -> Area -> District filters combine with each other and with text", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const ids = async (data: object) => (await searchSchools(deps(store), ADMIN, data, null)).schools.map((s) => s.id).sort();
    assert.deepEqual(await ids({ governorate: "giza" }), ["s3"]);
    assert.deepEqual(await ids({ governorate: "cairo", placeAreaId: "a1" }), ["s1", "s2"]);
    assert.deepEqual(await ids({ governorate: "cairo", placeAreaId: "a1", placeDistrictId: "d1" }), ["s1"]);
    assert.deepEqual(await ids({ governorate: "cairo", placeAreaId: "a1", query: "zahraa" }), ["s2"]);
    assert.deepEqual(await ids({ governorate: "giza", query: "zahraa" }), []);
    // Only the most specific place goes to Firestore; the rest is checked in memory.
    assert.deepEqual(serverFilters(parseSearchRequest({ governorate: "cairo", placeAreaId: "a1", placeDistrictId: "d1" })), {
      status: "active",
      placeDistrictId: "d1",
    });
  });

  it("rows carry the district's names", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const res = await searchSchools(deps(store), ADMIN, { query: "nasr" }, null);
    assert.equal(res.schools[0].placeDistrictNameEn, "Degla");
    assert.equal(res.schools[0].placeDistrictNameAr, "دجلة");
  });

  it("sorts by the Arabic or the English name", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const en = (await searchSchools(deps(store), ADMIN, { sort: "nameEn" }, null)).schools.map((s) => s.nameEn);
    assert.deepEqual(en, [...en].sort());
    const ar = (await searchSchools(deps(store), ADMIN, { sort: "nameAr" }, null)).schools.map((s) => s.nameAr);
    assert.deepEqual(ar, [...ar].sort());
  });

  it("refuses bad input", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const bad = [
      { status: "deleted" },
      { visibility: "secret" },
      { governorate: "atlantis" },
      { placeAreaId: "a1" },
      { governorate: "cairo", placeDistrictId: "d1" },
      { governorate: "cairo", placeAreaId: "../x" },
      { source: "DROP TABLE" },
      { sort: "createdAt" },
      { query: "x".repeat(81) },
      { query: 5 },
      [],
    ];
    for (const data of bad) await assert.rejects(searchSchools(deps(store), ADMIN, data, null), expectReason("invalid-request"), JSON.stringify(data));
  });
});

describe("school search: paging, counts, audit, limits", () => {
  const many = Array.from({ length: 130 }, (_, i) => row(`m${String(i).padStart(3, "0")}`, { nameEn: `Nile ${String(i).padStart(3, "0")}`, searchHidden: i % 10 === 0 }));

  it("pages of 50 by cursor; the count is exact and leaves hidden schools out", async () => {
    const store = new MemorySearchStore(many);
    const first = await searchSchools(deps(store), ADMIN, { sort: "nameEn" }, null);
    assert.equal(first.schools.length, PAGE_SIZE);
    assert.equal(first.total, 117);
    assert.equal(first.totalExact, true);
    const seen = new Set(first.schools.map((s) => s.id));
    let next = first.nextAfterId;
    while (next) {
      const page = await searchSchools(deps(store), ADMIN, { sort: "nameEn", afterId: next }, null);
      assert.equal(page.total, null, "later pages do not count again");
      for (const s of page.schools) {
        assert.ok(!seen.has(s.id));
        seen.add(s.id);
      }
      next = page.nextAfterId;
    }
    assert.equal(seen.size, 117);
  });

  it("a text search counts every match on the first page", async () => {
    const store = new MemorySearchStore(many);
    const res = await searchSchools(deps(store), ADMIN, { query: "nile", includeAll: true }, null);
    assert.equal(res.schools.length, PAGE_SIZE);
    assert.equal(res.total, 130);
    assert.equal(res.totalExact, true);
    assert.ok(res.nextAfterId);
  });

  it("a scan stops at SCAN_CAP reads and says the count is a lower bound", async () => {
    const big = Array.from({ length: SCAN_CAP + 100 }, (_, i) => row(`b${String(i).padStart(4, "0")}`, { nameEn: `Nile ${i}` }));
    const store = new MemorySearchStore(big);
    const res = await searchSchools(deps(store), ADMIN, { query: "nile" }, null);
    assert.ok(store.reads <= SCAN_CAP);
    assert.equal(res.total, SCAN_CAP);
    assert.equal(res.totalExact, false);
  });

  it("the first page is audited with kinds of filters only, never the text", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    const res = await searchSchools(deps(store), ADMIN, { query: "النصر", governorate: "cairo" }, "1.2.3.4");
    await searchSchools(deps(store), ADMIN, { query: "النصر", afterId: "s1" }, null);
    assert.equal(store.audits.length, 1);
    const entry = store.audits[0];
    assert.equal(entry.action, "school.search");
    assert.equal(entry.actorUid, "admin1");
    assert.deepEqual(entry.details, { text: true, filters: "governorate,status", includeAll: false, results: res.total, degraded: false });
    assert.ok(!JSON.stringify(entry).includes("النصر"));
  });

  it("is rate limited per admin", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    store.quotaLimitHit = true;
    await assert.rejects(searchSchools(deps(store), ADMIN, {}, null), expectReason("rate-limited"));
    assert.equal(store.reads, 0);
  });

  it("a missing index degrades to one Firestore filter, checks the rest in memory and reports it", async () => {
    const store = new MemorySearchStore(SCHOOLS);
    store.oneFilterOnly = true;
    const reports: string[] = [];
    const res = await searchSchools(deps(store, reports), ADMIN, { governorate: "cairo", placeAreaId: "a1", query: "zahraa" }, null);
    assert.deepEqual(res.schools.map((s) => s.id), ["s2"]);
    assert.equal(res.degraded, true);
    assert.equal(reports.length, 1);
    assert.ok(!reports[0].includes("zahraa"), "never the text");
    assert.deepEqual(fallbackFilters({ status: "active", placeAreaId: "a1", anyGrams: ["zah"] }), { anyGrams: ["zah"] });
  });
});

describe("school search: grams upkeep", () => {
  it("writes grams only when missing or stale", () => {
    const grams = schoolSearchGrams("مدرسة النصر", "Nasr");
    assert.deepEqual(gramsToWrite({ nameAr: "مدرسة النصر", nameEn: "Nasr" }), grams);
    assert.equal(gramsToWrite({ nameAr: "مدرسة النصر", nameEn: "Nasr", adminSearchGrams: grams }), null);
    assert.deepEqual(gramsToWrite({ nameAr: "مدرسة النور", nameEn: "Nasr", adminSearchGrams: grams }), schoolSearchGrams("مدرسة النور", "Nasr"));
    assert.equal(gramsToWrite(undefined), null);
  });
});

describe("adminSearchSchools callable: admin claim required", () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const fn = require("../src/admin_panel/callables").adminSearchSchools as (r: unknown) => Promise<unknown>;
  const isCode = (code: string) => (e: unknown) => (e as { code?: string }).code === code;

  it("refuses a signed-out caller", async () => {
    await assert.rejects(fn({ data: {}, rawRequest: { headers: {} } }), isCode("unauthenticated"));
  });

  it("refuses a signed-in parent without the admin claim", async () => {
    const nowS = Math.floor(Date.now() / 1000);
    await assert.rejects(
      fn({ auth: { uid: "parent1", token: { verified: true, auth_time: nowS } }, data: {}, rawRequest: { headers: {} } }),
      isCode("permission-denied"),
    );
  });

  it("is exported from index.ts", () => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { readFileSync } = require("node:fs") as typeof import("node:fs");
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { join } = require("node:path") as typeof import("node:path");
    const index = readFileSync(join(__dirname, "..", "..", "src", "index.ts"), "utf8");
    assert.match(index, /\badminSearchSchools,/);
    assert.match(index, /\bsyncSchoolAdminGrams\b/);
  });
});
