import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AddressError, addressFromDoc, checkAddress, countMoves, parseAddress } from "../src/places/address";
import { planPlaces } from "../src/places/catalog";
import {
  parseDropped,
  parseImportedSchool,
  planAutoMerges,
  planDroppedHiding,
  planImport,
  planUnhide,
  planUnmerge,
  recordWarning,
  type ExistingSchool,
  type MergedImport,
} from "../src/schools/catalog";
import { forEachPage, withRetries } from "../src/schools/paged";

function existing(id: string, over: Partial<ExistingSchool> = {}): ExistingSchool {
  return {
    id, status: "active", adminEdited: false, sourceKeys: [`osm:${id}`], nameAr: "مدرسة النيل", nameEn: "Nile School", kind: "school",
    governorate: "cairo", city: "", cityAr: "", location: { lat: 30, lng: 31.2 }, source: "osm", ...over,
  };
}

function incoming(id: string, keys: string[], mergedFrom: string[], over: Partial<MergedImport> = {}): MergedImport {
  return {
    id, source: "osm", sourceId: id, sourceKeys: keys, nameAr: "مدرسة النيل", nameEn: "Nile School", kind: "school",
    governorate: "cairo", city: "", cityAr: "", location: { lat: 30, lng: 31.2 }, mergedFrom, ...over,
  };
}

describe("automatic merges in Firestore", () => {
  it("hides the earlier documents of merged entries into the survivor, never deletes", () => {
    const ex = [existing("osm-n1"), existing("overture-x2", { sourceKeys: ["overture:x2"], source: "overture" })];
    const inc = [incoming("osm-n1", ["osm:n1", "overture:x2"], ["overture-x2"])];
    const plan = planImport(inc, ex);
    const merges = planAutoMerges(inc, ex, plan);
    assert.deepEqual(merges.hide, [{ id: "overture-x2", into: "osm-n1" }]);
    assert.deepEqual(merges.cancelled, []);
  });

  it("keeps an admin-edited school as the survivor and cancels the import's copy", () => {
    const ex = [existing("osm-n1"), existing("overture-x2", { sourceKeys: ["overture:x2"], source: "overture", adminEdited: true })];
    const inc = [incoming("osm-n1", ["osm:n1", "overture:x2"], ["overture-x2"])];
    const plan = planImport(inc, ex);
    const merges = planAutoMerges(inc, ex, plan);
    assert.deepEqual(merges.hide, [{ id: "osm-n1", into: "overture-x2" }]);
    assert.deepEqual(merges.cancelled, ["osm-n1"]);
    assert.equal(plan.updates.length + plan.creates.length, 0);
  });

  it("never merges parents' schools; lists look-alikes within 500 m", () => {
    const parent = existing("p1", { source: "parent", sourceKeys: [], location: { lat: 30.001, lng: 31.2 } });
    const far = existing("p2", { source: "parent", sourceKeys: [], location: { lat: 30.1, lng: 31.2 } });
    const ex = [existing("osm-n1"), parent, far];
    const inc = [incoming("osm-n1", ["osm:n1"], [])];
    const merges = planAutoMerges(inc, ex, planImport(inc, ex));
    assert.deepEqual(merges.hide, []);
    assert.deepEqual(merges.parentLookalikes, [{ id: "p1", like: "osm-n1" }]);
  });

  it("brings back a school an earlier import merged when this run keeps it apart (validator B2)", () => {
    const ex = [
      existing("osm-n1", { sourceKeys: ["osm:n1", "osm:n2"] }),
      existing("osm-n2", { sourceKeys: ["osm:n2"], status: "merged", mergedInto: "osm-n1", mergedBy: "import" }),
      existing("osm-n3", { sourceKeys: ["osm:n3"], status: "merged", mergedInto: "osm-n1" }), // an admin's merge
    ];
    const inc = [incoming("osm-n1", ["osm:n1"], []), incoming("osm-n2", ["osm:n2"], []), incoming("osm-n3", ["osm:n3"], [])];
    assert.deepEqual(planUnmerge(ex, inc), ["osm-n2"]);
    // Still merged in this run: stays merged.
    assert.deepEqual(planUnmerge(ex, [incoming("osm-n1", ["osm:n1", "osm:n2"], ["osm-n2"]), incoming("osm-n2", ["osm:n2"], [])]), []);
  });

  it("re-points a school an earlier import merged when its group has another survivor", () => {
    const ex = [
      existing("osm-n1", { sourceKeys: ["osm:n1"] }),
      existing("osm-n2", { sourceKeys: ["osm:n2"] }),
      existing("osm-n3", { sourceKeys: ["osm:n3"], status: "merged", mergedInto: "osm-n1", mergedBy: "import" }),
    ];
    const inc = [incoming("osm-n1", ["osm:n1"], []), incoming("osm-n2", ["osm:n2", "osm:n3"], ["osm-n3"])];
    const merges = planAutoMerges(inc, ex, planImport(inc, ex));
    assert.deepEqual(merges.hide, [{ id: "osm-n3", into: "osm-n2" }]);
    // Run again with it already pointing there: nothing to write.
    const ex2 = ex.map((s) => (s.id === "osm-n3" ? { ...s, mergedInto: "osm-n2" } : s));
    assert.deepEqual(planAutoMerges(inc, ex2, planImport(inc, ex2)).hide, []);
  });

  it("reads mergedFrom from schools.json", () => {
    const s = parseImportedSchool({ ...incoming("osm-n1", ["osm:n1"], ["overture-x2", "bad id!"]) });
    assert.deepEqual(s.mergedFrom, ["overture-x2"]);
  });
});

