import { createHash } from "node:crypto";
import type { CarpoolDeps } from "../carpools/flow";
import { cairoDate } from "../carpools/model";
import { newEvent, type OutboxEvent } from "../notifications/model";
import { addDays } from "../schedule/cairo";
import { leaveEmptyCarpools, removeChildFromCarpools, updateChildGrade } from "./carpools";
import {
  addRating,
  docId,
  guardianRequestId,
  linkId,
  linkLive,
  linkNeedsReview,
  MAX_ACTIVE_LINKS_PER_CHILD,
  MAX_RATEABLE,
  monthOf,
  needsReview,
  parseGuardianRequest,
  parseRating,
  parseYearAnswers,
  ratingId,
  record,
  sharedTrips,
  summaryView,
  TrustError,
  yearState,
  yearWindow,
  type GuardianLink,
  type GuardianRequest,
  type RatingTag,
  type Relation,
  type SummaryView,
  type TripLike,
  type TrustSummary,
  type YearSettings,
  type YearState,
} from "./model";

/**
 * Trust flows (Prompt 11, F17) over a [TrustStore]. Every write happens
 * here (Cloud Functions); the app only calls these. Logs carry counts and
 * reasons only, never names.
 */

export interface TrustAccount {
  uid: string;
  /** banned accounts read as "suspended". */
  status: string;
  firstName: string;
  parentId: string;
  /** Cairo date of the last approval of the account, or null. */
  verifiedOn: string | null;
  /** School year (start year) the parent last confirmed, or null. */
  yearConfirmed: number | null;
  yearCheckOverdue: boolean;
}

export interface ChildLite {
  id: string;
  ownerUid: string;
  firstName: string;
  grade: string;
  schoolId: string;
  schoolName: string;
  status: string;
}

export interface RatingRecord {
  id: string;
  month: string;
  raterUid: string;
  rateeUid: string;
  stars: number;
  tags: RatingTag[];
  vouch: boolean;
  tripId: string;
  carpoolId: string;
  createdAtMs: number;
}

export type FlagOutcome = "no-issue" | "contacted" | "escalated";
export const FLAG_OUTCOMES: readonly FlagOutcome[] = ["no-issue", "contacted", "escalated"];

export interface RatingFlag {
  id: string;
  ratingId: string;
  raterUid: string;
  rateeUid: string;
  stars: number;
  tags: RatingTag[];
  carpoolId: string;
  status: "open" | "handled";
  outcome: FlagOutcome | null;
  createdAtMs: number;
}

export interface YearChange {
  childId: string;
  /** New grade when the child stays, null when the child left the school. */
  grade: string | null;
}

export type TrustLimitKind = "ratings" | "guardianRequests" | "summaries";

