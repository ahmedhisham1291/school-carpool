import type { Firestore } from "firebase-admin/firestore";
import { REVIEW_ACCESS_MAX_DAYS, REVIEW_ACCESS_MAX_EXTRA, type ReviewAccess } from "./otp_flow";

/** Server settings for App Review sign-in (closed to the app: config/ is deny-all). */
export const REVIEW_ACCESS_DOC = "config/reviewAccess";

/** Reads config/reviewAccess; anything malformed counts as off. */
export async function readReviewAccess(db: Firestore): Promise<ReviewAccess | null> {
  const snap = await db.doc(REVIEW_ACCESS_DOC).get();
  if (!snap.exists) return null;
  const d = snap.data() ?? {};
  if (d.enabled !== true || typeof d.phoneKey !== "string" || typeof d.codeHash !== "string" || typeof d.expiresAtMs !== "number") return null;
  const extra = (Array.isArray(d.extra) ? d.extra : [])
    .filter((e: unknown): e is { phoneKey: string; codeHash: string } => {
      const r = e as { phoneKey?: unknown; codeHash?: unknown } | null;
      return !!r && typeof r.phoneKey === "string" && typeof r.codeHash === "string";
    })
    .slice(0, REVIEW_ACCESS_MAX_EXTRA)
    .map((e: { phoneKey: string; codeHash: string }) => ({ phoneKey: e.phoneKey, codeHash: e.codeHash }));
  return { enabled: true, phoneKey: d.phoneKey, codeHash: d.codeHash, expiresAtMs: d.expiresAtMs, ...(extra.length ? { extra } : {}) };
}

/**
 * App Review demo accounts (docs/apple-review/audit.md, guideline 2.1).
 *
 * users/{uid}.reviewDemoUntilMs is written only by scripts/review_demo.ts
 * (the rules let the app change nothing but `language`) on the two demo
 * parents, which hold fake data only. While it is in the future, and at
 * most REVIEW_ACCESS_MAX_DAYS ahead:
 * - a sign-in from a new phone opens no new-phone selfie check (Apple's
 *   device is always a new phone, and nobody can take the demo parent's
 *   selfie there);
 * - the demo driver can start a run without a face reference and is never
 *   picked for the random live selfie.
 * It ends by itself; a value further ahead than the limit counts as off.
 */
export const REVIEW_DEMO_FIELD = "reviewDemoUntilMs";

export function reviewDemoActive(untilMs: unknown, nowMs: number): boolean {
  return typeof untilMs === "number" && Number.isFinite(untilMs) && untilMs > nowMs && untilMs - nowMs <= REVIEW_ACCESS_MAX_DAYS * 24 * 3600 * 1000;
}

/** Codes too easy to guess for a review code (one digit six times, 123456, 987654 ...). */
export function weakCode(code: string): boolean {
  return /^(\d)\1{5}$/.test(code) || "0123456789".includes(code) || "9876543210".includes(code);
}
