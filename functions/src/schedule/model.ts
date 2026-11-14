import {
  checkArrangement,
  type ArrangementProblem,
  type ConsentRecord,
  type Day,
  type MemberRecord,
} from "../carpools/model";
import { addDays, cairoToUtcMs, daysBetween, isDate, termOf, weekdayOf } from "./cairo";

/**
 * Schedule (Prompt 7: F7, F11, F27, F28, F30, F37): records and the pure
 * rules (rotation, exceptions, deadlines, swaps, balance). No Firestore
 * here; flow.ts runs them inside one CarpoolStore transaction.
 *
 * Records (only Cloud Functions write them; approved members read them):
 * - carpools/{id}/schedule/{date}_{am|pm}: one run per carpool, Cairo date
 *   and direction, with at most one driver.
 * - carpools/{id}/swaps/{swapId}: swap requests for one run (F11).
 * - carpools/{id}/exceptions/{id}: no-school days and one-off or ranged
 *   time changes such as Ramadan times (F30), set by the group admin.
 * - carpools/{id}/balances/{termId}: runs driven and received per family
 *   this term (F37).
 * - notificationEvents/{id}: alert events for the notification sender
 *   (Prompt 8; functions only). Also used by the join-request flows.
 *
 * The backups rule (spec section 6) holds everywhere: a run gets a driver
 * only when that driver confirms (confirmRun, or taking the run, which is
 * a confirmation). With no confirmed driver by the cut-off the run is
 * "missed" and every parent is told to take their own child; nobody is
 * ever assigned without confirming.
 */

export type Direction = "toSchool" | "toHome";
export const DIRECTIONS: readonly Direction[] = ["toSchool", "toHome"];

/**
 * planned: proposed by the rotation, waiting for the driver to confirm.
 * confirmed: the driver confirmed (or took the run).
 * open: no driver (nobody could be proposed, the driver asked for a swap,
 *   consent was withdrawn, or the driver left); any eligible member can take it.
 * missed: the cut-off passed with no confirmed driver; parents were alerted.
 * cancelled: no school that day (F30).
 * completed: the run time passed with a confirmed driver (counted in F37).
 */
export type RunStatus = "planned" | "confirmed" | "open" | "missed" | "cancelled" | "completed";
export const RUN_STATUSES: readonly RunStatus[] = ["planned", "confirmed", "open", "missed", "cancelled", "completed"];

export interface Rider {
  id: string;
  firstName: string;
  parentUid: string;
}

export interface RunRecord {
  /** "{date}_am" or "{date}_pm". */
  id: string;
  carpoolId: string;
  date: string;
  direction: Direction;
  /** Cairo wall-clock time of the run (after exceptions). */
  time: string;
  startMs: number;
  /** Confirm by this instant (F28). */
  confirmByMs: number;
  status: RunStatus;
  driverUid: string | null;
  driverFirstName: string;
  /** True when the run was proposed on a day the driver did not choose. */
  fallback: boolean;
  /** True after a swap or a take (another driver than the rotation's). */
  swapped: boolean;
  /** The open swap request of this run, if any, and who asked for it. */
  swapId: string | null;
  swapBy: string | null;
  /** The pickup list (F27: absent children move to [absent]). */
  riders: Rider[];
  absent: Rider[];
  weekStart: string;
  termId: string;
  confirmedAtMs: number | null;
  createdAtMs: number;
  updatedAtMs: number;
}

export type SwapStatus = "open" | "accepted" | "cancelled" | "expired";

export interface SwapRecord {
  id: string;
  carpoolId: string;
  runId: string;
  date: string;
  direction: Direction;
  requesterUid: string;
  requesterFirstName: string;
  /** The run's status before the request (restored when the requester cancels). */
  previousStatus: "planned" | "confirmed";
  status: SwapStatus;
  acceptedBy: string | null;
  /** Eligible members, the family that has driven least first (F37). */
  suggestedUids: string[];
  createdAtMs: number;
  updatedAtMs: number;
}

