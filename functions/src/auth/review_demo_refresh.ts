import type { CarpoolDeps } from "../carpools/flow";
import { cairoDate } from "../carpools/model";
import { addDays, weekStartOf } from "../schedule/cairo";
import { confirmRun, planWeek } from "../schedule/flow";
import { reviewWindowOpen, type ReviewAccess } from "./otp_flow";
import { REVIEW_DEMO_MAX_UIDS, reviewDemoState } from "./review_access";
import { DEMO_IDS } from "./review_demo";

/**
 * App Review (guideline 2.1, docs/apple-review/submission-kit.md): keeps
 * the demo carpool's runs fresh while the review window is open, so the
 * reviewer finds a run to start on any school day without the owner
 * running `review-demo -- seed` again each evening.
 *
 * Bounded on purpose:
 * - does nothing unless config/reviewAccess is on and not expired, lists
 *   the demo parents, and every listed account is a demo account inside
 *   its window (reviewDemoState "open");
 * - touches ONE carpool, DEMO_IDS.carpool, and only while it is still at
 *   the demo school (never a real carpool or school);
 * - plans this week and the next with the demo driver (the carpool's
 *   admin, as the seed made it), then confirms the driver's runs of the
 *   next 14 days: at most 2 plans and DEMO_CONFIRM_MAX confirmations;
 * - goes through the same flows as the app (planWeek, confirmRun), so
 *   every rule of the schedule still applies.
 */
export const DEMO_CONFIRM_MAX = 20;
const DEMO_DAYS_AHEAD = 13;

export interface DemoRefreshDeps {
  carpools: CarpoolDeps;
  readReview(): Promise<ReviewAccess | null>;
  readUser(uid: string): Promise<Record<string, unknown> | undefined>;
}

export interface DemoRefreshResult {
  /** "off": no open review window; "not-ready": no demo carpool or accounts; "done": refreshed. */
  status: "off" | "not-ready" | "done";
  planned: number;
  confirmed: number;
}

export async function refreshReviewDemoRuns(deps: DemoRefreshDeps): Promise<DemoRefreshResult> {
  const none = (status: DemoRefreshResult["status"]): DemoRefreshResult => ({ status, planned: 0, confirmed: 0 });
  const nowMs = deps.carpools.now();
  const review = await deps.readReview();
  if (!reviewWindowOpen(review, nowMs)) return none("off");
  const uids = (review.demoUids ?? []).slice(0, REVIEW_DEMO_MAX_UIDS);
  const driverUid = uids[0];
  if (!driverUid) return none("not-ready");
  for (const uid of uids) {
    if (reviewDemoState(await deps.readUser(uid), uid, review, nowMs) !== "open") return none("not-ready");
  }
  const carpool = await deps.carpools.store.transact((tx) => tx.carpool(DEMO_IDS.carpool));
  if (!carpool || carpool.status !== "active" || carpool.schoolId !== DEMO_IDS.school) return none("not-ready");

  const today = cairoDate(nowMs);
  const as = { uid: driverUid, verifiedClaim: true };
  let planned = 0;
  const week = weekStartOf(today);
  for (const weekStart of [week, addDays(week, 7)]) {
    try {
      await planWeek(deps.carpools, as, { carpoolId: DEMO_IDS.carpool, weekStart });
      planned++;
    } catch {
      // Not plannable (for example the week is over) or a rate limit: the next day tries again.
    }
  }
  const runs = await deps.carpools.store.transact((tx) => tx.runs(DEMO_IDS.carpool, today, addDays(today, DEMO_DAYS_AHEAD)));
  let confirmed = 0;
  for (const run of runs.filter((r) => r.driverUid === driverUid && r.status === "planned").slice(0, DEMO_CONFIRM_MAX)) {
    try {
      await confirmRun(deps.carpools, as, { carpoolId: DEMO_IDS.carpool, runId: run.id });
      confirmed++;
    } catch {
      // Past its confirm-by time.
    }
  }
  return { status: "done", planned, confirmed };
}
