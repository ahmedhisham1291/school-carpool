import { DELETED_ID, anonymiseTrip, initialOf } from "./anonymise";
import { DAY_MS, YEAR_DAYS } from "./retention";

/**
 * Owner answer (14 Nov 2026, 13:29, DECISIONS.md): trip data is kept per
 * parent, while that parent's account is active + 1 year. A trip
 * (trips/{id}) is shared by its driver and the parents of the children on
 * it, so:
 * - it stays while ANY participant's account is active or closed less
 *   than a year ago;
 * - the part of a participant whose year is over is anonymised (their
 *   children's stops were already reduced to initials at deletion; the
 *   driver's uid becomes "deleted" and the name an initial);
 * - it is deleted when every participant's year is over.
 * Used by the closed-carpool purge and the account purge (1 year after
 * closure). Plain data in, plain data out.
 */

type Data = Record<string, unknown>;

/** What we know about one account: active, closed (when), or gone without a record. */
export type AccountState = { active: true } | { active: false; closedAtMs: number | null };

export const TRIP_KEEP_AFTER_CLOSE_MS = YEAR_DAYS * DAY_MS;

const isObj = (v: unknown): v is Data => typeof v === "object" && v !== null && !Array.isArray(v);

/** The driver and the parents of the children on the trip (not "deleted"). */
export function participantsOf(trip: Data): string[] {
  const out = new Set<string>();
  if (typeof trip.driverUid === "string" && trip.driverUid !== DELETED_ID) out.add(trip.driverUid);
  for (const s of Array.isArray(trip.stops) ? trip.stops : []) {
    if (isObj(s) && typeof s.parentUid === "string" && s.parentUid !== DELETED_ID) out.add(s.parentUid);
  }
  return [...out];
}

/** Active, or closed less than a year ago. No record at all: not kept. */
export function isRetained(state: AccountState | undefined, nowMs: number): boolean {
  if (!state) return false;
  if (state.active) return true;
  return state.closedAtMs !== null && nowMs - state.closedAtMs < TRIP_KEEP_AFTER_CLOSE_MS;
}

export type TripPlan = { action: "keep"; change: Data | null } | { action: "delete" };

/**
 * What happens to one trip now. [states] holds every participant's
 * account (missing: no record). [expired] forces some uids to count as
 * over (the account purge runs exactly at the year mark).
 */
export function planTripRetention(trip: Data, states: ReadonlyMap<string, AccountState>, nowMs: number, expired: ReadonlySet<string> = new Set()): TripPlan {
  const people = participantsOf(trip);
  const over = people.filter((u) => expired.has(u) || !isRetained(states.get(u), nowMs));
  if (over.length === people.length) return { action: "delete" };
  let current: Data = { ...trip };
  const change: Data = {};
  for (const uid of over) {
    const c = anonymiseTrip(current, uid) ?? {};
    if (current.driverUid === uid) {
      c.driverUid = DELETED_ID;
      c.driverFirstName = initialOf(current.driverFirstName);
      if (Array.isArray(current.viewerUids)) c.viewerUids = current.viewerUids.filter((v) => v !== uid);
    }
    Object.assign(change, c);
    current = { ...current, ...c };
  }
  return { action: "keep", change: Object.keys(change).length > 0 ? change : null };
}
