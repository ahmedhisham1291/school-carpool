import { newEvent, type OutboxEvent } from "../notifications/model";
import {
  amountField,
  cairoDay,
  canUseWallet,
  cleanNote,
  GIVE_UP_AFTER_MS,
  isReportReason,
  MAX_RESENDS,
  normalizeParentId,
  optionalUid,
  PARTNER_TIMEOUT_MS,
  RECONCILE_AFTER_MS,
  record,
  REPORT_NOTE_MAX,
  requestIdField,
  transferId,
  transferIdField,
  transferView,
  WALLET_TERMS_VERSION,
  WalletError,
  type AlertRecord,
  type DailyCounter,
  type FailReason,
  type TransferKind,
  type TransferRecord,
  type TransferResult,
  type TransferView,
  type WalletAccount,
  type WalletLimits,
  type WalletRecord,
} from "./model";
import { withTimeout, WalletProviderError, type ProviderOp, type WalletProvider } from "./provider";
import type { WalletContact, WalletStore } from "./store";

/**
 * Everything a parent can do with the wallet (callables.ts wraps these).
 * Every check is here, on the server: verified and not suspended, a wallet
 * that is open and not frozen on both sides, limits from server settings,
 * one transfer per request ID. Logs: kinds, counts and IDs only, never
 * names, notes or amounts.
 */

export interface WalletDeps {
  store: WalletStore;
  /** null: the wallet is switched off here (no provider configured). */
  provider: WalletProvider | null;
  now: () => number;
  log: (message: string, data?: Record<string, unknown>) => void;
  /** Time limit of one partner call (PARTNER_TIMEOUT_MS). */
  timeoutMs?: number;
}

export interface Caller {
  uid: string;
  /** The "verified" custom claim; the record is checked too. */
  verifiedClaim: boolean;
}

const HOUR = 3_600_000;

function provider(deps: WalletDeps): WalletProvider {
  if (!deps.provider) throw new WalletError("wallet-off");
  return deps.provider;
}

function call<T>(deps: WalletDeps, p: Promise<T>): Promise<T> {
  return withTimeout(p, deps.timeoutMs ?? PARTNER_TIMEOUT_MS);
}

/** A partner call that is not about moving money (balance, open, freeze): any failure is "unavailable" for the parent. */
async function partnerRead<T>(deps: WalletDeps, p: () => Promise<T>): Promise<T> {
  try {
    return await call(deps, p());
  } catch (error) {
    if (error instanceof WalletProviderError && error.kind === "not-configured") throw new WalletError("wallet-off");
    deps.log("wallet partner call failed", { kind: error instanceof WalletProviderError ? error.kind : "error" });
    throw new WalletError("wallet-unavailable");
  }
}

/** The caller, verified and not suspended or banned (spec section 6). */
export async function requireWalletAccount(deps: WalletDeps, caller: Caller): Promise<WalletAccount> {
  if (!caller.verifiedClaim) throw new WalletError("not-verified");
  const account = await deps.store.account(caller.uid);
  if (!account) throw new WalletError("not-verified");
  if (account.banned || account.status === "suspended") throw new WalletError("suspended");
  if (!canUseWallet(account)) throw new WalletError("not-verified");
  return account;
}

async function requireOpenWallet(deps: WalletDeps, uid: string): Promise<WalletRecord> {
  const w = await deps.store.wallet(uid);
  if (!w) throw new WalletError("no-wallet");
  if (w.status === "frozen") throw new WalletError("frozen");
  return w;
}

async function take(deps: WalletDeps, uid: string, kind: "lookups" | "reports", windowMs: number, max: number): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), { windowMs, max });
  if (!r.allowed) throw new WalletError("rate-limited", { retryAfterSeconds: Math.ceil(r.retryAfterMs / 1000) });
}

// --------------------------------------------------------------------------
// Open and read the wallet
// --------------------------------------------------------------------------

