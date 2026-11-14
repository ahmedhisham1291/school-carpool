import { createHash } from "node:crypto";

/**
 * Scraping alerts (spec section 7: "Alert admins when an account opens
 * many profiles, sends many chat requests or searches many areas in a short
 * time"; Prompt 12 adds parent ID lookups). Every limit that already
 * refuses calls stays as it is; this only TELLS the admins about an
 * account that comes close to sweeping data, once per account, kind and
 * hour. Pure; unit-tested. Counters hold short hashes of the targets
 * only (never the uid, parent ID, school or area as given; [keyHash]),
 * and expire after 2 days (TTL).
 */

export const ABUSE_KINDS = ["profiles", "chatRequests", "areaSearches", "parentIdLookups"] as const;
export type AbuseKind = (typeof ABUSE_KINDS)[number];

export const HOUR_MS = 3_600_000;

/**
 * Per hour. Distinct: count different targets (profiles, areas), not calls,
 * so reopening one profile or one area does not count again.
 */
export const ABUSE_THRESHOLDS: Readonly<Record<AbuseKind, { max: number; distinct: boolean }>> = {
  profiles: { max: 30, distinct: true },
  chatRequests: { max: 10, distinct: true },
  areaSearches: { max: 15, distinct: true },
  parentIdLookups: { max: 15, distinct: true },
};

/** At most this many distinct keys are kept per counter (above it the count still rises). */
export const MAX_KEYS = 100;

export interface AbuseCounter {
  hourStartMs: number;
  count: number;
  keys: string[];
  alerted: boolean;
}

export function hourStart(nowMs: number): number {
  return Math.floor(nowMs / HOUR_MS) * HOUR_MS;
}

/** Counter document ID: one per parent, kind and clock hour. */
export function counterId(uid: string, kind: AbuseKind, nowMs: number): string {
  return `${uid}_${kind}_${hourStart(nowMs)}`;
}

/**
 * Counts one call. Returns the counter to store and whether an alert must
 * be raised now (only on the call that crosses the threshold).
 */
export function countActivity(current: AbuseCounter | null, kind: AbuseKind, key: string, nowMs: number): { next: AbuseCounter; alert: boolean } {
  const start = hourStart(nowMs);
  const base: AbuseCounter = current && current.hourStartMs === start ? current : { hourStartMs: start, count: 0, keys: [], alerted: false };
  const rule = ABUSE_THRESHOLDS[kind];
  const seen = rule.distinct && base.keys.includes(key);
  if (seen) return { next: base, alert: false };
  const keys = rule.distinct && base.keys.length < MAX_KEYS ? [...base.keys, key] : base.keys;
  const count = base.count + 1;
  const alert = !base.alerted && count >= rule.max;
  return { next: { hourStartMs: start, count, keys, alerted: base.alerted || alert }, alert };
}

/** A target as stored in a counter: 16 hex of its SHA-256 (enough to tell targets apart within an hour). */
export function keyHash(key: string): string {
  return createHash("sha256").update(key).digest("hex").slice(0, 16);
}

export interface SecurityAlert {
  id: string;
  uid: string;
  kind: AbuseKind;
  count: number;
  hourStartMs: number;
  status: "open" | "handled";
  createdAtMs: number;
}

export function alertFor(uid: string, kind: AbuseKind, counter: AbuseCounter, nowMs: number): SecurityAlert {
  return { id: `${uid}_${kind}_${counter.hourStartMs}`, uid, kind, count: counter.count, hourStartMs: counter.hourStartMs, status: "open", createdAtMs: nowMs };
}

export interface AbuseStore {
  /** Reads, counts with [count] and writes the counter in one transaction; creates the alert when asked. */
  count(uid: string, kind: AbuseKind, nowMs: number, count: (current: AbuseCounter | null) => { next: AbuseCounter; alert: boolean }): Promise<SecurityAlert | null>;
}

/**
 * Best effort: a counting failure never blocks the parent's call (the
 * real limits are elsewhere). Returns the alert raised, if any.
 */
export async function noteActivity(
  store: AbuseStore,
  uid: string,
  kind: AbuseKind,
  key: string,
  nowMs: number,
  onError: (error: unknown) => void = () => undefined,
): Promise<SecurityAlert | null> {
  try {
    return await store.count(uid, kind, nowMs, (current) => countActivity(current, kind, keyHash(key.slice(0, 64)), nowMs));
  } catch (error) {
    onError(error);
    return null;
  }
}
