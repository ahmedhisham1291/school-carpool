import { randomBytes, randomInt } from "node:crypto";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, onRequest, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { adminDb, adminStorage } from "../admin";
import { deps as carpoolDeps } from "../carpools/callables";
import {
  ENFORCE_APP_CHECK,
  MAPS_SERVER_KEY,
  MIN_INSTANCES,
  ROUTES_PROVIDER,
  ROUTES_TRAFFIC,
  TRIP_HANDOVER_MIN,
  TRIP_SELFIE_PERCENT,
  TRIP_STALE_SEC,
  WHATSAPP_ACCESS_TOKEN,
  WHATSAPP_API_VERSION,
  WHATSAPP_CODE_TEMPLATE,
  WHATSAPP_PHONE_NUMBER_ID,
  WHATSAPP_PROVIDER,
  WHATSAPP_TEMPLATE_LANG_AR,
  WHATSAPP_TEMPLATE_LANG_EN,
} from "../config";
import { CAIRO_TZ } from "../schedule/cairo";
import { pauseDriverRuns } from "../schedule/pause";
import { reportError } from "../sentry";
import { createKycProvider, type FaceMatcher as KycFaceMatcher } from "../verification/kyc";
import { CloudStorageFiles, readFakeKycSetting } from "../verification/store";
import { createWhatsAppSender } from "../whatsapp/sender";
import {
  confirmHandover as confirmFlow,
  emergency as emergencyFlow,
  getHandoverAdults as getHandoverFlow,
  prepareTrip as prepareFlow,
  quickMessage as quickFlow,
  runTripTick,
  saveHandoverAdults as saveHandoverFlow,
  setEmergencyContact as contactFlow,
  startTrip as startFlow,
  submitSelfieCheck as selfieFlow,
  todayDriverCards,
  tripAction as actionFlow,
  uploadPoints,
  type Caller,
  type TripDeps,
} from "./flow";
import { TRIP_ERROR_CODES, TripError, tripSettings } from "./model";
import { createRoutesProvider } from "./routes";
import { FirestoreTripStore } from "./store";

/**
 * Trip callables (Prompt 10). Every trip write happens here. Logs carry
 * counts and reasons only: never names, phone numbers or coordinates.
 * No warm instances (COST MODE): MIN_INSTANCES, 0 by default.
 */

function tripDeps(): TripDeps {
  const db = adminDb();
  const appEnv = process.env.APP_ENV ?? "dev";
  const kyc = createKycProvider({
    provider: process.env.KYC_PROVIDER ?? "fake",
    appEnv,
    fakeSetting: () => readFakeKycSetting(db),
    valify: { enabled: false, baseUrl: "", username: "", clientId: "", clientSecret: "", password: "", bundleKey: "" },
  }) as unknown as KycFaceMatcher;
  const phoneNumberId = WHATSAPP_PHONE_NUMBER_ID.value();
  const carpools = carpoolDeps();
  return {
    store: new FirestoreTripStore(db),
    files: new CloudStorageFiles(adminStorage().bucket()),
    faces: { matchFace: (reference, live) => kyc.matchFace(reference, live) },
    // Built when used: the Maps key and the WhatsApp token are bound only
    // to the functions that need them (tripLocation, tripEmergency).
    routes: {
      kind: ROUTES_PROVIDER.value() === "google" ? "google" : "fake",
      legs: (origin, waypoints) =>
        createRoutesProvider(ROUTES_PROVIDER.value(), appEnv, () => MAPS_SERVER_KEY.value(), ROUTES_TRAFFIC.value()).legs(origin, waypoints),
    },
    whatsapp: {
      sendTemplate: (to, template, language, params, preview) =>
        createWhatsAppSender(
          {
            provider: WHATSAPP_PROVIDER.value(),
            appEnv,
            meta: {
              accessToken: WHATSAPP_ACCESS_TOKEN.value(),
              phoneNumberId: phoneNumberId === "none" ? "" : phoneNumberId,
              apiVersion: WHATSAPP_API_VERSION.value(),
              templateName: WHATSAPP_CODE_TEMPLATE.value(),
              templateLanguages: { ar: WHATSAPP_TEMPLATE_LANG_AR.value(), en: WHATSAPP_TEMPLATE_LANG_EN.value() },
            },
          },
          (message) => logger.info(message),
        ).sendTemplate(to, template, language, params, preview),
    },
    // Prompt 9's pause release: every run the driver drives from today on.
    releaseRuns: async (uid) => (await pauseDriverRuns(carpools, uid)).runs,
    now: () => Date.now(),
    newToken: () => randomBytes(32).toString("base64url"),
    roll: () => randomInt(0, 100),
    settings: tripSettings(TRIP_STALE_SEC.value(), TRIP_SELFIE_PERCENT.value(), TRIP_HANDOVER_MIN.value()),
    log: (message, data) => logger.info(message, data ?? {}),
  };
}