export interface WalletView {
  /** False while no partner is configured here (the wallet is switched off). */
  available: boolean;
  opened: boolean;
  termsVersion: string;
  status: "none" | "active" | "frozen";
  /** From the partner, in piastres; null before the wallet is opened. */
  balance: number | null;
  balanceAtMs: number | null;
  limits: { minAmount: number; perTransferMax: number; perDayMax: number; topUpMax: number };
  /** Sent and withdrawn today (Cairo day). */
  todayOut: number;
}

function limitsView(l: WalletLimits): WalletView["limits"] {
  return { minAmount: l.minAmount, perTransferMax: l.perTransferMax, perDayMax: l.perDayMax, topUpMax: l.topUpMax };
}

/**
 * { acceptTerms: version } -> the wallet. Verified parents only, after they
 * agree to the partner's terms (consent record saved with the wallet).
 */
export async function openWallet(deps: WalletDeps, caller: Caller, data: unknown): Promise<WalletView> {
  await requireWalletAccount(deps, caller);
  const terms = record(data).acceptTerms;
  if (terms !== WALLET_TERMS_VERSION) throw new WalletError("terms-required");
  const p = provider(deps);
  if (!(await deps.store.wallet(caller.uid))) {
    const { walletRef } = await partnerRead(deps, () => p.openWallet({ customerRef: caller.uid, requestId: `open_${caller.uid}` }));
    const nowMs = deps.now();
    const w: WalletRecord = {
      uid: caller.uid,
      walletRef,
      status: "active",
      balanceCopy: 0,
      balanceAtMs: nowMs,
      termsVersion: WALLET_TERMS_VERSION,
      frozenReason: null,
      frozenAtMs: null,
      frozenBy: null,
      openedAtMs: nowMs,
      updatedAtMs: nowMs,
    };
    await deps.store.createWallet(w, { type: "walletTerms", version: WALLET_TERMS_VERSION, acceptedAtMs: nowMs });
    deps.log("wallet opened");
  }
  return getWallet(deps, caller);
}

/** {} -> the wallet. The balance always comes from the partner; without it the call fails (never a stale copy). */
export async function getWallet(deps: WalletDeps, caller: Caller): Promise<WalletView> {
  await requireWalletAccount(deps, caller);
  const limits = await deps.store.limits();
  const w = await deps.store.wallet(caller.uid);
  if (!w) {
    return { available: deps.provider !== null, opened: false, termsVersion: WALLET_TERMS_VERSION, status: "none", balance: null, balanceAtMs: null, limits: limitsView(limits), todayOut: 0 };
  }
  const p = provider(deps);
  // Transfers left pending by a lost connection are settled first.
  await reconcileMine(deps, caller.uid);
  const balance = await partnerRead(deps, () => p.balance(w.walletRef));
  const nowMs = deps.now();
  if (balance !== w.balanceCopy) await deps.store.updateWallet(caller.uid, { balanceCopy: balance, balanceAtMs: nowMs, updatedAtMs: nowMs });
  const today = await todayOut(deps, caller.uid);
  return {
    available: true,
    opened: true,
    termsVersion: w.termsVersion,
    status: w.status,
    balance,
    balanceAtMs: nowMs,
    limits: limitsView(limits),
    todayOut: today,
  };
}

async function todayOut(deps: WalletDeps, uid: string): Promise<number> {
  const day = cairoDay(deps.now());
  const sent = await deps.store.sentSince(uid, deps.now() - 26 * HOUR);
  const results = await deps.store.results(sent.map((t) => t.id));
  return sent
    .filter((t) => t.day === day && (t.kind === "transfer" || t.kind === "withdraw") && results.get(t.id)?.status !== "failed")
    .reduce((sum, t) => sum + t.amount, 0);
}

// --------------------------------------------------------------------------
// Receivers: parent ID lookup and carpool contacts
// --------------------------------------------------------------------------

/**
 * { parentId } -> { firstName, verified } only (F44, spec section 6).
 * Rate limited per parent BEFORE anything is looked up, so IDs cannot be
 * tried in bulk (spec section 7).
 */
