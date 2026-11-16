import { evidencePurgeAt, purgeAfterClosure } from "./retention";

/**
 * Account deletion (spec section 7, Prompt 12; owner decision 16 Nov 2026,
 * which replaces "photos kept 1 year after close": App Review guideline
 * 5.1.1(v) and Apple's "Offering account deletion in your app": delete
 * the account and the data with it, keep only what the law requires, and
 * tell the parent what is kept).
 *
 * AT ONCE (deleteMyAccount): the parent leaves every carpool, live runs
 * stop, the chat user and every message the parent wrote are deleted
 * (private chats and group chats), and every record about the parent goes
 * (IMMEDIATE_TARGETS: home address and pin, children, car, devices, push
 * tokens, ...), then the user record and the Firebase Auth user. In the
 * same call, unless a safety hold applies, the EVIDENCE goes too: ID
 * photos, selfies, school IDs, licences, the driver photo, the face
 * reference, their thumbnails, the verification case records and the
 * archived routes of the runs the parent drove.
 *
 * SAFETY HOLD (only when an open report or rating flag about the parent
 * exists at deletion): the evidence above waits SAFETY_HOLD_DAYS (30), so
 * the admins can finish that case, then retentionDaily deletes it whatever
 * the case's state. Everything else still goes at once.
 *
 * KEPT, minimised and detached from the profile (no name, phone, address,
 * photo or ID number): run summaries shared with other families (the
 * parent as an initial; their part anonymised 1 year after closure), the
 * consent records (proof of consent, 1 year), Settle up records for the
 * other parent (an initial; 1 year), transfer records
 * (TRANSFER_RECORD_YEARS), reports about the parent, the admin audit log,
 * the keyed national-ID hash on the ban list (banned parents only) and the
 * reserved parent ID.
 *
 * The wallet must be empty and settled first. Every step runs on its own;
 * a failed step is recorded in closedAccounts/{uid} and retried by
 * retentionDaily, which reports what still fails (Sentry and the admins'
 * security alerts). Pure planning here; firestore_store.ts runs it.
 */

/** A Firestore delete of the parent's records. "{uid}" in a path is the parent. */
export type Target =
  | { kind: "doc"; path: string }
  | { kind: "where"; collection: string; field: string; op?: "==" | "array-contains" }
  | { kind: "subcollection"; path: string }
  | { kind: "storage"; prefix: string };

/**
 * Deleted AT ONCE, in this order, after the carpool, trip, chat and trust
 * steps (which go through the flows that keep groups consistent). Each
 * entry names the collection in firestore.rules it covers (the cascade
 * test checks that every collection is classified).
 */