export type ExceptionKind = "noSchool" | "times";
export const EXCEPTION_REASONS = ["holiday", "exams", "early", "ramadan", "other"] as const;
export type ExceptionReason = (typeof EXCEPTION_REASONS)[number];

export interface ExceptionRecord {
  id: string;
  carpoolId: string;
  kind: ExceptionKind;
  reason: ExceptionReason;
  /** Inclusive Cairo dates; one day when equal. */
  from: string;
  to: string;
  /** "times" only: new times; null keeps that run's usual time. */
  morning: string | null;
  afternoon: string | null;
  createdBy: string;
  createdAtMs: number;
}

export interface FamilyBalance {
  firstName: string;
  driven: number;
  received: number;
  /**
   * The family's fair share of the runs counted so far, built up run by run
   * (F37): each completed run adds children / children of the eligible
   * families to every family that was eligible for it (a member then, with
   * a child on the run, able to drive it). A family that joins mid-term
   * starts at 0; a family that cannot drive takes no share.
   */
  share: number;
}

export interface BalanceRecord {
  carpoolId: string;
  termId: string;
  families: Record<string, FamilyBalance>;
  updatedAtMs: number;
}

export type ScheduleEventType =
  | "plan-ready"
  | "no-driver"
  | "swap-requested"
  | "swap-accepted"
  | "swap-cancelled"
  | "run-taken"
  | "child-absent"
  | "child-back"
  | "driver-unavailable"
  | "schedule-changed"
  | "time-changed"
  // Prompt 8: join requests and decisions (carpools/flow.ts).
  | "join-requested"
  | "join-approved"
  | "join-declined";

/**
 * An alert for the notification sender (Prompt 8). Holds IDs only: no names, children's
 * names, addresses or message text (the app loads details after it opens).
 */
export interface ScheduleEvent {
  type: ScheduleEventType;
  carpoolId: string;
  runId: string | null;
  date: string | null;
  direction: Direction | null;
  /** Who should be told. */
  recipients: string[];
  actorUid: string | null;
  childId: string | null;
  /** Critical alerts also sound the in-app alarm (spec section 11). */
  critical: boolean;
  createdAtMs: number;
}

export const EVENT_TTL_DAYS = 30;
export const MAX_EXCEPTIONS = 60;
export const MAX_EXCEPTION_DAYS = 60;
/** How far ahead the admin may plan (weeks after the current one). */
export const PLAN_WEEKS_AHEAD = 3;
/** Exceptions may start this many days back (to fix today) and up to a year ahead. */
export const EXCEPTION_PAST_DAYS = 1;
export const EXCEPTION_FUTURE_DAYS = 366;

export function runId(date: string, direction: Direction): string {
  return `${date}_${direction === "toSchool" ? "am" : "pm"}`;
}

export function parseRunId(value: unknown): { date: string; direction: Direction } | null {
  if (typeof value !== "string") return null;
  const m = /^(\d{4}-\d{2}-\d{2})_(am|pm)$/.exec(value);
  if (!m || !isDate(m[1])) return null;
  return { date: m[1], direction: m[2] === "am" ? "toSchool" : "toHome" };
}

// --------------------------------------------------------------------------
// Deadlines (F28)
// --------------------------------------------------------------------------

export interface DeadlineSettings {
  /** Cairo time on the evening before each school day ("21:00"). */
  confirmBy: string;
  /** When a run is planned after that time: confirm this many minutes before it. */
  lateLeadMin: number;
}

export const DEFAULT_DEADLINES: DeadlineSettings = { confirmBy: "21:00", lateLeadMin: 60 };

/**
 * When the driver of a run on [date] at [time] must confirm: the evening
 * before at [settings.confirmBy], Cairo time (DST-aware). A run planned
 * after that gets [settings.lateLeadMin] minutes before it starts; null
 * when even that has passed (too late to plan the run).
 */
export function confirmDeadline(date: string, time: string, nowMs: number, settings: DeadlineSettings): number | null {
  const evening = cairoToUtcMs(addDays(date, -1), settings.confirmBy);
  if (evening > nowMs) return evening;
  const late = cairoToUtcMs(date, time) - settings.lateLeadMin * 60_000;
  return late > nowMs ? late : null;
}

