import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { clientIp } from "../auth/client_ip";
import { CLIENT_IP_HOP } from "../config";
import { adminAccess, isRefusal, type AdminCaller, type CallerAuth } from "./guard";

/**
 * The second factor is required everywhere except the local emulators
 * (the Auth emulator has no TOTP). There is no setting to turn it off in
 * a cloud project.
 */
export function mfaRequired(): boolean {
  return process.env.FUNCTIONS_EMULATOR !== "true";
}

/** The admin calling, or a permission error with details.reason for the panel. */
export function requireAdminCaller(request: CallableRequest, options: { superAdmin?: boolean } = {}): AdminCaller {
  const result = adminAccess(request.auth as CallerAuth | undefined, Math.floor(Date.now() / 1000), {
    requireMfa: mfaRequired(),
    superAdmin: options.superAdmin,
  });
  if (isRefusal(result)) {
    throw new HttpsError(result === "unauthenticated" ? "unauthenticated" : "permission-denied", result, { reason: result });
  }
  return result;
}

export function ipOf(request: CallableRequest): string {
  return clientIp(request.rawRequest.headers, request.rawRequest.ip, CLIENT_IP_HOP.value());
}
