import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  distanceKm,
  encodeGeohash,
  geohashCellDeg,
  geohashCoverPrefixes,
  GRID_DEG,
  inEgypt,
  JITTER_MAX_M,
  jitterFor,
  MAX_RANGES,
  RADIUS_CHOICES_KM,
  roundToGrid,
  STORED_GEOHASH_PRECISION,
  type LatLng,
} from "../src/maps/geo";
import { takeFromWindow } from "../src/maps/limits";
import {
  DEFAULT_MAP_LIMITS,
  MapError,
  MAX_DRIVING_SCHOOLS,
  parseMapSettings,
  parseNearby,
  parseSetHome,
  refreshPublicLocation,
  searchNearby,
  setDrivingSchools,
  setHome,
  takePlaceSearch,
  updateMapSettings,
  type MapDeps,
} from "../src/maps/parent_map";
import {
  autocomplete,
  FakePlacesProvider,
  GooglePlacesProvider,
  parseAutocomplete,
  placeDetails,
  type PlaceDetails,
  type PlacesProvider,
} from "../src/maps/places";
import { mapRefreshNeeded } from "../src/maps/sync";
import { MemoryMapStore, MemoryPlaceCache } from "./helpers/memory_maps";

const HOUR = 3_600_000;

// Fake homes in Maadi (Cairo). Exact points with 5 decimals, never on a grid line.
const ALICE: LatLng = { lat: 29.96123, lng: 31.25671 };
const BOB: LatLng = { lat: 29.96788, lng: 31.26244 }; // about 1 km from Alice
const CARA: LatLng = { lat: 29.95511, lng: 31.24987 }; // about 1 km the other way
const DINA: LatLng = { lat: 30.06261, lng: 31.21973 }; // Zamalek, about 12 km away

function setup(): { deps: MapDeps; store: MemoryMapStore; clock: { now: number } } {
  const store = new MemoryMapStore();
  const clock = { now: Date.UTC(2026, 10, 13, 8) };
  for (const [uid, name] of [["alice", "Alice"], ["bob", "Bob"], ["cara", "Cara"], ["dina", "Dina"], ["eve", "Eve"]] as const) {
    store.accounts.set(uid, { status: "verified", firstName: name });
    store.children.set(uid, ["nile"]);
  }
  for (const id of ["nile", "orman", "victoria", "s4", "s5", "s6"]) {
    store.schoolList.set(id, { id, nameAr: `مدرسة ${id}`, nameEn: `School ${id}`, status: "active" });
  }
  store.schoolList.set("merged1", { id: "merged1", nameAr: "x", nameEn: "x", status: "merged" });
  return { deps: { store, now: () => clock.now, limits: DEFAULT_MAP_LIMITS }, store, clock };
}

async function expectMapError(promise: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(promise, (e: unknown) => e instanceof MapError && e.reason === reason);
}

/** Every number with 4 or more decimals in a JSON text. */
function preciseNumbers(json: string): number[] {
  return (json.match(/-?\d+\.\d{4,}/g) ?? []).map(Number);
}

function metersBetween(a: LatLng, b: LatLng): number {
  return distanceKm(a, b) * 1000;
}

describe("geo: rounding to about 500 m", () => {
  it("snaps every point of a cell to the same centre, so the exact point cannot be recovered", () => {
    const a = roundToGrid({ lat: 29.96001, lng: 31.25501 });
    const b = roundToGrid({ lat: 29.96499, lng: 31.25999 });
    assert.deepEqual(a, b);
    assert.deepEqual(a, { lat: 29.9625, lng: 31.2575 });
    assert.deepEqual(roundToGrid(a), a, "rounding is idempotent");
  });

  it("keeps the rounded point within one cell (about 500 m) of the real one", () => {
    for (let i = 0; i < 500; i++) {
      const p = { lat: 22 + Math.random() * 9, lng: 25 + Math.random() * 11 };
      const r = roundToGrid(p);
      assert.ok(Math.abs(r.lat - p.lat) <= GRID_DEG / 2 + 1e-9);
      assert.ok(Math.abs(r.lng - p.lng) <= GRID_DEG / 2 + 1e-9);
      assert.ok(metersBetween(p, r) < 400);
    }
  });

  it("has cells of about 500 m in Egypt", () => {
    const c = { lat: 30.0, lng: 31.2 };
    const ns = metersBetween(c, { lat: c.lat + GRID_DEG, lng: c.lng });
    const ew = metersBetween(c, { lat: c.lat, lng: c.lng + GRID_DEG });
    assert.ok(ns > 500 && ns < 600, `north-south ${ns}`);
    assert.ok(ew > 450 && ew < 550, `east-west ${ew}`);
  });
});