// --------------------------------------------------------------------------
// Exceptions (F30)
// --------------------------------------------------------------------------

export interface DayPlan {
  noSchool: boolean;
  /** Time of each run that day, or null when the carpool has no such run. */
  toSchool: string | null;
  toHome: string | null;
}

export function exceptionCovers(e: ExceptionRecord, date: string): boolean {
  return e.from <= date && date <= e.to;
}

/**
 * What a carpool's day looks like after exceptions. A no-school exception
 * beats any time change; among time changes the latest one set wins, run
 * by run (a Ramadan range plus a one-off early dismissal inside it).
 */
export function dayPlan(
  carpool: { morning: string | null; afternoon: string | null; days: Day[] },
  exceptions: ExceptionRecord[],
  date: string,
): DayPlan {
  const covering = exceptions.filter((e) => exceptionCovers(e, date)).sort((a, b) => a.createdAtMs - b.createdAtMs || a.id.localeCompare(b.id));
  const schoolDay = carpool.days.includes(weekdayOf(date));
  const noSchool = !schoolDay || covering.some((e) => e.kind === "noSchool");
  let toSchool = carpool.morning;
  let toHome = carpool.afternoon;
  for (const e of covering) {
    if (e.kind !== "times") continue;
    if (e.morning && toSchool) toSchool = e.morning;
    if (e.afternoon && toHome) toHome = e.afternoon;
  }
  return { noSchool, toSchool, toHome };
}

// --------------------------------------------------------------------------
// Riders and eligibility
// --------------------------------------------------------------------------

/** Every child of the approved members, in a stable order. */
export function ridersOf(members: MemberRecord[]): Rider[] {
  return [...members]
    .sort((a, b) => a.uid.localeCompare(b.uid))
    .flatMap((m) => m.children.map((c) => ({ id: c.id, firstName: c.firstName, parentUid: m.uid })));
}

/** Can [driverUid] drive [riders]? Seats, a valid car and consent (Prompt 6's checkArrangement). */
export function runProblem(driverUid: string, riders: Rider[], members: MemberRecord[], consents: ConsentRecord[], today: string): ArrangementProblem | null {
  // A run whose children are all absent still needs nothing but a valid car.
  const ids = riders.map((r) => r.id);
  if (ids.length === 0) {
    const problem = checkArrangement({ driverUid, childIds: members.find((m) => m.uid === driverUid)?.children.map((c) => c.id) ?? [], members, consents, today });
    return problem && problem.reason !== "no-children" ? problem : null;
  }
  return checkArrangement({ driverUid, childIds: ids, members, consents, today });
}

// --------------------------------------------------------------------------
// Drive balance (F37)
// --------------------------------------------------------------------------

/** Weight of a family in the fair share: its children in the carpool (at least 1). */
function weightOf(m: MemberRecord): number {
  return Math.max(1, m.children.length);
}

/**
 * Families eligible for a run, with their weight: approved members with a
 * child on the pickup list who may drive it (car valid on the run's date,
 * enough seats, every parent's consent). The driver of the run is always
 * included (they drove it).
 */
export function eligibleFamilies(
  riders: Rider[],
  members: MemberRecord[],
  consents: ConsentRecord[],
  date: string,
  driverUid: string | null,
): Array<{ uid: string; weight: number }> {
  const riding = new Set(riders.map((r) => r.parentUid));
  return members
    .filter((m) => m.uid === driverUid || (riding.has(m.uid) && runProblem(m.uid, riders, members, consents, date) === null))
    .map((m) => ({ uid: m.uid, weight: weightOf(m) }));
}

/** Adds one run's fair share to [share] (uid -> share so far). */
export function accrueShare(share: Map<string, number>, families: Array<{ uid: string; weight: number }>): void {
  const total = families.reduce((n, f) => n + f.weight, 0);
  if (total === 0) return;
  for (const f of families) share.set(f.uid, (share.get(f.uid) ?? 0) + f.weight / total);
}

