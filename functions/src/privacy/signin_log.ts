import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes } from "node:crypto";
import { DAY_MS } from "./retention";

/**
 * Sign-in log for the Anti-Cybercrime Law (recommended change R2 in
 * docs/legal/answers.md 4.2; owner decision 16 Nov 2026, which replaces
 * "sign-in history deleted with the account" FOR THIS LOG ONLY).
 *
 * Law No. 175 of 2018, Art. 2 First: a service provider keeps "information
 * system logs" for 180 continuous days, confidential, disclosed only on an
 * order of the competent judicial authority. PM Decree 1699/2020 (its
 * regulations) lists what such a log holds. One entry per sign-in, kept
 * 180 days FROM THAT SIGN-IN (Firestore TTL on expiresAt), EVEN AFTER THE
 * ACCOUNT IS DELETED; then deleted.
 *
 * Where: signInLog/{id}, a server-only store. firestore.rules deny every
 * client, admins included. The only way to read it is the audited
 * super-admin callable adminDiscloseSignInLog (signin_log_callables.ts),
 * which needs a recorded judicial-order reference and a sign-in less than
 * 30 minutes old, and writes the audit entry BEFORE answering.
 *
 * Minimal fields, each justified in SIGN_IN_LOG_FIELDS. Never stored: names,
 * national ID, email, message text, photos, location or location history,
 * pages visited, contacts. The phone number and the IP address are
 * encrypted (AES-256-GCM, key in Secret Manager: SIGNIN_LOG_KEY); a keyed
 * hash of the phone lets a court order that names a number find its lines.
 *
 * Pure (no Firebase); unit-tested in test/signin_log.test.ts.
 */

export const SIGN_IN_LOG_DAYS = 180;

/**
 * Every stored field and why the law needs it (Law 175/2018 Art. 2 First
 * (1): "data that identify the user of the service", "data on the content
 * and nature of the information system handled", "data on communications
 * traffic", "data on the terminal devices"; Decree 1699/2020). Kept in step
 * with the store (test).
 */
export const SIGN_IN_LOG_FIELDS = {
  uid: "identifies the user's account (data identifying the user)",
  phoneKey: "keyed hash of the mobile number: finds the lines of a number named in a court order after the account is gone (data identifying the user)",
  phoneEnc: "the mobile number used to sign in, encrypted: the only identifier left once the account is deleted (data identifying the user)",
  event: "what the user did in the system: a sign-in (content and nature of the system handled)",
  at: "date and time of the sign-in (traffic data)",
  ipEnc: "the IP address the sign-in came from, encrypted (traffic data)",
  deviceKey: "keyed hash of the app's random install ID, never a hardware ID (terminal device data)",
  platform: "iPhone, Android or web (terminal device data)",
  appVersion: "the app version that signed in (terminal device data)",
  expiresAt: "the end of the 180 days: Firestore TTL deletes the line",
} as const;

export type SignInLogField = keyof typeof SIGN_IN_LOG_FIELDS;
export type SignInEvent = "signIn";

export interface SignInLogEntry {
  uid: string;
  phoneKey: string;
  phoneEnc: string;
  event: SignInEvent;
  atMs: number;
  ipEnc: string | null;
  deviceKey: string | null;
  platform: "ios" | "android" | "web";
  appVersion: string;
  expiresAtMs: number;
}

const VERSION = /^[0-9A-Za-z.+-]{1,32}$/;

/** "1.2.3+45" as the app sent it, or "unknown" (never free text). */
export function appVersionOf(value: unknown): string {
  return typeof value === "string" && VERSION.test(value) ? value : "unknown";
}

function keyBytes(secret: string): Buffer {
  if (secret.length < 16) throw new Error("sign-in log key too short");
  return createHash("sha256").update(`signin-log:${secret}`).digest();
}

/** AES-256-GCM: "v1:" + base64(iv 12 | tag 16 | ciphertext). */
export function sealText(secret: string, plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", keyBytes(secret), iv);
  const body = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return `v1:${Buffer.concat([iv, cipher.getAuthTag(), body]).toString("base64")}`;
}

