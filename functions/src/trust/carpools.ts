import type { CarpoolDeps } from "../carpools/flow";
import { cairoDate, carInfo, type CarInfo, type ChildRef, type MembershipRecord } from "../carpools/model";
import { DEFAULT_DEADLINES } from "../schedule/model";
import { releaseRunsWhere, removeChildFromRuns } from "../schedule/release";
import { runInvalid } from "./model";

/**
 * Carpool changes caused by trust events (Prompt 11, F17), each in one
 * carpool transaction (Prompt 6 and 7 records):
 * - a child left the school, or a guardian link ended: the child leaves
 *   that parent's carpools (memberships, members, open requests, future
 *   pickup lists); the carpool chat follows the membership (Prompt 9);
 * - a new grade for the new school year: the copies in carpools follow;
 * - a driver's car changed or expired: runs the car can no longer carry
 *   lose their driver (open for the group, "driver unavailable" only).
 */

const activeMembership = (m: MembershipRecord) => m.status === "approved" || m.status === "requested";

/** Returns the carpools changed. */
export async function removeChildFromCarpools(deps: CarpoolDeps, parentUid: string, childId: string): Promise<number> {
  const mine = (await deps.store.membershipsOf(parentUid)).filter((m) => activeMembership(m) && m.children.some((c) => c.id === childId));
  let changed = 0;
  for (const found of mine) {
    changed += await deps.store.transact(async (tx) => {
      const nowMs = deps.now();
      const m = await tx.membership(found.carpoolId, parentUid);
      if (!m || !activeMembership(m) || !m.children.some((c) => c.id === childId)) return 0;
      const children = m.children.filter((c) => c.id !== childId);
      if (m.status === "requested") {
        const requests = await tx.requests(found.carpoolId);
        const r = requests.find((x) => x.uid === parentUid);
        if (children.length === 0) {
          // Nothing left to ask for: the request ends.
          tx.putMembership({ ...m, children, status: "left", decidedAtMs: nowMs, decidedBy: parentUid, updatedAtMs: nowMs });
          tx.deleteRequest(found.carpoolId, parentUid);
        } else {
          tx.putMembership({ ...m, children, updatedAtMs: nowMs });
          if (r) tx.putRequest(found.carpoolId, { ...r, children });
        }
        return 1;
      }
      const carpool = await tx.carpool(found.carpoolId);
      const members = await tx.members(found.carpoolId);
      const member = members.find((x) => x.uid === parentUid);
      await removeChildFromRuns(tx, found.carpoolId, childId, cairoDate(nowMs), nowMs);
      tx.putMembership({ ...m, children, updatedAtMs: nowMs });
      if (member) tx.putMember(found.carpoolId, { ...member, children });
      if (carpool) tx.putCarpool({ ...carpool, childrenCount: Math.max(0, carpool.childrenCount - 1), updatedAtMs: nowMs });
      return 1;
    });
  }
  return changed;
}

/** The child's new grade in that parent's carpools (members see first names and grades). */
export async function updateChildGrade(deps: CarpoolDeps, parentUid: string, childId: string, grade: string): Promise<number> {
  const mine = (await deps.store.membershipsOf(parentUid)).filter((m) => activeMembership(m) && m.children.some((c) => c.id === childId && c.grade !== grade));
  let changed = 0;
  for (const found of mine) {
    changed += await deps.store.transact(async (tx) => {
      const nowMs = deps.now();
      const m = await tx.membership(found.carpoolId, parentUid);
      if (!m || !activeMembership(m)) return 0;
      const children: ChildRef[] = m.children.map((c) => (c.id === childId ? { ...c, grade } : c));
      tx.putMembership({ ...m, children, updatedAtMs: nowMs });
      if (m.status === "approved") {
        const member = (await tx.members(found.carpoolId)).find((x) => x.uid === parentUid);
        if (member) tx.putMember(found.carpoolId, { ...member, children });
      } else {
        const r = (await tx.requests(found.carpoolId)).find((x) => x.uid === parentUid);
        if (r) tx.putRequest(found.carpoolId, { ...r, children });
      }
      return 1;
    });
  }
  return changed;
}

/**
 * [driverUid]'s car is now [car] (null: none usable). In each carpool:
 * the member's copy of the car is refreshed, future runs the car cannot
 * carry are released, and when the driver started the carpool with a car
 * that now has fewer seats, the carpool's seats come down (never below the
 * children already in it). Returns the runs freed.
 */
export async function applyCarChange(deps: CarpoolDeps, driverUid: string, car: CarInfo | null): Promise<number> {
  const mine = (await deps.store.membershipsOf(driverUid)).filter((m) => m.status === "approved");
  const settings = deps.deadlines ?? DEFAULT_DEADLINES;
  let freed = 0;
  for (const found of mine) {
    freed += await deps.store.transact(async (tx) => {
      const nowMs = deps.now();
      const m = await tx.membership(found.carpoolId, driverUid);
      if (!m || m.status !== "approved") return 0;
      const carpool = await tx.carpool(found.carpoolId);
      const members = await tx.members(found.carpoolId);
      const member = members.find((x) => x.uid === driverUid);
      const n = await releaseRunsWhere(tx, found.carpoolId, driverUid, members, cairoDate(nowMs), nowMs, settings, (run) => runInvalid(run, car));
      const sameCar = JSON.stringify(m.car) === JSON.stringify(car);
      if (!sameCar) {
        tx.putMembership({ ...m, car, updatedAtMs: nowMs });
        if (member) tx.putMember(found.carpoolId, { ...member, car });
      }
      if (carpool && carpool.creatorUid === driverUid && car && car.seats < carpool.seats) {
        const seats = Math.max(carpool.childrenCount, car.seats);
        if (seats !== carpool.seats) tx.putCarpool({ ...carpool, seats, updatedAtMs: nowMs });
      }
      return n;
    });
  }
  return freed;
}

/** Same as [applyCarChange] with the car read again (daily papers check). */
export async function recheckDriver(deps: CarpoolDeps, driverUid: string): Promise<number> {
  return applyCarChange(deps, driverUid, carInfo(await deps.store.vehicle(driverUid)));
}
