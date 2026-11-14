import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";
import type { OutboxEvent } from "../../src/notifications/model";
import {
  dailyId,
  DEFAULT_WALLET_LIMITS,
  type AlertRecord,
  type DailyCounter,
  type PendingRecord,
  type TransferRecord,
  type TransferResult,
  type WalletAccount,
  type WalletLimits,
  type WalletRecord,
} from "../../src/wallet/model";
import type { FakeAccount, FakeLedger, FakeOp } from "../../src/wallet/provider";
import type { ConsentRecord, SettleResult, StartResult, WalletContact, WalletLimitKind, WalletStore } from "../../src/wallet/store";

const clone = <T>(v: T): T => structuredClone(v);

/** In-memory WalletStore for unit tests (fake data only). */
export class MemoryWalletStore implements WalletStore {
  accounts = new Map<string, WalletAccount>();
  parentIds = new Map<string, string>();
  wallets = new Map<string, WalletRecord>();
  consents: Array<ConsentRecord & { uid: string }> = [];
  config: WalletLimits = { ...DEFAULT_WALLET_LIMITS };
  transfers = new Map<string, TransferRecord>();
  results_ = new Map<string, TransferResult>();
  pendingMap = new Map<string, PendingRecord>();
  daily = new Map<string, DailyCounter>();
  counters = new Map<string, WindowCounter>();
  alertsMap = new Map<string, AlertRecord>();
  events = new Map<string, OutboxEvent>();
  contactList: Array<WalletContact & { of: string }> = [];
  adminNotes: string[] = [];
  /** Writes by kind, to prove the records are never changed. */
  writes: string[] = [];
  /** Runs inside startTransfer before the wallets are read (race tests). */
  beforeStart: (() => void) | null = null;

  addParent(uid: string, parentId: string, extra: Partial<WalletAccount> = {}): WalletAccount {
    const a: WalletAccount = { uid, status: "verified", banned: false, firstName: `Name-${uid}`, parentId, ...extra };
    this.accounts.set(uid, a);
    this.parentIds.set(parentId, uid);
    return a;
  }

  /** a and b in carpool [carpoolId] (both directions). */
  link(a: string, b: string, carpoolId: string, adminUid: string | null = null): void {
    for (const [of, other] of [
      [a, b],
      [b, a],
    ]) {
      this.contactList.push({
        of,
        uid: other,
        firstName: this.accounts.get(other)?.firstName ?? other,
        verified: true,
        carpoolId,
        carpoolNameAr: `مشوار ${carpoolId}`,
        carpoolNameEn: `Carpool ${carpoolId}`,
        isAdmin: other === adminUid,
      });
    }
  }

