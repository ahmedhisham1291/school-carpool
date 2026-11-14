import { createHash } from "node:crypto";
import type { AuditEntry } from "../admin_panel/types";
import { FeatureOffError, type FeatureSwitches } from "../features/model";
import { newEvent, type OutboxEvent } from "../notifications/model";
import {
  applyAction,
  canReport,
  DEFAULT_SETTLE_LIMITS,
  docId,
  ipaField,
  isFinal,
  limitRule,
  markReported,
  MAX_OPEN_PER_PAIR,
  newRecord,
  noteField,
  noticeFor,
  parseAction,
  parseCreate,
  record,
  roleOf,
  sameRequest,
  SettleError,
  settingsFrom,
  type SettleLimitKind,
  type SettleLimits,
  type SettleRecord,
  type SettleRole,
  type SettleSettings,
} from "./model";

/**
 * Settle up flows (F45) over a [SettleStore]. Every write happens here
 * (Cloud Functions); the app only calls these and reads its own records.
 * The app never moves, holds or sees money: these are records between two
 * parents. Logs carry reasons and counts only: never an InstaPay address,
 * an amount, a name or a note.
 */

export interface SettleAccount {
  uid: string;
  /** users/{uid}.status */
  status: string;
  banned: boolean;
  firstName: string;
}

export interface SettleContact {
  uid: string;
  firstName: string;
  verified: boolean;
  carpoolId: string;
  carpoolNameAr: string;
  carpoolNameEn: string;
}

export interface SettleReport {
  reporterUid: string;
  targetUid: string;
  settleUpId: string;
  note: string;
}

export interface SettleStore {
  account(uid: string): Promise<SettleAccount | null>;
  /** Both are approved members of this carpool now. */
  approvedMember(carpoolId: string, uid: string): Promise<boolean>;
  /**
   * Either parent blocked the other (chat blocks). The Firestore store
   * reads the chat feature's `chatBlocks` collection (store.ts,
   * chatBlockDocId): this method is the one seam, so a change of where
   * blocks live is a change in one place.
   */
  blockedEitherWay(a: string, b: string): Promise<boolean>;
  address(uid: string): Promise<string | null>;
  saveAddress(uid: string, address: string, nowMs: number): Promise<void>;
  removeAddress(uid: string): Promise<void>;
  /** config/settleUp as stored. */
  settings(): Promise<Record<string, unknown> | null>;
  takeLimit(uid: string, kind: SettleLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;
  get(id: string): Promise<SettleRecord | null>;
  /**
   * In ONE transaction: returns the record with this ID when it exists
   * (created: false); refuses with full: true when the two parents already
   * have [maxUnfinished] unfinished records (counted in the same
   * transaction, so two requests at once cannot both pass); otherwise
   * creates [r] and writes its event.
   */
  create(r: SettleRecord, event: OutboxEvent, maxUnfinished: number): Promise<{ record: SettleRecord; created: boolean; full: boolean }>;
  /**
   * In one transaction: reads the record, applies [change] and writes the
   * result, its event and, when given, a report for the admins' queue (so
   * a record is never marked "reported" without its report). null: not found.
   */
  update(id: string, change: (r: SettleRecord) => { record: SettleRecord; event: OutboxEvent | null; report?: SettleReport | null }): Promise<SettleRecord | null>;
  /** The parent's records, newest first. */
  listFor(uid: string, limit: number): Promise<SettleRecord[]>;
  /** Parents of the caller's active carpools (approved members). */
  contacts(uid: string): Promise<SettleContact[]>;
  audit(entry: AuditEntry): Promise<void>;
}

export interface SettleDeps {
  store: SettleStore;
  now: () => number;
  limits?: SettleLimits;
  /** The pilot feature switches; absent (unit tests of the feature itself): on. */
  features?: () => Promise<FeatureSwitches>;
}

export interface Caller {
  uid: string;
  verifiedClaim: boolean;
}

const limitsOf = (deps: SettleDeps): SettleLimits => deps.limits ?? DEFAULT_SETTLE_LIMITS;

async function requireOn(deps: SettleDeps): Promise<void> {
  if (deps.features && !(await deps.features()).settleUp) throw new FeatureOffError("settleUp");
}

async function take(deps: SettleDeps, uid: string, kind: SettleLimitKind): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), limitRule(limitsOf(deps), kind));
  if (!r.allowed) throw new SettleError("rate-limited", { retryAfterMs: r.retryAfterMs });
}

