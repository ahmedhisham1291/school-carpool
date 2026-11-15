import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AdminError } from "../src/admin_panel/errors";
import type { AdminCaller } from "../src/admin_panel/guard";
import type { AuditEntry } from "../src/admin_panel/types";
import {
  listAreas,
  listDistricts,
  mergePlaces,
  moveSchoolArea,
  resolvePlaceRequest,
  saveArea,
  saveDistrict,
  setPlaceActive,
  type PlaceKind,
  type PlaceRequestItem,
  type PlacesAdminStore,
  type SchoolPlace,
} from "../src/places/admin";
import {
  buildIndex,
  candidates,
  countSchools,
  locate,
  parsePlacesFile,
  placeKey,
  planPlaces,
  ringContains,
  ringsFromDoc,
  ringsToDoc,
  shapeContains,
  type PlaceArea,
  type PlaceDistrict,
  type Ring,
} from "../src/places/catalog";
import { placeOfPoint, type PlaceLocator } from "../src/places/store";
import { searchRecordFrom } from "../src/schools/catalog";
import { addOtherSchool, type OtherSchoolsStore, type PendingSchool } from "../src/schools/other";

/** A square ring of [half] degrees around (lat, lng), as [lat, lng] pairs. */
function square(lat: number, lng: number, half: number): Ring {
  return [
    [lat - half, lng - half],
    [lat - half, lng + half],
    [lat + half, lng + half],
    [lat + half, lng - half],
    [lat - half, lng - half],
  ];
}

function area(id: string, lat: number, lng: number, half: number, over: Partial<PlaceArea> = {}): PlaceArea {
  return {
    id,
    governorate: "cairo",
    nameAr: `منطقة ${id}`,
    nameEn: `Area ${id}`,
    level: 7,
    source: "osm",
    centre: { lat, lng },
    bbox: { minLat: lat - half, minLng: lng - half, maxLat: lat + half, maxLng: lng + half },
    rings: [square(lat, lng, half)],
    schoolCount: 0,
    addressCount: 0,
    active: true,
    mergedInto: null,
    adminEdited: false,
    ...over,
  };
}

function district(id: string, areaId: string, lat: number, lng: number, half: number | null, over: Partial<PlaceDistrict> = {}): PlaceDistrict {
  return {
    id,
    areaId,
    governorate: "cairo",
    nameAr: `حي ${id}`,
    nameEn: `District ${id}`,
    source: half === null ? "osm-place" : "osm-boundary",
    centre: { lat, lng },
    bbox: half === null ? null : { minLat: lat - half, minLng: lng - half, maxLat: lat + half, maxLng: lng + half },
    rings: half === null ? [] : [square(lat, lng, half)],
    schoolCount: 0,
    addressCount: 0,
    active: true,
    mergedInto: null,
    adminEdited: false,
    ...over,
  };
}

