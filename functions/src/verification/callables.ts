import * as logger from "firebase-functions/logger";
import { onInit } from "firebase-functions/v2";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { adminAuth, adminDb, adminStorage } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import {
  ENFORCE_APP_CHECK,
  KYC_PROVIDER,
  NATIONAL_ID_HMAC_KEY,
  VALIFY_BASE_URL,
  VALIFY_BUNDLE_KEY,
  VALIFY_CLIENT_ID,
  VALIFY_CLIENT_SECRET_NAME,
  VALIFY_ENABLED,
  VALIFY_PASSWORD_NAME,
  VALIFY_USERNAME,
  appEnv,
} from "../config";
import { reportError } from "../sentry";
import {
  decideVerification as decideFlow,
  openVerificationCase as openFlow,
  removeChild as removeChildFlow,
  withdrawVerification as withdrawFlow,
  submitVerification as submitFlow,
  type VerificationDeps,
} from "./flow";
import { createKycProvider, kycConfigProblem, type KycProvider } from "./kyc";
import { CloudStorageFiles, FirebaseClaimsService, FirestoreVerificationStore, readFakeKycSetting } from "./store";
import { VerificationError, type VerificationErrorReason } from "./submission";
import { gatedCall, realParentCall } from "../privacy/device_gate";

/**
 * Callable functions for verification (F2, F3, F18) and the daily
 * retention job. Errors carry `details.reason` (and `missing` for uploads
 * that are not there) so the app can say what to fix.
 */

/** Used only by the local emulators when no NATIONAL_ID_HMAC_KEY is set. Not a secret. */
const EMULATOR_ONLY_NATIONAL_ID_KEY = "emulator-only-national-id-key-not-for-cloud";

const ERROR_CODES: Record<VerificationErrorReason, FunctionsErrorCode> = {
  "invalid-request": "invalid-argument",
  "no-account": "failed-precondition",
  "signup-incomplete": "failed-precondition",
  suspended: "permission-denied",
  "case-open": "failed-precondition",
  "invalid-name": "invalid-argument",
  "invalid-national-id": "invalid-argument",
  "invalid-expiry": "invalid-argument",
  "id-expired": "invalid-argument",
  "invalid-child": "invalid-argument",
  "unknown-school": "failed-precondition",
  "invalid-driver": "invalid-argument",
  "license-expired": "invalid-argument",
  "missing-children": "invalid-argument",
  "too-many-children": "invalid-argument",
  "outdated-consent": "failed-precondition",
  "missing-upload": "failed-precondition",
  "duplicate-id": "already-exists",
  "banned-id": "permission-denied",
  "not-found": "not-found",
  "already-decided": "failed-precondition",
  "invalid-decision": "invalid-argument",
  "own-case": "permission-denied",
  "name-check-missing": "failed-precondition",
  "not-admin": "permission-denied",
  "reason-required": "failed-precondition",
};

export function toVerificationHttpsError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error;
  if (error instanceof VerificationError) {
    return new HttpsError(ERROR_CODES[error.reason], error.reason, { reason: error.reason, ...error.details });
  }
  return new HttpsError("internal", "Something went wrong.");
}

// Loud at instance start: a prod deploy with the fake ID check logs an
// error and reports to Sentry on every cold start, and submissions answer
// "failed-precondition" instead of a generic error.
onInit(async () => {
  const problem = kycConfigProblem(KYC_PROVIDER.value(), appEnv());
  if (problem) {
    logger.error(`CONFIGURATION ERROR: ${problem}`);
    await reportError(new Error(problem));
  }
});

function nationalIdKey(): string {
  const key = NATIONAL_ID_HMAC_KEY.value();
  if (key) return key;
  if (process.env.FUNCTIONS_EMULATOR === "true") return EMULATOR_ONLY_NATIONAL_ID_KEY;
  logger.error("NATIONAL_ID_HMAC_KEY is not set");
  throw new HttpsError("internal", "Verification is not configured.");
}

function onError(error: unknown): void {
  // Never the request data: it holds names and the ID number.
  logger.error("verification step failed", { message: error instanceof Error ? error.message : "unknown" });
  void reportError(error);
}

/** Stands in where no check runs (admin calls), so a prod KYC setting cannot break them. */
const NO_KYC: KycProvider = {
  kind: "none",
  check: () => Promise.reject(new Error("No KYC check outside submitVerification.")),
};

