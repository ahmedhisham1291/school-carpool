import { hmacHex } from "../auth/hash";
import { newEvent, type OutboxEvent } from "../notifications/model";
import { DAY_MS, LOGIN_HISTORY_DAYS } from "./retention";

/**
 * Active devices, recent sign-ins and the new-phone rule (spec section 7,
 * Prompt 12):
 *
 * - Each sign-in records the phone (a keyed hash of the app's random
 *   install ID, never a hardware ID) in users/{uid}/devices/{key} and a
 *   line in users/{uid}/logins (90 days). The parent reads both (rules).
 * - A sign-in from a phone this account never used before, when the
 *   account was used elsewhere already, is RISKY (numbers get recycled
 *   and SIM cards swapped): every other phone is signed out, the parent is
 *   told by email (and by a push that reaches the old phone), and a
 *   verified parent must take a fresh selfie (matched to the face
 *   reference) before chats, the wallet and child data open.
 * - The parent signs out any phone from the list. Firebase can only cut
 *   every session of an account at once, so the server revokes all
 *   sessions and hands the CALLING phone a fresh custom token: only the
 *   phone that asked stays signed in; other phones need a new code.
 *
 * No phone number, install ID or IP is stored here.
 */

export const PLATFORMS = ["ios", "android", "web"] as const;
export type Platform = (typeof PLATFORMS)[number];

export type SignOutReason = "user" | "newDevice" | "deleted";

export interface DeviceRecord {
  key: string;
  platform: Platform;
  firstSignInAtMs: number;
  lastSignInAtMs: number;
  lastSeenAtMs: number;
  signedOutAtMs: number | null;
  signOutReason: SignOutReason | null;
}

export interface LoginRecord {
  id: string;
  deviceKey: string;
  platform: Platform;
  atMs: number;
  newDevice: boolean;
  expiresAtMs: number;
}

/** lastSeen is written at most this often (app start and resume call touchDevice). */
export const TOUCH_EVERY_MS = 60 * 60_000;
/** The fresh selfie must be this recent. */
export const DEVICE_SELFIE_MAX_AGE_MS = 15 * 60_000;
export const deviceSelfiePath = (uid: string): string => `deviceChecks/${uid}/selfie.jpg`;

export function platformOf(value: unknown): Platform {
  return typeof value === "string" && (PLATFORMS as readonly string[]).includes(value) ? (value as Platform) : "ios";
}

/** Keyed hash of the install ID; a separate purpose string from the sign-in limits. */
export function sessionKey(hmacKey: string, installId: string): string {
  return `s_${hmacHex(hmacKey, `session:${installId}`).slice(0, 40)}`;
}

export interface SignInPlan {
  device: DeviceRecord;
  login: LoginRecord;
  /** Keys of the phones to sign out now. */
  signOut: string[];
  newPhone: boolean;
}

/**
 * What a sign-in on [key] changes. A phone is "new" when this account
 * never signed in on it and it signed in somewhere before (the very first
 * sign-in of an account is not risky).
 */
export function planSignIn(devices: readonly DeviceRecord[], key: string, platform: Platform, nowMs: number, loginId: string): SignInPlan {
  const existing = devices.find((d) => d.key === key) ?? null;
  const newPhone = existing === null && devices.length > 0;
  const device: DeviceRecord = existing
    ? { ...existing, platform, lastSignInAtMs: nowMs, lastSeenAtMs: nowMs, signedOutAtMs: null, signOutReason: null }
    : { key, platform, firstSignInAtMs: nowMs, lastSignInAtMs: nowMs, lastSeenAtMs: nowMs, signedOutAtMs: null, signOutReason: null };
  const signOut = newPhone ? devices.filter((d) => d.key !== key && d.signedOutAtMs === null).map((d) => d.key) : [];
  return {
    device,
    login: { id: loginId, deviceKey: key, platform, atMs: nowMs, newDevice: newPhone, expiresAtMs: nowMs + LOGIN_HISTORY_DAYS * DAY_MS },
    signOut,
    newPhone,
  };
}

export interface DeviceAccount {
  status: string;
  email: string | null;
  language: "ar" | "en";
  /** A face reference exists (the account was verified with a selfie). */
  hasFaceRef: boolean;
}

