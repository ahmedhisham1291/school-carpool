import type { CarpoolTx } from "../carpools/flow";
import type { MemberRecord } from "../carpools/model";
import { addDays } from "./cairo";
import { confirmDeadline, isLive, PLAN_WEEKS_AHEAD, type DeadlineSettings, type RunRecord, type ScheduleEvent, type ScheduleEventType } from "./model";

/**
 * Schedule changes caused by carpool changes (Prompt 6 flows call these
 * inside their own transactions): a member leaving, or a parent
 * withdrawing consent from a driver (F26). Kept apart from flow.ts so the
 * carpool flows can use them without an import cycle.
 */

export const uids = (members: MemberRecord[]): string[] => members.map((m) => m.uid);

export function event(
  type: ScheduleEventType,
  carpoolId: string,
  recipients: string[],
  nowMs: number,
  extra: Partial<Pick<ScheduleEvent, "runId" | "date" | "direction" | "actorUid" | "childId" | "critical">> = {},
): ScheduleEvent {
  return {
    type,
    carpoolId,
    runId: extra.runId ?? null,
    date: extra.date ?? null,
    direction: extra.direction ?? null,
    recipients: [...new Set(recipients)].sort(),
    actorUid: extra.actorUid ?? null,
    childId: extra.childId ?? null,
    critical: extra.critical ?? false,
    createdAtMs: nowMs,
  };
}

export function runEvent(type: ScheduleEventType, run: RunRecord, recipients: string[], nowMs: number, extra: Partial<ScheduleEvent> = {}): ScheduleEvent {
  return event(type, run.carpoolId, recipients, nowMs, { runId: run.id, date: run.date, direction: run.direction, ...extra });
}

/**
 * Leaves a run without a driver. A new confirm-by time gives the group a
 * chance to take it (the evening before, or [lateLeadMin] before the run);
 * when even that has passed the run is missed at once and every parent is
 * told to take their own child (spec section 6, backups). Returns the
 * changed run and the alert.
 */
export function releaseRun(run: RunRecord, recipients: string[], nowMs: number, settings: DeadlineSettings, swapId: string | null): { run: RunRecord; event: ScheduleEvent } {
  const deadline = confirmDeadline(run.date, run.time, nowMs, settings);
  if (deadline === null) {
    const missed: RunRecord = { ...run, status: "missed", driverUid: null, driverFirstName: "", swapId: null, updatedAtMs: nowMs };
    return { run: missed, event: runEvent("no-driver", missed, recipients, nowMs, { critical: true }) };
  }
  const open: RunRecord = { ...run, status: "open", driverUid: null, driverFirstName: "", swapId, confirmByMs: deadline, confirmedAtMs: null, updatedAtMs: nowMs };
  return { run: open, event: runEvent(swapId ? "swap-requested" : "driver-unavailable", open, recipients, nowMs) };
}

/** Every live run from [today] to the last week that can be planned. */
async function liveRuns(tx: CarpoolTx, carpoolId: string, today: string, nowMs: number): Promise<RunRecord[]> {
  const runs = await tx.runs(carpoolId, today, addDays(today, (PLAN_WEEKS_AHEAD + 1) * 7 + 6));
  return runs.filter((r) => isLive(r, nowMs));
}

/**
 * A member left: their children leave every future pickup list, and every
 * future run they were driving loses its driver (open for the group to
 * take, or missed with an alert when it is too late). [members] are the
 * members who stay.
 */
export async function releaseAfterLeave(
  tx: CarpoolTx,
  carpoolId: string,
  leaverUid: string,
  members: MemberRecord[],
  today: string,
  nowMs: number,
  settings: DeadlineSettings,
): Promise<void> {
  const stay = uids(members).filter((u) => u !== leaverUid);
  for (const run of await liveRuns(tx, carpoolId, today, nowMs)) {
    let next: RunRecord = {
      ...run,
      riders: run.riders.filter((r) => r.parentUid !== leaverUid),
      absent: run.absent.filter((r) => r.parentUid !== leaverUid),
    };
    const changed = next.riders.length !== run.riders.length || next.absent.length !== run.absent.length;
    if (run.driverUid === leaverUid) {
      const released = releaseRun(next, stay, nowMs, settings, null);
      next = released.run;
      tx.addEvent({ ...released.event, actorUid: leaverUid });
    } else if (!changed) {
      continue;
    }
    tx.putRun({ ...next, updatedAtMs: nowMs });
  }
}

