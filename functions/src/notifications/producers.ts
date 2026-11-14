import { createHash } from "node:crypto";
import { newEvent, type LatLng, type OutboxEvent } from "./model";

/**
 * Outbox events written by earlier prompts' flows, inside their own
 * transactions (Prompt 8 wiring). IDs only: no names, no message text.
 * Fixed IDs, so a flow that runs twice never makes two events.
 *
 * Other producers: schedule and join-request flows write through
 * CarpoolTx.addEvent (schedule/release.ts `event`), the tick writes
 * reminders and alarms (tick.ts).
 */

/** F2, F3 (Prompt 3): the result of a reviewed case, to its parent. */
export function verificationResultEvent(w: { caseId: string; uid: string; status: "approved" | "rejected" }, nowMs: number): OutboxEvent {
  return newEvent(`verification_${w.caseId}`, w.status === "approved" ? "verification-approved" : "verification-rejected", [w.uid], nowMs);
}

/**
 * F23 (Prompt 5): a parent was verified, has a home and a school, and is
 * shown on the map. The sender finds the nearby parents. Only the ROUNDED
 * point; one event per parent ever. The ID is a hash of the uid, because
 * it becomes the record ID other parents see in their push data.
 */
export function newParentEvent(uid: string, schoolIds: string[], roundedPoint: LatLng, nowMs: number): OutboxEvent {
  const key = createHash("sha256").update(`new-parent:${uid}`).digest("hex").slice(0, 32);
  return newEvent(`new-parent_${key}`, "new-parent", [], nowMs, { subjectUid: uid, schoolIds, point: roundedPoint });
}