export interface TrustStore {
  account(uid: string): Promise<TrustAccount | null>;
  accountByParentId(parentId: string): Promise<TrustAccount | null>;
  /** Finished trips (status ended) with [uid] as driver or parent, on or after [sinceDate]. */
  finishedTrips(uid: string, sinceDate: string): Promise<TripLike[]>;
  /** Parents [raterUid] already rated in [month]. */
  ratedIn(raterUid: string, month: string): Promise<string[]>;
  /** Creates the rating (throws TrustError already-rated when it exists), updates the summary and the flag, in one transaction. */
  saveRating(r: RatingRecord, update: (s: TrustSummary | null) => TrustSummary, flag: RatingFlag | null): Promise<void>;
  summary(uid: string): Promise<TrustSummary | null>;
  /** Both are approved members of one active carpool. */
  shareCarpool(a: string, b: string): Promise<boolean>;
  /** Every child record whose parent is [ownerUid] (any status). */
  childrenOf(ownerUid: string): Promise<ChildLite[]>;
  linksOfChild(childId: string): Promise<GuardianLink[]>;
  linksAs(uid: string, side: "owner" | "guardian"): Promise<GuardianLink[]>;
  link(id: string): Promise<GuardianLink | null>;
  guardianRequest(id: string): Promise<GuardianRequest | null>;
  guardianRequestsAs(uid: string, side: "owner" | "guardian"): Promise<GuardianRequest[]>;
  /** Writes the request (and its notice); with [expect], only when the stored status still is [expect]. */
  putGuardianRequest(r: GuardianRequest, notice: OutboxEvent | null, expect?: GuardianRequest["status"] | null): Promise<void>;
  /** Accept or decline: the request, the new links and notices together; refused (invalid-state) when the request changed. */
  decideGuardianRequest(r: GuardianRequest, links: GuardianLink[], notices: OutboxEvent[]): Promise<void>;
  /** Writes a link change (refused with invalid-state when the stored status is not [expect]). */
  putLink(l: GuardianLink, expect: GuardianLink["status"], notice: OutboxEvent | null): Promise<void>;
  linksInReview(limit: number): Promise<GuardianLink[]>;
  /** Children's new grades or "left", the parent's confirmed year, overdue cleared, audit: one transaction. */
  saveYear(uid: string, year: number, changes: YearChange[], nowMs: number): Promise<void>;
  flags(status: "open" | "handled", limit: number): Promise<RatingFlag[]>;
  /** Refused (invalid-state) when already handled. */
  resolveFlag(id: string, outcome: FlagOutcome, adminUid: string, nowMs: number): Promise<RatingFlag>;
  takeLimit(uid: string, kind: TrustLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;
  audit(entry: { actorUid: string; action: string; target: string; details?: Record<string, unknown>; ip: string | null }): Promise<void>;
}

export interface TrustDeps {
  store: TrustStore;
  /** Prompt 6 and 7 carpool flows (a child leaving carpools, grade copies). */
  carpools: CarpoolDeps;
  now: () => number;
  rateWindowDays: number;
  year: YearSettings;
}

export interface Caller {
  uid: string;
  verifiedClaim: boolean;
}

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const LIMITS: Record<TrustLimitKind, { windowMs: number; max: number }> = {
  ratings: { windowMs: DAY, max: 30 },
  guardianRequests: { windowMs: DAY, max: 5 },
  summaries: { windowMs: HOUR, max: 60 },
};

async function take(deps: TrustDeps, uid: string, kind: TrustLimitKind): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), LIMITS[kind]);
  if (!r.allowed) throw new TrustError("rate-limited", r.retryAfterMs);
}

/** A verified, not suspended caller (claim and record both). */
export async function requireVerified(deps: TrustDeps, caller: Caller): Promise<TrustAccount> {
  const account = await deps.store.account(caller.uid);
  if (!account) throw new TrustError("no-account");
  if (account.status === "suspended") throw new TrustError("suspended");
  if (!caller.verifiedClaim || account.status !== "verified") throw new TrustError("not-verified");
  return account;
}

const today = (deps: TrustDeps) => cairoDate(deps.now());

/** Short fixed event IDs (outbox; no names in them). */
function eventId(prefix: string, ...parts: string[]): string {
  return `${prefix}_${createHash("sha256").update(parts.join("|")).digest("hex").slice(0, 32)}`;
}

// --------------------------------------------------------------------------
// Ratings and vouching
// --------------------------------------------------------------------------

export interface RateableParent {
  uid: string;
  firstName: string;
  /** The other parent drove (driver) or had a child on the caller's run (parent). */
  role: "driver" | "parent";
  date: string;
  carpoolId: string;
}

/** Parents the caller shared a finished trip with recently and has not rated this month. */
export async function listRateable(deps: TrustDeps, caller: Caller): Promise<{ parents: RateableParent[]; month: string }> {
  await requireVerified(deps, caller);
  const day = today(deps);
  const month = monthOf(day);
  const since = addDays(day, -deps.rateWindowDays);
  const shared = sharedTrips(await deps.store.finishedTrips(caller.uid, since), caller.uid, since);
  const rated = new Set(await deps.store.ratedIn(caller.uid, month));
  const out: RateableParent[] = [];
  const candidates = [...shared.values()].filter((s) => !rated.has(s.otherUid)).sort((a, b) => b.date.localeCompare(a.date));
  for (const s of candidates.slice(0, MAX_RATEABLE)) {
    const other = await deps.store.account(s.otherUid);
    if (!other || other.status !== "verified") continue;
    out.push({ uid: s.otherUid, firstName: other.firstName, role: s.otherRole, date: s.date, carpoolId: s.carpoolId });
  }
  return { parents: out, month };
}

/**
 * Rates a parent after a shared finished trip: 1 to 5 stars, fixed tags,
 * and an optional vouch. Once per pair per month (the record ID holds the
 * month). Low stars or "unsafe driving" go to the admins' queue.
 */