/**
 * [parentUid] withdrew consent from [driverUid]: every future run that
 * driver would drive with that parent's children on the pickup list loses
 * its driver at once, and the group is alerted. Runs where those children
 * are marked absent keep the driver (bringing a child back checks consent).
 */
export async function releaseAfterWithdraw(
  tx: CarpoolTx,
  carpoolId: string,
  parentUid: string,
  driverUid: string,
  members: MemberRecord[],
  today: string,
  nowMs: number,
  settings: DeadlineSettings,
): Promise<void> {
  for (const run of await liveRuns(tx, carpoolId, today, nowMs)) {
    if (run.driverUid !== driverUid || !run.riders.some((r) => r.parentUid === parentUid)) continue;
    const released = releaseRun(run, uids(members), nowMs, settings, null);
    tx.putRun(released.run);
    tx.addEvent({ ...released.event, actorUid: parentUid });
  }
}

/**
 * Urgent report (Prompt 9, spec section 6): [driverUid]'s driving days pause
 * at once. Every future run they drive in this carpool loses its driver and
 * becomes open for the group to take (or missed with the "take your own
 * child" alert when it is too late). The group is told only that the
 * driver is unavailable: the event never says why. Returns the runs freed.
 */
export async function releaseAfterPause(
  tx: CarpoolTx,
  carpoolId: string,
  driverUid: string,
  members: MemberRecord[],
  today: string,
  nowMs: number,
  settings: DeadlineSettings,
): Promise<number> {
  let freed = 0;
  for (const run of await liveRuns(tx, carpoolId, today, nowMs)) {
    if (run.driverUid !== driverUid) continue;
    const released = releaseRun(run, uids(members), nowMs, settings, null);
    tx.putRun(released.run);
    tx.addEvent({ ...released.event, actorUid: driverUid });
    freed += 1;
  }
  return freed;
}

/**
 * Prompt 11 (F17, spec sections 3 and 6): [driverUid] can no longer drive
 * some of their runs in this carpool: the car expired, was replaced and
 * waits for review, or has fewer seats than the run's children. Every
 * future run they drive for which [invalid] is true loses its driver and
 * becomes open for the group to take (or missed with the "take your own
 * child" alert when it is too late). The group is told only that the
 * driver is unavailable. Returns the runs freed.
 */
export async function releaseRunsWhere(
  tx: CarpoolTx,
  carpoolId: string,
  driverUid: string,
  members: MemberRecord[],
  today: string,
  nowMs: number,
  settings: DeadlineSettings,
  invalid: (run: RunRecord) => boolean,
): Promise<number> {
  let freed = 0;
  for (const run of await liveRuns(tx, carpoolId, today, nowMs)) {
    if (run.driverUid !== driverUid || !invalid(run)) continue;
    const released = releaseRun(run, uids(members), nowMs, settings, null);
    tx.putRun(released.run);
    tx.addEvent({ ...released.event, actorUid: driverUid });
    freed += 1;
  }
  return freed;
}

/**
 * Prompt 11 (F17): [childId] left this carpool (left the school, or a
 * guardian link ended): the child leaves every future pickup list. Driving
 * stays as it is. Returns the runs changed.
 */
export async function removeChildFromRuns(tx: CarpoolTx, carpoolId: string, childId: string, today: string, nowMs: number): Promise<number> {
  let changed = 0;
  for (const run of await liveRuns(tx, carpoolId, today, nowMs)) {
    const riders = run.riders.filter((r) => r.id !== childId);
    const absent = run.absent.filter((r) => r.id !== childId);
    if (riders.length === run.riders.length && absent.length === run.absent.length) continue;
    tx.putRun({ ...run, riders, absent, updatedAtMs: nowMs });
    changed += 1;
  }
  return changed;
}
