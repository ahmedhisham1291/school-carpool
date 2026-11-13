import { HttpsError, beforeEmailSent, beforeUserSignedIn } from "firebase-functions/v2/identity";
import { emailAllowed, signInMethodAllowed } from "./sign_in_policy";

/**
 * Identity Platform blocking functions (free tier). They run before every
 * sign-in and before Firebase sends a sign-in or password-reset email.
 * Deploying them registers them with Authentication (SETUP.md 11.3).
 */
export const blockNonCodeSignIn = beforeUserSignedIn((event) => {
  const method = event.credential?.signInMethod ?? event.additionalUserInfo?.providerId;
  if (!signInMethodAllowed(method)) {
    throw new HttpsError("permission-denied", "Sign in with a WhatsApp code.");
  }
});

export const blockSignInEmails = beforeEmailSent((event) => {
  if (!emailAllowed(event.emailType)) {
    throw new HttpsError("permission-denied", "This email is not used by the app.");
  }
});
