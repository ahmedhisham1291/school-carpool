import type { OutboxEvent } from "../notifications/model";
import type { AlertRecord, DailyCounter, PendingRecord, TransferRecord, TransferResult, WalletAccount, WalletLimits, WalletRecord } from "./model";

/**
 * What the wallet reads and writes in Firestore (FirestoreWalletStore in
 * firestore_store.ts; an in-memory one in the tests). Every collection here
 * is closed to the app (firestore.rules): the app sees its wallet only
 * through the wallet functions.
 */

export interface WalletContact {
  uid: string;
  firstName: string;
  verified: boolean;
  carpoolId: string;
  carpoolNameAr: string;
  carpoolNameEn: string;
  /** The carpool's admin (who set the contribution). */
  isAdmin: boolean;
}

export interface ConsentRecord {
  type: "walletTerms";
  version: string;
  acceptedAtMs: number;
}

export type WalletLimitKind = "lookups" | "reports";

export interface StartResult {
  created: boolean;
  /** The transfer as stored (the earlier one when [created] is false). */
  transfer: TransferRecord;
  result: TransferResult | null;
}

export interface SettleResult {
  /** False when an earlier settlement won (the stored one is returned). */
  created: boolean;
  result: TransferResult;
}

export interface WalletStore {
  account(uid: string): Promise<WalletAccount | null>;
  /** The owner of a parent ID (parentIds/{id}), or null. */
  uidOfParentId(parentId: string): Promise<string | null>;

  wallet(uid: string): Promise<WalletRecord | null>;
  /** Creates wallets/{uid} and the consent record together; false when the wallet already exists. */
  createWallet(w: WalletRecord, consent: ConsentRecord): Promise<boolean>;
  /** Balance copy, freeze state (never a transfer). */
  updateWallet(
    uid: string,
    change: Partial<Pick<WalletRecord, "balanceCopy" | "balanceAtMs" | "status" | "frozenReason" | "frozenAtMs" | "frozenBy" | "partnerSynced" | "updatedAtMs">>,
    note?: string,
  ): Promise<void>;
  /** Wallets whose status has not reached the partner yet (partnerSynced false). */
  walletsToSync(limit: number): Promise<WalletRecord[]>;

  limits(): Promise<WalletLimits>;

  /**
   * In one transaction: when transfers/{t.id} exists, returns it unchanged
   * (a retry). Otherwise reads the day's counter and the wallets of
   * t.parties, lets [check] refuse (it throws; a wallet frozen a moment ago
   * is seen here), then creates the transfer, its pending entry and the
   * new counter.
   */
  startTransfer(t: TransferRecord, check: (daily: DailyCounter, wallets: Map<string, WalletRecord | null>) => DailyCounter): Promise<StartResult>;
  transfer(id: string): Promise<TransferRecord | null>;
  result(id: string): Promise<TransferResult | null>;
  results(ids: string[]): Promise<Map<string, TransferResult>>;

  /**
   * In one transaction: when transferResults/{id} exists, returns it (an
   * outcome is never written twice). Otherwise creates [r], removes the
   * pending entry, gives a failed outgoing amount back to the day's
   * counter, and creates [events] (each once).
   */
  settle(t: TransferRecord, r: TransferResult, events: OutboxEvent[]): Promise<SettleResult>;

  pending(id: string): Promise<PendingRecord | null>;
  /** Pending entries created before [beforeMs], oldest first. */
  pendingBefore(beforeMs: number, limit: number): Promise<PendingRecord[]>;
  /** Pending entries of one parent. */
  pendingOf(uid: string, limit: number): Promise<PendingRecord[]>;
  touchPending(id: string, resends: number, checkedAtMs: number): Promise<void>;
  /**
   * In one transaction: the pending entry, leased until nowMs + leaseMs, or
   * null when it is gone or another reconcile holds the lease (so two
   * reconciles never send the same transfer at the same time).
   */
  leasePending(id: string, nowMs: number, leaseMs: number): Promise<PendingRecord | null>;

  /** The parent's transfers, newest first (parties contains uid). */
  history(uid: string, limit: number, afterId: string | null): Promise<TransferRecord[]>;
  /** Every transfer, newest first (admin log); only [uid]'s when given. */
  allTransfers(uid: string | null, limit: number, afterId: string | null): Promise<TransferRecord[]>;
  /** Transfers [uid] sent since [sinceMs]. */
  sentSince(uid: string, sinceMs: number): Promise<TransferRecord[]>;
  /** Whether [uid] started a transfer to [toUid] before [beforeMs]. */
  sentBefore(uid: string, toUid: string, beforeMs: number): Promise<boolean>;

  /** Approved members of the parent's approved carpools (others only). */
  contacts(uid: string): Promise<WalletContact[]>;

  takeLimit(uid: string, kind: WalletLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;

  /** Creates the alert unless one with its ID exists; returns whether it was new. */
  createAlert(a: AlertRecord): Promise<boolean>;
  alert(id: string): Promise<AlertRecord | null>;
  putAlert(a: AlertRecord): Promise<void>;
  alerts(status: "open" | "handled", limit: number): Promise<AlertRecord[]>;

  /** Creates each event unless it exists (fixed IDs). */
  addEvents(events: OutboxEvent[]): Promise<void>;
}
