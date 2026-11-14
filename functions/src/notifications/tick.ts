import { addDays, cairoToUtcMs } from "../schedule/cairo";
import { cairoDate } from "../carpools/model";
import { cairoMinutes, isTime, newEvent, type OutboxEvent } from "./model";
import type { NotificationType } from "./catalog";

/**
 * The notification tick (Prompt 8), every 5 minutes, Cairo time. Two jobs,
 * both only WRITE outbox events; the dispatcher sends them:
 *
 * 1. Driver reminders (F12):
 *    - "confirm-reminder": a proposed driver who has not confirmed, when
 *      the confirm-by time is less than CONFIRM_LEAD away (missing driver
 *      confirmation, F28);
 *    - "drive-evening": the evening before (from REMINDER_EVENING_AT,
 *      19:00 Cairo), to the confirmed driver of each run tomorrow;
 *    - "drive-hour": one hour before, to the confirmed driver.
 *    Each reminder has a fixed event ID (type, carpool, run, driver), and
 *    events are created with create(): a second tick, an overlapping tick
 *    or a retry never makes a second reminder.
 * 2. Critical alarms (spec section 11): a critical record still unread at
 *    its alarm time gets one "critical-alarm" event (a louder push).
 */

export const CONFIRM_LEAD_MS = 2 * 3_600_000;
export const HOUR_LEAD_MS = 3_600_000;
export const DEFAULT_EVENING_AT = "19:00";

/** A run as the reminder queries return it. */
export interface RunLite {
  carpoolId: string;
  runId: string;
  date: string;
  direction: string;
  driverUid: string | null;
  startMs: number;
  confirmByMs: number;
  status: string;
}

export interface TickStore {
  /** Confirmed runs with a start time in [fromMs, toMs). Index: schedule (status, startAt). */
  confirmedRuns(fromMs: number, toMs: number, limit: number): Promise<RunLite[]>;
  /** Planned runs with a confirm-by time in [fromMs, toMs). Index: schedule (status, confirmBy). */
  plannedRuns(fromMs: number, toMs: number, limit: number): Promise<RunLite[]>;
  /** Creates the event unless its ID exists. False when it existed. */
  createEvent(event: OutboxEvent): Promise<boolean>;
  /** Critical records still waiting with an alarm time at or before [nowMs]. Index: notifications (alarmState, alarmAt). */
  dueAlarms(nowMs: number, limit: number): Promise<Array<{ uid: string; id: string }>>;
  /**
   * In one transaction: a record still unread and waiting becomes
   * "escalated" and the alarm event is created; a read one becomes
   * "cancelled". Returns what happened.
   */
  escalate(uid: string, id: string, alarm: OutboxEvent): Promise<"escalated" | "cancelled" | "gone">;
}

export interface TickDeps {
  store: TickStore;
  now: () => number;
  eveningAt: string;
}

export interface TickResult {
  reminders: number;
  alarms: number;
}

const LIMIT = 500;

/**
 * One reminder per run, driver and run time: the confirm reminder is keyed
 * to the confirm-by time, the drive reminders to the start time. A run that
 * moves (Ramadan times, early dismissal) or is re-asked gets a new reminder
 * for its new time; the same time never gets two.
 */
export function reminderId(type: NotificationType, run: RunLite, driverUid: string): string {
  const at = type === "confirm-reminder" ? run.confirmByMs : run.startMs;
  return `${type}_${run.carpoolId}_${run.runId}_${driverUid}_${at}`;
}

function reminder(type: NotificationType, run: RunLite, nowMs: number): OutboxEvent | null {
  const driver = run.driverUid;
  if (!driver) return null;
  return newEvent(reminderId(type, run, driver), type, [driver], nowMs, {
    carpoolId: run.carpoolId,
    runId: run.runId,
    date: run.date,
    direction: run.direction,
  });
}

/** The reminder events due at [nowMs] (pure). */
export function dueReminders(
  nowMs: number,
  eveningAt: string,
  runs: { tomorrow: RunLite[]; soon: RunLite[]; toConfirm: RunLite[] },
): OutboxEvent[] {
  const out: OutboxEvent[] = [];
  const evening = isTime(eveningAt) ? eveningAt : DEFAULT_EVENING_AT;
  const [h, m] = evening.split(":").map(Number);
  const tomorrow = addDays(cairoDate(nowMs), 1);
  if (cairoMinutes(nowMs) >= h * 60 + m) {
    for (const run of runs.tomorrow) {
      if (run.status !== "confirmed" || run.date !== tomorrow) continue;
      const e = reminder("drive-evening", run, nowMs);
      if (e) out.push(e);
    }
  }
  for (const run of runs.soon) {
    if (run.status !== "confirmed" || run.startMs <= nowMs || run.startMs > nowMs + HOUR_LEAD_MS) continue;
    const e = reminder("drive-hour", run, nowMs);
    if (e) out.push(e);
  }
  for (const run of runs.toConfirm) {
    if (run.status !== "planned" || run.confirmByMs <= nowMs || run.confirmByMs > nowMs + CONFIRM_LEAD_MS) continue;
    const e = reminder("confirm-reminder", run, nowMs);
    if (e) out.push(e);
  }
  return out;
}

export function alarmEventId(uid: string, recordId: string): string {
  return `alarm_${recordId}_${uid}`;
}

export async function runNotificationTick(deps: TickDeps): Promise<TickResult> {
  const { store } = deps;
  const nowMs = deps.now();
  const tomorrow = addDays(cairoDate(nowMs), 1);
  // The evening reminders only from REMINDER_EVENING_AT: no query before.
  const evening = isTime(deps.eveningAt) ? deps.eveningAt : DEFAULT_EVENING_AT;
  const [h, m] = evening.split(":").map(Number);
  const eveningNow = cairoMinutes(nowMs) >= h * 60 + m;
  const [tomorrowRuns, soon, toConfirm] = await Promise.all([
    eveningNow ? store.confirmedRuns(cairoToUtcMs(tomorrow, "00:00"), cairoToUtcMs(addDays(tomorrow, 1), "00:00"), LIMIT) : Promise.resolve([]),
    store.confirmedRuns(nowMs + 1, nowMs + HOUR_LEAD_MS + 1, LIMIT),
    store.plannedRuns(nowMs + 1, nowMs + CONFIRM_LEAD_MS + 1, LIMIT),
  ]);
  let reminders = 0;
  for (const e of dueReminders(nowMs, deps.eveningAt, { tomorrow: tomorrowRuns, soon, toConfirm })) {
    if (await store.createEvent(e)) reminders += 1;
  }
  let alarms = 0;
  for (const due of await store.dueAlarms(nowMs, LIMIT)) {
    const alarm = newEvent(alarmEventId(due.uid, due.id), "critical-alarm", [due.uid], nowMs, { refEventId: due.id });
    if ((await store.escalate(due.uid, due.id, alarm)) === "escalated") alarms += 1;
  }
  return { reminders, alarms };
}
