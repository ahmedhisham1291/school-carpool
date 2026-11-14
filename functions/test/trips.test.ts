import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { TEXTS } from "../src/notifications/texts";
import { routeFor, TYPES } from "../src/notifications/catalog";
import { cairoToUtcMs } from "../src/schedule/cairo";
import type { RunRecord } from "../src/schedule/model";
import {
  confirmHandover,
  driverPhotoPath,
  emergency,
  EMERGENCY_TEMPLATE,
  getHandoverAdults,
  hashToken,
  prepareTrip,
  quickMessage,
  runTripTick,
  saveHandoverAdults,
  selfiePath,
  setEmergencyContact,
  startTrip,
  submitSelfieCheck,
  todayDriverCards,
  tripAction,
  uploadPoints,
  type TripDeps,
} from "../src/trips/flow";
import {
  acceptPoints,
  applyAction,
  etaDue,
  etasFrom,
  isStale,
  overdueHandovers,
  parseUpload,
  routeAhead,
  selfieRequired,
  startProblem,
  stopsFor,
  TripError,
  tripSettings,
  viewersOf,
  type Stop,
} from "../src/trips/model";
import { FakeRoutesProvider, GoogleRoutesProvider } from "../src/trips/routes";
import { releaseDriverRuns } from "../src/trips/release";
import { MemoryCarpoolStore } from "./helpers/memory_carpools";
import { MemoryTripFiles, MemoryTripStore } from "./helpers/memory_trips";

const DATE = "2026-11-16";
const AM = cairoToUtcMs(DATE, "07:30");
const PM = cairoToUtcMs(DATE, "14:30");
const MIN = 60_000;

const driver = { uid: "d1", verifiedClaim: true };
const p1 = { uid: "p1", verifiedClaim: true };
const p2 = { uid: "p2", verifiedClaim: true };
const p3 = { uid: "p3", verifiedClaim: true };

function run(direction: "toSchool" | "toHome", status: RunRecord["status"] = "confirmed"): RunRecord {
  const am = direction === "toSchool";
  return {
    id: `${DATE}_${am ? "am" : "pm"}`,
    carpoolId: "k1",
    date: DATE,
    direction,
    time: am ? "07:30" : "14:30",
    startMs: am ? AM : PM,
    confirmByMs: AM - 10 * 3_600_000,
    status,
    driverUid: "d1",
    driverFirstName: "Dina",
    fallback: false,
    swapped: false,
    swapId: null,
    swapBy: null,
    riders: [
      { id: "c1", firstName: "Adam", parentUid: "p1" },
      { id: "c2", firstName: "Laila", parentUid: "p2" },
    ],
    absent: [{ id: "c3", firstName: "Omar", parentUid: "p3" }],
    weekStart: "2026-11-14",
    termId: "2026-t1",
    confirmedAtMs: AM - 12 * 3_600_000,
    createdAtMs: 0,
    updatedAtMs: 0,
  };
}

interface Harness {
  deps: TripDeps;
  store: MemoryTripStore;
  files: MemoryTripFiles;
  clock: { now: number };
  sent: Array<{ to: string; template: string; params: string[] }>;
  released: string[];
  routeCalls: number;
  face: { result: "match" | "no_match" | "error" };
  roll: { value: number };
}

function harness(start = AM - 10 * MIN): Harness {
  const store = new MemoryTripStore();
  const files = new MemoryTripFiles();
  for (const uid of ["d1", "p1", "p2", "p3", "x1"]) {
    store.accounts.set(uid, { status: "verified", firstName: uid === "d1" ? "Dina" : "P", drivingPaused: false, language: "en" });
  }
  store.runs.set(`k1/${DATE}_am`, run("toSchool"));
  store.runs.set(`k1/${DATE}_pm`, run("toHome"));
  store.places.set("k1", { kind: "school", schoolId: "s1", activityPoint: null });
  store.members.set("k1", ["d1", "p1", "p2", "p3"]);
  store.cars.set("d1", { model: "Corolla", color: "White", plate: "ABC 123" });
  store.homes.set("p1", { lat: 30.05, lng: 31.25 });
  store.homes.set("p2", { lat: 30.06, lng: 31.26 });
  store.children.set("c1", { ownerUid: "p1", status: "approved" });
  const h: Harness = {
    store,
    files,
    clock: { now: start },
    sent: [],
    released: [],
    routeCalls: 0,
    face: { result: "match" },
    roll: { value: 99 },
    deps: undefined as unknown as TripDeps,
  };
  const routes = new FakeRoutesProvider();
  h.deps = {
    store,
    files,
    faces: { matchFace: async (ref, live) => (await ref(), await live(), h.face.result) },
    routes: {
      kind: "fake",
      legs: async (o, w) => {
        h.routeCalls++;
        return routes.legs(o, w);
      },
    },
    whatsapp: {
      sendTemplate: async (to, template, _lang, params) => {
        h.sent.push({ to, template, params });
      },
    },
    releaseRuns: async (uid) => {
      h.released.push(uid);
      return 3;
    },
    now: () => h.clock.now,
    newToken: (() => {
      let n = 0;
      return () => `token-${++n}-abcdefghijklmnopqrstuvwxyz`;
    })(),
    roll: () => h.roll.value,
    log: () => undefined,
  };
  return h;
}

