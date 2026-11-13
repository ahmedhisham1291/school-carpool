import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { describe, it } from "node:test";
import {
  AlgoliaRestClient,
  MAX_SEARCH_KEYS_PER_DAY,
  nextKeyQuota,
  SCHOOL_INDEX_SETTINGS,
  SEARCH_KEY_LIMITS,
  searchConfigProblem,
  searchUserToken,
  securedSearchKey,
  type KeyQuota,
} from "../src/schools/algolia";
import { issueSearchKey, SearchKeyError, type SearchKeyDeps } from "../src/schools/search_key";
import {
  parseImportedSchool,
  planImport,
  searchKeysFor,
  searchRecordFrom,
  syncAction,
  type ExistingSchool,
  type ImportedSchool,
} from "../src/schools/catalog";
import {
  addOtherSchool,
  MAX_PENDING_PER_PARENT,
  OtherSchoolError,
  parseOtherSchool,
  type OtherSchoolsStore,
  type PendingSchool,
} from "../src/schools/other";
import { normalizeText } from "../src/text/normalize";

const imported = (over: Partial<ImportedSchool> = {}): ImportedSchool => ({
  id: "osm-n1",
  source: "osm",
  sourceId: "n1",
  sourceKeys: ["osm:n1"],
  nameAr: "مدرسة النيل",
  nameEn: "Nile School",
  kind: "school",
  governorate: "cairo",
  city: "Maadi",
  cityAr: "المعادي",
  location: { lat: 29.96, lng: 31.25 },
  ...over,
});

const stored = (s: ImportedSchool, over: Partial<ExistingSchool> = {}): ExistingSchool => ({
  id: s.id,
  status: "active",
  adminEdited: false,
  sourceKeys: s.sourceKeys,
  nameAr: s.nameAr,
  nameEn: s.nameEn,
  kind: s.kind,
  governorate: s.governorate,
  city: s.city,
  cityAr: s.cityAr,
  location: s.location,
  ...over,
});

/** Applies a plan to an in-memory collection, like scripts/load_schools.ts does to Firestore. */
function apply(existing: ExistingSchool[], incoming: ImportedSchool[]): ExistingSchool[] {
  const plan = planImport(incoming, existing);
  const byId = new Map(existing.map((s) => [s.id, s]));
  for (const s of plan.creates) byId.set(s.id, stored(s));
  for (const u of plan.updates) byId.set(u.id, { ...stored(u.school), id: u.id, adminEdited: byId.get(u.id)!.adminEdited });
  return [...byId.values()];
}

describe("text normalization (same cases as the Python tool and the app)", () => {
  it("Arabic forms, diacritics, tatweel, digits", () => {
    assert.equal(normalizeText("مَدْرَسَةُ"), "مدرسه");
    assert.equal(normalizeText("أحمد إبراهيم آمال ٱلنور"), "احمد ابراهيم امال النور");
    assert.equal(normalizeText("مستشفى"), "مستشفي");
    assert.equal(normalizeText("مدرســـة"), "مدرسه");
    assert.equal(normalizeText("مدرسة ٦ أكتوبر"), "مدرسه 6 اكتوبر");
    assert.equal(normalizeText("  St. Mark's   College "), "st mark s college");
    assert.equal(normalizeText("مدرسة النيل الدولية"), normalizeText("مدرسه النيل الدوليه"));
  });

  it("search keys hold both names once", () => {
    assert.deepEqual(searchKeysFor("مدرسة النيل", "Nile School"), ["مدرسه النيل", "nile school"]);
    assert.deepEqual(searchKeysFor("Nile", "Nile"), ["nile"]);
  });
});

