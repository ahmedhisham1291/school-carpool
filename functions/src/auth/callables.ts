import { FieldValue } from "firebase-admin/firestore";
import { readReviewAccess } from "./review_access";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminAuth, adminDb } from "../admin";
import {
  CLIENT_IP_HOP,
  ENFORCE_APP_CHECK,
  MIN_INSTANCES_SIGNIN,
  OTP_HMAC_KEY,
  OTP_MAX_FAILURES_PER_DAY,
  OTP_MAX_SENDS_PER_IP,
  WHATSAPP_ACCESS_TOKEN,
  WHATSAPP_API_VERSION,
  WHATSAPP_CODE_TEMPLATE,
  WHATSAPP_PHONE_NUMBER_ID,
  WHATSAPP_PROVIDER,
  WHATSAPP_TEMPLATE_LANG_AR,
  WHATSAPP_TEMPLATE_LANG_EN,
  appEnv,
} from "../config";
import { reportError } from "../sentry";
import { asLanguage, createWhatsAppSender, type WhatsAppSender } from "../whatsapp/sender";
import { FirebaseAccountService, USERS, verifiedEmail } from "./accounts";
import { clientIp } from "./client_ip";
import { CONSENT_VERSIONS, ConsentError, parseConsentRequest, recordConsents } from "./consents";
import {
  DEFAULT_OTP_LIMITS,
  OtpError,
  ipKey,
  requestCode as requestCodeFlow,
  verifyCode as verifyCodeFlow,
  type OtpDeps,
  type OtpErrorReason,
} from "./otp_flow";
import { FirestoreOtpStore } from "./otp_store";
import { emailConfirmationIsNew } from "./sign_in_policy";
import { afterSignIn } from "../privacy/callables";
import { classesMapper, requireUid, runCallable } from "../common/callable";

/**
 * Callable functions for sign-up and sign-in (F1). App Check is enforced in
 * staging and prod (ENFORCE_APP_CHECK). Errors carry `details.reason` so the
 * app can say exactly what to do next.
 */

/** Used only by the local emulators when no OTP_HMAC_KEY is set. Not a secret. */
const EMULATOR_ONLY_HMAC_KEY = "emulator-only-otp-key-not-for-cloud";

const OTP_ERROR_CODES: Record<OtpErrorReason, FunctionsErrorCode> = {
  "invalid-phone": "invalid-argument",
  "invalid-request": "invalid-argument",
  "wrong-code": "invalid-argument",
  expired: "failed-precondition",
  "too-many-attempts": "failed-precondition",
  locked: "resource-exhausted",
  "rate-limited": "resource-exhausted",
  "too-soon": "resource-exhausted",
  "send-failed": "unavailable",
  suspended: "permission-denied",
};

export function toHttpsError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error;
  if (error instanceof OtpError) {
    return new HttpsError(OTP_ERROR_CODES[error.reason], error.reason, { reason: error.reason, ...error.details });
  }
  if (error instanceof ConsentError) {
    const code: FunctionsErrorCode = error.reason === "outdated-terms" ? "failed-precondition" : "invalid-argument";
    return new HttpsError(code, error.reason, { reason: error.reason });
  }
  return new HttpsError("internal", "Something went wrong.");
}

function otpHmacKey(): string {
  const key = OTP_HMAC_KEY.value();
  if (key) return key;
  if (process.env.FUNCTIONS_EMULATOR === "true") return EMULATOR_ONLY_HMAC_KEY;
  logger.error("OTP_HMAC_KEY is not set");
  throw new HttpsError("internal", "Sign-in is not configured.");
}

function whatsAppSender(): WhatsAppSender {
  const phoneNumberId = WHATSAPP_PHONE_NUMBER_ID.value();
  return createWhatsAppSender(
    {
      provider: WHATSAPP_PROVIDER.value(),
      appEnv: appEnv(),
      meta: {
        accessToken: WHATSAPP_ACCESS_TOKEN.value(),
        phoneNumberId: phoneNumberId === "none" ? "" : phoneNumberId,
        apiVersion: WHATSAPP_API_VERSION.value(),
        templateName: WHATSAPP_CODE_TEMPLATE.value(),
        templateLanguages: { ar: WHATSAPP_TEMPLATE_LANG_AR.value(), en: WHATSAPP_TEMPLATE_LANG_EN.value() },
      },
    },
    (message) => logger.info(message),
  );
}

/**
 * The sender, built on first use. App Review audit: a demo phone gets no
 * WhatsApp message, so the reviewer's sign-in must not depend on the
 * WhatsApp settings being complete; a parent then gets "send-failed"
 * (reported) instead of an internal error.
 */
function lazyWhatsAppSender(): WhatsAppSender {
  let real: WhatsAppSender | null = null;
  const get = (): WhatsAppSender => (real ??= whatsAppSender());
  return {
    get kind() {
      return get().kind;
    },
    sendCode: async (to, code, language) => get().sendCode(to, code, language),
  };
}