/**
 * Members ordered for an offer: the family furthest behind its fair share
 * (largest share - driven) first, then the uid (stable).
 */
export function leastDrivenFirst(members: MemberRecord[], balance: BalanceRecord | null): string[] {
  const deficit = (uid: string) => (balance?.families[uid]?.share ?? 0) - (balance?.families[uid]?.driven ?? 0);
  return members
    .map((m) => m.uid)
    .sort((a, b) => deficit(b) - deficit(a) || a.localeCompare(b));
}

/**
 * Adds one completed run to the balance: the driver drove; every other
 * family with riders received; every family eligible for the run
 * ([eligible], see [eligibleFamilies]) gains its fair share of it.
 */
export function addToBalance(
  balance: BalanceRecord,
  run: RunRecord,
  names: Map<string, string>,
  eligible: Array<{ uid: string; weight: number }>,
  nowMs: number,
): BalanceRecord {
  if (!run.driverUid) return balance;
  const families: Record<string, FamilyBalance> = {};
  for (const [uid, f] of Object.entries(balance.families)) families[uid] = { ...f, share: f.share ?? 0 };
  const entry = (uid: string): FamilyBalance => {
    families[uid] ??= { firstName: names.get(uid) ?? "", driven: 0, received: 0, share: 0 };
    if (!families[uid].firstName && names.get(uid)) families[uid].firstName = names.get(uid) as string;
    return families[uid];
  };
  entry(run.driverUid).driven += 1;
  for (const parent of new Set(run.riders.map((r) => r.parentUid))) {
    if (parent !== run.driverUid) entry(parent).received += 1;
  }
  const shares = new Map<string, number>();
  accrueShare(shares, eligible);
  for (const [uid, add] of shares) entry(uid).share += add;
  return { ...balance, families, updatedAtMs: nowMs };
}

// --------------------------------------------------------------------------
// Rotation (F7)
// --------------------------------------------------------------------------

export interface RotationInput {
  carpool: { id: string; morning: string | null; afternoon: string | null; days: Day[] };
  weekStart: string;
  members: MemberRecord[];
  consents: ConsentRecord[];
  exceptions: ExceptionRecord[];
  /** Runs already saved for this week (kept when confirmed, done or missed). */
  existing: RunRecord[];
  /**
   * Planned and confirmed runs of the other plannable weeks: they count
   * for fairness (driven and share) before they complete, so planning
   * several weeks ahead stays even.
   */
  otherRuns?: RunRecord[];
  balance: BalanceRecord | null;
  nowMs: number;
  today: string;
  deadlines: DeadlineSettings;
}

export interface RotationResult {
  /** Runs to save (new or changed). */
  runs: RunRecord[];
  /** Runs that stayed open: nobody can drive them (no car, seats or consent). */
  open: string[];
}

const KEEP: readonly RunStatus[] = ["confirmed", "missed", "completed"];

/**
 * Proposes a fair plan for one week: one driver per morning and afternoon
 * run, never confirmed by the plan itself. For each run, in time order:
 *
 * 1. Candidates are members who may drive that run's children today
 *    (valid car, enough passenger seats, every parent's consent: F26).
 * 2. Members who chose that weekday as a driving day come first; when
 *    nobody chose it, every eligible member is a candidate (Flow B: "the
 *    app proposes the remaining days"), and the run is marked [fallback].
 * 3. Among candidates the family with the largest deficit wins: its fair
 *    share minus the runs it drove. Shares are built run by run (term
 *    balance, runs planned or confirmed in other weeks, then each run of
 *    this week): a run adds children / children of the eligible families
 *    to each family eligible for it (with a child on the run and able to
 *    drive it). So a family that joins mid-term owes nothing for the past,
 *    a family that cannot drive takes no share, and a family with two
 *    children drives about twice as often as one with one. Ties: fewer
 *    runs that day, then the uid.
 *
 * Confirmed, missed and completed runs are kept. A planned run keeps its
 * driver while that driver may still drive it. Runs on no-school days are
 * cancelled; times follow exceptions (Ramadan). Runs whose time has passed,
 * or whose late deadline has passed, are not created. Nobody eligible:
 * the run stays open, with no driver.
 */