describe("schools import plan (idempotent)", () => {
  it("checks each school of schools.json", () => {
    const ok = parseImportedSchool({ ...imported(), sourceKeys: ["osm:w2", "osm:n1", "osm:n1"] });
    assert.deepEqual(ok.sourceKeys, ["osm:n1", "osm:w2"]);
    assert.equal(parseImportedSchool({ ...imported(), location: null, kind: "x" }).kind, "school");
    for (const bad of [{ id: "a/b" }, { governorate: "atlantis" }, { nameAr: "x" }, { nameEn: "" }, { source: "" }]) {
      assert.throws(() => parseImportedSchool({ ...imported(), ...bad }));
    }
  });

  it("creates new schools, then a second run of the same file writes nothing", () => {
    const input = [imported(), imported({ id: "osm-n2", sourceId: "n2", sourceKeys: ["osm:n2"], nameEn: "Pyramids School" })];
    const first = planImport(input, []);
    assert.equal(first.creates.length, 2);
    const after = apply([], input);
    const second = planImport(input, after);
    assert.deepEqual([second.creates.length, second.updates.length, second.unchanged], [0, 0, 2]);
    assert.deepEqual(apply(after, input), after);
  });

  it("finds a school by any source key when its primary entry changes", () => {
    const before = [stored(imported({ sourceKeys: ["osm:n1", "osm:w9"] }))];
    // Next run: a ministry list entry became the primary of the same group.
    const next = imported({ id: "list_moe-7", source: "list_moe", sourceId: "7", sourceKeys: ["list_moe:7", "osm:n1"] });
    const plan = planImport([next], before);
    assert.equal(plan.creates.length, 0);
    assert.equal(plan.updates[0].id, "osm-n1");
    assert.deepEqual(plan.updates[0].school.sourceKeys, ["list_moe:7", "osm:n1", "osm:w9"]);
  });

  it("updates changed fields, leaves admin edits, merged and parents' schools alone, never deletes", () => {
    const a = imported();
    const b = imported({ id: "osm-n2", sourceId: "n2", sourceKeys: ["osm:n2"] });
    const c = imported({ id: "osm-n3", sourceId: "n3", sourceKeys: ["osm:n3"] });
    const d = imported({ id: "osm-n4", sourceId: "n4", sourceKeys: ["osm:n4"] });
    const gone = imported({ id: "osm-n5", sourceId: "n5", sourceKeys: ["osm:n5"] });
    const existing = [
      stored(a),
      stored(b, { adminEdited: true, nameEn: "Fixed by admin" }),
      stored(c, { status: "merged" }),
      stored(gone),
      { ...stored(d), status: "awaiting_review" },
      { ...stored(imported({ id: "parent1" })), sourceKeys: [], status: "awaiting_review" },
    ];
    const plan = planImport([{ ...a, nameEn: "Nile School Maadi" }, b, c, d], existing);
    assert.deepEqual(plan.updates.map((u) => u.id), ["osm-n1"]);
    assert.deepEqual(plan.skipped, [
      { id: "osm-n2", reason: "admin-edited" },
      { id: "osm-n3", reason: "merged" },
      { id: "osm-n4", reason: "not-active" },
    ]);
    assert.deepEqual(plan.notInInput, ["osm-n5"]);
  });

  it("two entries of one run that point at the same school are written once", () => {
    const existing = [stored(imported({ sourceKeys: ["osm:n1", "osm:n2"] }))];
    const plan = planImport(
      [imported({ nameEn: "Changed" }), imported({ id: "osm-n2", sourceId: "n2", sourceKeys: ["osm:n2"], nameEn: "Other" })],
      existing,
    );
    assert.equal(plan.updates.length, 1);
    assert.deepEqual(plan.skipped, [{ id: "osm-n2", reason: "same-target" }]);
  });
});

