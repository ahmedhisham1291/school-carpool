import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, beforeEmailSent, beforeUserCreated, beforeUserSignedIn } from "firebase-functions/v2/identity";
import { adminDb } from "../admin";
import { adminLinkAllowed, creationAllowed, emailAllowed, isAdminAccount, signInAllowed } from "./sign_in_policy";

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

/**
 * No account is created from a client: a password sign-up
 * (createUserWithEmailAndPassword), an email link or any other provider is
 * refused before the account exists. Parents and admins are created by our
 * functions with the Admin SDK (sign_in_policy.ts, creationAllowed).
 */
export const blockClientSignUps = beforeUserCreated((event) => {
  const method = event.credential?.signInMethod ?? event.additionalUserInfo?.providerId;
  if (!creationAllowed(method)) {
    throw new HttpsError("permission-denied", "Accounts are not created here.");
  }
});

export const blockSignInEmails = beforeEmailSent(async (event) => {
  if (emailAllowed(event.emailType)) return;
  // Only exception: the admin script's one-time set-password link
  // (sign_in_policy.ts, adminLinkAllowed). Any error refuses.
  let allowed = false;
  try {
    const note = await adminDb().collection("serverState").doc("adminPasswordLink").get();
    const eventEmail = (event.additionalUserInfo as { email?: unknown } | undefined)?.email;
    allowed = adminLinkAllowed(
      event.emailType,
      note.exists ? (note.data() as { email?: unknown; expiresAtMs?: unknown }) : null,
      typeof eventEmail === "string" ? eventEmail : undefined,
      Date.now(),
    );
  } catch (error) {
    logger.error("admin link note read failed", { message: error instanceof Error ? error.message : "unknown" });
  }
  if (!allowed) {
    throw new HttpsError("permission-denied", "This email is not used by the app.");
  }
});