export function proposeWeek(input: RotationInput): RotationResult {
  const { carpool, members, consents, exceptions, nowMs, today, deadlines } = input;
  const existing = new Map(input.existing.map((r) => [r.id, r]));
  const riders = ridersOf(members);
  const driven = new Map(members.map((m) => [m.uid, input.balance?.families[m.uid]?.driven ?? 0]));
  const share = new Map(members.map((m) => [m.uid, input.balance?.families[m.uid]?.share ?? 0]));
  const perDay = new Map<string, number>();
  const bump = (uid: string, date: string) => {
    driven.set(uid, (driven.get(uid) ?? 0) + 1);
    perDay.set(`${uid}|${date}`, (perDay.get(`${uid}|${date}`) ?? 0) + 1);
  };
  // Runs not in the term balance yet (only completed runs are): this
  // week's confirmed runs and the other weeks' planned and confirmed runs.
  const counted = [
    ...input.existing.filter((r) => r.status === "confirmed"),
    ...(input.otherRuns ?? []).filter((r) => r.status === "confirmed" || r.status === "planned"),
  ];
  for (const r of counted) {
    if (!r.driverUid || !driven.has(r.driverUid)) continue;
    accrueShare(share, eligibleFamilies(r.riders, members, consents, r.date, r.driverUid));
    bump(r.driverUid, r.date);
  }
  const out: RunRecord[] = [];
  const open: string[] = [];
  const term = (date: string) => termOf(date).id;

  for (let i = 0; i < 7; i++) {
    const date = addDays(input.weekStart, i);
    if (date < today) continue;
    const plan = dayPlan(carpool, exceptions, date);
    for (const direction of DIRECTIONS) {
      const usual = direction === "toSchool" ? carpool.morning : carpool.afternoon;
      if (!usual) continue;
      const id = runId(date, direction);
      const old = existing.get(id);
      if (old && KEEP.includes(old.status)) continue;
      const time = (direction === "toSchool" ? plan.toSchool : plan.toHome) ?? usual;
      if (plan.noSchool) {
        // Only days the carpool runs and that already have a run need a "cancelled" record.
        if (old && old.status !== "cancelled") {
          out.push({ ...old, status: "cancelled", driverUid: null, driverFirstName: "", swapId: null, fallback: false, updatedAtMs: nowMs });
        }
        continue;
      }
      const deadline = confirmDeadline(date, time, nowMs, deadlines);
      if (deadline === null) continue;
      const base: RunRecord = old
        ? { ...old, time, startMs: cairoToUtcMs(date, time), confirmByMs: deadline, riders: withoutAbsent(riders, old.absent), updatedAtMs: nowMs }
        : {
            id,
            carpoolId: carpool.id,
            date,
            direction,
            time,
            startMs: cairoToUtcMs(date, time),
            confirmByMs: deadline,
            status: "open",
            driverUid: null,
            driverFirstName: "",
            fallback: false,
            swapped: false,
            swapId: null,
            swapBy: null,
            riders,
            absent: [],
            weekStart: input.weekStart,
            termId: term(date),
            confirmedAtMs: null,
            createdAtMs: nowMs,
            updatedAtMs: nowMs,
          };
      if (base.status === "cancelled") base.status = "open";
      // Car validity is checked on the run's date (a licence that expires
      // before the run does not count).
      const canDrive = (uid: string) => runProblem(uid, base.riders, members, consents, date) === null;

      // A planned driver who may still drive keeps the run.
      if (base.status === "planned" && base.driverUid && canDrive(base.driverUid)) {
        accrueShare(share, eligibleFamilies(base.riders, members, consents, date, base.driverUid));
        bump(base.driverUid, date);
        out.push(base);
        continue;
      }
      // An open swap waits for someone to accept; the plan does not fill it.
      if (base.status === "open" && base.swapId) {
        out.push(base);
        open.push(id);
        continue;
      }
      const eligible = members.filter((m) => canDrive(m.uid));
      const weekday = weekdayOf(date);
      const chose = eligible.filter((m) => m.drivingDays.includes(weekday));
      const pool = chose.length > 0 ? chose : eligible;
      if (pool.length === 0) {
        out.push({ ...base, status: "open", driverUid: null, driverFirstName: "", fallback: false });
        open.push(id);
        continue;
      }
      // This run's fair share goes to the families eligible for it, then
      // the candidate with the largest deficit (share - driven) drives.
      accrueShare(share, eligibleFamilies(base.riders, members, consents, date, null));
      const deficit = (uid: string) => (share.get(uid) ?? 0) - (driven.get(uid) ?? 0);
      const pick = [...pool].sort(
        (a, b) =>
          deficit(b.uid) - deficit(a.uid) ||
          (perDay.get(`${a.uid}|${date}`) ?? 0) - (perDay.get(`${b.uid}|${date}`) ?? 0) ||
          a.uid.localeCompare(b.uid),
      )[0];
      bump(pick.uid, date);
      out.push({ ...base, status: "planned", driverUid: pick.uid, driverFirstName: pick.firstName, fallback: chose.length === 0, swapped: false });
    }
  }
  return { runs: out, open };
}

