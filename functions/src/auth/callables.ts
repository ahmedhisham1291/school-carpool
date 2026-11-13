import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminAuth, adminDb } from "../admin";
import {
  ENFORCE_APP_CHECK,
  MIN_INSTANCES_SIGNIN,
  OTP_HMAC_KEY,
  WHATSAPP_ACCESS_TOKEN,
  WHATSAPP_API_VERSION,
  WHATSAPP_CODE_TEMPLATE,
  WHATSAPP_PHONE_NUMBER_ID,
  WHATSAPP_PROVIDER,
  WHATSAPP_TEMPLATE_LANG_AR,
  WHATSAPP_TEMPLATE_LANG_EN,
} from "../config";
import { reportError } from "../sentry";
import { asLanguage, createWhatsAppSender, type WhatsAppSender } from "../whatsapp/sender";
import { FirebaseAccountService, USERS } from "./accounts";
import { ConsentError, parseConsentRequest, recordConsents } from "./consents";
import { OtpError, requestCode as requestCodeFlow, verifyCode as verifyCodeFlow, type OtpDeps, type OtpErrorReason } from "./otp_flow";
import { FirestoreOtpStore } from "./otp_store";

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

/**
 * Client IP for the per-IP limit. On Cloud Run the platform appends the
 * address it sees as the last X-Forwarded-For entry; a caller can only add
 * entries before it. Falls back to the socket address (emulator).
 */
export function clientIp(headers: Record<string, string | string[] | undefined>, fallback?: string): string {
  const raw = headers["x-forwarded-for"];
  const joined = Array.isArray(raw) ? raw.join(",") : (raw ?? "");
  const parts = joined
    .split(",")
    .map((part) => part.trim())
    .filter((part) => part.length > 0);
  return parts.length > 0 ? parts[parts.length - 1] : (fallback ?? "unknown");
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
      appEnv: process.env.APP_ENV ?? "dev",
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

function otpDeps(): OtpDeps {
  const db = adminDb();
  return {
    store: new FirestoreOtpStore(db),
    sender: whatsAppSender(),
    accounts: new FirebaseAccountService(adminAuth(), db),
    hmacKey: otpHmacKey(),
    now: () => Date.now(),
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
async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (!(error instanceof OtpError || error instanceof ConsentError || error instanceof HttpsError)) {
      logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
    throw toHttpsError(error);
  }
}

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return uid;
}

const signInOptions = {
  enforceAppCheck: ENFORCE_APP_CHECK,
  minInstances: MIN_INSTANCES_SIGNIN,
  secrets: [OTP_HMAC_KEY, WHATSAPP_ACCESS_TOKEN],
};

/** { phone, deviceId, language } -> { expiresInSeconds, resendAfterSeconds } */
export const requestCode = onCall(signInOptions, (request) =>
  run("requestCode", () =>
    requestCodeFlow(otpDeps(), {
      phone: field(request, "phone"),
      deviceId: field(request, "deviceId"),
      ip: clientIp(request.rawRequest.headers, request.rawRequest.ip),
      language: asLanguage(field(request, "language")),
    }),
  ),
);

/** { phone, code, language } -> { token } (a Firebase custom token) */
export const verifyCode = onCall(signInOptions, (request) =>
  run("verifyCode", async () => {
    const result = await verifyCodeFlow(otpDeps(), {
      phone: field(request, "phone"),
      code: field(request, "code"),
      language: asLanguage(field(request, "language")),
    });
    return { token: result.token };
  }),
);

/**
 * Copies a confirmed email from Firebase Auth to the user record. The app
 * sends the confirmation link with verifyBeforeUpdateEmail; Auth sets
 * emailVerified only after the parent opens the link.
 * {} -> { verified }
 */
export const confirmEmail = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("confirmEmail", async () => {
    const uid = requireUid(request);
    const user = await adminAuth().getUser(uid);
    if (!user.email || !user.emailVerified) return { verified: false };
    const ref = adminDb().collection(USERS).doc(uid);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("failed-precondition", "No account record.");
    await ref.update({ email: user.email, emailVerified: true, updatedAt: FieldValue.serverTimestamp() });
    return { verified: true };
  }),
);

/** { documents: { terms, privacy, conduct: version }, whatsapp } -> { ok } */
export const acceptConsents = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("acceptConsents", async () => {
    const uid = requireUid(request);
    const parsed = parseConsentRequest(request.data);
    const snap = await adminDb().collection(USERS).doc(uid).get();
    if (!snap.exists) throw new HttpsError("failed-precondition", "No account record.");
    await recordConsents(adminDb(), uid, parsed);
    return { ok: true };
  }),
);
