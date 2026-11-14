import { HttpsError } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { deviceCheckPending } from "./devices";

/**
 * Prompt 12 (spec section 7): after a sign-in from a new phone, chats, the
 * wallet and child data stay closed until the parent's fresh selfie
 * matched (users/{uid}.newDeviceCheck). Refused with details.reason
 * "device-check"; the app opens the selfie screen.
 */
export async function requireNoDeviceCheck(uid: string | undefined): Promise<void> {
  if (!uid) return;
  const snap = await adminDb().collection("users").doc(uid).get();
  if (deviceCheckPending(snap.data())) throw new HttpsError("failed-precondition", "device-check", { reason: "device-check" });
}