const runId = (am = true) => `${DATE}_${am ? "am" : "pm"}`;
const ids = (am = true) => ({ carpoolId: "k1", runId: runId(am) });
const tripKey = (am = true) => `k1_${runId(am)}`;

async function reason(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (e) {
    if (e instanceof TripError) return e.reason;
    throw e;
  }
  return "ok";
}

function pt(atMs: number, lat = 30.04, lng = 31.24, extra: Record<string, unknown> = {}) {
  return { coords: { latitude: lat, longitude: lng, accuracy: 10, speed: 8, heading: 90, ...extra }, timestamp: new Date(atMs).toISOString() };
}

describe("trips: who may start a run (F15)", () => {
  it("only the confirmed driver, from an hour before to three hours after", () => {
    const r = run("toSchool");
    assert.equal(startProblem(r, "d1", AM - 30 * MIN), null);
    assert.equal(startProblem(r, "p1", AM), "not-driver");
    assert.equal(startProblem({ ...r, status: "planned" }, "d1", AM), "not-confirmed");
    assert.equal(startProblem({ ...r, status: "completed" }, "d1", AM + 10 * MIN), null);
    assert.equal(startProblem(r, "d1", AM - 61 * MIN), "too-early");
    assert.equal(startProblem(r, "d1", AM + 181 * MIN), "too-late");
  });

  it("starts with stops, viewers = driver + parents of riding children; absent children's parents see nothing", async () => {
    const h = harness();
    const r = await startTrip(h.deps, driver, ids());
    const trip = h.store.trips.get(tripKey());
    assert.ok(trip);
    assert.deepEqual(trip.viewerUids, ["d1", "p1", "p2"]);
    assert.deepEqual(trip.stops.map((s) => [s.childId, s.state]), [["c1", "waiting"], ["c2", "waiting"], ["c3", "absent"]]);
    assert.equal(trip.tokenHash, hashToken(r.token));
    assert.ok(!JSON.stringify(trip).includes(r.token), "the token itself is never stored");
    assert.deepEqual(trip.car, { model: "Corolla", color: "White", plate: "ABC 123" });
    const started = h.store.events.filter((e) => e.type === "trip-started");
    assert.equal(started.length, 1);
    assert.deepEqual(started[0].recipients, ["p1", "p2"]);
    assert.equal(r.staleSeconds, 120);
  });

  it("refuses others, unverified callers, paused drivers and a planned run", async () => {
    const h = harness();
    assert.equal(await reason(startTrip(h.deps, p1, ids())), "not-driver");
    assert.equal(await reason(startTrip(h.deps, { uid: "d1", verifiedClaim: false }, ids())), "not-verified");
    h.store.paused.set("d1", "selfie-mismatch");
    assert.equal(await reason(startTrip(h.deps, driver, ids())), "driving-paused");
    const h2 = harness();
    h2.store.runs.set(`k1/${runId()}`, run("toSchool", "planned"));
    assert.equal(await reason(startTrip(h2.deps, driver, ids())), "not-confirmed");
    assert.equal(await reason(startTrip(h2.deps, driver, { carpoolId: "k1", runId: "x" })), "invalid-request");
  });

  it("starting again gives a new token and the old one stops working", async () => {
    const h = harness();
    const a = await startTrip(h.deps, driver, ids());
    const b = await startTrip(h.deps, driver, ids());
    assert.notEqual(a.token, b.token);
    assert.equal((await uploadPoints(h.deps, tripKey(), a.token, { location: pt(h.clock.now) })).status, 401);
    assert.equal((await uploadPoints(h.deps, tripKey(), b.token, { location: pt(h.clock.now) })).status, 200);
    assert.equal(h.store.events.filter((e) => e.type === "trip-started").length, 1);
  });
});

