import { randomBytes } from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { HttpsError, onCall, type CallableRequest, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onObjectDeleted, onObjectFinalized } from "firebase-functions/v2/storage";
import { adminAuth, adminDb, adminStorage } from "../admin";
import { ipOf, requireAdminCaller } from "../admin_panel/access";
import { AdminError, ADMIN_ERROR_CODES } from "../admin_panel/errors";
import { FirestoreListsStore } from "../admin_panel/store";
import { errorCode } from "../auth/accounts";
import { CONSENT_VERSIONS } from "../auth/consents";
import { removeFromCarpool } from "../carpools/flow";
import { deps as carpoolDeps } from "../carpools/callables";
import { server as chatServer } from "../chat/callables";
import { ENFORCE_APP_CHECK, MIN_INSTANCES, OTP_HMAC_KEY, REGION } from "../config";
import { mapDeps } from "../maps/callables";
import { updateMapSettings } from "../maps/parent_map";
import { CAIRO_TZ } from "../schedule/cairo";
import { reportError } from "../sentry";
import { endDriverTrips } from "../trips/flow";
import { tripDeps } from "../trips/callables";
import { leaveEmptyCarpools, removeChildFromCarpools } from "../trust/carpools";
import { faceMatcher } from "../verification/face_match";
import { purgeVerificationImages } from "../verification/flow";
import { CloudStorageFiles, FirestoreVerificationStore } from "../verification/store";
import { faceRefPath } from "../verification/submission";
import { walletProvider } from "../wallet/callables";
import { DeletionError, deleteAccount } from "./account_deletion";
import {
  adminDecideDeviceCheck,
  confirmNewDevice as confirmNewDeviceFlow,
  DEVICE_ERROR_CODES,
  DeviceDecisionError,
  DeviceError,
  recordSignIn,
  signOutDevice as signOutDeviceFlow,
  touchDevice as touchDeviceFlow,
  type DeviceDeps,
} from "./devices";
import { buildExport, EXPORT_LINK_MS, exportPath } from "./export";
import {
  FirestoreDeletionRunner,
  FirestoreDeviceStore,
  FirestoreExportSource,
  FirestoreMailOutbox,
  FirestorePrivacyStore,
  FirestoreRetentionStore,
  millis,
  ROUTE_ARCHIVES,
  SECURITY_ALERTS,
} from "./firestore_store";
import { runRetention } from "./jobs";
import { accessReason, selfieArchivePath, thumbPath } from "./photos";
import { dropThumb, ensureThumb } from "./thumbs";
import { consentKind, consentViews, correctionField, needsAdmin, newRequest, withdrawEffect, type PrivacyRequest } from "./requests";
import { routeArchivePurgeAt } from "./retention";
import { archivePath, packArchive, unpackArchive, type TrackPoint } from "./route_archive";
import { gatedCall, sessionCall } from "./device_gate";
import { featureOn } from "../features/gate";

/**
 * Privacy and security callables (Prompt 12, spec section 7). The app
 * reads none of these records directly: everything goes through here.
 * Logs carry codes and counts only (never names, numbers, coordinates,
 * photos or message text). minInstances 0 (COST MODE).
 */

/** Analytics consent version (the Settings switch text, Prompt 12). */
export const ANALYTICS_CONSENT_VERSION = "2026-11-14";

export type PrivacyErrorReason = "invalid-request" | "unauthenticated" | "not-found" | "wallet-not-empty" | "wallet-pending" | "wallet-unavailable" | "driving-now" | "no-account" | "rate-limited" | "export-failed";

const PRIVACY_ERROR_CODES: Record<PrivacyErrorReason, FunctionsErrorCode> = {
  "invalid-request": "invalid-argument",
  unauthenticated: "unauthenticated",
  "not-found": "not-found",
  "wallet-not-empty": "failed-precondition",
  "wallet-pending": "failed-precondition",
  "wallet-unavailable": "unavailable",
  "driving-now": "failed-precondition",
  "no-account": "failed-precondition",
  "rate-limited": "resource-exhausted",
  "export-failed": "unavailable",
};

function fail(reason: PrivacyErrorReason): never {
  throw new HttpsError(PRIVACY_ERROR_CODES[reason], reason, { reason });
}

