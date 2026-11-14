import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableOptions, type CallableRequest } from "firebase-functions/v2/https";
import { adminDb } from "../admin";
import { requireNoDeviceCheck, requireValidSession } from "../privacy/device_gate";
import { FeatureCache, FEATURES_DOC, type FeatureKey, type FeatureReader, type FeatureSwitches } from "./model";

/**
 * The feature switches for Cloud Functions (model.ts). One cache per
 * function instance; the gate runs FIRST in a gated callable (before the
 * session and device checks), so a switched-off feature costs at most one
 * cached read and never touches the feature's own records.
 */

const firestoreReader: FeatureReader = async () => (await adminDb().doc(FEATURES_DOC).get()).data();

function newCache(read: FeatureReader): FeatureCache {
  return new FeatureCache(read, undefined, undefined, (error) =>
    logger.warn("feature switches not read; using the last known or pilot values", { message: error instanceof Error ? error.message : "unknown" }),
  );
}

let cache = newCache(firestoreReader);

/** Tests only: answer from [read] instead of Firestore (null restores Firestore). */
export function setFeatureReaderForTests(read: FeatureReader | null): void {
  cache = newCache(read ?? firestoreReader);
}

export function features(): Promise<FeatureSwitches> {
  return cache.get();
}

export function featureOn(key: FeatureKey): Promise<boolean> {
  return cache.isOn(key);
}

/** After adminSetFeature on this instance. */
export function clearFeatureCache(): void {
  cache.clear();
}

/** The error every gated callable throws while its feature is off. */
export function featureOffError(feature: FeatureKey): HttpsError {
  return new HttpsError("failed-precondition", "feature-off", { reason: "feature-off", feature });
}

/** Throws "feature-off" (failed-precondition, details.reason and details.feature) when [key] is off. */
export async function requireFeature(key: FeatureKey): Promise<void> {
  if (!(await cache.isOn(key))) throw featureOffError(key);
}

/** gatedCall (valid session, no open new-phone check) behind the switch of [key]. */
export function featureGatedCall<T>(key: FeatureKey, options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireFeature(key);
    await requireNoDeviceCheck(request.auth);
    return handler(request);
  });
}

/** sessionCall (valid session only) behind the switch of [key]. */
export function featureSessionCall<T>(key: FeatureKey, options: CallableOptions, handler: (request: CallableRequest) => T | Promise<T>) {
  return onCall(options, async (request: CallableRequest) => {
    await requireFeature(key);
    await requireValidSession(request.auth);
    return handler(request);
  });
}

/** A scheduled job or trigger of [key]: true when it must do nothing (logged once per run, no data). */
export async function skipWhenOff(key: FeatureKey, name: string): Promise<boolean> {
  if (await cache.isOn(key)) return false;
  logger.debug("skipped: feature off", { name, feature: key });
  return true;
}