describe("places: geometry and lookup", () => {
  const maadi = area("osm-r1", 29.96, 31.25, 0.02);
  const big = area("osm-r9", 30.0, 31.25, 0.3, { level: 6 });
  const degla = district("osm-r5", "osm-r1", 29.955, 31.265, 0.004);
  const sarayat = district("osm-n10", "osm-r1", 29.965, 31.245, null);

  it("ray casting on [lat, lng] rings", () => {
    assert.equal(ringContains(square(30, 31, 0.1), { lat: 30.05, lng: 31.05 }), true);
    assert.equal(ringContains(square(30, 31, 0.1), { lat: 30.2, lng: 31 }), false);
    assert.equal(shapeContains(maadi, { lat: 29.96, lng: 31.25 }), true);
    assert.equal(shapeContains({ bbox: null, rings: maadi.rings }, { lat: 29.96, lng: 31.25 }), false);
  });

  it("finest active area first, then the district boundary, then the nearest named place", () => {
    assert.deepEqual(locate({ lat: 29.955, lng: 31.265 }, [big, maadi], [degla, sarayat]), {
      governorate: "cairo",
      areaId: "osm-r1",
      districtId: "osm-r5",
    });
    assert.equal(locate({ lat: 29.966, lng: 31.246 }, [maadi], [degla, sarayat]).districtId, "osm-n10");
    // In the area, but more than 1.5 km from any named place.
    assert.equal(locate({ lat: 29.979, lng: 31.231 }, [maadi], [degla, sarayat]).districtId, null);
    // Outside Maadi but inside the big area.
    assert.equal(locate({ lat: 30.2, lng: 31.3 }, [big, maadi], []).areaId, "osm-r9");
    // An inactive area is skipped.
    assert.equal(locate({ lat: 29.96, lng: 31.25 }, [area("osm-r1", 29.96, 31.25, 0.02, { active: false })], []).areaId, null);
    assert.deepEqual(locate({ lat: 25, lng: 33 }, [maadi], []), { governorate: null, areaId: null, districtId: null });
  });

  it("the index holds active areas with a shape; candidates by box", () => {
    const admin = area("adm-1", 30, 31, 0.1, { rings: [], bbox: null, source: "admin" });
    const off = area("osm-r2", 30, 31, 0.1, { active: false });
    const index = buildIndex([maadi, big, admin, off]);
    assert.deepEqual(index.map((e) => e.id), ["osm-r1", "osm-r9"]);
    assert.deepEqual(candidates(index, { lat: 29.96, lng: 31.25 }).sort(), ["osm-r1", "osm-r9"]);
    assert.deepEqual(candidates(index, { lat: 25, lng: 33 }), []);
  });

  it("rings go to Firestore as flat number lists (no nested arrays) and back", () => {
    const doc = ringsToDoc(maadi.rings);
    assert.deepEqual(Object.keys(doc[0]), ["p"]);
    assert.equal(doc[0].p.length, 10);
    assert.deepEqual(ringsFromDoc(doc), maadi.rings);
    assert.deepEqual(ringsFromDoc([{ p: [1, 2, 3] }, "x"]), []);
  });

  it("placeOfPoint returns the area's names", async () => {
    const locator: PlaceLocator = {
      locate: async (p) => locate(p, [maadi], [degla]),
      area: async (id) => (id === maadi.id ? maadi : null),
      district: async () => null,
    };
    assert.deepEqual(await placeOfPoint(locator, { lat: 29.955, lng: 31.265 }), {
      placeAreaId: "osm-r1",
      placeAreaNameAr: "منطقة osm-r1",
      placeAreaNameEn: "Area osm-r1",
      placeDistrictId: "osm-r5",
    });
    assert.deepEqual(await placeOfPoint(locator, { lat: 25, lng: 33 }), {});
  });

  it("place names match like the importer (قسم / مركز / حي ignored)", () => {
    assert.equal(placeKey("قسم المعادي"), placeKey("المعادي"));
    assert.equal(placeKey("Nasr City"), "nasr");
  });
});

describe("places: import file and plan", () => {
  const file = {
    format: "school-carpool-places/1",
    areas: [
      { id: "osm-r1", governorate: "cairo", nameAr: "المعادي", nameEn: "Maadi", level: 7, centre: { lat: 29.96, lng: 31.25 },
        bbox: { minLat: 29.94, minLng: 31.23, maxLat: 29.98, maxLng: 31.27 }, rings: [square(29.96, 31.25, 0.02)] },
      { id: "bad id!", governorate: "cairo", nameAr: "x" },
      { id: "osm-r2", governorate: "atlantis", nameAr: "مكان" },
    ],
    districts: [
      { id: "osm-n10", areaId: "osm-r1", governorate: "cairo", nameAr: "سرايات", source: "osm-place", centre: { lat: 29.965, lng: 31.245 } },
      { id: "osm-n11", areaId: "osm-r404", governorate: "cairo", nameAr: "يتيم" },
    ],
  };

  it("checks every entry; unknown areas and governorates are refused", () => {
    const parsed = parsePlacesFile(file);
    assert.equal(parsed.refused, 3);
    assert.deepEqual(parsed.areas.map((a) => a.id), ["osm-r1"]);
    assert.equal(parsed.areas[0].rings[0].length, 5);
    assert.deepEqual(parsed.districts.map((d) => [d.id, d.nameEn, d.source]), [["osm-n10", "سرايات", "osm-place"]]);
    assert.throws(() => parsePlacesFile({ format: "x" }));
  });

  it("is idempotent and keeps admin edits", () => {
    const parsed = parsePlacesFile(file);
    const first = planPlaces(parsed.areas, []);
    assert.equal(first.creates.length, 1);
    const stored = parsed.areas.map((a) => ({ ...area(a.id, 0, 0, 1), ...a }));
    assert.deepEqual(planPlaces(parsed.areas, stored), { creates: [], updates: [], unchanged: 1, skipped: 0 });
    const renamed = [{ ...stored[0], nameEn: "Old" }];
    assert.equal(planPlaces(parsed.areas, renamed).updates.length, 1);
    assert.equal(planPlaces(parsed.areas, [{ ...renamed[0], adminEdited: true }]).skipped, 1);
    assert.equal(planPlaces(parsed.areas, [{ ...renamed[0], mergedInto: "osm-r9" }]).skipped, 1);
  });

  it("counts schools per area and district", () => {
    const { areas, districts } = countSchools([
      { areaId: "a", districtId: "d" },
      { areaId: "a", districtId: null },
      { areaId: null, districtId: null },
    ]);
    assert.equal(areas.get("a"), 2);
    assert.equal(districts.get("d"), 1);
  });

  it("search records carry the area as a filter and its names", () => {
    const r = searchRecordFrom("s1", {
      status: "active", nameAr: "مدرسة", nameEn: "School", governorate: "cairo",
      placeAreaId: "osm-r1", placeAreaNameAr: "المعادي", placeAreaNameEn: "Maadi",
    })!;
    assert.equal(r.placeAreaId, "osm-r1");
    assert.equal(r.placeAreaNameEn, "Maadi");
    assert.equal(searchRecordFrom("s2", { status: "active", nameAr: "مدرسة", nameEn: "School" })!.placeAreaId, undefined);
  });
});

