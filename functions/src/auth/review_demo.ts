import type { CarpoolRecord, MembershipRecord } from "../carpools/model";
import { REVIEW_ACCESS_MAX_DAYS } from "./otp_flow";
import { REVIEW_DEMO_FIELD, REVIEW_DEMO_MARK } from "./review_access";

/**
 * Demo data for Apple's App Review (docs/apple-review/audit.md, guideline
 * 2.1: "include demo account info" with a working backend). Pure plan;
 * scripts/review_demo.ts writes it.
 *
 * Two verified demo parents with FAKE data only: a driver (the account in
 * App Store Connect's Sign-In Information) and a second parent ("the
 * other side": the owner signs in with it on another phone, for example
 * for the run video). One demo school, hidden from the school search, one
 * carpool with both, one child each, the driver's car, and driving days on
 * every school day so there is a run to start whatever day the review is.
 *
 * Nothing here is personal data: the phone numbers stay in the
 * environment of the script, and the accounts are created by the same
 * code as a real sign-in (so the parent IDs come from the server).
 */
export const DEMO_IDS = {
  school: "review-demo-school",
  area: "review-demo-area",
  carpool: "review-demo-carpool",
  childOfDriver: "review-demo-child-1",
  childOfParent: "review-demo-child-2",
} as const;

/** A reserved domain (RFC 2606): mail to it reaches nobody. */
const DEMO_EMAILS = ["review-demo-1@example.com", "review-demo-2@example.com"] as const;

/** Made-up point in Maadi, Cairo (the same area as the emulator seed). */
const DEMO_POINT = { lat: 29.9602, lng: 31.2569 };
const SCHOOL_DAYS = ["sun", "mon", "tue", "wed", "thu"] as const;

/** Until when the demo parents' exemption runs: the review access expiry, capped; null when it is closed. */
export function demoWindowMs(reviewExpiresAtMs: number | null | undefined, nowMs: number): number | null {
  if (typeof reviewExpiresAtMs !== "number" || !(reviewExpiresAtMs > nowMs)) return null;
  return Math.min(reviewExpiresAtMs, nowMs + REVIEW_ACCESS_MAX_DAYS * 24 * 3600 * 1000);
}

export interface DemoInput {
  /** Account of REVIEW_PHONE (created by the sign-in code). */
  driverUid: string;
  /** Account of REVIEW_PHONE_2. */
  parentUid: string;
  nowMs: number;
  /** demoWindowMs(...). */
  untilMs: number;
  /** Cairo date "YYYY-MM-DD" (licence dates are set well after it). */
  today: string;
}

export interface DemoPlan {
  users: Array<{ uid: string; fields: Record<string, unknown> }>;
  children: Array<{ id: string; fields: Record<string, unknown> }>;
  vehicles: Array<{ uid: string; fields: Record<string, unknown> }>;
  homes: Array<{ uid: string; firstName: string; lat: number; lng: number; label: string }>;
  school: { id: string; lat: number; lng: number; fields: Record<string, unknown> };
  area: { id: string; lat: number; lng: number; fields: Record<string, unknown> };
  carpool: { id: string; record: CarpoolRecord };
  members: MembershipRecord[];
  /** Every document the seed writes. */
  paths: string[];
  /** What `remove` deletes (not the accounts: those are closed with Delete account). */
  removePaths: string[];
}

