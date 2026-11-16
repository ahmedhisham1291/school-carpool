import { createHash, createHmac } from "node:crypto";

/**
 * Written consent for sensitive data (recommended change R3 in
 * docs/legal/answers.md 1.4; owner decision 16 Nov 2026). Decree 816/2025
 * Arts. 14(2) and 15 allow "explicit written consent (on paper or
 * electronically)"; a bare tick box is the weak end. So each sensitive
 * consent (storage abroad, ID, face matching, the guardian's declaration,
 * the 15-18 child's agreement) is:
 *
 * - its own unticked box (the app; the server requires each type by name);
 * - signed with the parent's typed full name, which must match the account
 *   name (the ID name) after Arabic normalisation (at sign-up no ID name
 *   exists yet: the typed name is recorded and checked for form only);
 * - confirmed by a fresh device check: Face ID / fingerprint / passcode on
 *   the phone ("deviceAuth", attested by the app), or, on a phone without
 *   one, a sign-in less than RECENT_SIGN_IN_MS old ("recentSignIn",
 *   checked here from the ID token's auth_time);
 * - recorded with the version, a hash of the exact text shown, the time,
 *   the device (keyed hash of the install ID), platform and app version;
 * - available to the parent as a copy (Privacy > consent > View copy).
 *
 * The kept consent record holds a KEYED HASH of the typed name, never the
 * name: the record outlives the account by 3 years (R1). The typed name
 * itself is on users/{uid}.signedNames and goes with the account.
 *
 * Pure (no Firebase); unit-tested in test/signature.test.ts.
 */

/** A sign-in younger than this counts as the fresh check on a phone with no passcode. */
export const RECENT_SIGN_IN_MS = 10 * 60_000;

export const SIGN_METHODS = ["deviceAuth", "recentSignIn"] as const;
export type SignMethod = (typeof SIGN_METHODS)[number];

export type SignatureErrorReason = "signature-required" | "signature-name" | "signature-name-mismatch" | "reauth-required";

export class SignatureError extends Error {
  constructor(readonly reason: SignatureErrorReason) {
    super(reason);
    this.name = "SignatureError";
  }
}

export const SIGNATURE_ERROR_CODES: Readonly<Record<SignatureErrorReason, string>> = {
  "signature-required": "failed-precondition",
  "signature-name": "invalid-argument",
  "signature-name-mismatch": "failed-precondition",
  "reauth-required": "failed-precondition",
};

const DIACRITICS = /[\u064B-\u065F\u0670\u06D6-\u06ED]/g;
const TATWEEL = /\u0640/g;

/**
 * Arabic and Latin names compared as people write them: diacritics and
 * tatweel dropped; أ إ آ ٱ -> ا, ة -> ه, ى -> ي, ؤ -> و, ئ -> ي; "عبد ال..."
 * written together or apart; Latin lower case without accents; anything
 * but letters becomes a space. Same rule in lib/features/auth/consent_signature.dart.
 */
export function normaliseName(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .normalize("NFKC")
    .replace(DIACRITICS, "")
    .replace(TATWEEL, "")
    .replace(/[أإآٱ]/g, "ا")
    .replace(/ة/g, "ه")
    .replace(/ى/g, "ي")
    .replace(/ؤ/g, "و")
    .replace(/ئ/g, "ي")
    .toLowerCase()
    .replace(/[^\p{L}]+/gu, " ")
    .replace(/(^| )عبد (?=\p{L})/gu, "$1عبد")
    .replace(/(^| )abd (?=\p{L})/gu, "$1abd")
    .replace(/(^| )abdel (?=\p{L})/gu, "$1abdel")
    .trim();
}

/** Letters only, at least two words (first and family name), 4 to 80 characters. */
export function nameLooksFull(value: string): boolean {
  const n = normaliseName(value);
  return n.length >= 4 && value.trim().length <= 80 && n.split(" ").filter((w) => w.length > 0).length >= 2;
}

/**
 * The typed name matches the account name: the same words, or it starts
 * with the first name and holds the family name's words in order (Egyptian
 * full names often add the father's and grandfather's names in between).
 */