function uidOf(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) fail("unauthenticated");
  return uid;
}

function data(request: CallableRequest): Record<string, unknown> {
  const d: unknown = request.data;
  return typeof d === "object" && d !== null ? (d as Record<string, unknown>) : {};
}

async function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    if (error instanceof DeviceError) throw new HttpsError(DEVICE_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason });
    if (error instanceof DeletionError) fail(error.reason);
    if (error instanceof AdminError) throw new HttpsError(ADMIN_ERROR_CODES[error.reason] as FunctionsErrorCode, error.reason, { reason: error.reason, ...error.details });
    logger.error(`${name} failed`, { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    throw new HttpsError("internal", "Something went wrong.");
  }
}

const bucket = () => adminStorage().bucket();
const opts = { enforceAppCheck: ENFORCE_APP_CHECK, minInstances: MIN_INSTANCES };
const newId = (): string => randomBytes(10).toString("hex");

function hmacKey(): string {
  const key = OTP_HMAC_KEY.value();
  if (key) return key;
  if (process.env.FUNCTIONS_EMULATOR === "true") return "emulator-only-otp-key-not-for-cloud";
  throw new HttpsError("internal", "Sign-in is not configured.");
}

/**
 * Signs every phone of [uid] out: refresh tokens revoked, and
 * users/{uid}.sessionsValidAfter set to the revocation time (seconds) so
 * firestore.rules and the gated callables refuse the old ID tokens at
 * once instead of when they expire (up to 1 hour).
 */
export async function revokeSessions(uid: string): Promise<void> {
  await adminAuth().revokeRefreshTokens(uid);
  const user = await adminAuth().getUser(uid);
  const validAfterMs = Date.parse(user.tokensValidAfterTime ?? "");
  const seconds = Math.floor((Number.isFinite(validAfterMs) ? validAfterMs : Date.now()) / 1000);
  await adminDb().collection("users").doc(uid).update({ sessionsValidAfter: seconds });
}

export function deviceDeps(): DeviceDeps {
  const db = adminDb();
  const files = new CloudStorageFiles(bucket());
  return {
    store: new FirestoreDeviceStore(db, bucket()),
    sessions: { revokeAll: revokeSessions, createToken: (uid) => adminAuth().createCustomToken(uid) },
    mailer: new FirestoreMailOutbox(db),
    files: {
      createdMs: async (path) => {
        const [exists] = await bucket().file(path).exists();
        if (!exists) return null;
        const [meta] = await bucket().file(path).getMetadata();
        const created = Date.parse(String(meta.timeCreated ?? ""));
        return Number.isFinite(created) ? created : null;
      },
      exists: (path) => files.exists(path),
      read: (path) => files.read(path),
      archive: async (path, to) => {
        await files.copy(path, to);
        await files.delete(path);
      },
    },
    faces: faceMatcher(),
    faceRefPath,
    selfieArchivePath,
    hmacKey: hmacKey(),
    now: () => Date.now(),
    newId,
    reportError: (error) => void reportError(error),
  };
}

/** Called by verifyCode after a right code (auth/callables.ts). Never fails the sign-in. */
export async function afterSignIn(uid: string, installId: unknown, platform: unknown): Promise<{ deviceKey: string | null; newDevice: boolean; freshSelfieRequired: boolean }> {
  try {
    return await recordSignIn(deviceDeps(), uid, installId, platform);
  } catch (error) {
    logger.error("sign-in record failed", { message: error instanceof Error ? error.message : "unknown" });
    await reportError(error);
    // FAIL CLOSED: we cannot tell whether this phone is new. A verified
    // parent (who has a face reference) is treated as on a new phone: the
    // other phones are signed out and a fresh selfie is asked for.
    try {
      const user = await adminDb().collection("users").doc(uid).get();
      if (user.get("status") === "verified") {
        await revokeSessions(uid);
        await adminDb().collection("users").doc(uid).update({ newDeviceCheck: { required: true, since: Timestamp.now() } });
        return { deviceKey: null, newDevice: true, freshSelfieRequired: true };
      }
    } catch (inner) {
      await reportError(inner);
      throw new HttpsError("unavailable", "Sign-in could not be recorded.");
    }
    return { deviceKey: null, newDevice: false, freshSelfieRequired: false };
  }
}

