import { randomInt } from "node:crypto";
import type { Language, WhatsAppSender } from "../whatsapp/sender";
import { hmacHex, safeEqualHex } from "./hash";
import { toEgyptE164 } from "./phone";

/**
 * Sign-in with a WhatsApp code (F1), as plain logic over a small store
 * interface so it can be unit-tested without the emulators.
 *
 * - The code is 6 digits. Only its keyed hash is stored, with a 5-minute
 *   expiry. A new request replaces the previous code.
 * - Sends are capped per phone number, per device (install ID from the app)
 *   and per IP address, in a rolling one-hour window, with a short cooldown
 *   between two codes for the same number.
 * - Each code allows a few attempts. Repeated failures for one number from
 *   one device lock that number on that device (no new codes, no checks)
 *   for an hour. A stranger who knows a number can therefore lock only
 *   their own device, not the parent's. Guessing across devices stays
 *   capped by the codes per number per hour times the tries per code.
 * - Phone numbers, device IDs and IPs are stored only as keyed hashes.
 */

export interface OtpLimits {
  codeTtlSeconds: number;
  resendCooldownSeconds: number;
  windowSeconds: number;
  maxSendsPerPhone: number;
  maxSendsPerDevice: number;
  /** High on purpose: Egyptian mobile carriers share IPs (carrier NAT). */
  maxSendsPerIp: number;
  maxAttemptsPerCode: number;
  maxFailuresBeforeLock: number;
  lockSeconds: number;
  /**
   * Wrong codes for one number per day across all devices. Above it the
   * number is closed for the rest of that day, for every device. High
   * enough that a stranger needs many codes over hours (5 codes an hour,
   * 5 tries each) to reach it.
   */
  maxFailuresPerPhonePerDay: number;
  /**
   * Prompt 12 (review 2, N1): a device where this number signed in before
   * stays "known" this long. The daily cap above does not close the number
   * on a known device, so a stranger rotating device IDs cannot lock the
   * parent out of their own phone. The per-device lock still applies.
   */
  knownDeviceDays: number;
}

export const DEFAULT_OTP_LIMITS: OtpLimits = {
  codeTtlSeconds: 300,
  resendCooldownSeconds: 60,
  windowSeconds: 3600,
  maxSendsPerPhone: 5,
  maxSendsPerDevice: 10,
  maxSendsPerIp: 60,
  maxAttemptsPerCode: 5,
  maxFailuresBeforeLock: 10,
  lockSeconds: 3600,
  maxFailuresPerPhonePerDay: 30,
  knownDeviceDays: 90,
};

const DAY_MS = 24 * 3600 * 1000;

export interface LimitRecord {
  windowStartMs: number;
  sends: number;
  lastSendMs: number;
  failWindowStartMs: number;
  failures: number;
  lockedUntilMs: number;
}

export interface CodeRecord {
  codeHash: string;
  createdAtMs: number;
  expiresAtMs: number;
  attempts: number;
}

/** All reads happen before any write (Firestore transaction rule). */
export interface OtpTransaction {
  getLimit(key: string): Promise<LimitRecord | undefined>;
  getCode(key: string): Promise<CodeRecord | undefined>;
  setLimit(key: string, record: LimitRecord): void;
  setCode(key: string, record: CodeRecord): void;
  deleteCode(key: string): void;
  /** Until when (ms) this number counts as known on this device; 0 when never. */
  getKnownDevice(key: string): Promise<number>;
  setKnownDevice(key: string, untilMs: number): void;
}

export interface OtpStore {
  run<T>(fn: (tx: OtpTransaction) => Promise<T>): Promise<T>;
}

export interface AccountService {
  /** Finds or creates the account for this number (user record, parent ID). */
  signInWithPhone(phoneE164: string, language: Language): Promise<{ uid: string; suspended: boolean }>;
  /** Firebase custom token for the app's signInWithCustomToken. */
  createToken(uid: string): Promise<string>;
}