export function nameMatches(typed: string, firstName: string, lastName: string): boolean {
  const t = normaliseName(typed).split(" ").filter(Boolean);
  const first = normaliseName(firstName).split(" ").filter(Boolean);
  const last = normaliseName(lastName).split(" ").filter(Boolean);
  if (t.length === 0 || first.length === 0 || last.length === 0) return false;
  for (let i = 0; i < first.length; i++) if (t[i] !== first[i]) return false;
  let at = first.length;
  for (const word of last) {
    const found = t.indexOf(word, at);
    if (found < 0) return false;
    at = found + 1;
  }
  return true;
}

export interface SignatureInput {
  fullName: string;
  method: SignMethod;
  /** The app's random install ID (hashed with a key before it is stored). */
  deviceId: string | null;
  platform: "ios" | "android" | "web";
  appVersion: string;
  /** The language the parent read the text in. */
  language: "ar" | "en";
}

const DEVICE_ID = /^[0-9a-f]{16,64}$/;
const VERSION = /^[0-9A-Za-z.+-]{1,32}$/;

/** { fullName, method, deviceId?, platform?, appVersion?, language? } from the app. */
export function parseSignature(value: unknown): SignatureInput {
  const raw = typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  if (!raw) throw new SignatureError("signature-required");
  const fullName = typeof raw.fullName === "string" ? raw.fullName.trim().replace(/\s+/g, " ") : "";
  if (!nameLooksFull(fullName)) throw new SignatureError("signature-name");
  const method = (SIGN_METHODS as readonly unknown[]).includes(raw.method) ? (raw.method as SignMethod) : null;
  if (!method) throw new SignatureError("signature-required");
  const platform = raw.platform === "android" || raw.platform === "web" ? raw.platform : "ios";
  return {
    fullName,
    method,
    deviceId: typeof raw.deviceId === "string" && DEVICE_ID.test(raw.deviceId) ? raw.deviceId : null,
    platform,
    appVersion: typeof raw.appVersion === "string" && VERSION.test(raw.appVersion) ? raw.appVersion : "unknown",
    language: raw.language === "en" ? "en" : "ar",
  };
}

/** "recentSignIn" needs a sign-in less than RECENT_SIGN_IN_MS old (ID token auth_time, seconds). */
export function checkMethod(method: SignMethod, authTimeSeconds: number | null, nowMs: number): void {
  if (method !== "recentSignIn") return;
  if (authTimeSeconds === null || nowMs - authTimeSeconds * 1000 > RECENT_SIGN_IN_MS) throw new SignatureError("reauth-required");
}

/** The ID token's auth_time (seconds) of a callable request, or null. */
export function authTimeOf(request: { auth?: { token?: Record<string, unknown> } | null }): number | null {
  const t = request.auth?.token?.auth_time;
  return typeof t === "number" && Number.isFinite(t) ? t : null;
}

/** SHA-256 of the exact text shown (the version's text in the language read). */
export function textHash(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/** Keyed hash of the normalised typed name, bound to the account. */
export function nameHash(key: string, uid: string, fullName: string): string {
  return createHmac("sha256", key).update(`signature:${uid}:${normaliseName(fullName)}`).digest("hex");
}

/** What a signed consent record holds besides type, version and times. */
export interface SignatureRecord {
  method: SignMethod;
  nameHash: string;
  /** null: no account name to compare with yet (sign-up). */
  nameMatched: boolean | null;
  textHash: string;
  language: "ar" | "en";
  deviceKey: string | null;
  platform: "ios" | "android" | "web";
  appVersion: string;
}

export function signatureRecord(
  key: string,
  uid: string,
  s: SignatureInput,
  text: string,
  nameMatched: boolean | null,
  deviceKey: string | null,
): SignatureRecord {
  return {
    method: s.method,
    nameHash: nameHash(key, uid, s.fullName),
    nameMatched,
    textHash: textHash(text),
    language: s.language,
    deviceKey,
    platform: s.platform,
    appVersion: s.appVersion,
  };
}
