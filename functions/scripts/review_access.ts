/**
 * App Review sign-in (Prompt 13; docs/app-review-notes.md). Turns on, for
 * at most 30 days, a fixed 6-digit code for ONE allow-listed test phone, so
 * Apple's reviewer can sign in without a WhatsApp number. Stored in
 * config/reviewAccess as keyed hashes only (the rules close config/ to the
 * app); every sign-in limit and lock still applies; no WhatsApp is sent for
 * that number. Off by default; turn it off after the review.
 *
 *   GCLOUD_PROJECT=<project> OTP_HMAC_KEY=<same secret as the functions> \
 *   REVIEW_PHONE=<test number> REVIEW_CODE=<6 digits> \
 *   npm --prefix functions run review-access -- on <days 1-30> <superAdminUid>
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run review-access -- off <superAdminUid>
 *
 * The number and the code come from the environment (not the command
 * line), are never printed and never stored in clear. Use a number that
 * belongs to the test account only (fake data, staging or the review
 * account in prod). Logged in the admin audit log.
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { FirestoreListsStore } from "../src/admin_panel/store";
import { toEgyptE164 } from "../src/auth/phone";
import { CODE_PATTERN, REVIEW_ACCESS_MAX_DAYS, reviewAccessFor } from "../src/auth/otp_flow";
import { REVIEW_ACCESS_DOC, weakCode } from "../src/auth/review_access";

function refuse(reason: string): never {
  console.error(`review-access: refusing to run: ${reason}`);
  process.exit(1);
}

async function main(): Promise<void> {
  const [mode, a, b] = process.argv.slice(2);
  const projectId = process.env.GCLOUD_PROJECT ?? "";
  if (!projectId) refuse("GCLOUD_PROJECT is not set");
  const actorUid = mode === "on" ? b : a;
  if ((mode !== "on" && mode !== "off") || !actorUid) refuse("usage: on <days> <superAdminUid> | off <superAdminUid>");
  initializeApp({ projectId });
  const db = getFirestore();
  const admin = await db.collection("admins").doc(actorUid).get();
  if (!admin.exists || admin.get("role") !== "superAdmin" || admin.get("disabled") === true) refuse("the actor is not an active super admin");
  const lists = new FirestoreListsStore(db);
  const ref = db.doc(REVIEW_ACCESS_DOC);
  if (mode === "off") {
    await lists.audit({ actorUid, action: "auth.reviewAccess.off", target: REVIEW_ACCESS_DOC, reasonCode: "appReview", ip: null, details: {} });
    await ref.set({ enabled: false, updatedAt: new Date() });
    console.log("review access is off");
    return;
  }
  const days = Number(a);
  if (!Number.isInteger(days) || days < 1 || days > REVIEW_ACCESS_MAX_DAYS) refuse(`days must be 1 to ${REVIEW_ACCESS_MAX_DAYS}`);
  const key = process.env.OTP_HMAC_KEY ?? "";
  if (key.length < 32) refuse("OTP_HMAC_KEY is missing (the same secret the functions use)");
  const phone = toEgyptE164(process.env.REVIEW_PHONE ?? "");
  if (!phone) refuse("REVIEW_PHONE is not an Egyptian mobile number");
  const code = process.env.REVIEW_CODE ?? "";
  if (!CODE_PATTERN.test(code) || weakCode(code)) refuse("REVIEW_CODE must be 6 digits and not easy to guess");
  const expiresAtMs = Date.now() + days * 24 * 3600 * 1000;
  await lists.audit({ actorUid, action: "auth.reviewAccess.on", target: REVIEW_ACCESS_DOC, reasonCode: "appReview", ip: null, details: { days } });
  await ref.set({ ...reviewAccessFor(key, phone, code, expiresAtMs), updatedAt: new Date() });
  console.log(`review access is on for ${days} days (number and code not shown)`);
}

main().catch((error: unknown) => {
  console.error("review-access failed:", error instanceof Error ? error.message : "unknown");
  process.exit(1);
});
