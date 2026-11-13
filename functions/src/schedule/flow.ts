import {
  requireActiveCarpool,
  requireApproved,
  requireVerified,
  take,
  type Caller,
  type CarpoolDeps,
  type CarpoolTx,
} from "../carpools/flow";
import {
  cairoDate,
  CarpoolError,
  docId,
  driverStatus,
  parseDays,
  parseTime,
  record,
  type ArrangementProblem,
  type CarpoolRecord,
} from "../carpools/model";
import { addDays, cairoToUtcMs, daysBetween, isDate, termOf, weekStartOf } from "./cairo";
import {
  addToBalance,
  confirmDeadline,
  dayPlan,
  DEFAULT_DEADLINES,
  DIRECTIONS,
  EXCEPTION_FUTURE_DAYS,
  EXCEPTION_PAST_DAYS,
  EXCEPTION_REASONS,
  isLive,
  leastDrivenFirst,
  MAX_EXCEPTION_DAYS,
  MAX_EXCEPTIONS,
  parseRunId,
  plannableWeek,
  proposeWeek,
  runProblem,
  type DeadlineSettings,
  type Direction,
  type ExceptionKind,
  type ExceptionReason,
  type ExceptionRecord,
  type RunRecord,
  type SwapRecord,
} from "./model";
import { event, releaseRun, runEvent, uids } from "./release";

/**
 * Schedule flows (Prompt 7: F7, F11, F27, F28, F30, F37). Every write
 * happens here, inside one store transaction that re-reads what it checks
 * (the run, the members, the consents); the app writes nothing
 * (firestore.rules). Logs never get names, children or times.
 */

const DAY_MS = 24 * 3_600_000;

function deadlines(deps: CarpoolDeps): DeadlineSettings {
  return deps.deadlines ?? DEFAULT_DEADLINES;
}

/** The error for a run a driver may not take (F26 consent, seats, car). */
export function arrangementError(problem: ArrangementProblem): CarpoolError {
  switch (problem.reason) {
    case "not-member":
      return new CarpoolError("not-member");
    case "no-car":
      return new CarpoolError("no-car");
    case "car-expired":
      return new CarpoolError("car-expired");
    case "too-many-children":
      return new CarpoolError("too-many-children");
    case "no-consent":
      return new CarpoolError("no-consent");
    default:
      return new CarpoolError("invalid-request");
  }
}


function parseCarpoolRun(data: unknown): { carpoolId: string; runId: string } {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  if (!parseRunId(raw.runId)) throw new CarpoolError("invalid-request");
  return { carpoolId, runId: raw.runId as string };
}

async function liveRun(tx: CarpoolTx, carpoolId: string, id: string, nowMs: number): Promise<RunRecord> {
  const run = await tx.run(carpoolId, id);
  if (!run) throw new CarpoolError("not-found");
  if (!isLive(run, nowMs)) throw new CarpoolError("too-late");
  return run;
}

// --------------------------------------------------------------------------
// Driving days (F7: members adjust their days)
// --------------------------------------------------------------------------

/**
 * A member chooses the weekdays they can drive. Days must be carpool days,
 * and a member may choose any only when they can drive every child of the
 * carpool: a valid approved car with enough seats and every other
 * parent's consent (F26, Prompt 6's driverStatus). An empty list is always
 * allowed. The next plan uses the new days; runs already planned stay.
 */
export async function setDrivingDays(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ days: string[] }> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const days = parseDays(raw.days, { allowEmpty: true });
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "scheduleChanges", DAY_MS, deps.limits.scheduleChangesPerDay);
  return deps.store.transact(async (tx) => {
    const carpool = await requireActiveCarpool(tx, carpoolId);
    const m = await requireApproved(tx, carpoolId, caller.uid);
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    if (days.some((d) => !carpool.days.includes(d))) throw new CarpoolError("invalid-request");
    const me = members.find((x) => x.uid === caller.uid);
    if (!me) throw new CarpoolError("not-member");
    if (days.length > 0) {
      const status = driverStatus(me, members, consents, cairoDate(deps.now()));
      if (status.problem) throw new CarpoolError(status.problem);
      if (!status.canDrive) throw new CarpoolError("no-consent");
    }
    const nowMs = deps.now();
    tx.putMembership({ ...m, drivingDays: days, updatedAtMs: nowMs });
    tx.putMember(carpoolId, { ...me, drivingDays: days });
    return { days };
  });
}