describe("trips: random selfie check (F38)", () => {
  it("is decided once per run, only with an approved photo", async () => {
    assert.equal(selfieRequired(20, 19.9, true), true);
    assert.equal(selfieRequired(20, 20, true), false);
    assert.equal(selfieRequired(100, 0, false), false);
    const h = harness();
    h.files.files.set(driverPhotoPath("d1"), Buffer.from("ref"));
    h.roll.value = 5;
    const first = await prepareTrip(h.deps, driver, ids());
    assert.equal(first.selfieRequired, true);
    h.roll.value = 99;
    assert.equal((await prepareTrip(h.deps, driver, ids())).selfieRequired, true, "no re-roll");
    assert.equal(await reason(startTrip(h.deps, driver, ids())), "selfie-required");
  });

  it("a match lets the run start; the live selfie is deleted at once", async () => {
    const h = harness();
    h.files.files.set(driverPhotoPath("d1"), Buffer.from("ref"));
    h.roll.value = 0;
    await prepareTrip(h.deps, driver, ids());
    h.files.files.set(selfiePath("d1", tripKey()), Buffer.from("live"));
    assert.equal((await submitSelfieCheck(h.deps, driver, ids())).status, "passed");
    assert.equal(h.files.files.has(selfiePath("d1", tripKey())), false);
    await startTrip(h.deps, driver, ids());
    assert.ok(h.store.trips.has(tripKey()));
  });

  it("a mismatch pauses driving, releases the driver's runs and files an urgent report", async () => {
    const h = harness();
    h.files.files.set(driverPhotoPath("d1"), Buffer.from("ref"));
    h.roll.value = 0;
    await prepareTrip(h.deps, driver, ids());
    h.files.files.set(selfiePath("d1", tripKey()), Buffer.from("live"));
    h.face.result = "no_match";
    assert.equal((await submitSelfieCheck(h.deps, driver, ids())).status, "failed");
    assert.equal(h.store.paused.get("d1"), "selfie-mismatch");
    assert.deepEqual(h.released, ["d1"]);
    assert.equal(h.store.reports.length, 1);
    assert.equal(h.store.reports[0].urgent, true);
    assert.equal(h.store.reports[0].reason, "selfie-mismatch");
    assert.equal(h.files.files.has(selfiePath("d1", tripKey())), false);
    assert.equal(await reason(startTrip(h.deps, driver, ids())), "driving-paused");
    assert.equal(await reason(prepareTrip(h.deps, driver, ids())), "driving-paused");
  });

  it("a provider error lets the run go and tells an admin (not urgent)", async () => {
    const h = harness();
    h.files.files.set(driverPhotoPath("d1"), Buffer.from("ref"));
    h.roll.value = 0;
    await prepareTrip(h.deps, driver, ids());
    h.files.files.set(selfiePath("d1", tripKey()), Buffer.from("live"));
    h.face.result = "error";
    assert.equal((await submitSelfieCheck(h.deps, driver, ids())).status, "error");
    assert.equal(h.store.reports[0].urgent, false);
    assert.equal(h.store.paused.size, 0);
    await startTrip(h.deps, driver, ids());
  });
});

