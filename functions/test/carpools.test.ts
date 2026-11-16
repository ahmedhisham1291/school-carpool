import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  cancelJoinRequest,
  createCarpool,
  createInvite,
  decideJoinRequest,
  DEFAULT_CARPOOL_LIMITS,
  deleteWanted,
  INVITE_CODE,
  leaveCarpool,
  listWanted,
  openInvite,
  requestToJoin,
  saveWanted,
  searchCarpools,
  setDriverConsent,
  setPickupSharing,
  type Caller,
  type CarpoolDeps,
} from "../src/carpools/flow";
import { newInviteCode } from "../src/carpools/callables";
import { FeatureOffError } from "../src/features/model";
import {
  cairoDate,
  CarpoolError,
  carInfo,
  checkArrangement,
  driverStatus,
  parseContribution,
  parseTime,
  suggestion,
  wantedMatches,
  type ConsentRecord,
  type MemberRecord,
  type WantedRecord,
  VOLUNTEER_TERMS_VERSION,
} from "../src/carpools/model";
import { roundToGrid } from "../src/maps/geo";
import { MemoryCarpoolStore } from "./helpers/memory_carpools";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

// Fake parents, children and cars only.
function setup() {
  const store = new MemoryCarpoolStore();
  const clock = { now: Date.UTC(2026, 10, 14, 8) };
  let codes = 0;
  const deps: CarpoolDeps = {
    store,
    now: () => clock.now,
    limits: { ...DEFAULT_CARPOOL_LIMITS },
    newCode: () => `ABCDEFGH${String(22 + codes++).padStart(2, "2")}`.slice(0, 10),
    linkBase: "https://links.example/",
  };
  store.schools.set("nile", { id: "nile", nameAr: "النيل", nameEn: "Nile", status: "active" });
  store.schools.set("orman", { id: "orman", nameAr: "الأورمان", nameEn: "Orman", status: "active" });
  store.schools.set("old", { id: "old", nameAr: "قديمة", nameEn: "Old", status: "merged" });
  store.areas.set("degla", { id: "degla", schoolId: "nile", nameAr: "دجلة", nameEn: "Degla" });
  store.areas.set("sarayat", { id: "sarayat", schoolId: "nile", nameAr: "السرايات", nameEn: "Sarayat" });
  store.areas.set("dokki", { id: "dokki", schoolId: "orman", nameAr: "الدقي", nameEn: "Dokki" });
  const people: Array<[string, string, string]> = [
    ["alice", "Alice", "verified"],
    ["bob", "Bob", "verified"],
    ["cara", "Cara", "verified"],
    ["dina", "Dina", "verified"],
    ["eve", "Eve", "pending"],
    ["sam", "Sam", "suspended"],
  ];
  for (const [uid, firstName, status] of people) store.accounts.set(uid, { status, firstName });
  store.children.set("alice", [{ id: "a1", firstName: "Adam", grade: "g3", schoolId: "nile" }]);
  store.children.set("bob", [
    { id: "b1", firstName: "Bassel", grade: "g2", schoolId: "nile" },
    { id: "b2", firstName: "Bana", grade: "kg2", schoolId: "nile" },
  ]);
  store.children.set("cara", [{ id: "c1", firstName: "Celine", grade: "g5", schoolId: "nile" }]);
  store.children.set("dina", [{ id: "d1", firstName: "Dalia", grade: "g1", schoolId: "orman" }]);
  const car = (seats: number, until = "2028-01-31") => ({ status: "approved", seats, licenseExpiry: until, carLicenseExpiry: "2029-05-01" });
  store.vehicles.set("alice", car(4));
  store.vehicles.set("bob", car(6));
  store.vehicles.set("dina", car(3));
  store.homes.set("alice", { location: { lat: 29.96123, lng: 31.25671 }, label: "Road 9 (test)" });
  store.homes.set("cara", { location: { lat: 29.96788, lng: 31.26244 }, label: "Road 50 (test)" });
  return { store, clock, deps };
}

const as = (uid: string, verifiedClaim = true): Caller => ({ uid, verifiedClaim });

const schoolCarpool = (extra: Record<string, unknown> = {}) => ({
  kind: "school",
  schoolId: "nile",
  areaId: "degla",
  morning: "07:30",
  afternoon: "14:30",
  days: ["sun", "mon", "tue", "wed", "thu"],
  driveDays: ["sun", "tue"],
  seats: 4,
  childIds: ["a1"],
  rules: ["no_smoking", "seat_belts"],
  contribution: { amount: 50, period: "week", note: " Fuel  share " },
  acceptVolunteer: true,
  ...extra,
});

async function rejects(p: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(p, (e: unknown) => e instanceof CarpoolError && e.reason === reason);
}

async function aliceCarpool(deps: CarpoolDeps, extra: Record<string, unknown> = {}): Promise<string> {
  return (await createCarpool(deps, as("alice"), schoolCarpool(extra))).carpoolId;
}

