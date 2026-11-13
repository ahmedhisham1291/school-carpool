/**
 * Fixed-window rate limits for the maps features (spec section 7: "Limit
 * home-location changes and map searches so nobody can sweep the map").
 * Counted on the server per parent in mapLimits/{uid}; the app cannot read
 * or change them (firestore.rules).
 */

export type MapLimitKind = "homeMoves" | "nearbySearches" | "placeSearches" | "placeDetails" | "drivingSchoolChanges";

export interface WindowCounter {
  windowStartMs: number;
  count: number;
}

export interface LimitRule {
  windowMs: number;
  max: number;
}

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

/** Window of each limit; the maximum comes from a param (config.ts). */
export const LIMIT_WINDOWS: Record<MapLimitKind, number> = {
  homeMoves: DAY,
  nearbySearches: HOUR,
  placeSearches: HOUR,
  placeDetails: HOUR,
  drivingSchoolChanges: DAY,
};

/**
 * Takes one from the counter. A new window starts when the old one has
 * passed. Returns whether the call is allowed and the counter to store
 * (unchanged when refused).
 */
export function takeFromWindow(
  current: WindowCounter | undefined,
  nowMs: number,
  rule: LimitRule,
): { allowed: boolean; next: WindowCounter; retryAfterMs: number } {
  const fresh = !current || nowMs - current.windowStartMs >= rule.windowMs || nowMs < current.windowStartMs;
  const counter = fresh ? { windowStartMs: nowMs, count: 0 } : current;
  if (counter.count >= rule.max) {
    return { allowed: false, next: counter, retryAfterMs: Math.max(0, counter.windowStartMs + rule.windowMs - nowMs) };
  }
  return { allowed: true, next: { windowStartMs: counter.windowStartMs, count: counter.count + 1 }, retryAfterMs: 0 };
}
