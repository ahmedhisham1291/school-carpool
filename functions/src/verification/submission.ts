import { isRealDate, parseNationalId } from "./national_id";

/**
 * Validation of what the app submits for review (F2, F3). Pure functions,
 * unit-tested. The app checks the same rules as the parent types
 * (lib/features/verification), the server has the last word.
 */

export type VerificationErrorReason =
  | "invalid-request"
  | "no-account"
  | "signup-incomplete"
  | "suspended"
  | "case-open"
  | "invalid-name"
  | "invalid-national-id"
  | "invalid-expiry"
  | "id-expired"
  | "invalid-child"
  | "unknown-school"
  | "invalid-driver"
  | "license-expired"
  | "missing-children"
  | "too-many-children"
  | "outdated-consent"
  | "missing-upload"
  | "duplicate-id"
  | "banned-id"
  | "not-found"
  | "already-decided"
  | "invalid-decision"
  | "own-case"
  | "name-check-missing"
  | "not-admin";

export class VerificationError extends Error {
  constructor(
    readonly reason: VerificationErrorReason,
    readonly details: Record<string, unknown> = {},
  ) {
    super(reason);
    this.name = "VerificationError";
  }
}

/**
 * Consent to process ID, face and child data (spec section 9, "Consent
 * record"; Law 151). Must match lib/features/auth/legal_documents.dart.
 */
export const VERIFICATION_CONSENT_VERSIONS = {
  id: "2026-11-13",
  face: "2026-11-13",
  childData: "2026-11-13",
} as const;

export type VerificationConsent = keyof typeof VERIFICATION_CONSENT_VERSIONS;

/** School grades, kindergarten to grade 12 (codes shared with the app). */
export const GRADES = ["kg1", "kg2", "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8", "g9", "g10", "g11", "g12"] as const;
export type Grade = (typeof GRADES)[number];

export const MAX_CHILDREN = 10;
export const CHILD_MIN_AGE = 2;
export const CHILD_MAX_AGE = 19;
export const MAX_PASSENGER_SEATS = 8;
/** An Egyptian ID card is valid for 7 years; allow some slack. */
export const MAX_ID_VALID_YEARS = 10;
export const MAX_LICENSE_VALID_YEARS = 15;

export type LivenessChallenge = "left" | "right";

export interface IdentitySubmission {
  firstName: string;
  lastName: string;
  /** 14 ASCII digits. Hashed right away, never stored. */
  nationalId: string;
  /** "YYYY-MM-DD", from the back of the ID. The only field kept from it. */
  idExpiry: string;
  livenessChallenge: LivenessChallenge;
}

export interface ChildSubmission {
  /** Slot chosen by the app; names the school ID upload. */
  ref: string;
  /** Set when a verified parent edits an existing child. */
  childId: string | null;
  firstName: string;
  age: number;
  grade: Grade;
  /** The school picked from the schools list, or the parent's own "Other" school (F4). */
  schoolId: string;
  /** The name the app showed; the server keeps it only if it is one of the school's names. */
  schoolName: string;
}

export interface DriverSubmission {
  plate: string;
  model: string;
  color: string;
  seats: number;
  licenseExpiry: string;
  carLicenseExpiry: string;
}

export interface Submission {
  identity: IdentitySubmission | null;
  children: ChildSubmission[];
  driver: DriverSubmission | null;
  consents: VerificationConsent[];
}

/** Upload names in verification/{uid}/pending/ (storage.rules allows only these). */
export const IDENTITY_FILES = ["id_front.jpg", "id_back.jpg", "selfie.jpg", "selfie_turn.jpg"] as const;
export const DRIVER_FILES = ["license.jpg", "car_license.jpg"] as const;
export function schoolIdFile(ref: string): string {
  return `school_id_${ref}.jpg`;
}

export function requiredFiles(submission: Submission): string[] {
  return [
    ...(submission.identity ? IDENTITY_FILES : []),
    ...submission.children.map((child) => schoolIdFile(child.ref)),
    ...(submission.driver ? DRIVER_FILES : []),
  ];
}

