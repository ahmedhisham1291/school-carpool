import { createHash } from "node:crypto";
import { PARENT_ID_PATTERN } from "../auth/parent_id";
import { cairoOffsetMinutes } from "../schedule/cairo";

/**
 * Wallet and transfers (Prompt 11B: F43, F44, F25; spec section 6
 * "Wallet", section 9 "Wallet" and "Transfer").
 *
 * MONEY rules (CLAUDE.md, never skipped):
 * - Every wallet action runs here, in Cloud Functions, through ONE
 *   WalletProvider (provider.ts). The app never writes a balance or a
 *   transfer (firestore.rules keep every wallet record closed).
 * - Every transfer carries the app's request ID; the transfer ID is derived
 *   from it, so a retry or a double tap can never send twice.
 * - Limits per transfer and per day come from server settings
 *   (config/wallet), never from the app.
 * - Transfer records are append-only: transfers/{id} is created once
 *   (status "pending"), its outcome is a second record created once
 *   (transferResults/{id}). Nothing is ever edited or deleted.
 * - No fee and no commission: the amount sent is the amount received.
 *
 * Amounts are whole piastres (EGP minor units, 100 per pound): integers,
 * never floating point.
 */

export const CURRENCY = "EGP";
export const PIASTRES_PER_POUND = 100;

/** Version of the wallet partner's terms the parent agrees to (consent record). Draft until the partner's contract. */
export const WALLET_TERMS_VERSION = "2026-11-14";

export type TransferKind = "transfer" | "topup" | "withdraw";
export type TransferStatus = "pending" | "done" | "failed";
export type WalletStatus = "active" | "frozen";

/** Why a transfer failed (shown to the parent as one short sentence). */
export const FAIL_REASONS = [
  "insufficient-funds",
  "declined",
  "sender-frozen",
  "receiver-frozen",
  "not-received",
  "partner-error",
] as const;
export type FailReason = (typeof FAIL_REASONS)[number];

/** Server settings (config/wallet). Amounts in piastres. */
export interface WalletLimits {
  /** Smallest amount for any action. */
  minAmount: number;
  /** Largest single transfer or withdrawal. */
  perTransferMax: number;
  /** Total sent and withdrawn per Cairo day. */
  perDayMax: number;
  /** Transfers and withdrawals per Cairo day. */
  perDayCount: number;
  /** Largest single top-up. */
  topUpMax: number;
  /** Total added per Cairo day. */
  topUpPerDayMax: number;
  /** Parent ID lookups per parent per hour (spec section 7: no bulk guessing). */
  lookupsPerHour: number;
  /** Unusual pattern: transfers to this many first-time receivers within an hour. */
  alertNewReceivers: number;
  /** Unusual pattern: this many transfers within an hour. */
  alertTransfersPerHour: number;
  /** Reports per parent per day. */
  reportsPerDay: number;
}

/**
 * Defaults until the partner's contract sets its own limits (open
 * question). 2,000 EGP per transfer and 5,000 EGP a day.
 */
export const DEFAULT_WALLET_LIMITS: WalletLimits = {
  minAmount: 100,
  perTransferMax: 200_000,
  perDayMax: 500_000,
  perDayCount: 20,
  topUpMax: 500_000,
  topUpPerDayMax: 1_000_000,
  lookupsPerHour: 20,
  alertNewReceivers: 3,
  alertTransfersPerHour: 10,
  reportsPerDay: 10,
};

/** Hard ceilings: a mistyped setting can never allow more than these. */
const CEILING: Readonly<Record<keyof WalletLimits, number>> = {
  minAmount: 10_000,
  perTransferMax: 5_000_000,
  perDayMax: 10_000_000,
  perDayCount: 200,
  topUpMax: 5_000_000,
  topUpPerDayMax: 10_000_000,
  lookupsPerHour: 200,
  alertNewReceivers: 100,
  alertTransfersPerHour: 500,
  reportsPerDay: 100,
};

