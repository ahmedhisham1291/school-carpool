import { normalizeText } from "../text/normalize";

/**
 * Blocked terms (spec section 5: moderation; App Review guideline 1.2: "a
 * method for filtering objectionable material from being posted"). The
 * list lives in the server setting config/chatModeration (Arabic and
 * English, closed to the app by firestore.rules) and admins edit it in the
 * admin panel (Settings > Chat word filter; super admins only, audited).
 * Without that document the defaults below apply. The message trigger
 * (fanout.ts) checks every text message on the server when it is sent and
 * removes one that contains a term, within a second or two; it never
 * reaches the chat list or a push. Whole words or phrases only, after the
 * same normalisation as name search (case, Arabic letter forms and
 * diacritics), so "Class" never matches a shorter word inside it.
 *
 * This is a first line only: reports, blocking and admin removal stay the
 * real tool (F13). There is no automatic image moderation
 * (docs/open-items.md).
 */
export const CHAT_MODERATION_DOC = "config/chatModeration";

/** At most this many terms per language, each at most TERM_MAX_LENGTH characters. */
export const MAX_TERMS_PER_LANGUAGE = 500;
export const TERM_MAX_LENGTH = 60;

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

export interface BlockedTerms {
  ar: string[];
  en: string[];
}

export const DEFAULT_BLOCKED_TERMS: BlockedTerms = { ar: [...BLOCKED_TERMS_AR], en: [...BLOCKED_TERMS_EN] };

/**
 * One language's list, cleaned: trimmed, inner spaces collapsed, empty and
 * repeated (after normalisation) terms dropped, order kept. Null when it
 * is not a list of strings or breaks a limit (the admin is told; nothing is
 * saved).
 */
export function cleanTerms(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null;
  const out: string[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (typeof item !== "string") return null;
    const term = item.replace(/\s+/g, " ").trim();
    if (!term) continue;
    if (Array.from(term).length > TERM_MAX_LENGTH) return null;
    const key = normalizeText(term);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(term);
  }
  return out.length > MAX_TERMS_PER_LANGUAGE ? null : out;
}

/** The lists stored in config/chatModeration, or the defaults for a missing or broken one (never an empty filter by accident). */
export function termsFrom(doc: Record<string, unknown> | null | undefined): BlockedTerms {
  if (!doc) return DEFAULT_BLOCKED_TERMS;
  const ar = cleanTerms(doc.termsAr);
  const en = cleanTerms(doc.termsEn);
  return { ar: ar ?? DEFAULT_BLOCKED_TERMS.ar, en: en ?? DEFAULT_BLOCKED_TERMS.en };
}

/** A matcher for [terms] (normalised once). */
export function blockedTermMatcher(terms: BlockedTerms): (text: string) => boolean {
  const padded = [...terms.ar, ...terms.en].map((t) => normalizeText(t)).filter((t) => t.length > 0).map((t) => ` ${t} `);
  return (text: string) => {
    const hay = ` ${normalizeText(text)} `;
    return padded.some((t) => hay.includes(t));
  };
}

const defaultMatcher = blockedTermMatcher(DEFAULT_BLOCKED_TERMS);

/** True when [text] contains a default blocked word or phrase. Never logged. */
export function hasBlockedTerm(text: string): boolean {
  return defaultMatcher(text);
}

/**
 * Reads config/chatModeration at most once a minute per instance
 * ([read] is the Firestore read), so a busy chat costs no extra reads and an
 * admin's change applies within a minute. A failed read keeps the last
 * list (or the defaults): the filter never switches itself off.
 */
export function cachedTermMatcher(read: () => Promise<Record<string, unknown> | null>, now: () => number, ttlMs = 60_000) {
  let matcher = defaultMatcher;
  let loadedAtMs = -Infinity;
  return {
    async get(): Promise<(text: string) => boolean> {
      if (now() - loadedAtMs < ttlMs) return matcher;
      try {
        matcher = blockedTermMatcher(termsFrom(await read()));
      } catch {
        // Keep the last list.
      }
      loadedAtMs = now();
      return matcher;
    },
    clear(): void {
      loadedAtMs = -Infinity;
    },
  };
}