function caller(request: CallableRequest): Caller {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
  return { uid, verifiedClaim: request.auth?.token?.verified === true };
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof TripError) {
      throw new HttpsError(TRIP_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
    }
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK };
const withSecrets = { enforceAppCheck: ENFORCE_APP_CHECK, secrets: [WHATSAPP_ACCESS_TOKEN] };

/** F38: { carpoolId, runId } -> { tripId, selfieRequired, selfieStatus, active } */
export const prepareTrip = onCall(opts, (r) => run("prepareTrip", () => prepareFlow(tripDeps(), caller(r), r.data)));

/** F38: { carpoolId, runId } -> { status } (after uploading selfieChecks/{uid}/{tripId}.jpg) */
export const submitSelfieCheck = onCall(opts, (r) => run("submitSelfieCheck", () => selfieFlow(tripDeps(), caller(r), r.data)));

/** F15: { carpoolId, runId } -> { tripId, token, expiresAtMs, staleSeconds } */
export const startTrip = onCall(opts, (r) => run("startTrip", () => startFlow(tripDeps(), caller(r), r.data)));

/** F16, F41: { carpoolId, runId, childId, action, requestId? } -> { state, status, applied } */
export const tripAction = onCall(opts, (r) => run("tripAction", () => actionFlow(tripDeps(), caller(r), r.data)));

/** F34: { carpoolId, runId, childId } -> { status } (the receiving parent) */
export const confirmHandover = onCall(opts, (r) => run("confirmHandover", () => confirmFlow(tripDeps(), caller(r), r.data)));

/** F35: { carpoolId, runId, kind, requestId? } -> { posted } */
export const quickMessage = onCall(opts, (r) => run("quickMessage", () => quickFlow(tripDeps(), caller(r), r.data)));

/** F20: { carpoolId, runId, point? } -> { emergencyId, contactSent, members } */
export const tripEmergency = onCall(withSecrets, (r) => run("tripEmergency", () => emergencyFlow(tripDeps(), caller(r), r.data)));

/** F29: { childId, adults: [{ name, relation, phone? }] } -> { adults } */
export const saveHandoverAdults = onCall(opts, (r) => run("saveHandoverAdults", () => saveHandoverFlow(tripDeps(), caller(r), r.data)));

/** F29: { childId } -> { adults } (the parent's own list) */
export const getHandoverAdults = onCall(opts, (r) => run("getHandoverAdults", () => getHandoverFlow(tripDeps(), caller(r), r.data)));

/** F20: { name, phone, relation } or { clear: true } -> { saved } */
export const setEmergencyContact = onCall(opts, (r) => run("setEmergencyContact", () => contactFlow(tripDeps(), caller(r), r.data)));

/** F33: { carpoolId } -> { date, cards } */
export const getTodayDriverCards = onCall(opts, (r) => run("getTodayDriverCards", () => todayDriverCards(tripDeps(), caller(r), r.data)));

/**
 * F15: live points from the driver's phone. The location plugin posts here
 * by itself (also with the phone locked) with `Authorization: Bearer
 * <token of this trip>` and `?trip=<tripId>`. 401: wrong token; 410: the
 * run is over, so the app stops tracking. App Check cannot run here (the
 * plugin's native uploader); the token is a 256-bit secret for one live
 * trip, stored only as a hash.
 */
export const tripLocation = onRequest({ minInstances: MIN_INSTANCES, timeoutSeconds: 30, maxInstances: 10, concurrency: 80, secrets: [MAPS_SERVER_KEY] }, async (req, res) => {
  try {
    if (req.method !== "POST") {
      res.status(405).json({ error: "method" });
      return;
    }
    const auth = req.headers.authorization;
    const header = Array.isArray(auth) ? auth[0] : auth;
    const token = typeof header === "string" && header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    const trip = typeof req.query.trip === "string" ? req.query.trip : "";
    const result = await uploadPoints(tripDeps(), trip, token, req.body);
    res.status(result.status).json({ accepted: result.accepted });
  } catch (error) {
    logger.error("tripLocation failed", { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    // 500: the plugin keeps the points and tries again later.
    res.status(500).json({ error: "internal" });
  }
});

/**
 * Every minute, Cairo time: "location stopped", "child not confirmed"
 * (F34), forgotten runs, and deleting live points within 24 hours.
 */
export const tripTick = onSchedule(
  { schedule: "every 1 minutes", timeZone: CAIRO_TZ, retryCount: 0, timeoutSeconds: 120, minInstances: MIN_INSTANCES },
  async () => {
    try {
      const result = await runTripTick(tripDeps());
      if (result.stale + result.notConfirmed + result.ended + result.deleted > 0) logger.info("trip tick", { ...result });
    } catch (error) {
      logger.error("trip tick failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);
