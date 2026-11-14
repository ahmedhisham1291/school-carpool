import type { CarInfo } from "../carpools/model";
import { addDays, daysBetween } from "../schedule/cairo";
import type { RunRecord } from "../schedule/model";
import { GRADES, type Grade } from "../verification/submission";

/**
 * Trust (Prompt 11, F17, spec sections 3 and 6): ratings and vouching
 * between parents after shared trips, guardian links (a spouse verifies
 * separately and is linked to the same children), driving papers, the
 * yearly check of children, grades and schools, and phone changes.
 *
 * Pure rules only: no Firestore here (store.ts), unit-tested.
 * PRIVACY: ratings carry stars, fixed tags and a vouch; never free text.
 */

export type TrustErrorReason =
  | "invalid-request"
  | "no-account"
  | "not-verified"
  | "suspended"
  | "not-found"
  | "self"
  | "no-shared-trip"
  | "already-rated"
  | "not-allowed"
  | "already-linked"
  | "already-requested"
  | "not-your-child"
  | "too-many-guardians"
  | "invalid-state"
  | "year-not-open"
  | "children-changed"
  | "rate-limited"
  // Phone change (re-verification with a WhatsApp code and a fresh selfie)
  | "phone-same"
  | "phone-taken"
  | "no-selfie"
  | "no-reference"
  | "selfie-mismatch"
  | "check-unavailable";

export class TrustError extends Error {
  constructor(
    readonly reason: TrustErrorReason,
    readonly retryAfterMs = 0,
  ) {
    super(reason);
    this.name = "TrustError";
  }
}

export const TRUST_ERROR_CODES: Record<TrustErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "no-account": "failed-precondition",
  "not-verified": "permission-denied",
  suspended: "permission-denied",
  "not-found": "not-found",
  self: "invalid-argument",
  "no-shared-trip": "failed-precondition",
  "already-rated": "already-exists",
  "not-allowed": "permission-denied",
  "already-linked": "already-exists",
  "already-requested": "already-exists",
  "not-your-child": "permission-denied",
  "too-many-guardians": "failed-precondition",
  "invalid-state": "failed-precondition",
  "year-not-open": "failed-precondition",
  "children-changed": "failed-precondition",
  "rate-limited": "resource-exhausted",
  "phone-same": "invalid-argument",
  "phone-taken": "already-exists",
  "no-selfie": "failed-precondition",
  "no-reference": "failed-precondition",
  "selfie-mismatch": "permission-denied",
  "check-unavailable": "unavailable",
};

const ID = /^[A-Za-z0-9_-]{1,128}$/;

export function record(v: unknown): Record<string, unknown> {
  if (v === null || typeof v !== "object" || Array.isArray(v)) throw new TrustError("invalid-request");
  return v as Record<string, unknown>;
}

export function docId(v: unknown): string {
  if (typeof v !== "string" || !ID.test(v)) throw new TrustError("invalid-request");
  return v;
}

// --------------------------------------------------------------------------
// Ratings and vouching (F17)
// --------------------------------------------------------------------------

/** Fixed tags (codes shared with the app). No free text, so nothing to moderate. */
export const POSITIVE_TAGS = ["on-time", "safe-driving", "friendly", "clear"] as const;
export const CONCERN_TAGS = ["late", "unsafe-driving", "rude"] as const;
export const RATING_TAGS = [...POSITIVE_TAGS, ...CONCERN_TAGS] as const;
export type RatingTag = (typeof RATING_TAGS)[number];

/** A rating is shown as an average only from this many ratings (one rating stays private). */
export const MIN_RATINGS_FOR_AVERAGE = 3;
/** Most parents listed as "to rate" at once. */
export const MAX_RATEABLE = 30;

export interface RatingInput {
  rateeUid: string;
  stars: number;
  tags: RatingTag[];
  vouch: boolean;
}

