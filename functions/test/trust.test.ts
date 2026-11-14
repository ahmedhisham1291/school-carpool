// Trust and yearly checks (Prompt 11, F17). Fake data only. Run: npm test.
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import { DEFAULT_OTP_LIMITS, verifyCode, type OtpDeps } from "../src/auth/otp_flow";
import { createCarpool, decideJoinRequest, DEFAULT_CARPOOL_LIMITS, removeFromCarpool, requestToJoin, setDriverConsent, type Caller, type CarpoolDeps } from "../src/carpools/flow";
import { CarpoolError } from "../src/carpools/model";
import { ALL_ON, FeatureOffError, type FeatureKey } from "../src/features/model";
import { routeFor, TYPES } from "../src/notifications/catalog";
import { planWeek, setDrivingDays } from "../src/schedule/flow";
import { DEFAULT_DEADLINES, type RunRecord } from "../src/schedule/model";
import { applyCarChange, removeChildFromCarpools } from "../src/trust/carpools";
import {
  adminDecideGuardianLink,
  adminResolveRatingFlag,
  adminTrustQueue,
  answerGuardianRequest,
  cancelGuardianRequest,
  confirmSchoolYear,
  getFamily,
  getTrustOverview,
  getTrustSummary,
  listRateable,
  rateParent,
  removeGuardianLink,
  requestGuardianLink,
  yearCheckOf,
  type TrustDeps,
} from "../src/trust/flow";
import { blockedAccount, releaseOnBlock, runTrustDaily, type JobDeps } from "../src/trust/jobs";
import {
  licenceNotice,
  linkNeedsReview,
  parseRating,
  parseReminderDays,
  parseYearAnswers,
  runInvalid,
  sharedTrips,
  summaryView,
  TrustError,
  yearReminderStage,
  yearSettings,
  yearState,
  yearWindow,
  type TripLike,
} from "../src/trust/model";
import { confirmPhoneChange, phoneChangeKey, phoneSelfiePath, requestPhoneChange, type PhoneChangeDeps } from "../src/trust/phone";
import { keptApproval, samePlate, usableVehicle, type UsableVehicle } from "../src/verification/vehicle";
import type { KycResult } from "../src/verification/kyc";
import type { Language, WhatsAppSender } from "../src/whatsapp/sender";
import { MemoryCarpoolStore } from "./helpers/memory_carpools";
import { MemoryOtpStore } from "./helpers/memory_otp_store";
import { MemoryFiles, MemoryTrustStore } from "./helpers/memory_trust";

// Saturday 14 Nov 2026, 10:00 in Cairo.
const NOW = Date.UTC(2026, 10, 14, 8);
const WEEK = "2026-11-14";
const DAY = 86_400_000;

async function rejects(p: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(p, (e: unknown) => (e instanceof TrustError || e instanceof CarpoolError) && e.reason === reason);
}

const as = (uid: string): Caller => ({ uid, verifiedClaim: true });

function trip(id: string, driverUid: string, stops: Array<[string, string]>, extra: Partial<TripLike> = {}): TripLike {
  return { id, carpoolId: "k1", date: "2026-11-12", status: "ended", driverUid, stops: stops.map(([parentUid, state]) => ({ parentUid, state })), ...extra };
}