describe("trips: live points (F15)", () => {
  it("reads the plugin's upload format and drops bad points", () => {
    const t = Date.UTC(2026, 10, 16, 5, 0, 0);
    const pts = parseUpload({ location: [pt(t), { coords: { latitude: 200, longitude: 1 }, timestamp: new Date(t).toISOString() }, "x", { lat: 30, lng: 31, atMs: t + 9000 }] });
    assert.equal(pts.length, 2);
    assert.equal(pts[0].speed, 29, "m/s to km/h");
    assert.equal(parseUpload({ location: pt(t) }).length, 1);
    assert.equal(parseUpload(null).length, 0);
  });

  it("keeps points at least 4 s apart, inside the trip's time, and accurate", () => {
    const base = 1_000_000;
    const raw = [0, 2000, 5000, 9000, 9500].map((d) => ({ lat: 30, lng: 31, accuracy: 10, speed: null, heading: null, atMs: base + d }));
    raw.push({ lat: 30, lng: 31, accuracy: 900, speed: null, heading: null, atMs: base + 20_000 });
    raw.push({ lat: 30, lng: 31, accuracy: 5, speed: null, heading: null, atMs: base - 120_000 });
    assert.deepEqual(acceptPoints(raw, null, base, base + 30_000, 4000).map((p) => p.atMs - base), [0, 5000, 9000]);
    assert.deepEqual(acceptPoints(raw, base + 3000, base, base + 30_000, 4000).map((p) => p.atMs - base), [9000]);
  });

  it("only the trip's own token, only while it tracks; points and last point stored", async () => {
    const h = harness();
    const { token } = await startTrip(h.deps, driver, ids());
    assert.equal((await uploadPoints(h.deps, tripKey(), "wrong-token-xxxxxxxxxxxxxxxx", { location: pt(h.clock.now) })).status, 401);
    assert.equal((await uploadPoints(h.deps, "k1_other", token, { location: pt(h.clock.now) })).status, 401);
    assert.equal((await uploadPoints(h.deps, tripKey(), "", {})).status, 401);
    const r = await uploadPoints(h.deps, tripKey(), token, { location: [pt(h.clock.now - 6000), pt(h.clock.now)] });
    assert.deepEqual(r, { status: 200, accepted: 2 });
    assert.equal(h.store.points.get(tripKey())?.length, 2);
    assert.equal(h.store.trips.get(tripKey())?.lastPointAtMs, h.clock.now);
    // Deleted within 24 hours.
    const p = h.store.points.get(tripKey())?.[0];
    assert.ok(p && p.expiresAtMs - h.clock.now <= 24 * 3_600_000);
  });

  it("arrival times: one Routes request at most once a minute; each parent gets only their own child", async () => {
    const h = harness();
    const { token } = await startTrip(h.deps, driver, ids());
    await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    assert.equal(h.routeCalls, 1);
    for (let i = 1; i <= 5; i++) {
      h.clock.now += 8000;
      await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    }
    assert.equal(h.routeCalls, 1, "not again within the minute");
    h.clock.now += MIN;
    await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    assert.equal(h.routeCalls, 2);
    const etas = h.store.etas.get(tripKey());
    assert.deepEqual(Object.keys(etas?.get("p1")?.stops ?? {}), ["c1"]);
    assert.deepEqual(Object.keys(etas?.get("p2")?.stops ?? {}), ["c2"]);
    assert.equal(etas?.has("p3"), false);
    assert.ok((etas?.get("p2")?.stops.c2 ?? 0) > (etas?.get("p1")?.stops.c1 ?? 0), "second stop after the first");
  });

  it("route ahead: morning homes then school; afternoon homes of children on board", () => {
    const stops = stopsFor(run("toSchool").riders, [], new Map());
    const where = { homes: { p1: { lat: 1, lng: 1 }, p2: { lat: 2, lng: 2 } }, school: { lat: 3, lng: 3 } };
    const am = routeAhead({ direction: "toSchool", status: "active", stops: [{ ...stops[0], state: "onBoard" }, stops[1]] }, where);
    assert.deepEqual(am.map((w) => w.point.lat), [2, 3]);
    assert.deepEqual(am[1].children, [{ childId: "c1", parentUid: "p1" }]);
    const pm = routeAhead({ direction: "toHome", status: "active", stops: [{ ...stops[0], state: "onBoard" }, stops[1]] }, where);
    assert.deepEqual(pm.map((w) => w.point.lat), [1]);
    const etas = etasFrom(am, [60, 120], 0);
    assert.equal(etas.get("p2")?.c2, 60_000);
    assert.equal(etas.get("p1")?.c1, 180_000);
    assert.equal(etaDue(null, 0, MIN), true);
    assert.equal(etaDue(0, 59_999, MIN), false);
    assert.equal(etaDue(0, MIN, MIN), true);
  });

  it("Google request: legs' durations only, traffic aware, stops as intermediates", async () => {
    const body = GoogleRoutesProvider.body({ lat: 1, lng: 2 }, [{ lat: 3, lng: 4 }, { lat: 5, lng: 6 }], true);
    assert.equal(body.routingPreference, "TRAFFIC_AWARE");
    assert.equal((body.intermediates as unknown[]).length, 1);
    let mask = "";
    const g = new GoogleRoutesProvider("k", true, async (_u, init) => {
      mask = init.headers["X-Goog-FieldMask"];
      return { ok: true, status: 200, json: async () => ({ routes: [{ legs: [{ duration: "90s" }, { duration: "30.4s" }] }] }) };
    });
    assert.deepEqual(await g.legs({ lat: 1, lng: 2 }, [{ lat: 3, lng: 4 }, { lat: 5, lng: 6 }]), [90, 30]);
    assert.equal(mask, "routes.legs.duration");
  });
});