async function join(deps: CarpoolDeps, uid: string, carpoolId: string, childIds: string[]): Promise<void> {
  await requestToJoin(deps, as(uid), { carpoolId, childIds, acceptRules: true, acceptVolunteer: true, acceptContribution: true });
  await decideJoinRequest(deps, as("alice"), { carpoolId, uid, approve: true });
}

describe("parsing", () => {
  it("times are HH:MM between 05:00 and 22:00 in 5-minute steps", () => {
    assert.equal(parseTime("07:30"), "07:30");
    assert.equal(parseTime(null), null);
    for (const bad of ["7:30", "04:55", "22:05", "07:31", "25:00", 730]) assert.throws(() => parseTime(bad), CarpoolError);
  });

  it("contribution is optional, whole pounds, a fixed period, a short note", () => {
    assert.equal(parseContribution(null), null);
    assert.deepEqual(parseContribution({ amount: 50, period: "month", note: "  a   b " }), { amount: 50, period: "month", note: "a b" });
    for (const bad of [{ amount: 0, period: "week" }, { amount: 10.5, period: "week" }, { amount: 10001, period: "week" }, { amount: 5, period: "year" }]) {
      assert.throws(() => parseContribution(bad), CarpoolError);
    }
  });

  it("a car counts only when approved, and is valid until the earlier expiry", () => {
    assert.equal(carInfo(null), null);
    assert.equal(carInfo({ status: "pending", seats: 4, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" }), null);
    assert.deepEqual(carInfo({ status: "approved", seats: 4, licenseExpiry: "2030-01-01", carLicenseExpiry: "2029-02-03" }), {
      seats: 4,
      validUntil: "2029-02-03",
    });
  });

  it("Cairo dates", () => {
    assert.equal(cairoDate(Date.UTC(2026, 10, 14, 22, 30)), "2026-11-15");
  });

  it("invite codes use letters and digits that cannot be confused", () => {
    for (let i = 0; i < 200; i++) assert.match(newInviteCode(), INVITE_CODE);
  });
});

describe("create (F5, F25, F36, F39)", () => {
  it("the creator becomes the admin and an approved member; the carpool is public to verified parents", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    const c = store.carpools.get(id);
    assert.ok(c);
    assert.equal(c.status, "active");
    assert.equal(c.childrenCount, 1);
    assert.equal(c.memberCount, 1);
    assert.equal(c.areaNameEn, "Degla");
    assert.deepEqual(c.rules, ["no_smoking", "seat_belts"]);
    assert.deepEqual(c.contribution, { amount: 50, period: "week", note: "Fuel share" });
    const m = store.memberships.get(`${id}_alice`);
    assert.equal(m?.status, "approved");
    assert.equal(m?.role, "admin");
    assert.deepEqual(m?.drivingDays, ["sun", "tue"]);
    assert.equal(store.members.get(id)?.get("alice")?.children[0].firstName, "Adam");
  });

  it("seats can never be more than the car's passenger seats", async () => {
    const { deps } = setup();
    await rejects(createCarpool(deps, as("alice"), schoolCarpool({ seats: 5 })), "car-too-small");
  });

  it("refuses more of the creator's own children than seats", async () => {
    const { deps } = setup();
    await rejects(createCarpool(deps, as("bob"), schoolCarpool({ seats: 1, childIds: ["b1", "b2"], areaId: null })), "too-many-children");
  });

  it("the creator needs an approved car with valid papers", async () => {
    const { deps, store } = setup();
    await rejects(createCarpool(deps, as("cara"), schoolCarpool({ childIds: ["c1"] })), "no-car");
    store.vehicles.set("alice", { status: "approved", seats: 4, licenseExpiry: "2026-11-13", carLicenseExpiry: "2030-01-01" });
    await rejects(aliceCarpool(deps), "car-expired");
  });

  it("only the parent's own approved children, at that school", async () => {
    const { deps } = setup();
    await rejects(aliceCarpool(deps, { childIds: ["b1"] }), "not-your-child");
    await rejects(aliceCarpool(deps, { childIds: [] }), "no-children");
    await rejects(createCarpool(deps, as("dina"), schoolCarpool({ childIds: ["d1"], seats: 3 })), "wrong-school");
  });

  it("the area must belong to the school, and the school must be active", async () => {
    const { deps } = setup();
    await rejects(aliceCarpool(deps, { areaId: "dokki" }), "invalid-area");
    await rejects(aliceCarpool(deps, { schoolId: "old" }), "invalid-school");
  });

  it("refuses bad input: no time, drive days outside the days, unknown rules", async () => {
    const { deps } = setup();
    await rejects(aliceCarpool(deps, { morning: null, afternoon: null }), "invalid-request");
    await rejects(aliceCarpool(deps, { driveDays: ["sat"] }), "invalid-request");
    await rejects(aliceCarpool(deps, { rules: ["no_smoking", "loud_music"] }), "invalid-request");
    await rejects(aliceCarpool(deps, { days: [] }), "invalid-request");
    await rejects(aliceCarpool(deps, { seats: 9 }), "invalid-request");
  });

  it("only verified parents, never suspended or pending ones", async () => {
    const { deps } = setup();
    await rejects(createCarpool(deps, as("alice", false), schoolCarpool()), "not-verified");
    await rejects(createCarpool(deps, as("eve"), schoolCarpool()), "not-verified");
    await rejects(createCarpool(deps, as("sam"), schoolCarpool()), "suspended");
    await rejects(createCarpool(deps, as("nobody"), schoolCarpool()), "no-account");
  });

  it("creating and joining need the volunteer acknowledgement (free turns, no payment for rides); its version is recorded", async () => {
    const { deps, store } = setup();
    await rejects(createCarpool(deps, as("alice"), schoolCarpool({ acceptVolunteer: false })), "must-accept");
    await rejects(createCarpool(deps, as("alice"), schoolCarpool({ acceptVolunteer: undefined })), "must-accept");
    const id = await aliceCarpool(deps);
    assert.equal([...store.memberships.values()].find((m) => m.carpoolId === id && m.uid === "alice")?.volunteerTerms, VOLUNTEER_TERMS_VERSION);
    await rejects(requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptContribution: true }), "must-accept");
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptContribution: true, acceptVolunteer: true });
    assert.equal([...store.memberships.values()].find((m) => m.carpoolId === id && m.uid === "bob")?.volunteerTerms, VOLUNTEER_TERMS_VERSION);
  });

  it("an activity carpool keeps its place rounded to about 500 m (F39)", async () => {
    const { deps, store } = setup();
    const location = { lat: 29.96543, lng: 31.27711 };
    const { carpoolId } = await createCarpool(
      deps,
      as("alice"),
      schoolCarpool({ kind: "activity", schoolId: undefined, areaId: undefined, activity: { name: "Swimming (test)", label: "Club (test)", location } }),
    );
    const c = store.carpools.get(carpoolId);
    assert.equal(c?.kind, "activity");
    assert.equal(c?.schoolId, null);
    assert.deepEqual(c?.activity?.point, roundToGrid(location));
    assert.equal(c?.activity?.geohash.length, 7);
  });

  it("creating is limited per day", async () => {
    const { deps } = setup();
    deps.limits.createsPerDay = 2;
    await aliceCarpool(deps);
    await aliceCarpool(deps);
    await rejects(aliceCarpool(deps), "rate-limited");
  });
});