/**
 * Prompt 13 (App Review): one allow-listed test phone may sign in with a
 * fixed code, so Apple's reviewer can get in without a WhatsApp number.
 * Off by default. Stored server-side only (config/reviewAccess, closed to
 * the app by the rules) as keyed hashes: the phone's [phoneKey] and the
 * code's [codeHash] (for that phone key), never the number or the code.
 * Every limit and lock of sign-in still applies; no WhatsApp is sent.
 */
export interface ReviewAccess {
  enabled: boolean;
  phoneKey: string;
  codeHash: string;
  expiresAtMs: number;
  /**
   * App Review audit: more allow-listed demo phones (the second demo
   * parent, "the other side" of the carpool), each with its own code
   * hash. At most REVIEW_ACCESS_MAX_EXTRA; same window and limits.
   */
  extra?: ReadonlyArray<{ phoneKey: string; codeHash: string }>;
  /**
   * Account IDs of the demo parents (scripts/review_demo.ts seed). Only
   * these accounts get the demo exemptions, and only while this access is
   * on (auth/review_access.ts, reviewDemoState).
   */
  demoUids?: ReadonlyArray<string>;
}

/** How many demo phones may be allow-listed besides the first. */
export const REVIEW_ACCESS_MAX_EXTRA = 1;

/** The longest a review window may be open (the script refuses more). */
export const REVIEW_ACCESS_MAX_DAYS = 30;

/** The review access is switched on, well formed, not expired and not open for longer than the limit. */
export function reviewWindowOpen(review: ReviewAccess | null | undefined, nowMs: number): review is ReviewAccess {
  if (!review || review.enabled !== true) return false;
  if (typeof review.phoneKey !== "string" || typeof review.codeHash !== "string") return false;
  if (!/^p_[0-9a-f]{64}$/.test(review.phoneKey) || !/^[0-9a-f]{64}$/.test(review.codeHash)) return false;
  if (typeof review.expiresAtMs !== "number" || !Number.isFinite(review.expiresAtMs)) return false;
  return review.expiresAtMs > nowMs && review.expiresAtMs - nowMs <= REVIEW_ACCESS_MAX_DAYS * DAY_MS;
}

/** The review code applies to this phone key now, or null. */
export function activeReview(review: ReviewAccess | null | undefined, pKey: string, nowMs: number): ReviewAccess | null {
  if (!reviewWindowOpen(review, nowMs)) return null;
  if (review.phoneKey === pKey) return review;
  const extra = Array.isArray(review.extra) ? review.extra.slice(0, REVIEW_ACCESS_MAX_EXTRA) : [];
  for (const e of extra) {
    if (!e || !/^p_[0-9a-f]{64}$/.test(e.phoneKey) || !/^[0-9a-f]{64}$/.test(e.codeHash)) continue;
    // The entry for this phone, shaped like the first one.
    if (e.phoneKey === pKey) return { enabled: true, phoneKey: e.phoneKey, codeHash: e.codeHash, expiresAtMs: review.expiresAtMs };
  }
  return null;
}

/** A demo phone of the open review window: its sign-ins are written to the audit log. */
export function isReviewPhone(review: ReviewAccess | null | undefined, hmacKey: string, phoneE164: string, nowMs: number): boolean {
  return activeReview(review, phoneKey(hmacKey, phoneE164), nowMs) !== null;
}

export interface OtpDeps {
  /** Prompt 13: the App Review access, if any (read per request). */
  review?: () => Promise<ReviewAccess | null>;
  /** App Review audit: called after a demo phone signed in (admin audit log; no number, no code). */
  onReviewSignIn?: (uid: string) => Promise<void>;
  store: OtpStore;
  sender: WhatsAppSender;
  accounts: AccountService;
  hmacKey: string;
  now: () => number;
  newCode?: () => string;
  limits?: OtpLimits;
  reportError?: (error: unknown) => void;
}

export type OtpErrorReason =
  | "invalid-phone"
  | "invalid-request"
  | "wrong-code"
  | "expired"
  | "too-many-attempts"
  | "locked"
  | "rate-limited"
  | "too-soon"
  | "send-failed"
  | "suspended";

export interface OtpErrorDetails {
  attemptsLeft?: number;
  retryAfterSeconds?: number;
}

