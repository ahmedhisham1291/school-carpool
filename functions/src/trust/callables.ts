import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { adminAuth, adminDb, adminStorage } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { AdminError, ADMIN_ERROR_CODES } from "../admin_panel/errors";
import { otpDeps, toHttpsError as otpHttpsError } from "../auth/callables";
import { clientIp } from "../auth/client_ip";
import { OtpError } from "../auth/otp_flow";
import { deps as carpoolDeps } from "../carpools/callables";
import { carInfo } from "../carpools/model";
import {
  CLIENT_IP_HOP,
  ENFORCE_APP_CHECK,
  LICENCE_REMINDER_DAYS,
  MIN_INSTANCES,
  OTP_HMAC_KEY,
  REGION,
  SCHOOL_YEAR_START,
  TRUST_RATE_WINDOW_DAYS,
  WHATSAPP_ACCESS_TOKEN,
  YEAR_CHECK_FIRST_YEAR,
  YEAR_CHECK_GRACE_DAYS,
  YEAR_CHECK_OPEN_DAYS,
} from "../config";
import { refresh as refreshParentMap } from "../maps/callables";
import { CAIRO_TZ } from "../schedule/cairo";
import { reportError } from "../sentry";
import { faceMatcher } from "../verification/face_match";
import { faceRefPath } from "../verification/submission";
import { usableVehicle } from "../verification/vehicle";
import { asLanguage } from "../whatsapp/sender";
import { applyCarChange } from "./carpools";
import {
  adminDecideGuardianLink as adminDecideFlow,
  adminResolveRatingFlag as adminResolveFlow,
  adminTrustQueue as adminQueueFlow,
  answerGuardianRequest as answerFlow,
  cancelGuardianRequest as cancelFlow,
  confirmSchoolYear as confirmYearFlow,
  getFamily as familyFlow,
  getTrustOverview as overviewFlow,
  getTrustSummary as summaryFlow,
  listRateable as rateableFlow,
  rateParent as rateFlow,
  removeGuardianLink as removeLinkFlow,
  requestGuardianLink as requestLinkFlow,
  type Caller,
  type TrustDeps,
} from "./flow";
import { releaseOnBlock, runTrustDaily } from "./jobs";
import { parseReminderDays, TRUST_ERROR_CODES, TrustError, yearSettings } from "./model";
import { confirmPhoneChange as confirmPhoneFlow, phoneChangeKey, requestPhoneChange as requestPhoneFlow, type PhoneChangeDeps, type PhoneFiles } from "./phone";
import { FirestoreTrustStore } from "./store";
import { noteAbuse } from "../privacy/abuse_hook";
import { gatedCall } from "../privacy/device_gate";

/**
 * Trust functions (Prompt 11, F17). The app reads and writes nothing of
 * trust in Firestore: everything goes through these. Logs carry counts and
 * reasons only (never names, phone numbers or photos). minInstances 0
 * (COST MODE).
 */

function trustDeps(): TrustDeps {
  return {
    store: new FirestoreTrustStore(adminDb()),
    carpools: carpoolDeps(),
    now: () => Date.now(),
    rateWindowDays: TRUST_RATE_WINDOW_DAYS.value(),
    year: yearSettings(SCHOOL_YEAR_START.value(), YEAR_CHECK_OPEN_DAYS.value(), YEAR_CHECK_GRACE_DAYS.value(), YEAR_CHECK_FIRST_YEAR.value()),
  };
}

function caller(request: CallableRequest): Caller {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return { uid, verifiedClaim: request.auth?.token?.verified === true };
}

function toHttpsError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error;
  if (error instanceof TrustError) {
    return new HttpsError(TRUST_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason, retryAfterMs: error.retryAfterMs });
  }
  if (error instanceof OtpError) return otpHttpsError(error);
  if (error instanceof AdminError) {
    return new HttpsError(ADMIN_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason, ...error.details });
  }
  return new HttpsError("internal", "Something went wrong.");
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (!(error instanceof TrustError || error instanceof OtpError || error instanceof AdminError || error instanceof HttpsError)) {
      // Never the request data: it may hold a phone number.
      logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
    }
    throw toHttpsError(error);
  }
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK, minInstances: MIN_INSTANCES };

// Ratings and vouching ----------------------------------------------------

/** {} -> { summary, toRate, yearCheck, requests } (Profile) */
export const getTrustOverview = gatedCall(opts, (r) => run("getTrustOverview", () => overviewFlow(trustDeps(), caller(r))));