describe("search (F5, F6, F36, F39)", () => {
  it("verified parents of the same school find it, with rules, contribution and free seats", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps);
    const { carpools } = await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile" });
    assert.equal(carpools.length, 1);
    assert.equal(carpools[0].id, id);
    assert.equal(carpools[0].seatsLeft, 3);
    assert.deepEqual(carpools[0].rules, ["no_smoking", "seat_belts"]);
    assert.equal(carpools[0].contribution?.amount, 50);
    assert.equal(carpools[0].myStatus, null);
    // Never the creator's uid, children or car.
    assert.equal(JSON.stringify(carpools).includes("alice"), false);
    assert.equal(JSON.stringify(carpools).includes("Adam"), false);
  });

  it("another school's parents cannot search it; driving schools count (Prompt 5)", async () => {
    const { deps, store } = setup();
    await aliceCarpool(deps);
    await rejects(searchCarpools(deps, as("dina"), { kind: "school", schoolId: "nile" }), "not-your-school");
    store.driving.set("dina", ["nile"]);
    assert.equal((await searchCarpools(deps, as("dina"), { kind: "school", schoolId: "nile" })).carpools.length, 1);
    await rejects(searchCarpools(deps, as("eve"), { kind: "school", schoolId: "nile" }), "not-verified");
  });

  it("filters by area and by times within 30 minutes", async () => {
    const { deps } = setup();
    await aliceCarpool(deps);
    const find = async (q: Record<string, unknown>) => (await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile", ...q })).carpools.length;
    assert.equal(await find({ areaId: "degla" }), 1);
    assert.equal(await find({ areaId: "sarayat" }), 0);
    assert.equal(await find({ morning: "08:00" }), 1);
    assert.equal(await find({ morning: "08:05" }), 0);
    assert.equal(await find({ afternoon: "14:00" }), 1);
    assert.equal(await find({ afternoon: "13:55" }), 0);
  });

  it("full carpools are hidden, except to their members", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps, { seats: 3 });
    await join(deps, "bob", id, ["b1", "b2"]);
    assert.equal((await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile" })).carpools.length, 0);
    const bobs = (await searchCarpools(deps, as("bob"), { kind: "school", schoolId: "nile" })).carpools;
    assert.equal(bobs[0].myStatus, "approved");
  });

  it("the nearby card's Join shows only that parent's carpools", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps);
    await createCarpool(deps, as("bob"), schoolCarpool({ childIds: ["b1"], areaId: "sarayat" }));
    const { carpools } = await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile", parentUid: "alice" });
    assert.deepEqual(carpools.map((c) => c.id), [id]);
    // Full carpools stay hidden here too.
    await join(deps, "bob", id, ["b1", "b2"]);
    const fourth = await createCarpool(deps, as("alice"), schoolCarpool({ seats: 1 }));
    const again = await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile", parentUid: "alice" });
    assert.equal(again.carpools.some((c) => c.id === fourth.carpoolId), false);
  });

  it("activity carpools are found by distance from the parent's rounded home", async () => {
    const { deps, store } = setup();
    const near = { lat: 29.97, lng: 31.26 };
    const far = { lat: 30.06261, lng: 31.21973 };
    const make = (location: { lat: number; lng: number }) =>
      createCarpool(deps, as("alice"), schoolCarpool({ kind: "activity", activity: { name: "Club (test)", label: "", location } }));
    const a = await make(near);
    await make(far);
    const { carpools } = await searchCarpools(deps, as("cara"), { kind: "activity", radiusKm: 3, activityName: "club  (TEST)" });
    assert.deepEqual(carpools.map((c) => c.id), [a.carpoolId]);
    assert.equal(carpools[0].distanceKm, 1);
    assert.ok(store.activityQueries.length <= 9);
    await rejects(searchCarpools(deps, as("bob"), { kind: "activity", activityName: "Club (test)" }), "no-home");
    await rejects(searchCarpools(deps, as("cara"), { kind: "activity", radiusKm: 7, activityName: "Club (test)" }), "invalid-request");
    // R9: one activity at a time; no activity name, no search.
    assert.deepEqual((await searchCarpools(deps, as("cara"), { kind: "activity", radiusKm: 3, activityName: "Football (test)" })).carpools, []);
    await rejects(searchCarpools(deps, as("cara"), { kind: "activity", radiusKm: 3 }), "invalid-request");
    // R9: never on the nearby map's "this parent's carpools" list (no public ride offers).
    assert.deepEqual((await searchCarpools(deps, as("cara"), { kind: "activity", radiusKm: 3, activityName: "Club (test)", parentUid: "alice" })).carpools, []);
  });

  it("R9: activity carpools (F39) are off in the pilot: create, search and join refuse with feature-off", async () => {
    const { deps } = setup();
    let on = true;
    deps.activityCarpoolsOn = async () => on;
    const location = { lat: 29.97, lng: 31.26 };
    const made = await createCarpool(deps, as("alice"), schoolCarpool({ kind: "activity", activity: { name: "Club (test)", label: "", location } }));
    on = false;
    const isOff = (e: unknown) => e instanceof FeatureOffError && e.feature === "activityCarpools";
    await assert.rejects(createCarpool(deps, as("alice"), schoolCarpool({ kind: "activity", activity: { name: "Club (test)", label: "", location } })), isOff);
    await assert.rejects(searchCarpools(deps, as("cara"), { kind: "activity", radiusKm: 3, activityName: "Club (test)" }), isOff);
    await assert.rejects(requestToJoin(deps, as("cara"), { carpoolId: made.carpoolId, childIds: ["c1"], acceptRules: true, acceptVolunteer: true }), isOff);
    // School carpools are not touched.
    await createCarpool(deps, as("alice"), schoolCarpool());
  });

  it("searches are limited per hour", async () => {
    const { deps, clock } = setup();
    deps.limits.searchesPerHour = 2;
    await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile" });
    await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile" });
    await rejects(searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile" }), "rate-limited");
    clock.now += HOUR;
    await searchCarpools(deps, as("cara"), { kind: "school", schoolId: "nile" });
  });
});