describe("geo: geohash", () => {
  it("encodes the reference points", () => {
    assert.equal(encodeGeohash({ lat: 57.64911, lng: 10.40744 }, 11), "u4pruydqqvj");
    assert.equal(encodeGeohash({ lat: 0, lng: 0 }, 5), "s0000");
    assert.equal(encodeGeohash({ lat: 30.0444, lng: 31.2357 }, 5), "stq4y");
  });

  it("gives cell sizes per precision", () => {
    const p5 = geohashCellDeg(5);
    assert.ok(Math.abs(p5.lat - 0.0439453125) < 1e-12);
    assert.ok(Math.abs(p5.lng - 0.0439453125) < 1e-12);
    const p6 = geohashCellDeg(6);
    assert.ok(Math.abs(p6.lat - 0.0054931640625) < 1e-12);
    assert.ok(Math.abs(p6.lng - 0.010986328125) < 1e-12);
  });

  it("covers every point inside the radius with at most 9 ranges", () => {
    for (const radius of RADIUS_CHOICES_KM) {
      for (let i = 0; i < 40; i++) {
        const center = roundToGrid({ lat: 23 + Math.random() * 8, lng: 26 + Math.random() * 9 });
        const prefixes = geohashCoverPrefixes(center, radius);
        assert.ok(prefixes.length >= 1 && prefixes.length <= MAX_RANGES, `${prefixes.length} ranges`);
        for (let j = 0; j < 60; j++) {
          const angle = Math.random() * 2 * Math.PI;
          const km = Math.random() * radius;
          const p = roundToGrid({
            lat: center.lat + (km / 111.32) * Math.cos(angle),
            lng: center.lng + (km / (111.32 * Math.cos((center.lat * Math.PI) / 180))) * Math.sin(angle),
          });
          if (distanceKm(center, p) > radius) continue;
          const hash = encodeGeohash(p, STORED_GEOHASH_PRECISION);
          assert.ok(prefixes.some((pre) => hash.startsWith(pre)), `point ${hash} not covered by ${prefixes}`);
        }
      }
    }
  });
});

describe("geo: marker offset", () => {
  it("is the same every time, at most 150 m, and stays inside the rounded cell", () => {
    const cell = roundToGrid(ALICE);
    for (const uid of ["alice", "bob", "a-very-long-uid-0123456789"]) {
      const a = jitterFor(uid, cell);
      assert.deepEqual(jitterFor(uid, cell), a);
      assert.ok(metersBetween(a, cell) <= JITTER_MAX_M + 1);
      assert.deepEqual(roundToGrid(a), cell);
    }
    assert.notDeepEqual(jitterFor("alice", cell), jitterFor("bob", cell));
  });

  it("knows Egypt's box", () => {
    assert.ok(inEgypt(ALICE));
    assert.ok(!inEgypt({ lat: 48.85, lng: 2.35 }));
  });
});

