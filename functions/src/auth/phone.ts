/**
 * Egyptian mobile numbers. The server is the authority; the app runs the
 * same checks while the parent types (lib/features/auth/phone_number.dart).
 *
 * Accepted input: 01012345678, 1012345678, +201012345678, 00201012345678,
 * with spaces or dashes, in Latin or Arabic-Indic digits.
 * Mobile prefixes: 010, 011, 012, 015.
 */
const ARABIC_INDIC = "٠١٢٣٤٥٦٧٨٩";
const EXTENDED_ARABIC_INDIC = "۰۱۲۳۴۵۶۷۸۹";

/** Replaces Arabic-Indic and Persian digits with 0-9. */
export function asciiDigits(input: string): string {
  return input.replace(/[٠-٩۰-۹]/g, (ch) => {
    const arabic = ARABIC_INDIC.indexOf(ch);
    return String(arabic >= 0 ? arabic : EXTENDED_ARABIC_INDIC.indexOf(ch));
  });
}

/** Returns the number as +201XXXXXXXXX, or null when it is not an Egyptian mobile. */
export function toEgyptE164(input: unknown): string | null {
  if (typeof input !== "string" || input.length > 32) return null;
  let digits = asciiDigits(input).replace(/\D/g, "");
  if (digits.startsWith("0020")) {
    digits = digits.slice(4);
  } else if (digits.startsWith("20") && digits.length === 12) {
    digits = digits.slice(2);
  } else if (digits.startsWith("0")) {
    digits = digits.slice(1);
  }
  return /^1[0125]\d{8}$/.test(digits) ? `+20${digits}` : null;
}

/**
 * Masks a phone number for logs: country code and the last two digits only
 * (PRIVACY: never log a phone number in clear).
 */
export function maskPhone(phone: string): string {
  const digits = asciiDigits(phone).replace(/\D/g, "");
  if (digits.length < 6) return "***";
  return `+${digits.slice(0, 2)}${"*".repeat(digits.length - 4)}${digits.slice(-2)}`;
}
