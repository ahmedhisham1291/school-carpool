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
 * seed (safe to run again, for example the evening before the review to
 * plan the new week): creates or finds the two accounts with the same code
 * as a real sign-in, marks them verified demo parents, writes one hidden
 * demo school, one carpool with both parents, one child each and the
 * driver's car, records the second parent's consent to the driver, plans
 * this week and the next and confirms the driver's runs.
 *
 * remove: ends the exemption, deletes the demo carpool, children, car,
 * homes and school. Close the two accounts with Delete account in the app
 * (or the admin panel); this script does not delete accounts.
 *
 * The numbers come from the environment, are never printed and never
 * stored by this script. Refuses numbers that are not both on the review
 * allow-list (config/reviewAccess), so it cannot mark a real parent.
 * Written to the admin audit log.
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, GeoPoint, Timestamp, getFirestore } from "firebase-admin/firestore";
import { schoolSearchGrams } from "../src/admin_panel/school_search";
import { FirestoreListsStore } from "../src/admin_panel/store";
import { FirebaseAccountService } from "../src/auth/accounts";
import { CONSENT_VERSIONS } from "../src/auth/consents";
import { isReviewPhone } from "../src/auth/otp_flow";
import { toEgyptE164 } from "../src/auth/phone";
import { REVIEW_ACCESS_DOC, REVIEW_DEMO_FIELD, readReviewAccess, reviewDemoActive } from "../src/auth/review_access";
import { DEMO_IDS, demoPlan, demoWindowMs } from "../src/auth/review_demo";
import { newInviteCode } from "../src/carpools/callables";
import { DEFAULT_CARPOOL_LIMITS, setDriverConsent, type CarpoolDeps } from "../src/carpools/flow";
import { cairoDate } from "../src/carpools/model";
import { carpoolToDoc, FirestoreCarpoolStore, memberToDoc, membershipToDoc } from "../src/carpools/store";
import { buildPublicLocation, defaultHome, type HomeRecord } from "../src/maps/parent_map";
import { addDays, weekStartOf } from "../src/schedule/cairo";
import { confirmRun, planWeek } from "../src/schedule/flow";
import { searchKeysFor } from "../src/schools/catalog";
import { nameSearchFields } from "../src/text/normalize";

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
  const review = await readReviewAccess(db);

  if (mode === "status") {
    const open = review !== null && review.expiresAtMs > nowMs;
    console.log(`review access: ${open ? `on, ${Math.ceil((review.expiresAtMs - nowMs) / 86_400_000)} day(s) left, ${1 + (review.extra?.length ?? 0)} demo phone(s)` : "off"}`);
    const carpool = await db.collection("carpools").doc(DEMO_IDS.carpool).get();
    console.log(`demo carpool: ${carpool.exists ? "present" : "missing"}`);
    if (carpool.exists) {
      const today = cairoDate(nowMs);
      const runs = await db.collection("carpools").doc(DEMO_IDS.carpool).collection("runs").where("date", "==", today).get();
      console.log(`runs today (${today}): ${runs.size}${runs.size === 0 ? " (run seed again on a school day, or the evening before)" : ""}`);
      const members = await db.collection("carpools").doc(DEMO_IDS.carpool).collection("members").get();
      for (const m of members.docs) {
        const user = await db.collection("users").doc(m.id).get();
        console.log(`demo parent ${m.get("role")}: status ${user.get("status")}, exemption ${reviewDemoActive(user.get(REVIEW_DEMO_FIELD), nowMs) ? "on" : "off"}`);
      }
    }
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
    for (const uid of uids) {
      const ref = db.collection("users").doc(uid);
      if ((await ref.get()).exists) await ref.update({ [REVIEW_DEMO_FIELD]: FieldValue.delete() });
    }
    const [a, b] = [uids[0] ?? "gone-1", uids[1] ?? "gone-2"];
    const plan = demoPlan({ driverUid: a, parentUid: b, nowMs, untilMs: nowMs, today: cairoDate(nowMs) });
    // The carpool with its runs, members and consents.
    await db.recursiveDelete(db.collection("carpools").doc(DEMO_IDS.carpool));
    for (const path of plan.removePaths) {
      if (path.includes("gone-")) continue;
      await db.doc(path).delete();
    }
    console.log("demo data removed. Now close the two demo accounts with Delete account in the app, and turn review access off.");
    return;
  }

  // ---- seed
  if (key.length < 32) refuse("OTP_HMAC_KEY is missing (the same secret the functions use)");
  if (!review) refuse(`review access is off: run \`review-access -- on\` first (${REVIEW_ACCESS_DOC})`);
  if (!isReviewPhone(review, key, phoneA, nowMs) || !isReviewPhone(review, key, phoneB, nowMs)) {
    refuse("both numbers must be on the review allow-list (run `review-access -- on` with REVIEW_PHONE, REVIEW_CODE, REVIEW_PHONE_2 and REVIEW_CODE_2)");
  }
  const untilMs = demoWindowMs(review.expiresAtMs, nowMs);
  if (untilMs === null) refuse("review access has expired");

  // The accounts, exactly as a first sign-in makes them (server parent IDs).
  const accounts = new FirebaseAccountService(auth, db);
  const driver = await accounts.signInWithPhone(phoneA, "en");
  const parent = await accounts.signInWithPhone(phoneB, "en");
  for (const uid of [driver.uid, parent.uid]) {
    const user = await db.collection("users").doc(uid).get();
    const isDemo = user.get(REVIEW_DEMO_FIELD) !== undefined || user.get("lastName") === "Demo";
    // A number that already belongs to a real parent is never turned into a demo account.
    if (user.get("status") !== "unverified" && !isDemo) refuse("one of the numbers already has a real account; use numbers that are only for the demo accounts");
  }
  const today = cairoDate(nowMs);
  const plan = demoPlan({ driverUid: driver.uid, parentUid: parent.uid, nowMs, untilMs, today });
  await lists.audit({ actorUid, action: "auth.reviewDemo.seed", target: `carpools/${DEMO_IDS.carpool}`, reasonCode: "appReview", ip: null, details: { days: Math.ceil((untilMs - nowMs) / 86_400_000) } });

  const now = Timestamp.fromMillis(nowMs);
  const batch = db.batch();
  for (const u of plan.users) {
    const email = String(u.fields.email);
    await auth.updateUser(u.uid, { email, emailVerified: true, displayName: String(u.fields.firstName) });
    await auth.setCustomUserClaims(u.uid, { verified: true });
    batch.set(
      db.collection("users").doc(u.uid),
      {
        ...u.fields,
        ...nameSearchFields(String(u.fields.firstName), String(u.fields.lastName)),
        termsAcceptedAt: now,
        termsVersion: CONSENT_VERSIONS.terms,
        updatedAt: now,
      },
      { merge: true },
    );
  }
  for (const c of plan.children) batch.set(db.collection("children").doc(c.id), { ...c.fields, createdAt: now });
  for (const v of plan.vehicles) batch.set(db.collection("vehicles").doc(v.uid), { ...v.fields, updatedAt: now });
  const s = plan.school;
  batch.set(db.collection("schools").doc(s.id), {
    ...s.fields,
    searchKeys: searchKeysFor(String(s.fields.nameAr), String(s.fields.nameEn)),
    adminSearchGrams: schoolSearchGrams(String(s.fields.nameAr), String(s.fields.nameEn)),
    location: new GeoPoint(s.lat, s.lng),
    createdAt: now,
  });
  batch.set(db.collection("areas").doc(plan.area.id), { ...plan.area.fields, center: new GeoPoint(plan.area.lat, plan.area.lng), createdAt: now });
  for (const h of plan.homes) {
    // Hidden from the nearby-parents map: real parents never see the demo parents.
    const home: HomeRecord = { ...defaultHome(nowMs), location: { lat: h.lat, lng: h.lng }, label: h.label, showOnMap: false, notifyNewParents: false };
    batch.set(db.collection("homes").doc(h.uid), {
      location: new GeoPoint(h.lat, h.lng),
      label: home.label,
      showOnMap: home.showOnMap,
      notifyNewParents: home.notifyNewParents,
      radiusKm: home.radiusKm,
      drivingSchools: home.drivingSchools,
      updatedAt: now,
    });
    const pub = buildPublicLocation(home, { status: "verified", firstName: h.firstName }, [DEMO_IDS.school], null, nowMs);
    if (pub) {
      batch.set(db.collection("parentLocations").doc(h.uid), {
        point: new GeoPoint(pub.point.lat, pub.point.lng),
        geohash: pub.geohash,
        firstName: pub.firstName,
        verified: pub.verified,
        showOnMap: pub.showOnMap,
        notifyNewParents: pub.notifyNewParents,
        radiusKm: pub.radiusKm,
        schoolIds: pub.schoolIds,
        childSchoolIds: pub.childSchoolIds,
        drivingSchoolIds: pub.drivingSchoolIds,
        announced: true,
        updatedAt: now,
      });
    }
  }
  const carpoolRef = db.collection("carpools").doc(plan.carpool.id);
  const existing = await carpoolRef.get();
  // Keep the first creation time on a second run.
  const record = existing.exists ? { ...plan.carpool.record, createdAtMs: (existing.get("createdAt") as Timestamp | undefined)?.toMillis() ?? nowMs } : plan.carpool.record;
  batch.set(carpoolRef, carpoolToDoc(record));
  for (const m of plan.members) {
    batch.set(db.collection("memberships").doc(`${m.carpoolId}_${m.uid}`), membershipToDoc(m));
    batch.set(
      carpoolRef.collection("members").doc(m.uid),
      memberToDoc({ uid: m.uid, role: m.role, firstName: m.firstName, children: m.children, car: m.car, drivingDays: m.drivingDays, pickupShared: false, joinedAtMs: nowMs }),
    );
  }
  await batch.commit();
  console.log("demo accounts, school and carpool written");

  // Consent, plan and confirm through the same flows as the app.
  const deps: CarpoolDeps = {
    store: new FirestoreCarpoolStore(db),
    now: () => Date.now(),
    limits: { ...DEFAULT_CARPOOL_LIMITS, plansPerDay: 1000, scheduleChangesPerDay: 1000 },
    newCode: newInviteCode,
    linkBase: process.env.INVITE_LINK_BASE ?? `https://${projectId}-links.web.app`,
  };
  const asDriver = { uid: driver.uid, verifiedClaim: true };
  const asParent = { uid: parent.uid, verifiedClaim: true };
  const step = async (name: string, action: () => Promise<unknown>): Promise<void> => {
    try {
      await action();
      console.log(`  ${name}: done`);
    } catch (error) {
      // Not fatal: `status` shows what is there; the owner can finish in the app.
      console.log(`  ${name}: skipped (${message(error)})`);
    }
  };
  await step("second parent's consent to the driver", () => setDriverConsent(deps, asParent, { carpoolId: DEMO_IDS.carpool, driverUid: driver.uid, accept: true }));
  const week = weekStartOf(today);
  for (const weekStart of [week, addDays(week, 7)]) {
    await step(`plan the week of ${weekStart}`, () => planWeek(deps, asDriver, { carpoolId: DEMO_IDS.carpool, weekStart }));
  }
  const runs = await carpoolRef.collection("runs").where("date", ">=", today).get();
  let confirmed = 0;
  for (const run of runs.docs) {
    if (run.get("driverUid") !== driver.uid) continue;
    try {
      await confirmRun(deps, asDriver, { carpoolId: DEMO_IDS.carpool, runId: run.id });
      confirmed++;
    } catch {
      // Already confirmed, or past its time.
    }
  }
  console.log(`  runs from today on: ${runs.size}, confirmed now: ${confirmed}`);
  console.log(`done. The demo parents' exemption ends in ${Math.ceil((untilMs - nowMs) / 86_400_000)} day(s), with the review access.`);
  console.log("Check with `review-demo -- status`, then sign in once with each demo number on your own iPhone (docs/apple-review/submission-kit.md).");
}

main().catch((error: unknown) => {
  console.error("review-demo failed:", message(error));
  process.exit(1);
});
