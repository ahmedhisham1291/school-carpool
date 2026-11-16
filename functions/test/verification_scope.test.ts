// Owner decision 16 Nov 2026 (App Review guideline 2.1 / 5.1.1: no dead end
// before the ID check). A parent who is not verified yet may look around and
// set up their own things; everything that involves another family needs a
// verified account. The app's router (lib/router/session_redirect.dart,
// needsVerification) closes the same places and opens the explanation
// screen. This file checks the server side of that line in one place.
//
//   Open before verification (own data)      Closed ("not-verified")
//   setHome / setHomeAddress                 searchNearby (parents nearby)
//   updateMapSettings                        createCarpool, searchCarpools
//   setDrivingSchools                        requestToJoin, openInvite
//   places search, school search key         saveWanted, listWanted
//   notifications, privacy, verification     chat (chat.test.ts), runs
//                                            (trips.test.ts, also handover
//                                            adults and emergency contact),
//                                            ratings, family,
//                                            phone change (trust.test.ts),
//                                            Settle up, wallet
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createCarpool,
  DEFAULT_CARPOOL_LIMITS,
  listWanted,
  openInvite,
  requestToJoin,
  saveWanted,
  searchCarpools,
  type CarpoolDeps,
} from "../src/carpools/flow";
import { CarpoolError } from "../src/carpools/model";
import { type LatLng } from "../src/maps/geo";
import {
  DEFAULT_MAP_LIMITS,
  MapError,
  searchNearby,
  setDrivingSchools,
  setHome,
  updateMapSettings,
  type MapDeps,
} from "../src/maps/parent_map";
import { MemoryCarpoolStore } from "./helpers/memory_carpools";
import { MemoryMapStore } from "./helpers/memory_maps";

// Fake homes in Maadi (Cairo), fake parents only.
const ALICE: LatLng = { lat: 29.96123, lng: 31.25671 };
const NORA: LatLng = { lat: 29.96788, lng: 31.26244 };

function maps(): { deps: MapDeps; store: MemoryMapStore } {
  const store = new MemoryMapStore();
  store.accounts.set("alice", { status: "verified", firstName: "Alice" });
  store.accounts.set("nora", { status: "unverified", firstName: "Nora" });
  store.accounts.set("pia", { status: "pending", firstName: "Pia" });
  for (const uid of ["alice", "nora", "pia"]) store.children.set(uid, ["nile"]);
  for (const id of ["nile", "orman"]) {
    store.schoolList.set(id, { id, nameAr: `مدرسة ${id}`, nameEn: `School ${id}`, status: "active" });
  }
  return { deps: { store, now: () => Date.UTC(2026, 10, 16, 8), limits: DEFAULT_MAP_LIMITS }, store };
}

function carpools(): CarpoolDeps {
  const store = new MemoryCarpoolStore();
  store.schools.set("nile", { id: "nile", nameAr: "النيل", nameEn: "Nile", status: "active" });
  store.areas.set("degla", { id: "degla", schoolId: "nile", nameAr: "دجلة", nameEn: "Degla" });
  store.accounts.set("nora", { status: "unverified", firstName: "Nora" });
  store.accounts.set("pia", { status: "pending", firstName: "Pia" });
  store.accounts.set("rana", { status: "rejected", firstName: "Rana" });
  for (const uid of ["nora", "pia", "rana"]) {
    store.children.set(uid, [{ id: `${uid}-c`, firstName: "Kid", grade: "g1", schoolId: "nile" }]);
    store.homes.set(uid, { location: NORA, label: "Road 1 (test)" });
  }
  return {
    store,
    now: () => Date.UTC(2026, 10, 16, 8),
    limits: { ...DEFAULT_CARPOOL_LIMITS },
    newCode: () => "ABCDEFGH22",
    linkBase: "https://links.example/",
  };
}

async function refusedAsNotVerified(p: Promise<unknown>): Promise<void> {
  await assert.rejects(
    p,
    (e: unknown) => (e instanceof CarpoolError || e instanceof MapError) && e.reason === "not-verified",
  );
}

describe("before the ID check: the parent's own things are open", () => {
  it("sets a home, map settings and driving schools, and stays off other parents' maps", async () => {
    const { deps, store } = maps();
    await setHome(deps, "nora", { location: NORA });
    await updateMapSettings(deps, "nora", { notifyNewParents: false });
    const saved = await setDrivingSchools(deps, "nora", { schoolIds: ["orman"] });
    assert.deepEqual(saved.schools.map((s) => s.id), ["orman"]);
    // Nobody sees Nora: her public record says not verified.
    assert.equal(store.publics.get("nora")?.verified, false);
    await setHome(deps, "alice", { location: ALICE });
    const near = await searchNearby(deps, { uid: "alice", verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 });
    assert.deepEqual(near.parents.map((p) => p.id), []);
  });
});

describe("before the ID check: anything with another family is refused", () => {
  it("parents nearby", async () => {
    const { deps } = maps();
    await setHome(deps, "nora", { location: NORA });
    await setHome(deps, "pia", { location: NORA });
    for (const uid of ["nora", "pia"]) {
      await refusedAsNotVerified(searchNearby(deps, { uid, verifiedClaim: false }, { schoolId: "nile", radiusKm: 3 }));
      // A stale or forged claim does not help: the record decides.
      await refusedAsNotVerified(searchNearby(deps, { uid, verifiedClaim: true }, { schoolId: "nile", radiusKm: 3 }));
    }
  });

  it("carpools: start, find, join, invite links and 'looking for a carpool'", async () => {
    const deps = carpools();
    for (const uid of ["nora", "pia", "rana"]) {
      for (const verifiedClaim of [false, true]) {
        const as = { uid, verifiedClaim };
        await refusedAsNotVerified(
          createCarpool(deps, as, {
            kind: "school",
            schoolId: "nile",
            areaId: "degla",
            morning: "07:30",
            afternoon: "14:30",
            days: ["sun", "mon", "tue", "wed", "thu"],
            driveDays: ["sun", "tue"],
            seats: 4,
            childIds: [`${uid}-c`],
            rules: ["no_smoking", "seat_belts"],
            contribution: { amount: 50, period: "week" },
          }),
        );
        await refusedAsNotVerified(searchCarpools(deps, as, { kind: "school", schoolId: "nile" }));
        await refusedAsNotVerified(
          requestToJoin(deps, as, { carpoolId: "k1", childIds: [`${uid}-c`], acceptRules: true, acceptContribution: true }),
        );
        await refusedAsNotVerified(openInvite(deps, as, { code: "ABCDEFGH22" }));
        await refusedAsNotVerified(saveWanted(deps, as, { schoolId: "nile", morning: "07:30", days: ["sun", "mon"], childIds: [`${uid}-c`] }));
        await refusedAsNotVerified(listWanted(deps, as, { schoolId: "nile" }));
      }
    }
  });
});
