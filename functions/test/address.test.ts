import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { DEFAULT_MAP_LIMITS, MapError } from "../src/maps/parent_map";
import { FakePlacesProvider } from "../src/maps/places";
import {
  AddressError,
  addressFromDoc,
  checkAddress,
  countMoves,
  geocodeQuery,
  parseAddress,
  startPoint,
  type HomeAddress,
} from "../src/places/address";
import { addressLabel, cityName, geocodeAddressFlow, placeForPointFlow, setHomeAddressFlow, type AddressDeps } from "../src/places/callables";
import { locate, type PlaceArea, type PlaceDistrict, type Ring } from "../src/places/catalog";
import type { PlaceLocator } from "../src/places/store";
import { MemoryMapStore } from "./helpers/memory_maps";

function square(lat: number, lng: number, half: number): Ring {
  return [
    [lat - half, lng - half],
    [lat - half, lng + half],
    [lat + half, lng + half],
    [lat + half, lng - half],
    [lat - half, lng - half],
  ];
}

const MAADI: PlaceArea = {
  id: "osm-r1", governorate: "cairo", nameAr: "المعادي", nameEn: "Maadi", level: 7, source: "osm",
  centre: { lat: 29.96, lng: 31.25 }, bbox: { minLat: 29.94, minLng: 31.23, maxLat: 29.98, maxLng: 31.27 },
  rings: [square(29.96, 31.25, 0.02)], schoolCount: 0, addressCount: 0, active: true, mergedInto: null, adminEdited: false,
};
const ZAYED: PlaceArea = { ...MAADI, id: "osm-r3", governorate: "giza", nameAr: "الشيخ زايد", nameEn: "Sheikh Zayed", centre: { lat: 30.04, lng: 30.98 },
  bbox: { minLat: 30.0, minLng: 30.94, maxLat: 30.08, maxLng: 31.02 }, rings: [square(30.04, 30.98, 0.04)] };
const DEGLA: PlaceDistrict = {
  id: "osm-n10", areaId: "osm-r1", governorate: "cairo", nameAr: "دجلة", nameEn: "Degla", source: "osm-place",
  centre: { lat: 29.958, lng: 31.27 }, bbox: null, rings: [], schoolCount: 0, addressCount: 0, active: true, mergedInto: null, adminEdited: false,
};
const ZAYED14: PlaceDistrict = { ...DEGLA, id: "osm-n20", areaId: "osm-r3", governorate: "giza", nameAr: "الحي 14", nameEn: "District 14", centre: { lat: 30.04, lng: 30.985 } };

const locator: PlaceLocator = {
  locate: async (p) => locate(p, [MAADI, ZAYED], [DEGLA, ZAYED14]),
  area: async (id) => [MAADI, ZAYED].find((a) => a.id === id) ?? null,
  district: async (id) => [DEGLA, ZAYED14].find((d) => d.id === id) ?? null,
};

const input = {
  governorate: "cairo",
  placeAreaId: "osm-r1",
  placeDistrictId: "osm-n10",
  street: "شارع 9",
  building: "12ب",
  floor: "3",
  apartment: "",
  landmark: "أمام الصيدلية",
};

async function rejectsWith(p: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(p, (e: unknown) => (e instanceof AddressError || e instanceof MapError) && e.reason === reason);
}