export class OtpError extends Error {
  constructor(
    readonly reason: OtpErrorReason,
    readonly details: OtpErrorDetails = {},
  ) {
    super(reason);
    this.name = "OtpError";
  }
}

export const CODE_PATTERN = /^\d{6}$/;
export const DEVICE_ID_PATTERN = /^[0-9a-f]{16,64}$/;

export function newSixDigitCode(): string {
  return randomInt(0, 1_000_000).toString().padStart(6, "0");
}

export function phoneKey(hmacKey: string, phoneE164: string): string {
  return `p_${hmacHex(hmacKey, `phone:${phoneE164}`)}`;
}

export function deviceKey(hmacKey: string, deviceId: string): string {
  return `d_${hmacHex(hmacKey, `device:${deviceId}`)}`;
}

/** "This number signed in on this device before" (Prompt 12). */
export function knownKey(hmacKey: string, phoneE164: string, deviceId: string): string {
  return `k_${hmacHex(hmacKey, `known:${phoneE164}:${deviceId}`)}`;
}

/** Failure counter and lock for one number on one device. */
export function lockKey(hmacKey: string, phoneE164: string, deviceId: string): string {
  return `l_${hmacHex(hmacKey, `lock:${phoneE164}:${deviceId}`)}`;
}

export function ipKey(hmacKey: string, ip: string): string {
  return `i_${hmacHex(hmacKey, `ip:${ip}`)}`;
}

/** What config/reviewAccess holds for [phoneE164] and [code] (scripts/review_access.ts). */
export function reviewAccessFor(hmacKey: string, phoneE164: string, code: string, expiresAtMs: number): ReviewAccess {
  const pKey = phoneKey(hmacKey, phoneE164);
  return { enabled: true, phoneKey: pKey, codeHash: codeHash(hmacKey, pKey, code), expiresAtMs };
}

/** Bound to the number's key, so a hash is useless for another number. */
export function codeHash(hmacKey: string, phoneKeyValue: string, code: string): string {
  return hmacHex(hmacKey, `code:${phoneKeyValue}:${code}`);
}

export function emptyLimit(): LimitRecord {
  return { windowStartMs: 0, sends: 0, lastSendMs: 0, failWindowStartMs: 0, failures: 0, lockedUntilMs: 0 };
}

function rollSendWindow(record: LimitRecord, now: number, windowMs: number): LimitRecord {
  return now - record.windowStartMs >= windowMs ? { ...record, windowStartMs: now, sends: 0 } : record;
}

function rollFailWindow(record: LimitRecord, now: number, windowMs: number): LimitRecord {
  return now - record.failWindowStartMs >= windowMs ? { ...record, failWindowStartMs: now, failures: 0 } : record;
}

/** Refusal when the number used up its wrong codes for the day. */
function dailyLimitRefusal(phoneRecord: LimitRecord, now: number, limits: OtpLimits): OtpError | null {
  const daily = rollFailWindow(phoneRecord, now, DAY_MS);
  if (daily.failures < limits.maxFailuresPerPhonePerDay) return null;
  return new OtpError("locked", { retryAfterSeconds: secondsUntil(daily.failWindowStartMs + DAY_MS - now) });
}

function secondsUntil(ms: number): number {
  return Math.max(1, Math.ceil(ms / 1000));
}

export interface RequestCodeInput {
  phone: unknown;
  deviceId: unknown;
  ip: string;
  language: Language;
}

export interface RequestCodeResult {
  expiresInSeconds: number;
  resendAfterSeconds: number;
}

