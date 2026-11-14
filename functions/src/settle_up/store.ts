import { Timestamp, type DocumentData, type Firestore, type Transaction } from "firebase-admin/firestore";
import { AUDIT_LOG, auditDoc, REPORTS } from "../admin_panel/store";
import type { AuditEntry } from "../admin_panel/types";
import { USERS } from "../auth/accounts";
import { CARPOOLS, MEMBERS, MEMBERSHIPS } from "../carpools/store";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import type { OutboxEvent } from "../notifications/model";
import { NOTIFICATION_EVENTS, outboxDoc } from "../notifications/outbox";
import type { SettleAccount, SettleContact, SettleReport, SettleStore } from "./flow";
import {
  CURRENCY,
  SETTLE_REASONS,
  SETTLE_STATUSES,
  type SettleEvent,
  type SettleEventType,
  type SettleLimitKind,
  type SettleReason,
  type SettleRecord,
  type SettleRole,
  type SettleStatus,
} from "./model";

/**
 * Settle up records in Firestore (F45; model.ts explains each one).
 * - settleUps/{id}: read by its two parties (firestore.rules), written
 *   only here.
 * - settleUpAddresses/{uid}, settleUpLimits/{uid}, config/settleUp: Cloud
 *   Functions only.
 */

export const SETTLE_UPS = "settleUps";
export const SETTLE_ADDRESSES = "settleUpAddresses";
export const SETTLE_LIMITS = "settleUpLimits";
export const SETTLE_CONFIG = "config/settleUp";
/**
 * Chat blocks (Prompt 9): chatBlocks/{blocker}_{blocked}, written by the
 * chat functions and only READ here. DEPENDENCY: if the chat feature moves
 * or renames this collection or its IDs, blockedEitherWay below must
 * follow, or blocked parents could create requests. The unit test
 * "chat blocks: the same document ID as the chat feature" fails when the
 * chat model's ID format changes.
 */
export const CHAT_BLOCKS = "chatBlocks";

/** The chat feature's block document ID (chat/model.ts blockId). */
export function chatBlockDocId(blockerUid: string, blockedUid: string): string {
  return `${blockerUid}_${blockedUid}`;
}

/** "a|b" with the two uids in order: one value per pair, whoever pays. */
export function pairKey(a: string, b: string): string {
  return [a, b].sort().join("|");
}

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);