describe("F46 address: what the app may send", () => {
  it("accepts a full address and trims it", () => {
    const a = parseAddress({ ...input, street: "  شارع   9 " });
    assert.equal(a.street, "شارع 9");
    assert.equal(a.districtText, "");
    assert.equal(a.landmark, "أمام الصيدلية");
  });

  it("says which field is wrong", () => {
    assert.throws(() => parseAddress(null), (e: unknown) => e instanceof AddressError && e.reason === "invalid-request");
    assert.throws(() => parseAddress({ ...input, governorate: "mars" }), (e: unknown) => (e as AddressError).reason === "invalid-city");
    assert.throws(() => parseAddress({ ...input, placeAreaId: "bad id!" }), (e: unknown) => (e as AddressError).reason === "invalid-area");
    assert.throws(() => parseAddress({ ...input, street: "x" }), (e: unknown) => (e as AddressError).reason === "invalid-street");
    assert.throws(() => parseAddress({ ...input, street: "<script>" }), (e: unknown) => (e as AddressError).reason === "invalid-street");
    assert.throws(() => parseAddress({ ...input, building: "" }), (e: unknown) => (e as AddressError).reason === "invalid-building");
    assert.throws(() => parseAddress({ ...input, building: "12345678901" }), (e: unknown) => (e as AddressError).reason === "invalid-building");
    assert.throws(() => parseAddress({ ...input, floor: "12345678901" }), (e: unknown) => (e as AddressError).reason === "invalid-extra");
  });

  it("a district not listed needs its typed name", () => {
    assert.equal(parseAddress({ ...input, placeDistrictId: null, districtText: "الحي الجديد" }).districtText, "الحي الجديد");
    assert.throws(() => parseAddress({ ...input, placeDistrictId: null }), (e: unknown) => (e as AddressError).reason === "invalid-district");
  });

  it("the area must be an active area of that city, the district of that area", () => {
    const a = parseAddress(input);
    const ok = checkAddress(a, MAADI, DEGLA);
    assert.equal(ok.placeAreaNameEn, "Maadi");
    assert.equal(ok.placeDistrictNameAr, "دجلة");
    assert.throws(() => checkAddress(a, ZAYED, DEGLA), (e: unknown) => (e as AddressError).reason === "invalid-area");
    assert.throws(() => checkAddress(a, { ...MAADI, active: false }, DEGLA), (e: unknown) => (e as AddressError).reason === "invalid-area");
    assert.throws(() => checkAddress(a, MAADI, ZAYED14), (e: unknown) => (e as AddressError).reason === "invalid-district");
    assert.throws(() => checkAddress(a, MAADI, null), (e: unknown) => (e as AddressError).reason === "invalid-district");
  });

  it("stored addresses read back; anything else is no address", () => {
    const a = checkAddress(parseAddress(input), MAADI, DEGLA);
    assert.deepEqual(addressFromDoc(JSON.parse(JSON.stringify(a))), a);
    assert.equal(addressFromDoc(null), null);
    assert.equal(addressFromDoc({ street: "x" }), null);
  });
});

describe("F46 address: search text, pin and counts", () => {
  const a: HomeAddress = checkAddress(parseAddress(input), MAADI, DEGLA);

  it("the search text names building, street, district, area and city", () => {
    assert.equal(geocodeQuery(a, "ar", cityName("cairo", "ar")), "12ب شارع 9، دجلة، المعادي، القاهرة، مصر");
    assert.equal(geocodeQuery(a, "en", cityName("cairo", "en")), "12ب شارع 9, Degla, Maadi, Cairo, Egypt");
    const typed = { ...a, placeDistrictId: null, districtText: "الحي الجديد" };
    assert.ok(geocodeQuery(typed, "ar", "القاهرة").includes("الحي الجديد"));
    assert.equal(addressLabel(a, "en"), "12ب شارع 9, Degla, Maadi");
  });

  it("a found point outside the area starts the map at the district instead", () => {
    assert.deepEqual(startPoint({ lat: 29.95, lng: 31.26 }, MAADI, DEGLA), { location: { lat: 29.95, lng: 31.26 }, approximate: false });
    assert.deepEqual(startPoint({ lat: 30.5, lng: 31.5 }, MAADI, DEGLA), { location: DEGLA.centre, approximate: true });
    assert.deepEqual(startPoint(null, MAADI, null), { location: MAADI.centre, approximate: true });
  });

  it("address counts move only when the area or district changes", () => {
    assert.deepEqual(countMoves(null, a), [
      { kind: "area", id: "osm-r1", by: 1 },
      { kind: "district", id: "osm-n10", by: 1 },
    ]);
    assert.deepEqual(countMoves(a, a), []);
    assert.deepEqual(countMoves(a, { placeAreaId: "osm-r1", placeDistrictId: null }), [{ kind: "district", id: "osm-n10", by: -1 }]);
  });
});