export async function lookupParent(deps: WalletDeps, caller: Caller, data: unknown): Promise<{ firstName: string; verified: boolean }> {
  await requireWalletAccount(deps, caller);
  const limits = await deps.store.limits();
  await take(deps, caller.uid, "lookups", HOUR, limits.lookupsPerHour);
  const parentId = normalizeParentId(record(data).parentId);
  const uid = parentId ? await deps.store.uidOfParentId(parentId) : null;
  if (!uid) throw new WalletError("receiver-not-found");
  if (uid === caller.uid) throw new WalletError("self");
  const other = await deps.store.account(uid);
  if (!other) throw new WalletError("receiver-not-found");
  return { firstName: other.firstName, verified: canUseWallet(other) };
}

/** { carpoolId? } -> { contacts }: parents of my carpools (first name, badge, carpool). */
export async function walletContacts(deps: WalletDeps, caller: Caller, data: unknown): Promise<{ contacts: WalletContact[] }> {
  await requireWalletAccount(deps, caller);
  const carpoolId = optionalUid(data === undefined || data === null ? undefined : record(data).carpoolId);
  const all = await deps.store.contacts(caller.uid);
  const seen = new Set<string>();
  const contacts = all
    .filter((c) => c.uid !== caller.uid && (carpoolId === null || c.carpoolId === carpoolId))
    .filter((c) => {
      const key = `${c.carpoolId}/${c.uid}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => a.firstName.localeCompare(b.firstName));
  return { contacts };
}

// --------------------------------------------------------------------------
// Money: send, add, withdraw
// --------------------------------------------------------------------------

export interface MoneyResult {
  transfer: TransferView;
  /** Top-up with the real partner: the page where the parent pays. */
  checkoutUrl: string | null;
}

interface Receiver {
  uid: string;
  account: WalletAccount;
  wallet: WalletRecord;
}

async function resolveReceiver(deps: WalletDeps, caller: Caller, raw: Record<string, unknown>, carpoolId: string | null, limits: WalletLimits): Promise<Receiver> {
  const hasUid = raw.toUid !== undefined && raw.toUid !== null;
  const hasPid = raw.toParentId !== undefined && raw.toParentId !== null;
  if (hasUid === hasPid) throw new WalletError("invalid-request");
  let uid: string | null;
  if (hasPid) {
    // Counts as a lookup: send cannot be used to probe parent IDs.
    await take(deps, caller.uid, "lookups", HOUR, limits.lookupsPerHour);
    const pid = normalizeParentId(raw.toParentId);
    uid = pid ? await deps.store.uidOfParentId(pid) : null;
    if (!uid) throw new WalletError("receiver-not-found");
  } else {
    uid = optionalUid(raw.toUid);
    if (!uid) throw new WalletError("invalid-request");
  }
  if (uid === caller.uid) throw new WalletError("self");
  // Chosen from a carpool (or paying a contribution): both must be approved
  // members of that carpool. A uid is accepted only this way.
  if (hasUid || carpoolId !== null) {
    const contacts = await deps.store.contacts(caller.uid);
    const shared = contacts.some((c) => c.uid === uid && (carpoolId === null || c.carpoolId === carpoolId));
    if (!shared) throw new WalletError("not-in-carpool");
  }
  const account = await deps.store.account(uid);
  if (!account) throw new WalletError("receiver-not-found");
  if (!canUseWallet(account)) throw new WalletError("receiver-cannot-receive");
  const wallet = await deps.store.wallet(uid);
  if (!wallet || wallet.status !== "active") throw new WalletError("receiver-cannot-receive");
  return { uid, account, wallet };
}

/** The daily limits for money going out (transfers and withdrawals). */
function outgoingCheck(limits: WalletLimits, amount: number): (d: DailyCounter) => DailyCounter {
  return (d) => {
    if (d.outCount + 1 > limits.perDayCount) throw new WalletError("too-many-today");
    if (d.outAmount + amount > limits.perDayMax) {
      throw new WalletError("over-daily-limit", { limit: limits.perDayMax, left: Math.max(0, limits.perDayMax - d.outAmount) });
    }
    return { ...d, outAmount: d.outAmount + amount, outCount: d.outCount + 1 };
  };
}

function checkSingle(limits: WalletLimits, amount: number, max: number): void {
  if (amount < limits.minAmount) throw new WalletError("amount-too-small", { min: limits.minAmount });
  if (amount > max) throw new WalletError("over-transfer-limit", { limit: max });
}

/** The same request ID with different details is a mistake in the app, never a second transfer. */
function sameRequest(a: TransferRecord, kind: TransferKind, amount: number, toUid: string | null): boolean {
  return a.kind === kind && a.amount === amount && (toUid === null || a.toUid === toUid);
}

async function replay(deps: WalletDeps, existing: TransferRecord, viewer: string): Promise<MoneyResult> {
  let result = await deps.store.result(existing.id);
  if (!result && deps.now() - existing.createdAtMs >= RECONCILE_AFTER_MS) result = await reconcile(deps, existing);
  return { transfer: transferView(existing, result, viewer), checkoutUrl: null };
}

/**
 * { requestId, amount, toParentId | toUid, note?, carpoolId? } -> the
 * transfer (done, failed or pending). Both parents verified, not
 * suspended, wallets open and not frozen; limits per transfer and per day;
 * one transfer per request ID however often the app retries.
 * The fresh Face ID / fingerprint / passcode check happens on the phone
 * right before this call (local_auth; MONEY rules).
 */
export async function sendTransfer(deps: WalletDeps, caller: Caller, data: unknown): Promise<MoneyResult> {
  const me = await requireWalletAccount(deps, caller);
  const raw = record(data);
  const requestId = requestIdField(raw.requestId);
  const amount = amountField(raw.amount);
  const note = cleanNote(raw.note);
  const carpoolId = optionalUid(raw.carpoolId);
  const p = provider(deps);
  const id = transferId(caller.uid, requestId);

  // A retry (double tap, lost answer): the first attempt, never a second transfer.
  const earlier = await deps.store.transfer(id);
  if (earlier) {
    if (!sameRequest(earlier, "transfer", amount, null)) throw new WalletError("request-reused");
    return replay(deps, earlier, caller.uid);
  }

  const limits = await deps.store.limits();
  const myWallet = await requireOpenWallet(deps, caller.uid);
  const to = await resolveReceiver(deps, caller, raw, carpoolId, limits);
  checkSingle(limits, amount, limits.perTransferMax);

  const nowMs = deps.now();
  const t: TransferRecord = {
    id,
    kind: "transfer",
    requestId,
    uid: caller.uid,
    fromUid: caller.uid,
    toUid: to.uid,
    parties: [caller.uid, to.uid],
    fromFirstName: me.firstName,
    toFirstName: to.account.firstName,
    amount,
    currency: "EGP",
    note,
    carpoolId,
    day: cairoDay(nowMs),
    createdAtMs: nowMs,
  };
  const started = await deps.store.startTransfer(t, outgoingCheck(limits, amount));
  if (!started.created) {
    if (!sameRequest(started.transfer, "transfer", amount, to.uid)) throw new WalletError("request-reused");
    return replay(deps, started.transfer, caller.uid);
  }
  deps.log("transfer started", { id });
  await checkPatterns(deps, caller.uid, limits).catch((error: unknown) => deps.log("pattern check failed", { message: error instanceof Error ? error.message : "unknown" }));

  const result = await attempt(deps, t, () => p.send({ fromRef: myWallet.walletRef, toRef: to.wallet.walletRef, amount, requestId: id }));
  return { transfer: transferView(t, result.result, caller.uid), checkoutUrl: result.checkoutUrl };
}

/** { requestId, amount } -> the top-up. Real partner: may be pending with a page to pay on. */
export async function addMoney(deps: WalletDeps, caller: Caller, data: unknown): Promise<MoneyResult> {
  const me = await requireWalletAccount(deps, caller);
  const raw = record(data);
  const requestId = requestIdField(raw.requestId);
  const amount = amountField(raw.amount);
  const p = provider(deps);
  const id = transferId(caller.uid, requestId);
  const earlier = await deps.store.transfer(id);
  if (earlier) {
    if (!sameRequest(earlier, "topup", amount, null)) throw new WalletError("request-reused");
    return replay(deps, earlier, caller.uid);
  }
  const limits = await deps.store.limits();
  const w = await requireOpenWallet(deps, caller.uid);
  checkSingle(limits, amount, limits.topUpMax);
  const nowMs = deps.now();
  const t: TransferRecord = {
    id,
    kind: "topup",
    requestId,
    uid: caller.uid,
    fromUid: null,
    toUid: caller.uid,
    parties: [caller.uid],
    fromFirstName: "",
    toFirstName: me.firstName,
    amount,
    currency: "EGP",
    note: "",
    carpoolId: null,
    day: cairoDay(nowMs),
    createdAtMs: nowMs,
  };
  const started = await deps.store.startTransfer(t, (d) => {
    if (d.topUpAmount + amount > limits.topUpPerDayMax) {
      throw new WalletError("over-daily-limit", { limit: limits.topUpPerDayMax, left: Math.max(0, limits.topUpPerDayMax - d.topUpAmount) });
    }
    return { ...d, topUpAmount: d.topUpAmount + amount };
  });
  if (!started.created) return replay(deps, started.transfer, caller.uid);
  const result = await attempt(deps, t, () => p.addMoney({ walletRef: w.walletRef, amount, requestId: id }));
  return { transfer: transferView(t, result.result, caller.uid), checkoutUrl: result.checkoutUrl };
}

/** { requestId, amount } -> the withdrawal to the parent's own account at the partner. Counts in the daily limits. */
export async function withdraw(deps: WalletDeps, caller: Caller, data: unknown): Promise<MoneyResult> {
  const me = await requireWalletAccount(deps, caller);
  const raw = record(data);
  const requestId = requestIdField(raw.requestId);
  const amount = amountField(raw.amount);
  const p = provider(deps);
  const id = transferId(caller.uid, requestId);
  const earlier = await deps.store.transfer(id);
  if (earlier) {
    if (!sameRequest(earlier, "withdraw", amount, null)) throw new WalletError("request-reused");
    return replay(deps, earlier, caller.uid);
  }
  const limits = await deps.store.limits();
  const w = await requireOpenWallet(deps, caller.uid);
  checkSingle(limits, amount, limits.perTransferMax);
  const nowMs = deps.now();
  const t: TransferRecord = {
    id,
    kind: "withdraw",
    requestId,
    uid: caller.uid,
    fromUid: caller.uid,
    toUid: null,
    parties: [caller.uid],
    fromFirstName: me.firstName,
    toFirstName: "",
    amount,
    currency: "EGP",
    note: "",
    carpoolId: null,
    day: cairoDay(nowMs),
    createdAtMs: nowMs,
  };
  const started = await deps.store.startTransfer(t, outgoingCheck(limits, amount));
  if (!started.created) return replay(deps, started.transfer, caller.uid);
  const result = await attempt(deps, t, () => p.withdraw({ walletRef: w.walletRef, amount, requestId: id }));
  return { transfer: transferView(t, result.result, caller.uid), checkoutUrl: result.checkoutUrl };
}

// --------------------------------------------------------------------------
// Calling the partner and settling
// --------------------------------------------------------------------------

/**
 * Calls the partner once. A clear answer settles the transfer; a timeout,
 * an outage or any other surprise leaves it PENDING: the money may or may
 * not have moved, so nothing is decided until the partner is asked
 * (reconcile). A pending transfer keeps its amount counted in the day.
 */
async function attempt(deps: WalletDeps, t: TransferRecord, run: () => Promise<ProviderOp>, notify = false): Promise<{ result: TransferResult | null; checkoutUrl: string | null }> {
  let op: ProviderOp;
  try {
    op = await call(deps, run());
  } catch (error) {
    if (error instanceof WalletProviderError && !error.outcomeUnknown) {
      // The partner refused before anything moved.
      return { result: await settle(deps, t, failedOp("partner-error"), notify), checkoutUrl: null };
    }
    deps.log("transfer outcome unknown", { id: t.id, kind: error instanceof WalletProviderError ? error.kind : "error" });
    return { result: null, checkoutUrl: null };
  }
  if (op.status === "pending") return { result: null, checkoutUrl: op.checkoutUrl };
  return { result: await settle(deps, t, op, notify), checkoutUrl: null };
}

function failedOp(reason: FailReason): ProviderOp {
  return { status: "failed", partnerRef: null, reason, checkoutUrl: null };
}

/** Notification events of an outcome. IDs only: no amount, name or note (lock screen; spec section 7). */
export function outcomeEvents(t: TransferRecord, r: TransferResult, notifyFailure: boolean, nowMs: number): OutboxEvent[] {
  if (r.status === "done") {
    if (t.kind === "transfer" && t.fromUid && t.toUid) {
      return [newEvent(`wallet_${t.id}_in`, "wallet-received", [t.toUid], nowMs), newEvent(`wallet_${t.id}_out`, "wallet-sent", [t.fromUid], nowMs)];
    }
    return notifyFailure ? [newEvent(`wallet_${t.id}_done`, "wallet-updated", [t.uid], nowMs)] : [];
  }
  return notifyFailure ? [newEvent(`wallet_${t.id}_failed`, "wallet-failed", [t.uid], nowMs)] : [];
}

async function settle(deps: WalletDeps, t: TransferRecord, op: ProviderOp, notifyFailure: boolean): Promise<TransferResult> {
  const nowMs = deps.now();
  const r: TransferResult = {
    id: t.id,
    status: op.status === "done" ? "done" : "failed",
    reason: op.status === "done" ? null : (op.reason ?? "partner-error"),
    partnerRef: op.partnerRef,
    settledAtMs: nowMs,
  };
  const saved = await deps.store.settle(t, r, outcomeEvents(t, r, notifyFailure, nowMs));
  if (saved.created) deps.log("transfer settled", { id: t.id, status: saved.result.status, reason: saved.result.reason });
  if (saved.created && saved.result.status === "done") await refreshCopies(deps, t);
  return saved.result;
}

/** Keeps the balance copies near the partner's (best effort; the app always reads the partner). */
async function refreshCopies(deps: WalletDeps, t: TransferRecord): Promise<void> {
  const p = deps.provider;
  if (!p) return;
  for (const uid of t.parties) {
    try {
      const w = await deps.store.wallet(uid);
      if (!w) continue;
      const balance = await call(deps, p.balance(w.walletRef));
      await deps.store.updateWallet(uid, { balanceCopy: balance, balanceAtMs: deps.now(), updatedAtMs: deps.now() });
    } catch {
      // The copy is refreshed again on the next read.
    }
  }
}

/**
 * Settles a pending transfer WITHOUT ever risking a second payment:
 * 1. ask the partner for our request ID;
 * 2. it knows it: take its answer (done or failed);
 * 3. it does not: the money never moved, so the same request is sent again
 *    (the partner's idempotency key makes a late duplicate harmless), at
 *    most MAX_RESENDS times, and only while both wallets are still open;
 * 4. still unknown to the partner after GIVE_UP_AFTER_MS: failed (nothing
 *    moved). A partner that does not answer leaves it pending.
 */
export async function reconcile(deps: WalletDeps, t: TransferRecord): Promise<TransferResult | null> {
  const existing = await deps.store.result(t.id);
  if (existing) return existing;
  const p = deps.provider;
  if (!p) return null;
  const nowMs = deps.now();
  let op: ProviderOp | null;
  try {
    op = await call(deps, p.findOperation(t.id));
  } catch {
    deps.log("reconcile: partner did not answer", { id: t.id });
    return null;
  }
  const pending = await deps.store.pending(t.id);
  if (op && op.status !== "pending") return settle(deps, t, op, true);
  if (op) {
    await deps.store.touchPending(t.id, pending?.resends ?? 0, nowMs);
    return null;
  }
  if (nowMs - t.createdAtMs >= GIVE_UP_AFTER_MS) return settle(deps, t, failedOp("not-received"), true);
  const resends = pending?.resends ?? 0;
  if (resends >= MAX_RESENDS) {
    await deps.store.touchPending(t.id, resends, nowMs);
    return null;
  }
  await deps.store.touchPending(t.id, resends + 1, nowMs);
  // The wallets must still be open: a wallet frozen since then must not pay.
  const from = t.fromUid ? await deps.store.wallet(t.fromUid) : null;
  const to = t.toUid ? await deps.store.wallet(t.toUid) : null;
  if (t.fromUid && (!from || from.status !== "active")) return settle(deps, t, failedOp("sender-frozen"), true);
  if (t.toUid && (!to || to.status !== "active")) {
    return settle(deps, t, failedOp(t.kind === "topup" ? "sender-frozen" : "receiver-frozen"), true);
  }
  deps.log("reconcile: sending again", { id: t.id, resends: resends + 1 });
  const run =
    t.kind === "transfer"
      ? () => p.send({ fromRef: (from as WalletRecord).walletRef, toRef: (to as WalletRecord).walletRef, amount: t.amount, requestId: t.id })
      : t.kind === "topup"
        ? () => p.addMoney({ walletRef: (to as WalletRecord).walletRef, amount: t.amount, requestId: t.id })
        : () => p.withdraw({ walletRef: (from as WalletRecord).walletRef, amount: t.amount, requestId: t.id });
  return (await attempt(deps, t, run, true)).result;
}

async function reconcileMine(deps: WalletDeps, uid: string): Promise<void> {
  const mine = await deps.store.pendingOf(uid, 5);
  for (const pnd of mine) {
    if (deps.now() - pnd.createdAtMs < RECONCILE_AFTER_MS) continue;
    const t = await deps.store.transfer(pnd.id);
    if (t) await reconcile(deps, t);
  }
}

/** The scheduled job: every pending transfer older than RECONCILE_AFTER_MS. */
export async function reconcileAll(deps: WalletDeps, limit = 50): Promise<{ checked: number; settled: number }> {
  const list = await deps.store.pendingBefore(deps.now() - RECONCILE_AFTER_MS, limit);
  let settled = 0;
  for (const pnd of list) {
    const t = await deps.store.transfer(pnd.id);
    if (!t) continue;
    if (await reconcile(deps, t)) settled += 1;
  }
  return { checked: list.length, settled };
}

// --------------------------------------------------------------------------
// History, one transfer, reports
// --------------------------------------------------------------------------

/** { afterId? } -> { transfers, nextAfterId }: the caller's history, newest first. */
export async function listHistory(deps: WalletDeps, caller: Caller, data: unknown): Promise<{ transfers: TransferView[]; nextAfterId: string | null }> {
  await requireWalletAccount(deps, caller);
  const raw = data === undefined || data === null ? {} : record(data);
  const afterId = raw.afterId === undefined || raw.afterId === null ? null : transferIdField(raw.afterId);
  const limit = 30;
  const list = await deps.store.history(caller.uid, limit, afterId);
  const results = await deps.store.results(list.map((t) => t.id));
  return {
    transfers: list.map((t) => transferView(t, results.get(t.id) ?? null, caller.uid)),
    nextAfterId: list.length === limit ? list[list.length - 1].id : null,
  };
}

async function partyTransfer(deps: WalletDeps, caller: Caller, id: string): Promise<TransferRecord> {
  const t = await deps.store.transfer(id);
  if (!t || !t.parties.includes(caller.uid)) throw new WalletError("not-found");
  return t;
}

/** { transferId } -> the transfer; a pending one is checked with the partner first. */
export async function getTransfer(deps: WalletDeps, caller: Caller, data: unknown): Promise<TransferView> {
  await requireWalletAccount(deps, caller);
  const t = await partyTransfer(deps, caller, transferIdField(record(data).transferId));
  let result = await deps.store.result(t.id);
  if (!result && deps.now() - t.createdAtMs >= RECONCILE_AFTER_MS) result = await reconcile(deps, t);
  return transferView(t, result, caller.uid);
}

/**
 * { transferId, reason, note? } -> { alertId, frozen }: a problem with a
 * transfer goes to the admins (and to the partner's dispute process: the
 * app cannot reverse a transfer). "Someone else sent it" from the sender
 * freezes the sender's own wallet at once, so a stolen phone cannot send more.
 */
export async function reportTransfer(deps: WalletDeps, caller: Caller, data: unknown): Promise<{ alertId: string; frozen: boolean }> {
  await requireWalletAccount(deps, caller);
  const raw = record(data);
  const t = await partyTransfer(deps, caller, transferIdField(raw.transferId));
  if (!isReportReason(raw.reason)) throw new WalletError("invalid-request");
  const note = cleanNote(raw.note, REPORT_NOTE_MAX);
  const limits = await deps.store.limits();
  await take(deps, caller.uid, "reports", 24 * HOUR, limits.reportsPerDay);
  const nowMs = deps.now();
  const alert: AlertRecord = {
    id: `report_${t.id}_${caller.uid}`,
    kind: "report",
    uid: caller.uid,
    transferId: t.id,
    reason: raw.reason,
    note,
    count: 1,
    status: "open",
    outcome: null,
    handledBy: null,
    createdAtMs: nowMs,
    handledAtMs: null,
  };
  await deps.store.createAlert(alert);
  let frozen = false;
  if (raw.reason === "unauthorized" && t.uid === caller.uid) {
    const w = await deps.store.wallet(caller.uid);
    if (w && w.status === "active") {
      // Our record first: even if the partner does not answer, no money leaves through us.
      await deps.store.updateWallet(caller.uid, { status: "frozen", frozenReason: "stolenPhone", frozenAtMs: nowMs, frozenBy: caller.uid, updatedAtMs: nowMs });
      try {
        if (deps.provider) await call(deps, deps.provider.freeze(w.walletRef, true));
      } catch {
        deps.log("partner freeze failed; frozen on our side", { id: t.id });
      }
    }
    frozen = true;
  }
  deps.log("transfer reported", { id: t.id, reason: raw.reason, frozen });
  return { alertId: alert.id, frozen };
}

// --------------------------------------------------------------------------
// Unusual patterns (admins are alerted; nothing is blocked automatically)
// --------------------------------------------------------------------------

/** The patterns in one parent's last hour of sending: many first-time receivers, or many transfers. */
export function detectPatterns(
  sentLastHour: TransferRecord[],
  isNewReceiver: (toUid: string) => boolean,
  limits: Pick<WalletLimits, "alertNewReceivers" | "alertTransfersPerHour">,
): { newReceivers: number; transfers: number; alerts: Array<"new-receivers" | "many-transfers"> } {
  const transfers = sentLastHour.filter((t) => t.kind === "transfer");
  const receivers = [...new Set(transfers.map((t) => t.toUid).filter((u): u is string => !!u))];
  const newReceivers = receivers.filter(isNewReceiver).length;
  const alerts: Array<"new-receivers" | "many-transfers"> = [];
  if (newReceivers >= limits.alertNewReceivers) alerts.push("new-receivers");
  if (transfers.length >= limits.alertTransfersPerHour) alerts.push("many-transfers");
  return { newReceivers, transfers: transfers.length, alerts };
}

async function checkPatterns(deps: WalletDeps, uid: string, limits: WalletLimits): Promise<void> {
  const nowMs = deps.now();
  const since = nowMs - HOUR;
  const sent = await deps.store.sentSince(uid, since);
  const known = new Map<string, boolean>();
  for (const to of new Set(sent.map((t) => t.toUid).filter((u): u is string => !!u))) {
    known.set(to, await deps.store.sentBefore(uid, to, since));
  }
  const found = detectPatterns(sent, (to) => known.get(to) !== true, limits);
  const bucket = Math.floor(nowMs / HOUR);
  for (const kind of found.alerts) {
    const created = await deps.store.createAlert({
      id: `${kind}_${uid}_${bucket}`,
      kind,
      uid,
      transferId: null,
      reason: null,
      note: "",
      count: kind === "new-receivers" ? found.newReceivers : found.transfers,
      status: "open",
      outcome: null,
      handledBy: null,
      createdAtMs: nowMs,
      handledAtMs: null,
    });
    if (created) deps.log("wallet alert", { kind });
  }
}