/** config/wallet with the defaults for anything missing, odd or above the ceiling. */
export function limitsFrom(doc: Record<string, unknown> | null | undefined): WalletLimits {
  const out: WalletLimits = { ...DEFAULT_WALLET_LIMITS };
  if (!doc) return out;
  for (const key of Object.keys(DEFAULT_WALLET_LIMITS) as (keyof WalletLimits)[]) {
    const v = doc[key];
    if (typeof v === "number" && Number.isSafeInteger(v) && v >= 1 && v <= CEILING[key]) out[key] = v;
  }
  if (out.minAmount > out.perTransferMax) out.minAmount = DEFAULT_WALLET_LIMITS.minAmount;
  return out;
}

/** One reconcile at a time per transfer: a lease on its pending entry. */
export const RECONCILE_LEASE_MS = 60_000;
/** A pending transfer is checked with the partner after this long (reconcile job and app polls). */
export const RECONCILE_AFTER_MS = 30_000;
/** The partner has no record of it: sent again (same request ID) at most this many times. */
export const MAX_RESENDS = 3;
/** Still unknown to the partner after this long: failed (no money moved). */
export const GIVE_UP_AFTER_MS = 24 * 3_600_000;
/** How long one partner call may take before the outcome counts as unknown. */
export const PARTNER_TIMEOUT_MS = 15_000;

export const NOTE_MAX = 80;
export const REPORT_NOTE_MAX = 300;

export const REPORT_REASONS = ["notReceived", "wrongAmount", "wrongPerson", "unauthorized", "other"] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

/** Freeze reason codes (admin panel). */
export const FREEZE_REASONS = ["fraudSuspected", "parentAsked", "stolenPhone", "dispute", "partnerRequest", "other"] as const;
export type FreezeReason = (typeof FREEZE_REASONS)[number];

/**
 * stuck: a transfer whose outcome the partner could not confirm and could
 * not cancel; it stays pending until an admin settles it with the partner.
 */
export type AlertKind = "new-receivers" | "many-transfers" | "report" | "stuck";

// --------------------------------------------------------------------------
// Records
// --------------------------------------------------------------------------

/** wallets/{uid}. The partner's record is the truth; balanceCopy is only a copy. */
export interface WalletRecord {
  uid: string;
  walletRef: string;
  status: WalletStatus;
  balanceCopy: number;
  balanceAtMs: number;
  termsVersion: string;
  frozenReason: FreezeReason | null;
  frozenAtMs: number | null;
  frozenBy: string | null;
  /**
   * False when our status (frozen or active) has not reached the partner
   * yet; walletReconcile applies it again until it has.
   */
  partnerSynced: boolean;
  openedAtMs: number;
  updatedAtMs: number;
}

/** transfers/{id}: created once, never changed. */
export interface TransferRecord {
  id: string;
  kind: TransferKind;
  /** The app's request ID (one per tap of Send, kept across retries). */
  requestId: string;
  /** Who started it (the sender, or the parent adding or withdrawing). */
  uid: string;
  fromUid: string | null;
  toUid: string | null;
  /** Both parents (or the one parent) for the history query. */
  parties: string[];
  fromFirstName: string;
  toFirstName: string;
  amount: number;
  currency: typeof CURRENCY;
  note: string;
  carpoolId: string | null;
  /** Cairo day it counts against (YYYY-MM-DD). */
  day: string;
  createdAtMs: number;
}

/** transferResults/{id}: the outcome, created once. */
export interface TransferResult {
  id: string;
  status: Exclude<TransferStatus, "pending">;
  reason: FailReason | null;
  partnerRef: string | null;
  settledAtMs: number;
}

/** walletPending/{id}: work list of transfers whose outcome is not known yet (server only). */
export interface PendingRecord {
  id: string;
  uid: string;
  createdAtMs: number;
  resends: number;
  checkedAtMs: number;
  /** A reconcile holds the entry until then (0: free). */
  leaseUntilMs: number;
}