describe("limits", () => {
  it("counts in a fixed window and opens a new one after it", () => {
    const rule = { windowMs: HOUR, max: 2 };
    const t0 = 1_000_000;
    const a = takeFromWindow(undefined, t0, rule);
    assert.ok(a.allowed);
    const b = takeFromWindow(a.next, t0 + 10, rule);
    assert.ok(b.allowed);
    const c = takeFromWindow(b.next, t0 + 20, rule);
    assert.ok(!c.allowed);
    assert.equal(c.retryAfterMs, HOUR - 20);
    const d = takeFromWindow(b.next, t0 + HOUR, rule);
    assert.ok(d.allowed);
    assert.equal(d.next.count, 1);
  });
});

describe("home (F21)", () => {
  it("keeps the exact point private and puts only the rounded point (and its geohash) in the public record", async () => {
    const { deps, store } = setup();
    const result = await setHome(deps, "alice", { location: ALICE, label: "Road 9, Maadi" });
    assert.deepEqual(store.homes.get("alice")?.location, ALICE);
    assert.equal(store.homes.get("alice")?.label, "Road 9, Maadi");
    const pub = store.publics.get("alice");
    assert.ok(pub);
    assert.deepEqual(pub.point, roundToGrid(ALICE));
    assert.deepEqual(result.approximate, roundToGrid(ALICE));
    assert.notDeepEqual(pub.point, ALICE);
    assert.equal(pub.geohash, encodeGeohash(roundToGrid(ALICE), STORED_GEOHASH_PRECISION));
    // Nothing in the public record carries the address or the exact numbers.
    const json = JSON.stringify(pub);
    assert.ok(!json.includes("Maadi"));
    assert.ok(!json.includes(String(ALICE.lat)) && !json.includes(String(ALICE.lng)));
  });

  it("refuses points outside Egypt and bad input", async () => {
    const { deps } = setup();
    await expectMapError(setHome(deps, "alice", { location: { lat: 48.85, lng: 2.35 } }), "outside-egypt");
    await expectMapError(setHome(deps, "alice", { location: { lat: "30", lng: 31 } }), "invalid-location");
    await expectMapError(setHome(deps, "alice", {}), "invalid-location");
    await expectMapError(setHome(deps, "alice", { location: { lat: Number.NaN, lng: 31 } }), "invalid-location");
    assert.equal(parseSetHome({ location: ALICE, label: "x".repeat(500) }).label.length, 200);
  });

  it("limits home moves per day; saving the same place again is not counted", async () => {
    const { deps, clock } = setup();
    for (let i = 0; i < DEFAULT_MAP_LIMITS.homeMovesPerDay; i++) {
      await setHome(deps, "alice", { location: { lat: ALICE.lat + i * 0.01, lng: ALICE.lng } });
    }
    const last = { lat: ALICE.lat + (DEFAULT_MAP_LIMITS.homeMovesPerDay - 1) * 0.01, lng: ALICE.lng };
    await setHome(deps, "alice", { location: last, label: "same place, new text" });
    await assert.rejects(
      setHome(deps, "alice", { location: BOB }),
      (e: unknown) => e instanceof MapError && e.reason === "rate-limited" && e.retryAfterMs > 0,
    );
    clock.now += 24 * HOUR;
    await setHome(deps, "alice", { location: BOB });
  });

  it("refuses a suspended or missing account", async () => {
    const { deps, store } = setup();
    store.accounts.set("alice", { status: "suspended", firstName: "Alice" });
    await expectMapError(setHome(deps, "alice", { location: ALICE }), "suspended");
    await expectMapError(setHome(deps, "nobody", { location: ALICE }), "no-account");
  });
});