export async function rateParent(deps: TrustDeps, caller: Caller, data: unknown): Promise<{ rated: true; flagged: boolean }> {
  const input = parseRating(data);
  await requireVerified(deps, caller);
  if (input.rateeUid === caller.uid) throw new TrustError("self");
  const day = today(deps);
  const since = addDays(day, -deps.rateWindowDays);
  const shared = sharedTrips(await deps.store.finishedTrips(caller.uid, since), caller.uid, since).get(input.rateeUid);
  if (!shared) throw new TrustError("no-shared-trip");
  const other = await deps.store.account(input.rateeUid);
  if (!other) throw new TrustError("not-found");
  await take(deps, caller.uid, "ratings");
  const nowMs = deps.now();
  const month = monthOf(day);
  const id = ratingId(month, caller.uid, input.rateeUid);
  const flagged = needsReview(input);
  const rating: RatingRecord = {
    id,
    month,
    raterUid: caller.uid,
    rateeUid: input.rateeUid,
    stars: input.stars,
    tags: input.tags,
    vouch: input.vouch,
    tripId: shared.tripId,
    carpoolId: shared.carpoolId,
    createdAtMs: nowMs,
  };
  const flag: RatingFlag | null = flagged
    ? { id, ratingId: id, raterUid: caller.uid, rateeUid: input.rateeUid, stars: input.stars, tags: input.tags, carpoolId: shared.carpoolId, status: "open", outcome: null, createdAtMs: nowMs }
    : null;
  await deps.store.saveRating(rating, (s) => addRating(s, input.stars, input.vouch, caller.uid), flag);
  return { rated: true, flagged };
}

/**
 * A parent's ratings and vouches: their own, or another parent's when both
 * are approved members of one carpool. The average shows from 3 ratings.
 */
export async function getTrustSummary(deps: TrustDeps, caller: Caller, data: unknown): Promise<SummaryView> {
  const raw = data === undefined || data === null ? {} : record(data);
  const uid = raw.uid === undefined ? caller.uid : docId(raw.uid);
  await requireVerified(deps, caller);
  if (uid !== caller.uid) {
    await take(deps, caller.uid, "summaries");
    if (!(await deps.store.shareCarpool(caller.uid, uid))) throw new TrustError("not-allowed");
  }
  return summaryView(await deps.store.summary(uid));
}

// --------------------------------------------------------------------------
// Yearly check
// --------------------------------------------------------------------------

export interface YearCheckView {
  state: YearState;
  year: number | null;
  opensOn: string | null;
  startsOn: string | null;
  deadline: string | null;
  children: Array<{ id: string; firstName: string; grade: string; schoolId: string; schoolName: string }>;
}

export async function yearCheckOf(deps: TrustDeps, account: TrustAccount): Promise<YearCheckView> {
  const day = today(deps);
  const w = yearWindow(day, deps.year);
  const children = (await deps.store.childrenOf(account.uid)).filter((c) => c.status === "approved");
  const state = yearState(w, day, { confirmedYear: account.yearConfirmed, verifiedOn: account.verifiedOn, hasChildren: children.length > 0 });
  return {
    state,
    year: w?.year ?? null,
    opensOn: w?.opensOn ?? null,
    startsOn: w?.startsOn ?? null,
    deadline: w?.deadline ?? null,
    children:
      state === "due" || state === "overdue"
        ? children.map((c) => ({ id: c.id, firstName: c.firstName, grade: c.grade, schoolId: c.schoolId, schoolName: c.schoolName }))
        : [],
  };
}

/**
 * The parent confirms each child for the new school year: stays (with the
 * new grade) or left the school. A child who left leaves the parent's and
 * every linked parent's carpools (and so the carpool chats); the map and
 * chat sync take the school and area groups away once the child is no
 * longer approved (Prompt 5 and 9 triggers). Their guardian links end.
 */