// --------------------------------------------------------------------------
// Devices and the new-phone check
// --------------------------------------------------------------------------

/** { deviceId, platform } -> { deviceKey, signedOut } (app start and resume) */
export const touchDevice = onCall({ ...opts, secrets: [OTP_HMAC_KEY] }, (r) => run("touchDevice", () => touchDeviceFlow(deviceDeps(), uidOf(r), r.data)));

/** { deviceId } -> { current: deviceKey, devices: [...], logins: [...] } */
export const listDevices = gatedCall({ ...opts, secrets: [OTP_HMAC_KEY] }, (r) =>
  run("listDevices", async () => {
    const uid = uidOf(r);
    const deps = deviceDeps();
    const current = await touchDeviceFlow(deps, uid, r.data);
    const store = deps.store as FirestoreDeviceStore;
    const devices = (await store.devices(uid)).sort((a, b) => b.lastSeenAtMs - a.lastSeenAtMs);
    return { current: current.deviceKey, devices, logins: await store.logins(uid) };
  }),
);

/** { deviceId, deviceKey } or { deviceId, all: true } -> { token } (the calling phone signs in again with it) */
export const signOutDevice = gatedCall({ ...opts, secrets: [OTP_HMAC_KEY] }, (r) =>
  run("signOutDevice", async () => {
    const uid = uidOf(r);
    const result = await signOutDeviceFlow(deviceDeps(), uid, r.data);
    await logRequest(uid, "withdraw", "device", "done", null);
    return result;
  }),
);

/** {} after uploading deviceChecks/{uid}/selfie.jpg -> { cleared, reviewed } */
export const confirmNewDevice = sessionCall({ ...opts, secrets: [OTP_HMAC_KEY] }, (r) => run("confirmNewDevice", () => confirmNewDeviceFlow(deviceDeps(), uidOf(r))));

// --------------------------------------------------------------------------
// The privacy screen
// --------------------------------------------------------------------------

async function logRequest(uid: string, kind: PrivacyRequest["kind"], subject: string | null, status: PrivacyRequest["status"], reason: string | null): Promise<PrivacyRequest> {
  const store = new FirestorePrivacyStore(adminDb());
  const nowMs = Date.now();
  const r: PrivacyRequest = { ...newRequest(store.newId(), uid, kind, subject, nowMs), status, reason, doneAtMs: status === "open" ? null : nowMs };
  await store.putRequest(r);
  return r;
}

const viewRequest = (r: PrivacyRequest) => ({ id: r.id, kind: r.kind, subject: r.subject, status: r.status, reason: r.reason, createdAtMs: r.createdAtMs, doneAtMs: r.doneAtMs });

/** {} -> { consents: [...], requests: [...] } */
export const getPrivacyOverview = gatedCall(opts, (r) =>
  run("getPrivacyOverview", async () => {
    const uid = uidOf(r);
    const store = new FirestorePrivacyStore(adminDb());
    const rows = await store.consents(uid);
    const analyticsRows = rows.filter((x) => x.type === "analytics").sort((a, b) => b.acceptedAtMs - a.acceptedAtMs);
    const analytics = analyticsRows.length > 0 ? analyticsRows[0].withdrawnAtMs === null : null;
    return {
      consents: consentViews(rows, { showOnMap: await store.showOnMap(uid), analytics }),
      requests: (await store.requests(uid, 30)).map(viewRequest),
    };
  }),
);