export interface DeviceStore {
  account(uid: string): Promise<DeviceAccount | null>;
  devices(uid: string): Promise<DeviceRecord[]>;
  /** Device, login and sign-outs in one batch; with [check], users/{uid}.newDeviceCheck is set too. */
  saveSignIn(uid: string, plan: SignInPlan, check: { required: boolean; sinceMs: number } | null, notice: OutboxEvent | null): Promise<void>;
  touch(uid: string, key: string, platform: Platform, nowMs: number, create: boolean): Promise<void>;
  markSignedOut(uid: string, keys: string[], reason: SignOutReason, nowMs: number): Promise<void>;
  /** users/{uid}.newDeviceCheck: null clears it. */
  setDeviceCheck(uid: string, check: { required: boolean; sinceMs: number } | null): Promise<void>;
  deviceCheck(uid: string): Promise<{ required: boolean; sinceMs: number } | null>;
  /** A report for the admins (a non-matching or unchecked new-phone selfie). */
  addReport(uid: string, reason: "new-device-mismatch" | "new-device-unchecked", urgent: boolean, nowMs: number): Promise<void>;
}

export interface Sessions {
  /** Every session of the account ends (refresh tokens revoked). */
  revokeAll(uid: string): Promise<void>;
  /** A custom token for the calling phone after a revoke. */
  createToken(uid: string): Promise<string>;
}

export interface Mailer {
  /** Queues a security email (mail outbox; never the phone number). */
  /** [uid] is stored with the mail so account deletion removes it at once. */
  sendNewDeviceEmail(uid: string, to: string, language: "ar" | "en", platform: Platform, atMs: number): Promise<void>;
}

export interface DeviceFiles {
  createdMs(path: string): Promise<number | null>;
  exists(path: string): Promise<boolean>;
  read(path: string): Promise<Buffer>;
  /** Moves the live selfie to the kept selfie archive (owner decision: live selfie checks are kept). */
  archive(path: string, to: string): Promise<void>;
}

export interface DeviceDeps {
  store: DeviceStore;
  sessions: Sessions;
  mailer: Mailer;
  files: DeviceFiles;
  faces: { matchFace(reference: () => Promise<Buffer>, live: () => Promise<Buffer>): Promise<"match" | "no_match" | "error"> };
  faceRefPath: (uid: string) => string;
  selfieArchivePath: (uid: string, name: string) => string;
  hmacKey: string;
  now: () => number;
  newId: () => string;
  reportError: (error: unknown) => void;
}

export type DeviceErrorReason = "invalid-request" | "not-found" | "no-account" | "no-selfie" | "no-reference" | "selfie-mismatch" | "no-check" | "own-device" | "selfie-unchecked";

export class DeviceError extends Error {
  constructor(readonly reason: DeviceErrorReason) {
    super(reason);
    this.name = "DeviceError";
  }
}

export const DEVICE_ERROR_CODES: Readonly<Record<DeviceErrorReason, string>> = {
  "invalid-request": "invalid-argument",
  "not-found": "not-found",
  "no-account": "failed-precondition",
  "no-selfie": "failed-precondition",
  "no-reference": "failed-precondition",
  "selfie-mismatch": "permission-denied",
  "no-check": "failed-precondition",
  "own-device": "failed-precondition",
  "selfie-unchecked": "failed-precondition",
};

const INSTALL_ID = /^[0-9a-f]{16,64}$/;
const KEY = /^s_[0-9a-f]{40}$/;

function installId(value: unknown): string {
  if (typeof value !== "string" || !INSTALL_ID.test(value)) throw new DeviceError("invalid-request");
  return value;
}

export interface SignInResult {
  deviceKey: string;
  newDevice: boolean;
  freshSelfieRequired: boolean;
}

/**
 * Called right after a successful WhatsApp code (verifyCode). The very
 * first phone of an account is trusted; a later new phone signs the others
 * out, emails the parent and (verified parents) asks for a fresh selfie.
 */
