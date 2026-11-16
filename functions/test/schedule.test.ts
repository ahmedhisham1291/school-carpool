import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createCarpool,
  decideJoinRequest,
  DEFAULT_CARPOOL_LIMITS,
  leaveCarpool,
  requestToJoin,
  setDriverConsent,
  type Caller,
  type CarpoolDeps,
} from "../src/carpools/flow";
import { deadlineSettings } from "../src/carpools/callables";
import { CarpoolError, type ConsentRecord, type MemberRecord } from "../src/carpools/model";
import { pauseDriverRuns } from "../src/schedule/pause";
import { addDays, cairoOffsetMinutes, cairoToUtcMs, termOf, weekdayOf, weekStartOf } from "../src/schedule/cairo";
import {
  cancelSwap,
  confirmRun,
  deleteException,
  planWeek,
  requestSwap,
  runScheduleTick,
  saveException,
  setChildAbsent,
  setDrivingDays,
  takeRun,
} from "../src/schedule/flow";
import {
  addToBalance,
  confirmDeadline,
  dayPlan,
  DEFAULT_DEADLINES,
  eligibleFamilies,
  leastDrivenFirst,
  plannableWeek,
  proposeWeek,
  retimeRun,
  runId,
  type BalanceRecord,
  type ExceptionRecord,
  type RotationInput,
  type RunRecord,
} from "../src/schedule/model";
import { MemoryCarpoolStore } from "./helpers/memory_carpools";

const HOUR = 3_600_000;
const MIN = 60_000;

// --------------------------------------------------------------------------
// Pure helpers: fake members only
// --------------------------------------------------------------------------

const car = (seats: number) => ({ seats, validUntil: "2030-01-01" });

function member(uid: string, children: number, opts: { seats?: number | null; days?: string[] } = {}): MemberRecord {
  return {
    uid,
    role: "member",
    firstName: uid.toUpperCase(),
    children: Array.from({ length: children }, (_, i) => ({ id: `${uid}${i + 1}`, firstName: `Kid${i + 1}`, grade: "g1" })),
    car: opts.seats === null ? null : car(opts.seats ?? 6),
    drivingDays: (opts.days ?? ["sun", "mon", "tue", "wed", "thu"]) as MemberRecord["drivingDays"],
    pickupShared: false,
    joinedAtMs: 0,
  };
}

/** Every parent with children accepts every other member as a driver. */
function allConsents(members: MemberRecord[]): ConsentRecord[] {
  const out: ConsentRecord[] = [];
  for (const p of members) {
    for (const d of members) {
      if (p.uid !== d.uid) out.push({ carpoolId: "k", parentUid: p.uid, driverUid: d.uid, status: "accepted", acceptedAtMs: 1, withdrawnAtMs: null, updatedAtMs: 1 });
    }
  }
  return out;
}

// Saturday 14 Nov 2026, 10:00 in Cairo (UTC+2).
const NOW = Date.UTC(2026, 10, 14, 8);
const WEEK = "2026-11-14";

function rotation(members: MemberRecord[], extra: Partial<RotationInput> = {}): RotationInput {
  return {
    carpool: { id: "k", morning: "07:30", afternoon: "14:30", days: ["sun", "mon", "tue", "wed", "thu"] },
    weekStart: WEEK,
    members,
    consents: allConsents(members),
    exceptions: [],
    existing: [],
    balance: null,
    nowMs: NOW,
    today: "2026-11-14",
    deadlines: DEFAULT_DEADLINES,
    ...extra,
  };
}

function countBy(runs: RunRecord[]): Map<string, number> {
  const m = new Map<string, number>();
  for (const r of runs) if (r.driverUid) m.set(r.driverUid, (m.get(r.driverUid) ?? 0) + 1);
  return m;
}

function exception(id: string, e: Partial<ExceptionRecord>): ExceptionRecord {
  return { id, carpoolId: "k", kind: "noSchool", reason: "holiday", from: "2026-11-17", to: "2026-11-17", morning: null, afternoon: null, createdBy: "a", createdAtMs: 1, ...e };
}

describe("Cairo time (DST-aware)", () => {
  it("knows winter (UTC+2) and summer (UTC+3) offsets", () => {
    assert.equal(cairoOffsetMinutes(Date.UTC(2026, 0, 15, 5)), 120);
    assert.equal(cairoOffsetMinutes(Date.UTC(2026, 6, 1, 5)), 180);
  });

  it("converts run times across the spring and autumn changes", () => {
    // DST starts Friday 24 April 2026 at 00:00 and ends after Thursday 29 October 2026.
    assert.equal(cairoToUtcMs("2026-04-23", "07:30"), Date.UTC(2026, 3, 23, 5, 30));
    assert.equal(cairoToUtcMs("2026-04-25", "07:30"), Date.UTC(2026, 3, 25, 4, 30));
    assert.equal(cairoToUtcMs("2026-10-29", "07:30"), Date.UTC(2026, 9, 29, 4, 30));
    assert.equal(cairoToUtcMs("2026-11-01", "07:30"), Date.UTC(2026, 10, 1, 5, 30));
  });

  it("puts the confirm-by time on the evening before, in that evening's offset", () => {
    // Saturday 25 April (summer): Friday 24 April 21:00 is already UTC+3.
    assert.equal(confirmDeadline("2026-04-25", "07:30", 0, DEFAULT_DEADLINES), Date.UTC(2026, 3, 24, 18));
    // Sunday 26 April: Saturday evening.
    assert.equal(confirmDeadline("2026-04-26", "07:30", 0, DEFAULT_DEADLINES), Date.UTC(2026, 3, 25, 18));
    // Friday 30 October run (winter) has its deadline on Thursday 29 October (still summer).
    assert.equal(confirmDeadline("2026-10-30", "07:30", 0, DEFAULT_DEADLINES), Date.UTC(2026, 9, 29, 18));
    // Sunday 1 November (winter): Saturday 31 October 21:00 is UTC+2.
    assert.equal(confirmDeadline("2026-11-01", "07:30", 0, DEFAULT_DEADLINES), Date.UTC(2026, 9, 31, 19));
  });

  it("gives a late plan an hour before the run, and nothing when that has passed", () => {
    const run = cairoToUtcMs("2026-11-15", "07:30");
    const afterEvening = Date.UTC(2026, 10, 14, 20);
    assert.equal(confirmDeadline("2026-11-15", "07:30", afterEvening, DEFAULT_DEADLINES), run - HOUR);
    assert.equal(confirmDeadline("2026-11-15", "07:30", run - 30 * MIN, DEFAULT_DEADLINES), null);
  });

  it("weeks run Saturday to Friday, terms September to January and February to August", () => {
    assert.equal(weekdayOf("2026-11-14"), "sat");
    assert.equal(weekdayOf("2026-11-15"), "sun");
    assert.equal(weekStartOf("2026-11-19"), "2026-11-14");
    assert.equal(weekStartOf("2026-11-20"), "2026-11-14");
    assert.equal(weekStartOf("2026-11-21"), "2026-11-21");
    assert.equal(addDays("2026-12-31", 1), "2027-01-01");
    assert.equal(termOf("2026-11-14").id, "2026-t1");
    assert.equal(termOf("2027-01-20").id, "2026-t1");
    assert.equal(termOf("2027-02-01").id, "2026-t2");
  });

  it("settings fall back to safe defaults", () => {
    assert.deepEqual(deadlineSettings("20:30", 90), { confirmBy: "20:30", lateLeadMin: 90 });
    assert.deepEqual(deadlineSettings("9pm", 5), DEFAULT_DEADLINES);
  });
});

