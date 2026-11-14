import type { CarpoolStore } from "../carpools/flow";
import { cairoDate } from "../carpools/model";
import { addDays } from "../schedule/cairo";
import { isLive, PLAN_WEEKS_AHEAD, type DeadlineSettings } from "../schedule/model";
import { releaseRun, uids } from "../schedule/release";

/**
 * F38: a failed selfie check pauses the driver. Every future run they
 * drive, in every carpool, loses its driver the Prompt 7 way (open for the
 * group to take, or missed with the critical "no driver" alert when it is
 * too late). The group is told only that the driver is unavailable.
 */
export async function releaseDriverRuns(store: CarpoolStore, uid: string, nowMs: number, settings: DeadlineSettings): Promise<number> {
  const today = cairoDate(nowMs);
  const last = addDays(today, (PLAN_WEEKS_AHEAD + 1) * 7 + 6);
  let released = 0;
  for (const m of await store.membershipsOf(uid)) {
    if (m.status !== "approved") continue;
    released += await store.transact(async (tx) => {
      const members = await tx.members(m.carpoolId);
      const runs = (await tx.runs(m.carpoolId, today, last)).filter((r) => r.driverUid === uid && isLive(r, nowMs));
      const stay = uids(members).filter((u) => u !== uid);
      for (const run of runs) {
        const r = releaseRun(run, stay, nowMs, settings, null);
        tx.putRun(r.run);
        tx.addEvent({ ...r.event, actorUid: uid });
      }
      return runs.length;
    });
  }
  return released;
}