export function parseRating(data: unknown): RatingInput {
  const raw = record(data);
  const rateeUid = docId(raw.uid);
  const stars = raw.stars;
  if (typeof stars !== "number" || !Number.isInteger(stars) || stars < 1 || stars > 5) throw new TrustError("invalid-request");
  const list = raw.tags === undefined ? [] : raw.tags;
  if (!Array.isArray(list) || list.length > RATING_TAGS.length) throw new TrustError("invalid-request");
  const tags: RatingTag[] = [];
  for (const t of list) {
    if (typeof t !== "string" || !(RATING_TAGS as readonly string[]).includes(t)) throw new TrustError("invalid-request");
    if (!tags.includes(t as RatingTag)) tags.push(t as RatingTag);
  }
  const vouch = raw.vouch === undefined ? false : raw.vouch;
  if (typeof vouch !== "boolean") throw new TrustError("invalid-request");
  // Vouching means "I trust this parent": not with a low rating or a concern.
  if (vouch && (stars < 4 || tags.some((t) => (CONCERN_TAGS as readonly string[]).includes(t)))) throw new TrustError("invalid-request");
  return { rateeUid, stars, tags: tags.sort(), vouch };
}

/** "YYYY-MM" of a Cairo date: one rating per pair in it. */
export function monthOf(date: string): string {
  return date.slice(0, 7);
}

export function ratingId(month: string, raterUid: string, rateeUid: string): string {
  return `${month}_${raterUid}_${rateeUid}`;
}

/** Low stars or a safety concern go to the admin queue (ratingFlags). */
export function needsReview(r: Pick<RatingInput, "stars" | "tags">): boolean {
  return r.stars <= 2 || r.tags.includes("unsafe-driving");
}

/** What the rating rules need of a trip (trips/{id}, Prompt 10). */
export interface TripLike {
  id: string;
  carpoolId: string;
  date: string;
  status: string;
  driverUid: string;
  stops: Array<{ parentUid: string; state: string }>;
}

export interface SharedTrip {
  otherUid: string;
  tripId: string;
  carpoolId: string;
  date: string;
  /** The other parent's part on that trip. */
  otherRole: "driver" | "parent";
}

/** A child was carried on this stop (dropped at school or home, or received). */
function carried(state: string): boolean {
  return state === "dropped" || state === "received";
}

/**
 * Parents [me] shared a FINISHED trip with since [sinceDate] (inclusive):
 * the driver and each parent whose child the driver carried. Only the
 * latest trip per parent. Parents of two children on the same run did
 * not travel together, so they are not a pair.
 */
export function sharedTrips(trips: TripLike[], me: string, sinceDate: string): Map<string, SharedTrip> {
  const out = new Map<string, SharedTrip>();
  const sorted = [...trips].sort((a, b) => (a.date === b.date ? a.id.localeCompare(b.id) : a.date.localeCompare(b.date)));
  for (const t of sorted) {
    if (t.status !== "ended" || t.date < sinceDate) continue;
    const parents = new Set(t.stops.filter((s) => carried(s.state)).map((s) => s.parentUid));
    if (t.driverUid === me) {
      for (const p of parents) if (p !== me) out.set(p, { otherUid: p, tripId: t.id, carpoolId: t.carpoolId, date: t.date, otherRole: "parent" });
    } else if (parents.has(me) && t.driverUid) {
      out.set(t.driverUid, { otherUid: t.driverUid, tripId: t.id, carpoolId: t.carpoolId, date: t.date, otherRole: "driver" });
    }
  }
  return out;
}

export interface TrustSummary {
  count: number;
  sum: number;
  /** Distinct parents who vouched (at most MAX_VOUCHERS kept). */
  voucherUids: string[];
}

const MAX_VOUCHERS = 500;

export function emptySummary(): TrustSummary {
  return { count: 0, sum: 0, voucherUids: [] };
}

export function addRating(s: TrustSummary | null, stars: number, vouch: boolean, raterUid: string): TrustSummary {
  const base = s ?? emptySummary();
  const vouchers = vouch && !base.voucherUids.includes(raterUid) && base.voucherUids.length < MAX_VOUCHERS ? [...base.voucherUids, raterUid] : base.voucherUids;
  return { count: base.count + 1, sum: base.sum + stars, voucherUids: vouchers };
}

export interface SummaryView {
  ratings: number;
  /** One decimal; null below MIN_RATINGS_FOR_AVERAGE. */
  average: number | null;
  vouches: number;
}