describe("schools the rules now drop", () => {
  const dropped = parseDropped([{ key: "overture:x9", reason: "name_script" }, { key: 3 }]);
  it("hides imported, active, unedited schools whose every key is dropped", () => {
    const ex = [
      existing("overture-x9", { sourceKeys: ["overture:x9"], source: "overture" }),
      existing("overture-x8", { sourceKeys: ["overture:x9", "overture:x8"], source: "overture" }),
      existing("p1", { source: "parent", sourceKeys: ["overture:x9"] }),
      existing("e1", { adminEdited: true, sourceKeys: ["overture:x9"] }),
    ];
    assert.deepEqual(planDroppedHiding(dropped, ex, []), [{ id: "overture-x9", reason: "name_script" }]);
  });
  it("brings back a hidden school the rules keep again", () => {
    const ex = [existing("overture-x9", { sourceKeys: ["overture:x9"], searchHidden: true, hiddenReason: "name_script" })];
    assert.deepEqual(planUnhide(ex, [incoming("overture-x9", ["overture:x9"], [])]), ["overture-x9"]);
    assert.deepEqual(planUnhide(ex, []), []);
  });
});

describe("Algolia record warning", () => {
  it("warns above the line only", () => {
    assert.equal(recordWarning(7200), null);
    assert.match(recordWarning(8001) ?? "", /8001 records/);
    assert.equal(recordWarning(9000, 10000), null);
  });
});

describe("places replaced by a better source", () => {
  const ring = [[30, 31], [30, 31.1], [30.1, 31.1], [30, 31]] as Array<[number, number]>;
  const area = (id: string, over: Record<string, unknown> = {}) => ({
    id, nameAr: id, nameEn: id, governorate: "cairo", centre: null, rings: [ring], adminEdited: false, mergedInto: null, active: true, source: "osm", ...over,
  });
  it("retires imported areas missing from the file, keeps admin ones", () => {
    const plan = planPlaces([area("cod-EG0101"), area("cod-EG0102")], [area("osm-r1"), area("osm-r2", { adminEdited: true }), area("a1", { source: "admin" })]);
    assert.deepEqual(plan.retires, ["osm-r1"]);
    assert.equal(plan.creates.length, 2);
  });
  it("retires nothing when the file is much smaller (broken download)", () => {
    const plan = planPlaces([area("cod-EG0101")], [area("osm-r1"), area("osm-r2")]);
    assert.deepEqual(plan.retires, []);
  });
});

describe("paged reads", () => {
  it("reads every page with the selected fields and retries a failed page", async () => {
    const docs = Array.from({ length: 1205 }, (_, i) => ({ id: `s${String(i).padStart(5, "0")}`, data: () => ({ i }) }));
    const calls: Array<{ start: number; select: string[] }> = [];
    let failOnce = true;
    const query = (start: number, limit: number, select: string[]): unknown => ({
      limit: (n: number) => query(start, n, select),
      select: (...f: string[]) => query(start, limit, f),
      startAfter: (d: { id: string }) => query(docs.findIndex((x) => x.id === d.id) + 1, limit, select),
      get: async () => {
        if (failOnce && start === 500) {
          failOnce = false;
          throw new Error("4 DEADLINE_EXCEEDED");
        }
        calls.push({ start, select });
        return { docs: docs.slice(start, start + limit) };
      },
    });
    const db = { collection: () => ({ orderBy: () => query(0, 0, []) }) } as unknown as Parameters<typeof forEachPage>[0];
    const seen: number[] = [];
    const total = await forEachPage(db, "schools", (page) => {
      seen.push(page.length);
    }, { pageSize: 500, select: ["nameAr"], sleep: async () => {} });
    assert.equal(total, 1205);
    assert.deepEqual(seen, [500, 500, 205]);
    assert.deepEqual(calls.map((c) => c.start), [0, 500, 1000]);
    assert.deepEqual(calls[0].select, ["nameAr"]);
  });
  it("gives up after the retries", async () => {
    let n = 0;
    await assert.rejects(withRetries(async () => {
      n++;
      throw new Error("down");
    }, 2, async () => {}));
    assert.equal(n, 3);
  });
});


describe("address in a city with no areas yet", () => {
  const base = { governorate: "luxor", street: "Karnak Street", building: "12", floor: "", apartment: "", landmark: "" };
  it("accepts no area (and an optional typed district) only when the city has none", () => {
    const input = parseAddress({ ...base, placeAreaId: "", placeDistrictId: null, districtText: "" });
    assert.equal(input.placeAreaId, "");
    assert.throws(() => checkAddress(input, null, null, true), (e: unknown) => e instanceof AddressError && e.reason === "invalid-area");
    const address = checkAddress(input, null, null, false);
    assert.equal(address.placeAreaId, "");
    assert.equal(checkAddress(parseAddress({ ...base, placeAreaId: null, districtText: "الكرنك" }), null, null, false).districtText, "الكرنك");
    assert.deepEqual(countMoves(null, address), []);
    assert.equal(addressFromDoc({ ...address })?.governorate, "luxor");
  });
  it("still needs the typed district when an area is chosen, and no district id without an area", () => {
    assert.throws(() => parseAddress({ ...base, placeAreaId: "cod-EG2101", placeDistrictId: null, districtText: "" }));
    assert.throws(() => parseAddress({ ...base, placeAreaId: "", placeDistrictId: "osm-n1" }));
  });
});