describe("places: an \"Other\" school gets its area on the server", () => {
  it("from its pin, none without one", async () => {
    const created: PendingSchool[] = [];
    const store: OtherSchoolsStore = {
      newId: () => `p${created.length + 1}`,
      accountState: async () => "ok",
      pendingOf: async () => [],
      create: async (s) => {
        created.push(s);
      },
    };
    const placeOf = async () => ({ placeAreaId: "osm-r1", placeAreaNameAr: "المعادي", placeAreaNameEn: "Maadi", placeDistrictId: null });
    await addOtherSchool({ store, now: () => 1, placeOf }, "alice", { name: "مدرسة الزهور", governorate: "cairo", location: { lat: 29.96, lng: 31.25 } });
    await addOtherSchool({ store, now: () => 1, placeOf }, "alice", { name: "مدرسة الياسمين", governorate: "cairo" });
    assert.equal(created[0].placeAreaId, "osm-r1");
    assert.equal(created[1].placeAreaId, undefined);
  });
});

class MemoryPlacesStore implements PlacesAdminStore {
  areas = new Map<string, PlaceArea>();
  districts = new Map<string, PlaceDistrict>();
  schools = new Map<string, SchoolPlace & { nameAr?: string }>();
  requests = new Map<string, PlaceRequestItem & { uid: string; status: string }>();
  audits: AuditEntry[] = [];
  homesDistrict = new Map<string, string | null>();
  counter = 0;

  newId(kind: PlaceKind) {
    this.counter++;
    return `adm-${kind}-${this.counter}`;
  }
  async listAreas(g: string) {
    return [...this.areas.values()].filter((a) => a.governorate === g);
  }
  async listDistricts(areaId: string) {
    return [...this.districts.values()].filter((d) => d.areaId === areaId);
  }
  async area(id: string) {
    return this.areas.get(id) ?? null;
  }
  async district(id: string) {
    return this.districts.get(id) ?? null;
  }
  async saveArea(a: { id: string; governorate: string; nameAr: string; nameEn: string }, isNew: boolean, audit: AuditEntry) {
    const old = this.areas.get(a.id);
    this.areas.set(a.id, isNew ? area(a.id, 0, 0, 0, { ...a, rings: [], bbox: null, source: "admin", level: 0, adminEdited: true }) : { ...old!, ...a, adminEdited: true });
    this.audits.push(audit);
  }
  async saveDistrict(d: { id: string; areaId: string; governorate: string; nameAr: string; nameEn: string; source: string }, isNew: boolean, audit: AuditEntry) {
    const old = this.districts.get(d.id);
    this.districts.set(d.id, isNew ? district(d.id, d.areaId, 0, 0, null, { ...d, adminEdited: true }) : { ...old!, ...d, adminEdited: true });
    this.audits.push(audit);
  }
  async setActive(kind: PlaceKind, id: string, active: boolean, audit: AuditEntry) {
    const map = kind === "area" ? this.areas : this.districts;
    map.set(id, { ...(map.get(id) as PlaceArea & PlaceDistrict), active });
    this.audits.push(audit);
  }
  async merge(kind: PlaceKind, fromId: string, intoId: string, audit: AuditEntry) {
    const field = kind === "area" ? "placeAreaId" : "placeDistrictId";
    let moved = 0;
    for (const s of this.schools.values()) {
      if (s[field] === fromId) {
        (s as unknown as Record<string, unknown>)[field] = intoId;
        moved++;
      }
    }
    const map = kind === "area" ? this.areas : this.districts;
    map.set(fromId, { ...(map.get(fromId) as PlaceArea & PlaceDistrict), active: false, mergedInto: intoId });
    this.audits.push(audit);
    return moved;
  }
  async school(id: string) {
    return this.schools.get(id) ?? null;
  }
  async moveSchool(schoolId: string, _from: SchoolPlace, a: PlaceArea, d: PlaceDistrict | null, audit: AuditEntry) {
    this.schools.set(schoolId, { ...this.schools.get(schoolId)!, placeAreaId: a.id, placeDistrictId: d?.id ?? null });
    this.audits.push(audit);
  }
  async listRequests() {
    return [...this.requests.values()].filter((r) => r.status === "open");
  }
  async request(id: string) {
    return this.requests.get(id) ?? null;
  }
  async resolveRequest(id: string, districtId: string | null, audit: AuditEntry) {
    const r = this.requests.get(id)!;
    this.requests.set(id, { ...r, status: "done" });
    if (districtId) this.homesDistrict.set(r.uid, districtId);
    this.audits.push(audit);
  }
}