describe("trips: stops (F16, F41)", () => {
  it("Arrived goes to that child's parent only, with sound; a second tap repeats it", async () => {
    const h = harness();
    await startTrip(h.deps, driver, ids());
    await tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "arrived" });
    await tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "arrived" });
    const arrived = h.store.events.filter((e) => e.type === "driver-arrived");
    assert.equal(arrived.length, 2);
    assert.notEqual(arrived[0].id, arrived[1].id);
    assert.deepEqual(arrived[0].recipients, ["p1"]);
    assert.equal(arrived[0].actorUid, "d1");
    assert.equal(TYPES["driver-arrived"].urgent, true);
    assert.ok(TYPES["driver-arrived"].template, "WhatsApp template");
    assert.equal(h.store.trips.get(tripKey())?.stops[0].arrivedCount, 2);
  });

  it("pickup and drop-off notify the parent each time; the last drop-off stops tracking", async () => {
    const h = harness();
    const { token } = await startTrip(h.deps, driver, ids());
    await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    for (const c of ["c1", "c2"]) await tripAction(h.deps, driver, { ...ids(), childId: c, action: "pickedUp" });
    await tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "dropped" });
    assert.equal(h.store.trips.get(tripKey())?.status, "active");
    const r = await tripAction(h.deps, driver, { ...ids(), childId: "c2", action: "dropped" });
    assert.equal(r.status, "ended", "morning: no handover to wait for");
    const trip = h.store.trips.get(tripKey());
    assert.equal(trip?.last, null, "the last point goes with tracking");
    assert.deepEqual(h.store.events.filter((e) => e.type === "child-picked-up").map((e) => e.recipients[0]), ["p1", "p2"]);
    assert.deepEqual(h.store.events.filter((e) => e.type === "child-dropped").map((e) => e.recipients[0]), ["p1", "p2"]);
    // After the run the phone's uploads are refused: the app stops tracking.
    h.clock.now += 10_000;
    assert.equal((await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) })).status, 410);
    assert.equal(await reason(tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "arrived" })), "trip-not-active");
  });

  it("wrong order, other parents and retries", async () => {
    const h = harness();
    await startTrip(h.deps, driver, ids());
    assert.equal(await reason(tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "dropped" })), "wrong-state");
    assert.equal(await reason(tripAction(h.deps, p1, { ...ids(), childId: "c1", action: "pickedUp" })), "not-driver");
    assert.equal(await reason(tripAction(h.deps, driver, { ...ids(), childId: "c3", action: "pickedUp" })), "wrong-state");
    assert.equal(await reason(tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "fly" })), "invalid-request");
    const a = await tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "pickedUp", requestId: "req-00000001" });
    const b = await tripAction(h.deps, driver, { ...ids(), childId: "c1", action: "pickedUp", requestId: "req-00000001" });
    assert.equal(a.applied, true);
    assert.equal(b.applied, false);
    assert.equal(h.store.events.filter((e) => e.type === "child-picked-up").length, 1);
  });

  it("state machine for both directions", () => {
    const s: Stop = stopsFor(run("toSchool").riders, [], new Map())[0];
    assert.equal(applyAction(s, "dropped", "toSchool", 1), null);
    assert.equal(applyAction(s, "arrived", "toHome", 1), null, "afternoon: arrive with the child on board");
    const onBoard = applyAction(s, "pickedUp", "toHome", 1);
    assert.equal(onBoard?.state, "onBoard");
    assert.equal(applyAction(onBoard as Stop, "arrived", "toHome", 2)?.state, "arrived");
    assert.equal(applyAction(onBoard as Stop, "dropped", "toHome", 2)?.state, "dropped");
    assert.deepEqual(viewersOf("d1", stopsFor(run("toSchool").riders, run("toSchool").absent, new Map())), ["d1", "p1", "p2"]);
  });
});

