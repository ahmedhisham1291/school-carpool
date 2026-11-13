import { hmacHex } from "../auth/hash";

/**
 * Egyptian national ID numbers (14 digits). The number is never stored or
 * logged: only a keyed hash (HMAC-SHA256 with the NATIONAL_ID_HMAC_KEY
 * secret) is kept, for the duplicate and ban checks (spec section 7). A
 * plain hash of a 14-digit number could be reversed by trying every number.
 *
 * Layout: C YYMMDD GG SSSS K
 *   C       century of birth: 2 = 1900s, 3 = 2000s
 *   YYMMDD  date of birth
 *   GG      governorate of birth (88 = born abroad)
 *   SSSS    sequence; the last of these digits is odd for men, even for women
 *   K       check digit (the algorithm is not public, so it is not checked)
 *
 * The app runs the same checks (lib/features/verification/national_id.dart).
 */

const GOVERNORATES = new Set([
  "01", "02", "03", "04", "11", "12", "13", "14", "15", "16", "17", "18", "19",
  "21", "22", "23", "24", "25", "26", "27", "28", "29", "31", "32", "33", "34", "35", "88",
]);

/** Parents are adults: born at least this many years before today. */
export const MIN_PARENT_AGE_YEARS = 18;

/** Arabic-Indic and Persian digits to 0-9; every other character dropped. */
export function normalizeDigits(input: string): string {
  let out = "";
  for (const char of input) {
    const code = char.codePointAt(0) ?? 0;
    if (code >= 0x30 && code <= 0x39) out += char;
    else if (code >= 0x0660 && code <= 0x0669) out += String.fromCharCode(0x30 + code - 0x0660);
    else if (code >= 0x06f0 && code <= 0x06f9) out += String.fromCharCode(0x30 + code - 0x06f0);
  }
  return out;
}

/**
 * The 14 ASCII digits of a valid national ID, or null. [today] is
 * "YYYY-MM-DD" (Cairo), used for the birth date and the adult check.
 */
export function parseNationalId(input: unknown, today: string): string | null {
  if (typeof input !== "string" || input.length > 40) return null;
  const digits = normalizeDigits(input);
  if (!/^[23]\d{13}$/.test(digits)) return null;
  const century = digits[0] === "2" ? 1900 : 2000;
  const year = century + Number(digits.slice(1, 3));
  const month = Number(digits.slice(3, 5));
  const day = Number(digits.slice(5, 7));
  if (!isRealDate(year, month, day)) return null;
  if (!GOVERNORATES.has(digits.slice(7, 9))) return null;
  const birth = `${year}-${pad(month)}-${pad(day)}`;
  const [ty, tm, td] = today.split("-").map(Number);
  const adultFrom = `${ty - MIN_PARENT_AGE_YEARS}-${pad(tm)}-${pad(td)}`;
  if (birth > adultFrom) return null;
  return digits;
}

/** Keyed hash used as the document ID in nationalIds and bannedIds. */
export function nationalIdHash(key: string, digits: string): string {
  return hmacHex(key, `nid:v1:${digits}`);
}

export function isRealDate(year: number, month: number, day: number): boolean {
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) return false;
  if (month < 1 || month > 12 || day < 1) return false;
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

function pad(n: number): string {
  return String(n).padStart(2, "0");
}