/** {} -> { parents: [{ uid, firstName, role, date, carpoolId }], month } */
export const listRateable = gatedCall(opts, (r) => run("listRateable", () => rateableFlow(trustDeps(), caller(r))));

/** { uid, stars, tags?, vouch? } -> { rated, flagged } */
export const rateParent = gatedCall(opts, (r) => run("rateParent", () => rateFlow(trustDeps(), caller(r), r.data)));

/** { uid? } -> { ratings, average, vouches } (self, or a parent of a shared carpool) */
export const getTrustSummary = gatedCall(opts, (r) =>
  run("getTrustSummary", async () => {
    // Prompt 12: opening many other parents' profiles alerts the admins.
    const target = typeof r.data === "object" && r.data !== null ? (r.data as { uid?: unknown }).uid : undefined;
    if (typeof target === "string" && target !== caller(r).uid) await noteAbuse(caller(r).uid, "profiles", target.slice(0, 64));
    return summaryFlow(trustDeps(), caller(r), r.data);
  }),
);

// Yearly check --------------------------------------------------------------

/** { year, children: [{ childId, stays, grade? }] } -> { state, left } */
export const confirmSchoolYear = gatedCall(opts, (r) => run("confirmSchoolYear", () => confirmYearFlow(trustDeps(), caller(r), r.data)));

// Guardian links ------------------------------------------------------------

/** {} -> { incoming, outgoing, shared, linked } */
export const getFamily = gatedCall(opts, (r) => run("getFamily", () => familyFlow(trustDeps(), caller(r))));

/** { parentId, relation } -> { requestId, firstName } */
export const requestGuardianLink = gatedCall(opts, (r) => run("requestGuardianLink", () => requestLinkFlow(trustDeps(), caller(r), r.data)));

/** { requestId } -> { status } */
export const cancelGuardianRequest = gatedCall(opts, (r) => run("cancelGuardianRequest", () => cancelFlow(trustDeps(), caller(r), r.data)));

/** { requestId, accept, childIds? } -> { status, links } */
export const answerGuardianRequest = gatedCall(opts, (r) => run("answerGuardianRequest", () => answerFlow(trustDeps(), caller(r), r.data)));

/** { linkId } -> { status } */
export const removeGuardianLink = gatedCall(opts, (r) => run("removeGuardianLink", () => removeLinkFlow(trustDeps(), caller(r), r.data)));

// Phone change ----------------------------------------------------------------

class StoragePhoneFiles implements PhoneFiles {
  private readonly bucket = adminStorage().bucket();

  async createdMs(path: string): Promise<number | null> {
    const file = this.bucket.file(path);
    const [exists] = await file.exists();
    if (!exists) return null;
    const [meta] = await file.getMetadata();
    const created = Date.parse(String(meta.timeCreated ?? ""));
    return Number.isFinite(created) ? created : null;
  }

  async read(path: string): Promise<Buffer> {
    const [data] = await this.bucket.file(path).download();
    return data;
  }

  async delete(path: string): Promise<void> {
    await this.bucket.file(path).delete({ ignoreNotFound: true });
  }

  async exists(path: string): Promise<boolean> {
    const [exists] = await this.bucket.file(path).exists();
    return exists;
  }

  async copy(from: string, to: string): Promise<void> {
    await this.bucket.file(from).copy(this.bucket.file(to));
  }
}

function phoneDeps(): PhoneChangeDeps {
  const db = adminDb();
  const signIn = otpDeps();
  // The project's face match (Valify in prod), built per match.
  const kyc = faceMatcher();
  return {
    store: new FirestoreTrustStore(db, adminAuth()),
    files: new StoragePhoneFiles(),
    // Its own key: a sign-in code never changes a number, and the other way round.
    otp: { ...signIn, hmacKey: phoneChangeKey(signIn.hmacKey) },
    faces: { matchFace: (reference, live) => kyc.matchFace(reference, live) },
    faceRefPath,
    now: () => Date.now(),
    reportError: (error) => void reportError(error),
  };
}

const phoneOpts = { enforceAppCheck: ENFORCE_APP_CHECK, minInstances: MIN_INSTANCES, secrets: [OTP_HMAC_KEY, WHATSAPP_ACCESS_TOKEN] };