// --------------------------------------------------------------------------
// Plan a week (F7, F30, F37)
// --------------------------------------------------------------------------

export interface PlanResult {
  weekStart: string;
  planned: number;
  open: number;
}

/**
 * The group admin plans a week (this week or up to three ahead): the
 * rotation proposes one driver per run, each of whom must confirm (F28).
 * Planning again fills open runs and keeps everything confirmed. Riders
 * are the approved members' children (absences kept). An alert tells
 * every member the plan is ready.
 */
export async function planWeek(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<PlanResult> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const weekStart = raw.weekStart;
  const nowMs = deps.now();
  const today = cairoDate(nowMs);
  if (typeof weekStart !== "string" || !plannableWeek(weekStart, weekStartOf(today))) throw new CarpoolError("not-plannable");
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "plans", DAY_MS, deps.limits.plansPerDay);
  return deps.store.transact(async (tx) => {
    const carpool = await requireActiveCarpool(tx, carpoolId);
    const admin = await requireApproved(tx, carpoolId, caller.uid);
    if (admin.role !== "admin") throw new CarpoolError("not-admin");
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    const exceptions = await tx.exceptions(carpoolId);
    const existing = await tx.runs(carpoolId, weekStart, addDays(weekStart, 6));
    const balance = await tx.balance(carpoolId, termOf(today).id);
    const result = proposeWeek({
      carpool,
      weekStart,
      members,
      consents,
      exceptions,
      existing,
      balance,
      nowMs,
      today,
      deadlines: deadlines(deps),
    });
    for (const run of result.runs) tx.putRun(run);
    const planned = result.runs.filter((r) => r.status === "planned").length;
    tx.addEvent(event("plan-ready", carpoolId, uids(members), nowMs, { date: weekStart, actorUid: caller.uid }));
    return { weekStart, planned, open: result.open.length };
  });
}

// --------------------------------------------------------------------------
// Driver confirmation (F28)
// --------------------------------------------------------------------------

/**
 * The proposed driver confirms a run before its confirm-by time. Consent,
 * seats and the car are checked again: a parent may have withdrawn consent
 * since the plan.
 */
export async function confirmRun(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<RunRecord> {
  const { carpoolId, runId } = parseCarpoolRun(data);
  await requireVerified(deps, caller);
  return deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    await requireApproved(tx, carpoolId, caller.uid);
    const nowMs = deps.now();
    const run = await liveRun(tx, carpoolId, runId, nowMs);
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    if (run.driverUid !== caller.uid || run.status === "open") throw new CarpoolError("not-driver");
    if (run.status === "confirmed") return run;
    if (nowMs >= run.confirmByMs) throw new CarpoolError("too-late");
    const problem = runProblem(caller.uid, run.riders, members, consents, cairoDate(nowMs));
    if (problem) throw arrangementError(problem);
    const next: RunRecord = { ...run, status: "confirmed", confirmedAtMs: nowMs, updatedAtMs: nowMs };
    tx.putRun(next);
    return next;
  });
}

// --------------------------------------------------------------------------
// Swaps (F11)
// --------------------------------------------------------------------------

/**
 * The run's driver (proposed or confirmed) cannot drive and asks for a
 * swap. The run is open at once: it never keeps a driver who cannot drive.
 * Every member is alerted; the swap lists eligible members, the family
 * that has driven least first (F37).
 */