export function demoPlan(input: DemoInput): DemoPlan {
  const { driverUid, parentUid, nowMs, untilMs } = input;
  const validUntil = `${Number(input.today.slice(0, 4)) + 3}-12-31`;
  const people = [
    { uid: driverUid, firstName: "Mona", firstNameAr: "منى", childId: DEMO_IDS.childOfDriver, child: "Youssef", grade: "g3", age: 8, offset: 0.004 },
    { uid: parentUid, firstName: "Karim", firstNameAr: "كريم", childId: DEMO_IDS.childOfParent, child: "Laila", grade: "g2", age: 7, offset: -0.004 },
  ];
  const school = {
    nameAr: "مدرسة تجريبية (عرض)",
    nameEn: "Demo School (App Review)",
  };
  const area = { nameAr: "المعادي (عرض)", nameEn: "Maadi (Demo)" };

  const users = people.map((p, i) => ({
    uid: p.uid,
    fields: {
      firstName: p.firstName,
      firstNameAr: p.firstNameAr,
      lastName: "Demo",
      email: DEMO_EMAILS[i],
      emailVerified: true,
      status: "verified",
      language: "en",
      whatsappOptIn: false,
      newDeviceCheck: null,
      [REVIEW_DEMO_FIELD]: untilMs,
      // Permanent: a demo account stays confined for as long as it exists.
      [REVIEW_DEMO_MARK]: true,
    } as Record<string, unknown>,
  }));
  const children = people.map((p) => ({
    id: p.childId,
    fields: {
      ownerUid: p.uid,
      firstName: p.child,
      age: p.age,
      grade: p.grade,
      schoolName: school.nameEn,
      schoolId: DEMO_IDS.school,
      status: "approved",
      caseId: null,
      schoolIdChecked: true,
    } as Record<string, unknown>,
  }));
  const vehicles = [
    {
      uid: driverUid,
      fields: {
        driverUid,
        plate: "DEMO 123",
        model: "Demo car",
        color: "White",
        seats: 4,
        licenseExpiry: validUntil,
        carLicenseExpiry: validUntil,
        status: "approved",
        reasonCode: null,
        caseId: null,
      } as Record<string, unknown>,
    },
  ];
  const homes = people.map((p) => ({ uid: p.uid, firstName: p.firstName, lat: DEMO_POINT.lat + p.offset, lng: DEMO_POINT.lng + p.offset, label: "Maadi (demo)" }));

  const member = (i: number, role: "admin" | "member"): MembershipRecord => ({
    carpoolId: DEMO_IDS.carpool,
    uid: people[i].uid,
    status: "approved",
    role,
    firstName: people[i].firstName,
    children: [{ id: people[i].childId, firstName: people[i].child, grade: people[i].grade }],
    car: i === 0 ? { seats: 4, validUntil } : null,
    drivingDays: i === 0 ? [...SCHOOL_DAYS] : [],
    acceptedRules: true,
    acceptedContribution: true,
    requestedAtMs: nowMs,
    decidedAtMs: nowMs,
    decidedBy: driverUid,
    updatedAtMs: nowMs,
  });
  const record: CarpoolRecord = {
    id: DEMO_IDS.carpool,
    kind: "school",
    schoolId: DEMO_IDS.school,
    schoolNameAr: school.nameAr,
    schoolNameEn: school.nameEn,
    areaId: DEMO_IDS.area,
    areaNameAr: area.nameAr,
    areaNameEn: area.nameEn,
    activity: null,
    morning: "07:30",
    afternoon: "14:30",
    days: [...SCHOOL_DAYS],
    seats: 4,
    childrenCount: 2,
    memberCount: 2,
    rules: ["no_smoking", "seat_belts", "wait_5_min"],
    contribution: { amount: 50, period: "week", note: "Fuel share (demo)" },
    creatorUid: driverUid,
    creatorFirstName: people[0].firstName,
    status: "active",
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  };

  const removePaths = [
    `carpools/${DEMO_IDS.carpool}`,
    ...people.map((p) => `carpools/${DEMO_IDS.carpool}/members/${p.uid}`),
    ...people.map((p) => `memberships/${DEMO_IDS.carpool}_${p.uid}`),
    ...children.map((c) => `children/${c.id}`),
    ...vehicles.map((v) => `vehicles/${v.uid}`),
    ...people.map((p) => `homes/${p.uid}`),
    ...people.map((p) => `parentLocations/${p.uid}`),
    `areas/${DEMO_IDS.area}`,
    `schools/${DEMO_IDS.school}`,
  ];
  return {
    users,
    children,
    vehicles,
    homes,
    school: {
      id: DEMO_IDS.school,
      ...DEMO_POINT,
      fields: {
        ...school,
        kind: "school",
        governorate: "cairo",
        city: "Maadi",
        cityAr: "المعادي",
        source: "review-demo",
        sourceId: DEMO_IDS.school,
        sourceKeys: [],
        status: "active",
        addedBy: null,
        mergedInto: null,
        // Never in the parents' school search or the search index.
        searchHidden: true,
        hiddenReason: "review-demo",
      },
    },
    area: { id: DEMO_IDS.area, ...DEMO_POINT, fields: { schoolId: DEMO_IDS.school, ...area } },
    carpool: { id: DEMO_IDS.carpool, record },
    members: [member(0, "admin"), member(1, "member")],
    paths: [...people.map((p) => `users/${p.uid}`), ...removePaths],
    removePaths,
  };
}
