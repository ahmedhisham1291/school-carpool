import * as logger from "firebase-functions/logger";
import { HttpsError, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { reportError } from "../sentry";

/**
 * The shared pieces of every callable handler (docs/architecture/overview.md,
 * "Callable handler pattern"):
 *
 *   gate (onCall options with enforceAppCheck + privacy/device_gate.ts or
 *   features/gate.ts)  ->  requireUid / callerOf  ->  flow(deps, caller, data)
 *   (input parsed by the flow from `unknown`)  ->  store
 *
 * and around the flow, runCallable(): domain errors become HttpsError with
 * `details.reason` (the app maps that reason to its own failure kind),
 * anything else is logged (message only, never the request data) and sent
 * to Sentry, then answered with a generic error.
 */

/** Turns a known domain error into the HttpsError the app sees, or returns undefined. */
export type ErrorMapper = (error: unknown) => HttpsError | undefined;

export interface RunOptions {
  /** Tried in order; the first one that returns an HttpsError wins. */
  readonly map?: readonly ErrorMapper[];
  /** The answer for an unexpected error (after logging and Sentry). Default: internal. */
  readonly fallback?: () => HttpsError;
}

/** The default answer for an unexpected error. */
export function internalError(): HttpsError {
  return new HttpsError("internal", "Something went wrong.");
}

/** An "unavailable" answer with a reason the app shows (for example "wallet-unavailable"). */
export function unavailable(reason: string): () => HttpsError {
  return () => new HttpsError("unavailable", reason, { reason });
}

/**
 * Runs [body]. An HttpsError passes through; a known domain error is mapped
 * by [options.map] without logging (it is an expected answer); anything else
 * is logged by [name] with its message only, reported to Sentry, and
 * answered with [options.fallback] (default: internal).
 */
export async function runCallable<T>(name: string, body: () => Promise<T>, options: RunOptions = {}): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    for (const map of options.map ?? []) {
      const mapped = map(error);
      if (mapped) throw mapped;
    }
    // Never the request data: it may hold a phone number, a name or coordinates.
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw (options.fallback ?? internalError)();
  }
}

/** What a domain error class must carry to be mapped by reasonErrorMapper. */
interface ReasonError extends Error {
  readonly reason: string;
  readonly retryAfterMs?: number;
  readonly details?: Readonly<Record<string, unknown>>;
}

/** Which extra fields go into `details` next to `reason`. */
export type ReasonExtras = "none" | "retryAfter" | "details";

/**
 * A mapper for the common domain error shape `{ reason, retryAfterMs?, details? }`:
 * HttpsError(codes[reason], reason, { reason, ...extras }).
 *
 * - "retryAfter": adds `retryAfterSeconds` (rate limits);
 * - "details": spreads the error's own details after `reason`.
 */
export function reasonErrorMapper<E extends ReasonError>(
  errorClass: abstract new (...args: never[]) => E,
  codes: Readonly<Record<string, string>>,
  extras: ReasonExtras = "none",
): ErrorMapper {
  return (error) => {
    if (!(error instanceof errorClass)) return undefined;
    const code = codes[error.reason] as FunctionsErrorCode;
    if (extras === "retryAfter") {
      return new HttpsError(code, error.reason, {
        reason: error.reason,
        retryAfterSeconds: Math.ceil((error.retryAfterMs ?? 0) / 1000),
      });
    }
    if (extras === "details") return new HttpsError(code, error.reason, { reason: error.reason, ...error.details });
    return new HttpsError(code, error.reason, { reason: error.reason });
  };
}

/**
 * A mapper that hands every error of the listed classes to [toHttpsError]
 * (for modules that already have one converter for all their errors).
 */
export function classesMapper(
  classes: ReadonlyArray<abstract new (...args: never[]) => Error>,
  toHttpsError: (error: unknown) => HttpsError,
): ErrorMapper {
  return (error) => (classes.some((c) => error instanceof c) ? toHttpsError(error) : undefined);
}

/** The signed-in caller's uid, or "unauthenticated". */
export function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return uid;
}

/** The signed-in caller with the "verified" custom claim, as the flows take it. */
export interface CallerIdentity {
  uid: string;
  verifiedClaim: boolean;
}

/** requireUid plus the "verified" custom claim (CLAUDE.md, SECURITY: a claim set only by Cloud Functions). */
export function callerOf(request: CallableRequest): CallerIdentity {
  const uid = requireUid(request);
  return { uid, verifiedClaim: request.auth?.token?.verified === true };
}