export async function requestSwap(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<SwapRecord> {
  const { carpoolId, runId } = parseCarpoolRun(data);
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "scheduleChanges", DAY_MS, deps.limits.scheduleChangesPerDay);
  const swapId = deps.store.newId();
  return deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    const m = await requireApproved(tx, carpoolId, caller.uid);
    const nowMs = deps.now();
    const run = await liveRun(tx, carpoolId, runId, nowMs);
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    const balance = await tx.balance(carpoolId, run.termId);
    if (run.driverUid !== caller.uid || (run.status !== "planned" && run.status !== "confirmed")) throw new CarpoolError("not-driver");
    const today = cairoDate(nowMs);
    const eligible = members.filter((x) => x.uid !== caller.uid && runProblem(x.uid, run.riders, members, consents, today) === null);
    const released = releaseRun(run, uids(members).filter((u) => u !== caller.uid), nowMs, deadlines(deps), swapId);
    const swap: SwapRecord = {
      id: swapId,
      carpoolId,
      runId,
      date: run.date,
      direction: run.direction,
      requesterUid: caller.uid,
      requesterFirstName: m.firstName,
      previousStatus: run.status,
      status: released.run.status === "missed" ? "expired" : "open",
      acceptedBy: null,
      suggestedUids: leastDrivenFirst(eligible, balance),
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
    };
    tx.putRun({ ...released.run, swapBy: released.run.swapId ? caller.uid : null });
    tx.putSwap(swap);
    tx.addEvent({ ...released.event, actorUid: caller.uid });
    return swap;
  });
}

/** The requester takes back an open swap request and drives the run again. */
export async function cancelSwap(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<RunRecord> {
  const { carpoolId, runId } = parseCarpoolRun(data);
  await requireVerified(deps, caller);
  return deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    const m = await requireApproved(tx, carpoolId, caller.uid);
    const nowMs = deps.now();
    const run = await liveRun(tx, carpoolId, runId, nowMs);
    const swap = run.swapId ? await tx.swap(carpoolId, run.swapId) : null;
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    if (!swap || swap.status !== "open" || run.status !== "open") throw new CarpoolError("run-taken");
    if (swap.requesterUid !== caller.uid) throw new CarpoolError("not-driver");
    if (nowMs >= run.confirmByMs) throw new CarpoolError("too-late");
    const problem = runProblem(caller.uid, run.riders, members, consents, cairoDate(nowMs));
    if (problem) throw arrangementError(problem);
    // Taking it back is a confirmation only when it was confirmed before.
    const status = swap.previousStatus;
    const next: RunRecord = {
      ...run,
      status,
      driverUid: caller.uid,
      driverFirstName: m.firstName,
      swapId: null,
      swapBy: null,
      confirmedAtMs: status === "confirmed" ? nowMs : null,
      updatedAtMs: nowMs,
    };
    tx.putRun(next);
    tx.putSwap({ ...swap, status: "cancelled", updatedAtMs: nowMs });
    tx.addEvent(runEvent("swap-cancelled", next, uids(members).filter((u) => u !== caller.uid), nowMs, { actorUid: caller.uid }));
    return next;
  });
}

/**
 * Any eligible member takes an open run: accepting a swap (F11) or
 * filling a run nobody could be proposed for. Taking is the driver's
 * confirmation. Checked inside the transaction: the run is still open, the
 * confirm-by time has not passed, and the member may carry every child on
 * the pickup list (seats, valid car, every parent's consent). The accepted
 * swap updates the schedule.
 */
export async function takeRun(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<RunRecord> {
  const { carpoolId, runId } = parseCarpoolRun(data);
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "scheduleChanges", DAY_MS, deps.limits.scheduleChangesPerDay);
  return deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    const m = await requireApproved(tx, carpoolId, caller.uid);
    const nowMs = deps.now();
    const run = await liveRun(tx, carpoolId, runId, nowMs);
    const swap = run.swapId ? await tx.swap(carpoolId, run.swapId) : null;
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    if (run.status !== "open" || run.driverUid) throw new CarpoolError("run-taken");
    if (nowMs >= run.confirmByMs) throw new CarpoolError("too-late");
    if (swap && swap.status === "open" && swap.requesterUid === caller.uid) throw new CarpoolError("invalid-request");
    const problem = runProblem(caller.uid, run.riders, members, consents, cairoDate(nowMs));
    if (problem) throw arrangementError(problem);
    const next: RunRecord = {
      ...run,
      status: "confirmed",
      driverUid: caller.uid,
      driverFirstName: m.firstName,
      swapped: true,
      fallback: false,
      swapId: null,
      swapBy: null,
      confirmedAtMs: nowMs,
      updatedAtMs: nowMs,
    };
    tx.putRun(next);
    if (swap && swap.status === "open") tx.putSwap({ ...swap, status: "accepted", acceptedBy: caller.uid, updatedAtMs: nowMs });
    const others = uids(members).filter((u) => u !== caller.uid);
    tx.addEvent(runEvent(swap ? "swap-accepted" : "run-taken", next, others, nowMs, { actorUid: caller.uid }));
    return next;
  });
}