/** { kind, granted } -> { effect } ; every change is logged as a privacy request. */
export const setConsent = gatedCall(opts, (r) =>
  run("setConsent", async () => {
    const uid = uidOf(r);
    const raw = data(r);
    const kind = consentKind(raw.kind);
    if (!kind || typeof raw.granted !== "boolean") fail("invalid-request");
    const granted = raw.granted;
    const store = new FirestorePrivacyStore(adminDb());
    const nowMs = Date.now();
    if (granted) {
      if (kind !== "analytics" && kind !== "showOnMap" && kind !== "whatsapp") fail("invalid-request");
      if (kind === "analytics") await store.setConsent(uid, "analytics", ANALYTICS_CONSENT_VERSION, true, nowMs);
      else if (kind === "whatsapp") {
        await store.setConsent(uid, "whatsapp", CONSENT_VERSIONS.whatsapp, true, nowMs);
        await adminDb().collection("users").doc(uid).update({ whatsappOptIn: true });
      } else await updateMapSettings(mapDeps(), uid, { showOnMap: true });
      await logRequest(uid, "consent", kind, "done", null);
      return { effect: "granted" };
    }
    const effect = withdrawEffect(kind);
    switch (effect) {
      case "analyticsOff":
        await store.setConsent(uid, "analytics", ANALYTICS_CONSENT_VERSION, false, nowMs);
        break;
      case "whatsappOff":
        await store.setConsent(uid, "whatsapp", CONSENT_VERSIONS.whatsapp, false, nowMs);
        await adminDb().collection("users").doc(uid).update({ whatsappOptIn: false });
        break;
      case "hiddenFromMap":
        await updateMapSettings(mapDeps(), uid, { showOnMap: false });
        break;
      case "walletClosed": {
        const w = await adminDb().collection("wallets").doc(uid).get();
        const pending = await adminDb().collection("walletPending").where("uid", "==", uid).limit(1).get();
        // Pilot switch: while the wallet is off the partner is never called
        // (no money can have moved since the switch-off; our copy is used,
        // and an unknown balance refuses, never guesses 0).
        const walletOn = await featureOn("wallet");
        const copy = w.exists && typeof w.get("balanceCopy") === "number" ? (w.get("balanceCopy") as number) : null;
        const balance = !w.exists ? 0 : walletOn ? await walletProvider()?.balance(String(w.get("walletRef"))).catch(() => null) : copy;
        if (!pending.empty) {
          await logRequest(uid, "withdraw", kind, "refused", "wallet-pending");
          fail("wallet-pending");
        }
        if (balance !== 0 && w.exists) {
          await logRequest(uid, "withdraw", kind, "refused", "wallet-not-empty");
          fail("wallet-not-empty");
        }
        if (w.exists) await w.ref.update({ status: "closed", closedAt: Timestamp.fromMillis(nowMs) });
        await store.setConsent(uid, "walletTerms", "", false, nowMs);
        break;
      }
      default:
        // needsDeletion / needsChildRemoval: nothing withdrawn half way.
        await logRequest(uid, "withdraw", kind, "refused", effect);
        return { effect };
    }
    await logRequest(uid, "withdraw", kind, "done", null);
    return { effect };
  }),
);

/** { field } -> { request }: fields the app edits itself are done there; ID details go to an admin. */
export const requestCorrection = gatedCall(opts, (r) =>
  run("requestCorrection", async () => {
    const uid = uidOf(r);
    const field = correctionField(data(r).field);
    if (!field) fail("invalid-request");
    const req = await logRequest(uid, "correct", field, needsAdmin(field) ? "open" : "done", needsAdmin(field) ? null : "self-service");
    return { request: viewRequest(req) };
  }),
);

/** {} -> { request }: a copy of the parent's photos is sent by the privacy team (never a download link to ID images). */
export const requestPhotoCopy = gatedCall(opts, (r) =>
  run("requestPhotoCopy", async () => ({ request: viewRequest(await logRequest(uidOf(r), "photoCopy", null, "open", null)) })),
);