describe("search index records and sync", () => {
  const data = (over: Record<string, unknown> = {}) => ({
    nameAr: "مدرسة النيل",
    nameEn: "Nile School",
    governorate: "cairo",
    city: "Maadi",
    cityAr: "المعادي",
    kind: "school",
    status: "active",
    location: { latitude: 29.96, longitude: 31.25 },
    addedBy: "parent-uid",
    source: "parent",
    sourceKeys: ["osm:n1"],
    adminEdited: true,
    ...over,
  });

  it("holds school names and places only, never anything about a parent", () => {
    const record = searchRecordFrom("s1", data())!;
    assert.deepEqual(Object.keys(record).sort(), ["_geoloc", "city", "cityAr", "governorate", "kind", "nameAr", "nameEn", "objectID", "searchKeys"]);
    assert.ok(!JSON.stringify(record).includes("parent-uid"));
    assert.deepEqual(record._geoloc, { lat: 29.96, lng: 31.25 });
    assert.equal(searchRecordFrom("s1", data({ status: "awaiting_review" })), null);
    assert.equal(searchRecordFrom("s1", data({ status: "merged" })), null);
    assert.equal(searchRecordFrom("s1", undefined), null);
    assert.equal(searchRecordFrom("s1", data({ location: null }))?._geoloc, undefined);
  });

  it("indexes active schools, removes the rest, skips writes that change nothing indexed", () => {
    assert.equal(syncAction("s1", undefined, data()).kind, "upsert");
    assert.equal(syncAction("s1", data(), data({ updatedAt: 2, adminEdited: false })).kind, "none");
    assert.equal(syncAction("s1", data(), data({ nameEn: "Nile Intl" })).kind, "upsert");
    assert.equal(syncAction("s1", data(), data({ status: "merged" })).kind, "delete");
    assert.equal(syncAction("s1", data(), undefined).kind, "delete");
    // A parent's "Other" school: not indexed until approved, then indexed.
    assert.equal(syncAction("s1", undefined, data({ status: "awaiting_review" })).kind, "none");
    assert.equal(syncAction("s1", data({ status: "awaiting_review" }), data({ addedBy: null })).kind, "upsert");
  });
});