function setup(nowMs = NOW) {
  const carpoolStore = new MemoryCarpoolStore();
  const clock = { now: nowMs };
  const carpools: CarpoolDeps = {
    store: carpoolStore,
    now: () => clock.now,
    limits: { ...DEFAULT_CARPOOL_LIMITS },
    newCode: () => "ABCDEFGH22",
    linkBase: "https://links.example",
    deadlines: DEFAULT_DEADLINES,
  };
  carpoolStore.schools.set("nile", { id: "nile", nameAr: "النيل", nameEn: "Nile", status: "active" });
  carpoolStore.areas.set("degla", { id: "degla", schoolId: "nile", nameAr: "دجلة", nameEn: "Degla" });
  for (const [uid, name] of [["alice", "Alice"], ["bob", "Bob"], ["cara", "Cara"], ["dina", "Dina"]]) carpoolStore.accounts.set(uid, { status: "verified", firstName: name });
  carpoolStore.children.set("alice", [{ id: "a1", firstName: "Adam", grade: "g3", schoolId: "nile" }]);
  carpoolStore.children.set("bob", [
    { id: "b1", firstName: "Bassel", grade: "g2", schoolId: "nile" },
    { id: "b2", firstName: "Bana", grade: "kg2", schoolId: "nile" },
  ]);
  carpoolStore.children.set("cara", [{ id: "c1", firstName: "Celine", grade: "g5", schoolId: "nile" }]);
  const vehicle = (seats: number) => ({ status: "approved", seats, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" });
  carpoolStore.vehicles.set("alice", vehicle(4));
  carpoolStore.vehicles.set("bob", vehicle(6));

  const store = new MemoryTrustStore();
  for (const uid of ["alice", "bob", "cara", "dina"]) store.addParent(uid);
  store.addChild({ id: "a1", ownerUid: "alice", firstName: "Adam" });
  store.addChild({ id: "b1", ownerUid: "bob", firstName: "Bassel", grade: "g2" });
  store.addChild({ id: "b2", ownerUid: "bob", firstName: "Bana", grade: "kg2" });
  store.addChild({ id: "c1", ownerUid: "cara", firstName: "Celine", grade: "g5" });
  const deps: TrustDeps = {
    store,
    carpools,
    now: () => clock.now,
    rateWindowDays: 30,
    year: yearSettings("09-01", 21, 14, 2026),
  };
  return { store, carpoolStore, carpools, clock, deps };
}

async function readyCarpool(deps: CarpoolDeps): Promise<string> {
  const { carpoolId } = await createCarpool(deps, as("alice"), {
    kind: "school",
    schoolId: "nile",
    areaId: "degla",
    morning: "07:30",
    afternoon: "14:30",
    days: ["sun", "mon", "tue", "wed", "thu"],
    driveDays: ["sun", "mon", "tue", "wed", "thu"],
    seats: 4,
    childIds: ["a1"],
    rules: [],
  });
  for (const [uid, kids] of [["bob", ["b1", "b2"]], ["cara", ["c1"]]] as const) {
    await requestToJoin(deps, as(uid), { carpoolId, childIds: kids, acceptRules: true });
    await decideJoinRequest(deps, as("alice"), { carpoolId, uid, approve: true });
  }
  for (const [parent, driver] of [["bob", "alice"], ["cara", "alice"], ["alice", "bob"], ["cara", "bob"]]) {
    await setDriverConsent(deps, as(parent), { carpoolId, driverUid: driver, accept: true });
  }
  await setDrivingDays(deps, as("bob"), { carpoolId, days: ["sun", "mon", "tue", "wed", "thu"] });
  await planWeek(deps, as("alice"), { carpoolId, weekStart: WEEK });
  return carpoolId;
}

function runsOf(store: MemoryCarpoolStore, carpoolId: string): RunRecord[] {
  return [...(store.runs.get(carpoolId)?.values() ?? [])].sort((a, b) => a.id.localeCompare(b.id));
}

// --------------------------------------------------------------------------
// Pure rules
// --------------------------------------------------------------------------

describe("trust rules", () => {
  it("ratings: 1 to 5 stars, known tags only, vouch only with 4+ stars and no concern", () => {
    assert.deepEqual(parseRating({ uid: "bob", stars: 5, tags: ["on-time", "friendly", "on-time"], vouch: true }), {
      rateeUid: "bob",
      stars: 5,
      tags: ["friendly", "on-time"],
      vouch: true,
    });
    for (const bad of [
      { uid: "bob", stars: 0 },
      { uid: "bob", stars: 6 },
      { uid: "bob", stars: 4.5 },
      { uid: "bob", stars: 4, tags: ["great guy"] },
      { uid: "bob", stars: 3, vouch: true },
      { uid: "bob", stars: 5, tags: ["late"], vouch: true },
      { uid: "../x", stars: 4 },
    ]) {
      assert.throws(() => parseRating(bad), TrustError, JSON.stringify(bad));
    }
  });

  it("shared trips: driver and the parents whose children were carried on a FINISHED trip", () => {
    const trips = [
      trip("t1", "alice", [["bob", "dropped"], ["cara", "absent"]]),
      trip("t2", "bob", [["alice", "received"]], { date: "2026-11-13" }),
      trip("t3", "bob", [["cara", "dropped"]], { status: "active" }),
      trip("t4", "dina", [["alice", "dropped"]], { date: "2026-10-01" }),
    ];
    const forAlice = sharedTrips(trips, "alice", "2026-10-15");
    assert.deepEqual([...forAlice.keys()].sort(), ["bob"]);
    assert.equal(forAlice.get("bob")?.tripId, "t2", "the latest trip");
    assert.equal(forAlice.get("bob")?.otherRole, "driver");
    // Cara's child was absent, and t3 is not finished.
    assert.deepEqual([...sharedTrips(trips, "cara", "2026-10-15").keys()], []);
    // Two parents on one run are not a pair; only the driver is.
    assert.deepEqual([...sharedTrips([trip("t5", "dina", [["alice", "dropped"], ["bob", "dropped"]])], "bob", "2026-11-01").keys()], ["dina"]);
  });

  it("summary: the average shows from 3 ratings, vouches count once per parent", () => {
    assert.deepEqual(summaryView(null), { ratings: 0, average: null, vouches: 0 });
    assert.deepEqual(summaryView({ count: 2, sum: 9, voucherUids: ["a"] }), { ratings: 2, average: null, vouches: 1 });
    assert.deepEqual(summaryView({ count: 3, sum: 13, voucherUids: ["a", "b"] }), { ratings: 3, average: 4.3, vouches: 2 });
  });

  it("guardian links: a guardian, or a child already linked to another adult, needs an admin", () => {
    assert.equal(linkNeedsReview("mother", 0), false);
    assert.equal(linkNeedsReview("father", 0), false);
    assert.equal(linkNeedsReview("guardian", 0), true);
    assert.equal(linkNeedsReview("mother", 1), true);
  });

  it("papers: reminders 30, 7 and 1 days before; expired the day after the last valid day", () => {
    const days = parseReminderDays("30, 7,1,x,400");
    assert.deepEqual(days, [30, 7, 1]);
    assert.deepEqual(parseReminderDays(""), [30, 7, 1]);
    assert.deepEqual(licenceNotice("2026-12-14", "2026-11-14", days), { kind: "expiring", days: 30 });
    assert.deepEqual(licenceNotice("2026-11-15", "2026-11-14", days), { kind: "expiring", days: 1 });
    assert.equal(licenceNotice("2026-11-14", "2026-11-14", days), null, "valid on its last day");
    assert.equal(licenceNotice("2026-11-20", "2026-11-14", days), null);
    assert.deepEqual(licenceNotice("2026-11-13", "2026-11-14", days), { kind: "expired" });
  });

  it("a run is invalid for a car that expires before it, has too few seats, or is gone", () => {
    const run = { date: "2026-11-20", riders: [{ id: "a", firstName: "A", parentUid: "p" }, { id: "b", firstName: "B", parentUid: "p" }] };
    assert.equal(runInvalid(run, { seats: 4, validUntil: "2026-11-20" }), false);
    assert.equal(runInvalid(run, { seats: 4, validUntil: "2026-11-19" }), true);
    assert.equal(runInvalid(run, { seats: 1, validUntil: "2027-01-01" }), true);
    assert.equal(runInvalid(run, null), true);
  });

  it("school year: the check opens 21 days before 1 Sep and closes 14 days after; from the first checked year", () => {
    const s = yearSettings("09-01", 21, 14, 2026);
    assert.deepEqual(yearWindow("2026-08-11", s), { year: 2026, opensOn: "2026-08-11", startsOn: "2026-09-01", deadline: "2026-09-15" });
    assert.equal(yearWindow("2026-08-10", s), null, "2025-26 is before the first checked year");
    assert.equal(yearWindow("2027-03-01", s)?.year, 2026);
    assert.equal(yearWindow("2026-11-14", yearSettings("09-01", 21, 14, 2027)), null);
    assert.deepEqual(yearSettings("13-40", -1, 999, 2027), { start: "09-01", openDays: 21, graceDays: 14, firstYear: 2027 });
    const w = yearWindow("2026-09-01", s);
    const a = { confirmedYear: null, verifiedOn: "2026-01-01", hasChildren: true };
    assert.equal(yearState(w, "2026-09-01", a), "due");
    assert.equal(yearState(w, "2026-09-16", a), "overdue");
    assert.equal(yearState(w, "2026-09-16", { ...a, confirmedYear: 2026 }), "done");
    assert.equal(yearState(w, "2026-09-16", { ...a, verifiedOn: "2026-08-20" }), "done", "verified after the check opened");
    assert.equal(yearState(w, "2026-09-16", { ...a, hasChildren: false }), "none");
    assert.equal(yearReminderStage(w as NonNullable<typeof w>, "2026-08-11"), "open");
    assert.equal(yearReminderStage(w as NonNullable<typeof w>, "2026-09-01"), "start");
    assert.equal(yearReminderStage(w as NonNullable<typeof w>, "2026-09-14"), "last");
    assert.equal(yearReminderStage(w as NonNullable<typeof w>, "2026-09-02"), null);
  });

  it("yearly answers: every child once, a grade when the child stays", () => {
    assert.deepEqual(parseYearAnswers({ year: 2026, children: [{ childId: "b1", stays: true, grade: "g3" }, { childId: "b2", stays: false }] }, ["b2", "b1"]).answers, [
      { childId: "b1", stays: true, grade: "g3" },
      { childId: "b2", stays: false, grade: null },
    ]);
    assert.throws(() => parseYearAnswers({ year: 2026, children: [{ childId: "b1", stays: true, grade: "g3" }] }, ["b1", "b2"]), (e: unknown) => e instanceof TrustError && e.reason === "children-changed");
    assert.throws(() => parseYearAnswers({ year: 2026, children: [{ childId: "b1", stays: true, grade: "g13" }] }, ["b1"]), TrustError);
    assert.throws(() => parseYearAnswers({ year: 2026, children: [{ childId: "b1", stays: true, grade: "g3" }, { childId: "b1", stays: false }] }, ["b1"]), TrustError);
  });

  it("a renewal of the same car keeps its approval while it waits; a new car does not", () => {
    const approved = { status: "approved", plate: "ABC 123", seats: 4, licenseExpiry: "2026-12-01", carLicenseExpiry: "2027-01-01", model: "Corolla", color: "White" };
    assert.equal(samePlate("abc-123", "ABC 123"), true);
    assert.equal(samePlate("", ""), false);
    const kept = keptApproval(approved, "ABC123");
    assert.equal(kept?.seats, 4);
    assert.equal(keptApproval(approved, "XYZ 999"), null, "another plate: a new car");
    assert.equal(keptApproval({ ...approved, status: "rejected" }, "ABC 123"), null);
    const pending = { status: "pending", plate: "ABC 123", seats: 5, licenseExpiry: "2031-01-01", carLicenseExpiry: "2031-01-01", approved: kept };
    assert.deepEqual(usableVehicle(pending), { ...approved, plate: "ABC 123" });
    assert.equal(usableVehicle({ ...pending, approved: null })?.status, "pending");
    assert.equal(usableVehicle(null), null);
  });

  it("notifications: the trust types have no {when} unless they carry the expiry date, and open the right screen", () => {
    assert.equal(TYPES["licence-expiring"].hasWhen, true);
    assert.equal(TYPES["year-check-due"].critical, false);
    assert.equal(routeFor({ type: "licence-expiring", carpoolId: null }), "/profile/driving");
    assert.equal(routeFor({ type: "year-check-due", carpoolId: null }), "/profile/school-year");
    assert.equal(routeFor({ type: "guardian-requested", carpoolId: null }), "/profile/family");
    assert.equal(routeFor({ type: "phone-changed", carpoolId: null }), "/profile");
  });
});

// --------------------------------------------------------------------------
// Ratings and vouching
// --------------------------------------------------------------------------

describe("ratings and vouching (F17)", () => {
  let t: ReturnType<typeof setup>;
  beforeEach(() => {
    t = setup();
    t.store.trips = [trip("k1_2026-11-12_am", "alice", [["bob", "dropped"], ["cara", "received"]])];
  });

  it("lists the parents of a shared finished trip, then rates once per month", async () => {
    const before = await listRateable(t.deps, as("alice"));
    assert.deepEqual(before.parents.map((p) => [p.uid, p.role]), [["bob", "parent"], ["cara", "parent"]]);
    assert.equal(before.parents[0].firstName, "Bob");
    assert.deepEqual(await rateParent(t.deps, as("alice"), { uid: "bob", stars: 5, tags: ["on-time"], vouch: true }), { rated: true, flagged: false });
    await rejects(rateParent(t.deps, as("alice"), { uid: "bob", stars: 4 }), "already-rated");
    assert.deepEqual((await listRateable(t.deps, as("alice"))).parents.map((p) => p.uid), ["cara"]);
    // Bob rates his driver back.
    await rateParent(t.deps, as("bob"), { uid: "alice", stars: 4 });
    // Next month the same trip (still within 30 days) cannot be rated again
    // (Prompt 12: once per trip and pair), and is no longer listed.
    t.clock.now = Date.UTC(2026, 11, 2, 8);
    await rejects(rateParent(t.deps, as("alice"), { uid: "bob", stars: 4 }), "already-rated");
    assert.deepEqual((await listRateable(t.deps, as("alice"))).parents.map((p) => p.uid), ["cara"]);
    // A new shared trip in the new month may be rated.
    t.store.trips.push(trip("k1_2026-12-01_am", "alice", [["bob", "dropped"]], { date: "2026-12-01" }));
    await rateParent(t.deps, as("alice"), { uid: "bob", stars: 4 });
    assert.equal(t.store.summaries.get("bob")?.count, 2);
    assert.deepEqual(t.store.summaries.get("bob")?.voucherUids, ["alice"]);
  });

  it("refuses without a shared finished trip, for oneself, and for unverified callers", async () => {
    await rejects(rateParent(t.deps, as("alice"), { uid: "dina", stars: 5 }), "no-shared-trip");
    await rejects(rateParent(t.deps, as("bob"), { uid: "cara", stars: 5 }), "no-shared-trip");
    await rejects(rateParent(t.deps, as("alice"), { uid: "alice", stars: 5 }), "self");
    await rejects(rateParent(t.deps, { uid: "alice", verifiedClaim: false }, { uid: "bob", stars: 5 }), "not-verified");
    t.store.accounts.get("alice")!.status = "suspended";
    await rejects(rateParent(t.deps, as("alice"), { uid: "bob", stars: 5 }), "suspended");
    // A trip older than the window does not count.
    t.store.accounts.get("alice")!.status = "verified";
    t.clock.now = NOW + 40 * DAY;
    await rejects(rateParent(t.deps, as("alice"), { uid: "bob", stars: 5 }), "no-shared-trip");
  });

  it("low stars or unsafe driving go to the admin queue; the admin closes the flag once", async () => {
    assert.equal((await rateParent(t.deps, as("bob"), { uid: "alice", stars: 2, tags: ["late"] })).flagged, true);
    assert.equal((await rateParent(t.deps, as("cara"), { uid: "alice", stars: 4, tags: ["unsafe-driving"] })).flagged, true);
    const queue = await adminTrustQueue(t.deps);
    assert.equal(queue.flags.length, 2);
    assert.equal(queue.flags[0].rateeFirstName, "Alice");
    assert.ok(["Bob", "Cara"].includes(queue.flags[0].raterFirstName));
    const id = queue.flags[0].id;
    const done = await adminResolveRatingFlag(t.deps, "admin1", { flagId: id, outcome: "contacted" }, null);
    assert.equal(done.status, "handled");
    await rejects(adminResolveRatingFlag(t.deps, "admin1", { flagId: id, outcome: "contacted" }, null), "invalid-state");
    await rejects(adminResolveRatingFlag(t.deps, "admin1", { flagId: id, outcome: "banned-forever" }, null), "invalid-request");
    assert.ok(t.store.audits.some((a) => a.action === "rating-flag.resolve"));
  });

  it("summaries: one's own, or a parent of a shared carpool only", async () => {
    await rateParent(t.deps, as("bob"), { uid: "alice", stars: 5, vouch: true });
    assert.deepEqual(await getTrustSummary(t.deps, as("alice"), {}), { ratings: 1, average: null, vouches: 1 });
    await rejects(getTrustSummary(t.deps, as("dina"), { uid: "alice" }), "not-allowed");
    t.store.carpoolsOf.set("alice", ["k1"]);
    t.store.carpoolsOf.set("dina", ["k1"]);
    assert.equal((await getTrustSummary(t.deps, as("dina"), { uid: "alice" })).vouches, 1);
  });
});

// --------------------------------------------------------------------------
// Guardian links
// --------------------------------------------------------------------------

describe("guardian links (spouse linked to the same children)", () => {
  let t: ReturnType<typeof setup>;
  beforeEach(() => {
    t = setup();
  });

  const bobsId = () => t.store.accounts.get("bob")!.parentId;

  it("a parent asks by parent ID, the children's parent picks the children and accepts: active at once", async () => {
    const { requestId, firstName } = await requestGuardianLink(t.deps, as("dina"), { parentId: bobsId().toLowerCase(), relation: "mother" });
    assert.equal(firstName, "Bob");
    assert.equal(t.store.events.at(-1)?.type, "guardian-requested");
    assert.deepEqual(t.store.events.at(-1)?.recipients, ["bob"]);
    await rejects(requestGuardianLink(t.deps, as("dina"), { parentId: bobsId(), relation: "mother" }), "already-requested");
    assert.equal((await getFamily(t.deps, as("bob"))).incoming.length, 1);
    await rejects(answerGuardianRequest(t.deps, as("bob"), { requestId, accept: true, childIds: ["c1"] }), "not-your-child");
    const answer = await answerGuardianRequest(t.deps, as("bob"), { requestId, accept: true, childIds: ["b1", "b2"] });
    assert.deepEqual(answer.links, [{ childId: "b1", status: "active" }, { childId: "b2", status: "active" }]);
    assert.equal(t.store.events.at(-1)?.type, "guardian-linked");
    const fam = await getFamily(t.deps, as("dina"));
    assert.deepEqual(fam.linked.map((l) => l.childId), ["b1", "b2"]);
    assert.deepEqual(fam.linked.map((l) => [l.childSchoolId, l.childGrade]), [["nile", "g2"], ["nile", "kg2"]]);
    assert.equal(fam.outgoing.length, 0);
    await rejects(answerGuardianRequest(t.deps, as("bob"), { requestId, accept: true, childIds: ["b1"] }), "invalid-state");
  });

  it("a guardian (not a parent) waits for an admin; the admin approves or rejects", async () => {
    const { requestId } = await requestGuardianLink(t.deps, as("dina"), { parentId: bobsId(), relation: "guardian" });
    const answer = await answerGuardianRequest(t.deps, as("bob"), { requestId, accept: true, childIds: ["b1"] });
    assert.deepEqual(answer.links, [{ childId: "b1", status: "review" }]);
    const queue = await adminTrustQueue(t.deps);
    assert.deepEqual(queue.links.map((l) => l.id), ["b1_dina"]);
    await adminDecideGuardianLink(t.deps, "admin1", { linkId: "b1_dina", approve: true }, null);
    assert.equal(t.store.links.get("b1_dina")?.status, "active");
    assert.equal(t.store.events.at(-1)?.type, "guardian-linked");
    await rejects(adminDecideGuardianLink(t.deps, "admin1", { linkId: "b1_dina", approve: false }, null), "invalid-state");
    assert.ok(t.store.audits.some((a) => a.action === "guardian.approve"));
  });

  it("declining, cancelling and the checks on who may ask", async () => {
    await rejects(requestGuardianLink(t.deps, as("bob"), { parentId: bobsId(), relation: "father" }), "self");
    await rejects(requestGuardianLink(t.deps, as("dina"), { parentId: "AAAA2222", relation: "father" }), "not-found");
    await rejects(requestGuardianLink(t.deps, as("dina"), { parentId: bobsId(), relation: "uncle" }), "invalid-request");
    const first = await requestGuardianLink(t.deps, as("dina"), { parentId: bobsId(), relation: "mother" });
    await cancelGuardianRequest(t.deps, as("dina"), { requestId: first.requestId });
    await rejects(answerGuardianRequest(t.deps, as("bob"), { requestId: first.requestId, accept: true, childIds: ["b1"] }), "invalid-state");
    const again = await requestGuardianLink(t.deps, as("dina"), { parentId: bobsId(), relation: "mother" });
    await rejects(answerGuardianRequest(t.deps, as("cara"), { requestId: again.requestId, accept: false }), "not-found");
    assert.equal((await answerGuardianRequest(t.deps, as("bob"), { requestId: again.requestId, accept: false })).status, "declined");
    assert.equal(t.store.events.at(-1)?.type, "guardian-declined");
    assert.equal(t.store.links.size, 0);
  });

  it("a linked parent can join a carpool with the child once; ending the link takes the child out", async () => {
    const k = await readyCarpool(t.carpools);
    const { requestId } = await requestGuardianLink(t.deps, as("dina"), { parentId: bobsId(), relation: "mother" });
    await answerGuardianRequest(t.deps, as("bob"), { requestId, accept: true, childIds: ["b1"] });
    // The carpool store sees linked children as Dina's too (FirestoreCarpoolStore.approvedChildren).
    t.carpoolStore.children.set("dina", [{ id: "b1", firstName: "Bassel", grade: "g2", schoolId: "nile" }]);
    await rejects(requestToJoin(t.carpools, as("dina"), { carpoolId: k, childIds: ["b1"], acceptRules: true }), "child-in-carpool");
    // Bob takes Bassel out (link ends for his side in another carpool): Dina may bring him.
    await removeChildFromCarpools(t.carpools, "bob", "b1");
    const bob = t.carpoolStore.members.get(k)?.get("bob");
    assert.deepEqual(bob?.children.map((c) => c.id), ["b2"]);
    assert.ok(runsOf(t.carpoolStore, k).every((r) => !r.riders.some((x) => x.id === "b1")));
    assert.equal(t.carpoolStore.carpools.get(k)?.childrenCount, 3);
    await requestToJoin(t.carpools, as("dina"), { carpoolId: k, childIds: ["b1"], acceptRules: true });
    await decideJoinRequest(t.carpools, as("alice"), { carpoolId: k, uid: "dina", approve: true });
    // Bob ends the link: Bassel leaves Dina's carpools, and Dina, with no
    // child left in it, leaves the carpool (and its chat).
    await removeGuardianLink(t.deps, as("bob"), { linkId: "b1_dina" });
    assert.equal(t.carpoolStore.members.get(k)?.get("dina"), undefined);
    assert.equal(t.carpoolStore.memberships.get(`${k}_dina`)?.status, "left");
    await rejects(removeGuardianLink(t.deps, as("bob"), { linkId: "b1_dina" }), "invalid-state");
    await rejects(removeGuardianLink(t.deps, as("cara"), { linkId: "b1_dina" }), "not-found");
  });
});

// --------------------------------------------------------------------------
// Yearly check
// --------------------------------------------------------------------------

describe("yearly check of children, grades and schools", () => {
  it("due after the check opens; a child who left leaves the carpools of both linked parents", async () => {
    const t = setup(NOW);
    const k = await readyCarpool(t.carpools);
    // 25 Aug 2027: the 2027-28 check is open.
    t.deps.year = yearSettings("09-01", 21, 14, 2027);
    t.clock.now = Date.UTC(2027, 7, 25, 8);
    t.store.links.set("b2_dina", {
      id: "b2_dina", childId: "b2", childFirstName: "Bana", ownerUid: "bob", ownerFirstName: "Bob", guardianUid: "dina", guardianFirstName: "Dina",
      relation: "mother", status: "active", createdAtMs: NOW, decidedAtMs: null, decidedBy: null, updatedAtMs: NOW,
    });
    const view = await yearCheckOf(t.deps, t.store.accounts.get("bob")!);
    assert.equal(view.state, "due");
    assert.deepEqual(view.children.map((c) => c.id).sort(), ["b1", "b2"]);
    assert.equal((await getTrustOverview(t.deps, as("bob"))).yearCheck.state, "due");
    await rejects(confirmSchoolYear(t.deps, as("bob"), { year: 2027, children: [{ childId: "b1", stays: true, grade: "g3" }] }), "children-changed");
    await rejects(confirmSchoolYear(t.deps, as("bob"), { year: 2026, children: [{ childId: "b1", stays: true, grade: "g3" }, { childId: "b2", stays: false }] }), "year-not-open");
    const res = await confirmSchoolYear(t.deps, as("bob"), { year: 2027, children: [{ childId: "b1", stays: true, grade: "g3" }, { childId: "b2", stays: false }] });
    assert.deepEqual(res, { state: "done", left: 1 });
    assert.equal(t.store.children.get("b2")?.status, "left");
    assert.equal(t.store.children.get("b1")?.grade, "g3");
    assert.equal(t.store.links.get("b2_dina")?.status, "removed");
    const bob = t.carpoolStore.members.get(k)?.get("bob");
    assert.deepEqual(bob?.children, [{ id: "b1", firstName: "Bassel", grade: "g3" }]);
    assert.equal(t.carpoolStore.carpools.get(k)?.childrenCount, 3);
    assert.equal((await yearCheckOf(t.deps, t.store.accounts.get("bob")!)).state, "done");
    // Cara's only child left the school: Cara leaves the carpool and its chat.
    await confirmSchoolYear(t.deps, as("cara"), { year: 2027, children: [{ childId: "c1", stays: false }] });
    assert.equal(t.carpoolStore.members.get(k)?.get("cara"), undefined);
    assert.equal(t.carpoolStore.memberships.get(`${k}_cara`)?.status, "left");
    await rejects(confirmSchoolYear(t.deps, as("bob"), { year: 2027, children: [] }), "year-not-open");
  });

  it("the daily job reminds on the stage days and, after the deadline, stops new driving days", async () => {
    const t = setup(Date.UTC(2027, 7, 11, 6));
    t.deps.year = yearSettings("09-01", 21, 14, 2027);
    const job = (): JobDeps => ({ store: t.store, carpools: t.carpools, now: t.deps.now, reminderDays: [30, 7, 1], year: t.deps.year, log: () => undefined });
    t.store.accounts.get("cara")!.verifiedOn = "2027-08-11"; // verified with the check open: done
    await runTrustDaily(job());
    const reminders = () => t.store.events.filter((e) => e.type === "year-check-due").map((e) => e.recipients[0]).sort();
    assert.deepEqual(reminders(), ["alice", "bob"], "Dina has no children; Cara just verified");
    await runTrustDaily(job());
    assert.equal(reminders().length, 2, "fixed IDs: never twice");
    t.clock.now = Date.UTC(2027, 7, 20, 6); // not a stage day
    await runTrustDaily(job());
    assert.equal(reminders().length, 2);
    t.clock.now = Date.UTC(2027, 8, 16, 6); // the day after the deadline
    const result = await runTrustDaily(job());
    assert.equal(result.overdue, 2);
    assert.equal(t.store.accounts.get("alice")?.yearCheckOverdue, true);
    assert.equal(t.store.accounts.get("cara")?.yearCheckOverdue, false);
    // Confirming clears it.
    await confirmSchoolYear(t.deps, as("alice"), { year: 2027, children: [{ childId: "a1", stays: true, grade: "g4" }] });
    assert.equal(t.store.accounts.get("alice")?.yearCheckOverdue, false);
    // Prompt 11 review item 3: Bob's children are no longer approved, so
    // there is nothing to confirm; the job clears his mark.
    assert.equal(t.store.accounts.get("bob")?.yearCheckOverdue, true);
    for (const id of ["b1", "b2"]) t.store.children.get(id)!.status = "rejected";
    const later = await runTrustDaily(job());
    assert.equal(later.overdueCleared, 1);
    assert.equal(t.store.accounts.get("bob")?.yearCheckOverdue, false);
  });

  it("a new grade also reaches the carpools a linked parent brought the child into", async () => {
    const t = setup(NOW);
    const k = await readyCarpool(t.carpools);
    t.deps.year = yearSettings("09-01", 21, 14, 2027);
    t.clock.now = Date.UTC(2027, 7, 25, 8);
    t.store.links.set("b1_dina", {
      id: "b1_dina", childId: "b1", childFirstName: "Bassel", ownerUid: "bob", ownerFirstName: "Bob", guardianUid: "dina", guardianFirstName: "Dina",
      relation: "mother", status: "active", createdAtMs: NOW, decidedAtMs: null, decidedBy: null, updatedAtMs: NOW,
    });
    // Dina brought Bassel into a carpool of her own (a copy of Bob's membership).
    const bobs = t.carpoolStore.memberships.get(`${k}_bob`);
    assert.ok(bobs);
    t.carpoolStore.memberships.set(`k2_dina`, { ...bobs, carpoolId: "k2", uid: "dina", children: [{ id: "b1", firstName: "Bassel", grade: "g2" }] });
    await confirmSchoolYear(t.deps, as("bob"), { year: 2027, children: [{ childId: "b1", stays: true, grade: "g3" }, { childId: "b2", stays: true, grade: "g1" }] });
    assert.equal(t.carpoolStore.memberships.get(`${k}_bob`)?.children.find((c) => c.id === "b1")?.grade, "g3");
    assert.equal(t.carpoolStore.memberships.get("k2_dina")?.children[0].grade, "g3", "the linked parent's carpools are updated too");
  });

  it("nothing is due before the first checked year", async () => {
    const t = setup(NOW);
    t.deps.year = yearSettings("09-01", 21, 14, 2027);
    assert.equal((await yearCheckOf(t.deps, t.store.accounts.get("bob")!)).state, "none");
    await rejects(confirmSchoolYear(t.deps, as("bob"), { year: 2026, children: [] }), "year-not-open");
  });
});

// --------------------------------------------------------------------------
// Who may drive: papers, cars, suspension
// --------------------------------------------------------------------------

describe("who may drive: papers, car changes and suspended drivers", () => {
  const usable = (licenseExpiry: string, extra: Record<string, unknown> = {}) => ({
    status: "approved", seats: 4, licenseExpiry, carLicenseExpiry: "2030-01-01", plate: "ABC 123", model: "Corolla", color: "White", ...extra,
  });

  it("reminds 30, 7 and 1 days before the papers expire, once each", async () => {
    const t = setup(NOW);
    t.store.vehicleRows = [{ uid: "bob", vehicle: usable("2026-12-14") }, { uid: "alice", vehicle: usable("2026-11-21") }, { uid: "cara", vehicle: usable("2026-11-15", { status: "pending" }) }];
    const job: JobDeps = { store: t.store, carpools: t.carpools, now: t.deps.now, reminderDays: [30, 7, 1], year: t.deps.year, log: () => undefined };
    const r = await runTrustDaily(job);
    assert.equal(r.expiring, 2);
    const e = t.store.events.filter((x) => x.type === "licence-expiring");
    assert.deepEqual(e.map((x) => [x.recipients[0], x.date]).sort(), [["alice", "2026-11-21"], ["bob", "2026-12-14"]]);
    assert.equal((await runTrustDaily(job)).expiring, 0, "not twice");
  });

  it("expired papers: a notice, and runs after the last valid day lose the driver (group hears only 'driver unavailable')", async () => {
    const t = setup(NOW);
    const k = await readyCarpool(t.carpools);
    const bobs = runsOf(t.carpoolStore, k).filter((r) => r.driverUid === "bob");
    assert.ok(bobs.length > 1);
    // Bob's licence ended yesterday in the test data.
    t.carpoolStore.vehicles.set("bob", { status: "approved", seats: 6, licenseExpiry: "2026-11-13", carLicenseExpiry: "2030-01-01" });
    t.store.vehicleRows = [{ uid: "bob", vehicle: usable("2026-11-13", { seats: 6 }) }];
    const before = t.carpoolStore.events.length;
    const r = await runTrustDaily({ store: t.store, carpools: t.carpools, now: t.deps.now, reminderDays: [30, 7, 1], year: t.deps.year, log: () => undefined });
    assert.equal(r.expired, 1);
    assert.equal(r.runsFreed, bobs.length);
    for (const run of bobs) {
      const after = t.carpoolStore.runs.get(k)?.get(run.id) as RunRecord;
      assert.equal(after.driverUid, null);
      assert.ok(after.status === "open" || after.status === "missed");
    }
    const events = t.carpoolStore.events.slice(before);
    assert.ok(events.every((e) => e.type === "driver-unavailable" || e.type === "no-driver"));
    // Taking a run again is refused: the car expired (Prompt 7 checkArrangement).
    assert.equal(t.carpoolStore.members.get(k)?.get("bob")?.car?.validUntil, "2026-11-13");
  });

  it("fewer seats: runs with more children lose the driver and the creator's carpool seats come down", async () => {
    const t = setup(NOW);
    const k = await readyCarpool(t.carpools);
    const alices = runsOf(t.carpoolStore, k).filter((r) => r.driverUid === "alice");
    assert.ok(alices.some((r) => r.riders.length > 2));
    const freed = await applyCarChange(t.carpools, "alice", { seats: 2, validUntil: "2030-01-01" });
    assert.equal(freed, alices.filter((r) => r.riders.length > 2).length);
    assert.equal(t.carpoolStore.carpools.get(k)?.seats, 4, "never below the children in it");
    assert.equal(t.carpoolStore.members.get(k)?.get("alice")?.car?.seats, 2);
    // A new car waiting for review: no usable car, every run released.
    const left = runsOf(t.carpoolStore, k).filter((r) => r.driverUid === "bob").length;
    assert.equal(await applyCarChange(t.carpools, "bob", null), left);
  });

  it("suspending or banning a driver opens their runs once", async () => {
    const t = setup(NOW);
    const k = await readyCarpool(t.carpools);
    const bobs = runsOf(t.carpoolStore, k).filter((r) => r.driverUid === "bob").length;
    assert.equal(blockedAccount({ status: "suspended" }), true);
    assert.equal(blockedAccount({ status: "verified", banned: true }), true);
    assert.equal(await releaseOnBlock(t.carpools, "bob", { status: "verified" }, { status: "verified", firstName: "Bob" }), 0);
    assert.equal(await releaseOnBlock(t.carpools, "bob", { status: "verified" }, { status: "suspended" }), bobs);
    assert.equal(runsOf(t.carpoolStore, k).filter((r) => r.driverUid === "bob").length, 0);
    const opened = t.carpoolStore.events.filter((e) => e.type === "driver-unavailable" && e.actorUid === "bob");
    assert.ok(opened.length > 0);
    assert.equal(await releaseOnBlock(t.carpools, "bob", { status: "suspended" }, { status: "suspended", banned: true }), 0, "already blocked");
  });
});

// --------------------------------------------------------------------------
// Phone change: WhatsApp code + fresh selfie
// --------------------------------------------------------------------------

class RecordingSender implements WhatsAppSender {
  readonly kind = "fake";
  readonly sent: Array<{ to: string; code: string }> = [];
  async sendCode(to: string, code: string, _language: Language): Promise<void> {
    this.sent.push({ to, code });
  }
}

describe("phone change (re-verification)", () => {
  const DEVICE = "0123456789abcdef0123456789abcdef";
  let store: MemoryTrustStore;
  let files: MemoryFiles;
  let sender: RecordingSender;
  let face: KycResult;
  let deps: PhoneChangeDeps;
  let otp: OtpDeps;
  let now: number;

  beforeEach(() => {
    store = new MemoryTrustStore();
    store.addParent("bob", { phone: "+201011111111" });
    store.addParent("cara", { phone: "+201022222222" });
    files = new MemoryFiles();
    files.files.set("faceRefs/bob/selfie.jpg", { data: Buffer.from("ref"), createdMs: 0 });
    sender = new RecordingSender();
    face = "match";
    now = NOW;
    let n = 0;
    otp = {
      store: new MemoryOtpStore(),
      sender,
      accounts: { signInWithPhone: async () => ({ uid: "x", suspended: false }), createToken: async () => "t" },
      hmacKey: phoneChangeKey("sign-in-key"),
      now: () => now,
      newCode: () => String(111111 + n++),
      limits: DEFAULT_OTP_LIMITS,
    };
    deps = {
      store,
      files,
      otp,
      faces: { matchFace: async () => face },
      faceRefPath: (uid) => `faceRefs/${uid}/selfie.jpg`,
      now: () => now,
      reportError: () => undefined,
    };
  });

  const selfie = () => files.files.set(phoneSelfiePath("bob"), { data: Buffer.from("live"), createdMs: now });
  const bob = { uid: "bob", verifiedClaim: true };

  it("a code to the new number and a matching selfie change the number; the selfie is deleted", async () => {
    await requestPhoneChange(deps, bob, { phone: "01033333333", deviceId: DEVICE }, "1.2.3.4", "ar");
    assert.deepEqual(sender.sent.map((s) => s.to), ["+201033333333"]);
    selfie();
    assert.deepEqual(await confirmPhoneChange(deps, bob, { phone: "01033333333", code: sender.sent[0].code, deviceId: DEVICE }), { changed: true });
    assert.equal(store.accounts.get("bob")?.phone, "+201033333333");
    assert.equal(store.events.at(-1)?.type, "phone-changed");
    assert.equal(files.files.has(phoneSelfiePath("bob")), false);
  });

  it("a phone-change code is not a sign-in code (its own key)", async () => {
    await requestPhoneChange(deps, bob, { phone: "01033333333", deviceId: DEVICE }, "1.2.3.4", "en");
    const signIn: OtpDeps = { ...otp, hmacKey: "sign-in-key" };
    await assert.rejects(verifyCode(signIn, { phone: "01033333333", code: sender.sent[0].code, deviceId: DEVICE, language: "en" }));
  });

  it("refuses the same number, a missing or old selfie, a number another parent uses, and a mismatch (reported)", async () => {
    await rejects(requestPhoneChange(deps, bob, { phone: "01011111111", deviceId: DEVICE }, "1.2.3.4", "ar"), "phone-same");
    await requestPhoneChange(deps, bob, { phone: "01022222222", deviceId: DEVICE }, "1.2.3.4", "ar");
    await rejects(confirmPhoneChange(deps, bob, { phone: "01022222222", code: sender.sent[0].code, deviceId: DEVICE }), "no-selfie");
    files.files.set(phoneSelfiePath("bob"), { data: Buffer.from("old"), createdMs: now - 60 * 60_000 });
    await rejects(confirmPhoneChange(deps, bob, { phone: "01022222222", code: sender.sent[0].code, deviceId: DEVICE }), "no-selfie");
    assert.equal(files.files.has(phoneSelfiePath("bob")), false, "deleted on every path");
    selfie();
    await rejects(confirmPhoneChange(deps, bob, { phone: "01022222222", code: sender.sent[0].code, deviceId: DEVICE }), "phone-taken");
    now += 61_000;
    await requestPhoneChange(deps, bob, { phone: "01044444444", deviceId: DEVICE }, "1.2.3.4", "ar");
    selfie();
    face = "no_match";
    await rejects(confirmPhoneChange(deps, bob, { phone: "01044444444", code: sender.sent[1].code, deviceId: DEVICE }), "selfie-mismatch");
    assert.deepEqual(store.reports, ["bob"]);
    assert.equal(store.accounts.get("bob")?.phone, "+201011111111");
    assert.equal(files.files.has(phoneSelfiePath("bob")), false);
  });

  it("only verified parents with a face reference", async () => {
    await rejects(requestPhoneChange(deps, { uid: "bob", verifiedClaim: false }, { phone: "01033333333", deviceId: DEVICE }, "1.2.3.4", "ar"), "not-verified");
    files.files.delete("faceRefs/bob/selfie.jpg");
    selfie();
    await rejects(confirmPhoneChange(deps, bob, { phone: "01033333333", code: "123456", deviceId: DEVICE }), "no-reference");
  });

  it("a face check that cannot run changes nothing (try again later)", async () => {
    await requestPhoneChange(deps, bob, { phone: "01033333333", deviceId: DEVICE }, "1.2.3.4", "ar");
    selfie();
    face = "error";
    await rejects(confirmPhoneChange(deps, bob, { phone: "01033333333", code: sender.sent[0].code, deviceId: DEVICE }), "check-unavailable");
    assert.equal(store.accounts.get("bob")?.phone, "+201011111111");
    assert.deepEqual(store.reports, []);
  });
});

// --------------------------------------------------------------------------
// Prompt 12: account deletion takes the parent out of every carpool
// --------------------------------------------------------------------------

describe("removeFromCarpool (account deletion)", () => {
  it("the admin's carpool passes to the longest-standing member; the last one out closes it", async () => {
    const t = setup(NOW);
    const k = await readyCarpool(t.carpools);
    assert.equal(await removeFromCarpool(t.carpools, "alice", k), "left");
    assert.equal(t.carpoolStore.members.get(k)?.get("alice"), undefined);
    assert.equal(t.carpoolStore.memberships.get(`${k}_alice`)?.status, "left");
    assert.equal(t.carpoolStore.members.get(k)?.get("bob")?.role, "admin", "Bob joined first");
    assert.equal(t.carpoolStore.memberships.get(`${k}_bob`)?.role, "admin");
    assert.equal(t.carpoolStore.carpools.get(k)?.status, "active");
    // Alice's runs lose their driver; no consent mentions her any more.
    assert.ok(runsOf(t.carpoolStore, k).every((r) => r.driverUid !== "alice"));
    assert.equal(await removeFromCarpool(t.carpools, "alice", k), "none", "idempotent");
    await removeFromCarpool(t.carpools, "bob", k);
    assert.equal(await removeFromCarpool(t.carpools, "cara", k), "closed");
    assert.equal(t.carpoolStore.carpools.get(k)?.status, "closed");
    assert.equal(t.carpoolStore.carpools.get(k)?.memberCount, 0);
  });
});

// --------------------------------------------------------------------------
// Pilot feature switches (owner decision 14 Nov 2026): ratings and vouching
// and the yearly check can be off; driver eligibility never is.
// --------------------------------------------------------------------------

describe("trust with the pilot feature switches", () => {
  const off = (key: FeatureKey) => (e: unknown) => e instanceof FeatureOffError && e.feature === key;
  const switches = (over: Partial<Record<FeatureKey, boolean>>) => async () => ({ ...ALL_ON, ...over });

  it("ratings and vouching off: rating, the list and summaries refuse; the overview shows none", async () => {
    const t = setup(NOW);
    t.store.trips = [trip("t1", "alice", [["bob", "dropped"]])];
    t.deps.features = switches({ ratingsAndVouching: false });
    await assert.rejects(listRateable(t.deps, as("bob")), off("ratingsAndVouching"));
    await assert.rejects(rateParent(t.deps, as("bob"), { uid: "alice", stars: 5 }), off("ratingsAndVouching"));
    await assert.rejects(getTrustSummary(t.deps, as("bob"), {}), off("ratingsAndVouching"));
    await assert.rejects(adminResolveRatingFlag(t.deps, "admin1", { flagId: "f1", outcome: "no-issue" }, null), off("ratingsAndVouching"));
    const o = await getTrustOverview(t.deps, as("bob"));
    assert.equal(o.toRate, 0);
    assert.deepEqual(o.summary, { ratings: 0, average: null, vouches: 0 });
    assert.deepEqual((await adminTrustQueue(t.deps)).flags, [], "no rating flags in the admin queue");
    assert.equal(t.store.ratings.size, 0, "nothing was written");
  });

  it("ratings back on (no release): the same calls work again", async () => {
    const t = setup(NOW);
    t.store.trips = [trip("t1", "alice", [["bob", "dropped"]])];
    t.deps.features = switches({ ratingsAndVouching: true });
    assert.equal((await listRateable(t.deps, as("bob"))).parents.length, 1);
    assert.equal((await rateParent(t.deps, as("bob"), { uid: "alice", stars: 5 })).rated, true);
  });

  it("yearly checks off: nothing is due, confirming refuses, nobody is reminded or marked overdue", async () => {
    const t = setup(Date.UTC(2027, 8, 16, 6)); // the day after the deadline
    t.deps.year = yearSettings("09-01", 21, 14, 2027);
    t.deps.features = switches({ yearlyChecks: false });
    const alice = t.store.accounts.get("alice");
    assert.ok(alice);
    assert.equal((await yearCheckOf(t.deps, alice)).state, "none");
    assert.equal((await getTrustOverview(t.deps, as("alice"))).yearCheck.state, "none");
    await assert.rejects(confirmSchoolYear(t.deps, as("alice"), { year: 2027, children: [{ childId: "a1", stays: true, grade: "g4" }] }), off("yearlyChecks"));
    const result = await runTrustDaily({ store: t.store, carpools: t.carpools, now: t.deps.now, reminderDays: [30, 7, 1], year: t.deps.year, features: t.deps.features, log: () => undefined });
    assert.equal(result.yearReminders, 0);
    assert.equal(result.overdue, 0);
    assert.equal(t.store.events.filter((e) => e.type === "year-check-due").length, 0);
    assert.equal(t.store.accounts.get("alice")?.yearCheckOverdue, false, "nobody is blocked");
    // The same day with the switch on: the mark is set.
    const on = await runTrustDaily({ store: t.store, carpools: t.carpools, now: t.deps.now, reminderDays: [30, 7, 1], year: t.deps.year, features: switches({}), log: () => undefined });
    assert.ok(on.overdue >= 1);
  });

  it("driving papers are driver eligibility: reminders and expiry run with every switch off", async () => {
    const t = setup(NOW);
    const usable = (licenseExpiry: string): UsableVehicle => ({ status: "approved", seats: 4, licenseExpiry, carLicenseExpiry: "2030-01-01", plate: "ABC 123", model: "Corolla", color: "White" });
    t.store.vehicleRows = [{ uid: "bob", vehicle: usable("2026-11-21") }, { uid: "alice", vehicle: usable("2026-11-13") }];
    const result = await runTrustDaily({
      store: t.store,
      carpools: t.carpools,
      now: t.deps.now,
      reminderDays: [30, 7, 1],
      year: t.deps.year,
      features: switches({ wallet: false, ratingsAndVouching: false, yearlyChecks: false, settleUp: false }),
      log: () => undefined,
    });
    assert.equal(result.expiring, 1);
    assert.equal(result.expired, 1);
  });

  it("guardian links have no switch", async () => {
    const t = setup(NOW);
    t.deps.features = switches({ ratingsAndVouching: false, yearlyChecks: false });
    const family = await getFamily(t.deps, as("alice"));
    assert.deepEqual(family.incoming, []);
  });
});
