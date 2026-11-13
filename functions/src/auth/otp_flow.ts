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
 * - Each code allows a few attempts. Repeated failures for one number lock
 *   it (no new codes, no checks) for an hour.
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
};

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

export interface OtpDeps {
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

export function ipKey(hmacKey: string, ip: string): string {
  return `i_${hmacHex(hmacKey, `ip:${ip}`)}`;
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
  const code = (deps.newCode ?? newSixDigitCode)();
  const windowMs = limits.windowSeconds * 1000;
  const cooldownMs = limits.resendCooldownSeconds * 1000;

  const refusal = await deps.store.run(async (tx): Promise<OtpError | null> => {
    const now = deps.now();
    const phoneRecord = rollSendWindow((await tx.getLimit(pKey)) ?? emptyLimit(), now, windowMs);
    const deviceRecord = rollSendWindow((await tx.getLimit(dKey)) ?? emptyLimit(), now, windowMs);
    const ipRecord = rollSendWindow((await tx.getLimit(iKey)) ?? emptyLimit(), now, windowMs);

    if (phoneRecord.lockedUntilMs > now) {
      return new OtpError("locked", { retryAfterSeconds: secondsUntil(phoneRecord.lockedUntilMs - now) });
    }
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
      codeHash: codeHash(deps.hmacKey, pKey, code),
      createdAtMs: now,
      expiresAtMs: now + limits.codeTtlSeconds * 1000,
      attempts: 0,
    });
    return null;
  });
  if (refusal) throw refusal;

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
  language: Language;
}

export interface VerifyCodeResult {
  uid: string;
  token: string;
}

export async function verifyCode(deps: OtpDeps, input: VerifyCodeInput): Promise<VerifyCodeResult> {
  const limits = deps.limits ?? DEFAULT_OTP_LIMITS;
  const phone = toEgyptE164(input.phone);
  if (!phone) throw new OtpError("invalid-phone");
  if (typeof input.code !== "string" || !CODE_PATTERN.test(input.code)) {
    throw new OtpError("invalid-request");
  }
  const code: string = input.code;
  const pKey = phoneKey(deps.hmacKey, phone);
  const windowMs = limits.windowSeconds * 1000;

  const refusal = await deps.store.run(async (tx): Promise<OtpError | null> => {
    const now = deps.now();
    const limit = (await tx.getLimit(pKey)) ?? emptyLimit();
    const stored = await tx.getCode(pKey);

    if (limit.lockedUntilMs > now) {
      return new OtpError("locked", { retryAfterSeconds: secondsUntil(limit.lockedUntilMs - now) });
    }
    if (!stored) return new OtpError("expired");
    if (now >= stored.expiresAtMs) {
      tx.deleteCode(pKey);
      return new OtpError("expired");
    }

    if (safeEqualHex(codeHash(deps.hmacKey, pKey, code), stored.codeHash)) {
      // Single use: the code is gone after one success.
      tx.deleteCode(pKey);
      tx.setLimit(pKey, { ...limit, failures: 0, failWindowStartMs: 0 });
      return null;
    }

    const counted = rollFailWindow(limit, now, windowMs);
    const failures = counted.failures + 1;
    const attempts = stored.attempts + 1;
    if (failures >= limits.maxFailuresBeforeLock) {
      tx.setLimit(pKey, { ...counted, failures: 0, failWindowStartMs: 0, lockedUntilMs: now + limits.lockSeconds * 1000 });
      tx.deleteCode(pKey);
      return new OtpError("locked", { retryAfterSeconds: limits.lockSeconds });
    }
    tx.setLimit(pKey, { ...counted, failures });
    if (attempts >= limits.maxAttemptsPerCode) {
      tx.deleteCode(pKey);
      return new OtpError("too-many-attempts");
    }
    tx.setCode(pKey, { ...stored, attempts });
    return new OtpError("wrong-code", { attemptsLeft: limits.maxAttemptsPerCode - attempts });
  });
  if (refusal) throw refusal;

  const { uid, suspended } = await deps.accounts.signInWithPhone(phone, input.language);
  if (suspended) throw new OtpError("suspended");
  return { uid, token: await deps.accounts.createToken(uid) };
}
