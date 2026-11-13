/**
 * Text normalization for matching names typed in Arabic or English
 * (admin user search now; the schools list in Prompt 4B).
 *
 * - Latin letters are lower-cased; Arabic-Indic digits become 0-9.
 * - Arabic: diacritics (harakat, shadda, sukun, dagger alef) and the
 *   tatweel are removed; alef forms (hamza above or below, madda, wasla)
 *   become a bare alef; alef maqsura becomes yaa; taa marbuta becomes haa.
 * - Anything that is not a letter or digit becomes a space; spaces are
 *   collapsed.
 */
const DIACRITICS = /[ً-ْٰـ]/g;
const ALEF_FORMS = /[آأإٱ]/g;
const ALEF = "ا";
const ALEF_MAQSURA = /ى/g;
const YAA = "ي";
const TAA_MARBUTA = /ة/g;
const HAA = "ه";

function asciiDigits(input: string): string {
  return input.replace(/[٠-٩۰-۹]/g, (ch) => {
    const code = ch.charCodeAt(0);
    return String(code >= 0x06f0 ? code - 0x06f0 : code - 0x0660);
  });
}

export function normalizeText(input: string): string {
  return asciiDigits(input)
    .normalize("NFKC")
    .toLowerCase()
    .replace(DIACRITICS, "")
    .replace(ALEF_FORMS, ALEF)
    .replace(ALEF_MAQSURA, YAA)
    .replace(TAA_MARBUTA, HAA)
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()
    .replace(/\s+/g, " ");
}

/** Search fields for a person's name: the full normalized name and its distinct words. */
export function nameSearchFields(firstName: string, lastName: string): { nameKey: string; nameTokens: string[] } {
  const nameKey = normalizeText(`${firstName} ${lastName}`);
  const nameTokens = [...new Set(nameKey.split(" ").filter((token) => token.length > 0))];
  return { nameKey, nameTokens };
}