/** The plain text, or null when the value is not ours or was changed. */
export function openText(secret: string, sealed: string): string | null {
  if (!sealed.startsWith("v1:")) return null;
  try {
    const raw = Buffer.from(sealed.slice(3), "base64");
    if (raw.length < 29) return null;
    const decipher = createDecipheriv("aes-256-gcm", keyBytes(secret), raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
  } catch {
    return null;
  }
}

/** The lookup-hash key: derived separately from the encryption key (one secret, two purposes, two keys). */
function lookupKeyBytes(secret: string): Buffer {
  if (secret.length < 16) throw new Error("sign-in log key too short");
  return createHash("sha256").update(`signin-log-lookup:${secret}`).digest();
}

/** Keyed hash of an E.164 number (its own purpose string; not the sign-in limits' key). */
export function signInPhoneKey(secret: string, phoneE164: string): string {
  return `l_${createHmac("sha256", lookupKeyBytes(secret)).update(`phone:${phoneE164}`).digest("hex").slice(0, 48)}`;
}

/** One line for a sign-in that just happened. */
export function newSignInEntry(
  secret: string,
  e: { uid: string; phoneE164: string; ip: string | null; deviceKey: string | null; platform: "ios" | "android" | "web"; appVersion: unknown; atMs: number },
): SignInLogEntry {
  const ip = e.ip && e.ip !== "unknown" ? e.ip : null;
  return {
    uid: e.uid,
    phoneKey: signInPhoneKey(secret, e.phoneE164),
    phoneEnc: sealText(secret, e.phoneE164),
    event: "signIn",
    atMs: e.atMs,
    ipEnc: ip ? sealText(secret, ip) : null,
    deviceKey: e.deviceKey,
    platform: e.platform,
    appVersion: appVersionOf(e.appVersion),
    expiresAtMs: e.atMs + SIGN_IN_LOG_DAYS * DAY_MS,
  };
}

// --------------------------------------------------------------------------
// Disclosure on a judicial order (super admins only)
// --------------------------------------------------------------------------

export type SignInLogErrorReason = "invalid-request" | "order-required";

export class SignInLogError extends Error {
  constructor(readonly reason: SignInLogErrorReason) {
    super(reason);
    this.name = "SignInLogError";
  }
}

export const SIGN_IN_LOG_ERROR_CODES: Readonly<Record<SignInLogErrorReason, string>> = {
  "invalid-request": "invalid-argument",
  "order-required": "failed-precondition",
};

/** Order numbers and authority names: letters (any script), digits, spaces and / . - _ ( ). */
const ORDER_REF = /^[\p{L}\p{N}][\p{L}\p{N} /.()_-]{2,79}$/u;
const AUTHORITY = /^[\p{L}\p{N}][\p{L}\p{N} ,/.()_-]{1,119}$/u;
const UID = /^[A-Za-z0-9_-]{1,128}$/;
const EGYPT_E164 = /^\+201[0125]\d{8}$/;
export const DISCLOSE_MAX = 500;

export interface DisclosureRequest {
  /** The judicial order's number / reference, as written on it (required). */
  orderRef: string;
  /** The court or prosecution office that issued it (required). */
  authority: string;
  /** The order's date, "YYYY-MM-DD". */
  orderDate: string;
  subject: { uid: string } | { phone: string };
}

function str(value: unknown): string {
  return typeof value === "string" ? value.trim().replace(/\s+/g, " ") : "";
}

export function parseDisclosure(data: unknown, nowMs: number): DisclosureRequest {
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : null;
  if (!raw) throw new SignInLogError("invalid-request");
  const orderRef = str(raw.orderRef);
  const authority = str(raw.authority);
  const orderDate = str(raw.orderDate);
  if (!orderRef || !authority) throw new SignInLogError("order-required");
  if (!ORDER_REF.test(orderRef) || !AUTHORITY.test(authority)) throw new SignInLogError("invalid-request");
  const date = /^(\d{4})-(\d{2})-(\d{2})$/.exec(orderDate);
  const dateMs = date ? Date.UTC(Number(date[1]), Number(date[2]) - 1, Number(date[3])) : NaN;
  if (!date || !Number.isFinite(dateMs) || dateMs > nowMs + DAY_MS || dateMs < nowMs - 2 * 365 * DAY_MS) throw new SignInLogError("invalid-request");
  const uid = str(raw.uid);
  const phone = str(raw.phone);
  if ((uid ? 1 : 0) + (phone ? 1 : 0) !== 1) throw new SignInLogError("invalid-request");
  if (uid && !UID.test(uid)) throw new SignInLogError("invalid-request");
  if (phone && !EGYPT_E164.test(phone)) throw new SignInLogError("invalid-request");
  return { orderRef, authority, orderDate, subject: uid ? { uid } : { phone } };
}

export interface SignInLogStore {
  add(entry: SignInLogEntry): Promise<void>;
  byUid(uid: string, limit: number): Promise<SignInLogEntry[]>;
  byPhoneKey(phoneKey: string, limit: number): Promise<SignInLogEntry[]>;
  /** The audit entry, written BEFORE the answer (no phone number, no IP). */
  audit(entry: { actorUid: string; ip: string; orderRef: string; authority: string; orderDate: string; subject: "uid" | "phone"; target: string; count: number; atMs: number }): Promise<void>;
}

export interface SignInLogDeps {
  store: SignInLogStore;
  secret: string;
  now: () => number;
}

export interface DisclosedLine {
  uid: string;
  event: SignInEvent;
  atMs: number;
  phone: string | null;
  ip: string | null;
  deviceKey: string | null;
  platform: string;
  appVersion: string;
}

/**
 * A super admin answers a judicial order: the lines of one account or one
 * number (newest first). The audit entry (order reference, authority, who,
 * when, how many lines) is written first; without it nothing is returned.
 */
export async function discloseSignInLog(deps: SignInLogDeps, actor: { uid: string; ip: string }, data: unknown): Promise<{ lines: DisclosedLine[]; count: number }> {
  const nowMs = deps.now();
  const req = parseDisclosure(data, nowMs);
  const entries =
    "uid" in req.subject
      ? await deps.store.byUid(req.subject.uid, DISCLOSE_MAX)
      : await deps.store.byPhoneKey(signInPhoneKey(deps.secret, req.subject.phone), DISCLOSE_MAX);
  const live = entries.filter((e) => e.expiresAtMs > nowMs).sort((a, b) => b.atMs - a.atMs);
  await deps.store.audit({
    actorUid: actor.uid,
    ip: actor.ip,
    orderRef: req.orderRef,
    authority: req.authority,
    orderDate: req.orderDate,
    subject: "uid" in req.subject ? "uid" : "phone",
    // The account, or the keyed hash of the number (never the number).
    target: "uid" in req.subject ? `signInLog/uid:${req.subject.uid}` : `signInLog/${signInPhoneKey(deps.secret, req.subject.phone)}`,
    count: live.length,
    atMs: nowMs,
  });
  return {
    count: live.length,
    lines: live.map((e) => ({
      uid: e.uid,
      event: e.event,
      atMs: e.atMs,
      phone: openText(deps.secret, e.phoneEnc),
      ip: e.ipEnc ? openText(deps.secret, e.ipEnc) : null,
      deviceKey: e.deviceKey,
      platform: e.platform,
      appVersion: e.appVersion,
    })),
  };
}