describe("join requests and approval (F6, F25, F36)", () => {
  it("a request with the children's first names and grades reaches the admin; approval makes a member", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1", "b2"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    assert.equal(store.memberships.get(`${id}_bob`)?.status, "requested");
    const req = store.requests.get(id)?.get("bob");
    assert.deepEqual(req?.children.map((c) => [c.firstName, c.grade]), [["Bassel", "g2"], ["Bana", "kg2"]]);
    assert.equal(store.members.get(id)?.has("bob"), false, "not a member before approval");

    await decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "bob", approve: true });
    assert.equal(store.memberships.get(`${id}_bob`)?.status, "approved");
    assert.equal(store.memberships.get(`${id}_bob`)?.decidedBy, "alice");
    assert.equal(store.requests.get(id)?.has("bob"), false);
    assert.equal(store.members.get(id)?.get("bob")?.car?.seats, 6);
    assert.equal(store.carpools.get(id)?.childrenCount, 3);
    assert.equal(store.carpools.get(id)?.memberCount, 2);
  });

  it("rules and the contribution must be accepted", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps);
    await rejects(requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: false, acceptContribution: true }), "must-accept");
    await rejects(requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: false }), "must-accept");
    const free = await aliceCarpool(deps, { contribution: null });
    await requestToJoin(deps, as("bob"), { carpoolId: free, childIds: ["b1"], acceptRules: true, acceptVolunteer: true });
  });

  it("contributions switched off (owner, 16 Nov 2026: no money in the app): a new one is refused, joining never asks for an old one, searches hide it", async () => {
    const { deps, store } = setup();
    // A carpool made while contributions were on (staging data).
    const old = await aliceCarpool(deps);
    const off: CarpoolDeps = { ...deps, contributionsOn: async () => false };
    await assert.rejects(
      createCarpool(off, as("bob"), schoolCarpool({ childIds: ["b1"] })),
      (e: unknown) => e instanceof FeatureOffError && e.feature === "contributions",
    );
    const free = (await createCarpool(off, as("bob"), schoolCarpool({ childIds: ["b1"], contribution: null }))).carpoolId;
    assert.equal(store.carpools.get(free)?.contribution, null);
    const { carpools } = await searchCarpools(off, as("cara"), { kind: "school", schoolId: "nile" });
    assert.equal(carpools.length, 2);
    for (const c of carpools) assert.equal(c.contribution, null, "no amount is shown while off");
    // Joining the old carpool: no contribution to accept, none recorded.
    await requestToJoin(off, as("cara"), { carpoolId: old, childIds: ["c1"], acceptRules: true, acceptVolunteer: true });
    assert.equal([...store.memberships.values()].find((m) => m.carpoolId === old && m.uid === "cara")?.acceptedContribution, false);
  });

  it("refuses children that do not fit the free seats", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps, { seats: 2 });
    await rejects(requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1", "b2"], acceptRules: true, acceptVolunteer: true, acceptContribution: true }), "no-seats");
  });

  it("approval re-checks the seats: two requests that each fit cannot both be approved", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps, { seats: 3 });
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1", "b2"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await requestToJoin(deps, as("cara"), { carpoolId: id, childIds: ["c1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "bob", approve: true });
    await rejects(decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "cara", approve: true }), "no-seats");
    assert.equal(store.carpools.get(id)?.childrenCount, 3);
    assert.equal(store.memberships.get(`${id}_cara`)?.status, "requested");
  });

  it("only the admin decides; a decline is recorded", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await join(deps, "bob", id, ["b1"]);
    await requestToJoin(deps, as("cara"), { carpoolId: id, childIds: ["c1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await rejects(decideJoinRequest(deps, as("bob"), { carpoolId: id, uid: "cara", approve: true }), "not-admin");
    await rejects(decideJoinRequest(deps, as("dina"), { carpoolId: id, uid: "cara", approve: true }), "not-member");
    await decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "cara", approve: false });
    assert.equal(store.memberships.get(`${id}_cara`)?.status, "declined");
    assert.equal(store.members.get(id)?.has("cara"), false);
    // A declined parent may ask again.
    await requestToJoin(deps, as("cara"), { carpoolId: id, childIds: ["c1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
  });

  it("Prompt 8: a join request tells the admins, a decision tells the requester (IDs only)", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    const before = store.events.length;
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await requestToJoin(deps, as("cara"), { carpoolId: id, childIds: ["c1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "bob", approve: true });
    await decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "cara", approve: false });
    const events = store.events.slice(before).map((e) => ({ type: e.type, recipients: e.recipients, carpoolId: e.carpoolId, actorUid: e.actorUid }));
    assert.deepEqual(events, [
      { type: "join-requested", recipients: ["alice"], carpoolId: id, actorUid: "bob" },
      { type: "join-requested", recipients: ["alice"], carpoolId: id, actorUid: "cara" },
      { type: "join-approved", recipients: ["bob"], carpoolId: id, actorUid: "alice" },
      { type: "join-declined", recipients: ["cara"], carpoolId: id, actorUid: "alice" },
    ]);
    // No names in the events: the app loads the request after it opens.
    assert.ok(!/Bob|Cara|Alice|Bassel|Celine|Adam/.test(JSON.stringify(store.events)));
  });

  it("no double requests, no joining twice, children of the right school only", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await rejects(requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true }), "already-requested");
    await rejects(requestToJoin(deps, as("alice"), { carpoolId: id, childIds: ["a1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true }), "already-member");
    store.driving.set("dina", ["nile"]);
    await rejects(requestToJoin(deps, as("dina"), { carpoolId: id, childIds: ["d1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true }), "wrong-school");
  });

  it("a requester can cancel", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await cancelJoinRequest(deps, as("bob"), { carpoolId: id });
    assert.equal(store.memberships.get(`${id}_bob`)?.status, "left");
    assert.equal(store.requests.get(id)?.has("bob"), false);
    await rejects(cancelJoinRequest(deps, as("bob"), { carpoolId: id }), "not-requested");
  });

  it("join requests are limited per day", async () => {
    const { deps } = setup();
    deps.limits.joinRequestsPerDay = 1;
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await cancelJoinRequest(deps, as("bob"), { carpoolId: id });
    await rejects(requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true }), "rate-limited");
  });
});

describe("driver consent (F26) and seats", () => {
  const member = (uid: string, children: string[], seats: number | null, validUntil = "2030-01-01"): MemberRecord => ({
    uid,
    role: "member",
    firstName: uid,
    children: children.map((id) => ({ id, firstName: id, grade: "g1" })),
    car: seats === null ? null : { seats, validUntil },
    drivingDays: [],
    pickupShared: false,
    joinedAtMs: 0,
  });
  const consent = (parentUid: string, driverUid: string, status: "accepted" | "withdrawn" = "accepted"): ConsentRecord => ({
    carpoolId: "k",
    parentUid,
    driverUid,
    status,
    acceptedAtMs: 1,
    withdrawnAtMs: status === "withdrawn" ? 2 : null,
    updatedAtMs: 2,
  });
  const today = "2026-11-14";

  it("a new member cannot drive other children until each parent accepted", () => {
    const members = [member("alice", ["a1"], 4), member("bob", ["b1", "b2"], 6), member("cara", ["c1"], null)];
    let s = driverStatus(members[1], members, [], today);
    assert.equal(s.canDrive, false);
    assert.deepEqual(s.waitingFor, ["alice", "cara"]);
    s = driverStatus(members[1], members, [consent("alice", "bob")], today);
    assert.deepEqual(s.waitingFor, ["cara"]);
    s = driverStatus(members[1], members, [consent("alice", "bob"), consent("cara", "bob")], today);
    assert.equal(s.canDrive, true);
    s = driverStatus(members[1], members, [consent("alice", "bob"), consent("cara", "bob", "withdrawn")], today);
    assert.equal(s.canDrive, false, "withdrawn consent counts as none");
    assert.equal(driverStatus(members[2], members, [], today).problem, "no-car");
  });

  it("a driver whose car has fewer passenger seats than the children cannot drive them all", () => {
    const members = [member("alice", ["a1"], 3), member("bob", ["b1", "b2", "b3"], 6)];
    const s = driverStatus(members[0], members, [consent("bob", "alice")], today);
    assert.equal(s.problem, "car-too-small");
    assert.equal(s.canDrive, false);
  });

  it("checkArrangement refuses runs with more children than seats, missing consent or expired papers", () => {
    const members = [member("alice", ["a1"], 2), member("bob", ["b1", "b2"], 6, "2026-11-13"), member("cara", ["c1"], null)];
    assert.deepEqual(checkArrangement({ driverUid: "alice", childIds: ["a1", "b1", "c1"], members, consents: [], today }), {
      reason: "too-many-children",
      children: 3,
      seats: 2,
    });
    assert.deepEqual(checkArrangement({ driverUid: "alice", childIds: ["a1", "b1"], members, consents: [], today }), {
      reason: "no-consent",
      parents: ["bob"],
    });
    assert.equal(checkArrangement({ driverUid: "alice", childIds: ["a1", "b1"], members, consents: [consent("bob", "alice")], today }), null);
    assert.equal(checkArrangement({ driverUid: "alice", childIds: ["a1"], members, consents: [], today }), null, "own children need no consent");
    assert.deepEqual(checkArrangement({ driverUid: "bob", childIds: ["b1"], members, consents: [], today }), { reason: "car-expired" });
    assert.deepEqual(checkArrangement({ driverUid: "cara", childIds: ["c1"], members, consents: [], today }), { reason: "no-car" });
    assert.deepEqual(checkArrangement({ driverUid: "alice", childIds: ["x9"], members, consents: [], today }), { reason: "unknown-child", childId: "x9" });
    assert.deepEqual(checkArrangement({ driverUid: "zed", childIds: ["a1"], members, consents: [], today }), { reason: "not-member" });
  });

  it("members accept each other as drivers and can withdraw at any time", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await join(deps, "bob", id, ["b1"]);
    await setDriverConsent(deps, as("alice"), { carpoolId: id, driverUid: "bob", accept: true });
    await setDriverConsent(deps, as("bob"), { carpoolId: id, driverUid: "alice", accept: true });
    const consents = [...(store.consents.get(id)?.values() ?? [])];
    const members = [...(store.members.get(id)?.values() ?? [])];
    assert.equal(driverStatus(members.find((m) => m.uid === "bob") as MemberRecord, members, consents, today).canDrive, true);
    assert.equal(driverStatus(members.find((m) => m.uid === "alice") as MemberRecord, members, consents, today).canDrive, true);

    const w = await setDriverConsent(deps, as("alice"), { carpoolId: id, driverUid: "bob", accept: false });
    assert.equal(w.status, "withdrawn");
    assert.ok(w.acceptedAtMs !== null && w.withdrawnAtMs !== null);
    const after = [...(store.consents.get(id)?.values() ?? [])];
    assert.equal(driverStatus(members.find((m) => m.uid === "bob") as MemberRecord, members, after, today).canDrive, false);
  });

  it("consent only between approved members, never to oneself", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await rejects(setDriverConsent(deps, as("alice"), { carpoolId: id, driverUid: "bob", accept: true }), "not-member");
    await rejects(setDriverConsent(deps, as("bob"), { carpoolId: id, driverUid: "alice", accept: true }), "not-member");
    await rejects(setDriverConsent(deps, as("alice"), { carpoolId: id, driverUid: "alice", accept: true }), "self-consent");
  });

  it("leaving removes the member, frees seats, deletes the pickup point and every consent given to or by them", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await join(deps, "cara", id, ["c1"]);
    await setDriverConsent(deps, as("alice"), { carpoolId: id, driverUid: "cara", accept: true });
    await setDriverConsent(deps, as("cara"), { carpoolId: id, driverUid: "alice", accept: true });
    await setPickupSharing(deps, as("cara"), { carpoolId: id, share: true });
    await leaveCarpool(deps, as("cara"), { carpoolId: id });
    assert.equal(store.memberships.get(`${id}_cara`)?.status, "left");
    assert.equal(store.members.get(id)?.has("cara"), false);
    assert.equal(store.pickups.get(id)?.has("cara"), false);
    assert.equal(store.consents.get(id)?.size, 0);
    assert.equal(store.carpools.get(id)?.childrenCount, 1);
    // Joining again needs fresh consent.
    await join(deps, "cara", id, ["c1"]);
    const members = [...(store.members.get(id)?.values() ?? [])];
    assert.deepEqual(driverStatus(members.find((m) => m.uid === "alice") as MemberRecord, members, [], today).waitingFor, ["cara"]);
  });

  it("closing the carpool declines its open requests", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await leaveCarpool(deps, as("alice"), { carpoolId: id });
    assert.equal(store.memberships.get(`${id}_bob`)?.status, "declined");
    assert.equal(store.requests.get(id)?.size ?? 0, 0);
  });

  it("a requester whose account is gone cannot be approved", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    store.accounts.delete("bob");
    await rejects(decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "bob", approve: true }), "not-verified");
  });

  it("the admin stays while others are members; leaving last closes the carpool", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await join(deps, "bob", id, ["b1"]);
    await rejects(leaveCarpool(deps, as("alice"), { carpoolId: id }), "admin-must-stay");
    await leaveCarpool(deps, as("bob"), { carpoolId: id });
    await leaveCarpool(deps, as("alice"), { carpoolId: id });
    assert.equal(store.carpools.get(id)?.status, "closed");
    await rejects(requestToJoin(deps, as("cara"), { carpoolId: id, childIds: ["c1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true }), "closed");
  });
});

describe("pickup points (exact, approved members only)", () => {
  it("shares the exact home only on request, and needs a home", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    await join(deps, "bob", id, ["b1"]);
    await rejects(setPickupSharing(deps, as("bob"), { carpoolId: id, share: true }), "no-home");
    assert.equal(store.pickups.get(id)?.size ?? 0, 0, "nothing is shared by default");
    await setPickupSharing(deps, as("alice"), { carpoolId: id, share: true });
    assert.deepEqual(store.pickups.get(id)?.get("alice")?.location, { lat: 29.96123, lng: 31.25671 });
    assert.equal(store.members.get(id)?.get("alice")?.pickupShared, true);
    await setPickupSharing(deps, as("alice"), { carpoolId: id, share: false });
    assert.equal(store.pickups.get(id)?.has("alice"), false);
    await rejects(setPickupSharing(deps, as("cara"), { carpoolId: id, share: true }), "not-member");
  });
});

