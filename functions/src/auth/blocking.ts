import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, beforeEmailSent, beforeUserSignedIn } from "firebase-functions/v2/identity";
import { adminDb } from "../admin";
import { emailAllowed, isAdminAccount, signInAllowed } from "./sign_in_policy";

/**
 * Identity Platform blocking functions (free tier). They run before every
 * sign-in and before Firebase sends a sign-in or password-reset email.
 * Deploying them registers them with Authentication (SETUP.md 11.3).
 *
 * Parents: WhatsApp code (custom token) only. Admins (F14): email and
 * password, only for allow-listed admin accounts (sign_in_policy.ts); the
 * panel then requires the TOTP second factor, and every admin function
 * checks it on the token (admin_panel/guard.ts).
 */
export const blockNonCodeSignIn = beforeUserSignedIn(async (event) => {
  const method = event.credential?.signInMethod ?? event.additionalUserInfo?.providerId;
  const account = event.data;
  if (!signInAllowed(method, account)) {
    throw new HttpsError("permission-denied", "Sign in with a WhatsApp code.");
  }
  if (method === "password" && account && isAdminAccount(account)) {
    // Every admin sign-in is in the audit log. A failed write must not lock
    // the admins out, so it is logged and the sign-in continues.
    try {
      await adminDb().collection("auditLog").doc().create({
        actorUid: account.uid,
        action: "admin.signIn",
        target: `admins/${account.uid}`,
        ip: event.ipAddress ?? null,
        time: FieldValue.serverTimestamp(),
      });
    } catch (error) {
      logger.error("admin sign-in audit failed", { message: error instanceof Error ? error.message : "unknown" });
    }
  }
});

export const blockSignInEmails = beforeEmailSent((event) => {
  if (!emailAllowed(event.emailType)) {
    throw new HttpsError("permission-denied", "This email is not used by the app.");
  }
});
