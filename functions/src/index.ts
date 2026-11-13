import { setGlobalOptions } from "firebase-functions/v2";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { ENABLE_TEST_ERROR, ENFORCE_APP_CHECK, MAX_INSTANCES, MIN_INSTANCES, REGION } from "./config";
import { reportError } from "./sentry";

setGlobalOptions({
  region: REGION,
  minInstances: MIN_INSTANCES,
  maxInstances: MAX_INSTANCES,
});

/**
 * Prompt 1: proves Sentry works from Cloud Functions. Throws on purpose,
 * reports the error (scrubbed) and returns an "internal" error to the app.
 * Disabled in prod via ENABLE_TEST_ERROR.
 */
export const debugTestError = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, async () => {
  if (!ENABLE_TEST_ERROR.value()) {
    throw new HttpsError("permission-denied", "Test errors are disabled in this environment.");
  }
  const error = new Error("Sentry test error from Cloud Functions (Prompt 1)");
  logger.warn("debugTestError called; reporting a test error to Sentry");
  await reportError(error);
  throw new HttpsError("internal", "Test error raised and reported.");
});

// Sign-up and sign-in with a WhatsApp code (Prompt 2: F1, F44).
export { acceptConsents, confirmEmail, requestCode, verifyCode } from "./auth/callables";

// Identity verification, children and the automated ID check (Prompt 3: F2, F3, F18).
export {
  decideVerification,
  listVerificationQueue,
  openVerificationCase,
  purgeVerificationImagesDaily,
  removeChild,
  submitVerification,
  withdrawVerification,
} from "./verification/callables";

// Only WhatsApp-code sign-in (custom token); no password or email-link sign-in.
export { blockNonCodeSignIn, blockSignInEmails } from "./auth/blocking";