export function otpDeps(): OtpDeps {
  const db = adminDb();
  return {
    // Prompt 13: App Review sign-in, off unless config/reviewAccess is on.
    review: () => readReviewAccess(db),
    // Every demo sign-in is in the admin audit log (no number, no code).
    onReviewSignIn: async (uid) => {
      await db.collection("auditLog").doc().create({
        actorUid: uid,
        action: "auth.reviewAccess.signIn",
        target: `users/${uid}`,
        reasonCode: "appReview",
        ip: null,
        time: FieldValue.serverTimestamp(),
      });
    },
    store: new FirestoreOtpStore(db),
    sender: lazyWhatsAppSender(),
    accounts: new FirebaseAccountService(adminAuth(), db),
    hmacKey: otpHmacKey(),
    now: () => Date.now(),
    limits: { ...DEFAULT_OTP_LIMITS, maxSendsPerIp: OTP_MAX_SENDS_PER_IP.value(), maxFailuresPerPhonePerDay: OTP_MAX_FAILURES_PER_DAY.value() },
    reportError: (error) => {
      logger.error("WhatsApp send failed", { message: error instanceof Error ? error.message : "unknown" });
      void reportError(error);
    },
  };
}

function field(request: CallableRequest, name: string): unknown {
  const data: unknown = request.data;
  return typeof data === "object" && data !== null ? (data as Record<string, unknown>)[name] : undefined;
}

/** Logs unexpected errors (never the request data) and converts them. */
function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, { map: [classesMapper([OtpError, ConsentError], toHttpsError)] });
}

const signInOptions = {
  enforceAppCheck: ENFORCE_APP_CHECK,
  minInstances: MIN_INSTANCES_SIGNIN,
  secrets: [OTP_HMAC_KEY, WHATSAPP_ACCESS_TOKEN],
};

/**
 * { phone, deviceId, language } -> { expiresInSeconds, resendAfterSeconds }
 *
 * Prompt 12 (review 2, item 5): App Check replay protection. The app sends
 * a limited-use token that is consumed here, so one captured token cannot
 * be replayed to send many paid WhatsApp codes.
 */
export const requestCode = onCall({ ...signInOptions, consumeAppCheckToken: true }, (request) =>
  run("requestCode", async () => {
    const deps = otpDeps();
    const ip = clientIp(request.rawRequest.headers, request.rawRequest.ip, CLIENT_IP_HOP.value());
    if (appEnv() !== "prod") {
      // A hash prefix, not the IP: lets the owner check that two networks
      // give two different keys (SETUP.md 11.7).
      logger.info("requestCode", { ipKeyPrefix: ipKey(deps.hmacKey, ip).slice(0, 10) });
    }
    return requestCodeFlow(deps, {
      phone: field(request, "phone"),
      deviceId: field(request, "deviceId"),
      ip,
      language: asLanguage(field(request, "language")),
    });
  }),
);

/**
 * { phone, code, deviceId, language, platform? } -> { token, newDevice, freshSelfieRequired }
 *
 * Prompt 12: every sign-in is recorded (users/{uid}/devices, logins). A
 * sign-in from a new phone signs the other phones out, emails the parent
 * and, for a verified parent, asks for a fresh selfie before chats, the
 * wallet and child data open (privacy/devices.ts).
 */
export const verifyCode = onCall(signInOptions, (request) =>
  run("verifyCode", async () => {
    const result = await verifyCodeFlow(otpDeps(), {
      phone: field(request, "phone"),
      code: field(request, "code"),
      deviceId: field(request, "deviceId"),
      language: asLanguage(field(request, "language")),
    });
    const device = await afterSignIn(result.uid, field(request, "deviceId"), field(request, "platform"));
    return { token: result.token, newDevice: device.newDevice, freshSelfieRequired: device.freshSelfieRequired };
  }),
);

/**
 * Copies a confirmed email from Firebase Auth to the user record. The app
 * sends the link with verifyBeforeUpdateEmail; Auth sets emailVerified only
 * after the parent opens it. Opening the link changes the account's email,
 * and Firebase then revokes the app's session, so a verified answer also
 * carries a fresh custom token for the app to sign in with again, but only
 * on the change to confirmed.
 * {} -> { verified, token? }
 */
export const confirmEmail = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("confirmEmail", async () => {
    const uid = requireUid(request);
    const auth = adminAuth();
    const email = verifiedEmail(await auth.getUser(uid));
    if (!email) return { verified: false };
    const ref = adminDb().collection(USERS).doc(uid);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("failed-precondition", "No account record.");
    if (snap.get("status") === "suspended") throw new HttpsError("permission-denied", "suspended", { reason: "suspended" });
    // Only the change to "confirmed" writes and mints a token; a repeat
    // call (the app checks on open and on resume) gets no token.
    if (!emailConfirmationIsNew({ email: snap.get("email"), emailVerified: snap.get("emailVerified") }, email)) {
      return { verified: true };
    }
    await ref.update({ email, emailVerified: true, updatedAt: FieldValue.serverTimestamp() });
    return { verified: true, token: await auth.createCustomToken(uid) };
  }),
);

/** { documents: { terms, privacy, conduct: version }, whatsapp } -> { ok } */
export const acceptConsents = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("acceptConsents", async () => {
    const uid = requireUid(request);
    const parsed = parseConsentRequest(request.data);
    const snap = await adminDb().collection(USERS).doc(uid).get();
    if (!snap.exists) throw new HttpsError("failed-precondition", "No account record.");
    // Prompt 12 (review 2, item 7): the email step comes first on the
    // server too, and a repeated call for the same terms version records
    // nothing again (consent changes later go through the privacy screen).
    if (snap.get("emailVerified") !== true) throw new HttpsError("failed-precondition", "email-first", { reason: "email-first" });
    if (snap.get("termsAcceptedAt") && snap.get("termsVersion") === CONSENT_VERSIONS.terms) return { ok: true };
    await recordConsents(adminDb(), uid, parsed);
    return { ok: true };
  }),
);