/** Verified, not suspended, not banned (claim and record both). */
export function eligible(a: SettleAccount | null): a is SettleAccount {
  return !!a && !a.banned && a.status === "verified";
}

async function requireEligible(deps: SettleDeps, caller: Caller): Promise<SettleAccount> {
  const account = await deps.store.account(caller.uid);
  if (!account) throw new SettleError("no-account");
  if (account.banned || account.status === "suspended") throw new SettleError("suspended");
  if (!caller.verifiedClaim || account.status !== "verified") throw new SettleError("not-verified");
  return account;
}

/** A signed-in parent with a record: enough to finish records that exist. */
async function requireAccount(deps: SettleDeps, caller: Caller): Promise<SettleAccount> {
  const account = await deps.store.account(caller.uid);
  if (!account) throw new SettleError("no-account");
  return account;
}

/** Short fixed event IDs (the outbox; no names, amounts or addresses in them). */
function eventId(...parts: string[]): string {
  return `settle_${createHash("sha256").update(parts.join("|")).digest("hex").slice(0, 32)}`;
}

function notice(r: SettleRecord, kind: Parameters<typeof noticeFor>[0], actorUid: string, toUid: string, nowMs: number): OutboxEvent {
  // One event per record and history entry: a retried call never sends twice.
  return newEvent(eventId(r.id, String(r.events.length), kind), noticeFor(kind), [toUid], nowMs, { actorUid });
}

// --------------------------------------------------------------------------
// The caller's InstaPay address
// --------------------------------------------------------------------------

export interface ProfileView {
  /** The caller's own address, or null. Never anyone else's. */
  address: string | null;
  maxAmount: number;
  reportAfter: number;
}

/** {} -> { address, maxAmount, reportAfter } */
export async function getProfile(deps: SettleDeps, caller: Caller): Promise<ProfileView> {
  await requireOn(deps);
  await requireAccount(deps, caller);
  const settings = settingsFrom(await deps.store.settings());
  return { address: await deps.store.address(caller.uid), maxAmount: settings.maxAmount, reportAfter: limitsOf(deps).reportAfter };
}

/** { address } -> { address }: verified parents only; the shape is checked, the address stays private. */
export async function saveAddress(deps: SettleDeps, caller: Caller, data: unknown): Promise<{ address: string }> {
  await requireOn(deps);
  const address = ipaField(record(data).address);
  await requireEligible(deps, caller);
  await take(deps, caller.uid, "addressChanges");
  await deps.store.saveAddress(caller.uid, address, deps.now());
  return { address };
}

/**
 * {} -> { removed }: the owner removes it at any time (open requests then
 * show "no address"). Never rate limited: taking your own address away
 * must always work.
 */
export async function removeAddress(deps: SettleDeps, caller: Caller): Promise<{ removed: true }> {
  await requireOn(deps);
  await requireAccount(deps, caller);
  await deps.store.removeAddress(caller.uid);
  return { removed: true };
}

// --------------------------------------------------------------------------
// Contacts, create, actions
// --------------------------------------------------------------------------

