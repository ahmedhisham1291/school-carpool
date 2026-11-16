import * as logger from "firebase-functions/logger";
import { onCall } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { reasonErrorMapper, runCallable } from "../common/callable";
import { ENFORCE_APP_CHECK, SIGNIN_LOG_KEY } from "../config";
import { reportError } from "../sentry";
import { discloseSignInLog, newSignInEntry, SIGN_IN_LOG_ERROR_CODES, SignInLogError } from "./signin_log";
import { FirestoreSignInLogStore } from "./signin_log_store";

/** Used only by the local emulators when SIGNIN_LOG_KEY is not set. Not a secret. */
const EMULATOR_ONLY_KEY = "emulator-only-signin-log-key";

function logKey(): string | null {
  const key = SIGNIN_LOG_KEY.value();
  if (key) return key;
  if (process.env.FUNCTIONS_EMULATOR === "true") return EMULATOR_ONLY_KEY;
  return null;
}

/** The secret verifyCode needs (auth/callables.ts adds it to its options). */
export const SIGNIN_LOG_SECRETS = [SIGNIN_LOG_KEY];

/**
 * Called by verifyCode after a right code. Never fails the sign-in: a
 * missing key or a failed write is logged (no number, no IP) and reported
 * to Sentry so the owner fixes it (the law asks for every sign-in).
 */
export async function logSignIn(e: {
  uid: string;
  phoneE164: string;
  ip: string | null;
  deviceKey: string | null;
  platform: "ios" | "android" | "web";
  appVersion: unknown;
}): Promise<void> {
  try {
    const key = logKey();
    if (!key) throw new Error("SIGNIN_LOG_KEY is not set");
    await new FirestoreSignInLogStore(adminDb()).add(newSignInEntry(key, { ...e, atMs: Date.now() }));
  } catch (error) {
    logger.error("sign-in log write failed", { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
  }
}

/**
 * Admin panel (super admins only, sign-in less than 30 minutes old): the
 * sign-in lines of one account or one number, for a judicial order.
 * { orderRef, authority, orderDate, uid | phone } -> { lines, count }.
 * The audit entry is written before the answer.
 */
export const adminDiscloseSignInLog = onCall({ enforceAppCheck: ENFORCE_APP_CHECK, secrets: [SIGNIN_LOG_KEY] }, (request) =>
  runCallable(
    "adminDiscloseSignInLog",
    async () => {
      const caller = await requireAdminCaller(request, { superAdmin: true, recentSignIn: true });
      const secret = logKey();
      if (!secret) throw new Error("SIGNIN_LOG_KEY is not set");
      return discloseSignInLog({ store: new FirestoreSignInLogStore(adminDb()), secret, now: () => Date.now() }, { uid: caller.uid, ip: ipOf(request) }, request.data);
    },
    { map: [reasonErrorMapper(SignInLogError, SIGN_IN_LOG_ERROR_CODES)] },
  ),
);
