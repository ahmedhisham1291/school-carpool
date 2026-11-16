/**
 * Demo accounts and data for Apple's App Review (docs/apple-review/
 * submission-kit.md; plan in src/auth/review_demo.ts). FAKE data only.
 *
 * Run AFTER `review-access -- on` (the demo parents' exemption from the
 * new-phone selfie and the driver face reference follows that window and
 * ends with it):
 *
 *   GCLOUD_PROJECT=<project> REVIEW_PHONE=<demo number 1> REVIEW_PHONE_2=<demo number 2> \
 *   npm --prefix functions run review-demo -- seed <superAdminUid>
 *
 *   GCLOUD_PROJECT=<project> npm --prefix functions run review-demo -- status <superAdminUid>
 *   GCLOUD_PROJECT=<project> REVIEW_PHONE=... REVIEW_PHONE_2=... \
 *   npm --prefix functions run review-demo -- remove <superAdminUid>
 *
 * `review-access -- on` with both demo numbers runs this seed by itself;
 * run it by hand only to repair the data. While the window is open the
 * scheduled function reviewDemoDaily (src/auth/review_demo_job.ts) plans
 * the demo week and confirms the driver's runs every evening, so the
 * owner no longer has to seed again before each school day.
 *
 * seed (safe to run again): creates or finds the two accounts with the same code
 * as a real sign-in, marks them verified demo parents, writes one hidden
 * demo school, one carpool with both parents, one child each and the
 * driver's car, records the second parent's consent to the driver, plans
 * this week and the next and confirms the driver's runs.
 *
 * remove: ends the exemption, takes "verified" away from the two demo
 * accounts, signs their phones out and deletes the demo carpool,
 * children, car, homes and school. After it the server refuses the demo
 * accounts everything except Delete account. Close the two accounts with
 * Delete account in the app (sign in again first) or in the admin panel;
 * this script does not delete accounts.
 *
 * The numbers come from the environment, are never printed and never
 * stored by this script. Refuses numbers that are not both on the review
 * allow-list (config/reviewAccess), so it cannot mark a real parent.
 *
 * Demo accounts are confined by the server (src/privacy/device_gate.ts,
 * src/auth/review_access.ts): the exemption from the new-phone selfie and
 * the face reference applies only to the two accounts listed in
 * config/reviewAccess while that access is on; they cannot add driving
 * schools, join or search carpools outside the demo school, change phone
 * number, link a guardian, submit documents or use the wallet; outside the
 * window every function refuses them.
 * Written to the admin audit log.
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { FirestoreListsStore } from "../src/admin_panel/store";
import { toEgyptE164 } from "../src/auth/phone";
import { REVIEW_ACCESS_DOC, REVIEW_DEMO_FIELD, REVIEW_DEMO_MARK, isReviewDemoAccount } from "../src/auth/review_access";
import { DEMO_IDS, demoPlan } from "../src/auth/review_demo";
import { cairoDate } from "../src/carpools/model";
import { printReviewDemoStatus, seedReviewDemo, SeedRefused } from "./review_demo_lib";

function refuse(reason: string): never {
  console.error(`review-demo: refusing to run: ${reason}`);
  process.exit(1);
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : "unknown";
}

async function main(): Promise<void> {
  const [mode, actorUid] = process.argv.slice(2);
  const projectId = process.env.GCLOUD_PROJECT ?? "";
  if (!projectId) refuse("GCLOUD_PROJECT is not set");
  if (!["seed", "status", "remove"].includes(mode ?? "") || !actorUid) refuse("usage: seed|status|remove <superAdminUid>");
  initializeApp({ projectId });
  const db = getFirestore();
  const auth = getAuth();
  const admin = await db.collection("admins").doc(actorUid).get();
  if (!admin.exists || admin.get("role") !== "superAdmin" || admin.get("disabled") === true) refuse("the actor is not an active super admin");
  const lists = new FirestoreListsStore(db);
  const nowMs = Date.now();

  if (mode === "status") {
    await printReviewDemoStatus(db);
    return;
  }

  const key = process.env.OTP_HMAC_KEY ?? "";
  const phones = [toEgyptE164(process.env.REVIEW_PHONE ?? ""), toEgyptE164(process.env.REVIEW_PHONE_2 ?? "")];
  if (!phones[0] || !phones[1] || phones[0] === phones[1]) refuse("REVIEW_PHONE and REVIEW_PHONE_2 must be two different Egyptian mobile numbers");
  const [phoneA, phoneB] = phones as [string, string];

  if (mode === "remove") {
    await lists.audit({ actorUid, action: "auth.reviewDemo.remove", target: `carpools/${DEMO_IDS.carpool}`, reasonCode: "appReview", ip: null, details: {} });
    const uids: string[] = [];
    for (const phone of [phoneA, phoneB]) {
      try {
        uids.push((await auth.getUserByPhoneNumber(phone)).uid);
      } catch {
        // Already deleted in the app.
      }
    }
    // No account is listed for the exemption any more.
    const accessRef = db.doc(REVIEW_ACCESS_DOC);
    if ((await accessRef.get()).exists) await accessRef.update({ demoUids: [] });
    for (const uid of uids) {
      const ref = db.collection("users").doc(uid);
      const user = await ref.get();
      // Only accounts this script marked: never a real parent who now owns the number.
      if (!user.exists || !isReviewDemoAccount(user.data())) continue;
      // The exemption ends, the account is no longer "verified" (it never
      // passed an ID check) and every phone is signed out. The demo mark
      // stays, so the server keeps refusing the account until it is deleted.
      await ref.update({ [REVIEW_DEMO_FIELD]: FieldValue.delete(), [REVIEW_DEMO_MARK]: true, status: "unverified", sessionsValidAfter: Math.ceil(nowMs / 1000) + 1 });
      await auth.setCustomUserClaims(uid, {});
      await auth.revokeRefreshTokens(uid);
    }
    const [a, b] = [uids[0] ?? "gone-1", uids[1] ?? "gone-2"];
    const plan = demoPlan({ driverUid: a, parentUid: b, nowMs, untilMs: nowMs, today: cairoDate(nowMs) });
    // The carpool with its runs, members and consents.
    await db.recursiveDelete(db.collection("carpools").doc(DEMO_IDS.carpool));
    for (const path of plan.removePaths) {
      if (path.includes("gone-")) continue;
      await db.doc(path).delete();
    }
    console.log("demo data removed; the demo accounts are signed out, no longer verified and refused by the server.");
    console.log("Now turn review access off (`review-access -- off`). To erase the two accounts too: Delete account in the app (sign in again first) or the admin panel.");
    return;
  }

  // ---- seed (scripts/review_demo_lib.ts; also run by `review-access -- on`)
  try {
    await seedReviewDemo({ db, auth, lists, actorUid, projectId, key, phoneA, phoneB });
  } catch (error) {
    if (error instanceof SeedRefused) refuse(error.message);
    throw error;
  }
}

main().catch((error: unknown) => {
  console.error("review-demo failed:", message(error));
  process.exit(1);
});