export async function requestCode(deps: OtpDeps, input: RequestCodeInput): Promise<RequestCodeResult> {
  const limits = deps.limits ?? DEFAULT_OTP_LIMITS;
  const phone = toEgyptE164(input.phone);
  if (!phone) throw new OtpError("invalid-phone");
  if (typeof input.deviceId !== "string" || !DEVICE_ID_PATTERN.test(input.deviceId)) {
    throw new OtpError("invalid-request");
  }
  const pKey = phoneKey(deps.hmacKey, phone);
  const dKey = deviceKey(deps.hmacKey, input.deviceId);
  const iKey = ipKey(deps.hmacKey, input.ip || "unknown");
  const lKey = lockKey(deps.hmacKey, phone, input.deviceId);
  const kKey = knownKey(deps.hmacKey, phone, input.deviceId);
  const code = (deps.newCode ?? newSixDigitCode)();
  const windowMs = limits.windowSeconds * 1000;
  const cooldownMs = limits.resendCooldownSeconds * 1000;
  let review: ReviewAccess | null = null;
  try {
    review = activeReview(deps.review ? await deps.review() : null, pKey, deps.now());
  } catch (error) {
    // Fails closed: a normal WhatsApp code is sent.
    deps.reportError?.(error);
  }

  const refusal = await deps.store.run(async (tx): Promise<OtpError | null> => {
    const now = deps.now();
    const phoneRecord = rollSendWindow((await tx.getLimit(pKey)) ?? emptyLimit(), now, windowMs);
    const deviceRecord = rollSendWindow((await tx.getLimit(dKey)) ?? emptyLimit(), now, windowMs);
    const ipRecord = rollSendWindow((await tx.getLimit(iKey)) ?? emptyLimit(), now, windowMs);
    const lockRecord = (await tx.getLimit(lKey)) ?? emptyLimit();
    const known = (await tx.getKnownDevice(kKey)) > now;

    if (lockRecord.lockedUntilMs > now) {
      return new OtpError("locked", { retryAfterSeconds: secondsUntil(lockRecord.lockedUntilMs - now) });
    }
    const dailyRefusal = known ? null : dailyLimitRefusal(phoneRecord, now, limits);
    if (dailyRefusal) return dailyRefusal;
    if (phoneRecord.lastSendMs > 0 && now - phoneRecord.lastSendMs < cooldownMs) {
      return new OtpError("too-soon", { retryAfterSeconds: secondsUntil(phoneRecord.lastSendMs + cooldownMs - now) });
    }
    const checks: Array<[LimitRecord, number]> = [
      [phoneRecord, limits.maxSendsPerPhone],
      [deviceRecord, limits.maxSendsPerDevice],
      [ipRecord, limits.maxSendsPerIp],
    ];
    for (const [record, max] of checks) {
      if (record.sends >= max) {
        return new OtpError("rate-limited", { retryAfterSeconds: secondsUntil(record.windowStartMs + windowMs - now) });
      }
    }

    tx.setLimit(pKey, { ...phoneRecord, sends: phoneRecord.sends + 1, lastSendMs: now });
    tx.setLimit(dKey, { ...deviceRecord, sends: deviceRecord.sends + 1, lastSendMs: now });
    tx.setLimit(iKey, { ...ipRecord, sends: ipRecord.sends + 1, lastSendMs: now });
    tx.setCode(pKey, {
      codeHash: review ? review.codeHash : codeHash(deps.hmacKey, pKey, code),
      createdAtMs: now,
      expiresAtMs: now + limits.codeTtlSeconds * 1000,
      attempts: 0,
    });
    return null;
  });
  if (refusal) throw refusal;

  if (review) {
    // App Review: the fixed code is already stored (as its hash); nothing is sent.
    return { expiresInSeconds: limits.codeTtlSeconds, resendAfterSeconds: limits.resendCooldownSeconds };
  }
  // Sent after the transaction commits, so a retried transaction never
  // sends twice. The send still counts against the limits if it fails.
  try {
    await deps.sender.sendCode(phone, code, input.language);
  } catch (error) {
    deps.reportError?.(error);
    throw new OtpError("send-failed");
  }
  return { expiresInSeconds: limits.codeTtlSeconds, resendAfterSeconds: limits.resendCooldownSeconds };
}

export interface VerifyCodeInput {
  phone: unknown;
  code: unknown;
  deviceId: unknown;
  language: Language;
}

export interface VerifyCodeResult {
  uid: string;
  token: string;
}