describe("exceptions (F30)", () => {
  const carpool = { morning: "07:30", afternoon: "14:30", days: ["sun", "mon", "tue", "wed", "thu"] as RotationInput["carpool"]["days"] };

  it("no school beats a time change; weekends are never school days", () => {
    const ex = [exception("1", { kind: "times", morning: "09:00", afternoon: "13:00", createdAtMs: 5 }), exception("2", { createdAtMs: 1 })];
    assert.equal(dayPlan(carpool, ex, "2026-11-17").noSchool, true);
    assert.equal(dayPlan(carpool, [], "2026-11-20").noSchool, true);
  });

  it("Ramadan times over a range, with a later one-off early dismissal inside it", () => {
    const ramadan = exception("r", { kind: "times", reason: "ramadan", from: "2027-02-08", to: "2027-03-09", morning: "08:30", afternoon: "13:30", createdAtMs: 1 });
    const early = exception("e", { kind: "times", reason: "early", from: "2027-02-10", to: "2027-02-10", afternoon: "12:00", createdAtMs: 2 });
    assert.deepEqual(dayPlan(carpool, [ramadan, early], "2027-02-09"), { noSchool: false, toSchool: "08:30", toHome: "13:30" });
    assert.deepEqual(dayPlan(carpool, [ramadan, early], "2027-02-10"), { noSchool: false, toSchool: "08:30", toHome: "12:00" });
    assert.deepEqual(dayPlan(carpool, [ramadan, early], "2027-03-10"), { noSchool: false, toSchool: "07:30", toHome: "14:30" });
  });

  it("a time change never adds a run the carpool does not have", () => {
    const morningOnly = { ...carpool, afternoon: null };
    assert.equal(dayPlan(morningOnly, [exception("t", { kind: "times", afternoon: "12:00" })], "2026-11-17").toHome, null);
  });
});