describe("nearby parents (F22): the app never receives another parent's exact coordinates", () => {
  async function seeded() {
    const s = setup();
    await setHome(s.deps, "alice", { location: ALICE });
    await setHome(s.deps, "bob", { location: BOB });
    await setHome(s.deps, "cara", { location: CARA });
    await setHome(s.deps, "dina", { location: DINA });
    await setHome(s.deps, "eve", { location: { lat: BOB.lat + 0.001, lng: BOB.lng } });
    return s;
  }

  it("returns verified parents of the same school within the radius, with rounded and offset points only", async () => {
    const { deps, store } = await seeded();
    const result = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    const ids = result.parents.map((p) => p.id).sort();
    assert.deepEqual(ids, ["bob", "cara", "eve"]);
    const exact: Record<string, LatLng> = { bob: BOB, cara: CARA, eve: { lat: BOB.lat + 0.001, lng: BOB.lng } };
    for (const p of result.parents) {
      assert.deepEqual(Object.keys(p).sort(), ["firstName", "id", "point", "schoolId"]);
      const cell = roundToGrid(exact[p.id]);
      // The point is the rounded cell centre plus the fixed offset ...
      assert.deepEqual(p.point, jitterFor(p.id, cell));
      assert.deepEqual(roundToGrid(p.point), cell);
      // ... never the exact point.
      assert.notDeepEqual(p.point, exact[p.id]);
    }
    // No exact coordinate of any other parent appears anywhere in the answer.
    const json = JSON.stringify(result);
    for (const uid of ["bob", "cara", "dina", "eve"]) {
      const e = store.homes.get(uid)?.location;
      assert.ok(e);
      for (const n of preciseNumbers(json)) {
        assert.notEqual(n, e.lat);
        assert.notEqual(n, e.lng);
      }
    }
    // And no public record (what the search reads) ever held an exact point.
    for (const w of store.publicWrites) assert.deepEqual(roundToGrid(w.point), w.point);
  });

  it("rounds again even if a public record somehow held an exact point (defence in depth)", async () => {
    const { deps, store } = await seeded();
    const bob = store.publics.get("bob");
    assert.ok(bob);
    store.publics.set("bob", { ...bob, point: BOB });
    const result = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    const p = result.parents.find((x) => x.id === "bob");
    assert.ok(p);
    assert.deepEqual(p.point, jitterFor("bob", roundToGrid(BOB)));
  });

  it("leaves out hidden, unverified, suspended and far parents, other schools and the caller", async () => {
    const { deps, store } = await seeded();
    await updateMapSettings(deps, "bob", { showOnMap: false });
    store.accounts.set("cara", { status: "pending", firstName: "Cara" });
    await refreshPublicLocation(deps, "cara");
    store.children.set("eve", ["orman"]);
    await refreshPublicLocation(deps, "eve");
    const near = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    assert.deepEqual(near.parents, []);
    const far = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 10 });
    assert.deepEqual(far.parents.map((p) => p.id), []);
    store.accounts.set("dina", { status: "verified", firstName: "Dina" });
    // Dina is about 12 km away: outside even the largest radius.
    assert.ok(distanceKm(roundToGrid(ALICE), roundToGrid(DINA)) > 10);
  });

  it("orders by distance and sends first name and school only", async () => {
    const { deps } = await seeded();
    const result = await searchNearby(deps, { uid: "bob", verifiedClaim: true }, { schoolId: "nile", radiusKm: 5 });
    assert.equal(result.parents[0].id, "eve");
    assert.equal(result.parents[0].firstName, "Eve");
    assert.equal(result.parents[0].schoolId, "nile");
  });

  it("needs the verified claim and a verified account", async () => {
    const { deps, store } = await seeded();
    await expectMapError(searchNearby(deps, { uid: "alice", verifiedClaim: false }, { schoolId: "nile", radiusKm: 3 }), "not-verified");
    store.accounts.set("alice", { status: "pending", firstName: "Alice" });
    await expectMapError(searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 }), "not-verified");
  });

  it("searches only from the caller's own home and only the caller's schools", async () => {
    const { deps, store } = await seeded();
    store.accounts.set("zed", { status: "verified", firstName: "Zed" });
    store.children.set("zed", ["nile"]);
    await expectMapError(searchNearby(deps, { uid: "zed", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 }), "no-home");
    await expectMapError(searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "orman", radiusKm: 3 }), "not-your-school");
    // A centre in the request is ignored: there is no such field.
    const r = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 1, center: DINA });
    assert.ok(r.parents.every((p) => distanceKm(p.point, roundToGrid(ALICE)) < 2));
  });

  it("refuses radii outside the list and limits searches per hour", async () => {
    const { deps, clock } = await seeded();
    assert.throws(() => parseNearby({ schoolId: "nile", radiusKm: 50 }), MapError);
    assert.throws(() => parseNearby({ schoolId: "../x", radiusKm: 3 }), MapError);
    assert.equal(parseNearby({ schoolId: "nile" }).radiusKm, 3);
    for (let i = 0; i < DEFAULT_MAP_LIMITS.nearbySearchesPerHour; i++) {
      await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    }
    await expectMapError(searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 }), "rate-limited");
    clock.now += HOUR;
    await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
  });

  it("uses at most 9 range queries per search", async () => {
    const { deps, store } = await seeded();
    store.nearbyQueries = [];
    await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 10 });
    assert.ok(store.nearbyQueries.length <= MAX_RANGES);
  });
});

