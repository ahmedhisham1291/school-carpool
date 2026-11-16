import { AdminError } from "../admin_panel/errors";
import type { AdminCaller } from "../admin_panel/guard";
import type { AuditEntry } from "../admin_panel/types";
import { cleanTerms, DEFAULT_BLOCKED_TERMS, MAX_TERMS_PER_LANGUAGE, TERM_MAX_LENGTH, termsFrom, type BlockedTerms } from "./moderation";

/**
 * Admin panel > Settings > Chat word filter (App Review guideline 1.2).
 * Every admin sees the Arabic and English lists; only a super admin
 * changes them. A change and its audit entry are written together; the
 * audit entry holds the counts only (the words themselves stay in the
 * setting). Pure over [ModerationAdminStore]; unit-tested.
 */

export interface ModerationAdminStore {
  /** config/chatModeration as stored (null: no document yet, the defaults apply). */
  read(): Promise<Record<string, unknown> | null>;
  /** Writes both lists with who changed them, AND the audit entry, in one batch. */
  write(terms: BlockedTerms, adminUid: string, nowMs: number, audit: AuditEntry): Promise<void>;
}

export interface ModerationAdminDeps {
  store: ModerationAdminStore;
  now: () => number;
  /** This instance reads the setting again on its next message. */
  changed?: () => void;
}

export interface ModerationView {
  termsAr: string[];
  termsEn: string[];
  /** True while no admin has saved a list (the built-in defaults apply). */
  usingDefaults: boolean;
  maxTerms: number;
  maxLength: number;
}

export async function getChatModeration(deps: ModerationAdminDeps): Promise<ModerationView> {
  const doc = await deps.store.read();
  const terms = termsFrom(doc);
  return { termsAr: terms.ar, termsEn: terms.en, usingDefaults: doc === null, maxTerms: MAX_TERMS_PER_LANGUAGE, maxLength: TERM_MAX_LENGTH };
}

/**
 * { termsAr: string[], termsEn: string[] } -> the lists after the change.
 * Super admins only. A list may be shortened but never emptied in both
 * languages at once (the filter would be off): use the defaults instead.
 */
export async function setChatModeration(deps: ModerationAdminDeps, caller: AdminCaller, data: unknown, ip: string | null): Promise<ModerationView> {
  if (caller.role !== "superAdmin") throw new AdminError("invalid-state");
  const raw = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  const reset = raw.reset === true;
  const ar = reset ? DEFAULT_BLOCKED_TERMS.ar : cleanTerms(raw.termsAr);
  const en = reset ? DEFAULT_BLOCKED_TERMS.en : cleanTerms(raw.termsEn);
  if (!ar || !en) throw new AdminError("invalid-request");
  if (ar.length + en.length === 0) throw new AdminError("invalid-request");
  await deps.store.write({ ar, en }, caller.uid, deps.now(), {
    actorUid: caller.uid,
    action: reset ? "chat.wordFilter.reset" : "chat.wordFilter.set",
    target: "config/chatModeration",
    details: { arabicTerms: ar.length, englishTerms: en.length },
    ip,
  });
  deps.changed?.();
  return getChatModeration(deps);
}