export function summaryView(s: TrustSummary | null): SummaryView {
  const x = s ?? emptySummary();
  const average = x.count >= MIN_RATINGS_FOR_AVERAGE ? Math.round((x.sum / x.count) * 10) / 10 : null;
  return { ratings: x.count, average, vouches: x.voucherUids.length };
}

// --------------------------------------------------------------------------
// Guardian links (spec section 6, "Who may drive"; section 9 "Guardian link")
// --------------------------------------------------------------------------

export const RELATIONS = ["father", "mother", "guardian"] as const;
export type Relation = (typeof RELATIONS)[number];

/** Most other adults linked to one child (besides the child's parent). */
export const MAX_ACTIVE_LINKS_PER_CHILD = 2;

export type LinkStatus = "review" | "active" | "rejected" | "removed";

export interface GuardianLink {
  /** "{childId}_{guardianUid}". */
  id: string;
  childId: string;
  childFirstName: string;
  ownerUid: string;
  ownerFirstName: string;
  guardianUid: string;
  guardianFirstName: string;
  relation: Relation;
  status: LinkStatus;
  createdAtMs: number;
  decidedAtMs: number | null;
  decidedBy: string | null;
  updatedAtMs: number;
}

export type GuardianRequestStatus = "requested" | "accepted" | "declined" | "cancelled";

export interface GuardianRequest {
  /** "{ownerUid}_{guardianUid}". */
  id: string;
  ownerUid: string;
  guardianUid: string;
  guardianFirstName: string;
  relation: Relation;
  status: GuardianRequestStatus;
  createdAtMs: number;
  updatedAtMs: number;
}

export function linkId(childId: string, guardianUid: string): string {
  return `${childId}_${guardianUid}`;
}

export function guardianRequestId(ownerUid: string, guardianUid: string): string {
  return `${ownerUid}_${guardianUid}`;
}

const PARENT_ID = /^[2-9A-HJ-NP-Z]{8}$/;

export function parseGuardianRequest(data: unknown): { parentId: string; relation: Relation } {
  const raw = record(data);
  const parentId = typeof raw.parentId === "string" ? raw.parentId.replace(/[\s-]/g, "").toUpperCase() : "";
  if (!PARENT_ID.test(parentId)) throw new TrustError("invalid-request");
  if (typeof raw.relation !== "string" || !(RELATIONS as readonly string[]).includes(raw.relation)) throw new TrustError("invalid-request");
  return { parentId, relation: raw.relation as Relation };
}

/**
 * Admin review "if needed": a guardian who is not a father or mother, or a
 * child who already has another linked adult besides their parent.
 */
export function linkNeedsReview(relation: Relation, otherActiveLinks: number): boolean {
  return relation === "guardian" || otherActiveLinks > 0;
}

/** A link that still gives access, or waits for an admin. */
export function linkLive(l: Pick<GuardianLink, "status">): boolean {
  return l.status === "active" || l.status === "review";
}

// --------------------------------------------------------------------------
// Driving papers (spec section 3: store both expiry dates, remind before
// expiry, block driving days after it)
// --------------------------------------------------------------------------

export function parseReminderDays(value: string): number[] {
  const days = value
    .split(",")
    .map((x) => Number(x.trim()))
    .filter((n) => Number.isInteger(n) && n > 0 && n <= 90);
  return days.length > 0 ? [...new Set(days)].sort((a, b) => b - a) : [30, 7, 1];
}

export type LicenceNotice = { kind: "expiring"; days: number } | { kind: "expired" } | null;

/** The notice due today for papers valid until [validUntil] (inclusive). */
export function licenceNotice(validUntil: string, today: string, reminderDays: number[]): LicenceNotice {
  const d = daysBetween(today, validUntil);
  if (d < 0) return { kind: "expired" };
  return reminderDays.includes(d) ? { kind: "expiring", days: d } : null;
}

/** A run [car] cannot carry: no usable car, the papers expire before the run, or too many children. */
export function runInvalid(run: Pick<RunRecord, "date" | "riders">, car: CarInfo | null): boolean {
  return car === null || run.date > car.validUntil || run.riders.length > car.seats;
}