export const IMMEDIATE_TARGETS: ReadonlyArray<{ collection: string; target: Target }> = [
  // Maps (Prompt 5)
  { collection: "homes", target: { kind: "doc", path: "homes/{uid}" } },
  { collection: "parentLocations", target: { kind: "doc", path: "parentLocations/{uid}" } },
  { collection: "mapLimits", target: { kind: "doc", path: "mapLimits/{uid}" } },
  { collection: "newParentEvents", target: { kind: "where", collection: "newParentEvents", field: "uid" } },
  { collection: "searchKeyLimits", target: { kind: "doc", path: "searchKeyLimits/{uid}" } },
  // Places (F46): "my district isn't listed" requests carry the parent's uid.
  { collection: "placeRequests", target: { kind: "where", collection: "placeRequests", field: "uid" } },
  // Carpools (Prompt 6): memberships and members go through removeFromCarpool first.
  { collection: "memberships", target: { kind: "where", collection: "memberships", field: "uid" } },
  { collection: "carpoolWanted", target: { kind: "doc", path: "carpoolWanted/{uid}" } },
  { collection: "carpoolLimits", target: { kind: "doc", path: "carpoolLimits/{uid}" } },
  // Notifications (Prompt 8)
  { collection: "notificationSettings", target: { kind: "doc", path: "notificationSettings/{uid}" } },
  { collection: "pushTokens", target: { kind: "where", collection: "pushTokens", field: "uid" } },
  { collection: "notificationLimits", target: { kind: "doc", path: "notificationLimits/{uid}" } },
  { collection: "users/notifications", target: { kind: "subcollection", path: "users/{uid}/notifications" } },
  { collection: "users/chatPushes", target: { kind: "subcollection", path: "users/{uid}/chatPushes" } },
  // Chat (Prompt 9): the Stream user is cut off by the chat step.
  { collection: "chatRequests", target: { kind: "where", collection: "chatRequests", field: "fromUid" } },
  { collection: "chatRequests", target: { kind: "where", collection: "chatRequests", field: "toUid" } },
  { collection: "chatBlocks", target: { kind: "where", collection: "chatBlocks", field: "blockerUid" } },
  { collection: "chatBlocks", target: { kind: "where", collection: "chatBlocks", field: "blockedUid" } },
  { collection: "chatMutes", target: { kind: "where", collection: "chatMutes", field: "uid" } },
  { collection: "chatSettings", target: { kind: "doc", path: "chatSettings/{uid}" } },
  { collection: "chatMemberships", target: { kind: "doc", path: "chatMemberships/{uid}" } },
  { collection: "chatLimits", target: { kind: "doc", path: "chatLimits/{uid}" } },
  // Trips (Prompt 10): handover lists of the parent's children go with the children step.
  { collection: "emergencyContacts", target: { kind: "doc", path: "emergencyContacts/{uid}" } },
  { collection: "tripLimits", target: { kind: "doc", path: "tripLimits/{uid}" } },
  { collection: "handoverAdults", target: { kind: "where", collection: "handoverAdults", field: "ownerUid" } },
  // Trust (Prompt 11): ratings by and about the parent, summaries, links, requests.
  { collection: "ratings", target: { kind: "where", collection: "ratings", field: "raterUid" } },
  { collection: "ratings", target: { kind: "where", collection: "ratings", field: "rateeUid" } },
  { collection: "trustSummaries", target: { kind: "doc", path: "trustSummaries/{uid}" } },
  { collection: "trustLimits", target: { kind: "doc", path: "trustLimits/{uid}" } },
  { collection: "guardianRequests", target: { kind: "where", collection: "guardianRequests", field: "ownerUid" } },
  { collection: "guardianRequests", target: { kind: "where", collection: "guardianRequests", field: "guardianUid" } },
  { collection: "guardianLinks", target: { kind: "where", collection: "guardianLinks", field: "ownerUid" } },
  { collection: "guardianLinks", target: { kind: "where", collection: "guardianLinks", field: "guardianUid" } },
  // Children and car (Prompt 3)
  { collection: "children", target: { kind: "where", collection: "children", field: "ownerUid" } },
  { collection: "vehicles", target: { kind: "doc", path: "vehicles/{uid}" } },
  // Wallet (Prompt 11B): counters only; transfers stay (TRANSFER_RECORD_YEARS), wallets/{uid} is closed, not deleted.
  { collection: "walletLimits", target: { kind: "doc", path: "walletLimits/{uid}" } },
  // Settle up (F45): the InstaPay address and the counters go at once; the
  // records stay for the other parent with an initial only (anonymise step).
  { collection: "settleUpAddresses", target: { kind: "doc", path: "settleUpAddresses/{uid}" } },
  { collection: "settleUpLimits", target: { kind: "doc", path: "settleUpLimits/{uid}" } },
  // Devices and privacy (Prompt 12)
  { collection: "users/devices", target: { kind: "subcollection", path: "users/{uid}/devices" } },
  { collection: "users/logins", target: { kind: "subcollection", path: "users/{uid}/logins" } },
  { collection: "abuseCounters", target: { kind: "where", collection: "abuseCounters", field: "uid" } },
  // Security emails to the parent's address (sent or waiting).
  { collection: "mail", target: { kind: "where", collection: "mail", field: "uid" } },
  // Live uploads that may still be there.
  { collection: "storage:pending", target: { kind: "storage", prefix: "verification/{uid}/pending/" } },
  { collection: "storage:phoneChecks", target: { kind: "storage", prefix: "phoneChecks/{uid}/" } },
  { collection: "storage:deviceChecks", target: { kind: "storage", prefix: "deviceChecks/{uid}/" } },
  { collection: "storage:selfieChecks", target: { kind: "storage", prefix: "selfieChecks/{uid}/" } },
  { collection: "storage:exports", target: { kind: "storage", prefix: "exports/{uid}/" } },
  // Last: the user record (its consents subcollection, the proof of consent, stays 1 year).
  { collection: "users", target: { kind: "doc", path: "users/{uid}" } },
];

/**
 * EVIDENCE: deleted with the account, in the same call (owner decision 16
 * Nov 2026), or SAFETY_HOLD_DAYS later when an open report about the
 * parent exists. Never later than that.
 */