describe("rotation (F7, F37)", () => {
  it("proposes one driver for every morning and afternoon run, never confirmed", () => {
    const { runs, open } = proposeWeek(rotation([member("a", 1), member("b", 1)]));
    assert.equal(runs.length, 10);
    assert.equal(open.length, 0);
    assert.ok(runs.every((r) => r.status === "planned" && r.driverUid !== null && r.confirmedAtMs === null));
    assert.deepEqual(
      runs.map((r) => r.id).slice(0, 2),
      ["2026-11-15_am", "2026-11-15_pm"],
    );
  });

  it("two families with one child each drive five runs each", () => {
    const counts = countBy(proposeWeek(rotation([member("a", 1), member("b", 1)])).runs);
    assert.deepEqual([counts.get("a"), counts.get("b")], [5, 5]);
  });

  it("uneven numbers of children: a family with two children drives about twice as often", () => {
    const counts = countBy(proposeWeek(rotation([member("a", 1), member("b", 2)])).runs);
    // Fair shares of 10 runs: 3.3 and 6.7.
    assert.ok(Math.abs((counts.get("a") ?? 0) - 10 / 3) <= 1, `a drove ${counts.get("a")}`);
    assert.ok(Math.abs((counts.get("b") ?? 0) - 20 / 3) <= 1, `b drove ${counts.get("b")}`);
  });

  it("odd numbers: three families share ten runs 4, 3, 3 and never more than one apart", () => {
    const counts = countBy(proposeWeek(rotation([member("a", 1), member("b", 1), member("c", 1)])).runs);
    const values = [...counts.values()].sort();
    assert.deepEqual(values, [3, 3, 4]);
  });

  it("the family that has driven least this term is offered more", () => {
    // Equal shares (3 each) but A drove 6 and B none: B is 3 behind, A 3 ahead.
    const balance = {
      carpoolId: "k",
      termId: "2026-t1",
      families: { a: { firstName: "A", driven: 6, received: 0, share: 3 }, b: { firstName: "B", driven: 0, received: 6, share: 3 } },
      updatedAtMs: 0,
    };
    const counts = countBy(proposeWeek(rotation([member("a", 1), member("b", 1)], { balance })).runs);
    // After this week both have driven 8 of 8 shares.
    assert.equal(counts.get("b"), 8);
    assert.equal(counts.get("a"), 2);
    assert.deepEqual(leastDrivenFirst([member("a", 1), member("b", 1)], balance), ["b", "a"]);
  });

  it("members' driving days come first; days nobody chose go to everyone (fallback)", () => {
    const a = member("a", 1, { days: ["sun", "mon"] });
    const b = member("b", 1, { days: ["tue", "wed"] });
    const { runs } = proposeWeek(rotation([a, b]));
    for (const r of runs) {
      const day = weekdayOf(r.date);
      if (day === "sun" || day === "mon") assert.equal(r.driverUid, "a");
      if (day === "tue" || day === "wed") assert.equal(r.driverUid, "b");
      assert.equal(r.fallback, day === "thu");
    }
    // Thursday is shared fairly (balanced 4 and 4 before it).
    const thu = runs.filter((r) => weekdayOf(r.date) === "thu").map((r) => r.driverUid).sort();
    assert.deepEqual(thu, ["a", "b"]);
  });

  it("only drivers with every parent's consent, a valid car and enough seats are proposed", () => {
    const a = member("a", 1);
    const b = member("b", 2, { seats: 2 }); // 3 children in all: b's car is too small
    const c = member("c", 1, { seats: null }); // no car
    const consents = allConsents([a, b, c]);
    const { runs } = proposeWeek(rotation([a, b, c], { consents }));
    assert.ok(runs.every((r) => r.driverUid === "a"));
    // Without c's consent nobody may drive: every run stays open, with no driver.
    const noConsent = consents.filter((x) => !(x.parentUid === "c" && x.driverUid === "a"));
    const result = proposeWeek(rotation([a, b, c], { consents: noConsent }));
    assert.equal(result.open.length, 10);
    assert.ok(result.runs.every((r) => r.status === "open" && r.driverUid === null));
  });

  it("follows exceptions: no-school days are skipped, Ramadan times are used", () => {
    const ex = [
      exception("h", { from: "2026-11-17", to: "2026-11-17" }),
      exception("t", { kind: "times", reason: "ramadan", from: "2026-11-18", to: "2026-11-19", morning: "08:30", afternoon: "13:30" }),
    ];
    const { runs } = proposeWeek(rotation([member("a", 1), member("b", 1)], { exceptions: ex }));
    assert.equal(runs.length, 8);
    assert.ok(!runs.some((r) => r.date === "2026-11-17"));
    const wed = runs.find((r) => r.id === "2026-11-18_am");
    assert.equal(wed?.time, "08:30");
    assert.equal(wed?.startMs, Date.UTC(2026, 10, 18, 6, 30));
  });

  it("keeps confirmed runs and counts them for fairness", () => {
    const first = proposeWeek(rotation([member("a", 1), member("b", 1)])).runs;
    const confirmed = first.map((r) => ({ ...r, status: "confirmed" as const, driverUid: "a", driverFirstName: "A" })).slice(0, 4);
    const { runs } = proposeWeek(rotation([member("a", 1), member("b", 1)], { existing: confirmed }));
    assert.ok(!runs.some((r) => confirmed.some((c) => c.id === r.id)));
    const counts = countBy(runs);
    assert.equal(counts.get("b"), 5);
    assert.equal(counts.get("a"), 1);
  });

  it("skips runs whose time has passed", () => {
    const now = cairoToUtcMs("2026-11-15", "10:00");
    const { runs } = proposeWeek(rotation([member("a", 1)], { nowMs: now, today: "2026-11-15" }));
    assert.ok(!runs.some((r) => r.id === "2026-11-15_am"));
    assert.ok(runs.some((r) => r.id === "2026-11-15_pm"));
  });

  it("only families with a child on the run who can drive it share in it", () => {
    const a = member("a", 1);
    const b = member("b", 2);
    const c = member("c", 3, { seats: null }); // no car: takes no share
    const riders = [...a.children, ...b.children, ...c.children].map((x) => ({ id: x.id, firstName: x.firstName, parentUid: x.id.replace(/\d+$/, "") }));
    const families = eligibleFamilies(riders, [a, b, c].map((m) => ({ ...m, car: m.car ? car(8) : null })), allConsents([a, b, c]), "2026-11-15", null);
    assert.deepEqual(families, [
      { uid: "a", weight: 1 },
      { uid: "b", weight: 2 },
    ]);
  });

  it("plans this week and up to three weeks ahead, from a Saturday only", () => {
    assert.equal(plannableWeek("2026-11-14", "2026-11-14"), true);
    assert.equal(plannableWeek("2026-12-05", "2026-11-14"), true);
    assert.equal(plannableWeek("2026-12-12", "2026-11-14"), false);
    assert.equal(plannableWeek("2026-11-07", "2026-11-14"), false);
    assert.equal(plannableWeek("2026-11-15", "2026-11-14"), false);
  });

  it("the balance counts driven for the driver and received for other families on the run", () => {
    const run = proposeWeek(rotation([member("a", 1), member("b", 2)])).runs[0];
    const names = new Map([["a", "A"], ["b", "B"]]);
    const eligible = [
      { uid: "a", weight: 1 },
      { uid: "b", weight: 2 },
    ];
    const b = addToBalance({ carpoolId: "k", termId: "2026-t1", families: {}, updatedAtMs: 0 }, { ...run, driverUid: "a" }, names, eligible, 5);
    assert.deepEqual(b.families, {
      a: { firstName: "A", driven: 1, received: 0, share: 1 / 3 },
      b: { firstName: "B", driven: 0, received: 1, share: 2 / 3 },
    });
  });
});

/**
 * Plans [weeks] weeks in a row from [firstWeek] and completes every run,
 * as the tick would (balance with run-by-run fair shares). [membersAt]
 * gives the members of each week (index 0-based), so a family can join.
 */
function simulate(
  weeks: number,
  membersAt: (week: number) => MemberRecord[],
  firstWeek = WEEK,
  start: BalanceRecord | null = null,
): { balance: BalanceRecord; perWeek: Array<Map<string, number>> } {
  let balance: BalanceRecord = start ?? { carpoolId: "k", termId: "2026-t1", families: {}, updatedAtMs: 0 };
  const perWeek: Array<Map<string, number>> = [];
  for (let w = 0; w < weeks; w++) {
    const weekStart = addDays(firstWeek, w * 7);
    const members = membersAt(w);
    const consents = allConsents(members);
    const { runs } = proposeWeek(
      rotation(members, { weekStart, consents, balance, nowMs: cairoToUtcMs(weekStart, "10:00"), today: weekStart }),
    );
    perWeek.push(countBy(runs));
    const names = new Map(members.map((m) => [m.uid, m.firstName]));
    for (const run of runs) {
      balance = addToBalance(balance, run, names, eligibleFamilies(run.riders, members, consents, run.date, run.driverUid), 0);
    }
  }
  return { balance, perWeek };
}

