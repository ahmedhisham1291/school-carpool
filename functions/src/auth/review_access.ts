import type { Firestore } from "firebase-admin/firestore";
import { REVIEW_ACCESS_MAX_DAYS, REVIEW_ACCESS_MAX_EXTRA, reviewWindowOpen, type ReviewAccess } from "./otp_flow";

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
  // The demo parents' account IDs (scripts/review_demo.ts seed), at most one per demo phone.
  const demoUids = (Array.isArray(d.demoUids) ? d.demoUids : []).filter((u: unknown): u is string => typeof u === "string" && u.length > 0).slice(0, REVIEW_DEMO_MAX_UIDS);
  return { enabled: true, phoneKey: d.phoneKey, codeHash: d.codeHash, expiresAtMs: d.expiresAtMs, ...(extra.length ? { extra } : {}), ...(demoUids.length ? { demoUids } : {}) };
}

/** One demo account per allow-listed phone. */
export const REVIEW_DEMO_MAX_UIDS = 1 + REVIEW_ACCESS_MAX_EXTRA;

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
 * The field alone is NOT enough: see reviewDemoState below (the review
 * access must be on and list the account).
 */
export const REVIEW_DEMO_FIELD = "reviewDemoUntilMs";

export function reviewDemoActive(untilMs: unknown, nowMs: number): boolean {
  return typeof untilMs === "number" && Number.isFinite(untilMs) && untilMs > nowMs && untilMs - nowMs <= REVIEW_ACCESS_MAX_DAYS * 24 * 3600 * 1000;
}

/**
 * Validator review (docs/reviews/apple-review.md, B1 and B2): the
 * permanent mark of a demo account. Written by scripts/review_demo.ts
 * with the exemption and NEVER removed (not by `remove`, not when the
 * window ends): a demo parent is "verified" without an ID check, so it
 * stays confined for as long as the account exists.
 */
export const REVIEW_DEMO_MARK = "reviewDemo";

/** A demo account, inside or outside its window (the mark, or the exemption field of an older seed). */
export function isReviewDemoAccount(user: Record<string, unknown> | undefined | null): boolean {
  return !!user && (user[REVIEW_DEMO_MARK] === true || user[REVIEW_DEMO_FIELD] !== undefined);
}

/**
 * "none": a real parent. "open": a demo parent inside the review window.
 * "closed": a demo parent outside it.
 *
 * "open" needs ALL of: the account's own exemption date (future, at most
 * REVIEW_ACCESS_MAX_DAYS ahead), the review access switched on and not
 * expired (config/reviewAccess, closed to the app), and the account ID
 * listed there as one of the (at most two) demo parents. So the exemption
 * from the new-phone selfie and the face reference applies only to those
 * two accounts and ends the moment the owner runs `review-access off`,
 * the window expires or `review-demo remove` runs; a stray date on any
 * other account does nothing.
 */
export type ReviewDemoState = "none" | "open" | "closed";

export function reviewDemoState(user: Record<string, unknown> | undefined | null, uid: string, review: ReviewAccess | null | undefined, nowMs: number): ReviewDemoState {
  if (!isReviewDemoAccount(user)) return "none";
  const listed = !!review && reviewWindowOpen(review, nowMs) && (review.demoUids ?? []).slice(0, REVIEW_DEMO_MAX_UIDS).includes(uid);
  return listed && reviewDemoActive(user?.[REVIEW_DEMO_FIELD], nowMs) ? "open" : "closed";
}

/** reviewDemoState with config/reviewAccess read only for a demo account (no extra read for real parents). */
export async function readReviewDemoState(db: Firestore, uid: string, user: Record<string, unknown> | undefined | null, nowMs: number): Promise<ReviewDemoState> {
  if (!isReviewDemoAccount(user)) return "none";
  let review: ReviewAccess | null = null;
  try {
    review = await readReviewAccess(db);
  } catch {
    // Fails closed: no exemption, demo account refused.
  }
  return reviewDemoState(user, uid, review, nowMs);
}

/** Codes too easy to guess for a review code (one digit six times, 123456, 987654 ...). */
export function weakCode(code: string): boolean {
  return /^(\d)\1{5}$/.test(code) || "0123456789".includes(code) || "9876543210".includes(code);
}