export const EVIDENCE_TARGETS: ReadonlyArray<{ collection: string; target: Target }> = [
  { collection: "storage:verification", target: { kind: "storage", prefix: "verification/{uid}/" } },
  { collection: "storage:faceRefs", target: { kind: "storage", prefix: "faceRefs/{uid}/" } },
  { collection: "storage:driverPhotos", target: { kind: "storage", prefix: "driverPhotos/{uid}/" } },
  { collection: "storage:selfieArchive", target: { kind: "storage", prefix: "selfieArchive/{uid}/" } },
  { collection: "storage:thumbs", target: { kind: "storage", prefix: "thumbs/{uid}/" } },
  { collection: "verifications", target: { kind: "where", collection: "verifications", field: "uid" } },
];

/** Deleted 1 YEAR after closure by retentionDaily: the proof of consent. */
export const PURGE_TARGETS: ReadonlyArray<{ collection: string; target: Target }> = [
  { collection: "users/consents", target: { kind: "subcollection", path: "users/{uid}/consents" } },
];

/**
 * Collections in firestore.rules that are NOT deleted with an account,
 * and why. With the two lists above this covers every collection (test).
 */
export const NOT_DELETED: Readonly<Record<string, string>> = {
  bannedIds: "ban list: keyed national-ID hash (kept, spec section 7)",
  nationalIds: "released by the identity step (the claim on the ID number is deleted)",
  reports: "reports about or by the parent are kept (safety); handled ones lose their message copy after 1 year",
  moderations: "admin decisions (part of the audit trail)",
  auditLog: "admin actions, 2 years",
  transfers: "transfer records, as long as the law requires (TRANSFER_RECORD_YEARS: 5, confirmed by the lawyer and the owner)",
  transferResults: "transfer outcomes, with the transfers",
  walletPending: "empty: the wallet must be settled before deletion",
  walletDaily: "per-day amounts for the limits (no names); TTL expiresAt, 35 days",
  walletAlerts: "admin alerts about transfers (with the transfer records)",
  wallets: "closed, not deleted: the partner reference the transfer records need",
  fakeWalletAccounts: "fake partner (dev/staging test money)",
  fakeWalletOps: "fake partner (dev/staging test money)",
  settleUps: "payment records between two parents (F45): the deleted parent becomes an initial and leaves `parties` at once (anonymise step); the record goes when neither account is active and the last closure is 1 year old (retentionDaily)",
  parentIds: "the parent ID is reserved forever so it is never reused (holds only the uid)",
  admins: "not a parent record",
  adminLimits: "not a parent record",
  config: "settings",
  schools: "not personal",
  areas: "not personal",
  placeAreas: "not personal (public place names and outlines)",
  placeDistricts: "not personal (public place names; a district an admin added from a request carries no uid)",
  placeIndex: "not personal (the areas' boxes)",
  placeInternal: "not personal (outlines and address counts; the places step takes the parent's address out of the counts)",
  schoolReview: "not personal (the AI name review's cache: school names and verdicts)",
  placeCache: "not personal (place details)",
  carpools: "the group stays for the other members (the parent's names become initials); a closed carpool is deleted 1 year after it closed",
  carpoolInvites: "carpool links (no personal data)",
  schedule: "runs stay for the group with initials only; future runs are released; deleted with the closed carpool",
  scheduleEvents: "events, 30-day TTL",
  notificationEvents: "outbox, 30-day TTL",
  chatChannels: "the chat's record; the parent's own messages are deleted at once (chat step); a private chat ends and what the other parent wrote is deleted 1 year later",
  verifications: "deleted with the account (evidence step; at most 30 days later under a safety hold)",
  trips: "kept while any participant's account is active + 1 year (owner, 14 Nov 2026 13:29): the parent's children become initials at once; 1 year after closure the parent's part is anonymised (purge step trips), and a trip goes when every participant's year is over",
  tripStops: "exact stops of one run, deleted 1 day after the run",
  tripChecks: "selfie-check state of one run (no image)",
  ratingFlags: "open flags are like reports (kept until handled)",
  otpCodes: "keyed hashes only, TTL",
  otpLimits: "keyed hashes only, TTL",
  closedAccounts: "the deletion report and purge date (no name, phone or ID)",
  privacyRequests: "proof that each request was answered, 3 years",
  breachRegister: "personal data breach register (Law 151 Art. 7, Decree 816/2025 Art. 5); incidents, counts and admin notes, never a parent's data; kept as the law requires (docs/legal/breach-runbook.md)",
  securityAlerts: "admin alerts, 1 year after handled",
  routeArchives: "purged 1 year after the run; the routes of a deleted driver go with the account (evidence step)",
  retentionRuns: "job reports (counts only)",
};