export async function recordSignIn(deps: DeviceDeps, uid: string, rawInstallId: unknown, rawPlatform: unknown): Promise<SignInResult> {
  const key = sessionKey(deps.hmacKey, installId(rawInstallId));
  const platform = platformOf(rawPlatform);
  const nowMs = deps.now();
  const [account, devices] = [await deps.store.account(uid), await deps.store.devices(uid)];
  if (!account) throw new DeviceError("no-account");
  const plan = planSignIn(devices, key, platform, nowMs, deps.newId());
  const needsSelfie = plan.newPhone && account.status === "verified" && account.hasFaceRef;
  const notice = plan.newPhone ? newEvent(`new-device_${uid}_${nowMs}`, "new-device", [uid], nowMs) : null;
  await deps.store.saveSignIn(uid, plan, needsSelfie ? { required: true, sinceMs: nowMs } : null, notice);
  if (plan.newPhone) {
    // Every older session ends: the old phone cannot refresh its token.
    await deps.sessions.revokeAll(uid);
    if (account.email) {
      try {
        await deps.mailer.sendNewDeviceEmail(uid, account.email, account.language, platform, nowMs);
      } catch (error) {
        deps.reportError(error);
      }
    }
  }
  return { deviceKey: key, newDevice: plan.newPhone, freshSelfieRequired: needsSelfie };
}

/**
 * App start and resume: { deviceId, platform } -> { deviceKey, signedOut }.
 * A phone signed out from another phone learns it here and signs out.
 * Sessions from before Prompt 12 get their device record on the first call.
 */
export async function touchDevice(deps: DeviceDeps, uid: string, data: unknown): Promise<{ deviceKey: string; signedOut: boolean }> {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  const key = sessionKey(deps.hmacKey, installId(raw.deviceId));
  const platform = platformOf(raw.platform);
  const nowMs = deps.now();
  const devices = await deps.store.devices(uid);
  const mine = devices.find((d) => d.key === key) ?? null;
  if (mine?.signedOutAtMs != null) return { deviceKey: key, signedOut: true };
  if (!mine || nowMs - mine.lastSeenAtMs >= TOUCH_EVERY_MS) await deps.store.touch(uid, key, platform, nowMs, mine === null);
  return { deviceKey: key, signedOut: false };
}

/**
 * { deviceKey, deviceId } -> { token }: signs out one phone of the list
 * (not the calling one). Every session ends; the calling phone gets a
 * fresh custom token and signs in with it at once.
 */
export async function signOutDevice(deps: DeviceDeps, uid: string, data: unknown): Promise<{ token: string }> {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  const own = sessionKey(deps.hmacKey, installId(raw.deviceId));
  const all = raw.all === true;
  const target = typeof raw.deviceKey === "string" && KEY.test(raw.deviceKey) ? raw.deviceKey : null;
  if (!all && !target) throw new DeviceError("invalid-request");
  if (target === own) throw new DeviceError("own-device");
  const devices = await deps.store.devices(uid);
  const keys = all ? devices.filter((d) => d.key !== own && d.signedOutAtMs === null).map((d) => d.key) : [target as string];
  if (!all && !devices.some((d) => d.key === target)) throw new DeviceError("not-found");
  await deps.store.markSignedOut(uid, keys, "user", deps.now());
  await deps.sessions.revokeAll(uid);
  return { token: await deps.sessions.createToken(uid) };
}

/**
 * The fresh selfie after a new-phone sign-in (uploaded to
 * deviceChecks/{uid}/selfie.jpg). A match opens chats, the wallet and
 * child data again. A clear mismatch keeps them closed and files an
 * urgent report. FAIL CLOSED: when the face check cannot decide (an
 * error, a timeout, Valify not answering), everything stays closed and the
 * admins get a report to compare the kept selfie by hand; an admin clears
 * the check with a logged reason (adminClearDeviceCheck). The selfie is
 * kept on every path (selfie archive, owner decision 14 Nov 2026).
 */
