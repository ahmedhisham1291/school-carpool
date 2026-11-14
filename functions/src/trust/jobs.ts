import type { CarpoolDeps } from "../carpools/flow";
import { cairoDate } from "../carpools/model";
import { newEvent, type OutboxEvent } from "../notifications/model";
import { pauseDriverRuns } from "../schedule/pause";
import { addDays, daysBetween } from "../schedule/cairo";
import type { UsableVehicle } from "../verification/vehicle";
import { recheckDriver } from "./carpools";
import { licenceNotice, yearReminderStage, yearState, yearWindow, type YearSettings } from "./model";

/**
 * Prompt 11 (F17) background work:
 * - the daily check (trustDaily, Cairo morning): driving papers reminders
 *   30, 7 and 1 days before the earlier expiry, "papers expired" with the
 *   runs after it released; the yearly check's reminders and, after the
 *   deadline, "no new driving days" for parents who did not confirm;
 * - a suspended or banned driver: their runs become open for the group
 *   (Prompt 9's pause release; the group hears only "driver unavailable");
 * - a car that changed (new car waiting for review, fewer seats, other
 *   dates): runs it can no longer carry are released.
 * Events have fixed IDs, so a retried job never sends twice.
 */

export interface VehicleRow {
  uid: string;
  vehicle: UsableVehicle;
}

export interface UserRow {
  uid: string;
  verifiedOn: string | null;
  yearConfirmed: number | null;
  yearCheckOverdue: boolean;
}

export interface JobStore {
  /** vehicles/{uid} ordered by uid, after [afterUid]; [last] is null on the last page. */
  vehicles(afterUid: string | null, limit: number): Promise<{ rows: VehicleRow[]; last: string | null }>;
  /** Verified, not banned users ordered by uid, after [afterUid]; [last] is null on the last page. */
  verifiedUsers(afterUid: string | null, limit: number): Promise<{ rows: UserRow[]; last: string | null }>;
  approvedChildCount(uid: string): Promise<number>;
  /** false when an event with this ID exists (sent before). */
  createEvent(e: OutboxEvent): Promise<boolean>;
  setYearCheckOverdue(uid: string, overdue: boolean): Promise<void>;
}

export interface JobDeps {
  store: JobStore;
  carpools: CarpoolDeps;
  now: () => number;
  reminderDays: number[];
  year: YearSettings;
  log: (message: string, data?: Record<string, unknown>) => void;
}

const PAGE = 300;
const MAX_PAGES = 20;

export interface DailyResult {
  vehicles: number;
  expiring: number;
  expired: number;
  runsFreed: number;
  yearReminders: number;
  overdue: number;
}

export async function runTrustDaily(deps: JobDeps): Promise<DailyResult> {
  const result: DailyResult = { vehicles: 0, expiring: 0, expired: 0, runsFreed: 0, yearReminders: 0, overdue: 0 };
  await papersCheck(deps, result);
  await yearCheck(deps, result);
  return result;
}

async function papersCheck(deps: JobDeps, result: DailyResult): Promise<void> {
  const today = cairoDate(deps.now());
  let after: string | null = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const { rows, last }: { rows: VehicleRow[]; last: string | null } = await deps.store.vehicles(after, PAGE);
    for (const row of rows) {
      result.vehicles += 1;
      const v = row.vehicle;
      if (v.status !== "approved") continue;
      const dates = [v.licenseExpiry, v.carLicenseExpiry].filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d)).sort();
      if (dates.length === 0) continue;
      const validUntil = dates[0];
      const notice = licenceNotice(validUntil, today, deps.reminderDays);
      const nowMs = deps.now();
      if (notice?.kind === "expiring") {
        const sent = await deps.store.createEvent(
          newEvent(`licence-expiring_${row.uid}_${validUntil}_${notice.days}`, "licence-expiring", [row.uid], nowMs, { date: validUntil }),
        );
        if (sent) result.expiring += 1;
      } else if (notice?.kind === "expired") {
        const sent = await deps.store.createEvent(newEvent(`licence-expired_${row.uid}_${validUntil}`, "licence-expired", [row.uid], nowMs));
        if (sent) result.expired += 1;
        // Runs after the expiry lose this driver (a few days, so a failed run is retried).
        if (daysBetween(validUntil, today) <= 3) result.runsFreed += await recheckDriver(deps.carpools, row.uid);
      }
    }
    if (last === null) return;
    after = last;
  }
  deps.log("trust daily: vehicle pages full", { pages: MAX_PAGES });
}

async function yearCheck(deps: JobDeps, result: DailyResult): Promise<void> {
  const today = cairoDate(deps.now());
  const w = yearWindow(today, deps.year);
  if (!w || today > addDays(w.deadline, 7)) return;
  const stage = yearReminderStage(w, today);
  let after: string | null = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const { rows, last }: { rows: UserRow[]; last: string | null } = await deps.store.verifiedUsers(after, PAGE);
    for (const u of rows) {
      if (u.yearConfirmed !== null && u.yearConfirmed >= w.year) continue;
      if (u.verifiedOn !== null && u.verifiedOn >= w.opensOn) continue;
      const children = await deps.store.approvedChildCount(u.uid);
      const state = yearState(w, today, { confirmedYear: u.yearConfirmed, verifiedOn: u.verifiedOn, hasChildren: children > 0 });
      if (state === "due" && stage) {
        if (await deps.store.createEvent(newEvent(`year-check_${u.uid}_${w.year}_${stage}`, "year-check-due", [u.uid], deps.now()))) result.yearReminders += 1;
      } else if (state === "overdue" && !u.yearCheckOverdue) {
        await deps.store.setYearCheckOverdue(u.uid, true);
        result.overdue += 1;
      }
    }
    if (last === null) return;
    after = last;
  }
  deps.log("trust daily: user pages full", { pages: MAX_PAGES });
}

/** A users/{uid} document reads as blocked (suspended, banned or gone). */
export function blockedAccount(d: Record<string, unknown> | undefined): boolean {
  return !d || d.banned === true || d.status === "suspended";
}

/**
 * Suspended or banned (spec section 6): every run the driver drives from
 * today becomes open for the group to take, with "driver unavailable" only.
 * Only on the change into blocked, so a retried trigger frees nothing twice.
 */
export async function releaseOnBlock(deps: CarpoolDeps, uid: string, before: Record<string, unknown> | undefined, after: Record<string, unknown> | undefined): Promise<number> {
  if (after === undefined || !blockedAccount(after) || (before !== undefined && blockedAccount(before))) return 0;
  return (await pauseDriverRuns(deps, uid)).runs;
}