describe("invite links (F31)", () => {
  it("a member makes a link; a verified parent opens it and still has to ask to join", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    const invite = await createInvite(deps, as("alice"), { carpoolId: id });
    assert.match(invite.code, INVITE_CODE);
    assert.equal(invite.url, `https://links.example/c/${invite.code}`);
    assert.deepEqual(await openInvite(deps, as("cara"), { code: invite.code.toLowerCase() }), { carpoolId: id });
    assert.equal(store.memberships.has(`${id}_cara`), false, "opening an invite joins nothing");
  });

  it("the invited parent must be verified", async () => {
    const { deps } = setup();
    const id = await aliceCarpool(deps);
    const { code } = await createInvite(deps, as("alice"), { carpoolId: id });
    await rejects(openInvite(deps, as("eve"), { code }), "not-verified");
    await rejects(openInvite(deps, as("cara", false), { code }), "not-verified");
  });

  it("only members make links; links expire; unknown codes are refused and limited", async () => {
    const { deps, clock } = setup();
    deps.limits.inviteOpensPerHour = 2;
    const id = await aliceCarpool(deps);
    await rejects(createInvite(deps, as("cara"), { carpoolId: id }), "not-member");
    const { code } = await createInvite(deps, as("alice"), { carpoolId: id });
    await rejects(openInvite(deps, as("cara"), { code: "ZZZZZZZZZZ" }), "invite-invalid");
    await rejects(openInvite(deps, as("cara"), { code: "bad" }), "invite-invalid");
    await rejects(openInvite(deps, as("cara"), { code }), "rate-limited");
    clock.now += 15 * DAY;
    await rejects(openInvite(deps, as("cara"), { code }), "invite-invalid");
  });
});