// --------------------------------------------------------------------------
// Yearly check (spec section 3: "before the first term each parent
// confirms children, grades and schools")
// --------------------------------------------------------------------------

export interface YearSettings {
  /** "MM-DD" in Cairo. */
  start: string;
  openDays: number;
  graceDays: number;
  firstYear: number;
}

export function yearSettings(start: string, openDays: number, graceDays: number, firstYear: number): YearSettings {
  const ok = /^(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(start);
  return {
    start: ok ? start : "09-01",
    openDays: Number.isInteger(openDays) && openDays >= 0 && openDays <= 120 ? openDays : 21,
    graceDays: Number.isInteger(graceDays) && graceDays >= 0 && graceDays <= 120 ? graceDays : 14,
    firstYear: Number.isInteger(firstYear) ? firstYear : 2027,
  };
}

export interface YearWindow {
  /** The calendar year the school year starts in (2026 = 2026-27). */
  year: number;
  opensOn: string;
  startsOn: string;
  deadline: string;
}

function windowOf(year: number, s: YearSettings): YearWindow {
  const startsOn = `${year}-${s.start}`;
  return { year, opensOn: addDays(startsOn, -s.openDays), startsOn, deadline: addDays(startsOn, s.graceDays) };
}

/** The school year whose check opened most recently, or null before the first checked year. */
export function yearWindow(today: string, s: YearSettings): YearWindow | null {
  const y = Number(today.slice(0, 4));
  const current = windowOf(y, s);
  const w = today >= current.opensOn ? current : windowOf(y - 1, s);
  return w.year >= s.firstYear ? w : null;
}

export type YearState = "none" | "due" | "overdue" | "done";

/**
 * A parent with approved children confirms once per school year. A parent
 * verified after the check opened has just shown their children: done.
 */
export function yearState(w: YearWindow | null, today: string, a: { confirmedYear: number | null; verifiedOn: string | null; hasChildren: boolean }): YearState {
  if (!w || !a.hasChildren) return "none";
  if (a.confirmedYear !== null && a.confirmedYear >= w.year) return "done";
  if (a.verifiedOn !== null && a.verifiedOn >= w.opensOn) return "done";
  return today > w.deadline ? "overdue" : "due";
}

/** Reminder days: when the check opens, when the year starts, the day before the deadline. */
export function yearReminderStage(w: YearWindow, today: string): "open" | "start" | "last" | null {
  if (today === w.opensOn) return "open";
  if (today === w.startsOn) return "start";
  if (today === addDays(w.deadline, -1) && w.deadline !== w.startsOn) return "last";
  return null;
}

export interface YearAnswer {
  childId: string;
  /** false: the child left this school (leaves its carpools and chats). */
  stays: boolean;
  /** The grade for the new year (stays only). */
  grade: Grade | null;
}

/**
 * confirmSchoolYear input: { year, children: [{ childId, stays, grade? }] }.
 * Every approved child of the parent must be answered, once each.
 */
export function parseYearAnswers(data: unknown, childIds: string[]): { year: number; answers: YearAnswer[] } {
  const raw = record(data);
  const year = raw.year;
  if (typeof year !== "number" || !Number.isInteger(year)) throw new TrustError("invalid-request");
  if (!Array.isArray(raw.children) || raw.children.length > 20) throw new TrustError("invalid-request");
  const answers: YearAnswer[] = [];
  for (const item of raw.children) {
    const a = record(item);
    const childId = docId(a.childId);
    if (typeof a.stays !== "boolean") throw new TrustError("invalid-request");
    let grade: Grade | null = null;
    if (a.stays) {
      if (!(GRADES as readonly string[]).includes(String(a.grade))) throw new TrustError("invalid-request");
      grade = a.grade as Grade;
    }
    if (answers.some((x) => x.childId === childId)) throw new TrustError("invalid-request");
    answers.push({ childId, stays: a.stays, grade });
  }
  const asked = [...childIds].sort();
  const got = answers.map((a) => a.childId).sort();
  if (asked.length !== got.length || asked.some((id, i) => id !== got[i])) throw new TrustError("children-changed");
  return { year, answers };
}