/**
 * Subcollections of shared records (carpools, trips) in firestore.rules
 * and how a deleted parent's data in them ends (test: every one listed).
 */
export const SUBCOLLECTIONS: Readonly<Record<string, string>> = {
  "carpools/members": "deleted by removeFromCarpool (carpools step)",
  "carpools/requests": "deleted by removeFromCarpool (carpools step)",
  "carpools/driverConsents": "deleted by removeFromCarpool (carpools step)",
  "carpools/pickupPoints": "deleted by removeFromCarpool (carpools step)",
  "carpools/schedule": "future runs released (carpools step); past runs keep initials only (anonymise step); deleted with the closed carpool",
  "carpools/swaps": "initials only (anonymise step); deleted with the closed carpool",
  "carpools/exceptions": "no-school days (creator uid, no names); deleted with the closed carpool",
  "carpools/balances": "counts with an initial (anonymise step); deleted with the closed carpool",
  "carpools/emergencies": "24-hour TTL",
  "trips/points": "1-day TTL (live location)",
  "trips/eta": "1-day TTL",
};

/** Steps that run through the app's flows (not plain deletes), in order. */
/**
 * anonymise: the parent's and children's names in records that stay with
 * other parents (other drivers' trips, the carpools' past runs, swaps,
 * balances, carpool cards, settle-up records) become initials
 * (anonymise.ts, settle_up/model.ts). After
 * "carpools" (future runs released) and before "records" (memberships,
 * used to find the carpools, are deleted there).
 */
/**
 * places (F46): the parent's address leaves its area's and district's
 * address counts (placeInternal), before "records" deletes homes/{uid}.
 */
export const FLOW_STEPS = ["trips", "carpools", "anonymise", "chat", "trust", "identity", "wallet", "places", "records", "auth"] as const;
export type FlowStep = (typeof FLOW_STEPS)[number];
/** routes: the archived routes (files and records) of the runs the parent drove. */
export const EVIDENCE_STEPS = ["routes"] as const;
export type EvidenceStep = (typeof EVIDENCE_STEPS)[number];
/**
 * trips (owner answer 14 Nov 2026 13:29): the trips the parent drove are
 * deleted only when no other participant's data is still kept; otherwise
 * the parent's part is anonymised (trip_retention.ts).
 */
export const PURGE_STEPS = ["trips"] as const;
export type PurgeStep = (typeof PURGE_STEPS)[number];

export interface DeletionFacts {
  exists: boolean;
  /** Wallet: none, or its balance at the partner (piastres) and pending transfers. */
  wallet: { balance: number; pending: number } | null;
  /** The parent is driving a run right now. */
  drivingNow: boolean;
}

/** What the runner reads about the account before deleting it. */
export interface AccountFacts extends Omit<DeletionFacts, "wallet"> {
  parentId: string;
  banned: boolean;
  /** An open report or rating flag about this parent exists: the evidence waits (safety hold). */
  openCase: boolean;
}

export type DeletionRefusal = "wallet-not-empty" | "wallet-pending" | "wallet-unavailable" | "driving-now" | "no-account";

/** Why the account cannot be deleted yet, or null. */
export function deletionRefusal(f: DeletionFacts): DeletionRefusal | null {
  if (!f.exists) return "no-account";
  if (f.wallet && f.wallet.pending > 0) return "wallet-pending";
  if (f.wallet && f.wallet.balance !== 0) return "wallet-not-empty";
  if (f.drivingNow) return "driving-now";
  return null;
}

export function pathFor(template: string, uid: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(uid)) throw new Error("bad uid");
  return template.split("{uid}").join(uid);
}

export interface ClosedAccount {
  uid: string;
  parentId: string;
  closedAtMs: number;
  /** A safety hold applied at deletion (an open report about the parent). */
  hold: boolean;
  /** When the evidence (photos, case records, routes) goes: at closure, or 30 days later under a hold. */
  evidenceAtMs: number;
  evidenceDoneAtMs: number | null;
  /** When the kept records end (consents; the parent's part of trips): closure + 1 year. */
  purgeAtMs: number;
  banned: boolean;
  /** Steps still to do (retried by retentionDaily). */
  failed: string[];
  purgedAtMs: number | null;
}