describe("settings and driving schools (F24)", () => {
  it("parses settings", () => {
    assert.deepEqual(parseMapSettings({ showOnMap: false }), { showOnMap: false });
    assert.deepEqual(parseMapSettings({ notifyNewParents: true, radiusKm: 5 }), { notifyNewParents: true, radiusKm: 5 });
    assert.throws(() => parseMapSettings({}), MapError);
    assert.throws(() => parseMapSettings({ showOnMap: "no" }), MapError);
    assert.throws(() => parseMapSettings({ radiusKm: 4 }), MapError);
  });

  it("saves settings before a home exists, without a public record", async () => {
    const { deps, store } = setup();
    const s = await updateMapSettings(deps, "alice", { notifyNewParents: false });
    assert.deepEqual(s, { showOnMap: true, notifyNewParents: false, radiusKm: 3 });
    assert.equal(store.homes.get("alice")?.location, null);
    assert.equal(store.publics.has("alice"), false);
  });

  it("hiding removes the parent from search but they can still search", async () => {
    const { deps } = setup();
    await setHome(deps, "alice", { location: ALICE });
    await setHome(deps, "bob", { location: BOB });
    await updateMapSettings(deps, "alice", { showOnMap: false });
    const fromAlice = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    assert.deepEqual(fromAlice.parents.map((p) => p.id), ["bob"]);
    const fromBob = await searchNearby(deps, { uid: "bob", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    assert.deepEqual(fromBob.parents, []);
  });

  it("driving schools: active only, at most 5, and they open that school's map", async () => {
    const { deps, store } = setup();
    await setHome(deps, "alice", { location: ALICE });
    await setHome(deps, "bob", { location: BOB });
    store.children.set("bob", ["orman"]);
    await refreshPublicLocation(deps, "bob");
    await expectMapError(searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "orman", radiusKm: 3 }), "not-your-school");
    const saved = await setDrivingSchools(deps, "alice", { schoolIds: ["orman"] });
    assert.deepEqual(saved.schools, [{ id: "orman", nameAr: "مدرسة orman", nameEn: "School orman" }]);
    const r = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "orman", radiusKm: 3 });
    assert.deepEqual(r.parents.map((p) => p.id), ["bob"]);
    await expectMapError(setDrivingSchools(deps, "alice", { schoolIds: ["merged1"] }), "invalid-school");
    await expectMapError(setDrivingSchools(deps, "alice", { schoolIds: ["missing"] }), "invalid-school");
    await expectMapError(
      setDrivingSchools(deps, "alice", { schoolIds: ["nile", "orman", "victoria", "s4", "s5", "s6"] }),
      "too-many-schools",
    );
    assert.equal(MAX_DRIVING_SCHOOLS, 5);
    await expectMapError(setDrivingSchools(deps, "alice", { schoolIds: "orman" }), "invalid-request");
  });

  it("limits driving school changes per day", async () => {
    const { deps } = setup();
    for (let i = 0; i < DEFAULT_MAP_LIMITS.drivingSchoolChangesPerDay; i++) {
      await setDrivingSchools(deps, "alice", { schoolIds: i % 2 === 0 ? ["orman"] : [] });
    }
    await expectMapError(setDrivingSchools(deps, "alice", { schoolIds: ["victoria"] }), "rate-limited");
  });
});

