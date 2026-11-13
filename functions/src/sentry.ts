import * as Sentry from "@sentry/node";
import { scrubEvent } from "./scrub";

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
      sendDefaultPii: false,
      beforeSend: (event) => scrubEvent(event),
      beforeBreadcrumb: (breadcrumb) => scrubEvent(breadcrumb),
    });
    started = true;
  }
  return true;
}

/** Reports an error and waits for delivery (functions can freeze after return). */
export async function reportError(error: unknown): Promise<void> {
  if (!startSentry()) return;
  Sentry.captureException(error);
  await Sentry.flush(2000);
}