describe("Algolia", () => {
  it("secured key: HMAC of the parameters with the parent key, limited to the index, an expiry and the user", () => {
    const token = searchUserToken("uid-alice");
    const key = securedSearchKey("parent-search-key", "schools_dev", 1_900_000_000, token);
    const decoded = Buffer.from(key, "base64").toString();
    const params = `restrictIndices=schools_dev&validUntil=1900000000&userToken=${token}`;
    assert.equal(decoded.slice(64), params);
    assert.equal(decoded.slice(0, 64), createHmac("sha256", "parent-search-key").update(params).digest("hex"));
    assert.ok(!decoded.includes("parent-search-key"));
    // The user token is a stable hash, never the uid itself.
    assert.match(token, /^[0-9a-f]{32}$/);
    assert.equal(token, searchUserToken("uid-alice"));
    assert.notEqual(token, searchUserToken("uid-bob"));
    assert.ok(!decoded.includes("uid-alice"));
    // Per-user limits fit the free month: 100 an hour, 6 keys a day.
    assert.ok(SEARCH_KEY_LIMITS.maxQueriesPerIPPerHour <= 200);
    assert.ok(SEARCH_KEY_LIMITS.maxQueriesPerIPPerHour * MAX_SEARCH_KEYS_PER_DAY <= 1000);
  });

  it("daily key quota per parent", () => {
    assert.deepEqual(nextKeyQuota(null, "2026-11-13"), { day: "2026-11-13", count: 1 });
    assert.deepEqual(nextKeyQuota({ day: "2026-11-13", count: 5 }, "2026-11-13"), { day: "2026-11-13", count: 6 });
    assert.equal(nextKeyQuota({ day: "2026-11-13", count: 6 }, "2026-11-13"), null);
    assert.deepEqual(nextKeyQuota({ day: "2026-11-12", count: 6 }, "2026-11-13"), { day: "2026-11-13", count: 1 });
  });

  it("issues keys tied to the parent, refuses over the daily cap, and refuses the fake search in prod", async () => {
    const quota = new Map<string, KeyQuota>();
    const problems: string[] = [];
    const deps = (over: Partial<SearchKeyDeps> = {}): SearchKeyDeps => ({
      provider: "algolia",
      appEnv: "staging",
      appId: "APP",
      parentSearchKey: "parent",
      indexName: "schools_staging",
      nowMs: Date.UTC(2026, 10, 13, 10),
      consumeQuota: async (uid, today) => {
        const next = nextKeyQuota(quota.get(uid) ?? null, today);
        if (!next) return false;
        quota.set(uid, next);
        return true;
      },
      reportProblem: async (p) => {
        problems.push(p);
      },
      ...over,
    });
    const first = await issueSearchKey(deps(), "alice");
    assert.equal(first.provider, "algolia");
    if (first.provider !== "algolia") return;
    assert.ok(Buffer.from(first.key, "base64").toString().includes(`userToken=${searchUserToken("alice")}`));
    assert.equal(first.validUntil, Date.UTC(2026, 10, 13, 10) / 1000 + 3600);
    for (let i = 1; i < MAX_SEARCH_KEYS_PER_DAY; i++) await issueSearchKey(deps(), "alice");
    await assert.rejects(issueSearchKey(deps(), "alice"), (e: unknown) => e instanceof SearchKeyError && e.reason === "search-limit");
    // Another parent is not affected; the next Cairo day starts again.
    assert.equal((await issueSearchKey(deps(), "bob")).provider, "algolia");
    assert.equal((await issueSearchKey(deps({ nowMs: Date.UTC(2026, 10, 14, 10) }), "alice")).provider, "algolia");

    assert.deepEqual(await issueSearchKey(deps({ provider: "fake", appEnv: "dev" }), "alice"), { provider: "fake" });
    assert.deepEqual(await issueSearchKey(deps({ provider: "fake", appEnv: "staging" }), "alice"), { provider: "fake" });
    await assert.rejects(
      issueSearchKey(deps({ provider: "fake", appEnv: "prod" }), "alice"),
      (e: unknown) => e instanceof SearchKeyError && e.reason === "search-misconfigured",
    );
    await assert.rejects(issueSearchKey(deps({ parentSearchKey: "" }), "alice"), (e: unknown) => e instanceof SearchKeyError);
    await assert.rejects(issueSearchKey(deps({ provider: "elastic" }), "alice"), (e: unknown) => e instanceof SearchKeyError);
    assert.equal(problems.length, 3);
    assert.match(problems[0], /not allowed in prod/);
    assert.equal(searchConfigProblem("algolia", "prod"), null);
  });

  it("REST calls carry the keys in headers and only the record", async () => {
    const calls: Array<{ url: string; method: string; headers: Record<string, string>; body?: string }> = [];
    let status = 200;
    const fake = async (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => {
      calls.push({ url, ...init });
      return { ok: status < 300, status, text: async () => "" };
    };
    const client = new AlgoliaRestClient("APPID", "write-key", "schools", fake);
    const record = searchRecordFrom("osm-n1", { nameAr: "مدرسة", nameEn: "Nile School", status: "active", governorate: "cairo" })!;
    await client.save(record);
    assert.equal(calls[0].url, "https://APPID.algolia.net/1/indexes/schools/osm-n1");
    assert.equal(calls[0].method, "PUT");
    assert.equal(calls[0].headers["X-Algolia-API-Key"], "write-key");
    assert.deepEqual(JSON.parse(calls[0].body!), record);
    status = 404;
    await client.remove("osm-n1"); // already gone: fine
    await assert.rejects(client.save(record), /Algolia PUT failed with 404/);
    status = 200;
    await client.setSettings();
    assert.deepEqual(JSON.parse(calls.at(-1)!.body!), SCHOOL_INDEX_SETTINGS);
    assert.ok(SCHOOL_INDEX_SETTINGS.attributesForFaceting.includes("filterOnly(governorate)"));
  });
});

class MemoryOtherStore implements OtherSchoolsStore {
  private counter = 0;
  readonly schools: PendingSchool[] = [];
  readonly accounts = new Map<string, "suspended" | "ok">([["alice", "ok"], ["sam", "suspended"]]);
  newId() {
    this.counter++;
    return `p${this.counter}`;
  }
  async accountState(uid: string) {
    return this.accounts.get(uid) ?? "missing";
  }
  async pendingOf(uid: string, limit: number) {
    return this.schools.filter((s) => s.addedBy === uid).slice(0, limit);
  }
  async create(school: PendingSchool) {
    this.schools.push(school);
  }
}

describe('"Other" school (parent)', () => {
  const reason = (r: string) => (e: unknown) => e instanceof OtherSchoolError && e.reason === r;

  it("checks the name, governorate and optional pin", () => {
    assert.deepEqual(parseOtherSchool({ name: "  مدرسة   الزهور ", governorate: "giza" }), {
      name: "مدرسة الزهور",
      governorate: "giza",
      location: null,
    });
    assert.deepEqual(parseOtherSchool({ name: "Zohour School", governorate: "cairo", location: { lat: 30.123456, lng: 31.2 } }).location, {
      lat: 30.12346,
      lng: 31.2,
    });
    assert.throws(() => parseOtherSchool({ name: "ab", governorate: "cairo" }), reason("invalid-name"));
    assert.throws(() => parseOtherSchool({ name: "<script>", governorate: "cairo" }), reason("invalid-name"));
    assert.throws(() => parseOtherSchool({ name: "...", governorate: "cairo" }), reason("invalid-name"));
    assert.throws(() => parseOtherSchool({ name: "x".repeat(121), governorate: "cairo" }), reason("invalid-name"));
    assert.throws(() => parseOtherSchool({ name: "Zohour", governorate: "Cairo" }), reason("invalid-governorate"));
    assert.throws(() => parseOtherSchool({ name: "Zohour", governorate: "cairo", location: { lat: 48.8, lng: 2.3 } }), reason("invalid-location"));
    assert.throws(() => parseOtherSchool({ name: "Zohour", governorate: "cairo", location: { lat: "30" } }), reason("invalid-location"));
  });

  it("saves it awaiting review for that parent; the same name again returns it", async () => {
    const store = new MemoryOtherStore();
    const deps = { store, now: () => 1000 };
    const first = await addOtherSchool(deps, "alice", { name: "مدرسة الزهور", governorate: "cairo" });
    assert.deepEqual(first, { id: "p1", nameAr: "مدرسة الزهور", nameEn: "مدرسة الزهور", governorate: "cairo", status: "awaiting_review" });
    assert.equal(store.schools[0].addedBy, "alice");
    const again = await addOtherSchool(deps, "alice", { name: "مدرسه الزهور", governorate: "cairo" });
    assert.equal(again.id, "p1");
    assert.equal(store.schools.length, 1);
    // Another governorate is another school.
    assert.equal((await addOtherSchool(deps, "alice", { name: "مدرسة الزهور", governorate: "giza" })).id, "p2");
  });

  it("refuses unknown and suspended accounts, and more than the pending limit", async () => {
    const store = new MemoryOtherStore();
    const deps = { store, now: () => 1000 };
    await assert.rejects(addOtherSchool(deps, "nobody", { name: "Zohour", governorate: "cairo" }), reason("no-account"));
    await assert.rejects(addOtherSchool(deps, "sam", { name: "Zohour", governorate: "cairo" }), reason("suspended"));
    for (let i = 0; i < MAX_PENDING_PER_PARENT; i++) await addOtherSchool(deps, "alice", { name: `School number ${i}`, governorate: "cairo" });
    await assert.rejects(addOtherSchool(deps, "alice", { name: "One more school", governorate: "cairo" }), reason("too-many-pending"));
    // A retry of one already waiting still answers.
    assert.equal((await addOtherSchool(deps, "alice", { name: "School number 0", governorate: "cairo" })).id, "p1");
  });
});
