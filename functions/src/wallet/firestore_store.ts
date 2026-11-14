import { Timestamp, type DocumentData, type Firestore, type Query, type Transaction } from "firebase-admin/firestore";
import { PARENT_IDS, USERS } from "../auth/accounts";
import { CARPOOLS, MEMBERS } from "../carpools/store";
import { FirestoreChatStore } from "../chat/firestore_store";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import type { OutboxEvent } from "../notifications/model";
import { NOTIFICATION_EVENTS, outboxDoc } from "../notifications/outbox";
import {
  dailyId,
  FAIL_REASONS,
  isFreezeReason,
  isReportReason,
  limitsFrom,
  type AlertKind,
  type AlertRecord,
  type DailyCounter,
  type FailReason,
  type PendingRecord,
  type TransferKind,
  type TransferRecord,
  type TransferResult,
  type WalletAccount,
  type WalletLimits,
  type WalletRecord,
} from "./model";
import type { FakeAccount, FakeLedger, FakeMode, FakeOp } from "./provider";
import type { ConsentRecord, SettleResult, StartResult, WalletContact, WalletLimitKind, WalletStore } from "./store";

/**
 * Wallet records in Firestore. Cloud Functions only: firestore.rules close
 * every one of them to the app (the app never writes a balance or a
 * transfer, and reads its wallet through the functions).
 *
 * - wallets/{uid}: partner reference, status (active, frozen), balance copy
 * - transfers/{id}: one per money request, created once, never changed
 * - transferResults/{id}: its outcome, created once, never changed
 * - walletPending/{id}: transfers waiting for the partner's answer (work list)
 * - walletDaily/{uid}_{day}: amounts moved per Cairo day (limits)
 * - walletLimits/{uid}: lookup and report counters
 * - walletAlerts/{id}: unusual patterns and transfer reports, for admins
 * - config/wallet: limits (server settings); config/walletFake: fake mode
 * - fakeWalletAccounts/{ref}, fakeWalletOps/{requestId}: the FAKE partner's
 *   test money (dev and staging only; the fake is refused in prod)
 * - users/{uid}/consents/{id}: the "walletTerms" consent (Prompt 2 records)
 */

export const WALLETS = "wallets";
export const TRANSFERS = "transfers";
export const TRANSFER_RESULTS = "transferResults";
export const WALLET_PENDING = "walletPending";
export const WALLET_DAILY = "walletDaily";
export const WALLET_LIMITS = "walletLimits";
export const WALLET_ALERTS = "walletAlerts";
export const FAKE_ACCOUNTS = "fakeWalletAccounts";
export const FAKE_OPS = "fakeWalletOps";
const CONFIG = "config";

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);
const tsOrNull = (ms: number | null): Timestamp | null => (ms === null ? null : ts(ms));