export async function confirmNewDevice(deps: DeviceDeps, uid: string): Promise<{ cleared: boolean; reviewed: boolean }> {
  const live = deviceSelfiePath(uid);
  const check = await deps.store.deviceCheck(uid);
  if (!check?.required) throw new DeviceError("no-check");
  const created = await deps.files.createdMs(live);
  const nowMs = deps.now();
  if (created === null || nowMs - created > DEVICE_SELFIE_MAX_AGE_MS) throw new DeviceError("no-selfie");
  try {
    if (!(await deps.files.exists(deps.faceRefPath(uid)))) throw new DeviceError("no-reference");
    let result: "match" | "no_match" | "error";
    try {
      result = await deps.faces.matchFace(
        () => deps.files.read(deps.faceRefPath(uid)),
        () => deps.files.read(live),
      );
    } catch (error) {
      deps.reportError(error);
      result = "error";
    }
    if (result === "no_match") {
      await deps.store.addReport(uid, "new-device-mismatch", true, nowMs);
      throw new DeviceError("selfie-mismatch");
    }
    if (result !== "match") {
      await deps.store.addReport(uid, "new-device-unchecked", true, nowMs);
      throw new DeviceError("selfie-unchecked");
    }
    await deps.store.setDeviceCheck(uid, null);
    return { cleared: true, reviewed: false };
  } finally {
    try {
      if (await deps.files.exists(live)) await deps.files.archive(live, deps.selfieArchivePath(uid, `device_${nowMs}.jpg`));
    } catch (error) {
      deps.reportError(error);
    }
  }
}

/**
 * How an admin closed an open new-phone check (Prompt 13; needed while
 * Valify's face match is a stub and the check fails closed):
 * approved: the kept new-phone selfie matches the face reference (compared
 * by hand in the panel); confirmedOtherWay: the parent was confirmed by
 * other means (for example a call to the number on file).
 */
export const DEVICE_CHECK_OUTCOMES = ["approved", "confirmedOtherWay"] as const;
export type DeviceCheckOutcome = (typeof DEVICE_CHECK_OUTCOMES)[number];

export interface DeviceDecisionDeps {
  store: Pick<DeviceStore, "deviceCheck" | "setDeviceCheck">;
  /** The admin audit log (written first). */
  audit(entry: { actorUid: string; action: string; target: string; reasonCode: string; ip: string | null; details: Record<string, string | number | boolean | null> }): Promise<void>;
}

export class DeviceDecisionError extends Error {
  constructor(readonly reason: "invalid-request" | "not-found") {
    super(reason);
    this.name = "DeviceDecisionError";
  }
}

/**
 * { uid, reason, outcome } -> { cleared }: an admin opens the parent's
 * data again. [reason] is an access reason code (photos.ts). Refused when
 * no check is open. Logged before the change.
 */
export async function adminDecideDeviceCheck(deps: DeviceDecisionDeps, adminUid: string, data: unknown, ip: string | null, isReason: (v: unknown) => boolean): Promise<{ cleared: true; outcome: DeviceCheckOutcome }> {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  const uid = typeof raw.uid === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(raw.uid) ? raw.uid : null;
  const outcome = raw.outcome === undefined ? "approved" : raw.outcome;
  if (!uid || !isReason(raw.reason) || !(DEVICE_CHECK_OUTCOMES as readonly unknown[]).includes(outcome)) throw new DeviceDecisionError("invalid-request");
  if (uid === adminUid) throw new DeviceDecisionError("invalid-request");
  const check = await deps.store.deviceCheck(uid);
  if (!check?.required) throw new DeviceDecisionError("not-found");
  const decided = outcome as DeviceCheckOutcome;
  await deps.audit({ actorUid: adminUid, action: `device.check.${decided}`, target: `users/${uid}`, reasonCode: String(raw.reason), ip, details: { outcome: decided } });
  await deps.store.setDeviceCheck(uid, null);
  return { cleared: true, outcome: decided };
}

/** Chats, the wallet and child data stay closed while this is true. */
export function deviceCheckPending(user: Record<string, unknown> | undefined): boolean {
  const c = user?.newDeviceCheck as { required?: unknown } | null | undefined;
  return c?.required === true;
}

/**
 * The session gate (device_gate.ts and firestore.rules sessionValid and
 * deviceChecked): sessionsValidAfter in seconds, the token's auth_time.
 */
export type GateRefusal = "signed-out" | "device-check";

/** Why [user]'s session with sign-in time [authTime] (seconds) is refused, or null. */
export function gateRefusal(user: Record<string, unknown> | undefined, authTime: number | null, checkDevice: boolean): GateRefusal | null {
  if (!user) return null;
  const after = user.sessionsValidAfter;
  if (typeof after === "number" && (authTime === null || authTime < after)) return "signed-out";
  if (checkDevice && deviceCheckPending(user)) return "device-check";
  return null;
}
