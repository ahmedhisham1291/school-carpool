/**
 * Who may use the admin panel functions (F14). Pure, unit-tested; the
 * callables turn a refusal into a permission-denied error.
 *
 * An admin caller must have:
 * - the "admin" custom claim (a super admin also has "superAdmin"); only a
 *   super admin (createAdmin) or the bootstrap script sets them,
 * - signed in with a second factor (TOTP, Identity Platform), unless the
 *   local emulators run (the Auth emulator has no TOTP),
 * - signed in less than ADMIN_SESSION_MAX_SECONDS ago (short sessions; the
 *   panel also signs out after 15 idle minutes).
 *
 * firestore.rules applies the same three checks (isAdmin()).
 */
export type AdminRole = "admin" | "superAdmin";

export interface AdminCaller {
  uid: string;
  role: AdminRole;
}

/** Keep in sync with ADMIN_SESSION_HOURS in firestore.rules. */
export const ADMIN_SESSION_MAX_SECONDS = 8 * 60 * 60;

export type AccessRefusal = "unauthenticated" | "not-admin" | "mfa-required" | "session-expired" | "not-super-admin";

export interface CallerAuth {
  uid: string;
  token: Record<string, unknown>;
}

export function adminRoleOf(claims: Record<string, unknown> | undefined | null): AdminRole | null {
  if (!claims || claims.admin !== true) return null;
  return claims.superAdmin === true ? "superAdmin" : "admin";
}

function secondFactorOf(token: Record<string, unknown>): string | null {
  const firebase = token.firebase;
  if (typeof firebase !== "object" || firebase === null) return null;
  const factor = (firebase as Record<string, unknown>).sign_in_second_factor;
  return typeof factor === "string" && factor.length > 0 ? factor : null;
}

export function adminAccess(
  auth: CallerAuth | undefined,
  nowSeconds: number,
  options: { requireMfa: boolean; superAdmin?: boolean },
): AdminCaller | AccessRefusal {
  if (!auth?.uid) return "unauthenticated";
  const role = adminRoleOf(auth.token);
  if (!role) return "not-admin";
  if (options.requireMfa && !secondFactorOf(auth.token)) return "mfa-required";
  const authTime = typeof auth.token.auth_time === "number" ? auth.token.auth_time : 0;
  if (nowSeconds - authTime > ADMIN_SESSION_MAX_SECONDS) return "session-expired";
  if (options.superAdmin && role !== "superAdmin") return "not-super-admin";
  return { uid: auth.uid, role };
}

export function isRefusal(value: AdminCaller | AccessRefusal): value is AccessRefusal {
  return typeof value === "string";
}