/** { carpoolId? } -> { contacts }: parents of my carpools I can settle up with. */
export async function contacts(deps: SettleDeps, caller: Caller, data: unknown): Promise<{ contacts: SettleContact[] }> {
  await requireOn(deps);
  await requireEligible(deps, caller);
  const raw = data === undefined || data === null ? {} : record(data);
  const carpoolId = raw.carpoolId === undefined || raw.carpoolId === null ? null : docId(raw.carpoolId);
  const seen = new Set<string>();
  const list = (await deps.store.contacts(caller.uid))
    .filter((c) => c.uid !== caller.uid && (carpoolId === null || c.carpoolId === carpoolId))
    .filter((c) => {
      const key = `${c.carpoolId}/${c.uid}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => a.firstName.localeCompare(b.firstName) || a.uid.localeCompare(b.uid));
  return { contacts: list };
}

async function settingsOf(deps: SettleDeps): Promise<SettleSettings> {
  return settingsFrom(await deps.store.settings());
}

/**
 * { requestId, kind: request | paid, otherUid, carpoolId, amount, reason, note? } -> { record, created }
 *
 * "request": the caller (payee) asks the other parent to pay; needs the
 * caller's saved InstaPay address. "paid": the caller (payer) records a
 * payment already made; it waits for the payee's confirmation.
 * Both must be verified, not suspended or banned, not blocked by each
 * other, and approved members of [carpoolId] now. One record per request
 * ID: a retry returns the first one.
 */
export async function createSettleUp(deps: SettleDeps, caller: Caller, data: unknown): Promise<{ record: SettleRecord; created: boolean }> {
  await requireOn(deps);
  const input = parseCreate(data, await settingsOf(deps));
  const me = await requireEligible(deps, caller);
  if (input.otherUid === caller.uid) throw new SettleError("self");
  const nowMs = deps.now();
  const draft = newRecord(input, { uid: me.uid, firstName: me.firstName }, { uid: input.otherUid, firstName: "" }, nowMs);
  // A retry of a request that already exists: no second record, no second check.
  const before = await deps.store.get(draft.id);
  if (before) {
    if (!sameRequest(before, { ...draft, payeeFirstName: before.payeeFirstName, payerFirstName: before.payerFirstName })) throw new SettleError("request-reused");
    return { record: before, created: false };
  }
  const other = await deps.store.account(input.otherUid);
  // One answer for "no such parent", "not verified" and "blocked": nothing to probe.
  if (!eligible(other)) throw new SettleError("not-allowed");
  if (await deps.store.blockedEitherWay(caller.uid, other.uid)) throw new SettleError("not-allowed");
  const [mine, theirs] = await Promise.all([deps.store.approvedMember(input.carpoolId, caller.uid), deps.store.approvedMember(input.carpoolId, other.uid)]);
  if (!mine || !theirs) throw new SettleError("not-allowed");
  if (input.kind === "request" && !(await deps.store.address(caller.uid))) throw new SettleError("no-address");
  await take(deps, caller.uid, "requests");
  const fresh = newRecord(input, { uid: me.uid, firstName: me.firstName }, { uid: other.uid, firstName: other.firstName }, nowMs);
  const event = notice(fresh, input.kind === "request" ? "requested" : "recorded", caller.uid, other.uid, nowMs);
  const result = await deps.store.create(fresh, event, MAX_OPEN_PER_PAIR);
  if (result.full) throw new SettleError("too-many-open");
  if (!result.created && !sameRequest(result.record, fresh)) throw new SettleError("request-reused");
  return { record: result.record, created: result.created };
}

/**
 * { id, action: paid | received | notReceived | cancel | decline } -> { record }
 *
 * Only the two parties, each for their own steps (model.ts TRANSITIONS).
 * No carpool or verification check here: a parent who left the carpool (or
 * was suspended since) can still finish records that exist.
 */
export async function settleUpAction(deps: SettleDeps, caller: Caller, data: unknown): Promise<{ record: SettleRecord }> {
  await requireOn(deps);
  const { id, action } = parseAction(data);
  await requireAccount(deps, caller);
  await take(deps, caller.uid, "changes");
  const nowMs = deps.now();
  const updated = await deps.store.update(id, (r) => {
    const role = roleOf(r, caller.uid);
    // Not a party: the same answer as a record that does not exist.
    if (!role) throw new SettleError("not-found");
    const next = applyAction(r, role, action, nowMs);
    const otherUid = role === "payee" ? next.payerUid : next.payeeUid;
    const event = next.parties.includes(otherUid) ? notice(next, action, caller.uid, otherUid, nowMs) : null;
    return { record: next, event };
  });
  if (!updated) throw new SettleError("not-found");
  return { record: updated };
}

/**
 * { id } -> { address }: the payee's InstaPay address, shown ONLY when all
 * of these hold (anything else is refused, and every refusal is tested):
 * - the caller is the record's payer, verified now, not suspended or banned;
 * - the PAYEE created the record (a real request from the address owner).
 *   A record the payer made themselves ("I already paid") never opens the
 *   address, also not after the payee answers "Not received" and it reads
 *   as open again: otherwise any carpool member could fetch an address
 *   nobody offered them;
 * - the record is open (not paid, closed, cancelled or declined) and
 *   nobody reported it;
 * - the payee still has an account, is verified and not suspended or
 *   banned, and neither parent blocked the other.
 * null when the payee removed the address. Rate limited; never logged.
 */
export async function getAddressFor(deps: SettleDeps, caller: Caller, data: unknown): Promise<{ address: string | null }> {
  await requireOn(deps);
  const id = docId(record(data).id);
  await requireEligible(deps, caller);
  const r = await deps.store.get(id);
  if (!r || !roleOf(r, caller.uid)) throw new SettleError("not-found");
  if (roleOf(r, caller.uid) !== "payer") throw new SettleError("not-allowed");
  if (r.createdBy !== "payee") throw new SettleError("not-allowed");
  if (r.status !== "open") throw new SettleError("invalid-state", { status: r.status });
  if (r.reportedBy.length > 0) throw new SettleError("not-allowed");
  if (!r.parties.includes(r.payeeUid)) throw new SettleError("not-allowed");
  if (!eligible(await deps.store.account(r.payeeUid))) throw new SettleError("not-allowed");
  if (await deps.store.blockedEitherWay(caller.uid, r.payeeUid)) throw new SettleError("not-allowed");
  await take(deps, caller.uid, "addressViews");
  return { address: await deps.store.address(r.payeeUid) };
}

/**
 * { id, note? } -> { reported }: after the record bounced ("Not received")
 * limits.reportAfter times either side may send it to the admins' reports
 * queue, once per side. The app cannot settle a money dispute: the report
 * is about the other parent's conduct.
 */
export async function reportSettleUp(deps: SettleDeps, caller: Caller, data: unknown): Promise<{ reported: true }> {
  await requireOn(deps);
  const raw = record(data);
  const id = docId(raw.id);
  const note = noteField(raw.note);
  await requireAccount(deps, caller);
  await take(deps, caller.uid, "changes");
  const nowMs = deps.now();
  // The mark and the report are written together (one transaction): a
  // failed write leaves neither, so a retry reports again instead of
  // answering "already reported" with no report in the queue.
  const updated = await deps.store.update(id, (r) => {
    const role: SettleRole | null = roleOf(r, caller.uid);
    if (!role) throw new SettleError("not-found");
    const can = canReport(r, role, limitsOf(deps).reportAfter);
    if (can !== "ok") throw new SettleError(can);
    const targetUid = role === "payee" ? r.payerUid : r.payeeUid;
    return { record: markReported(r, role, nowMs), event: null, report: { reporterUid: caller.uid, targetUid, settleUpId: id, note } };
  });
  if (!updated) throw new SettleError("not-found");
  return { reported: true };
}

// --------------------------------------------------------------------------
// Admin panel: read-only, with a logged reason
// --------------------------------------------------------------------------

export interface AdminSettleView {
  id: string;
  role: SettleRole;
  otherFirstName: string;
  amount: number;
  reason: string;
  status: string;
  notReceived: number;
  reported: boolean;
  finished: boolean;
  createdAtMs: number;
  updatedAtMs: number;
}

/**
 * { uid, reason } -> { records }: one parent's settle-up records for the
 * user page. Read only (admins cannot change a record), logged first with
 * the reason code. Never the InstaPay address and never the note.
 */
export async function adminListSettleUps(deps: SettleDeps, adminUid: string, uid: string, reasonCode: string, ip: string | null): Promise<{ records: AdminSettleView[] }> {
  await requireOn(deps);
  await deps.store.audit({ actorUid: adminUid, action: "settle-up.view", target: `users/${uid}`, reasonCode, ip });
  const records = await deps.store.listFor(uid, 100);
  return {
    records: records.flatMap((r) => {
      const role = roleOf(r, uid);
      if (!role) return [];
      return [
        {
          id: r.id,
          role,
          otherFirstName: role === "payee" ? r.payerFirstName : r.payeeFirstName,
          amount: r.amount,
          reason: r.reason,
          status: r.status,
          notReceived: r.notReceived,
          reported: r.reportedBy.length > 0,
          finished: isFinal(r.status),
          createdAtMs: r.createdAtMs,
          updatedAtMs: r.updatedAtMs,
        },
      ];
    }),
  };
}
