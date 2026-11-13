/**
 * Reasons an admin panel request is refused. They reach the panel in
 * `details.reason` so it can say what to do.
 */
export type AdminErrorReason =
  | "invalid-request"
  | "not-found"
  | "rate-limited"
  | "own-account"
  | "target-is-admin"
  | "already-exists"
  | "invalid-state";

export class AdminError extends Error {
  constructor(
    readonly reason: AdminErrorReason,
    readonly details: Record<string, unknown> = {},
  ) {
    super(reason);
    this.name = "AdminError";
  }
}

/** HTTPS error code for each reason (the callables map them). */
export const ADMIN_ERROR_CODES: Record<AdminErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "not-found": "not-found",
  "rate-limited": "resource-exhausted",
  "own-account": "permission-denied",
  "target-is-admin": "permission-denied",
  "already-exists": "already-exists",
  "invalid-state": "failed-precondition",
};

export function record(data: unknown): Record<string, unknown> | null {
  return typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : null;
}

/** Firestore document IDs we accept from the panel. */
export const DOC_ID = /^[A-Za-z0-9_-]{1,64}$/;

export function docId(value: unknown): string {
  if (typeof value !== "string" || !DOC_ID.test(value)) throw new AdminError("invalid-request");
  return value;
}

/** A trimmed string of [min, max] characters, or an invalid-request error. */
export function text(value: unknown, min: number, max: number): string {
  if (typeof value !== "string") throw new AdminError("invalid-request");
  const trimmed = value.trim().replace(/\s+/g, " ");
  if (trimmed.length < min || trimmed.length > max) throw new AdminError("invalid-request");
  return trimmed;
}

export function optionalText(value: unknown, max: number): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value === "string" && value.trim().length === 0) return null;
  return text(value, 1, max);
}
