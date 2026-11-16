/**
 * The App Review demo seed and status, shared by `review-demo` and
 * `review-access -- on` (which seeds by itself when both demo numbers are
 * given). FAKE data only; see scripts/review_demo.ts for what is written.
 */
import type { Auth } from "firebase-admin/auth";
import { GeoPoint, Timestamp, type Firestore } from "firebase-admin/firestore";
import { schoolSearchGrams } from "../src/admin_panel/school_search";
import type { FirestoreListsStore } from "../src/admin_panel/store";
import { FirebaseAccountService } from "../src/auth/accounts";
import { CONSENT_TEXT_KEYS, consentText } from "../src/auth/consent_texts";
import { CONSENT_VERSIONS, REQUIRED_CONSENTS } from "../src/auth/consents";
import { textHash } from "../src/auth/signature";
import { isReviewPhone } from "../src/auth/otp_flow";
import { REVIEW_ACCESS_DOC, isReviewDemoAccount, readReviewAccess, reviewDemoState } from "../src/auth/review_access";
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
import { VERIFICATION_CONSENT_VERSIONS } from "../src/verification/submission";

/** A refusal with a reason the script prints (never a number or code). */
export class SeedRefused extends Error {}

function message(error: unknown): string {
  return error instanceof Error ? error.message : "unknown";
}

/** Prints the review window, the demo carpool, today's runs and each demo parent (no numbers). */
export async function printReviewDemoStatus(db: Firestore): Promise<void> {
  const nowMs = Date.now();
  const review = await readReviewAccess(db);
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
      const state = reviewDemoState(user.data(), m.id, review, nowMs);
      console.log(`demo parent ${m.get("role")} (parent ID ${String(user.get("parentId") ?? "?")}): status ${user.get("status")}, demo access ${state === "open" ? "open (exemption on)" : "CLOSED (run seed again after review-access on)"}`);
    }
  }
}

export interface SeedContext {
  db: Firestore;
  auth: Auth;
  lists: FirestoreListsStore;
  actorUid: string;
  projectId: string;
  /** OTP_HMAC_KEY (the same secret the functions use). */
  key: string;
  /** The two allow-listed demo numbers (E.164), never printed. */
  phoneA: string;
  phoneB: string;
}

/** Creates or refreshes the demo accounts, school, carpool and runs. Safe to run again. */
export async function seedReviewDemo(ctx: SeedContext): Promise<void> {
  const { db, auth, lists, actorUid, projectId, key, phoneA, phoneB } = ctx;
  const nowMs = Date.now();
  const review = await readReviewAccess(db);
  if (key.length < 32) throw new SeedRefused("OTP_HMAC_KEY is missing (the same secret the functions use)");
  if (!review) throw new SeedRefused(`review access is off: run \`review-access -- on\` first (${REVIEW_ACCESS_DOC})`);
  if (!isReviewPhone(review, key, phoneA, nowMs) || !isReviewPhone(review, key, phoneB, nowMs)) {
    throw new SeedRefused("both numbers must be on the review allow-list (run `review-access -- on` with REVIEW_PHONE, REVIEW_CODE, REVIEW_PHONE_2 and REVIEW_CODE_2)");
  }
  const untilMs = demoWindowMs(review.expiresAtMs, nowMs);
  if (untilMs === null) throw new SeedRefused("review access has expired");

  // The accounts, exactly as a first sign-in makes them (server parent IDs).
  const accounts = new FirebaseAccountService(auth, db);
  const driver = await accounts.signInWithPhone(phoneA, "en");
  const parent = await accounts.signInWithPhone(phoneB, "en");
  for (const uid of [driver.uid, parent.uid]) {
    const user = await db.collection("users").doc(uid).get();
    const isDemo = isReviewDemoAccount(user.data());
    // A number that already belongs to a real parent is never turned into a demo account.
    if (user.get("status") !== "unverified" && !isDemo) throw new SeedRefused("one of the numbers already has a real account; use numbers that are only for the demo accounts");
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
        // R3: the typed names of the signed consents (the copy under Privacy shows them).
        signedNames: Object.fromEntries(Object.keys(CONSENT_TEXT_KEYS).map((t) => [t, `${String(u.fields.firstName)} ${String(u.fields.lastName)}`])),
        updatedAt: now,
      },
      { merge: true },
    );
    // The consent records a real sign-up and ID check would leave (current
    // versions, incl. storage abroad and the guardian declaration), so the
    // Privacy screen shows them as given and the app never asks again.
    // Fixed IDs: a second seed overwrites, never duplicates.
    const consents: Array<[string, string]> = [
      ...REQUIRED_CONSENTS.map((t): [string, string] => [t, CONSENT_VERSIONS[t]]),
      ...(Object.entries(VERIFICATION_CONSENT_VERSIONS) as Array<[string, string]>),
    ];
    const language = u.fields.language === "en" ? "en" : "ar";
    for (const [type, version] of consents) {
      // R3: the sensitive-data consents carry a signature like a real one
      // (the exact text's hash), marked as the demo's (no key, no device).
      const text = type in CONSENT_TEXT_KEYS ? consentText(type, version, language) : null;
      batch.set(db.collection("users").doc(u.uid).collection("consents").doc(`review-demo-${type}`), {
        type,
        version,
        acceptedAt: now,
        withdrawnAt: null,
        source: "reviewDemo",
        ...(text === null
          ? {}
          : { signature: { method: "deviceAuth", nameHash: "review-demo", nameMatched: true, textHash: textHash(text), language, deviceKey: null, platform: "ios", appVersion: "review-demo" } }),
      });
    }
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
  // Only these two accounts get the exemption, and only while the access is on (reviewDemoState).
  batch.update(db.doc(REVIEW_ACCESS_DOC), { demoUids: [driver.uid, parent.uid] });
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