/** { phone, deviceId, language } -> { expiresInSeconds, resendAfterSeconds } (code to the NEW number) */
export const requestPhoneChange = gatedCall(phoneOpts, (r) =>
  run("requestPhoneChange", () => {
    const data: unknown = r.data;
    const language = asLanguage(typeof data === "object" && data !== null ? (data as Record<string, unknown>).language : undefined);
    return requestPhoneFlow(phoneDeps(), caller(r), data, clientIp(r.rawRequest.headers, r.rawRequest.ip, CLIENT_IP_HOP.value()) || "unknown", language);
  }),
);

/** { phone, code, deviceId } after uploading phoneChecks/{uid}/selfie.jpg -> { changed } */
export const confirmPhoneChange = gatedCall(phoneOpts, (r) => run("confirmPhoneChange", () => confirmPhoneFlow(phoneDeps(), caller(r), r.data)));

// Admin panel (F14) -------------------------------------------------------

function adminCall<T>(name: string, body: (adminUid: string, request: CallableRequest) => Promise<T>) {
  return onCall({ enforceAppCheck: ENFORCE_APP_CHECK }, (request) => run(name, async () => body((await requireAdminCaller(request)).uid, request)));
}

/** {} -> { links (waiting for review), flags (open rating flags) } */
export const adminTrustQueue = adminCall("adminTrustQueue", () => adminQueueFlow(trustDeps()));

/** { linkId, approve } -> { status } */
export const adminDecideGuardianLink = adminCall("adminDecideGuardianLink", (uid, r) => adminDecideFlow(trustDeps(), uid, r.data, ipOf(r)));

/** { flagId, outcome: no-issue | contacted | escalated } -> the flag */
export const adminResolveRatingFlag = adminCall("adminResolveRatingFlag", (uid, r) => adminResolveFlow(trustDeps(), uid, r.data, ipOf(r)));

// Triggers and the daily job ------------------------------------------------

/**
 * Spec section 6: a suspended or banned driver's runs become open for the
 * group to take; the group is told only "driver unavailable". Retried.
 */
export const releaseRunsOnUserBlock = onDocumentWritten({ document: "users/{uid}", region: REGION, retry: true }, async (event) => {
  const uid = (event.params as Record<string, string>).uid;
  try {
    const runs = await releaseOnBlock(carpoolDeps(), uid, event.data?.before?.data(), event.data?.after?.data());
    if (runs > 0) logger.info("runs released for a blocked account", { runs });
  } catch (error) {
    logger.error("releasing runs failed", { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw error;
  }
});

/**
 * Spec section 3, re-verify when the car changes: a new car waiting for
 * review, fewer seats or other dates. Runs the car can no longer carry
 * lose their driver; members' copies of the car follow.
 */
export const recheckRunsOnVehicleWrite = onDocumentWritten({ document: "vehicles/{uid}", region: REGION, retry: true }, async (event) => {
  const uid = (event.params as Record<string, string>).uid;
  const car = (d: Record<string, unknown> | undefined) => {
    const v = usableVehicle(d);
    return v ? carInfo({ status: v.status, seats: v.seats, licenseExpiry: v.licenseExpiry, carLicenseExpiry: v.carLicenseExpiry }) : null;
  };
  const before = car(event.data?.before?.data());
  const after = car(event.data?.after?.data());
  if (JSON.stringify(before) === JSON.stringify(after)) return;
  try {
    const runs = await applyCarChange(carpoolDeps(), uid, after);
    if (runs > 0) logger.info("runs released after a car change", { runs });
  } catch (error) {
    logger.error("car change failed", { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw error;
  }
});

/** A guardian link changed: the linked parent's map and school groups follow (Prompt 5 and 9). */
export const refreshOnGuardianLinkWrite = onDocumentWritten({ document: "guardianLinks/{id}", region: REGION, retry: false }, async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (before?.status === after?.status) return;
  const uid = typeof after?.guardianUid === "string" ? after.guardianUid : typeof before?.guardianUid === "string" ? before.guardianUid : null;
  if (uid) await refreshParentMap(uid);
});

/** Every morning, Cairo time: papers reminders and expiry, the yearly check. */
export const trustDaily = onSchedule(
  { schedule: "every day 08:10", timeZone: CAIRO_TZ, retryCount: 1, timeoutSeconds: 540, minInstances: MIN_INSTANCES },
  async () => {
    const d = trustDeps();
    const result = await runTrustDaily({
      store: new FirestoreTrustStore(adminDb()),
      carpools: d.carpools,
      now: d.now,
      reminderDays: parseReminderDays(LICENCE_REMINDER_DAYS.value()),
      year: d.year,
      log: (message, data) => logger.warn(message, data ?? {}),
    });
    logger.info("trust daily", { ...result });
  },
);
