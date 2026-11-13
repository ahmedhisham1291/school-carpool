import { FieldValue, Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { clientIp } from "../auth/client_ip";
import { CLIENT_IP_HOP } from "../config";
import {
  adminAccess,
  adminRecordAccess,
  isRefusal,
  shouldTouch,
  type AccessRefusal,
  type AdminCaller,
  type AdminRecordState,
  type CallerAuth,
} from "./guard";
import { ADMINS } from "./store";

/**
 * The second factor is required everywhere except the local emulators
 * (the Auth emulator has no TOTP). There is no setting to turn it off in
 * a cloud project.
 */
export function mfaRequired(): boolean {
  return process.env.FUNCTIONS_EMULATOR !== "true";
}

function refuse(reason: AccessRefusal): never {
  throw new HttpsError(reason === "unauthenticated" ? "unauthenticated" : "permission-denied", reason, { reason });
}

function millis(value: unknown): number | null {
  return value instanceof Timestamp ? value.toMillis() : null;
}

/**
 * The admin calling, or a permission error with details.reason for the
 * panel. Checks the token (claim, second factor, 8 hours), then the
 * admin's record (not disabled, token not revoked, not idle for 15
 * minutes) and records the activity.
 */
export async function requireAdminCaller(
  request: CallableRequest,
  options: { superAdmin?: boolean } = {},
): Promise<AdminCaller> {
  const nowMs = Date.now();
  const result = adminAccess(request.auth as CallerAuth | undefined, Math.floor(nowMs / 1000), {
    requireMfa: mfaRequired(),
    superAdmin: options.superAdmin,
  });
  if (isRefusal(result)) refuse(result);

  const ref = adminDb().collection(ADMINS).doc(result.uid);
  const snap = await ref.get();
  const record: AdminRecordState | undefined = snap.exists
    ? {
        disabled: snap.get("disabled") === true,
        revokedAtMs: millis(snap.get("revokedAt")),
        lastActiveAtMs: millis(snap.get("lastActiveAt")),
      }
    : undefined;
  const refusal = adminRecordAccess(record, request.auth?.token ?? {}, nowMs);
  if (refusal) refuse(refusal);
  if (record && shouldTouch(record, nowMs)) {
    try {
      await ref.update({ lastActiveAt: FieldValue.serverTimestamp() });
    } catch (error) {
      logger.warn("admin activity not recorded", { message: error instanceof Error ? error.message : "unknown" });
    }
  }
  return result;
}

export function ipOf(request: CallableRequest): string {
  return clientIp(request.rawRequest.headers, request.rawRequest.ip, CLIENT_IP_HOP.value());
}
