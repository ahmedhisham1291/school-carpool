import { HttpsError, onCall, type CallableOptions, type CallableRequest } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { gateRefusal } from "./devices";

export { gateRefusal, type GateRefusal } from "./devices";

/**
 * Prompt 12 (spec section 7), enforced on the server: the same two fields
 * of users/{uid} that firestore.rules checks (sessionValid, deviceChecked).
 *
 * - sessionsValidAfter (seconds): phones signed out (signOutDevice, a
 *   sign-in from a new phone) lose access at once: a token whose sign-in
 *   (auth_time) is older is refused with reason "signed-out".
 * - newDeviceCheck.required: after a sign-in from a new phone, every
 *   callable that reads or changes child, carpool, schedule, trip,
 *   location, chat, wallet or privacy data refuses with reason
 *   "device-check" until the fresh selfie matched. A SIM swap (the number
 *   alone) opens none of it.
 */
type Auth = CallableRequest["auth"];

function authTimeOf(auth: Auth): number | null {
  const t = (auth?.token as { auth_time?: unknown } | undefined)?.auth_time;
  return typeof t === "number" ? t : null;
}

async function check(auth: Auth, checkDevice: boolean): Promise<void> {
  if (!auth?.uid) return; // each callable refuses a missing sign-in itself
  const snap = await adminDb().collection("users").doc(auth.uid).get();
  const refusal = gateRefusal(snap.data(), authTimeOf(auth), checkDevice);
  if (refusal === "signed-out") throw new HttpsError("unauthenticated", "signed-out", { reason: "signed-out" });
  if (refusal === "device-check") throw new HttpsError("failed-precondition", "device-check", { reason: "device-check" });
}

/** Throws unless the session is valid and no new-phone check is open. */
export function requireNoDeviceCheck(auth: Auth): Promise<void> {
  return check(auth, true);
}

/** Throws unless the session is valid (phones signed out lose access at once). */
export function requireValidSession(auth: Auth): Promise<void> {
  return check(auth, false);
}

/** onCall with the full gate (valid session, no open new-phone check) before [handler]. */
export function gatedCall<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireNoDeviceCheck(request.auth);
    return handler(request);
  });
}

/** onCall with the session check only (works during a new-phone check). */
export function sessionCall<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireValidSession(request.auth);
    return handler(request);
  });
}