export async function confirmSchoolYear(deps: TrustDeps, caller: Caller, data: unknown): Promise<{ state: YearState; left: number }> {
  const account = await requireVerified(deps, caller);
  const view = await yearCheckOf(deps, account);
  if (view.state !== "due" && view.state !== "overdue") throw new TrustError("year-not-open");
  const { year, answers } = parseYearAnswers(data, view.children.map((c) => c.id));
  if (year !== view.year) throw new TrustError("year-not-open");
  const nowMs = deps.now();
  const changes: YearChange[] = answers.map((a) => ({ childId: a.childId, grade: a.stays ? a.grade : null }));
  await deps.store.saveYear(caller.uid, year, changes, nowMs);
  let left = 0;
  for (const a of answers) {
    const before = view.children.find((c) => c.id === a.childId);
    if (a.stays) {
      if (a.grade && before && before.grade !== a.grade) await updateChildGrade(deps.carpools, caller.uid, a.childId, a.grade);
      continue;
    }
    left += 1;
    await removeChildFromCarpools(deps.carpools, caller.uid, a.childId);
    for (const l of (await deps.store.linksOfChild(a.childId)).filter(linkLive)) {
      await deps.store.putLink({ ...l, status: "removed", decidedAtMs: nowMs, decidedBy: caller.uid, updatedAtMs: nowMs }, l.status, null);
      await removeChildFromCarpools(deps.carpools, l.guardianUid, a.childId);
      await leaveEmptyCarpools(deps.carpools, l.guardianUid);
    }
  }
  // A parent with no child left in a carpool leaves it (and its chat).
  if (left > 0) await leaveEmptyCarpools(deps.carpools, caller.uid);
  return { state: "done", left };
}

// --------------------------------------------------------------------------
// Overview (Profile)
// --------------------------------------------------------------------------

export async function getTrustOverview(
  deps: TrustDeps,
  caller: Caller,
): Promise<{ summary: SummaryView; toRate: number; yearCheck: YearCheckView; requests: number }> {
  const account = await requireVerified(deps, caller);
  const [rateable, yearCheck, requests, summary] = await Promise.all([
    listRateable(deps, caller),
    yearCheckOf(deps, account),
    deps.store.guardianRequestsAs(caller.uid, "owner"),
    deps.store.summary(caller.uid),
  ]);
  return { summary: summaryView(summary), toRate: rateable.parents.length, yearCheck, requests: requests.filter((r) => r.status === "requested").length };
}

// --------------------------------------------------------------------------
// Guardian links
// --------------------------------------------------------------------------

/**
 * A verified parent (often the other parent) asks to be linked to the
 * children of the parent with [parentId]. That parent chooses the children
 * and accepts; an admin reviews when needed (linkNeedsReview).
 */
export async function requestGuardianLink(deps: TrustDeps, caller: Caller, data: unknown): Promise<{ requestId: string; firstName: string }> {
  const input = parseGuardianRequest(data);
  const me = await requireVerified(deps, caller);
  const owner = await deps.store.accountByParentId(input.parentId);
  if (!owner) throw new TrustError("not-found");
  if (owner.uid === caller.uid) throw new TrustError("self");
  if (owner.status !== "verified") throw new TrustError("not-allowed");
  await take(deps, caller.uid, "guardianRequests");
  const id = guardianRequestId(owner.uid, caller.uid);
  const existing = await deps.store.guardianRequest(id);
  if (existing?.status === "requested") throw new TrustError("already-requested");
  const nowMs = deps.now();
  const r: GuardianRequest = {
    id,
    ownerUid: owner.uid,
    guardianUid: caller.uid,
    guardianFirstName: me.firstName,
    relation: input.relation,
    status: "requested",
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  };
  await deps.store.putGuardianRequest(r, newEvent(eventId("guardian-req", id, String(nowMs)), "guardian-requested", [owner.uid], nowMs), existing?.status ?? null);
  return { requestId: id, firstName: owner.firstName };
}

/** The asking parent takes the request back. */
export async function cancelGuardianRequest(deps: TrustDeps, caller: Caller, data: unknown): Promise<{ status: string }> {
  const id = docId(record(data).requestId);
  await requireVerified(deps, caller);
  const r = await deps.store.guardianRequest(id);
  if (!r || r.guardianUid !== caller.uid) throw new TrustError("not-found");
  if (r.status !== "requested") throw new TrustError("invalid-state");
  await deps.store.putGuardianRequest({ ...r, status: "cancelled", updatedAtMs: deps.now() }, null, "requested");
  return { status: "cancelled" };
}

/**
 * The children's parent answers: accept with the children to share (their
 * own approved children), or decline. Each child gets a link that is
 * active at once, or waits for an admin (review).
 */