// --------------------------------------------------------------------------
// Child absent today (F27)
// --------------------------------------------------------------------------

/**
 * A parent marks their own child absent (or back) for the morning and/or
 * afternoon run of one date. The child leaves (or rejoins) that run's
 * pickup list and the driver and group are alerted. Rejoining checks the
 * driver again (consent and seats). Runs that already started, were
 * missed or cancelled do not change.
 */
export async function setChildAbsent(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ changed: string[] }> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const childId = docId(raw.childId);
  const date = raw.date;
  if (!isDate(date)) throw new CarpoolError("invalid-request");
  if (typeof raw.absent !== "boolean") throw new CarpoolError("invalid-request");
  const absent = raw.absent;
  const directions = Array.isArray(raw.directions) ? raw.directions : DIRECTIONS;
  if (directions.length === 0 || directions.some((d) => !(DIRECTIONS as readonly unknown[]).includes(d))) throw new CarpoolError("invalid-request");
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "scheduleChanges", DAY_MS, deps.limits.scheduleChangesPerDay);
  return deps.store.transact(async (tx) => {
    await requireActiveCarpool(tx, carpoolId);
    const m = await requireApproved(tx, carpoolId, caller.uid);
    if (!m.children.some((c) => c.id === childId)) throw new CarpoolError("not-your-child");
    const nowMs = deps.now();
    const runs = (await tx.runs(carpoolId, date, date)).filter((r) => (directions as Direction[]).includes(r.direction));
    const members = await tx.members(carpoolId);
    const consents = await tx.consents(carpoolId);
    const live = runs.filter((r) => isLive(r, nowMs));
    if (live.length === 0) throw new CarpoolError(runs.length === 0 ? "not-found" : "too-late");
    const changed: string[] = [];
    for (const run of live) {
      const riding = run.riders.find((r) => r.id === childId);
      const away = run.absent.find((r) => r.id === childId);
      if (absent && riding) {
        const next = { ...run, riders: run.riders.filter((r) => r.id !== childId), absent: [...run.absent, riding], updatedAtMs: nowMs };
        tx.putRun(next);
        tx.addEvent(runEvent("child-absent", next, uids(members).filter((u) => u !== caller.uid), nowMs, { actorUid: caller.uid, childId }));
        changed.push(run.id);
      } else if (!absent && away) {
        const riders = [...run.riders, away].sort((a, b) => a.parentUid.localeCompare(b.parentUid) || a.id.localeCompare(b.id));
        if (run.driverUid) {
          const problem = runProblem(run.driverUid, riders, members, consents, cairoDate(nowMs));
          if (problem) throw arrangementError(problem);
        }
        const next = { ...run, riders, absent: run.absent.filter((r) => r.id !== childId), updatedAtMs: nowMs };
        tx.putRun(next);
        tx.addEvent(runEvent("child-back", next, uids(members).filter((u) => u !== caller.uid), nowMs, { actorUid: caller.uid, childId }));
        changed.push(run.id);
      }
    }
    return { changed };
  });
}

// --------------------------------------------------------------------------
// Exceptions (F30)
// --------------------------------------------------------------------------

export function parseException(data: unknown): {
  carpoolId: string;
  kind: ExceptionKind;
  reason: ExceptionReason;
  from: string;
  to: string;
  morning: string | null;
  afternoon: string | null;
} {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const kind = raw.kind;
  if (kind !== "noSchool" && kind !== "times") throw new CarpoolError("invalid-request");
  const reason = raw.reason;
  if (typeof reason !== "string" || !(EXCEPTION_REASONS as readonly string[]).includes(reason)) throw new CarpoolError("invalid-request");
  const from = raw.from;
  const to = raw.to ?? raw.from;
  if (!isDate(from) || !isDate(to) || to < from || daysBetween(from, to) >= MAX_EXCEPTION_DAYS) throw new CarpoolError("invalid-request");
  const morning = kind === "times" ? parseTime(raw.morning) : null;
  const afternoon = kind === "times" ? parseTime(raw.afternoon) : null;
  if (kind === "times" && !morning && !afternoon) throw new CarpoolError("invalid-request");
  return { carpoolId, kind, reason: reason as ExceptionReason, from, to, morning, afternoon };
}

