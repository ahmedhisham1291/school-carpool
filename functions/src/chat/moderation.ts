import { normalizeText } from "../text/normalize";

/**
 * Blocked terms (spec section 5: moderation; the same list as before the
 * move to our own chat). The message trigger removes a message that contains one,
 * within a second or two of sending; nobody is notified of it. Whole words
 * or phrases only, after the same normalisation as name search (case,
 * Arabic letter forms and diacritics), so "Class" never matches a shorter
 * word inside it.
 *
 * This is a first line only: reports and admin removal stay the real tool
 * (F13). There is no automatic image moderation (docs/open-items.md).
 */
export const BLOCKED_TERMS_AR: readonly string[] = [
  "كس امك",
  "يلعن ابوك",
  "ابن الكلب",
  "ابن الوسخة",
  "شرموط",
  "شرموطة",
  "عرص",
  "خول",
  "منيوك",
  "متناك",
  "زبي",
  "طيز",
  "قحبة",
  "ابن المتناكة",
  "يا وسخ",
];

export const BLOCKED_TERMS_EN: readonly string[] = [
  "fuck",
  "fucking",
  "motherfucker",
  "shit",
  "bitch",
  "bastard",
  "asshole",
  "cunt",
  "dick",
  "slut",
  "whore",
  "retard",
  "kill yourself",
];

const TERMS: readonly string[] = [...BLOCKED_TERMS_AR, ...BLOCKED_TERMS_EN].map((t) => ` ${normalizeText(t)} `);

/** True when [text] contains a blocked word or phrase. Never logged. */
export function hasBlockedTerm(text: string): boolean {
  const padded = ` ${normalizeText(text)} `;
  return TERMS.some((t) => padded.includes(t));
}