describe("trips: two-sided handover (F34)", () => {
  async function afternoonDropped(h: Harness) {
    h.clock.now = PM - 5 * MIN;
    await startTrip(h.deps, driver, ids(false));
    for (const c of ["c1", "c2"]) await tripAction(h.deps, driver, { ...ids(false), childId: c, action: "pickedUp" });
    for (const c of ["c1", "c2"]) await tripAction(h.deps, driver, { ...ids(false), childId: c, action: "dropped" });
  }

  it("waits for the receiving parent; no confirmation in 10 minutes alerts both (critical), once", async () => {
    const h = harness();
    await afternoonDropped(h);
    assert.equal(h.store.trips.get(tripKey(false))?.status, "handover");
    await confirmHandover(h.deps, p2, { ...ids(false), childId: "c2" });
    h.clock.now += 9 * MIN;
    await runTripTick(h.deps);
    assert.equal(h.store.events.filter((e) => e.type === "child-not-confirmed").length, 0);
    h.clock.now += MIN;
    await runTripTick(h.deps);
    const alerts = h.store.events.filter((e) => e.type === "child-not-confirmed");
    assert.equal(alerts.length, 1);
    assert.deepEqual(alerts[0].recipients, ["d1", "p1"]);
    assert.equal(alerts[0].critical, true);
    assert.equal(alerts[0].childId, "c1");
    h.clock.now += MIN;
    await runTripTick(h.deps);
    assert.equal(h.store.events.filter((e) => e.type === "child-not-confirmed").length, 1, "once");
    assert.equal(routeFor({ type: "child-not-confirmed", carpoolId: "k1", runId: runId(false) }), `/carpools/k1/trip/${runId(false)}`);
  });

  it("only that child's parent confirms; the driver is told; the trip ends", async () => {
    const h = harness();
    await afternoonDropped(h);
    assert.equal(await reason(confirmHandover(h.deps, p2, { ...ids(false), childId: "c1" })), "not-parent");
    await confirmHandover(h.deps, p1, { ...ids(false), childId: "c1" });
    const r = await confirmHandover(h.deps, p2, { ...ids(false), childId: "c2" });
    assert.equal(r.status, "ended");
    assert.deepEqual(h.store.events.filter((e) => e.type === "child-received").map((e) => e.recipients), [["d1"], ["d1"]]);
    h.clock.now += 30 * MIN;
    await runTripTick(h.deps);
    assert.equal(h.store.events.filter((e) => e.type === "child-not-confirmed").length, 0);
  });

  it("overdue rule", () => {
    const s = { ...stopsFor(run("toHome").riders, [], new Map())[0], state: "dropped" as const, droppedAtMs: 0 };
    assert.equal(overdueHandovers({ direction: "toHome", stops: [s] }, 10 * MIN - 1, 10 * MIN).length, 0);
    assert.equal(overdueHandovers({ direction: "toHome", stops: [s] }, 10 * MIN, 10 * MIN).length, 1);
    assert.equal(overdueHandovers({ direction: "toSchool", stops: [s] }, 60 * MIN, 10 * MIN).length, 0);
  });
});

describe("trips: location stopped (F15)", () => {
  it("staleness rule", () => {
    const t = { status: "active" as const, lastPointAtMs: null, startedAtMs: 0, staleAlertedAtMs: null };
    assert.equal(isStale(t, 120_000, 120_000), false);
    assert.equal(isStale(t, 120_001, 120_000), true);
    assert.equal(isStale({ ...t, lastPointAtMs: 100_000 }, 200_000, 120_000), false);
    assert.equal(isStale({ ...t, staleAlertedAtMs: 1 }, 999_999, 120_000), false);
    assert.equal(isStale({ ...t, status: "handover" }, 999_999, 120_000), false);
  });

  it("parents of the run and the driver are alerted once; a new point re-arms it", async () => {
    const h = harness();
    const { token } = await startTrip(h.deps, driver, ids());
    await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    h.clock.now += 2 * MIN + 1000;
    await runTripTick(h.deps);
    await runTripTick(h.deps);
    let stops = h.store.events.filter((e) => e.type === "location-stopped");
    assert.equal(stops.length, 1);
    assert.deepEqual(stops[0].recipients, ["d1", "p1", "p2"]);
    assert.equal(TYPES["location-stopped"].urgent, true);
    await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    h.clock.now += 2 * MIN + 1000;
    await runTripTick(h.deps);
    stops = h.store.events.filter((e) => e.type === "location-stopped");
    assert.equal(stops.length, 2);
  });

  it("a forgotten run stops tracking after 4 hours; live points are deleted within 24 hours", async () => {
    const h = harness();
    const { token } = await startTrip(h.deps, driver, ids());
    await uploadPoints(h.deps, tripKey(), token, { location: pt(h.clock.now) });
    h.clock.now += 4 * 60 * MIN + MIN;
    const r = await runTripTick(h.deps);
    assert.equal(r.ended, 1);
    assert.equal(h.store.trips.get(tripKey())?.status, "ended");
    assert.equal(h.store.trips.get(tripKey())?.last, null);
    h.clock.now += 20 * 60 * MIN;
    await runTripTick(h.deps);
    assert.equal(h.store.points.get(tripKey())?.length, 0);
  });

  it("settings are bounded", () => {
    assert.deepEqual(tripSettings(120, 20, 10), { staleMs: 120_000, selfiePercent: 20, handoverMs: 600_000 });
    assert.deepEqual(tripSettings(5, 500, 0), { staleMs: 120_000, selfiePercent: 20, handoverMs: 600_000 });
  });
});

