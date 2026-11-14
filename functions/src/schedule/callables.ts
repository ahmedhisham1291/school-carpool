import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { caller, deps, opts, run } from "../carpools/callables";
import { MIN_INSTANCES } from "../config";
import { reportError } from "../sentry";
import { CAIRO_TZ } from "./cairo";
import {
  cancelSwap as cancelSwapFlow,
  confirmRun as confirmFlow,
  deleteException as deleteExceptionFlow,
  planWeek as planFlow,
  requestSwap as swapFlow,
  runScheduleTick,
  saveException as saveExceptionFlow,
  setChildAbsent as absentFlow,
  setDrivingDays as daysFlow,
  takeRun as takeFlow,
} from "./flow";
import { gatedCall } from "../privacy/device_gate";

/**
 * Schedule callables (Prompt 7: F7, F11, F27, F28, F30, F37). Every
 * schedule write happens here, in a transaction. Logs never contain names,
 * children, times or coordinates: only counts and error messages.
 */

/** F7: { carpoolId, days } -> { days } */
export const setDrivingDays = gatedCall(opts, (r) => run("setDrivingDays", () => daysFlow(deps(), caller(r), r.data)));

/** F7: { carpoolId, weekStart } -> { weekStart, planned, open } (group admin) */
export const planScheduleWeek = gatedCall(opts, (r) => run("planScheduleWeek", () => planFlow(deps(), caller(r), r.data)));

/** F28: { carpoolId, runId } -> the run */
export const confirmRun = gatedCall(opts, (r) => run("confirmRun", () => confirmFlow(deps(), caller(r), r.data)));

/** F11: { carpoolId, runId } -> the swap */
export const requestSwap = gatedCall(opts, (r) => run("requestSwap", () => swapFlow(deps(), caller(r), r.data)));

/** F11: { carpoolId, runId } -> the run */
export const cancelSwap = gatedCall(opts, (r) => run("cancelSwap", () => cancelSwapFlow(deps(), caller(r), r.data)));

/** F11: { carpoolId, runId } -> the run (accept a swap or take an open run) */
export const takeRun = gatedCall(opts, (r) => run("takeRun", () => takeFlow(deps(), caller(r), r.data)));

/** F27: { carpoolId, date, childId, absent, directions? } -> { changed } */
export const setChildAbsent = gatedCall(opts, (r) => run("setChildAbsent", () => absentFlow(deps(), caller(r), r.data)));

/** F30: { carpoolId, kind, reason, from, to?, morning?, afternoon? } -> the exception (group admin) */
export const saveScheduleException = gatedCall(opts, (r) => run("saveScheduleException", () => saveExceptionFlow(deps(), caller(r), r.data)));

/** F30: { carpoolId, exceptionId } -> { deleted } (group admin) */
export const deleteScheduleException = gatedCall(opts, (r) =>
  run("deleteScheduleException", () => deleteExceptionFlow(deps(), caller(r), r.data)),
);

/**
 * F28 and F37: every 15 minutes, Cairo time (DST-aware): runs past their
 * confirm-by time with no confirmed driver become "missed" with a critical
 * alert to every parent; confirmed runs that started count in the drive
 * balance. No warm instances (COST MODE): MIN_INSTANCES, 0 by default.
 */
export const scheduleTick = onSchedule(
  { schedule: "every 15 minutes", timeZone: CAIRO_TZ, retryCount: 1, timeoutSeconds: 300, minInstances: MIN_INSTANCES },
  async () => {
    try {
      const result = await runScheduleTick(deps());
      if (result.backlog) logger.warn("schedule tick: a page was full; more runs wait for the next tick", result);
      else logger.info("schedule tick", result);
    } catch (error) {
      logger.error("schedule tick failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);