describe("new parent nearby event (F23)", () => {
  it("is created once, when a parent with a home and a school is verified, with the rounded point only", async () => {
    const { deps, store } = setup();
    store.accounts.set("alice", { status: "pending", firstName: "Alice" });
    await setHome(deps, "alice", { location: ALICE });
    assert.equal(store.events.size, 0, "not before verification");
    store.accounts.set("alice", { status: "verified", firstName: "Alice" });
    await refreshPublicLocation(deps, "alice");
    const event = store.events.get("alice");
    assert.ok(event);
    assert.deepEqual(event.point, roundToGrid(ALICE));
    assert.deepEqual(event.schoolIds, ["nile"]);
    assert.equal(event.firstName, "Alice");
    assert.equal(event.status, "pending");
    assert.equal(store.publics.get("alice")?.announced, true);
    await refreshPublicLocation(deps, "alice");
    await setHome(deps, "alice", { location: BOB });
    assert.equal(store.events.size, 1, "never twice");
  });

  it("is not created for a hidden parent or a parent without a school", async () => {
    const { deps, store } = setup();
    await updateMapSettings(deps, "alice", { showOnMap: false });
    await setHome(deps, "alice", { location: ALICE });
    store.children.set("bob", []);
    await setHome(deps, "bob", { location: BOB });
    assert.equal(store.events.size, 0);
  });

  it("the public record follows the account: suspended parents leave the map", async () => {
    const { deps, store } = setup();
    await setHome(deps, "bob", { location: BOB });
    assert.equal(store.publics.get("bob")?.verified, true);
    store.accounts.set("bob", { status: "suspended", firstName: "Bob" });
    await refreshPublicLocation(deps, "bob");
    assert.equal(store.publics.get("bob")?.verified, false);
    store.accounts.delete("bob");
    await refreshPublicLocation(deps, "bob");
    assert.equal(store.publics.has("bob"), false);
  });

  it("triggers react only to fields that matter", () => {
    assert.ok(mapRefreshNeeded("user", { status: "pending" }, { status: "verified" }));
    assert.ok(mapRefreshNeeded("user", undefined, { status: "unverified" }));
    assert.ok(!mapRefreshNeeded("user", { status: "verified", language: "ar" }, { status: "verified", language: "en" }));
    assert.ok(mapRefreshNeeded("child", { status: "awaiting_review", schoolId: "a" }, { status: "approved", schoolId: "a" }));
    assert.ok(!mapRefreshNeeded("child", { status: "approved", schoolId: "a", grade: 1 }, { status: "approved", schoolId: "a", grade: 2 }));
  });
});

