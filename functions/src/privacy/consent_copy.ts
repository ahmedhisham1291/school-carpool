import { consentText } from "../auth/consent_texts";
import type { SignatureRecord } from "../auth/signature";
import { consentKind, type ConsentKind, type ConsentRow } from "./requests";

/**
 * The parent's copy of a signed consent (R3, Decree 816/2025 Art. 2: a
 * consent register; answers.md 1.4: "a copy the parent can open"). Built
 * from the latest record of a kind: the exact text of that version in the
 * language the parent read, the typed name (users/{uid}.signedNames, gone
 * with the account), date, method, device platform, app version and the
 * text fingerprint. Pure; unit-tested in test/signature.test.ts.
 */

export interface ConsentCopy {
  kind: ConsentKind;
  version: string;
  language: "ar" | "en";
  text: string;
  signedName: string | null;
  acceptedAtMs: number;
  withdrawnAtMs: number | null;
  method: SignatureRecord["method"];
  platform: string;
  appVersion: string;
  textHash: string;
  /** The first 12 characters of the text hash, shown on screen. */
  fingerprint: string;
}

/** null: never given, or given before signed copies (an older, unsigned version). */
export function consentCopy(rows: readonly ConsentRow[], rawKind: unknown, signedName: string | null): ConsentCopy | null {
  const kind = consentKind(rawKind);
  if (!kind) return null;
  const latest = rows.filter((r) => r.type === kind).sort((a, b) => b.acceptedAtMs - a.acceptedAtMs)[0];
  const sig = latest?.signature;
  if (!latest || !sig || !latest.version) return null;
  const text = consentText(kind, latest.version, sig.language);
  if (text === null) return null;
  return {
    kind,
    version: latest.version,
    language: sig.language,
    text,
    signedName,
    acceptedAtMs: latest.acceptedAtMs,
    withdrawnAtMs: latest.withdrawnAtMs,
    method: sig.method,
    platform: sig.platform,
    appVersion: sig.appVersion,
    textHash: sig.textHash,
    fingerprint: sig.textHash.slice(0, 12),
  };
}

/** The downloadable file: a plain-text copy in the language the parent read. */
export function consentCopyFile(c: ConsentCopy): string {
  const at = new Date(c.acceptedAtMs).toISOString();
  const method = c.method === "deviceAuth" ? (c.language === "ar" ? "بصمة الوجه أو رمز الهاتف" : "Face ID or phone passcode") : c.language === "ar" ? "تسجيل دخول حديث" : "a fresh sign-in";
  const lines =
    c.language === "ar"
      ? [`نسخة الموافقة - مشوار المدرسة`, `النوع: ${c.kind}`, `النسخة: ${c.version}`, `وقّعها: ${c.signedName ?? "-"}`, `التاريخ والوقت (UTC): ${at}`, `طريقة التأكيد: ${method}`, `الجهاز: ${c.platform}، نسخة التطبيق: ${c.appVersion}`, `بصمة النص (SHA-256): ${c.textHash}`]
      : [`Consent copy - School Carpool`, `Type: ${c.kind}`, `Version: ${c.version}`, `Signed by: ${c.signedName ?? "-"}`, `Date and time (UTC): ${at}`, `Confirmed with: ${method}`, `Device: ${c.platform}, app version: ${c.appVersion}`, `Text fingerprint (SHA-256): ${c.textHash}`];
  if (c.withdrawnAtMs !== null) lines.push(c.language === "ar" ? `سُحبت في: ${new Date(c.withdrawnAtMs).toISOString()}` : `Withdrawn: ${new Date(c.withdrawnAtMs).toISOString()}`);
  return `${lines.join("\n")}\n\n----\n\n${c.text}\n`;
}

/** Where the downloadable copy is written (the exports folder: deleted after 1 day; the link works 1 hour). */
export function consentCopyPath(uid: string, kind: ConsentKind, nowMs: number): string {
  return `exports/${uid}/consent-${kind}-${nowMs}.txt`;
}