describe("fairness over a term (F37, review blocking 3)", () => {
  it("a family that joins in week 5 gets its share from then on, not every run", () => {
    const a = member("a", 1);
    const b = member("b", 1);
    const n = member("n", 1);
    const { balance, perWeek } = simulate(8, (w) => (w < 4 ? [a, b] : [a, b, n]));
    for (let w = 4; w < 8; w++) {
      const got = perWeek[w].get("n") ?? 0;
      assert.ok(got >= 3 && got <= 4, `week ${w + 1}: n drove ${got} of 10`);
    }
    // Over weeks 5 to 8 (40 runs) each family drove about a third.
    const fromJoin = (uid: string) => perWeek.slice(4).reduce((x, m) => x + (m.get(uid) ?? 0), 0);
    for (const uid of ["a", "b", "n"]) assert.ok(Math.abs(fromJoin(uid) - 40 / 3) <= 1, `${uid} drove ${fromJoin(uid)}`);
    assert.ok(Math.abs(balance.families.n.share - 40 / 3) < 1e-9);
  });

  it("1 child against 2 children, with a family that cannot drive, approaches 1:2", () => {
    const a = member("a", 1);
    const b = member("b", 2);
    const c = member("c", 3, { seats: null });
    const big = (m: MemberRecord) => ({ ...m, car: m.car ? car(8) : null });
    const { balance } = simulate(20, () => [big(a), big(b), big(c)]);
    const fa = balance.families.a.driven;
    const fb = balance.families.b.driven;
    assert.equal(fa + fb, 200);
    assert.equal(balance.families.c?.driven ?? 0, 0);
    assert.ok(Math.abs(fa - 200 / 3) <= 1, `a drove ${fa}`);
    assert.ok(Math.abs(fb - 400 / 3) <= 1, `b drove ${fb}`);
    assert.equal(balance.families.c?.share ?? 0, 0);
  });

  it("planning three weeks ahead on one day stays even (other weeks count)", () => {
    const fams = [member("a", 1), member("b", 1), member("c", 1)];
    const consents = allConsents(fams);
    const planned: RunRecord[] = [];
    for (let w = 0; w < 3; w++) {
      const weekStart = addDays(WEEK, w * 7);
      const { runs } = proposeWeek(rotation(fams, { weekStart, consents, otherRuns: planned }));
      planned.push(...runs);
    }
    const counts = countBy(planned);
    assert.deepEqual([...counts.values()].sort(), [10, 10, 10]);
  });
});

describe("time changes on planned and confirmed runs (F30, F28, review blocking 2)", () => {
  const base = (): RunRecord => {
    const run = proposeWeek(rotation([member("a", 1), member("b", 1)])).runs.find((r) => r.id === "2026-11-15_pm") as RunRecord;
    return run;
  };

  it("an early dismissal on a late-deadline run moves the confirm-by time before the new start", () => {
    // Planned on Sunday morning: confirm by 13:30 for the 14:30 run.
    const sunday10 = cairoToUtcMs("2026-11-15", "10:00");
    const late = { ...base(), confirmByMs: cairoToUtcMs("2026-11-15", "13:30") };
    const moved = retimeRun(late, "12:00", sunday10, DEFAULT_DEADLINES);
    assert.equal(moved.missed, false);
    assert.equal(moved.run.startMs, cairoToUtcMs("2026-11-15", "12:00"));
    assert.equal(moved.run.confirmByMs, cairoToUtcMs("2026-11-15", "11:00"));
    assert.ok(moved.run.confirmByMs < moved.run.startMs);
  });

  it("when the new deadline has passed, the run is missed at once (alert now, not after pickup)", () => {
    const at11 = cairoToUtcMs("2026-11-15", "11:00");
    const late = { ...base(), confirmByMs: cairoToUtcMs("2026-11-15", "13:30") };
    const moved = retimeRun(late, "11:30", at11, DEFAULT_DEADLINES);
    assert.equal(moved.missed, true);
    assert.equal(moved.run.status, "missed");
    assert.equal(moved.run.driverUid, null);
    // A new start already past: missed too, never counted as completed.
    const past = retimeRun({ ...base(), status: "confirmed" }, "10:30", at11, DEFAULT_DEADLINES);
    assert.equal(past.run.status, "missed");
  });

  it("a confirmed driver is asked to confirm again; with no time left the driver stays and is told", () => {
    const sat = NOW;
    const again = retimeRun({ ...base(), status: "confirmed", confirmedAtMs: 1 }, "13:00", sat, DEFAULT_DEADLINES);
    assert.equal(again.run.status, "planned");
    assert.equal(again.notice, "reconfirm");
    assert.equal(again.run.confirmByMs, Date.UTC(2026, 10, 14, 19));
    const close = cairoToUtcMs("2026-11-15", "12:30");
    const told = retimeRun({ ...base(), status: "confirmed" }, "13:00", close, DEFAULT_DEADLINES);
    assert.equal(told.run.status, "confirmed");
    assert.equal(told.notice, "moved");
  });
});

// --------------------------------------------------------------------------
// Flows over the in-memory store
// --------------------------------------------------------------------------

function setup() {
  const store = new MemoryCarpoolStore();
  const clock = { now: NOW };
  const deps: CarpoolDeps = {
    store,
    now: () => clock.now,
    limits: { ...DEFAULT_CARPOOL_LIMITS },
    newCode: () => "ABCDEFGH22",
    linkBase: "https://links.example",
    deadlines: DEFAULT_DEADLINES,
  };
  store.schools.set("nile", { id: "nile", nameAr: "النيل", nameEn: "Nile", status: "active" });
  store.areas.set("degla", { id: "degla", schoolId: "nile", nameAr: "دجلة", nameEn: "Degla" });
  for (const [uid, name] of [["alice", "Alice"], ["bob", "Bob"], ["cara", "Cara"]]) store.accounts.set(uid, { status: "verified", firstName: name });
  store.children.set("alice", [{ id: "a1", firstName: "Adam", grade: "g3", schoolId: "nile" }]);
  store.children.set("bob", [
    { id: "b1", firstName: "Bassel", grade: "g2", schoolId: "nile" },
    { id: "b2", firstName: "Bana", grade: "kg2", schoolId: "nile" },
  ]);
  store.children.set("cara", [{ id: "c1", firstName: "Celine", grade: "g5", schoolId: "nile" }]);
  const vehicle = (seats: number) => ({ status: "approved", seats, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" });
  store.vehicles.set("alice", vehicle(4));
  store.vehicles.set("bob", vehicle(6));
  return { store, clock, deps };
}

const as = (uid: string): Caller => ({ uid, verifiedClaim: true });

async function rejects(p: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(p, (e: unknown) => e instanceof CarpoolError && e.reason === reason);
}

/** Alice (admin, 1 child, car), Bob (2 children, car), Cara (1 child, no car); everyone accepts Alice and Bob. */
async function readyCarpool(deps: CarpoolDeps, { consent = true } = {}): Promise<string> {
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
    acceptVolunteer: true,
  });
  for (const [uid, kids] of [["bob", ["b1", "b2"]], ["cara", ["c1"]]] as const) {
    await requestToJoin(deps, as(uid), { carpoolId, childIds: kids, acceptRules: true, acceptVolunteer: true });
    await decideJoinRequest(deps, as("alice"), { carpoolId, uid, approve: true });
  }
  if (consent) {
    for (const [parent, driver] of [["bob", "alice"], ["cara", "alice"], ["alice", "bob"], ["cara", "bob"]]) {
      await setDriverConsent(deps, as(parent), { carpoolId, driverUid: driver, accept: true });
    }
    await setDrivingDays(deps, as("bob"), { carpoolId, days: ["sun", "mon", "tue", "wed", "thu"] });
  }
  return carpoolId;
}

