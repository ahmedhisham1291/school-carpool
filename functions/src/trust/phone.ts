import { selfieArchivePath } from "../privacy/photos";
import { checkCode, requestCode, type OtpDeps, type RequestCodeResult } from "../auth/otp_flow";
import { toEgyptE164 } from "../auth/phone";
import { newEvent, type OutboxEvent } from "../notifications/model";
import type { KycResult } from "../verification/kyc";
import type { Language } from "../whatsapp/sender";
import { record, TrustError } from "./model";

/**
 * Re-verification when the phone number changes (spec section 3, Prompt
 * 11): a WhatsApp code to the NEW number (the sign-in limits and locks,
 * with their own key so a sign-in code never works here) and a fresh live
 * selfie matched to the parent's face reference (the identity selfie kept
 * at approval). Only then the number changes in Firebase Auth and on the
 * account. The selfie is deleted on every path. Numbers are never logged.
 */

/** Where the app uploads the live selfie (storage.rules: owner uploads only, no reads). */
export const phoneSelfiePath = (uid: string): string => `phoneChecks/${uid}/selfie.jpg`;
/** A selfie older than this is refused (take a new one). */
export const SELFIE_MAX_AGE_MS = 15 * 60 * 1000;

export interface PhoneAccount {
  status: string;
  phone: string | null;
}

export interface PhoneChangeStore {
  account(uid: string): Promise<PhoneAccount | null>;
  /** The uid that signs in with [phoneE164], or null. */
  uidByPhone(phoneE164: string): Promise<string | null>;
  /** Firebase Auth and users/{uid}.phone, the audit entry and the notice. */
  changePhone(uid: string, phoneE164: string, notice: OutboxEvent, nowMs: number): Promise<void>;
  /** A non-urgent report for the admins (selfie did not match). */
  reportMismatch(uid: string, nowMs: number): Promise<void>;
}

export interface PhoneFiles {
  /** Upload time in ms, or null when the file is missing. */
  createdMs(path: string): Promise<number | null>;
  read(path: string): Promise<Buffer>;
  delete(path: string): Promise<void>;
  exists(path: string): Promise<boolean>;
  /** Prompt 12: keeps the live selfie in the selfie archive. */
  copy(from: string, to: string): Promise<void>;
}

export interface PhoneChangeDeps {
  store: PhoneChangeStore;
  files: PhoneFiles;
  /** OTP deps with the phone-change key (never the sign-in key). */
  otp: OtpDeps;
  faces: { matchFace(reference: () => Promise<Buffer>, live: () => Promise<Buffer>): Promise<KycResult> };
  faceRefPath: (uid: string) => string;
  now: () => number;
  reportError: (error: unknown) => void;
}

/** A separate key for phone-change codes: codes and limits never mix with sign-in. */
export function phoneChangeKey(signInKey: string): string {
  return `${signInKey}|phone-change`;
}

async function requireVerifiedAccount(deps: PhoneChangeDeps, uid: string, verifiedClaim: boolean): Promise<PhoneAccount> {
  const account = await deps.store.account(uid);
  if (!account) throw new TrustError("no-account");
  if (account.status === "suspended") throw new TrustError("suspended");
  if (!verifiedClaim || account.status !== "verified") throw new TrustError("not-verified");
  return account;
}

/** { phone, deviceId } -> a code by WhatsApp to the new number. */
export async function requestPhoneChange(
  deps: PhoneChangeDeps,
  caller: { uid: string; verifiedClaim: boolean },
  data: unknown,
  ip: string,
  language: Language,
): Promise<RequestCodeResult> {
  const raw = record(data);
  const account = await requireVerifiedAccount(deps, caller.uid, caller.verifiedClaim);
  const phone = toEgyptE164(raw.phone);
  if (phone && phone === account.phone) throw new TrustError("phone-same");
  return requestCode(deps.otp, { phone: raw.phone, deviceId: raw.deviceId, ip, language });
}

/**
 * { phone, code, deviceId } after uploading phoneChecks/{uid}/selfie.jpg.
 * The selfie and the face reference are checked first (no code is used up
 * for a missing photo), then the code, then the face match.
 */
export async function confirmPhoneChange(
  deps: PhoneChangeDeps,
  caller: { uid: string; verifiedClaim: boolean },
  data: unknown,
): Promise<{ changed: true }> {
  const selfie = phoneSelfiePath(caller.uid);
  try {
    const raw = record(data);
    const account = await requireVerifiedAccount(deps, caller.uid, caller.verifiedClaim);
    const created = await deps.files.createdMs(selfie);
    if (created === null || deps.now() - created > SELFIE_MAX_AGE_MS) throw new TrustError("no-selfie");
    if (!(await deps.files.exists(deps.faceRefPath(caller.uid)))) throw new TrustError("no-reference");
    const phone = await checkCode(deps.otp, { phone: raw.phone, code: raw.code, deviceId: raw.deviceId });
    if (phone === account.phone) throw new TrustError("phone-same");
    const owner = await deps.store.uidByPhone(phone);
    if (owner !== null && owner !== caller.uid) throw new TrustError("phone-taken");
    const result = await deps.faces.matchFace(
      () => deps.files.read(deps.faceRefPath(caller.uid)),
      () => deps.files.read(selfie),
    );
    const nowMs = deps.now();
    if (result === "no_match") {
      await deps.store.reportMismatch(caller.uid, nowMs);
      throw new TrustError("selfie-mismatch");
    }
    if (result !== "match") throw new TrustError("check-unavailable");
    await deps.store.changePhone(caller.uid, phone, newEvent(`phone-changed_${caller.uid}_${nowMs}`, "phone-changed", [caller.uid], nowMs), nowMs);
    return { changed: true };
  } finally {
    try {
      if (await deps.files.exists(selfie)) {
        // Prompt 12 (owner decision: live selfie checks are kept): a copy
        // goes to the selfie archive (KMS key, 1 year after closure).
        await deps.files.copy(selfie, selfieArchivePath(caller.uid, `phone_${deps.now()}.jpg`));
        await deps.files.delete(selfie);
      }
    } catch (error) {
      deps.reportError(error);
    }
  }
}