/** walletDaily/{uid}_{day}: what the parent moved out and added that day (server only). */
export interface DailyCounter {
  outAmount: number;
  outCount: number;
  topUpAmount: number;
}

/** walletAlerts/{id}: for admins (unusual patterns and transfer problem reports). */
export interface AlertRecord {
  id: string;
  kind: AlertKind;
  uid: string;
  transferId: string | null;
  reason: ReportReason | null;
  note: string;
  count: number;
  status: "open" | "handled";
  outcome: string | null;
  handledBy: string | null;
  createdAtMs: number;
  handledAtMs: number | null;
}

/** The parent as the wallet sees them (users/{uid}). */
export interface WalletAccount {
  uid: string;
  status: string;
  banned: boolean;
  firstName: string;
  parentId: string;
}

export function canUseWallet(a: WalletAccount | null): a is WalletAccount {
  return !!a && !a.banned && a.status === "verified";
}

// --------------------------------------------------------------------------
// Errors
// --------------------------------------------------------------------------

export type WalletErrorReason =
  | "invalid-request"
  | "not-verified"
  | "suspended"
  | "no-wallet"
  | "wallet-exists"
  | "terms-required"
  | "frozen"
  | "receiver-not-found"
  | "receiver-cannot-receive"
  | "self"
  | "not-in-carpool"
  | "amount-too-small"
  | "over-transfer-limit"
  | "over-daily-limit"
  | "too-many-today"
  | "request-reused"
  | "not-found"
  | "rate-limited"
  | "wallet-off"
  | "wallet-unavailable";

export const WALLET_ERROR_CODES: Readonly<Record<WalletErrorReason, string>> = {
  "invalid-request": "invalid-argument",
  "not-verified": "permission-denied",
  suspended: "permission-denied",
  "no-wallet": "failed-precondition",
  "wallet-exists": "already-exists",
  "terms-required": "failed-precondition",
  frozen: "failed-precondition",
  "receiver-not-found": "not-found",
  "receiver-cannot-receive": "failed-precondition",
  self: "invalid-argument",
  "not-in-carpool": "permission-denied",
  "amount-too-small": "out-of-range",
  "over-transfer-limit": "out-of-range",
  "over-daily-limit": "out-of-range",
  "too-many-today": "resource-exhausted",
  "request-reused": "already-exists",
  "not-found": "not-found",
  "rate-limited": "resource-exhausted",
  "wallet-off": "failed-precondition",
  "wallet-unavailable": "unavailable",
};

export class WalletError extends Error {
  constructor(
    readonly reason: WalletErrorReason,
    readonly details: Record<string, number | string> = {},
  ) {
    super(reason);
    this.name = "WalletError";
  }
}

// --------------------------------------------------------------------------
// Parsing (everything from the app is checked here)
// --------------------------------------------------------------------------

export function record(data: unknown): Record<string, unknown> {
  if (typeof data !== "object" || data === null || Array.isArray(data)) throw new WalletError("invalid-request");
  return data as Record<string, unknown>;
}

/** A whole number of piastres, at least 1. Floats, strings and huge numbers are refused. */
export function amountField(v: unknown): number {
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 1 || v > 1_000_000_000) throw new WalletError("invalid-request");
  return v;
}

const REQUEST_ID = /^[A-Za-z0-9-]{16,64}$/;

/** The app's request ID (a random UUID per Send tap). */
export function requestIdField(v: unknown): string {
  if (typeof v !== "string" || !REQUEST_ID.test(v)) throw new WalletError("invalid-request");
  return v;
}

const UID = /^[A-Za-z0-9_-]{1,128}$/;

export function uidField(v: unknown): string {
  if (typeof v !== "string" || !UID.test(v)) throw new WalletError("invalid-request");
  return v;
}