/**
 * Applies the exceptions to the runs already saved between two dates:
 * no-school days cancel runs (and their open swaps), a school day again
 * reopens a cancelled run (with no driver), and times follow the latest
 * change. Confirmed drivers stay confirmed when only the time moves; the
 * group is told the schedule changed.
 */
async function reconcile(
  tx: CarpoolTx,
  deps: CarpoolDeps,
  carpool: CarpoolRecord,
  exceptions: ExceptionRecord[],
  from: string,
  to: string,
  nowMs: number,
): Promise<number> {
  const runs = (await tx.runs(carpool.id, from, to)).filter((r) => r.startMs > nowMs || r.status === "cancelled");
  const swaps = new Map<string, SwapRecord>();
  for (const r of runs) {
    if (r.swapId) {
      const s = await tx.swap(carpool.id, r.swapId);
      if (s) swaps.set(s.id, s);
    }
  }
  let changed = 0;
  for (const run of runs) {
    if (run.status === "completed" || run.status === "missed") continue;
    const plan = dayPlan(carpool, exceptions, run.date);
    const usual = run.direction === "toSchool" ? carpool.morning : carpool.afternoon;
    const time = (run.direction === "toSchool" ? plan.toSchool : plan.toHome) ?? usual ?? run.time;
    if (plan.noSchool) {
      if (run.status === "cancelled") continue;
      const swap = run.swapId ? swaps.get(run.swapId) : undefined;
      if (swap && swap.status === "open") tx.putSwap({ ...swap, status: "cancelled", updatedAtMs: nowMs });
      tx.putRun({ ...run, status: "cancelled", driverUid: null, driverFirstName: "", swapId: null, confirmedAtMs: null, updatedAtMs: nowMs });
      changed++;
      continue;
    }
    const startMs = cairoToUtcMs(run.date, time);
    if (run.status === "cancelled") {
      const deadline = confirmDeadline(run.date, time, nowMs, deadlines(deps));
      if (deadline === null) continue;
      tx.putRun({ ...run, status: "open", time, startMs, confirmByMs: deadline, updatedAtMs: nowMs });
      changed++;
    } else if (time !== run.time) {
      tx.putRun({ ...run, time, startMs, updatedAtMs: nowMs });
      changed++;
    }
  }
  return changed;
}

/** The group admin adds a no-school day (or days) or a time change, for example Ramadan times. */
export async function saveException(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<ExceptionRecord> {
  const input = parseException(data);
  const nowMs = deps.now();
  const today = cairoDate(nowMs);
  if (daysBetween(today, input.from) < -EXCEPTION_PAST_DAYS || daysBetween(today, input.to) > EXCEPTION_FUTURE_DAYS) throw new CarpoolError("invalid-request");
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "scheduleChanges", DAY_MS, deps.limits.scheduleChangesPerDay);
  const id = deps.store.newId();
  return deps.store.transact(async (tx) => {
    const carpool = await requireActiveCarpool(tx, input.carpoolId);
    const admin = await requireApproved(tx, input.carpoolId, caller.uid);
    if (admin.role !== "admin") throw new CarpoolError("not-admin");
    const existing = await tx.exceptions(input.carpoolId);
    const members = await tx.members(input.carpoolId);
    if (existing.length >= MAX_EXCEPTIONS) throw new CarpoolError("too-many-exceptions");
    if (input.kind === "times" && ((input.morning && !carpool.morning) || (input.afternoon && !carpool.afternoon))) {
      throw new CarpoolError("invalid-request");
    }
    const e: ExceptionRecord = { id, ...input, createdBy: caller.uid, createdAtMs: nowMs };
    await reconcile(tx, deps, carpool, [...existing, e], input.from, input.to, nowMs);
    tx.putException(e);
    tx.addEvent(event("schedule-changed", input.carpoolId, uids(members), nowMs, { date: input.from, actorUid: caller.uid }));
    return e;
  });
}