describe("trips: quick buttons (F35) and emergency (F20)", () => {
  it("quick messages go to the run's parents, once per two minutes per kind", async () => {
    const h = harness();
    await startTrip(h.deps, driver, ids());
    assert.equal((await quickMessage(h.deps, driver, { ...ids(), kind: "late" })).posted, true);
    assert.equal((await quickMessage(h.deps, driver, { ...ids(), kind: "late" })).posted, false);
    assert.equal((await quickMessage(h.deps, driver, { ...ids(), kind: "gate" })).posted, true);
    h.clock.now += 2 * MIN;
    assert.equal((await quickMessage(h.deps, driver, { ...ids(), kind: "late" })).posted, true);
    const late = h.store.events.filter((e) => e.type === "driver-late");
    assert.equal(late.length, 2);
    assert.deepEqual(late[0].recipients, ["p1", "p2"]);
    assert.equal(await reason(quickMessage(h.deps, p1, { ...ids(), kind: "late" })), "not-driver");
    assert.equal(await reason(quickMessage(h.deps, driver, { ...ids(), kind: "x" })), "invalid-request");
  });

  it("emergency: every carpool member (critical) and the saved contact by WhatsApp with the location", async () => {
    const h = harness();
    await setEmergencyContact(h.deps, driver, { name: "Sara", phone: "01012345678", relation: "sibling" });
    await startTrip(h.deps, driver, ids());
    const r = await emergency(h.deps, driver, { ...ids(), point: { lat: 30.012345, lng: 31.2 } });
    assert.equal(r.contactSent, true);
    const ev = h.store.events.find((e) => e.type === "emergency");
    assert.ok(ev);
    assert.deepEqual(ev.recipients, ["p1", "p2", "p3"], "the whole group, not only the run");
    assert.equal(ev.critical, true);
    assert.equal(routeFor({ type: "emergency", carpoolId: "k1", runId: runId() }), "/carpools/k1/emergency");
    assert.deepEqual(h.sent, [{ to: "+201012345678", template: EMERGENCY_TEMPLATE, params: ["Dina", "https://maps.google.com/?q=30.01234,31.20000"] }]);
    assert.ok(h.store.emergencies[0].expiresAtMs - h.clock.now <= 24 * 3_600_000);
    // No coordinates in any push text.
    assert.ok(!/\d+\.\d{3}/.test(JSON.stringify(TEXTS.emergency)));
  });

  it("emergency without a contact still alerts the group; only the driver may press it", async () => {
    const h = harness();
    await startTrip(h.deps, driver, ids());
    const r = await emergency(h.deps, driver, ids());
    assert.equal(r.contactSent, false);
    assert.equal(r.members, 3);
    assert.equal(await reason(emergency(h.deps, p1, ids())), "not-driver");
  });

  it("emergency contact input is checked", async () => {
    const h = harness();
    assert.equal(await reason(setEmergencyContact(h.deps, driver, { name: "Sara", phone: "123", relation: "sibling" })), "invalid-request");
    assert.equal(await reason(setEmergencyContact(h.deps, driver, { name: "Sara", phone: "01012345678", relation: "boss" })), "invalid-request");
    assert.equal((await setEmergencyContact(h.deps, driver, { clear: true })).saved, false);
  });
});