describe("F46 address: flows", () => {
  function deps(): { d: AddressDeps; store: MemoryMapStore; moves: unknown[]; requests: unknown[] } {
    const store = new MemoryMapStore();
    store.accounts.set("alice", { status: "verified", firstName: "Alice" });
    const moves: unknown[] = [];
    const requests: unknown[] = [];
    return {
      store,
      moves,
      requests,
      d: {
        map: { store, now: () => Date.UTC(2026, 10, 16, 8), limits: DEFAULT_MAP_LIMITS },
        places: locator,
        moveCounts: async (m) => {
          moves.push(...m);
        },
        districtRequest: async (uid, r) => {
          requests.push([uid, r]);
        },
      },
    };
  }

  it("saves the address with the exact pin privately; the public record has the area only", async () => {
    const { d, store, moves, requests } = deps();
    const exact = { lat: 29.95812, lng: 31.26934 };
    const out = await setHomeAddressFlow(d, "alice", { address: input, location: exact });
    const home = store.homes.get("alice")!;
    assert.deepEqual(home.location, exact);
    assert.equal(home.address?.placeDistrictId, "osm-n10");
    assert.equal(home.address?.street, "شارع 9");
    const pub = store.publics.get("alice")!;
    assert.equal(pub.placeAreaId, "osm-r1");
    assert.equal(pub.placeDistrictId, "osm-n10");
    assert.notDeepEqual(pub.point, exact);
    assert.deepEqual(out.approximate, pub.point);
    assert.ok(!JSON.stringify(pub).includes("شارع"));
    assert.equal(moves.length, 2);
    assert.deepEqual(requests, [["alice", null]]);
  });

  it("a district not listed opens a request for the admins", async () => {
    const { d, requests } = deps();
    await setHomeAddressFlow(d, "alice", {
      address: { ...input, placeDistrictId: null, districtText: "الحي الجديد" },
      location: { lat: 29.95, lng: 31.25 },
    });
    assert.deepEqual(requests, [["alice", { areaId: "osm-r1", governorate: "cairo", text: "الحي الجديد" }]]);
  });

  it("refuses an area of another city, and a pin outside Egypt", async () => {
    const { d, store } = deps();
    await rejectsWith(setHomeAddressFlow(d, "alice", { address: { ...input, governorate: "giza" }, location: { lat: 29.95, lng: 31.25 } }), "invalid-area");
    await rejectsWith(setHomeAddressFlow(d, "alice", { address: input, location: { lat: 48.8, lng: 2.35 } }), "outside-egypt");
    assert.equal(store.homes.size, 0);
  });

  it("where a point is: the area and district for the prefill", async () => {
    assert.deepEqual(await placeForPointFlow({ places: locator }, { location: { lat: 29.958, lng: 31.2695 } }), {
      governorate: "cairo",
      placeAreaId: "osm-r1",
      placeDistrictId: "osm-n10",
    });
    assert.deepEqual(await placeForPointFlow({ places: locator }, { location: { lat: 25.0, lng: 33.0 } }), {
      governorate: null,
      placeAreaId: null,
      placeDistrictId: null,
    });
    await rejectsWith(placeForPointFlow({ places: locator }, { location: "x" }), "invalid-location");
  });

  it("geocoding searches once with the structured address and falls back to the district", async () => {
    const queries: string[] = [];
    let searches = 0;
    const provider = new FakePlacesProvider();
    const base = {
      places: locator,
      provider: {
        autocomplete: async (q: string, t: string, l: "ar" | "en", n: { lat: number; lng: number } | null) => {
          queries.push(q);
          return provider.autocomplete("Maadi", t, l, n);
        },
        details: provider.details.bind(provider),
      },
      details: async (placeId: string) => ({ location: (await provider.details(placeId, "t", "en"))!.location }),
      beforeSearch: async () => {
        searches++;
      },
      cityName,
    };
    const found = await geocodeAddressFlow(base, { address: input, sessionToken: "token-1234", language: "ar" });
    assert.deepEqual(found, { location: { lat: 29.9602, lng: 31.2569 }, approximate: false }); // fake Road 9, Maadi
    assert.equal(searches, 1);
    assert.ok(queries[0].includes("دجلة"));
    // Nothing found: the district's centre, to be moved by the parent.
    const none = await geocodeAddressFlow(
      { ...base, provider: { ...base.provider, autocomplete: async () => [] } },
      { address: input, sessionToken: "token-1234", language: "en" },
    );
    assert.deepEqual(none, { location: DEGLA.centre, approximate: true });
    await rejectsWith(geocodeAddressFlow(base, { address: input, sessionToken: "x", language: "en" }), "invalid-request");
  });
});