describe("address search (Places proxy)", () => {
  it("validates input and the session token", () => {
    assert.throws(() => parseAutocomplete({ input: "ab", sessionToken: "abcdefgh12" }), MapError);
    assert.throws(() => parseAutocomplete({ input: "Maadi", sessionToken: "bad token" }), MapError);
    const ok = parseAutocomplete({ input: "  Road   9 ", sessionToken: "3f2b0c1e-aaaa-4bbb-8ccc-0123456789ab", language: "en", near: ALICE });
    assert.equal(ok.input, "Road 9");
    assert.equal(ok.language, "en");
    assert.deepEqual(ok.near, ALICE);
    assert.equal(parseAutocomplete({ input: "Maadi", sessionToken: "abcdefgh12", near: { lat: 48, lng: 2 } }).near, null);
  });

  it("the fake provider answers in Arabic and English", async () => {
    const fake = new FakePlacesProvider();
    const ar = await autocomplete(fake, { input: "المعادي", sessionToken: "abcdefgh12", language: "ar" });
    assert.equal(ar.suggestions[0].placeId, "fake-maadi");
    const en = await autocomplete(fake, { input: "maadi", sessionToken: "abcdefgh12", language: "en" });
    assert.equal(en.suggestions[0].primary, "Road 9, Maadi");
  });

  it("caches details, so the second pick of the same place costs nothing", async () => {
    let calls = 0;
    const inner = new FakePlacesProvider();
    const provider: PlacesProvider = {
      autocomplete: (...a) => inner.autocomplete(...a),
      details: async (...a) => {
        calls++;
        return inner.details(...a);
      },
    };
    const cache = new MemoryPlaceCache();
    const deps = { provider, cache, now: () => 1_000 };
    const a = await placeDetails(deps, { placeId: "fake-zamalek", sessionToken: "abcdefgh12", language: "en" });
    const b = await placeDetails(deps, { placeId: "fake-zamalek", sessionToken: "abcdefgh13", language: "en" });
    assert.deepEqual(a, b);
    assert.equal(calls, 1);
    await placeDetails({ ...deps, now: () => 1_000 + 31 * 24 * HOUR }, { placeId: "fake-zamalek", sessionToken: "abcdefgh14", language: "en" });
    assert.equal(calls, 2, "expired after 30 days");
  });

  it("refuses places outside Egypt", async () => {
    const provider: PlacesProvider = {
      autocomplete: async () => [],
      details: async (placeId): Promise<PlaceDetails> => ({ placeId, label: "Paris", location: { lat: 48.85, lng: 2.35 } }),
    };
    await expectMapError(
      placeDetails({ provider, cache: new MemoryPlaceCache(), now: () => 0 }, { placeId: "paris", sessionToken: "abcdefgh12" }),
      "outside-egypt",
    );
  });

  it("calls Places API (New) with the session token, Egypt only and the cheapest field mask", async () => {
    const requests: Array<{ url: string; init: { method: string; headers: Record<string, string>; body?: string } }> = [];
    const fetchFn = async (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => {
      requests.push({ url, init });
      const body = url.includes(":autocomplete")
        ? { suggestions: [{ placePrediction: { placeId: "p1", structuredFormat: { mainText: { text: "Road 9" }, secondaryText: { text: "Maadi" } } } }] }
        : { id: "p1", formattedAddress: "Road 9, Maadi, Cairo", location: { latitude: 29.96, longitude: 31.25 } };
      return { ok: true, status: 200, json: async () => body };
    };
    const google = new GooglePlacesProvider("server-key", fetchFn);
    const s = await google.autocomplete("Road 9", "tok-12345678", "en", ALICE);
    assert.deepEqual(s, [{ placeId: "p1", primary: "Road 9", secondary: "Maadi" }]);
    const sent = JSON.parse(requests[0].init.body ?? "{}");
    assert.equal(sent.sessionToken, "tok-12345678");
    assert.deepEqual(sent.includedRegionCodes, ["eg"]);
    assert.equal(requests[0].init.headers["X-Goog-Api-Key"], "server-key");
    const d = await google.details("p1", "tok-12345678", "ar");
    assert.deepEqual(d, { placeId: "p1", label: "Road 9, Maadi, Cairo", location: { lat: 29.96, lng: 31.25 } });
    assert.ok(requests[1].url.includes("sessionToken=tok-12345678"));
    assert.ok(requests[1].url.includes("languageCode=ar"));
    assert.equal(requests[1].init.headers["X-Goog-FieldMask"], "id,formattedAddress,location");
  });

  it("address searches are limited per hour", async () => {
    const { deps } = setup();
    for (let i = 0; i < DEFAULT_MAP_LIMITS.placeSearchesPerHour; i++) await takePlaceSearch(deps, "alice");
    await expectMapError(takePlaceSearch(deps, "alice"), "rate-limited");
  });
});