/** The group admin removes an exception; runs on those days return to the usual plan (open, to be taken or planned again). */
export async function deleteException(deps: CarpoolDeps, caller: Caller, data: unknown): Promise<{ deleted: boolean }> {
  const raw = record(data);
  const carpoolId = docId(raw.carpoolId);
  const exceptionId = docId(raw.exceptionId);
  await requireVerified(deps, caller);
  await take(deps, caller.uid, "scheduleChanges", DAY_MS, deps.limits.scheduleChangesPerDay);
  return deps.store.transact(async (tx) => {
    const carpool = await requireActiveCarpool(tx, carpoolId);
    const admin = await requireApproved(tx, carpoolId, caller.uid);
    if (admin.role !== "admin") throw new CarpoolError("not-admin");
    const existing = await tx.exceptions(carpoolId);
    const members = await tx.members(carpoolId);
    const gone = existing.find((e) => e.id === exceptionId);
    if (!gone) throw new CarpoolError("not-found");
    const nowMs = deps.now();
    await reconcile(tx, deps, carpool, existing.filter((e) => e.id !== exceptionId), gone.from, gone.to, nowMs);
    tx.deleteException(carpoolId, exceptionId);
    tx.addEvent(event("schedule-changed", carpoolId, uids(members), nowMs, { date: gone.from, actorUid: caller.uid }));
    return { deleted: true };
  });
}

// --------------------------------------------------------------------------
// Scheduled tick: cut-offs (F28, backups) and the drive balance (F37)
// --------------------------------------------------------------------------

/**
 * Runs every few minutes (Cairo time zone):
 * - A planned or open run past its confirm-by time becomes "missed". Its
 *   proposed driver is removed (never assigned without confirming), any
 *   open swap expires, and every member gets a critical "no driver: take
 *   your own child" alert.
 * - A confirmed run whose start time has passed becomes "completed" and is
 *   counted in the term's drive balance (driven for the driver, received
 *   for every other family with children on it).
 * Each run changes in its own transaction, which checks the status again,
 * so a retry or an overlapping tick never counts twice.
 */
export async function runScheduleTick(deps: CarpoolDeps, limit = 200): Promise<{ missed: number; completed: number }> {
  const nowMs = deps.now();
  let missed = 0;
  let completed = 0;
  for (const ref of await deps.store.dueRuns(nowMs, limit)) {
    const done = await deps.store.transact(async (tx) => {
      const run = await tx.run(ref.carpoolId, ref.runId);
      if (!run || (run.status !== "planned" && run.status !== "open") || run.confirmByMs > nowMs) return false;
      const swap = run.swapId ? await tx.swap(ref.carpoolId, run.swapId) : null;
      const members = await tx.members(ref.carpoolId);
      const next: RunRecord = { ...run, status: "missed", driverUid: null, driverFirstName: "", swapId: null, updatedAtMs: nowMs };
      tx.putRun(next);
      if (swap && swap.status === "open") tx.putSwap({ ...swap, status: "expired", updatedAtMs: nowMs });
      tx.addEvent(runEvent("no-driver", next, uids(members), nowMs, { critical: true }));
      return true;
    });
    if (done) missed++;
  }
  for (const ref of await deps.store.finishedRuns(nowMs, limit)) {
    const done = await deps.store.transact(async (tx) => {
      const run = await tx.run(ref.carpoolId, ref.runId);
      if (!run || run.status !== "confirmed" || run.startMs > nowMs) return false;
      const balance = await tx.balance(ref.carpoolId, run.termId);
      const members = await tx.members(ref.carpoolId);
      const names = new Map(members.map((m) => [m.uid, m.firstName]));
      tx.putRun({ ...run, status: "completed", updatedAtMs: nowMs });
      tx.putBalance(addToBalance(balance ?? { carpoolId: ref.carpoolId, termId: run.termId, families: {}, updatedAtMs: nowMs }, run, names, nowMs));
      return true;
    });
    if (done) completed++;
  }
  return { missed, completed };
}