export function newClosedAccount(uid: string, parentId: string, banned: boolean, nowMs: number, hold = false): ClosedAccount {
  return {
    uid,
    parentId,
    closedAtMs: nowMs,
    hold,
    evidenceAtMs: evidencePurgeAt(nowMs, hold),
    evidenceDoneAtMs: null,
    purgeAtMs: purgeAfterClosure(nowMs),
    banned,
    failed: [],
    purgedAtMs: null,
  };
}

/** The next time retentionDaily has work on this account (null: all done). */
export function nextWorkAt(c: ClosedAccount): number | null {
  if (c.evidenceDoneAtMs === null) return c.evidenceAtMs;
  return c.purgedAtMs === null ? c.purgeAtMs : null;
}

/**
 * What the wallet was before deletion locked it (so a refused deletion
 * puts it back exactly). null: the parent has no open wallet.
 */
export interface WalletLock {
  status: string;
  frozenReason: string | null;
  frozenAtMs: number | null;
  frozenBy: string | null;
}

/** Wallet status reason written while the account is being closed. */
export const CLOSING_REASON = "accountClosing";

export interface DeletionRunner {
  /** The account facts without the wallet (read after the lock). */
  facts(uid: string): Promise<AccountFacts>;
  /**
   * Closes the wallet to money FIRST: frozen with reason accountClosing in
   * our copy (startTransfer reads it in its transaction, so no transfer to
   * or from the parent starts after this) and frozen at the partner.
   * Throws when the partner cannot be told (our copy is put back).
   */
  lockWallet(uid: string, nowMs: number): Promise<WalletLock | null>;
  /** Balance at the partner and transfers not settled, in BOTH directions. Throws when unknown. */
  walletFacts(uid: string, nowMs: number): Promise<{ balance: number; pending: number }>;
  /** A refused deletion: the wallet is as it was. */
  unlockWallet(uid: string, lock: WalletLock, nowMs: number): Promise<void>;
  saveClosed(c: ClosedAccount): Promise<void>;
  closed(uid: string): Promise<ClosedAccount | null>;
  /** One flow step (carpools, chat ...). Throws on failure. */
  runFlowStep(uid: string, step: FlowStep, nowMs: number): Promise<void>;
  runTarget(uid: string, target: Target): Promise<number>;
  runPurgeStep(uid: string, step: PurgeStep | EvidenceStep): Promise<void>;
}

/** Every step of the immediate deletion, as names (stored when one fails). */
export function immediateSteps(): string[] {
  const out: string[] = [];
  for (const s of FLOW_STEPS) {
    if (s === "records") IMMEDIATE_TARGETS.forEach((_, i) => out.push(`target:${i}`));
    else out.push(`flow:${s}`);
  }
  return out;
}

async function runStep(runner: DeletionRunner, uid: string, name: string, nowMs: number): Promise<void> {
  const [kind, id] = name.split(":");
  if (kind === "flow") await runner.runFlowStep(uid, id as FlowStep, nowMs);
  else if (kind === "target") await runner.runTarget(uid, IMMEDIATE_TARGETS[Number(id)].target);
  else if (kind === "purge" && (PURGE_STEPS as readonly string[]).includes(id)) await runner.runPurgeStep(uid, id as PurgeStep);
  else if (kind === "ptarget" && PURGE_TARGETS[Number(id)]) await runner.runTarget(uid, PURGE_TARGETS[Number(id)].target);
  else if (kind === "evidence" && (EVIDENCE_STEPS as readonly string[]).includes(id)) await runner.runPurgeStep(uid, id as EvidenceStep);
  else if (kind === "etarget" && EVIDENCE_TARGETS[Number(id)]) await runner.runTarget(uid, EVIDENCE_TARGETS[Number(id)].target);
  // An unknown name (written by an older version) is done: the phases below run every current step again.
}

/**
 * Runs [steps] one by one; every failure is caught and returned (the
 * account is never left half-deleted silently).
 */
export async function runSteps(runner: DeletionRunner, uid: string, steps: string[], nowMs: number, onError: (step: string, error: unknown) => void): Promise<string[]> {
  const failed: string[] = [];
  for (const step of steps) {
    try {
      await runStep(runner, uid, step, nowMs);
    } catch (error) {
      failed.push(step);
      onError(step, error);
    }
  }
  return failed;
}

