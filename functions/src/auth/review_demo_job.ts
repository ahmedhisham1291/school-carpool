import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { adminDb } from "../admin";
import { deps as carpoolDeps } from "../carpools/callables";
import { MIN_INSTANCES } from "../config";
import { CAIRO_TZ } from "../schedule/cairo";
import { reportError } from "../sentry";
import { readReviewAccess } from "./review_access";
import { refreshReviewDemoRuns } from "./review_demo_refresh";

/**
 * App Review: every evening (Cairo time) while the review window is open,
 * plans the demo carpool's week and the next and confirms the demo
 * driver's runs (refreshReviewDemoRuns: demo carpool only, bounded). Reads
 * one document and stops when review access is off, which is the normal
 * case: the cost is one Cloud Scheduler job (USD 0.10 a month after the
 * free 3; docs/COSTS.md). 18:30 is before the 21:00 confirm-by time of the
 * next day's runs (DEFAULT_DEADLINES, a server setting).
 */
export const reviewDemoDaily = onSchedule(
  { schedule: "30 18 * * *", timeZone: CAIRO_TZ, retryCount: 1, timeoutSeconds: 120, minInstances: MIN_INSTANCES },
  async () => {
    try {
      const db = adminDb();
      const result = await refreshReviewDemoRuns({
        carpools: carpoolDeps(),
        readReview: () => readReviewAccess(db),
        readUser: async (uid) => (await db.collection("users").doc(uid).get()).data(),
      });
      // Counts only: no account ID, number or name.
      logger.info("review demo refresh", result);
    } catch (error) {
      logger.error("review demo refresh failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);