function withoutAbsent(riders: Rider[], absent: Rider[]): Rider[] {
  const gone = new Set(absent.map((a) => a.id));
  return riders.filter((r) => !gone.has(r.id));
}

/**
 * What a time change (F30: Ramadan, early dismissal) does to one run that
 * is planned, confirmed or open:
 * - The new start has passed: the run is missed (no driver) and every
 *   parent gets the critical "take your own child" alert at once.
 * - Planned or open: the confirm-by time moves with the start, to
 *   min(old confirm-by, new start - lateLeadMin), so it always comes
 *   before the run with a margin; when that has passed, the run is missed
 *   at once with the critical alert (backups rule, spec section 6).
 * - Confirmed: the driver is asked to confirm again (status planned, the
 *   driver kept, a new confirm-by time). When there is no time left to ask
 *   (less than lateLeadMin before the new start), the driver stays
 *   confirmed and gets a critical notice of the new time.
 * [missedRecipients] get the critical alert; the driver gets the notice.
 */
export function retimeRun(
  run: RunRecord,
  time: string,
  nowMs: number,
  settings: DeadlineSettings,
): { run: RunRecord; missed: boolean; notice: "reconfirm" | "moved" | null } {
  const startMs = cairoToUtcMs(run.date, time);
  const moved: RunRecord = { ...run, time, startMs, updatedAtMs: nowMs };
  const missed = (): { run: RunRecord; missed: boolean; notice: null } => ({
    run: { ...moved, status: "missed", driverUid: null, driverFirstName: "", swapId: null, confirmedAtMs: null },
    missed: true,
    notice: null,
  });
  if (startMs <= nowMs) return missed();
  if (run.status === "confirmed") {
    const deadline = confirmDeadline(run.date, time, nowMs, settings);
    if (deadline === null) return { run: moved, missed: false, notice: "moved" };
    return { run: { ...moved, status: "planned", confirmByMs: deadline, confirmedAtMs: null }, missed: false, notice: "reconfirm" };
  }
  const confirmByMs = Math.min(run.confirmByMs, startMs - settings.lateLeadMin * 60_000);
  if (confirmByMs <= nowMs) return missed();
  return { run: { ...moved, confirmByMs }, missed: false, notice: run.driverUid ? "reconfirm" : null };
}

/** Runs still ahead whose driver or riders can change (not done, missed or cancelled). */
export function isLive(run: RunRecord, nowMs: number): boolean {
  return (run.status === "planned" || run.status === "confirmed" || run.status === "open") && run.startMs > nowMs;
}

/** The week starts the admin may plan: this week and [PLAN_WEEKS_AHEAD] after it. */
export function plannableWeek(weekStart: string, thisWeek: string): boolean {
  const d = daysBetween(thisWeek, weekStart);
  return isDate(weekStart) && weekdayOf(weekStart) === "sat" && d >= 0 && d <= PLAN_WEEKS_AHEAD * 7;
}