describe("trips: handover list (F29) and driver card (F33)", () => {
  it("the parent saves names; the driver sees names and relations on the live trip, never phones", async () => {
    const h = harness();
    await startTrip(h.deps, driver, ids());
    await saveHandoverAdults(h.deps, p1, { childId: "c1", adults: [{ name: "Mona", relation: "grandparent", phone: "01112345678" }] });
    const stop = h.store.trips.get(tripKey())?.stops.find((s) => s.childId === "c1");
    assert.deepEqual(stop?.handover, [{ name: "Mona", relation: "grandparent" }]);
    assert.ok(!JSON.stringify(h.store.trips.get(tripKey())).includes("+2011"));
    assert.equal((await getHandoverAdults(h.deps, p1, { childId: "c1" })).adults[0].phone, "+201112345678");
    assert.equal(await reason(saveHandoverAdults(h.deps, p2, { childId: "c1", adults: [] })), "not-parent");
    assert.equal(await reason(getHandoverAdults(h.deps, p2, { childId: "c1" })), "not-parent");
    assert.equal(await reason(saveHandoverAdults(h.deps, p1, { childId: "c1", adults: [{ name: "1", relation: "other" }] })), "invalid-request");
    const many = Array.from({ length: 7 }, () => ({ name: "Mona", relation: "other" }));
    assert.equal(await reason(saveHandoverAdults(h.deps, p1, { childId: "c1", adults: many })), "invalid-request");
  });

  it("a new trip starts with the saved names", async () => {
    const h = harness();
    await saveHandoverAdults(h.deps, p1, { childId: "c1", adults: [{ name: "Mona", relation: "grandparent" }] });
    await startTrip(h.deps, driver, ids());
    assert.equal(h.store.trips.get(tripKey())?.stops[0].handover[0].name, "Mona");
  });

  it("today's driver card: members of that carpool only, with a short photo link", async () => {
    const h = harness(AM - 3 * 3_600_000);
    h.files.files.set(driverPhotoPath("d1"), Buffer.from("ref"));
    const r = await todayDriverCards(h.deps, p1, { carpoolId: "k1" });
    assert.equal(r.date, DATE);
    assert.equal(r.cards.length, 2);
    assert.equal(r.cards[0].runId, runId());
    assert.deepEqual(r.cards[0].car, { model: "Corolla", color: "White", plate: "ABC 123" });
    assert.match(r.cards[0].photoUrl ?? "", /driverPhotos\/d1\/photo\.jpg\?e=\d+/);
    assert.equal(await reason(todayDriverCards(h.deps, { uid: "x1", verifiedClaim: true }, { carpoolId: "k1" })), "not-member");
    const tomorrow = harness(AM + 24 * 3_600_000);
    assert.equal((await todayDriverCards(tomorrow.deps, p1, { carpoolId: "k1" })).cards.length, 0, "only on the day");
  });

  it("parents whose child is not on the run are not viewers (p3)", async () => {
    const h = harness();
    await startTrip(h.deps, driver, ids());
    assert.ok(!h.store.trips.get(tripKey())?.viewerUids.includes("p3"));
    // p3's child is marked absent: p3 cannot act on the run either.
    assert.equal(await reason(confirmHandover(h.deps, p3, { ...ids(), childId: "c3" })), "wrong-state");
    assert.equal(await reason(confirmHandover(h.deps, { uid: "x1", verifiedClaim: true }, { ...ids(), childId: "c1" })), "not-parent");
  });
});

describe("trips: a paused driver's runs are released (F38, Prompt 7 release)", () => {
  it("every future run the driver drives loses its driver; the group is told", async () => {
    const store = new MemoryCarpoolStore();
    const member = (uid: string) => ({ uid, role: "member" as const, firstName: uid, children: [], car: null, drivingDays: [], pickupShared: false, joinedAtMs: 0 });
    store.memberships.set("k1_d1", {
      carpoolId: "k1", uid: "d1", status: "approved", role: "member", firstName: "Dina", children: [], car: null, drivingDays: [],
      acceptedRules: true, acceptedContribution: true, requestedAtMs: 0, decidedAtMs: 0, decidedBy: null, updatedAtMs: 0,
    });
    store.members.set("k1", new Map([["d1", member("d1")], ["p1", member("p1")]]));
    const runs = new Map<string, RunRecord>();
    runs.set(runId(), run("toSchool"));
    runs.set(runId(false), run("toHome"));
    runs.set("2026-11-17_am", { ...run("toSchool"), id: "2026-11-17_am", date: "2026-11-17", startMs: AM + 24 * 3_600_000, driverUid: "p1" });
    store.runs.set("k1", runs);
    const n = await releaseDriverRuns(store, "d1", AM - 3 * 3_600_000, { confirmBy: "21:00", lateLeadMin: 60 });
    assert.equal(n, 2);
    const after = store.runs.get("k1");
    assert.equal(after?.get(runId())?.driverUid, null);
    assert.equal(after?.get(runId(false))?.driverUid, null);
    assert.equal(after?.get("2026-11-17_am")?.driverUid, "p1", "other drivers keep their runs");
    assert.ok(store.events.every((e) => !e.recipients.includes("d1")));
    assert.ok(store.events.length >= 2);
  });
});
