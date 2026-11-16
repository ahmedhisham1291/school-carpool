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
 * A second demo phone (the other parent of the demo carpool): add
 * REVIEW_PHONE_2=<another test number> REVIEW_CODE_2=<another 6 digits>.
 * With both numbers, `on` then (re)seeds the demo accounts and data by
 * itself (scripts/review_demo_lib.ts, the same as `review-demo -- seed`)
 * and lists them (`review-demo -- status`). With one number it stops and
 * prints the one thing left to do. While the window is open the scheduled
 * function reviewDemoDaily keeps the demo runs planned and confirmed.
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run review-access -- off <superAdminUid>
 *
 * The number and the code come from the environment (not the command
 * line), are never printed and never stored in clear. Use a number that
 * belongs to the test account only (fake data, staging or the review
 * account in prod). Logged in the admin audit log.
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { FirestoreListsStore } from "../src/admin_panel/store";
import { toEgyptE164 } from "../src/auth/phone";
import { CODE_PATTERN, REVIEW_ACCESS_MAX_DAYS, reviewAccessFor } from "../src/auth/otp_flow";
import { REVIEW_ACCESS_DOC, weakCode } from "../src/auth/review_access";
import { printReviewDemoStatus, seedReviewDemo, SeedRefused } from "./review_demo_lib";

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
  // Optional second demo phone, with its own code.
  const extra: Array<{ phoneKey: string; codeHash: string }> = [];
  const rawPhone2 = process.env.REVIEW_PHONE_2 ?? "";
  if (rawPhone2) {
    const phone2 = toEgyptE164(rawPhone2);
    if (!phone2 || phone2 === phone) refuse("REVIEW_PHONE_2 must be another Egyptian mobile number");
    const code2 = process.env.REVIEW_CODE_2 ?? "";
    if (!CODE_PATTERN.test(code2) || weakCode(code2) || code2 === code) refuse("REVIEW_CODE_2 must be 6 digits, not easy to guess and different from REVIEW_CODE");
    const second = reviewAccessFor(key, phone2, code2, expiresAtMs);
    extra.push({ phoneKey: second.phoneKey, codeHash: second.codeHash });
  }
  await lists.audit({ actorUid, action: "auth.reviewAccess.on", target: REVIEW_ACCESS_DOC, reasonCode: "appReview", ip: null, details: { days, phones: 1 + extra.length } });
  await ref.set({ ...reviewAccessFor(key, phone, code, expiresAtMs), extra, updatedAt: new Date() });
  console.log(`review access is on for ${days} days for ${1 + extra.length} demo phone(s) (numbers and codes not shown)`);
  // Turning the access on again starts with no listed demo account: the
  // seed lists them and renews their exemption for this window.
  if (!rawPhone2) {
    console.log("TO DO: the demo carpool needs two demo parents. Run `on` again with REVIEW_PHONE_2 and REVIEW_CODE_2 added; it then seeds the demo data by itself.");
    return;
  }
  console.log("seeding the demo accounts and data (the same as `review-demo -- seed`) ...");
  try {
    await seedReviewDemo({ db, auth: getAuth(), lists, actorUid, projectId, key, phoneA: phone, phoneB: toEgyptE164(rawPhone2) as string });
  } catch (error) {
    if (error instanceof SeedRefused) {
      console.error(`review-access: the access is on, but the demo seed refused: ${error.message}`);
      console.error("TO DO: fix that, then run `review-demo -- seed` (or `on` again).");
      process.exit(1);
    }
    throw error;
  }
  await printReviewDemoStatus(db);
  console.log("The demo runs are kept planned and confirmed every evening (reviewDemoDaily) until the access ends.");
}

main().catch((error: unknown) => {
  console.error("review-access failed:", error instanceof Error ? error.message : "unknown");
  process.exit(1);
});