export function optionalUid(v: unknown): string | null {
  return v === undefined || v === null || v === "" ? null : uidField(v);
}

const TRANSFER_ID = /^t_[a-f0-9]{40}$/;

export function transferIdField(v: unknown): string {
  if (typeof v !== "string" || !TRANSFER_ID.test(v)) throw new WalletError("invalid-request");
  return v;
}

/** Upper case, spaces and dashes removed; null when it cannot be a parent ID. */
export function normalizeParentId(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const id = v.replace(/[\s-]/g, "").toUpperCase();
  return PARENT_ID_PATTERN.test(id) ? id : null;
}

/** One line, trimmed, at most [max] characters; control and bidi characters removed. */
export function cleanNote(v: unknown, max = NOTE_MAX): string {
  if (v === undefined || v === null) return "";
  if (typeof v !== "string") throw new WalletError("invalid-request");
  const cleaned = v
    .replace(/[\u0000-\u001f\u007f‎‏‪-‮⁦-⁩]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return [...cleaned].slice(0, max).join("");
}

export function isReportReason(v: unknown): v is ReportReason {
  return typeof v === "string" && (REPORT_REASONS as readonly string[]).includes(v);
}

export function isFreezeReason(v: unknown): v is FreezeReason {
  return typeof v === "string" && (FREEZE_REASONS as readonly string[]).includes(v);
}

// --------------------------------------------------------------------------
// IDs and days
// --------------------------------------------------------------------------

/**
 * The transfer ID: the same parent and request ID always give the same ID,
 * so a retry finds the first attempt. It is also the request ID sent to the
 * partner (the partner's idempotency key).
 */
export function transferId(uid: string, requestId: string): string {
  return "t_" + createHash("sha256").update(`${uid}:${requestId}`).digest("hex").slice(0, 40);
}

/** Cairo calendar day of [ms] (the daily limits follow the parents' day). */
export function cairoDay(ms: number): string {
  const local = new Date(ms + cairoOffsetMinutes(ms) * 60_000);
  return local.toISOString().slice(0, 10);
}

export function dailyId(uid: string, day: string): string {
  return `${uid}_${day}`;
}

/** "12.50": for logs and tests only (the app formats amounts itself). */
export function formatPiastres(amount: number): string {
  const pounds = Math.trunc(amount / PIASTRES_PER_POUND);
  const rest = Math.abs(amount % PIASTRES_PER_POUND);
  return `${pounds}.${rest.toString().padStart(2, "0")}`;
}

// --------------------------------------------------------------------------
// Views returned to the app (no uids of other parents, no partner data)
// --------------------------------------------------------------------------

export interface TransferView {
  id: string;
  kind: TransferKind;
  /** "out" when the caller sent or withdrew, "in" when they received or added. */
  direction: "in" | "out";
  /** The other parent's first name ("" for top-ups and withdrawals). */
  otherName: string;
  amount: number;
  currency: typeof CURRENCY;
  note: string;
  carpoolId: string | null;
  status: TransferStatus;
  reason: FailReason | null;
  createdAtMs: number;
  settledAtMs: number | null;
}

export function transferView(t: TransferRecord, r: TransferResult | null, viewerUid: string): TransferView {
  const out = t.kind === "withdraw" || (t.kind === "transfer" && t.fromUid === viewerUid);
  return {
    id: t.id,
    kind: t.kind,
    direction: out ? "out" : "in",
    otherName: t.kind !== "transfer" ? "" : out ? t.toFirstName : t.fromFirstName,
    amount: t.amount,
    currency: t.currency,
    // The note is the sender's words to the receiver: both see it.
    note: t.note,
    carpoolId: t.carpoolId,
    status: r?.status ?? "pending",
    reason: r?.reason ?? null,
    createdAtMs: t.createdAtMs,
    settledAtMs: r?.settledAtMs ?? null,
  };
}