const caller = { uid: "admin1", role: "admin" } as AdminCaller;

describe("places: admin panel", () => {
  function setup(): { store: MemoryPlacesStore; deps: { store: MemoryPlacesStore } } {
    const store = new MemoryPlacesStore();
    store.areas.set("osm-r1", area("osm-r1", 29.96, 31.25, 0.02, { nameAr: "المعادي", nameEn: "Maadi", schoolCount: 4 }));
    store.areas.set("osm-r2", area("osm-r2", 30.06, 31.33, 0.02, { nameAr: "مدينة نصر", nameEn: "Nasr City" }));
    store.areas.set("osm-r3", area("osm-r3", 30.0, 31.0, 0.1, { governorate: "giza", nameAr: "الدقي", nameEn: "Dokki" }));
    store.districts.set("osm-n10", district("osm-n10", "osm-r1", 29.965, 31.245, null));
    store.districts.set("osm-n11", district("osm-n11", "osm-r1", 29.955, 31.26, null));
    store.districts.set("osm-n20", district("osm-n20", "osm-r2", 30.06, 31.33, null));
    store.schools.set("s1", { id: "s1", status: "active", governorate: "cairo", placeAreaId: "osm-r1", placeDistrictId: "osm-n10" });
    store.schools.set("s2", { id: "s2", status: "active", governorate: "cairo", placeAreaId: "osm-r2", placeDistrictId: null });
    store.requests.set("q1", { id: "q1", uid: "alice", status: "open", areaId: "osm-r1", governorate: "cairo", text: "الحي الجديد", createdAtMs: 1 });
    return { store, deps: { store } };
  }

  it("lists a city's areas (Arabic order) and an area's districts, without outlines", async () => {
    const { deps } = setup();
    const { areas } = await listAreas(deps, { governorate: "cairo" });
    assert.deepEqual(areas.map((a) => a.id), ["osm-r1", "osm-r2"]);
    assert.equal(areas[0].schoolCount, 4);
    assert.equal(areas[0].hasShape, true);
    assert.ok(!("rings" in areas[0]));
    assert.deepEqual((await listDistricts(deps, { areaId: "osm-r1" })).districts.map((d) => d.id).sort(), ["osm-n10", "osm-n11"]);
    await assert.rejects(listAreas(deps, { governorate: "mars" }), AdminError);
  });

  it("adds and renames areas and districts, each with an audit entry", async () => {
    const { store, deps } = setup();
    const { id } = await saveArea(deps, caller, { governorate: "cairo", nameAr: "العاصمة الإدارية", nameEn: "New Capital" }, "1.2.3.4");
    assert.equal(store.areas.get(id)?.source, "admin");
    await saveArea(deps, caller, { id: "osm-r1", nameAr: "المعادي الجديدة", nameEn: "Maadi" }, null);
    assert.equal(store.areas.get("osm-r1")?.nameAr, "المعادي الجديدة");
    assert.equal(store.areas.get("osm-r1")?.governorate, "cairo");
    const d = await saveDistrict(deps, caller, { areaId: "osm-r1", nameAr: "زهراء المعادي", nameEn: "Zahraa El Maadi" }, null);
    assert.equal(store.districts.get(d.id)?.areaId, "osm-r1");
    assert.deepEqual(store.audits.map((a) => a.action), ["place.area.create", "place.area.rename", "place.district.create"]);
    await assert.rejects(saveArea(deps, caller, { governorate: "cairo", nameAr: "x", nameEn: "y" }, null), AdminError);
    await assert.rejects(saveDistrict(deps, caller, { areaId: "nope", nameAr: "حي", nameEn: "District" }, null), AdminError);
  });

  it("deactivates, and merges only within the same city (areas) or area (districts)", async () => {
    const { store, deps } = setup();
    assert.deepEqual(await setPlaceActive(deps, caller, { kind: "district", id: "osm-n11", active: false }, null), { id: "osm-n11", active: false });
    assert.equal(store.districts.get("osm-n11")?.active, false);
    await assert.rejects(mergePlaces(deps, caller, { kind: "area", fromId: "osm-r3", intoId: "osm-r1" }, null), AdminError);
    await assert.rejects(mergePlaces(deps, caller, { kind: "district", fromId: "osm-n20", intoId: "osm-n10" }, null), AdminError);
    const merged = await mergePlaces(deps, caller, { kind: "area", fromId: "osm-r2", intoId: "osm-r1" }, null);
    assert.deepEqual(merged, { id: "osm-r1", schoolsMoved: 1 });
    assert.equal(store.areas.get("osm-r2")?.mergedInto, "osm-r1");
    // A merged area is no longer listed and can be neither renamed nor merged again.
    assert.deepEqual((await listAreas(deps, { governorate: "cairo" })).areas.map((a) => a.id), ["osm-r1"]);
    await assert.rejects(saveArea(deps, caller, { id: "osm-r2", nameAr: "اسم", nameEn: "Name" }, null), AdminError);
    await assert.rejects(mergePlaces(deps, caller, { kind: "area", fromId: "osm-r2", intoId: "osm-r1" }, null), AdminError);
  });

  it("moves a school to an area of its own city, with a district of that area", async () => {
    const { store, deps } = setup();
    await moveSchoolArea(deps, caller, { schoolId: "s2", areaId: "osm-r1", districtId: "osm-n11" }, null);
    assert.deepEqual([store.schools.get("s2")?.placeAreaId, store.schools.get("s2")?.placeDistrictId], ["osm-r1", "osm-n11"]);
    assert.equal(store.audits.at(-1)?.action, "school.move-area");
    assert.deepEqual(store.audits.at(-1)?.details, { from: "osm-r2", into: "osm-r1" });
    await assert.rejects(moveSchoolArea(deps, caller, { schoolId: "s1", areaId: "osm-r3" }, null), AdminError); // Giza
    await assert.rejects(moveSchoolArea(deps, caller, { schoolId: "s1", areaId: "osm-r1", districtId: "osm-n20" }, null), AdminError);
  });

  it("resolves a \"district not listed\" request: add it, map it, or dismiss", async () => {
    const { store, deps } = setup();
    const created = await resolvePlaceRequest(deps, caller, { id: "q1", action: "create", nameAr: "الحي الجديد", nameEn: "New District" }, null);
    assert.ok(created.districtId?.startsWith("adm-district-"));
    assert.equal(store.districts.get(created.districtId!)?.areaId, "osm-r1");
    assert.equal(store.homesDistrict.get("alice"), created.districtId);
    await assert.rejects(resolvePlaceRequest(deps, caller, { id: "q1", action: "dismiss" }, null), AdminError); // already done

    store.requests.set("q2", { id: "q2", uid: "bob", status: "open", areaId: "osm-r1", governorate: "cairo", text: "سرايات", createdAtMs: 2 });
    assert.deepEqual(await resolvePlaceRequest(deps, caller, { id: "q2", action: "map", districtId: "osm-n10" }, null), { id: "q2", districtId: "osm-n10" });
    store.requests.set("q3", { id: "q3", uid: "bob", status: "open", areaId: "osm-r1", governorate: "cairo", text: "x", createdAtMs: 3 });
    await assert.rejects(resolvePlaceRequest(deps, caller, { id: "q3", action: "map", districtId: "osm-n20" }, null), AdminError);
    assert.deepEqual(await resolvePlaceRequest(deps, caller, { id: "q3", action: "dismiss" }, null), { id: "q3", districtId: null });
    await assert.rejects(resolvePlaceRequest(deps, caller, { id: "q3", action: "explode" }, null), AdminError);
  });
});