function runsOf(store: MemoryCarpoolStore, carpoolId: string): RunRecord[] {
  return [...(store.runs.get(carpoolId)?.values() ?? [])].sort((a, b) => a.id.localeCompare(b.id));
}

describe("driving days (F7)", () => {
  it("a member chooses carpool days only after every parent accepted them", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps, { consent: false });
    await rejects(setDrivingDays(deps, as("bob"), { carpoolId: k, days: ["sun"] }), "no-consent");
    await rejects(setDrivingDays(deps, as("cara"), { carpoolId: k, days: ["sun"] }), "no-car");
    await setDriverConsent(deps, as("alice"), { carpoolId: k, driverUid: "bob", accept: true });
    await setDriverConsent(deps, as("cara"), { carpoolId: k, driverUid: "bob", accept: true });
    await rejects(setDrivingDays(deps, as("bob"), { carpoolId: k, days: ["fri"] }), "invalid-request");
    assert.deepEqual(await setDrivingDays(deps, as("bob"), { carpoolId: k, days: ["mon", "sun"] }), { days: ["sun", "mon"] });
    assert.deepEqual(store.members.get(k)?.get("bob")?.drivingDays, ["sun", "mon"]);
    // Clearing days is always allowed.
    await setDrivingDays(deps, as("cara"), { carpoolId: k, days: [] });
  });
});

describe("plan a week (F7)", () => {
  it("only the group admin plans, this week or up to three ahead", async () => {
    const { deps } = setup();
    const k = await readyCarpool(deps);
    await rejects(planWeek(deps, as("bob"), { carpoolId: k, weekStart: WEEK }), "not-admin");
    await rejects(planWeek(deps, as("alice"), { carpoolId: k, weekStart: "2026-11-15" }), "not-plannable");
    await rejects(planWeek(deps, as("alice"), { carpoolId: k, weekStart: "2026-12-12" }), "not-plannable");
  });

  it("this week's plan has a proposed driver for every run, riders and a confirm-by time", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    const result = await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    assert.deepEqual(result, { weekStart: WEEK, planned: 10, open: 0 });
    const runs = runsOf(store, k);
    assert.equal(runs.length, 10);
    assert.ok(runs.every((r) => r.status === "planned" && (r.driverUid === "alice" || r.driverUid === "bob")));
    assert.deepEqual(runs[0].riders.map((r) => r.id).sort(), ["a1", "b1", "b2", "c1"]);
    assert.equal(runs[0].confirmByMs, Date.UTC(2026, 10, 14, 19));
    // Bob brings two children: he is offered more runs than Alice.
    const counts = countBy(runs);
    assert.ok((counts.get("bob") ?? 0) > (counts.get("alice") ?? 0));
    assert.equal(store.events.at(-1)?.type, "plan-ready");
    assert.deepEqual(store.events.at(-1)?.recipients, ["alice", "bob", "cara"]);
  });

  it("planning again keeps confirmed runs and their drivers", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const first = runsOf(store, k)[0];
    await confirmRun(deps, as(first.driverUid as string), { carpoolId: k, runId: first.id });
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const again = runsOf(store, k)[0];
    assert.equal(again.status, "confirmed");
    assert.equal(again.driverUid, first.driverUid);
  });
});

describe("driver confirmation (F28) and the backups rule", () => {
  it("only the proposed driver confirms, before the cut-off", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k)[0];
    const other = run.driverUid === "alice" ? "bob" : "alice";
    await rejects(confirmRun(deps, as(other), { carpoolId: k, runId: run.id }), "not-driver");
    await rejects(confirmRun(deps, as("cara"), { carpoolId: k, runId: run.id }), "not-driver");
    clock.now = run.confirmByMs;
    await rejects(confirmRun(deps, as(run.driverUid as string), { carpoolId: k, runId: run.id }), "too-late");
  });

  it("confirming checks consent again", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "bob") as RunRecord;
    // Cara withdraws: Bob's runs carrying Celine lose their driver at once.
    await setDriverConsent(deps, as("cara"), { carpoolId: k, driverUid: "bob", accept: false });
    const after = store.runs.get(k)?.get(run.id) as RunRecord;
    assert.equal(after.status, "open");
    assert.equal(after.driverUid, null);
    assert.equal(store.events.at(-1)?.type, "driver-unavailable");
    await rejects(confirmRun(deps, as("bob"), { carpoolId: k, runId: run.id }), "not-driver");
  });

  it("with no confirmation by the cut-off the run is missed, every parent is alerted, and nobody is assigned", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const [sunAm, sunPm] = runsOf(store, k);
    await confirmRun(deps, as(sunAm.driverUid as string), { carpoolId: k, runId: sunAm.id });
    clock.now = sunPm.confirmByMs + MIN;
    const result = await runScheduleTick(deps);
    assert.equal(result.missed, 1);
    const pm = store.runs.get(k)?.get(sunPm.id) as RunRecord;
    assert.equal(pm.status, "missed");
    assert.equal(pm.driverUid, null);
    assert.equal(store.runs.get(k)?.get(sunAm.id)?.status, "confirmed");
    const alert = store.events.find((e) => e.type === "no-driver" && e.runId === sunPm.id);
    assert.ok(alert);
    assert.equal(alert.critical, true);
    assert.deepEqual(alert.recipients, ["alice", "bob", "cara"]);
    // A second tick changes nothing (no double alerts).
    const count = store.events.length;
    await runScheduleTick(deps);
    assert.equal(store.events.filter((e) => e.type === "no-driver").length, store.events.slice(0, count).filter((e) => e.type === "no-driver").length);
    // A missed run cannot be taken afterwards.
    await rejects(takeRun(deps, as("alice"), { carpoolId: k, runId: sunPm.id }), "too-late");
  });

  it("a confirmed run counts in the drive balance once it has started, once only", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k)[0];
    const driver = run.driverUid as string;
    await confirmRun(deps, as(driver), { carpoolId: k, runId: run.id });
    clock.now = run.startMs + MIN;
    const first = await runScheduleTick(deps);
    assert.equal(first.completed, 1);
    await runScheduleTick(deps);
    const balance = store.balances.get(k)?.get("2026-t1");
    assert.equal(balance?.families[driver].driven, 1);
    for (const parent of ["alice", "bob", "cara"].filter((p) => p !== driver)) assert.equal(balance?.families[parent].received, 1);
    assert.equal(store.runs.get(k)?.get(run.id)?.status, "completed");
  });
});

