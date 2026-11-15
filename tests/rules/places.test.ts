// Rules for City -> Area -> District (F4 grouping, F46 addresses). Signed-in
// users read areas and districts (lists at most 500 at a time); nobody
// writes them from the app; the server's index and the "district not
// listed" requests are closed to every client. Runs only against the
// emulators. Written, not run here (no npm registry in the build
// workspace); CI runs it.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";

const root = join(__dirname, "..", "..", "..");

let env: RulesTestEnvironment;

const token = { firebase: { sign_in_provider: "custom" as const } };
const asAlice = (): RulesTestContext => env.authenticatedContext("alice", token);
const asAdmin = (): RulesTestContext => env.authenticatedContext("admin1", { ...token, admin: true });
const signedOut = (): RulesTestContext => env.unauthenticatedContext();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-school-carpool-places",
    firestore: { rules: readFileSync(join(root, "firestore.rules"), "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc("placeAreas/osm-r1").set({ governorate: "cairo", nameAr: "المعادي", nameEn: "Maadi", active: true, schoolCount: 3 });
    await db.doc("placeDistricts/osm-n1").set({ areaId: "osm-r1", governorate: "cairo", nameAr: "دجلة", nameEn: "Degla", active: true });
    await db.doc("placeIndex/areas").set({ areas: [{ id: "osm-r1", governorate: "cairo" }] });
    await db.doc("placeRequests/r1").set({ uid: "alice", areaId: "osm-r1", text: "الحي الجديد", status: "open" });
  });
});

after(async () => {
  await env?.cleanup();
});

describe("places: reading", () => {
  it("a signed-in parent reads and lists areas and districts", async () => {
    const db = asAlice().firestore();
    await assertSucceeds(db.doc("placeAreas/osm-r1").get());
    await assertSucceeds(db.collection("placeAreas").where("governorate", "==", "cairo").limit(500).get());
    await assertSucceeds(db.doc("placeDistricts/osm-n1").get());
    await assertSucceeds(db.collection("placeDistricts").where("areaId", "==", "osm-r1").limit(200).get());
  });

  it("lists need a limit of at most 500", async () => {
    const db = asAlice().firestore();
    await assertFails(db.collection("placeAreas").where("governorate", "==", "cairo").get());
    await assertFails(db.collection("placeAreas").limit(501).get());
    await assertFails(db.collection("placeDistricts").get());
  });

  it("signed-out users read nothing", async () => {
    const db = signedOut().firestore();
    await assertFails(db.doc("placeAreas/osm-r1").get());
    await assertFails(db.collection("placeDistricts").limit(10).get());
  });

  it("the index and the requests are closed, even to an admin's client", async () => {
    for (const ctx of [asAlice(), asAdmin()]) {
      const db = ctx.firestore();
      await assertFails(db.doc("placeIndex/areas").get());
      await assertFails(db.doc("placeRequests/r1").get());
      await assertFails(db.collection("placeRequests").where("uid", "==", "alice").limit(10).get());
    }
  });
});

describe("places: writing", () => {
  it("nobody writes areas, districts, the index or requests from a client", async () => {
    for (const ctx of [asAlice(), asAdmin()]) {
      const db = ctx.firestore();
      await assertFails(db.doc("placeAreas/osm-r1").update({ nameAr: "x" }));
      await assertFails(db.doc("placeAreas/new").set({ governorate: "cairo", nameAr: "x" }));
      await assertFails(db.doc("placeAreas/osm-r1").delete());
      await assertFails(db.doc("placeDistricts/osm-n1").update({ areaId: "other" }));
      await assertFails(db.doc("placeDistricts/new").set({ areaId: "osm-r1", nameAr: "x" }));
      await assertFails(db.doc("placeIndex/areas").set({ areas: [] }));
      await assertFails(db.doc("placeRequests/r2").set({ uid: "alice", text: "x" }));
    }
  });
});

// F46: the structured address lives in homes/{uid} with the exact point
// (owner only); the public record (parentLocations) is Cloud Functions only.
describe("addresses: the owner's only, and never written from the app", () => {
  const address = {
    governorate: "cairo", placeAreaId: "osm-r1", placeDistrictId: "osm-n1", street: "شارع 9", building: "12",
    floor: "", apartment: "", landmark: "", districtText: "",
  };

  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      const db = ctx.firestore();
      await db.doc("homes/alice").set({ location: null, label: "12 شارع 9", address, showOnMap: true, radiusKm: 3 });
      await db.doc("parentLocations/alice").set({ geohash: "stq4", placeAreaId: "osm-r1", placeDistrictId: "osm-n1" });
    });
  });

  it("the owner reads their address; nobody else does", async () => {
    await assertSucceeds(asAlice().firestore().doc("homes/alice").get());
    await assertFails(env.authenticatedContext("bob", token).firestore().doc("homes/alice").get());
    await assertFails(asAdmin().firestore().doc("homes/alice").get());
    await assertFails(signedOut().firestore().doc("homes/alice").get());
  });

  it("nobody writes an address or the area of the public record from a client", async () => {
    await assertFails(asAlice().firestore().doc("homes/alice").update({ "address.placeAreaId": "osm-r2" }));
    await assertFails(asAlice().firestore().doc("homes/alice").set({ address }));
    await assertFails(asAlice().firestore().doc("parentLocations/alice").update({ placeAreaId: "osm-r2" }));
    await assertFails(env.authenticatedContext("bob", token).firestore().doc("parentLocations/alice").get());
  });
});
