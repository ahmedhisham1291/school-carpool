import { Timestamp, type DocumentData, type Firestore, type Transaction } from "firebase-admin/firestore";
import type { CodeRecord, LimitRecord, OtpStore, OtpTransaction } from "./otp_flow";

/**
 * Firestore storage for codes and limits. Both collections are closed to the
 * app by firestore.rules; only this Admin SDK code reads and writes them.
 * Document IDs are keyed hashes (otp_flow.ts), never a phone number.
 *
 * `expireAt` is for a Firestore TTL policy that deletes old documents
 * (SETUP.md step "TTL for sign-in records").
 */
export const OTP_CODES = "otpCodes";
export const OTP_LIMITS = "otpLimits";

const HOUR_MS = 3600 * 1000;

function num(data: DocumentData | undefined, key: string): number {
  const value: unknown = data?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

export function limitFromData(data: DocumentData | undefined): LimitRecord {
  return {
    windowStartMs: num(data, "windowStartMs"),
    sends: num(data, "sends"),
    lastSendMs: num(data, "lastSendMs"),
    failWindowStartMs: num(data, "failWindowStartMs"),
    failures: num(data, "failures"),
    lockedUntilMs: num(data, "lockedUntilMs"),
  };
}

export function codeFromData(data: DocumentData | undefined): CodeRecord | undefined {
  const hash: unknown = data?.codeHash;
  if (typeof hash !== "string") return undefined;
  return {
    codeHash: hash,
    createdAtMs: num(data, "createdAtMs"),
    expiresAtMs: num(data, "expiresAtMs"),
    attempts: num(data, "attempts"),
  };
}

class FirestoreOtpTransaction implements OtpTransaction {
  constructor(
    private readonly db: Firestore,
    private readonly tx: Transaction,
  ) {}

  async getLimit(key: string): Promise<LimitRecord | undefined> {
    const snap = await this.tx.get(this.db.collection(OTP_LIMITS).doc(key));
    return snap.exists ? limitFromData(snap.data()) : undefined;
  }

  async getCode(key: string): Promise<CodeRecord | undefined> {
    const snap = await this.tx.get(this.db.collection(OTP_CODES).doc(key));
    return snap.exists ? codeFromData(snap.data()) : undefined;
  }

  setLimit(key: string, record: LimitRecord): void {
    const latest = Math.max(record.windowStartMs, record.failWindowStartMs, record.lockedUntilMs, record.lastSendMs);
    this.tx.set(this.db.collection(OTP_LIMITS).doc(key), {
      ...record,
      expireAt: Timestamp.fromMillis(latest + 2 * HOUR_MS),
    });
  }

  setCode(key: string, record: CodeRecord): void {
    this.tx.set(this.db.collection(OTP_CODES).doc(key), {
      ...record,
      expireAt: Timestamp.fromMillis(record.expiresAtMs + HOUR_MS),
    });
  }

  deleteCode(key: string): void {
    this.tx.delete(this.db.collection(OTP_CODES).doc(key));
  }
}

export class FirestoreOtpStore implements OtpStore {
  constructor(private readonly db: Firestore) {}

  run<T>(fn: (tx: OtpTransaction) => Promise<T>): Promise<T> {
    return this.db.runTransaction((tx) => fn(new FirestoreOtpTransaction(this.db, tx)));
  }
}