describe("swaps (F11)", () => {
  it("the driver asks for a swap; any eligible member accepts and the schedule updates", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "alice") as RunRecord;
    await rejects(requestSwap(deps, as("bob"), { carpoolId: k, runId: run.id }), "not-driver");
    const swap = await requestSwap(deps, as("alice"), { carpoolId: k, runId: run.id });
    assert.equal(swap.status, "open");
    assert.deepEqual(swap.suggestedUids, ["bob"]);
    const open = store.runs.get(k)?.get(run.id) as RunRecord;
    assert.equal(open.status, "open");
    assert.equal(open.driverUid, null);
    assert.equal(open.swapBy, "alice");
    assert.equal(store.events.at(-1)?.type, "swap-requested");
    assert.deepEqual(store.events.at(-1)?.recipients, ["bob", "cara"]);
    // Cara has no car; Alice asked for it (she cancels instead).
    await rejects(takeRun(deps, as("cara"), { carpoolId: k, runId: run.id }), "no-car");
    await rejects(takeRun(deps, as("alice"), { carpoolId: k, runId: run.id }), "invalid-request");
    const taken = await takeRun(deps, as("bob"), { carpoolId: k, runId: run.id });
    assert.equal(taken.status, "confirmed");
    assert.equal(taken.driverUid, "bob");
    assert.equal(taken.swapped, true);
    assert.equal(store.swaps.get(k)?.get(swap.id)?.status, "accepted");
    assert.equal(store.swaps.get(k)?.get(swap.id)?.acceptedBy, "bob");
    assert.equal(store.events.at(-1)?.type, "swap-accepted");
    await rejects(takeRun(deps, as("bob"), { carpoolId: k, runId: run.id }), "run-taken");
  });

  it("two members accepting at once: only one gets the run", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    store.vehicles.set("cara", { status: "approved", seats: 5, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" });
    // Cara's car is read when she joined (none); give it through the member record for this test.
    const cara = store.members.get(k)?.get("cara") as MemberRecord;
    store.members.get(k)?.set("cara", { ...cara, car: { seats: 5, validUntil: "2030-01-01" } });
    for (const parent of ["alice", "bob"]) await setDriverConsent(deps, as(parent), { carpoolId: k, driverUid: "cara", accept: true });
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "alice") as RunRecord;
    await requestSwap(deps, as("alice"), { carpoolId: k, runId: run.id });
    const results = await Promise.allSettled([takeRun(deps, as("bob"), { carpoolId: k, runId: run.id }), takeRun(deps, as("cara"), { carpoolId: k, runId: run.id })]);
    assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
    const failed = results.find((r) => r.status === "rejected") as PromiseRejectedResult;
    assert.equal((failed.reason as CarpoolError).reason, "run-taken");
  });

  it("taking a run checks seats and consent on the server", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "bob") as RunRecord;
    await requestSwap(deps, as("bob"), { carpoolId: k, runId: run.id });
    // Alice's car has 4 seats for 4 children; with a smaller car she cannot take it.
    const car = store.vehicles.get("alice");
    store.vehicles.set("alice", { status: "approved", seats: 3, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" });
    await rejects(takeRun(deps, as("alice"), { carpoolId: k, runId: run.id }), "too-many-children");
    if (car) store.vehicles.set("alice", car);
    await setDriverConsent(deps, as("cara"), { carpoolId: k, driverUid: "alice", accept: false });
    await rejects(takeRun(deps, as("alice"), { carpoolId: k, runId: run.id }), "no-consent");
  });

  it("the requester can take a swap back before anyone accepts", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "alice") as RunRecord;
    await confirmRun(deps, as("alice"), { carpoolId: k, runId: run.id });
    const swap = await requestSwap(deps, as("alice"), { carpoolId: k, runId: run.id });
    await rejects(cancelSwap(deps, as("bob"), { carpoolId: k, runId: run.id }), "not-driver");
    const back = await cancelSwap(deps, as("alice"), { carpoolId: k, runId: run.id });
    assert.equal(back.status, "confirmed");
    assert.equal(back.driverUid, "alice");
    assert.equal(store.swaps.get(k)?.get(swap.id)?.status, "cancelled");
  });

  it("an unanswered swap expires at the cut-off and the group is told to take their own child", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "alice") as RunRecord;
    const swap = await requestSwap(deps, as("alice"), { carpoolId: k, runId: run.id });
    clock.now = run.confirmByMs + MIN;
    await runScheduleTick(deps);
    assert.equal(store.swaps.get(k)?.get(swap.id)?.status, "expired");
    assert.equal(store.runs.get(k)?.get(run.id)?.status, "missed");
    assert.ok(store.events.some((e) => e.type === "no-driver" && e.runId === run.id && e.critical));
  });

  it("a swap asked after the cut-off stays open until an hour before the run", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "alice" && r.direction === "toHome") as RunRecord;
    await confirmRun(deps, as("alice"), { carpoolId: k, runId: run.id });
    clock.now = run.startMs - 3 * HOUR;
    await requestSwap(deps, as("alice"), { carpoolId: k, runId: run.id });
    const open = store.runs.get(k)?.get(run.id) as RunRecord;
    assert.equal(open.status, "open");
    assert.equal(open.confirmByMs, run.startMs - HOUR);
    clock.now = run.startMs - 30 * MIN;
    await rejects(takeRun(deps, as("bob"), { carpoolId: k, runId: run.id }), "too-late");
  });
});