describe("looking for a carpool (F32)", () => {
  const post = (uid: string, extra: Partial<WantedRecord> = {}): WantedRecord => ({
    uid,
    firstName: uid,
    schoolId: "nile",
    schoolNameAr: "",
    schoolNameEn: "",
    areaId: "degla",
    areaNameAr: "",
    areaNameEn: "",
    morning: "07:30",
    afternoon: null,
    days: ["sun", "mon", "tue"],
    childrenCount: 1,
    createdAtMs: 0,
    expiresAtMs: Number.MAX_SAFE_INTEGER,
    ...extra,
  });

  it("matches the same school and area, close times and a shared day", () => {
    const me = post("me");
    assert.equal(wantedMatches(me, post("a", { morning: "07:55" })), true);
    assert.equal(wantedMatches(me, post("a", { morning: "08:15" })), false);
    assert.equal(wantedMatches(me, post("a", { areaId: "sarayat" })), false);
    assert.equal(wantedMatches(me, post("a", { areaId: null })), true);
    assert.equal(wantedMatches(me, post("a", { schoolId: "orman" })), false);
    assert.equal(wantedMatches(me, post("a", { days: ["thu"] })), false);
    assert.equal(wantedMatches(me, post("a", { morning: null, afternoon: "14:00" })), false, "no shared direction");
    assert.equal(wantedMatches(me, post("me")), false);
  });

  it("suggests a group at three families, not two", () => {
    const me = post("me");
    assert.equal(suggestion(me, [post("a")]), null);
    const s = suggestion(me, [post("a", { days: ["sun"] }), post("b", { days: ["mon", "wed"] }), post("c", { morning: "10:00" })]);
    assert.deepEqual(s, { families: 3, areaId: "degla", morning: "07:30", afternoon: null, days: ["sun", "mon"] });
    assert.equal(suggestion(null, [post("a"), post("b")]), null);
  });

  it("verified parents post for their child's school and see the same school's posts with the suggestion", async () => {
    const { deps, store } = setup();
    store.children.set("dina", [{ id: "d1", firstName: "Dalia", grade: "g1", schoolId: "nile" }]);
    const body = { schoolId: "nile", areaId: "degla", morning: "07:30", days: ["sun", "mon"], childIds: [] as string[] };
    await saveWanted(deps, as("bob"), { ...body, childIds: ["b1", "b2"] });
    await saveWanted(deps, as("cara"), { ...body, childIds: ["c1"], morning: "07:45" });
    let r = await listWanted(deps, as("cara"), { schoolId: "nile" });
    assert.equal(r.posts.length, 2);
    assert.equal(r.suggestion, null);
    await saveWanted(deps, as("dina"), { ...body, childIds: ["d1"], areaId: null, morning: "07:15" });
    r = await listWanted(deps, as("cara"), { schoolId: "nile" });
    assert.equal(r.suggestion?.families, 3);
    assert.equal(r.posts.find((p) => p.mine)?.firstName, "Cara");
    assert.equal(r.posts.find((p) => p.firstName === "Bob")?.childrenCount, 2);
    // Never children's names in the posts.
    assert.equal(JSON.stringify(r).includes("Bassel"), false);
  });

  it("posts need the parent's own child at that school; other schools cannot list; posts expire", async () => {
    const { deps, clock } = setup();
    await rejects(saveWanted(deps, as("bob"), { schoolId: "orman", days: ["sun"], morning: "07:30", childIds: ["b1"] }), "wrong-school");
    await rejects(saveWanted(deps, as("bob"), { schoolId: "nile", days: ["sun"], childIds: ["b1"] }), "invalid-request");
    await saveWanted(deps, as("bob"), { schoolId: "nile", days: ["sun"], morning: "07:30", childIds: ["b1"] });
    await rejects(listWanted(deps, as("dina"), { schoolId: "nile" }), "not-your-school");
    clock.now += 61 * DAY;
    assert.equal((await listWanted(deps, as("cara"), { schoolId: "nile" })).posts.length, 0);
  });

  it("a parent deletes their post", async () => {
    const { deps, store } = setup();
    await saveWanted(deps, as("bob"), { schoolId: "nile", days: ["sun"], morning: "07:30", childIds: ["b1"] });
    await deleteWanted(deps, as("bob"));
    assert.equal(store.wanteds.has("bob"), false);
  });
});