/** The parent deletes the account (the app asked for confirmation and a fresh Face ID check). */
export async function deleteAccount(
  runner: DeletionRunner,
  uid: string,
  nowMs: number,
  onError: (step: string, error: unknown) => void,
): Promise<{ closed: true; failed: number; held: boolean; evidenceAtMs: number; purgeAtMs: number }> {
  const facts = await runner.facts(uid);
  const early = deletionRefusal({ ...facts, wallet: null });
  if (early) throw new DeletionError(early);
  // The wallet is locked FIRST, then checked: a transfer cannot start (or
  // arrive) between the check and the deletion.
  let lock: WalletLock | null;
  try {
    lock = await runner.lockWallet(uid, nowMs);
  } catch (error) {
    onError("wallet:lock", error);
    throw new DeletionError("wallet-unavailable");
  }
  if (lock) {
    let wallet: { balance: number; pending: number } | null = null;
    try {
      wallet = await runner.walletFacts(uid, nowMs);
    } catch (error) {
      onError("wallet:facts", error);
    }
    const refusal = wallet ? deletionRefusal({ ...facts, wallet }) : "wallet-unavailable";
    if (refusal) {
      try {
        await runner.unlockWallet(uid, lock, nowMs);
      } catch (error) {
        // Stays frozen (safe side); an admin can unfreeze from the panel.
        onError("wallet:unlock", error);
      }
      throw new DeletionError(refusal);
    }
  }
  // Recorded FIRST: if anything below fails, the daily job finishes it.
  const closed = newClosedAccount(uid, facts.parentId, facts.banned, nowMs, facts.openCase);
  // No hold: the photos, case records and routes go in this same call.
  const steps = closed.hold ? immediateSteps() : [...immediateSteps(), ...evidenceSteps()];
  await runner.saveClosed({ ...closed, failed: steps });
  const failed = await runSteps(runner, uid, steps, nowMs, onError);
  const evidenceDoneAtMs = !closed.hold && !failed.some(isEvidenceStep) ? nowMs : null;
  await runner.saveClosed({ ...closed, failed, evidenceDoneAtMs });
  return { closed: true, failed: failed.length, held: closed.hold, evidenceAtMs: closed.evidenceAtMs, purgeAtMs: closed.purgeAtMs };
}

/** The evidence steps: photos, face reference, case records, archived routes. */
export function evidenceSteps(): string[] {
  return [...EVIDENCE_TARGETS.map((_, i) => `etarget:${i}`), ...EVIDENCE_STEPS.map((s) => `evidence:${s}`)];
}

function isEvidenceStep(name: string): boolean {
  return name.startsWith("etarget:") || name.startsWith("evidence:");
}

/** Every purge step (1 year after closure): consents and the parent's part of trips. */
export function purgeSteps(): string[] {
  return [...PURGE_TARGETS.map((_, i) => `ptarget:${i}`), ...PURGE_STEPS.map((s) => `purge:${s}`)];
}

/**
 * retentionDaily: retries failed steps, deletes the evidence when its
 * date came (the end of a safety hold; also every account closed under
 * the older 1-year rule), and purges the kept records of accounts whose
 * year is over. Returns what still fails (reported).
 */
export async function continueDeletion(
  runner: DeletionRunner,
  c: ClosedAccount,
  nowMs: number,
  onError: (step: string, error: unknown) => void,
): Promise<{ failed: string[]; purged: boolean; evidenceDeleted: boolean }> {
  let failed = c.failed.length > 0 ? await runSteps(runner, c.uid, c.failed, nowMs, onError) : [];
  let evidenceDoneAtMs = c.evidenceDoneAtMs;
  if (evidenceDoneAtMs === null && c.evidenceAtMs <= nowMs) {
    // Evidence steps already in the list were tried at deletion and again
    // just above; otherwise the evidence was waiting (hold) and runs now.
    if (!c.failed.some(isEvidenceStep)) failed = [...failed, ...(await runSteps(runner, c.uid, evidenceSteps(), nowMs, onError))];
    if (!failed.some(isEvidenceStep)) evidenceDoneAtMs = nowMs;
  }
  let purgedAtMs = c.purgedAtMs;
  if (purgedAtMs === null && evidenceDoneAtMs !== null && c.purgeAtMs <= nowMs && failed.length === 0) {
    failed = await runSteps(runner, c.uid, purgeSteps(), nowMs, onError);
    if (failed.length === 0) purgedAtMs = nowMs;
  }
  await runner.saveClosed({ ...c, failed, evidenceDoneAtMs, purgedAtMs });
  return { failed, purged: purgedAtMs !== null && c.purgedAtMs === null, evidenceDeleted: evidenceDoneAtMs !== null && c.evidenceDoneAtMs === null };
}

export class DeletionError extends Error {
  constructor(readonly reason: DeletionRefusal) {
    super(reason);
    this.name = "DeletionError";
  }
}