describe("child absent today (F27)", () => {
  it("removes the child from that day's pickup list and tells the driver and group", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    await rejects(setChildAbsent(deps, as("cara"), { carpoolId: k, date: "2026-11-15", childId: "b1", absent: true }), "not-your-child");
    const r = await setChildAbsent(deps, as("cara"), { carpoolId: k, date: "2026-11-15", childId: "c1", absent: true });
    assert.deepEqual(r.changed, ["2026-11-15_am", "2026-11-15_pm"]);
    const am = store.runs.get(k)?.get("2026-11-15_am") as RunRecord;
    assert.ok(!am.riders.some((x) => x.id === "c1"));
    assert.deepEqual(am.absent.map((x) => x.id), ["c1"]);
    const ev = store.events.filter((e) => e.type === "child-absent");
    assert.equal(ev.length, 2);
    assert.ok(ev[0].recipients.includes(am.driverUid as string));
    assert.ok(!ev[0].recipients.includes("cara"));
    assert.equal(ev[0].childId, "c1");
    // Other days do not change.
    assert.ok((store.runs.get(k)?.get("2026-11-16_am") as RunRecord).riders.some((x) => x.id === "c1"));
    // Back again: on the list once more.
    await setChildAbsent(deps, as("cara"), { carpoolId: k, date: "2026-11-15", childId: "c1", absent: false, directions: ["toSchool"] });
    const back = store.runs.get(k)?.get("2026-11-15_am") as RunRecord;
    assert.ok(back.riders.some((x) => x.id === "c1"));
    assert.equal(back.absent.length, 0);
  });

  it("a run that has started does not change", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    clock.now = (store.runs.get(k)?.get("2026-11-15_pm") as RunRecord).startMs + MIN;
    await rejects(setChildAbsent(deps, as("cara"), { carpoolId: k, date: "2026-11-15", childId: "c1", absent: true }), "too-late");
  });
});

describe("exceptions on a planned week (F30)", () => {
  it("a holiday cancels that day's runs and their swaps; removing it reopens them without a driver", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const tue = runsOf(store, k).find((r) => r.id === "2026-11-17_am") as RunRecord;
    await rejects(saveException(deps, as("bob"), { carpoolId: k, kind: "noSchool", reason: "holiday", from: "2026-11-17" }), "not-admin");
    const ex = await saveException(deps, as("alice"), { carpoolId: k, kind: "noSchool", reason: "holiday", from: "2026-11-17" });
    assert.equal(store.runs.get(k)?.get(tue.id)?.status, "cancelled");
    assert.equal(store.runs.get(k)?.get(tue.id)?.driverUid, null);
    assert.equal(store.events.at(-1)?.type, "schedule-changed");
    await deleteException(deps, as("alice"), { carpoolId: k, exceptionId: ex.id });
    assert.equal(store.runs.get(k)?.get(tue.id)?.status, "open");
    // The admin plans again to propose a driver.
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    assert.equal(store.runs.get(k)?.get(tue.id)?.status, "planned");
  });

  it("Ramadan times move planned runs and keep their drivers", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const before = store.runs.get(k)?.get("2026-11-18_pm") as RunRecord;
    await saveException(deps, as("alice"), { carpoolId: k, kind: "times", reason: "ramadan", from: "2026-11-18", to: "2026-11-19", morning: "08:30", afternoon: "13:30" });
    const after = store.runs.get(k)?.get("2026-11-18_pm") as RunRecord;
    assert.equal(after.time, "13:30");
    assert.equal(after.startMs, Date.UTC(2026, 10, 18, 11, 30));
    assert.equal(after.driverUid, before.driverUid);
  });

  it("an early dismissal on the day: a late-deadline run is missed at once and everyone is alerted", async () => {
    const { deps, store, clock } = setup();
    const k = await readyCarpool(deps);
    // Planned on Sunday at 10:00: the 14:30 run must be confirmed by 13:30.
    clock.now = cairoToUtcMs("2026-11-15", "10:00");
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const pm = store.runs.get(k)?.get("2026-11-15_pm") as RunRecord;
    assert.equal(pm.confirmByMs, cairoToUtcMs("2026-11-15", "13:30"));
    // At 11:00 the admin moves pickup to 11:30: no time left to confirm.
    clock.now = cairoToUtcMs("2026-11-15", "11:00");
    await saveException(deps, as("alice"), { carpoolId: k, kind: "times", reason: "early", from: "2026-11-15", afternoon: "11:30" });
    const after = store.runs.get(k)?.get(pm.id) as RunRecord;
    assert.equal(after.status, "missed");
    assert.equal(after.driverUid, null);
    const alert = store.events.find((e) => e.type === "no-driver" && e.runId === pm.id);
    assert.ok(alert?.critical);
    assert.deepEqual(alert?.recipients, ["alice", "bob", "cara"]);
  });

  it("a time change asks a confirmed driver to confirm again, before the new start", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = store.runs.get(k)?.get("2026-11-17_pm") as RunRecord;
    const driver = run.driverUid as string;
    await confirmRun(deps, as(driver), { carpoolId: k, runId: run.id });
    await saveException(deps, as("alice"), { carpoolId: k, kind: "times", reason: "early", from: "2026-11-17", afternoon: "12:00" });
    const after = store.runs.get(k)?.get(run.id) as RunRecord;
    assert.equal(after.status, "planned");
    assert.equal(after.driverUid, driver);
    assert.ok(after.confirmByMs < after.startMs);
    const notice = store.events.find((e) => e.type === "time-changed" && e.runId === run.id);
    assert.deepEqual(notice?.recipients, [driver]);
    await confirmRun(deps, as(driver), { carpoolId: k, runId: run.id });
    assert.equal(store.runs.get(k)?.get(run.id)?.status, "confirmed");
  });

  it("checks input: kinds, reasons, ranges up to 60 days, times only for runs the carpool has", async () => {
    const { deps } = setup();
    const k = await readyCarpool(deps);
    const bad = [
      { kind: "party", reason: "holiday", from: "2026-11-17" },
      { kind: "noSchool", reason: "fun", from: "2026-11-17" },
      { kind: "noSchool", reason: "holiday", from: "2026-11-18", to: "2026-11-17" },
      { kind: "noSchool", reason: "holiday", from: "2026-11-17", to: "2027-01-20" },
      { kind: "times", reason: "early", from: "2026-11-17" },
      { kind: "times", reason: "early", from: "2026-11-17", afternoon: "12:07" },
      { kind: "noSchool", reason: "holiday", from: "2026-02-30" },
      { kind: "noSchool", reason: "holiday", from: "2026-10-01" },
    ];
    for (const b of bad) await rejects(saveException(deps, as("alice"), { carpoolId: k, ...b }), "invalid-request");
  });
});