// Letters of any script, spaces, apostrophes, dots and hyphens.
const NAME = /^[\p{L}\p{M}][\p{L}\p{M} .'’-]{0,38}[\p{L}\p{M}.]$/u;
const FREE_TEXT = /^[\p{L}\p{M}\p{N} .,'()&’/-]+$/u;
/** Child slots c1 to c10 (MAX_CHILDREN); storage.rules allows the same names. */
const REF = /^c([1-9]|10)$/;
const DOC_ID = /^[A-Za-z0-9]{1,40}$/;
/** School document IDs: generated ones and the import's "osm-n123" (catalog.ts). */
const SCHOOL_ID = /^[A-Za-z0-9_-]{1,64}$/;
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

export function cleanName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().replace(/\s+/g, " ");
  return NAME.test(trimmed) ? trimmed : null;
}

function cleanText(value: unknown, min: number, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().replace(/\s+/g, " ");
  if (trimmed.length < min || trimmed.length > max) return null;
  return FREE_TEXT.test(trimmed) ? trimmed : null;
}

/** "YYYY-MM-DD" when it is a real date, else null. */
export function cleanDate(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const match = DATE.exec(value);
  if (!match) return null;
  return isRealDate(Number(match[1]), Number(match[2]), Number(match[3])) ? value : null;
}

export function addYears(date: string, years: number): string {
  const [y, m, d] = date.split("-");
  return `${Number(y) + years}-${m}-${d}`;
}

/** "YYYY-MM-DD" of [nowMs] in Cairo. */
export function cairoDate(nowMs: number): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Africa/Cairo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date(nowMs));
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function parseIdentity(raw: Record<string, unknown>, today: string): IdentitySubmission {
  const firstName = cleanName(raw.firstName);
  const lastName = cleanName(raw.lastName);
  if (!firstName || !lastName) throw new VerificationError("invalid-name");
  const nationalId = parseNationalId(raw.nationalId, today);
  if (!nationalId) throw new VerificationError("invalid-national-id");
  const idExpiry = cleanDate(raw.idExpiry);
  if (!idExpiry || idExpiry > addYears(today, MAX_ID_VALID_YEARS)) throw new VerificationError("invalid-expiry");
  if (idExpiry < today) throw new VerificationError("id-expired");
  const challenge = raw.livenessChallenge;
  if (challenge !== "left" && challenge !== "right") throw new VerificationError("invalid-request");
  return { firstName, lastName, nationalId, idExpiry, livenessChallenge: challenge };
}

function parseChild(value: unknown): ChildSubmission {
  const raw = record(value);
  if (!raw) throw new VerificationError("invalid-child");
  const ref = typeof raw.ref === "string" && REF.test(raw.ref) ? raw.ref : null;
  const childId = raw.childId === undefined || raw.childId === null ? null : raw.childId;
  const firstName = cleanName(raw.firstName);
  const age = raw.age;
  const grade = GRADES.includes(raw.grade as Grade) ? (raw.grade as Grade) : null;
  const schoolId = typeof raw.schoolId === "string" && SCHOOL_ID.test(raw.schoolId) ? raw.schoolId : null;
  const schoolName = raw.schoolName === undefined || raw.schoolName === null ? "" : cleanText(raw.schoolName, 2, 120);
  const ageOk = typeof age === "number" && Number.isInteger(age) && age >= CHILD_MIN_AGE && age <= CHILD_MAX_AGE;
  const idOk = childId === null || (typeof childId === "string" && DOC_ID.test(childId));
  if (!ref || !firstName || !ageOk || !grade || !schoolId || schoolName === null || !idOk) {
    throw new VerificationError("invalid-child", { ref });
  }
  return { ref, childId: childId as string | null, firstName, age: age as number, grade, schoolId, schoolName };
}

function parseDriver(raw: Record<string, unknown>, today: string): DriverSubmission {
  const plate = cleanText(raw.plate, 2, 20);
  const model = cleanText(raw.model, 2, 40);
  const color = cleanText(raw.color, 2, 30);
  const seats = raw.seats;
  const seatsOk = typeof seats === "number" && Number.isInteger(seats) && seats >= 1 && seats <= MAX_PASSENGER_SEATS;
  const licenseExpiry = cleanDate(raw.licenseExpiry);
  const carLicenseExpiry = cleanDate(raw.carLicenseExpiry);
  if (!plate || !model || !color || !seatsOk || !licenseExpiry || !carLicenseExpiry) {
    throw new VerificationError("invalid-driver");
  }
  const latest = addYears(today, MAX_LICENSE_VALID_YEARS);
  if (licenseExpiry > latest || carLicenseExpiry > latest) throw new VerificationError("invalid-driver");
  if (licenseExpiry < today || carLicenseExpiry < today) throw new VerificationError("license-expired");
  return { plate, model, color, seats: seats as number, licenseExpiry, carLicenseExpiry };
}

function parseConsents(value: unknown, needed: VerificationConsent[]): VerificationConsent[] {
  const raw = record(value);
  if (!raw) throw new VerificationError("invalid-request");
  for (const type of needed) {
    if (raw[type] !== VERIFICATION_CONSENT_VERSIONS[type]) throw new VerificationError("outdated-consent");
  }
  return needed;
}

