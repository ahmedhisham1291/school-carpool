import { HttpsError, onCall, type CallableOptions, type CallableRequest } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { readReviewDemoState } from "../auth/review_access";
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

/**
 * Validator review (docs/reviews/apple-review.md, B1): App Review demo
 * parents are "verified" without an ID check, and their sign-in code is
 * known outside the team, so the server confines them:
 * - outside the review window (access off or expired, or the account not
 *   listed in config/reviewAccess) every gated callable refuses them
 *   ("demo-closed");
 * - inside it, the callables that reach real parents or leave the demo
 *   school and carpool refuse them ("demo-account"): realParentCall and
 *   refuseReviewDemo below. Everything a demo parent can still do is
 *   scoped by the server to its own school and carpool (children's
 *   schools, shared carpool), which hold fake data only.
 */
const demoCallers = new WeakSet<object>();

export function demoAccountError(): HttpsError {
  return new HttpsError("failed-precondition", "demo-account", { reason: "demo-account" });
}

async function check(request: CallableRequest, checkDevice: boolean, allowClosedDemo = false): Promise<void> {
  const auth = request.auth;
  if (!auth?.uid) return; // each callable refuses a missing sign-in itself
  const snap = await adminDb().collection("users").doc(auth.uid).get();
  const refusal = gateRefusal(snap.data(), authTimeOf(auth), checkDevice);
  if (refusal === "signed-out") throw new HttpsError("unauthenticated", "signed-out", { reason: "signed-out" });
  if (refusal === "device-check") throw new HttpsError("failed-precondition", "device-check", { reason: "device-check" });
  const demo = await readReviewDemoState(adminDb(), auth.uid, snap.data(), Date.now());
  if (demo === "closed" && allowClosedDemo) return;
  if (demo === "closed") throw new HttpsError("permission-denied", "demo-closed", { reason: "demo-closed" });
  if (demo === "open") demoCallers.add(request);
}

/** True when the gate found the caller to be an App Review demo parent (inside its window). */
export function isReviewDemoCaller(request: CallableRequest): boolean {
  return demoCallers.has(request);
}

/** Throws "demo-account" for an App Review demo parent. Call after the gate ran. */
export function refuseReviewDemo(request: CallableRequest): void {
  if (isReviewDemoCaller(request)) throw demoAccountError();
}

/** Throws unless the session is valid and no new-phone check is open. */
export function requireNoDeviceCheck(request: CallableRequest): Promise<void> {
  return check(request, true);
}

/** Throws unless the session is valid (phones signed out lose access at once). */
export function requireValidSession(request: CallableRequest): Promise<void> {
  return check(request, false);
}

/** onCall with the full gate (valid session, no open new-phone check) before [handler]. */
export function gatedCall<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireNoDeviceCheck(request);
    return handler(request);
  });
}

/**
 * gatedCall that a demo parent outside its window may still use. Only for
 * deleteMyAccount: closing a demo account is always allowed.
 */
export function gatedCallAlsoClosedDemo<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await check(request, true, true);
    return handler(request);
  });
}

/** gatedCall that also refuses App Review demo parents (reaches real parents, or leaves the demo school and carpool). */
export function realParentCall<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireNoDeviceCheck(request);
    refuseReviewDemo(request);
    return handler(request);
  });
}

/** onCall with the session check only (works during a new-phone check). */
export function sessionCall<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireValidSession(request);
    return handler(request);
  });
}

/** sessionCall that also refuses App Review demo parents. */
export function realParentSessionCall<T>(options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireValidSession(request);
    refuseReviewDemo(request);
    return handler(request);
  });
}