export async function answerGuardianRequest(deps: TrustDeps, caller: Caller, data: unknown): Promise<{ status: string; links: Array<{ childId: string; status: string }> }> {
  const raw = record(data);
  const id = docId(raw.requestId);
  if (typeof raw.accept !== "boolean") throw new TrustError("invalid-request");
  const me = await requireVerified(deps, caller);
  const r = await deps.store.guardianRequest(id);
  if (!r || r.ownerUid !== caller.uid) throw new TrustError("not-found");
  if (r.status !== "requested") throw new TrustError("invalid-state");
  const nowMs = deps.now();
  if (!raw.accept) {
    await deps.store.decideGuardianRequest({ ...r, status: "declined", updatedAtMs: nowMs }, [], [
      newEvent(eventId("guardian-no", id, String(nowMs)), "guardian-declined", [r.guardianUid], nowMs),
    ]);
    return { status: "declined", links: [] };
  }
  const guardian = await deps.store.account(r.guardianUid);
  if (!guardian || guardian.status !== "verified") throw new TrustError("not-allowed");
  if (!Array.isArray(raw.childIds) || raw.childIds.length === 0 || raw.childIds.length > 10) throw new TrustError("invalid-request");
  const ids = [...new Set(raw.childIds.map((x) => docId(x)))];
  const mine = new Map((await deps.store.childrenOf(caller.uid)).filter((c) => c.status === "approved").map((c) => [c.id, c]));
  const links: GuardianLink[] = [];
  for (const childId of ids) {
    const child = mine.get(childId);
    if (!child) throw new TrustError("not-your-child");
    const others = (await deps.store.linksOfChild(childId)).filter((l) => linkLive(l) && l.guardianUid !== r.guardianUid);
    if (others.length >= MAX_ACTIVE_LINKS_PER_CHILD) throw new TrustError("too-many-guardians");
    const current = await deps.store.link(linkId(childId, r.guardianUid));
    if (current && linkLive(current)) throw new TrustError("already-linked");
    links.push({
      id: linkId(childId, r.guardianUid),
      childId,
      childFirstName: child.firstName,
      ownerUid: caller.uid,
      ownerFirstName: me.firstName,
      guardianUid: r.guardianUid,
      guardianFirstName: guardian.firstName,
      relation: r.relation as Relation,
      status: linkNeedsReview(r.relation, others.filter((l) => l.status === "active").length) ? "review" : "active",
      createdAtMs: nowMs,
      decidedAtMs: null,
      decidedBy: null,
      updatedAtMs: nowMs,
    });
  }
  const notices = links.some((l) => l.status === "active") ? [newEvent(eventId("guardian-yes", id, String(nowMs)), "guardian-linked", [r.guardianUid], nowMs)] : [];
  await deps.store.decideGuardianRequest({ ...r, status: "accepted", updatedAtMs: nowMs }, links, notices);
  return { status: "accepted", links: links.map((l) => ({ childId: l.childId, status: l.status })) };
}

/**
 * Either parent ends a link (or takes back one waiting for review). The
 * child leaves the linked parent's carpools.
 */
export async function removeGuardianLink(deps: TrustDeps, caller: Caller, data: unknown): Promise<{ status: string }> {
  const id = docId(record(data).linkId);
  await requireVerified(deps, caller);
  const l = await deps.store.link(id);
  if (!l || (l.ownerUid !== caller.uid && l.guardianUid !== caller.uid)) throw new TrustError("not-found");
  if (!linkLive(l)) throw new TrustError("invalid-state");
  const nowMs = deps.now();
  await deps.store.putLink({ ...l, status: "removed", decidedAtMs: nowMs, decidedBy: caller.uid, updatedAtMs: nowMs }, l.status, null);
  await removeChildFromCarpools(deps.carpools, l.guardianUid, l.childId);
  await leaveEmptyCarpools(deps.carpools, l.guardianUid);
  return { status: "removed" };
}

/** A link to another parent's child, with what the linked parent needs to bring the child to a carpool. */
export interface LinkedChildView extends GuardianLink {
  childGrade: string;
  childSchoolId: string;
  childSchoolName: string;
}