/** Like createKycProvider, but a bad setting answers "failed-precondition" (logged at startup too). */
function kycProvider(options: Parameters<typeof createKycProvider>[0]): KycProvider {
  try {
    return createKycProvider(options);
  } catch (error) {
    logger.error("KYC provider is misconfigured", { message: error instanceof Error ? error.message : "unknown" });
    throw new HttpsError("failed-precondition", "The ID check is not configured.", { reason: "kyc-misconfigured" });
  }
}

/** [forSubmit]: also the ID hash key and the KYC provider. */
function deps(forSubmit: boolean): VerificationDeps {
  const db = adminDb();
  return {
    store: new FirestoreVerificationStore(db),
    files: new CloudStorageFiles(adminStorage().bucket()),
    kyc: !forSubmit ? NO_KYC : kycProvider({
      provider: KYC_PROVIDER.value(),
      appEnv: appEnv(),
      fakeSetting: () => readFakeKycSetting(db),
      valify: {
        enabled: VALIFY_ENABLED.value(),
        baseUrl: VALIFY_BASE_URL.value(),
        username: VALIFY_USERNAME.value(),
        clientId: VALIFY_CLIENT_ID.value(),
        clientSecret: process.env[VALIFY_CLIENT_SECRET_NAME] ?? "",
        password: process.env[VALIFY_PASSWORD_NAME] ?? "",
        bundleKey: VALIFY_BUNDLE_KEY.value(),
      },
    }),
    claims: new FirebaseClaimsService(adminAuth()),
    nationalIdKey: forSubmit ? nationalIdKey() : "",
    now: () => Date.now(),
    reportError: onError,
  };
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (!(error instanceof VerificationError || error instanceof HttpsError)) {
      logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
    throw toVerificationHttpsError(error);
  }
}

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return uid;
}

/**
 * Admins carry the "admin" custom claim (set only by a super admin or the
 * bootstrap script), signed in with a second factor, within the session
 * limit (admin_panel/guard.ts).
 */
export async function requireAdmin(request: CallableRequest): Promise<string> {
  return (await requireAdminCaller(request)).uid;
}

const options = { enforceAppCheck: ENFORCE_APP_CHECK, secrets: [NATIONAL_ID_HMAC_KEY], timeoutSeconds: 120 };

/**
 * Parent: submit documents for review.
 * { identity?, children: [...], driver?, consents } -> { caseId }
 * The images must already be in verification/{uid}/pending/.
 */
// Not for App Review demo parents: they hold fake data only and are never sent to the ID review.
export const submitVerification = realParentCall(options, (request) =>
  run("submitVerification", () => submitFlow(deps(true), requireUid(request), request.data)),
);

/** Parent: remove a child (F3). { childId } -> { ok } */
export const removeChild = gatedCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("removeChild", async () => {
    await removeChildFlow(deps(false), requireUid(request), request.data);
    return { ok: true };
  }),
);

/** Parent: withdraw the case waiting for review (releases the ID claim). { caseId } -> { ok } */
export const withdrawVerification = gatedCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("withdrawVerification", async () => {
    await withdrawFlow(deps(false), requireUid(request), request.data);
    return { ok: true };
  }),
);

/** Admin: oldest cases first. {} -> { cases: [...] } */
export const listVerificationQueue = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("listVerificationQueue", async () => {
    await requireAdmin(request);
    return { cases: await deps(false).store.queue(50) };
  }),
);

/** Admin: one case with 5-minute image links; the view is logged. { caseId } -> case */
export const openVerificationCase = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("openVerificationCase", async () => openFlow(deps(false), await requireAdmin(request), request.data, ipOf(request))),
);

/**
 * Admin: approve or reject. The only way an account becomes verified and
 * gets the "verified" claim.
 * { caseId, decision: "approve" | "reject", nameCheck?, reasonCode?, note?, ban? } -> { status }
 * nameCheck ("match" | "birth_certificate") is required to approve a case with children.
 */
export const decideVerification = onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) =>
  run("decideVerification", async () => decideFlow(deps(false), await requireAdmin(request), request.data, ipOf(request))),
);

// Prompt 12: the daily image purge runs inside retentionDaily (privacy/callables.ts).
