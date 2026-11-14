import type { CarpoolDeps } from "../carpools/flow";
import { cairoDate } from "../carpools/model";
import { DEFAULT_DEADLINES } from "./model";
import { releaseAfterPause } from "./release";

/**
 * Pauses a driver's driving days in every carpool they are in (urgent
 * report, Prompt 9). The driver's own record gets `drivingPaused` (written
 * by the caller), which stops them confirming, taking or being planned for
 * any run until an admin lifts it (the stores read it as status "paused",
 * so withFreshCars gives them no car). Here: their runs from today on are
 * released, one carpool transaction each.
 */
export async function pauseDriverRuns(deps: CarpoolDeps, driverUid: string): Promise<{ carpools: number; runs: number }> {
  const nowMs = deps.now();
  const today = cairoDate(nowMs);
  const settings = deps.deadlines ?? DEFAULT_DEADLINES;
  const memberships = (await deps.store.membershipsOf(driverUid)).filter((m) => m.status === "approved");
  let runs = 0;
  for (const m of memberships) {
    runs += await deps.store.transact(async (tx) => {
      const members = await tx.members(m.carpoolId);
      return releaseAfterPause(tx, m.carpoolId, driverUid, members, today, nowMs, settings);
    });
  }
  return { carpools: memberships.length, runs };
}
