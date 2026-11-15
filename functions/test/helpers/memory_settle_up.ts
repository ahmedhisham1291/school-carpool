import type { AuditEntry } from "../../src/admin_panel/types";
import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";
import type { OutboxEvent } from "../../src/notifications/model";
import type { SettleAccount, SettleContact, SettleReport, SettleStore } from "../../src/settle_up/flow";
import { isFinal, type SettleLimitKind, type SettleRecord } from "../../src/settle_up/model";

const clone = <T>(v: T): T => structuredClone(v);

/** In-memory stand-in for settle_up/store.ts (unit tests). Fake data only. */
export class MemorySettleStore implements SettleStore {
  readonly accounts = new Map<string, SettleAccount>();
  /** carpoolId -> approved member uids */
  readonly members = new Map<string, Set<string>>();
  readonly carpoolNames = new Map<string, { ar: string; en: string }>();
  /** "blocker_blocked" */
  readonly blocks = new Set<string>();
  readonly addresses = new Map<string, string>();
  readonly records = new Map<string, SettleRecord>();
  readonly events: OutboxEvent[] = [];
  readonly reports: Array<SettleReport & { atMs: number }> = [];
  readonly audits: AuditEntry[] = [];
  readonly limits = new Map<string, WindowCounter>();
  config: Record<string, unknown> | null = null;
  /** Reads of another parent's address through the store (privacy tests). */
  readonly addressReads: string[] = [];

  addParent(uid: string, firstName: string, extra: Partial<SettleAccount> = {}): void {
    this.accounts.set(uid, { uid, status: "verified", banned: false, firstName, ...extra });
  }

  addCarpool(id: string, uids: string[], names = { ar: "مدرسة النيل", en: "Nile School" }): void {
    this.members.set(id, new Set(uids));
    this.carpoolNames.set(id, names);
  }

  async account(uid: string): Promise<SettleAccount | null> {
    return clone(this.accounts.get(uid) ?? null);
  }

  async approvedMember(carpoolId: string, uid: string): Promise<boolean> {
    return this.members.get(carpoolId)?.has(uid) ?? false;
  }

  async blockedEitherWay(a: string, b: string): Promise<boolean> {
    return this.blocks.has(`${a}_${b}`) || this.blocks.has(`${b}_${a}`);
  }

  async address(uid: string): Promise<string | null> {
    this.addressReads.push(uid);
    return this.addresses.get(uid) ?? null;
  }

  async saveAddress(uid: string, address: string): Promise<void> {
    this.addresses.set(uid, address);
  }

  async removeAddress(uid: string): Promise<void> {
    this.addresses.delete(uid);
  }

  async settings(): Promise<Record<string, unknown> | null> {
    return this.config;
  }

  async takeLimit(uid: string, kind: SettleLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const key = `${uid}/${kind}`;
    const result = takeFromWindow(this.limits.get(key), nowMs, rule);
    if (result.allowed) this.limits.set(key, result.next);
    return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
  }

  async get(id: string): Promise<SettleRecord | null> {
    return clone(this.records.get(id) ?? null);
  }

  /** The next write (create or update) fails once with this (a lost transaction). */
  failNextWrite: Error | null = null;

  private maybeFailWrite(): void {
    const e = this.failNextWrite;
    if (e) {
      this.failNextWrite = null;
      throw e;
    }
  }

  async create(r: SettleRecord, event: OutboxEvent, maxUnfinished: number): Promise<{ record: SettleRecord; created: boolean; full: boolean }> {
    const existing = this.records.get(r.id);
    if (existing) return { record: clone(existing), created: false, full: false };
    const unfinished = [...this.records.values()].filter((x) => !isFinal(x.status) && x.parties.includes(r.payeeUid) && x.parties.includes(r.payerUid)).length;
    if (unfinished >= maxUnfinished) return { record: clone(r), created: false, full: true };
    this.maybeFailWrite();
    this.records.set(r.id, clone(r));
    this.events.push(clone(event));
    return { record: clone(r), created: true, full: false };
  }

  async update(id: string, change: (r: SettleRecord) => { record: SettleRecord; event: OutboxEvent | null; report?: SettleReport | null }): Promise<SettleRecord | null> {
    const existing = this.records.get(id);
    if (!existing) return null;
    // Like a transaction: nothing is written when [change] throws or the write fails.
    const { record, event, report } = change(clone(existing));
    this.maybeFailWrite();
    this.records.set(id, clone(record));
    if (event && !this.events.some((e) => e.id === event.id)) this.events.push(clone(event));
    if (report) this.reports.push({ ...report, atMs: record.updatedAtMs });
    return clone(record);
  }

  async listFor(uid: string, limit: number): Promise<SettleRecord[]> {
    return clone(
      [...this.records.values()]
        .filter((r) => r.parties.includes(uid))
        .sort((x, y) => y.updatedAtMs - x.updatedAtMs)
        .slice(0, limit),
    );
  }

  async contacts(uid: string): Promise<SettleContact[]> {
    const out: SettleContact[] = [];
    for (const [carpoolId, uids] of this.members) {
      if (!uids.has(uid)) continue;
      const names = this.carpoolNames.get(carpoolId) ?? { ar: "", en: "" };
      for (const other of uids) {
        if (other === uid) continue;
        const a = this.accounts.get(other);
        out.push({ uid: other, firstName: a?.firstName ?? "", verified: !!a && a.status === "verified" && !a.banned, carpoolId, carpoolNameAr: names.ar, carpoolNameEn: names.en });
      }
    }
    return out;
  }

  async audit(entry: AuditEntry): Promise<void> {
    this.audits.push(entry);
  }
}