export interface FamilyView {
  incoming: GuardianRequest[];
  outgoing: GuardianRequest[];
  /** Links of my children to other parents. */
  shared: GuardianLink[];
  /** Links that give me another parent's children (approved children only carry details). */
  linked: LinkedChildView[];
}

export async function getFamily(deps: TrustDeps, caller: Caller): Promise<FamilyView> {
  await requireVerified(deps, caller);
  const [incoming, outgoing, shared, linked] = await Promise.all([
    deps.store.guardianRequestsAs(caller.uid, "owner"),
    deps.store.guardianRequestsAs(caller.uid, "guardian"),
    deps.store.linksAs(caller.uid, "owner"),
    deps.store.linksAs(caller.uid, "guardian"),
  ]);
  const live = linked.filter(linkLive);
  const owners = new Map<string, ChildLite[]>();
  for (const owner of new Set(live.filter((l) => l.status === "active").map((l) => l.ownerUid))) owners.set(owner, await deps.store.childrenOf(owner));
  return {
    incoming: incoming.filter((r) => r.status === "requested"),
    outgoing: outgoing.filter((r) => r.status === "requested"),
    shared: shared.filter(linkLive),
    linked: live.map((l) => {
      const c = l.status === "active" ? owners.get(l.ownerUid)?.find((x) => x.id === l.childId && x.status === "approved") : undefined;
      return { ...l, childGrade: c?.grade ?? "", childSchoolId: c?.schoolId ?? "", childSchoolName: c?.schoolName ?? "" };
    }),
  };
}

// --------------------------------------------------------------------------
// Admin (F14): guardian links in review and rating flags
// --------------------------------------------------------------------------

export interface FlagView extends RatingFlag {
  raterFirstName: string;
  rateeFirstName: string;
  rateeParentId: string;
}

/** Links waiting for review and open rating flags, with first names and the rated parent's ID. */
export async function adminTrustQueue(deps: TrustDeps): Promise<{ links: GuardianLink[]; flags: FlagView[] }> {
  const [links, flags] = await Promise.all([deps.store.linksInReview(100), deps.store.flags("open", 100)]);
  const accounts = new Map<string, TrustAccount | null>();
  for (const uid of new Set(flags.flatMap((f) => [f.raterUid, f.rateeUid]))) accounts.set(uid, await deps.store.account(uid));
  return {
    links,
    flags: flags.map((f) => ({
      ...f,
      raterFirstName: accounts.get(f.raterUid)?.firstName ?? "",
      rateeFirstName: accounts.get(f.rateeUid)?.firstName ?? "",
      rateeParentId: accounts.get(f.rateeUid)?.parentId ?? "",
    })),
  };
}

export async function adminDecideGuardianLink(deps: TrustDeps, adminUid: string, data: unknown, ip: string | null): Promise<{ status: string }> {
  const raw = record(data);
  const id = docId(raw.linkId);
  if (typeof raw.approve !== "boolean") throw new TrustError("invalid-request");
  const l = await deps.store.link(id);
  if (!l) throw new TrustError("not-found");
  if (l.status !== "review") throw new TrustError("invalid-state");
  const nowMs = deps.now();
  const status = raw.approve ? "active" : "rejected";
  await deps.store.putLink(
    { ...l, status, decidedAtMs: nowMs, decidedBy: adminUid, updatedAtMs: nowMs },
    "review",
    newEvent(eventId("guardian-admin", id, String(nowMs)), raw.approve ? "guardian-linked" : "guardian-declined", [l.guardianUid], nowMs),
  );
  await deps.store.audit({ actorUid: adminUid, action: raw.approve ? "guardian.approve" : "guardian.reject", target: `guardianLinks/${id}`, ip });
  return { status };
}

export async function adminResolveRatingFlag(deps: TrustDeps, adminUid: string, data: unknown, ip: string | null): Promise<RatingFlag> {
  const raw = record(data);
  const id = docId(raw.flagId);
  if (typeof raw.outcome !== "string" || !(FLAG_OUTCOMES as readonly string[]).includes(raw.outcome)) throw new TrustError("invalid-request");
  const flag = await deps.store.resolveFlag(id, raw.outcome as FlagOutcome, adminUid, deps.now());
  await deps.store.audit({ actorUid: adminUid, action: "rating-flag.resolve", target: `ratingFlags/${id}`, details: { outcome: raw.outcome }, ip });
  return flag;
}