/** {} -> { url, expiresAtMs, requestId }: a JSON file with every data type, link valid 1 hour. */
export const exportMyData = gatedCall({ ...opts, timeoutSeconds: 120, memory: "512MiB" }, (r) =>
  run("exportMyData", async () => {
    const uid = uidOf(r);
    const db = adminDb();
    // At most 3 exports a day.
    const since = Timestamp.fromMillis(Date.now() - 86_400_000);
    const recent = await db.collection("privacyRequests").where("uid", "==", uid).where("kind", "==", "export").where("createdAt", ">=", since).limit(3).get();
    if (recent.size >= 3) fail("rate-limited");
    const store = new FirestorePrivacyStore(db);
    const nowMs = Date.now();
    const request = newRequest(store.newId(), uid, "export", null, nowMs);
    await store.putRequest(request);
    try {
      const file = await buildExport(new FirestoreExportSource(db, bucket(), chatServer()), uid, nowMs, (id, error) => {
        logger.warn("export section failed", { section: id, message: error instanceof Error ? error.message : "unknown" });
      });
      const path = exportPath(uid, request.id);
      await bucket().file(path).save(Buffer.from(JSON.stringify(file, null, 2), "utf8"), { contentType: "application/json", resumable: false });
      const expiresAtMs = nowMs + EXPORT_LINK_MS;
      const [url] = await bucket().file(path).getSignedUrl({ version: "v4", action: "read", expires: expiresAtMs, responseDisposition: `attachment; filename="school-carpool-data.json"` });
      const notes = [file.missing.length > 0 ? `missing:${file.missing.join(",")}` : "", file.truncated.length > 0 ? `truncated:${file.truncated.join(",")}` : ""].filter((x) => x !== "");
      await store.putRequest({ ...request, status: "done", reason: notes.length > 0 ? notes.join(";") : null, doneAtMs: Date.now() });
      return { url, expiresAtMs, requestId: request.id, missing: file.missing, truncated: file.truncated };
    } catch (error) {
      await store.putRequest({ ...request, status: "failed", reason: "export-failed", doneAtMs: Date.now() });
      logger.error("export failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      fail("export-failed");
    }
  }),
);

/**
 * {} -> { closed, purgeAtMs }: deletes the account (the app asked for
 * confirmation and a fresh Face ID check). Refused with money in the
 * wallet, a pending transfer, or a run being driven.
 */
export const deleteMyAccount = gatedCall({ ...opts, timeoutSeconds: 300, memory: "512MiB" }, (r) =>
  run("deleteMyAccount", async () => {
    const uid = uidOf(r);
    const store = new FirestorePrivacyStore(adminDb());
    const request = newRequest(store.newId(), uid, "delete", null, Date.now());
    await store.putRequest(request);
    try {
      const result = await deleteAccount(deletionRunner(), uid, Date.now(), (step, error) => {
        logger.error("account deletion step failed", { step, message: error instanceof Error ? error.message : "unknown" });
        void reportError(error);
      });
      await store.putRequest({ ...request, status: result.failed > 0 ? "open" : "done", reason: result.failed > 0 ? "steps-retried" : null, doneAtMs: Date.now() });
      return { closed: true, purgeAtMs: result.purgeAtMs };
    } catch (error) {
      if (error instanceof DeletionError) await store.putRequest({ ...request, status: "refused", reason: error.reason, doneAtMs: Date.now() });
      throw error;
    }
  }),
);

export function deletionRunner(): FirestoreDeletionRunner {
  const carpools = carpoolDeps();
  const trips = tripDeps();
  return new FirestoreDeletionRunner(adminDb(), bucket(), {
    stopTrips: async (uid, nowMs) => void (await endDriverTrips(trips, uid, nowMs)),
    removeFromCarpool: async (uid, carpoolId) => void (await removeFromCarpool(carpools, uid, carpoolId)),
    removeLinkedChild: async (guardianUid, childId) => {
      await removeChildFromCarpools(carpools, guardianUid, childId);
      await leaveEmptyCarpools(carpools, guardianUid);
    },
    chat: chatServer(),
    walletBalance: async (walletRef) => {
      const p = walletProvider();
      return p ? p.balance(walletRef) : null;
    },
    walletFreeze: async (walletRef, frozen) => {
      const p = walletProvider();
      if (p) await p.freeze(walletRef, frozen);
    },
    revokeSessions: (uid) => adminAuth().revokeRefreshTokens(uid),
    deleteAuthUser: async (uid) => {
      try {
        await adminAuth().deleteUser(uid);
      } catch (error) {
        if (errorCode(error) !== "auth/user-not-found") throw error;
      }
    },
  });
}

// --------------------------------------------------------------------------
// Retention job
// --------------------------------------------------------------------------

/**
 * Every night 03:10 Cairo time (replaces purgeVerificationImagesDaily and
 * chatRetentionDaily: one Cloud Scheduler job instead of two). Writes
 * retentionRuns/{date}; failures go to Sentry and the admins' security
 * alerts.
 */
export const retentionDaily = onSchedule(
  { schedule: "10 3 * * *", timeZone: CAIRO_TZ, retryCount: 1, timeoutSeconds: 540, memory: "512MiB" },
  async () => {
    const db = adminDb();
    const chat = chatServer();
    const report = await runRetention({
      store: new FirestoreRetentionStore(db, bucket()),
      runner: deletionRunner(),
      deleteChannel: (cid) => {
        const [type, id] = cid.split(":");
        return chat.deleteChannel(type, id);
      },
      freezeChannel: (cid) => {
        const [type, id] = cid.split(":");
        return chat.setFrozen(type, id, true);
      },
      now: () => Date.now(),
      reportError: (error) => void reportError(error),
    });
    // Uploads never submitted (3 days) and orphaned case folders; withdrawn cases.
    try {
      const pending = await purgeVerificationImages({ store: new FirestoreVerificationStore(db), files: new CloudStorageFiles(bucket()), now: () => Date.now() });
      logger.info("retention: verification uploads", pending);
    } catch (error) {
      await reportError(error);
    }
    logger.info("retention", { tasks: report.tasks, failures: report.failures.length });
  },
);

// --------------------------------------------------------------------------
// Route archive (owner decision: one compressed track per run, 1 year)
// --------------------------------------------------------------------------

/**
 * When a run's tracking stops (trackingEndedAt is set), its live points
 * (deleted within 24 hours) become one gzipped, down-sampled track in
 * routeArchive/{year}/{tripId}.json.gz, written in the COLDLINE storage
 * class, plus routeArchives/{tripId} (Cloud Functions only). Idempotent.
 */
export const archiveRouteOnTripWrite = onDocumentWritten({ document: "trips/{tripId}", region: REGION, retry: true, memory: "512MiB" }, async (event) => {
  const before = event.data?.before?.data();
  const after = event.data?.after?.data();
  if (!after || !after.trackingEndedAt || before?.trackingEndedAt) return;
  const tripId = (event.params as Record<string, string>).tripId;
  const db = adminDb();
  const record = db.collection(ROUTE_ARCHIVES).doc(tripId);
  if ((await record.get()).exists) return;
  const snap = await db.collection("trips").doc(tripId).collection("points").orderBy("time").limit(5_000).get();
  const points: TrackPoint[] = [];
  for (const d of snap.docs) {
    const loc = d.get("location") as { latitude?: unknown; longitude?: unknown } | undefined;
    if (typeof loc?.latitude === "number" && typeof loc.longitude === "number") points.push({ lat: loc.latitude, lng: loc.longitude, atMs: millis(d.get("time")) });
  }
  const startedAtMs = millis(after.startedAt);
  const endedAtMs = millis(after.trackingEndedAt);
  const meta = { tripId, carpoolId: String(after.carpoolId ?? ""), driverUid: String(after.driverUid ?? ""), startedAtMs, endedAtMs };
  const packed = packArchive(meta, points);
  if (packed.points === 0) return;
  const path = archivePath(tripId, startedAtMs);
  await bucket().file(path).save(packed.data, { contentType: "application/gzip", resumable: false, metadata: { storageClass: "COLDLINE" } });
  await record.set({ path, carpoolId: meta.carpoolId, driverUid: meta.driverUid, startedAt: Timestamp.fromMillis(startedAtMs), endedAt: Timestamp.fromMillis(endedAtMs), points: packed.points, bytes: packed.data.length, purgeAt: Timestamp.fromMillis(routeArchivePurgeAt(endedAtMs)) });
  logger.info("route archived", { points: packed.points, bytes: packed.data.length });
});

// --------------------------------------------------------------------------
// Thumbnails for the admin panel (server-made)
// --------------------------------------------------------------------------

/**
 * A 320 px WebP thumbnail of every kept photo (thumbs/{uid}/...), so admin
 * lists never load full ID images. Uses sharp (justified in
 * docs/progress/prompt-12.md). The thumbnail is kept and purged with the
 * photo (account deletion, thumbs/{uid}/).
 */
export const makePhotoThumbnail = onObjectFinalized({ region: REGION, memory: "1GiB", timeoutSeconds: 60 }, async (event) => {
  // Remade when the original was replaced (its generation changed).
  await ensureThumb(bucket(), event.data.name, event.data.generation === undefined ? null : String(event.data.generation));
});

/** A kept photo was deleted (withdrawn case, purge): its thumbnail goes too. */
export const dropPhotoThumbnail = onObjectDeleted({ region: REGION }, async (event) => {
  await dropThumb(bucket(), event.data.name);
});

// --------------------------------------------------------------------------
// Admin: photos and routes with a logged reason, alerts, requests
// --------------------------------------------------------------------------

async function audit(actorUid: string, action: string, target: string, reasonCode: string | null, ip: string | null, details?: Record<string, string | number | boolean | null>): Promise<void> {
  await new FirestoreListsStore(adminDb()).audit({ actorUid, action, target, reasonCode, ip, details });
}

function reasonOf(raw: Record<string, unknown>) {
  const reason = accessReason(raw.reason);
  if (!reason) throw new AdminError("invalid-request");
  return reason;
}

/**
 * { uid, reason, full? } -> { photos: [{ name, kind, storedAt, url }] }:
 * a parent's kept photos (face reference, driver photo, kept selfies,
 * decided case images). Thumbnails by default; full images only with
 * full=true. Logged first, with the reason; links work 5 minutes.
 */
export const adminOpenUserPhotos = onCall({ ...opts, memory: "1GiB", timeoutSeconds: 120 }, (r) =>
  run("adminOpenUserPhotos", async () => {
    const caller = await requireAdminCaller(r);
    const raw = data(r);
    const uid = typeof raw.uid === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(raw.uid) ? raw.uid : null;
    if (!uid) throw new AdminError("invalid-request");
    const reason = reasonOf(raw);
    const full = raw.full === true;
    // Which file each photo is served from is decided BEFORE the audit
    // entry, so the log says "full" whenever any full image is served (a
    // photo without a thumbnail yet included).
    const picked: Array<{ name: string; kind: string; storedAt: string; path: string; isFull: boolean }> = [];
    for (const [prefix, kind] of [
      [`faceRefs/${uid}/`, "faceRef"],
      [`driverPhotos/${uid}/`, "driverPhoto"],
      [`selfieArchive/${uid}/`, "selfie"],
      [`verification/${uid}/cases/`, "case"],
    ] as const) {
      const [files] = await bucket().getFiles({ prefix });
      for (const f of files.slice(0, 60)) {
        const thumb = thumbPath(f.name);
        const useThumb = !full && thumb !== null && (await ensureThumb(bucket(), f.name, null).catch(() => "skipped")) !== "skipped";
        picked.push({ name: f.name.slice(f.name.lastIndexOf("/") + 1), kind, storedAt: String(f.metadata.timeCreated ?? ""), path: useThumb ? (thumb as string) : f.name, isFull: !useThumb });
      }
    }
    const fullCount = picked.filter((p) => p.isFull).length;
    await audit(caller.uid, fullCount > 0 ? "photos.view.full" : "photos.view", `users/${uid}`, reason, ipOf(r), { photos: picked.length, full: fullCount });
    const expires = Date.now() + 5 * 60_000;
    const out: Array<{ name: string; kind: string; storedAt: string; url: string; full: boolean }> = [];
    for (const p of picked) {
      const [url] = await bucket().file(p.path).getSignedUrl({ version: "v4", action: "read", expires });
      out.push({ name: p.name, kind: p.kind, storedAt: p.storedAt, url, full: p.isFull });
    }
    return { photos: out };
  }),
);

/** { tripId, reason } -> { meta, points }: one archived route (safety investigations). Logged first. */
export const adminOpenRouteArchive = onCall(opts, (r) =>
  run("adminOpenRouteArchive", async () => {
    const caller = await requireAdminCaller(r);
    const raw = data(r);
    const tripId = typeof raw.tripId === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(raw.tripId) ? raw.tripId : null;
    if (!tripId) throw new AdminError("invalid-request");
    const reason = reasonOf(raw);
    const rec = await adminDb().collection(ROUTE_ARCHIVES).doc(tripId).get();
    if (!rec.exists) throw new AdminError("not-found");
    await audit(caller.uid, "route.view", `routeArchives/${tripId}`, reason, ipOf(r));
    const [file] = await bucket().file(String(rec.get("path"))).download();
    return unpackArchive(file);
  }),
);

/**
 * { uid, reason } -> { cleared }: after comparing the kept new-phone
 * selfie with the face reference by hand (the face check could not
 * decide; it fails closed), an admin opens the parent's data again.
 * Logged first with the reason code.
 */
export const adminClearDeviceCheck = onCall(opts, (r) =>
  run("adminClearDeviceCheck", async () => {
    const caller = await requireAdminCaller(r);
    const store = new FirestoreDeviceStore(adminDb(), bucket());
    try {
      // Prompt 13: { uid, reason, outcome: approved | confirmedOtherWay }.
      return await adminDecideDeviceCheck(
        { store, audit: (e) => audit(e.actorUid, e.action, e.target, e.reasonCode, e.ip, e.details) },
        caller.uid,
        r.data,
        ipOf(r),
        (v) => accessReason(v) !== null,
      );
    } catch (error) {
      if (error instanceof DeviceDecisionError) throw new AdminError(error.reason);
      throw error;
    }
  }),
);

/** { status? } -> { alerts } : scraping and retention-failure alerts. */
export const adminListSecurityAlerts = onCall(opts, (r) =>
  run("adminListSecurityAlerts", async () => {
    await requireAdminCaller(r);
    const status = data(r).status === "handled" ? "handled" : "open";
    const snap = await adminDb().collection(SECURITY_ALERTS).where("status", "==", status).orderBy("createdAt", "desc").limit(100).get();
    return {
      alerts: snap.docs.map((d) => ({
        id: d.id,
        uid: d.get("uid") ?? null,
        kind: String(d.get("kind") ?? ""),
        count: Number(d.get("count") ?? 0),
        createdAtMs: millis(d.get("createdAt")),
        failures: Array.isArray(d.get("failures")) ? (d.get("failures") as unknown[]).slice(0, 50) : [],
      })),
    };
  }),
);

const ALERT_OUTCOMES = ["noIssue", "suspended", "watching", "fixed"] as const;

/** { alertId, outcome } -> { status } ; logged. */
export const adminResolveSecurityAlert = onCall(opts, (r) =>
  run("adminResolveSecurityAlert", async () => {
    const caller = await requireAdminCaller(r);
    const raw = data(r);
    const id = typeof raw.alertId === "string" && /^[A-Za-z0-9_-]{1,300}$/.test(raw.alertId) ? raw.alertId : null;
    if (!id || !(ALERT_OUTCOMES as readonly unknown[]).includes(raw.outcome)) throw new AdminError("invalid-request");
    const ref = adminDb().collection(SECURITY_ALERTS).doc(id);
    if (!(await ref.get()).exists) throw new AdminError("not-found");
    await audit(caller.uid, "security-alert.resolve", `securityAlerts/${id}`, String(raw.outcome), ipOf(r));
    await ref.update({ status: "handled", outcome: raw.outcome, handledBy: caller.uid, handledAt: Timestamp.now() });
    return { status: "handled" };
  }),
);

/** {} -> { requests }: open privacy requests (ID-detail corrections, photo copies). */
export const adminListPrivacyRequests = onCall(opts, (r) =>
  run("adminListPrivacyRequests", async () => {
    await requireAdminCaller(r);
    return { requests: (await new FirestorePrivacyStore(adminDb()).openRequests(100)).map((x) => ({ ...viewRequest(x), uid: x.uid })) };
  }),
);

/** { requestId, outcome: done | refused } -> { status } ; logged. */
export const adminClosePrivacyRequest = onCall(opts, (r) =>
  run("adminClosePrivacyRequest", async () => {
    const caller = await requireAdminCaller(r);
    const raw = data(r);
    const id = typeof raw.requestId === "string" && /^[A-Za-z0-9]{1,40}$/.test(raw.requestId) ? raw.requestId : null;
    const outcome = raw.outcome === "done" || raw.outcome === "refused" ? raw.outcome : null;
    if (!id || !outcome) throw new AdminError("invalid-request");
    const store = new FirestorePrivacyStore(adminDb());
    const req = await store.request(id);
    if (!req) throw new AdminError("not-found");
    await audit(caller.uid, "privacy-request.close", `privacyRequests/${id}`, outcome, ipOf(r), { kind: req.kind });
    await store.putRequest({ ...req, status: outcome, doneAtMs: Date.now() });
    return { status: outcome };
  }),
);