describe("done when: two fake parents", () => {
  it("one creates, the other finds it, asks, is approved, and both accept each other as drivers; an invite opens the right carpool", async () => {
    const { deps, store } = setup();
    const id = await aliceCarpool(deps);
    const found = (await searchCarpools(deps, as("bob"), { kind: "school", schoolId: "nile", morning: "07:30" })).carpools;
    assert.equal(found[0].id, id);
    await requestToJoin(deps, as("bob"), { carpoolId: id, childIds: ["b1"], acceptRules: true, acceptVolunteer: true, acceptContribution: true });
    await decideJoinRequest(deps, as("alice"), { carpoolId: id, uid: "bob", approve: true });
    await setDriverConsent(deps, as("alice"), { carpoolId: id, driverUid: "bob", accept: true });
    await setDriverConsent(deps, as("bob"), { carpoolId: id, driverUid: "alice", accept: true });
    const members = [...(store.members.get(id)?.values() ?? [])];
    const consents = [...(store.consents.get(id)?.values() ?? [])];
    for (const m of members) assert.equal(driverStatus(m, members, consents, "2026-11-14").canDrive, true, m.uid);
    const { code } = await createInvite(deps, as("bob"), { carpoolId: id });
    assert.deepEqual(await openInvite(deps, as("cara"), { code }), { carpoolId: id });
  });
});
