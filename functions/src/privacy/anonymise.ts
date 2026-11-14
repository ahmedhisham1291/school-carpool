import { createHash } from "node:crypto";

/**
 * Prompt 12 review (item 3): when a parent deletes the account, their
 * children's first names, handover names and their own first name are
 * replaced in the records that stay with OTHER parents (other drivers'
 * trips, the carpool's past runs, swaps and term balances, the carpool
 * card). An initial stays so the group's history still reads ("A."), and
 * the uids become "deleted". Plain data in, plain data out (no Firestore
 * here): the deletion runner reads, calls these and writes back only what
 * changed.
 */

/** The marker that replaces a deleted parent's or child's ID. */
export const DELETED_ID = "deleted";

/** "Adam" -> "A."; empty -> "". */
export function initialOf(name: unknown): string {
  if (typeof name !== "string") return "";
  const first = Array.from(name.trim())[0];
  return first ? `${first}.` : "";
}

type Data = Record<string, unknown>;

const isObj = (v: unknown): v is Data => typeof v === "object" && v !== null && !Array.isArray(v);

/** Riders / absent lists of a run: the parent's children become an initial. */
function riders(list: unknown, uid: string): { list: unknown; changed: boolean } {
  if (!Array.isArray(list)) return { list, changed: false };
  let changed = false;
  const out = list.map((r) => {
    if (!isObj(r) || r.parentUid !== uid) return r;
    changed = true;
    return { ...r, id: DELETED_ID, parentUid: DELETED_ID, firstName: initialOf(r.firstName) };
  });
  return { list: out, changed };
}

/**
 * A trip (trips/{id}) the parent took part in. Their children's stops keep
 * the times (the driver's record) but lose the name, the child ID and the
 * handover names; the parent leaves viewerUids. A trip the parent drove
 * keeps only the driver's initial (purged 1 year after closure anyway).
 * Returns the changed fields, or null when nothing changes.
 */
export function anonymiseTrip(trip: Data, uid: string): Data | null {
  const change: Data = {};
  const stops = Array.isArray(trip.stops) ? trip.stops : [];
  const gone = new Set<string>();
  let stopsChanged = false;
  const newStops = stops.map((s) => {
    if (!isObj(s) || s.parentUid !== uid) return s;
    stopsChanged = true;
    if (typeof s.childId === "string") gone.add(s.childId);
    return { ...s, childId: DELETED_ID, parentUid: DELETED_ID, firstName: initialOf(s.firstName), handover: [] };
  });
  if (stopsChanged) change.stops = newStops;
  if (Array.isArray(trip.viewerUids) && trip.viewerUids.includes(uid) && trip.driverUid !== uid) {
    change.viewerUids = trip.viewerUids.filter((v) => v !== uid);
  }
  if (Array.isArray(trip.childIds) && gone.size > 0) {
    change.childIds = trip.childIds.filter((c) => typeof c !== "string" || !gone.has(c));
  }
  if (trip.driverUid === uid && typeof trip.driverFirstName === "string" && trip.driverFirstName !== initialOf(trip.driverFirstName)) {
    change.driverFirstName = initialOf(trip.driverFirstName);
  }
  return Object.keys(change).length > 0 ? change : null;
}

/** A run of the carpool's schedule (past runs; future ones were released). */
export function anonymiseRun(run: Data, uid: string): Data | null {
  const change: Data = {};
  const r = riders(run.riders, uid);
  if (r.changed) change.riders = r.list;
  const a = riders(run.absent, uid);
  if (a.changed) change.absent = a.list;
  if (run.driverUid === uid) {
    change.driverUid = DELETED_ID;
    change.driverFirstName = initialOf(run.driverFirstName);
  }
  if (run.swapBy === uid) change.swapBy = DELETED_ID;
  return Object.keys(change).length > 0 ? change : null;
}

/** A swap request the parent made or accepted. */
export function anonymiseSwap(swap: Data, uid: string): Data | null {
  const change: Data = {};
  if (swap.requesterUid === uid) {
    change.requesterUid = DELETED_ID;
    change.requesterFirstName = initialOf(swap.requesterFirstName);
  }
  if (swap.acceptedBy === uid) change.acceptedBy = DELETED_ID;
  if (Array.isArray(swap.suggestedUids) && swap.suggestedUids.includes(uid)) {
    change.suggestedUids = swap.suggestedUids.filter((v) => v !== uid);
  }
  return Object.keys(change).length > 0 ? change : null;
}

/** A term balance: the family's counts stay (fair shares), the name becomes an initial. */
export function anonymiseBalance(balance: Data, uid: string): Data | null {
  const families = balance.families;
  if (!isObj(families) || !isObj(families[uid])) return null;
  const mine = families[uid] as Data;
  const rest: Data = { ...families };
  delete rest[uid];
  return { families: { ...rest, [`${DELETED_ID}_${createHash("sha256").update(uid).digest("hex").slice(0, 8)}`]: { ...mine, firstName: initialOf(mine.firstName) } } };
}

/** The carpool card when the parent created it. */
export function anonymiseCarpool(carpool: Data, uid: string): Data | null {
  if (carpool.creatorUid !== uid) return null;
  return { creatorUid: DELETED_ID, creatorFirstName: initialOf(carpool.creatorFirstName) };
}