  async account(uid: string) {
    return clone(this.accounts.get(uid) ?? null);
  }
  async uidOfParentId(parentId: string) {
    return this.parentIds.get(parentId) ?? null;
  }
  async wallet(uid: string) {
    return clone(this.wallets.get(uid) ?? null);
  }
  async createWallet(w: WalletRecord, consent: ConsentRecord) {
    if (this.wallets.has(w.uid)) return false;
    this.wallets.set(w.uid, clone(w));
    this.consents.push({ ...consent, uid: w.uid });
    return true;
  }
  async updateWallet(uid: string, change: Partial<WalletRecord>, note?: string) {
    const w = this.wallets.get(uid);
    if (!w) throw new Error("no wallet");
    this.wallets.set(uid, { ...w, ...clone(change) });
    if (note !== undefined) this.adminNotes.push(note);
    this.writes.push(`wallet:${uid}`);
  }
  async limits() {
    return clone(this.config);
  }
  async startTransfer(t: TransferRecord, check: (d: DailyCounter, wallets: Map<string, WalletRecord | null>) => DailyCounter): Promise<StartResult> {
    const existing = this.transfers.get(t.id);
    if (existing) return { created: false, transfer: clone(existing), result: clone(this.results_.get(t.id) ?? null) };
    const key = dailyId(t.uid, t.day);
    const wallets = new Map<string, WalletRecord | null>(t.parties.map((u) => [u, clone(this.wallets.get(u) ?? null)]));
    // Tests can freeze a wallet "between" the checks and the transaction.
    this.beforeStart?.();
    for (const u of t.parties) wallets.set(u, clone(this.wallets.get(u) ?? null));
    const next = check(clone(this.daily.get(key) ?? { outAmount: 0, outCount: 0, topUpAmount: 0 }), wallets);
    this.transfers.set(t.id, clone(t));
    this.pendingMap.set(t.id, { id: t.id, uid: t.uid, createdAtMs: t.createdAtMs, resends: 0, checkedAtMs: t.createdAtMs, leaseUntilMs: 0 });
    this.daily.set(key, next);
    this.writes.push(`transfer:create:${t.id}`);
    return { created: true, transfer: clone(t), result: null };
  }
  async transfer(id: string) {
    return clone(this.transfers.get(id) ?? null);
  }
  async result(id: string) {
    return clone(this.results_.get(id) ?? null);
  }
  async results(ids: string[]) {
    const m = new Map<string, TransferResult>();
    for (const id of ids) {
      const r = this.results_.get(id);
      if (r) m.set(id, clone(r));
    }
    return m;
  }
  async settle(t: TransferRecord, r: TransferResult, events: OutboxEvent[]): Promise<SettleResult> {
    const existing = this.results_.get(t.id);
    if (existing) return { created: false, result: clone(existing) };
    this.results_.set(t.id, clone(r));
    this.writes.push(`result:create:${t.id}`);
    this.pendingMap.delete(t.id);
    if (r.status === "failed") {
      const key = dailyId(t.uid, t.day);
      const d = this.daily.get(key) ?? { outAmount: 0, outCount: 0, topUpAmount: 0 };
      this.daily.set(
        key,
        t.kind === "topup"
          ? { ...d, topUpAmount: Math.max(0, d.topUpAmount - t.amount) }
          : { ...d, outAmount: Math.max(0, d.outAmount - t.amount), outCount: Math.max(0, d.outCount - 1) },
      );
    }
    for (const e of events) if (!this.events.has(e.id)) this.events.set(e.id, clone(e));
    return { created: true, result: clone(r) };
  }
  async pending(id: string) {
    return clone(this.pendingMap.get(id) ?? null);
  }
  async pendingBefore(beforeMs: number, limit: number) {
    return [...this.pendingMap.values()]
      .filter((p) => p.createdAtMs < beforeMs)
      .sort((a, b) => a.createdAtMs - b.createdAtMs)
      .slice(0, limit)
      .map(clone);
  }
  async pendingOf(uid: string, limit: number) {
    return [...this.pendingMap.values()].filter((p) => p.uid === uid).slice(0, limit).map(clone);
  }
  async touchPending(id: string, resends: number, checkedAtMs: number) {
    const p = this.pendingMap.get(id);
    if (p) this.pendingMap.set(id, { ...p, resends, checkedAtMs });
  }
  async leasePending(id: string, nowMs: number, leaseMs: number) {
    const p = this.pendingMap.get(id);
    if (!p || p.leaseUntilMs > nowMs) return null;
    const leased = { ...p, leaseUntilMs: nowMs + leaseMs };
    this.pendingMap.set(id, leased);
    return clone(leased);
  }
  async walletsToSync(limit: number) {
    return [...this.wallets.values()].filter((w) => !w.partnerSynced).slice(0, limit).map(clone);
  }
  private sorted(filter: (t: TransferRecord) => boolean, limit: number, afterId: string | null) {
    const all = [...this.transfers.values()].filter(filter).sort((a, b) => b.createdAtMs - a.createdAtMs || (a.id < b.id ? 1 : -1));
    const start = afterId ? all.findIndex((t) => t.id === afterId) + 1 : 0;
    return all.slice(start, start + limit).map(clone);
  }
  async history(uid: string, limit: number, afterId: string | null) {
    return this.sorted((t) => t.parties.includes(uid), limit, afterId);
  }
  async allTransfers(uid: string | null, limit: number, afterId: string | null) {
    return this.sorted((t) => uid === null || t.parties.includes(uid), limit, afterId);
  }
  async sentSince(uid: string, sinceMs: number) {
    return [...this.transfers.values()].filter((t) => t.uid === uid && t.createdAtMs >= sinceMs).map(clone);
  }
  async sentBefore(uid: string, toUid: string, beforeMs: number) {
    return [...this.transfers.values()].some((t) => t.uid === uid && t.toUid === toUid && t.createdAtMs < beforeMs);
  }
  async contacts(uid: string) {
    return this.contactList.filter((c) => c.of === uid).map(({ of: _of, ...c }) => clone(c));
  }
  async takeLimit(uid: string, kind: WalletLimitKind, nowMs: number, rule: { windowMs: number; max: number }) {
    const key = `${uid}:${kind}`;
    const r = takeFromWindow(this.counters.get(key), nowMs, rule);
    if (r.allowed) this.counters.set(key, r.next);
    return { allowed: r.allowed, retryAfterMs: r.retryAfterMs };
  }
  async createAlert(a: AlertRecord) {
    if (this.alertsMap.has(a.id)) return false;
    this.alertsMap.set(a.id, clone(a));
    return true;
  }
  async alert(id: string) {
    return clone(this.alertsMap.get(id) ?? null);
  }
  async putAlert(a: AlertRecord) {
    this.alertsMap.set(a.id, clone(a));
  }
  async alerts(status: "open" | "handled", limit: number) {
    return [...this.alertsMap.values()].filter((a) => a.status === status).slice(0, limit).map(clone);
  }
  async addEvents(events: OutboxEvent[]) {
    for (const e of events) if (!this.events.has(e.id)) this.events.set(e.id, clone(e));
  }
}

/** The fake partner's ledger in memory. */
export class MemoryLedger implements FakeLedger {
  accounts = new Map<string, FakeAccount>();
  ops = new Map<string, FakeOp>();

  async account(ref: string) {
    return clone(this.accounts.get(ref) ?? null);
  }
  async accountOfCustomer(customerRef: string) {
    return clone([...this.accounts.values()].find((a) => a.customerRef === customerRef) ?? null);
  }
  async op(requestId: string) {
    return clone(this.ops.get(requestId) ?? null);
  }
  async opsOf(ref: string, limit: number) {
    return [...this.ops.values()].filter((o) => o.fromRef === ref || o.toRef === ref).slice(0, limit).map(clone);
  }
  async apply(
    requestId: string,
    refs: string[],
    change: (accounts: Map<string, FakeAccount>, existing: FakeOp | null) => { accounts: FakeAccount[]; op: FakeOp | null },
  ) {
    const existing = this.ops.get(requestId) ?? null;
    if (existing) return clone(existing);
    const m = new Map<string, FakeAccount>();
    for (const r of refs) {
      const a = this.accounts.get(r);
      if (a) m.set(r, clone(a));
    }
    const out = change(m, null);
    for (const a of out.accounts) this.accounts.set(a.walletRef, clone(a));
    if (out.op) this.ops.set(requestId, clone(out.op));
    return clone(out.op);
  }
  async putAccount(a: FakeAccount) {
    this.accounts.set(a.walletRef, clone(a));
  }
}
