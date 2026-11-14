import type { Firestore } from "firebase-admin/firestore";
import type { ReviewAccess } from "./otp_flow";

/** Server settings for App Review sign-in (closed to the app: config/ is deny-all). */
export const REVIEW_ACCESS_DOC = "config/reviewAccess";

/** Reads config/reviewAccess; anything malformed counts as off. */
export async function readReviewAccess(db: Firestore): Promise<ReviewAccess | null> {
  const snap = await db.doc(REVIEW_ACCESS_DOC).get();
  if (!snap.exists) return null;
  const d = snap.data() ?? {};
  if (d.enabled !== true || typeof d.phoneKey !== "string" || typeof d.codeHash !== "string" || typeof d.expiresAtMs !== "number") return null;
  return { enabled: true, phoneKey: d.phoneKey, codeHash: d.codeHash, expiresAtMs: d.expiresAtMs };
}

/** Codes too easy to guess for a review code (one digit six times, 123456, 987654 ...). */
export function weakCode(code: string): boolean {
  return /^(\d)\1{5}$/.test(code) || "0123456789".includes(code) || "9876543210".includes(code);
}