/**
 * Validates a submission.
 * - A parent who is not verified yet sends the identity part and at least
 *   one child (spec section 3, steps 3 to 5); driving is optional (step 6).
 * - A verified parent sends only children (add or edit) and/or driving
 *   details, never the identity part (re-verification comes later).
 */
export function parseSubmission(data: unknown, options: { today: string; verified: boolean }): Submission {
  const raw = record(data);
  if (!raw) throw new VerificationError("invalid-request");
  const identityRaw = raw.identity === undefined || raw.identity === null ? null : record(raw.identity);
  const driverRaw = raw.driver === undefined || raw.driver === null ? null : record(raw.driver);
  if ((raw.identity != null && !identityRaw) || (raw.driver != null && !driverRaw) || !Array.isArray(raw.children)) {
    throw new VerificationError("invalid-request");
  }
  if (options.verified ? identityRaw !== null : identityRaw === null) throw new VerificationError("invalid-request");

  const identity = identityRaw ? parseIdentity(identityRaw, options.today) : null;
  if (raw.children.length > MAX_CHILDREN) throw new VerificationError("too-many-children");
  const children = raw.children.map(parseChild);
  if (new Set(children.map((c) => c.ref)).size !== children.length) throw new VerificationError("invalid-child");
  const editIds = children.flatMap((c) => (c.childId ? [c.childId] : []));
  if (new Set(editIds).size !== editIds.length) throw new VerificationError("invalid-child");
  if (!options.verified && editIds.length > 0) throw new VerificationError("invalid-child");
  if (identity && children.length === 0) throw new VerificationError("missing-children");
  const driver = driverRaw ? parseDriver(driverRaw, options.today) : null;
  if (!identity && children.length === 0 && !driver) throw new VerificationError("invalid-request");

  const needed: VerificationConsent[] = [
    ...(identity ? (["id", "face"] as const) : []),
    ...(children.length > 0 ? (["childData"] as const) : []),
  ];
  const consents = parseConsents(raw.consents, needed);
  return { identity, children, driver, consents };
}

/** Reasons an admin can give (codes shared with the app, which translates them). */
export const REJECTION_REASONS = [
  "photo_unclear",
  "id_mismatch",
  "selfie_mismatch",
  "liveness_failed",
  "id_expired",
  "school_id_unclear",
  "child_name_mismatch",
  "license_invalid",
  "other",
] as const;
export type RejectionReason = (typeof REJECTION_REASONS)[number];

/**
 * Parent and child name check (spec section 3): the child's full name on
 * the school ID contains the father's name from the national ID (for a
 * mother, the husband's name on the back of her ID), or the parent showed
 * a birth certificate, which is viewed and not stored.
 */
export const NAME_CHECKS = ["match", "birth_certificate"] as const;
export type NameCheck = (typeof NAME_CHECKS)[number];

export interface Decision {
  caseId: string;
  /** Approve only; required by decideVerification when the case has children. */
  nameCheck: NameCheck | null;
  approve: boolean;
  reasonCode: RejectionReason | null;
  note: string | null;
  /** Reject only: put the ID on the ban list and suspend the account. */
  ban: boolean;
}

export function parseDecision(data: unknown): Decision {
  const raw = record(data);
  if (!raw || typeof raw.caseId !== "string" || !DOC_ID.test(raw.caseId)) throw new VerificationError("invalid-decision");
  const decision = raw.decision;
  if (decision !== "approve" && decision !== "reject") throw new VerificationError("invalid-decision");
  const note = raw.note === undefined || raw.note === null ? null : raw.note;
  if (note !== null && (typeof note !== "string" || note.trim().length === 0 || note.length > 500)) {
    throw new VerificationError("invalid-decision");
  }
  const ban = raw.ban === true;
  if (decision === "approve") {
    if (raw.reasonCode != null || ban) throw new VerificationError("invalid-decision");
    const nameCheck = raw.nameCheck == null ? null : raw.nameCheck;
    if (nameCheck !== null && !NAME_CHECKS.includes(nameCheck as NameCheck)) throw new VerificationError("invalid-decision");
    return {
      caseId: raw.caseId,
      nameCheck: nameCheck as NameCheck | null,
      approve: true,
      reasonCode: null,
      note: note === null ? null : note.trim(),
      ban: false,
    };
  }
  if (raw.nameCheck != null) throw new VerificationError("invalid-decision");
  const reasonCode = REJECTION_REASONS.includes(raw.reasonCode as RejectionReason) ? (raw.reasonCode as RejectionReason) : null;
  if (!reasonCode) throw new VerificationError("invalid-decision");
  if (reasonCode === "other" && note === null) throw new VerificationError("invalid-decision");
  return { caseId: raw.caseId, nameCheck: null, approve: false, reasonCode, note: note === null ? null : note.trim(), ban };
}