describe("leaving and consent (Prompt 6 hooks)", () => {
  it("a member who leaves leaves every future pickup list; their runs lose their driver", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const bobs = runsOf(store, k).filter((r) => r.driverUid === "bob").map((r) => r.id);
    await leaveCarpool(deps, as("bob"), { carpoolId: k });
    for (const run of runsOf(store, k)) {
      assert.ok(!run.riders.some((r) => r.parentUid === "bob"));
      if (bobs.includes(run.id)) {
        assert.equal(run.status, "open");
        assert.equal(run.driverUid, null);
      }
    }
    assert.ok(store.events.some((e) => e.type === "driver-unavailable" && e.actorUid === "bob"));
  });
});

describe("every driver assignment checks consent, seats, car and account (Prompt 6 review)", () => {
  it("the creator's own driving days give no run before the other parents consent", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps, { consent: false });
    // Alice chose every day at creation, but Bob and Cara never accepted her.
    const result = await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    assert.deepEqual([result.planned, result.open], [0, 10]);
    assert.ok(runsOf(store, k).every((r) => r.status === "open" && r.driverUid === null));
  });

  it("a car re-verified with fewer seats or expired papers stops that member driving at once", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const run = runsOf(store, k).find((r) => r.driverUid === "bob") as RunRecord;
    // Bob's car now has 3 passenger seats (4 children ride): the member copy still says 6.
    store.vehicles.set("bob", { status: "approved", seats: 3, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" });
    await rejects(confirmRun(deps, as("bob"), { carpoolId: k, runId: run.id }), "too-many-children");
    store.vehicles.set("bob", { status: "approved", seats: 6, licenseExpiry: "2026-11-01", carLicenseExpiry: "2030-01-01" });
    await rejects(confirmRun(deps, as("bob"), { carpoolId: k, runId: run.id }), "car-expired");
    await rejects(setDrivingDays(deps, as("bob"), { carpoolId: k, days: ["sun"] }), "car-expired");
    // Planning again moves Bob's runs to Alice and updates the members' copy of his car.
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    assert.ok(runsOf(store, k).every((r) => r.driverUid === "alice"));
    assert.equal(store.members.get(k)?.get("bob")?.car?.validUntil, "2026-11-01");
  });

  it("a suspended parent cannot confirm or take a run", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const mine = runsOf(store, k).find((r) => r.driverUid === "alice") as RunRecord;
    await requestSwap(deps, as("alice"), { carpoolId: k, runId: mine.id });
    store.accounts.set("bob", { status: "suspended", firstName: "Bob" });
    // Bob's own token still says verified; the account read in the transaction does not.
    await assert.rejects(takeRun(deps, as("bob"), { carpoolId: k, runId: mine.id }), CarpoolError);
    assert.equal(store.runs.get(k)?.get(mine.id)?.driverUid, null);
  });
});

describe("the Done-when flow", () => {
  it("see this week's plan, swap one run with the second parent, mark a child absent, add a holiday", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    assert.ok(runsOf(store, k).every((r) => r.driverUid !== null));
    const mine = runsOf(store, k).find((r) => r.driverUid === "alice") as RunRecord;
    await requestSwap(deps, as("alice"), { carpoolId: k, runId: mine.id });
    await takeRun(deps, as("bob"), { carpoolId: k, runId: mine.id });
    assert.equal(store.runs.get(k)?.get(mine.id)?.driverUid, "bob");
    await setChildAbsent(deps, as("alice"), { carpoolId: k, date: "2026-11-16", childId: "a1", absent: true });
    await saveException(deps, as("alice"), { carpoolId: k, kind: "noSchool", reason: "holiday", from: "2026-11-19" });
    assert.equal(store.runs.get(k)?.get(runId("2026-11-19", "toSchool"))?.status, "cancelled");
  });
});

describe("urgent report pauses driving (Prompt 9, spec section 6)", () => {
  it("every future run of the driver opens for the group, who are told only that the driver is unavailable", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    const bobs = runsOf(store, k).filter((r) => r.driverUid === "bob");
    assert.ok(bobs.length > 0);
    const before = store.events.length;
    const result = await pauseDriverRuns(deps, "bob");
    assert.deepEqual(result, { carpools: 1, runs: bobs.length });
    for (const r of bobs) {
      const after = store.runs.get(k)?.get(r.id) as RunRecord;
      assert.equal(after.status, "open");
      assert.equal(after.driverUid, null);
    }
    const events = store.events.slice(before);
    assert.equal(events.length, bobs.length);
    assert.ok(events.every((e) => e.type === "driver-unavailable" && e.actorUid === "bob"));
    // Alice's runs keep their driver.
    assert.ok(runsOf(store, k).filter((r) => r.driverUid === "alice").length > 0);
  });

  it("a paused driver (status paused) cannot take an open run", async () => {
    const { deps, store } = setup();
    const k = await readyCarpool(deps);
    await planWeek(deps, as("alice"), { carpoolId: k, weekStart: WEEK });
    await pauseDriverRuns(deps, "bob");
    store.accounts.set("bob", { status: "paused", firstName: "Bob" });
    const open = runsOf(store, k).find((r) => r.status === "open") as RunRecord;
    await assert.rejects(takeRun(deps, as("bob"), { carpoolId: k, runId: open.id }));
    assert.equal(store.runs.get(k)?.get(open.id)?.driverUid, null);
  });
});