function ms(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

const ROLES: readonly string[] = ["payee", "payer"];
const EVENT_TYPES: readonly string[] = ["requested", "recorded", "paid", "received", "not-received", "cancelled", "declined", "reported", "account-closed"];

export function settleToDoc(r: SettleRecord): DocumentData {
  return {
    requestId: r.requestId,
    createdBy: r.createdBy,
    payeeUid: r.payeeUid,
    payerUid: r.payerUid,
    payeeFirstName: r.payeeFirstName,
    payerFirstName: r.payerFirstName,
    parties: r.parties,
    carpoolId: r.carpoolId,
    amount: r.amount,
    currency: r.currency,
    reason: r.reason,
    note: r.note,
    status: r.status,
    // The pair and "not finished" as fields, for the per-pair count in the
    // create transaction. A deleted parent reads as "deleted" here too.
    pair: pairKey(r.payeeUid, r.payerUid),
    finished: r.status === "closed" || r.status === "cancelled" || r.status === "declined",
    notReceived: r.notReceived,
    reportedBy: r.reportedBy,
    events: r.events.map((e) => ({ type: e.type, by: e.by, at: ts(e.atMs) })),
    createdAt: ts(r.createdAtMs),
    updatedAt: ts(r.updatedAtMs),
    closedAt: r.closedAtMs === null ? null : ts(r.closedAtMs),
    keptUntilMs: r.keptUntilMs,
  };
}

export function settleFromDoc(id: string, d: DocumentData): SettleRecord {
  const events: SettleEvent[] = [];
  for (const e of Array.isArray(d.events) ? (d.events as DocumentData[]) : []) {
    if (!e || !EVENT_TYPES.includes(e.type)) continue;
    events.push({ type: e.type as SettleEventType, by: ROLES.includes(e.by) ? (e.by as SettleRole) : "system", atMs: ms(e.at) });
  }
  return {
    id,
    requestId: text(d.requestId),
    createdBy: d.createdBy === "payer" ? "payer" : "payee",
    payeeUid: text(d.payeeUid),
    payerUid: text(d.payerUid),
    payeeFirstName: text(d.payeeFirstName),
    payerFirstName: text(d.payerFirstName),
    parties: Array.isArray(d.parties) ? d.parties.filter((p: unknown): p is string => typeof p === "string") : [],
    carpoolId: text(d.carpoolId),
    amount: typeof d.amount === "number" && Number.isSafeInteger(d.amount) ? d.amount : 0,
    currency: CURRENCY,
    reason: (SETTLE_REASONS as readonly string[]).includes(d.reason) ? (d.reason as SettleReason) : "other",
    note: text(d.note),
    status: (SETTLE_STATUSES as readonly string[]).includes(d.status) ? (d.status as SettleStatus) : "cancelled",
    notReceived: typeof d.notReceived === "number" ? d.notReceived : 0,
    reportedBy: Array.isArray(d.reportedBy) ? d.reportedBy.filter((p: unknown): p is SettleRole => p === "payee" || p === "payer") : [],
    events,
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
    closedAtMs: d.closedAt ? ms(d.closedAt) : null,
    keptUntilMs: typeof d.keptUntilMs === "number" ? d.keptUntilMs : null,
  };
}

/**
 * A report for the admin panel's reports queue, in the shape its report
 * screen reads (Prompt 9's reports: reason "other", a user target, no chat
 * context), so an admin can open and close it like any other report. The
 * record ID travels in the note; never an amount or an InstaPay address.
 */
export function reportDoc(report: SettleReport, nowMs: number): DocumentData {
  return {
    reporterId: report.reporterUid,
    targetType: "user",
    targetId: report.targetUid,
    subjectUid: report.targetUid,
    reason: "other",
    source: "settleUp",
    settleUpId: report.settleUpId,
    cid: "",
    kind: "private",
    note: `[settle-up ${report.settleUpId}] ${report.note}`.trim(),
    urgent: false,
    context: [],
    pausedDriving: false,
    outcome: null,
    handledBy: null,
    handledAt: null,
    status: "open",
    createdAt: ts(nowMs),
  };
}

export class FirestoreSettleStore implements SettleStore {
  constructor(
    private readonly db: Firestore,
    /** The admin panel's audit writer (one format for the whole log). */
    private readonly writeAudit?: (entry: AuditEntry) => Promise<void>,
  ) {}

  async account(uid: string): Promise<SettleAccount | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return { uid, status: text(d.status) || "unverified", banned: d.banned === true, firstName: text(d.firstName) };
  }

  async approvedMember(carpoolId: string, uid: string): Promise<boolean> {
    // carpools/{id}/members/{uid} exists only for approved members.
    return (await this.db.collection(CARPOOLS).doc(carpoolId).collection(MEMBERS).doc(uid).get()).exists;
  }

  async blockedEitherWay(a: string, b: string): Promise<boolean> {
    const [ab, ba] = await this.db.getAll(this.db.collection(CHAT_BLOCKS).doc(chatBlockDocId(a, b)), this.db.collection(CHAT_BLOCKS).doc(chatBlockDocId(b, a)));
    return ab.exists || ba.exists;
  }

  async address(uid: string): Promise<string | null> {
    const snap = await this.db.collection(SETTLE_ADDRESSES).doc(uid).get();
    return snap.exists ? text(snap.get("address")) || null : null;
  }

  async saveAddress(uid: string, address: string, nowMs: number): Promise<void> {
    await this.db.collection(SETTLE_ADDRESSES).doc(uid).set({ uid, address, updatedAt: ts(nowMs) });
  }

  async removeAddress(uid: string): Promise<void> {
    await this.db.collection(SETTLE_ADDRESSES).doc(uid).delete();
  }

  async settings(): Promise<Record<string, unknown> | null> {
    return (await this.db.doc(SETTLE_CONFIG).get()).data() ?? null;
  }

  takeLimit(uid: string, kind: SettleLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(SETTLE_LIMITS).doc(uid);
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

  async get(id: string): Promise<SettleRecord | null> {
    const snap = await this.db.collection(SETTLE_UPS).doc(id).get();
    return snap.exists ? settleFromDoc(id, snap.data() ?? {}) : null;
  }

  create(r: SettleRecord, event: OutboxEvent, maxUnfinished: number): Promise<{ record: SettleRecord; created: boolean; full: boolean }> {
    const ref = this.db.collection(SETTLE_UPS).doc(r.id);
    const unfinished = this.db
      .collection(SETTLE_UPS)
      .where("pair", "==", pairKey(r.payeeUid, r.payerUid))
      .where("finished", "==", false)
      .limit(maxUnfinished);
    return this.db.runTransaction(async (tx: Transaction) => {
      const snap = await tx.get(ref);
      if (snap.exists) return { record: settleFromDoc(r.id, snap.data() ?? {}), created: false, full: false };
      // Counted inside the transaction: a second request of the same pair
      // at the same moment conflicts and is tried again after this one.
      const open = await tx.get(unfinished);
      if (open.size >= maxUnfinished) return { record: r, created: false, full: true };
      tx.create(ref, settleToDoc(r));
      tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(event.id), outboxDoc(event));
      return { record: r, created: true, full: false };
    });
  }

  update(id: string, change: (r: SettleRecord) => { record: SettleRecord; event: OutboxEvent | null; report?: SettleReport | null }): Promise<SettleRecord | null> {
    const ref = this.db.collection(SETTLE_UPS).doc(id);
    return this.db.runTransaction(async (tx: Transaction) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return null;
      const { record, event, report } = change(settleFromDoc(id, snap.data() ?? {}));
      tx.set(ref, settleToDoc(record));
      if (event) tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(event.id), outboxDoc(event));
      if (report) tx.create(this.db.collection(REPORTS).doc(), reportDoc(report, record.updatedAtMs));
      return record;
    });
  }

  async listFor(uid: string, limit: number): Promise<SettleRecord[]> {
    const snap = await this.db.collection(SETTLE_UPS).where("parties", "array-contains", uid).orderBy("updatedAt", "desc").limit(limit).get();
    return snap.docs.map((d) => settleFromDoc(d.id, d.data()));
  }

  async contacts(uid: string): Promise<SettleContact[]> {
    const out: SettleContact[] = [];
    const mine = await this.db.collection(MEMBERSHIPS).where("uid", "==", uid).limit(50).get();
    for (const m of mine.docs) {
      if (m.get("status") !== "approved") continue;
      const carpoolId = text(m.get("carpoolId"));
      if (!carpoolId) continue;
      const carpool = await this.db.collection(CARPOOLS).doc(carpoolId).get();
      if (!carpool.exists || carpool.get("status") !== "active") continue;
      const members = await this.db.collection(CARPOOLS).doc(carpoolId).collection(MEMBERS).limit(50).get();
      if (!members.docs.some((d) => d.id === uid)) continue;
      const others = members.docs.filter((d) => d.id !== uid);
      const accounts = others.length ? await this.db.getAll(...others.map((d) => this.db.collection(USERS).doc(d.id))) : [];
      const activity = carpool.get("activity") as { name?: unknown } | null | undefined;
      const fallback = text(activity?.name);
      others.forEach((d, i) => {
        const a = accounts[i];
        out.push({
          uid: d.id,
          firstName: text(d.get("firstName")),
          verified: a?.exists === true && a.get("status") === "verified" && a.get("banned") !== true,
          carpoolId,
          carpoolNameAr: text(carpool.get("schoolNameAr")) || fallback,
          carpoolNameEn: text(carpool.get("schoolNameEn")) || fallback,
        });
      });
    }
    return out;
  }

  async audit(entry: AuditEntry): Promise<void> {
    if (this.writeAudit) return this.writeAudit(entry);
    await this.db.collection(AUDIT_LOG).doc().create(auditDoc(entry));
  }
}