function ms(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function msOrNull(v: unknown): number | null {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : null;
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function int(v: unknown): number {
  return typeof v === "number" && Number.isSafeInteger(v) ? v : 0;
}

function isAlreadyExists(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  return code === 6 || code === "already-exists";
}

export function walletToDoc(w: WalletRecord): DocumentData {
  return {
    uid: w.uid,
    walletRef: w.walletRef,
    status: w.status,
    balanceCopy: w.balanceCopy,
    balanceAt: ts(w.balanceAtMs),
    termsVersion: w.termsVersion,
    frozenReason: w.frozenReason,
    frozenAt: tsOrNull(w.frozenAtMs),
    frozenBy: w.frozenBy,
    partnerSynced: w.partnerSynced,
    openedAt: ts(w.openedAtMs),
    updatedAt: ts(w.updatedAtMs),
  };
}

export function walletFromDoc(uid: string, d: DocumentData): WalletRecord {
  return {
    uid,
    walletRef: text(d.walletRef),
    status: d.status === "frozen" ? "frozen" : "active",
    balanceCopy: int(d.balanceCopy),
    balanceAtMs: ms(d.balanceAt),
    termsVersion: text(d.termsVersion),
    frozenReason: isFreezeReason(d.frozenReason) ? d.frozenReason : null,
    frozenAtMs: msOrNull(d.frozenAt),
    frozenBy: text(d.frozenBy) || null,
    partnerSynced: d.partnerSynced !== false,
    openedAtMs: ms(d.openedAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function transferToDoc(t: TransferRecord): DocumentData {
  return {
    kind: t.kind,
    requestId: t.requestId,
    uid: t.uid,
    fromUid: t.fromUid,
    toUid: t.toUid,
    parties: t.parties,
    fromFirstName: t.fromFirstName,
    toFirstName: t.toFirstName,
    amount: t.amount,
    currency: t.currency,
    note: t.note,
    carpoolId: t.carpoolId,
    day: t.day,
    // The record is never changed. Its status is NOT here: the outcome is
    // transferResults/{id} (spec section 9, "Transfer"); this only says how
    // every transfer starts, so a console reader is not misled.
    initialStatus: "pending",
    createdAt: ts(t.createdAtMs),
  };
}

const KINDS: readonly TransferKind[] = ["transfer", "topup", "withdraw"];

export function transferFromDoc(id: string, d: DocumentData): TransferRecord {
  return {
    id,
    kind: KINDS.includes(d.kind) ? (d.kind as TransferKind) : "transfer",
    requestId: text(d.requestId),
    uid: text(d.uid),
    fromUid: text(d.fromUid) || null,
    toUid: text(d.toUid) || null,
    parties: Array.isArray(d.parties) ? d.parties.filter((p: unknown): p is string => typeof p === "string") : [],
    fromFirstName: text(d.fromFirstName),
    toFirstName: text(d.toFirstName),
    amount: int(d.amount),
    currency: "EGP",
    note: text(d.note),
    carpoolId: text(d.carpoolId) || null,
    day: text(d.day),
    createdAtMs: ms(d.createdAt),
  };
}

export function resultToDoc(r: TransferResult): DocumentData {
  return { status: r.status, reason: r.reason, partnerRef: r.partnerRef, settledAt: ts(r.settledAtMs) };
}

export function resultFromDoc(id: string, d: DocumentData): TransferResult {
  return {
    id,
    status: d.status === "done" ? "done" : "failed",
    reason: (FAIL_REASONS as readonly string[]).includes(d.reason) ? (d.reason as FailReason) : null,
    partnerRef: text(d.partnerRef) || null,
    settledAtMs: ms(d.settledAt),
  };
}

function pendingFromDoc(id: string, d: DocumentData): PendingRecord {
  return { id, uid: text(d.uid), createdAtMs: ms(d.createdAt), resends: int(d.resends), checkedAtMs: ms(d.checkedAt), leaseUntilMs: ms(d.leaseUntil) };
}

function dailyFromDoc(d: DocumentData | undefined): DailyCounter {
  return { outAmount: int(d?.outAmount), outCount: int(d?.outCount), topUpAmount: int(d?.topUpAmount) };
}

const ALERT_KINDS: readonly AlertKind[] = ["new-receivers", "many-transfers", "report", "stuck"];

export function alertToDoc(a: AlertRecord): DocumentData {
  return {
    kind: a.kind,
    uid: a.uid,
    transferId: a.transferId,
    reason: a.reason,
    note: a.note,
    count: a.count,
    status: a.status,
    outcome: a.outcome,
    handledBy: a.handledBy,
    createdAt: ts(a.createdAtMs),
    handledAt: tsOrNull(a.handledAtMs),
  };
}

export function alertFromDoc(id: string, d: DocumentData): AlertRecord {
  return {
    id,
    kind: ALERT_KINDS.includes(d.kind) ? (d.kind as AlertKind) : "report",
    uid: text(d.uid),
    transferId: text(d.transferId) || null,
    reason: isReportReason(d.reason) ? d.reason : null,
    note: text(d.note),
    count: int(d.count),
    status: d.status === "handled" ? "handled" : "open",
    outcome: text(d.outcome) || null,
    handledBy: text(d.handledBy) || null,
    createdAtMs: ms(d.createdAt),
    handledAtMs: msOrNull(d.handledAt),
  };
}

export class FirestoreWalletStore implements WalletStore {
  private readonly chat: FirestoreChatStore;

  constructor(private readonly db: Firestore) {
    this.chat = new FirestoreChatStore(db);
  }

  async account(uid: string): Promise<WalletAccount | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { uid, status: text(d.status) || "unverified", banned: d.banned === true, firstName: text(d.firstName), parentId: text(d.parentId) };
  }

  async uidOfParentId(parentId: string): Promise<string | null> {
    const snap = await this.db.collection(PARENT_IDS).doc(parentId).get();
    return snap.exists ? text(snap.get("uid")) || null : null;
  }

  async wallet(uid: string): Promise<WalletRecord | null> {
    const snap = await this.db.collection(WALLETS).doc(uid).get();
    return snap.exists ? walletFromDoc(uid, snap.data() ?? {}) : null;
  }

  async createWallet(w: WalletRecord, consent: ConsentRecord): Promise<boolean> {
    const batch = this.db.batch();
    batch.create(this.db.collection(WALLETS).doc(w.uid), walletToDoc(w));
    batch.create(this.db.collection(USERS).doc(w.uid).collection("consents").doc(), {
      type: consent.type,
      version: consent.version,
      acceptedAt: ts(consent.acceptedAtMs),
      withdrawnAt: null,
      source: "wallet",
    });
    try {
      await batch.commit();
      return true;
    } catch (error) {
      if (isAlreadyExists(error)) return false;
      throw error;
    }
  }

  async updateWallet(uid: string, change: Partial<WalletRecord>, note?: string): Promise<void> {
    const d: DocumentData = {};
    if (change.balanceCopy !== undefined) d.balanceCopy = change.balanceCopy;
    if (change.balanceAtMs !== undefined) d.balanceAt = ts(change.balanceAtMs);
    if (change.status !== undefined) d.status = change.status;
    if (change.frozenReason !== undefined) d.frozenReason = change.frozenReason;
    if (change.frozenAtMs !== undefined) d.frozenAt = tsOrNull(change.frozenAtMs);
    if (change.frozenBy !== undefined) d.frozenBy = change.frozenBy;
    if (change.partnerSynced !== undefined) d.partnerSynced = change.partnerSynced;
    if (change.updatedAtMs !== undefined) d.updatedAt = ts(change.updatedAtMs);
    // The admin's note stays on the server (never shown to the parent).
    if (note !== undefined) d.adminNote = note;
    await this.db.collection(WALLETS).doc(uid).update(d);
  }

  async walletsToSync(limit: number): Promise<WalletRecord[]> {
    const snap = await this.db.collection(WALLETS).where("partnerSynced", "==", false).limit(limit).get();
    return snap.docs.map((d) => walletFromDoc(d.id, d.data()));
  }

  async limits(): Promise<WalletLimits> {
    const snap = await this.db.collection(CONFIG).doc("wallet").get();
    return limitsFrom(snap.exists ? snap.data() : null);
  }

  async startTransfer(t: TransferRecord, check: (daily: DailyCounter, wallets: Map<string, WalletRecord | null>) => DailyCounter): Promise<StartResult> {
    const ref = this.db.collection(TRANSFERS).doc(t.id);
    const dailyRef = this.db.collection(WALLET_DAILY).doc(dailyId(t.uid, t.day));
    return this.db.runTransaction(async (tx: Transaction) => {
      const existing = await tx.get(ref);
      if (existing.exists) {
        const resultSnap = await tx.get(this.db.collection(TRANSFER_RESULTS).doc(t.id));
        return {
          created: false,
          transfer: transferFromDoc(t.id, existing.data() ?? {}),
          result: resultSnap.exists ? resultFromDoc(t.id, resultSnap.data() ?? {}) : null,
        };
      }
      const daily = await tx.get(dailyRef);
      const wallets = new Map<string, WalletRecord | null>();
      for (const uid of t.parties) {
        const w = await tx.get(this.db.collection(WALLETS).doc(uid));
        wallets.set(uid, w.exists ? walletFromDoc(uid, w.data() ?? {}) : null);
      }
      const next = check(dailyFromDoc(daily.exists ? daily.data() : undefined), wallets);
      tx.create(ref, transferToDoc(t));
      tx.create(this.db.collection(WALLET_PENDING).doc(t.id), {
        uid: t.uid,
        createdAt: ts(t.createdAtMs),
        resends: 0,
        checkedAt: ts(t.createdAtMs),
        leaseUntil: ts(0),
      });
      tx.set(dailyRef, { uid: t.uid, day: t.day, ...next, updatedAt: ts(t.createdAtMs) });
      return { created: true, transfer: t, result: null };
    });
  }

  async transfer(id: string): Promise<TransferRecord | null> {
    const snap = await this.db.collection(TRANSFERS).doc(id).get();
    return snap.exists ? transferFromDoc(id, snap.data() ?? {}) : null;
  }

  async result(id: string): Promise<TransferResult | null> {
    const snap = await this.db.collection(TRANSFER_RESULTS).doc(id).get();
    return snap.exists ? resultFromDoc(id, snap.data() ?? {}) : null;
  }

  async results(ids: string[]): Promise<Map<string, TransferResult>> {
    const out = new Map<string, TransferResult>();
    if (ids.length === 0) return out;
    const snaps = await this.db.getAll(...ids.map((id) => this.db.collection(TRANSFER_RESULTS).doc(id)));
    for (const s of snaps) if (s.exists) out.set(s.id, resultFromDoc(s.id, s.data() ?? {}));
    return out;
  }

  async settle(t: TransferRecord, r: TransferResult, events: OutboxEvent[]): Promise<SettleResult> {
    const ref = this.db.collection(TRANSFER_RESULTS).doc(t.id);
    const dailyRef = this.db.collection(WALLET_DAILY).doc(dailyId(t.uid, t.day));
    return this.db.runTransaction(async (tx: Transaction) => {
      const existing = await tx.get(ref);
      if (existing.exists) return { created: false, result: resultFromDoc(t.id, existing.data() ?? {}) };
      const daily = r.status === "failed" ? await tx.get(dailyRef) : null;
      const eventSnaps = await Promise.all(events.map((e) => tx.get(this.db.collection(NOTIFICATION_EVENTS).doc(e.id))));
      tx.create(ref, resultToDoc(r));
      tx.delete(this.db.collection(WALLET_PENDING).doc(t.id));
      if (daily) {
        // A failed amount does not count against the day.
        const d = dailyFromDoc(daily.exists ? daily.data() : undefined);
        const back =
          t.kind === "topup"
            ? { topUpAmount: Math.max(0, d.topUpAmount - t.amount) }
            : { outAmount: Math.max(0, d.outAmount - t.amount), outCount: Math.max(0, d.outCount - 1) };
        tx.set(dailyRef, { uid: t.uid, day: t.day, ...d, ...back, updatedAt: ts(r.settledAtMs) });
      }
      events.forEach((e, i) => {
        if (!eventSnaps[i].exists) tx.create(this.db.collection(NOTIFICATION_EVENTS).doc(e.id), outboxDoc(e));
      });
      return { created: true, result: r };
    });
  }

  async pending(id: string): Promise<PendingRecord | null> {
    const snap = await this.db.collection(WALLET_PENDING).doc(id).get();
    return snap.exists ? pendingFromDoc(id, snap.data() ?? {}) : null;
  }

  async pendingBefore(beforeMs: number, limit: number): Promise<PendingRecord[]> {
    const snap = await this.db.collection(WALLET_PENDING).where("createdAt", "<", ts(beforeMs)).orderBy("createdAt").limit(limit).get();
    return snap.docs.map((d) => pendingFromDoc(d.id, d.data()));
  }

  async pendingOf(uid: string, limit: number): Promise<PendingRecord[]> {
    const snap = await this.db.collection(WALLET_PENDING).where("uid", "==", uid).limit(limit).get();
    return snap.docs.map((d) => pendingFromDoc(d.id, d.data()));
  }

  async touchPending(id: string, resends: number, checkedAtMs: number): Promise<void> {
    try {
      await this.db.collection(WALLET_PENDING).doc(id).update({ resends, checkedAt: ts(checkedAtMs) });
    } catch {
      // Settled meanwhile (the entry is gone).
    }
  }

  leasePending(id: string, nowMs: number, leaseMs: number): Promise<PendingRecord | null> {
    const ref = this.db.collection(WALLET_PENDING).doc(id);
    return this.db.runTransaction(async (tx: Transaction) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return null;
      const p = pendingFromDoc(id, snap.data() ?? {});
      if (p.leaseUntilMs > nowMs) return null;
      tx.update(ref, { leaseUntil: ts(nowMs + leaseMs) });
      return { ...p, leaseUntilMs: nowMs + leaseMs };
    });
  }

  private async page(query: Query, limit: number, afterId: string | null): Promise<TransferRecord[]> {
    let q = query.orderBy("createdAt", "desc");
    if (afterId) {
      const after = await this.db.collection(TRANSFERS).doc(afterId).get();
      if (after.exists) q = q.startAfter(after);
    }
    const snap = await q.limit(limit).get();
    return snap.docs.map((d) => transferFromDoc(d.id, d.data()));
  }

  history(uid: string, limit: number, afterId: string | null): Promise<TransferRecord[]> {
    return this.page(this.db.collection(TRANSFERS).where("parties", "array-contains", uid), limit, afterId);
  }

  allTransfers(uid: string | null, limit: number, afterId: string | null): Promise<TransferRecord[]> {
    const base = this.db.collection(TRANSFERS);
    return this.page(uid ? base.where("parties", "array-contains", uid) : base, limit, afterId);
  }

  async sentSince(uid: string, sinceMs: number): Promise<TransferRecord[]> {
    const snap = await this.db.collection(TRANSFERS).where("uid", "==", uid).where("createdAt", ">=", ts(sinceMs)).limit(200).get();
    return snap.docs.map((d) => transferFromDoc(d.id, d.data()));
  }

  async sentBefore(uid: string, toUid: string, beforeMs: number): Promise<boolean> {
    const snap = await this.db
      .collection(TRANSFERS)
      .where("uid", "==", uid)
      .where("toUid", "==", toUid)
      .where("createdAt", "<", ts(beforeMs))
      .limit(1)
      .get();
    return !snap.empty;
  }

  async contacts(uid: string): Promise<WalletContact[]> {
    const out: WalletContact[] = [];
    for (const carpoolId of await this.chat.carpoolIdsOf(uid)) {
      const carpool = await this.chat.carpool(carpoolId);
      if (!carpool || !carpool.active) continue;
      const members = await this.db.collection(CARPOOLS).doc(carpoolId).collection(MEMBERS).limit(50).get();
      if (!members.docs.some((m) => m.id === uid)) continue;
      const others = members.docs.filter((m) => m.id !== uid);
      const accounts = others.length ? await this.db.getAll(...others.map((m) => this.db.collection(USERS).doc(m.id))) : [];
      others.forEach((m, i) => {
        const a = accounts[i];
        out.push({
          uid: m.id,
          firstName: text(m.get("firstName")),
          verified: a?.exists === true && a.get("status") === "verified" && a.get("banned") !== true,
          carpoolId,
          carpoolNameAr: carpool.nameAr,
          carpoolNameEn: carpool.nameEn,
          isAdmin: m.get("role") === "admin",
        });
      });
    }
    return out;
  }

  takeLimit(uid: string, kind: WalletLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(WALLET_LIMITS).doc(uid);
    return this.db.runTransaction(async (tx: Transaction) => {
      const snap = await tx.get(ref);
      const raw = (snap.exists ? snap.get(kind) : undefined) as { windowStartMs?: unknown; count?: unknown } | undefined;
      const current: WindowCounter | undefined =
        raw && typeof raw.windowStartMs === "number" && typeof raw.count === "number" ? { windowStartMs: raw.windowStartMs, count: raw.count } : undefined;
      const result = takeFromWindow(current, nowMs, rule);
      if (result.allowed) tx.set(ref, { [kind]: result.next }, { merge: true });
      return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
    });
  }

  async createAlert(a: AlertRecord): Promise<boolean> {
    try {
      await this.db.collection(WALLET_ALERTS).doc(a.id).create(alertToDoc(a));
      return true;
    } catch (error) {
      if (isAlreadyExists(error)) return false;
      throw error;
    }
  }

  async alert(id: string): Promise<AlertRecord | null> {
    const snap = await this.db.collection(WALLET_ALERTS).doc(id).get();
    return snap.exists ? alertFromDoc(id, snap.data() ?? {}) : null;
  }

  async putAlert(a: AlertRecord): Promise<void> {
    await this.db.collection(WALLET_ALERTS).doc(a.id).set(alertToDoc(a));
  }

  async alerts(status: "open" | "handled", limit: number): Promise<AlertRecord[]> {
    const snap = await this.db.collection(WALLET_ALERTS).where("status", "==", status).orderBy("createdAt", "desc").limit(limit).get();
    return snap.docs.map((d) => alertFromDoc(d.id, d.data()));
  }

  async addEvents(events: OutboxEvent[]): Promise<void> {
    for (const e of events) {
      try {
        await this.db.collection(NOTIFICATION_EVENTS).doc(e.id).create(outboxDoc(e));
      } catch (error) {
        if (!isAlreadyExists(error)) throw error;
      }
    }
  }
}

// --------------------------------------------------------------------------
// The FAKE partner's test money (dev and staging)
// --------------------------------------------------------------------------

function fakeAccountFromDoc(ref: string, d: DocumentData): FakeAccount {
  return { walletRef: ref, customerRef: text(d.customerRef), balance: int(d.balance), frozen: d.frozen === true };
}

function fakeOpFromDoc(id: string, d: DocumentData): FakeOp {
  return {
    requestId: id,
    kind: KINDS.includes(d.kind) ? (d.kind as TransferKind) : "transfer",
    fromRef: text(d.fromRef) || null,
    toRef: text(d.toRef) || null,
    amount: int(d.amount),
    status: d.status === "done" ? "done" : "failed",
    reason: (FAIL_REASONS as readonly string[]).includes(d.reason) ? (d.reason as FailReason) : null,
    partnerRef: text(d.partnerRef),
    atMs: ms(d.at),
  };
}

function fakeOpToDoc(o: FakeOp): DocumentData {
  return {
    kind: o.kind,
    fromRef: o.fromRef,
    toRef: o.toRef,
    refs: [o.fromRef, o.toRef].filter((r): r is string => !!r),
    amount: o.amount,
    status: o.status,
    reason: o.reason,
    partnerRef: o.partnerRef,
    at: ts(o.atMs),
  };
}

export class FirestoreFakeLedger implements FakeLedger {
  constructor(private readonly db: Firestore) {}

  async account(walletRef: string): Promise<FakeAccount | null> {
    const snap = await this.db.collection(FAKE_ACCOUNTS).doc(walletRef).get();
    return snap.exists ? fakeAccountFromDoc(walletRef, snap.data() ?? {}) : null;
  }

  async accountOfCustomer(customerRef: string): Promise<FakeAccount | null> {
    const snap = await this.db.collection(FAKE_ACCOUNTS).where("customerRef", "==", customerRef).limit(1).get();
    const d = snap.docs[0];
    return d ? fakeAccountFromDoc(d.id, d.data()) : null;
  }

  async op(requestId: string): Promise<FakeOp | null> {
    const snap = await this.db.collection(FAKE_OPS).doc(requestId).get();
    return snap.exists ? fakeOpFromDoc(requestId, snap.data() ?? {}) : null;
  }

  async opsOf(walletRef: string, limit: number): Promise<FakeOp[]> {
    const snap = await this.db.collection(FAKE_OPS).where("refs", "array-contains", walletRef).orderBy("at", "desc").limit(limit).get();
    return snap.docs.map((d) => fakeOpFromDoc(d.id, d.data()));
  }

  apply(
    requestId: string,
    refs: string[],
    change: (accounts: Map<string, FakeAccount>, existing: FakeOp | null) => { accounts: FakeAccount[]; op: FakeOp | null },
  ): Promise<FakeOp | null> {
    return this.db.runTransaction(async (tx: Transaction) => {
      const opRef = this.db.collection(FAKE_OPS).doc(requestId);
      const opSnap = await tx.get(opRef);
      const accounts = new Map<string, FakeAccount>();
      for (const ref of new Set(refs)) {
        const s = await tx.get(this.db.collection(FAKE_ACCOUNTS).doc(ref));
        if (s.exists) accounts.set(ref, fakeAccountFromDoc(ref, s.data() ?? {}));
      }
      const existing = opSnap.exists ? fakeOpFromDoc(requestId, opSnap.data() ?? {}) : null;
      if (existing) return existing;
      const out = change(accounts, null);
      for (const a of out.accounts) {
        tx.set(this.db.collection(FAKE_ACCOUNTS).doc(a.walletRef), { customerRef: a.customerRef, balance: a.balance, frozen: a.frozen });
      }
      if (out.op) tx.create(opRef, fakeOpToDoc(out.op));
      return out.op;
    });
  }

  async putAccount(a: FakeAccount): Promise<void> {
    await this.db.collection(FAKE_ACCOUNTS).doc(a.walletRef).set({ customerRef: a.customerRef, balance: a.balance, frozen: a.frozen });
  }
}

/** config/walletFake.mode (dev and staging): ok, timeout, lost or down. */
export async function fakeMode(db: Firestore): Promise<FakeMode> {
  const snap = await db.collection(CONFIG).doc("walletFake").get();
  const mode = snap.exists ? snap.get("mode") : "ok";
  return mode === "timeout" || mode === "lost" || mode === "down" ? mode : "ok";
}

