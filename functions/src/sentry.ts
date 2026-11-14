import * as Sentry from "@sentry/node";
import { areaOf, scrubEvent } from "./scrub";

let started = false;

/**
 * Starts Sentry once per instance if SENTRY_DSN is set.
 *
 * COST MODE: Sentry free Developer plan, errors only (no tracing, no
 * profiling). PRIVACY: sendDefaultPii off and every event and breadcrumb
 * goes through scrubEvent.
 */
export function startSentry(): boolean {
  const dsn = process.env.SENTRY_DSN ?? "";
  if (!dsn) return false;
  if (!started) {
    const rate = Number(process.env.SENTRY_SAMPLE_RATE ?? "1");
    Sentry.init({
      dsn,
      environment: process.env.APP_ENV ?? "unknown",
      sampleRate: Number.isFinite(rate) ? Math.min(Math.max(rate, 0), 1) : 1,
      beforeSend: (event) => scrubEvent(event),
      // Prompt 12: alert rules filter on these (function name and area only).
      initialScope: { tags: { function: functionName(), area: areaOf(functionName()) } },
      beforeBreadcrumb: (breadcrumb) => scrubEvent(breadcrumb),
    });
    started = true;
  }
  return true;
}

/** The running function's name (set by Cloud Functions), never request data. */
function functionName(): string {
  return process.env.FUNCTION_TARGET ?? process.env.K_SERVICE ?? "unknown";
}

/** Reports an error and waits for delivery (functions can freeze after return). */
export async function reportError(error: unknown): Promise<void> {
  if (!startSentry()) return;
  Sentry.captureException(error);
  await Sentry.flush(2000);
}