export async function verifyCode(deps: OtpDeps, input: VerifyCodeInput): Promise<VerifyCodeResult> {
  const phone = await checkCode(deps, input);
  const { uid, suspended } = await deps.accounts.signInWithPhone(phone, input.language);
  if (suspended) throw new OtpError("suspended");
  if (deps.review && deps.onReviewSignIn) {
    // Audited, never blocking: a failed audit write is reported, the
    // sign-in still works (the reviewer must get in).
    try {
      if (isReviewPhone(await deps.review(), deps.hmacKey, phone, deps.now())) await deps.onReviewSignIn(uid);
    } catch (error) {
      deps.reportError?.(error);
    }
  }
  return { uid, token: await deps.accounts.createToken(uid) };
}

/**
 * Checks (and uses up) a code for [input.phone] with every limit and lock
 * of sign-in, and returns the number in E.164. Prompt 11 (phone change)
 * uses it with its own key (trust/phone.ts), so a sign-in code never works
 * for a phone change and the other way round.
 */
export async function checkCode(deps: Pick<OtpDeps, "store" | "hmacKey" | "now" | "limits">, input: Omit<VerifyCodeInput, "language">): Promise<string> {
  const limits = deps.limits ?? DEFAULT_OTP_LIMITS;
  const phone = toEgyptE164(input.phone);
  if (!phone) throw new OtpError("invalid-phone");
  if (typeof input.code !== "string" || !CODE_PATTERN.test(input.code)) {
    throw new OtpError("invalid-request");
  }
  if (typeof input.deviceId !== "string" || !DEVICE_ID_PATTERN.test(input.deviceId)) {
    throw new OtpError("invalid-request");
  }
  const code: string = input.code;
  const pKey = phoneKey(deps.hmacKey, phone);
  const lKey = lockKey(deps.hmacKey, phone, input.deviceId);
  const kKey = knownKey(deps.hmacKey, phone, input.deviceId);
  const windowMs = limits.windowSeconds * 1000;

  const refusal = await deps.store.run(async (tx): Promise<OtpError | null> => {
    const now = deps.now();
    const limit = (await tx.getLimit(lKey)) ?? emptyLimit();
    const phoneRecord = (await tx.getLimit(pKey)) ?? emptyLimit();
    const stored = await tx.getCode(pKey);
    const known = (await tx.getKnownDevice(kKey)) > now;

    if (limit.lockedUntilMs > now) {
      return new OtpError("locked", { retryAfterSeconds: secondsUntil(limit.lockedUntilMs - now) });
    }
    const dailyRefusal = known ? null : dailyLimitRefusal(phoneRecord, now, limits);
    if (dailyRefusal) return dailyRefusal;
    if (!stored) return new OtpError("expired");
    if (now >= stored.expiresAtMs) {
      tx.deleteCode(pKey);
      return new OtpError("expired");
    }

    if (safeEqualHex(codeHash(deps.hmacKey, pKey, code), stored.codeHash)) {
      // Single use: the code is gone after one success.
      tx.deleteCode(pKey);
      tx.setLimit(lKey, { ...limit, failures: 0, failWindowStartMs: 0 });
      tx.setKnownDevice(kKey, now + limits.knownDeviceDays * DAY_MS);
      return null;
    }

    const counted = rollFailWindow(limit, now, windowMs);
    const failures = counted.failures + 1;
    const attempts = stored.attempts + 1;
    // The number's daily count, shared by all devices (same document as
    // the number's send counters, which stay untouched).
    const daily = rollFailWindow(phoneRecord, now, DAY_MS);
    tx.setLimit(pKey, { ...daily, failures: daily.failures + 1 });
    if (failures >= limits.maxFailuresBeforeLock) {
      tx.setLimit(lKey, { ...counted, failures: 0, failWindowStartMs: 0, lockedUntilMs: now + limits.lockSeconds * 1000 });
      tx.deleteCode(pKey);
      return new OtpError("locked", { retryAfterSeconds: limits.lockSeconds });
    }
    tx.setLimit(lKey, { ...counted, failures });
    if (attempts >= limits.maxAttemptsPerCode) {
      tx.deleteCode(pKey);
      return new OtpError("too-many-attempts");
    }
    tx.setCode(pKey, { ...stored, attempts });
    return new OtpError("wrong-code", { attemptsLeft: limits.maxAttemptsPerCode - attempts });
  });
  if (refusal) throw refusal;
  return phone;
}
