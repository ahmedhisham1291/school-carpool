import { createHash } from "node:crypto";

/**
 * "Settle up" by InstaPay (F45, owner decision 14 Nov 2026, docs/DECISIONS.md
 * "Improvements, revised" item 8): the pilot's payment feature.
 *
 * PRINCIPLE (never break): the app never moves, holds or sees money and
 * never asks for bank or card details. It only RECORDS payment requests
 * between two parents of one carpool (requested, paid, received) and shows
 * the payer the payee's InstaPay address so they can pay in the InstaPay
 * app themselves. No fee, no commission.
 *
 * Records:
 * - settleUpAddresses/{uid}: the parent's InstaPay address (IPA). Cloud
 *   Functions only; never logged, never sent to Sentry, Algolia or
 *   analytics; shown only to its owner and, through getSettleUpAddress, to
 *   the payer of an OPEN request from that payee.
 * - settleUps/{id}: one payment record between a payee and a payer. Only
 *   Cloud Functions write it; its two parties read it. The history is
 *   append-only: every change adds one entry to `events`, nothing is edited
 *   away and the app never deletes a record.
 * - settleUpLimits/{uid}: rate-limit counters.
 * - config/settleUp: the largest amount of one record (server setting).
 *
 * Amounts are whole piastres (EGP minor units), integers only.
 * Pure; unit-tested (test/settle_up.test.ts).
 */

export const CURRENCY = "EGP";
export const PIASTRES_PER_POUND = 100;

// --------------------------------------------------------------------------
// Errors
// --------------------------------------------------------------------------

export type SettleErrorReason =
  | "invalid-request"
  | "invalid-address"
  | "invalid-amount"
  | "amount-too-high"
  | "no-account"
  | "not-verified"
  | "suspended"
  | "self"
  | "not-allowed"
  | "no-address"
  | "not-found"
  | "invalid-state"
  | "request-reused"
  | "too-many-open"
  | "report-too-early"
  | "already-reported"
  | "rate-limited";

export class SettleError extends Error {
  constructor(
    readonly reason: SettleErrorReason,
    readonly details: Record<string, unknown> = {},
  ) {
    super(reason);
    this.name = "SettleError";
  }
}

export const SETTLE_ERROR_CODES: Record<SettleErrorReason, string> = {
  "invalid-request": "invalid-argument",
  "invalid-address": "invalid-argument",
  "invalid-amount": "invalid-argument",
  "amount-too-high": "failed-precondition",
  "no-account": "failed-precondition",
  "not-verified": "permission-denied",
  suspended: "permission-denied",
  self: "invalid-argument",
  "not-allowed": "permission-denied",
  "no-address": "failed-precondition",
  "not-found": "not-found",
  "invalid-state": "failed-precondition",
  "request-reused": "already-exists",
  "too-many-open": "resource-exhausted",
  "report-too-early": "failed-precondition",
  "already-reported": "already-exists",
  "rate-limited": "resource-exhausted",
};

// --------------------------------------------------------------------------
// InstaPay address (IPA)
// --------------------------------------------------------------------------

/**
 * The Instant Payment Address is "presented in the form of name@instapay"
 * (InstaPay FAQs published by member banks of the Instant Payment Network,
 * for example Bank ABC Egypt and ABK Egypt; sources in
 * docs/progress/improve-a.md). The network publishes no character rules
 * for the name, so we accept what InstaPay handles are seen to use:
 * Latin letters, digits, dot, hyphen and underscore, starting with a
 * letter or digit, 3 to 50 characters, then "@instapay". Stored in lower
 * case (InstaPay addresses are not case-sensitive in the app).
 *
 * This checks the SHAPE only: the app cannot know whether the address
 * exists. The InstaPay app shows the receiver's name before the payer
 * confirms, which is the real check.
 */
export const IPA_SUFFIX = "@instapay";
const IPA = /^[a-z0-9][a-z0-9._-]{2,49}@instapay$/;

/** The address in its stored form, or null when it is not an InstaPay address. */
export function normalizeIpa(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim().toLowerCase();
  return IPA.test(v) ? v : null;
}

export function ipaField(value: unknown): string {
  const v = normalizeIpa(value);
  if (!v) throw new SettleError("invalid-address");
  return v;
}

/** "ad…@instapay": for the owner's own screens only (never logged). */
export function maskIpa(address: string): string {
  const at = address.lastIndexOf("@");
  if (at <= 0) return "";
  return `${address.slice(0, Math.min(2, at))}…${address.slice(at)}`;
}

// --------------------------------------------------------------------------
// Settings and limits
// --------------------------------------------------------------------------

export interface SettleSettings {
  /** Largest amount of one record, in piastres. */
  maxAmount: number;
}

/** EGP 5,000 (owner default). */
export const DEFAULT_SETTLE_SETTINGS: SettleSettings = { maxAmount: 5_000 * PIASTRES_PER_POUND };
/** A stored value above this is ignored (a typo cannot open huge amounts). */
export const MAX_AMOUNT_CEILING = 100_000 * PIASTRES_PER_POUND;
export const MIN_AMOUNT = 1 * PIASTRES_PER_POUND;

/** config/settleUp with the default for anything missing or odd. */
export function settingsFrom(doc: Record<string, unknown> | null | undefined): SettleSettings {
  const v = doc?.maxAmount;
  if (typeof v === "number" && Number.isSafeInteger(v) && v >= MIN_AMOUNT && v <= MAX_AMOUNT_CEILING) return { maxAmount: v };
  return { ...DEFAULT_SETTLE_SETTINGS };
}

/** Rate limits per parent (params in config.ts) and the report threshold. */
export interface SettleLimits {
  requestsPerDay: number;
  changesPerDay: number;
  addressChangesPerDay: number;
  addressViewsPerHour: number;
  /** "Not received" marks after which either side may report the record. */
  reportAfter: number;
}

export const DEFAULT_SETTLE_LIMITS: SettleLimits = { requestsPerDay: 20, changesPerDay: 100, addressChangesPerDay: 5, addressViewsPerHour: 30, reportAfter: 2 };

export type SettleLimitKind = "requests" | "changes" | "addressChanges" | "addressViews";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

export function limitRule(limits: SettleLimits, kind: SettleLimitKind): { windowMs: number; max: number } {
  switch (kind) {
    case "requests":
      return { windowMs: DAY, max: limits.requestsPerDay };
    case "changes":
      return { windowMs: DAY, max: limits.changesPerDay };
    case "addressChanges":
      return { windowMs: DAY, max: limits.addressChangesPerDay };
    case "addressViews":
      return { windowMs: HOUR, max: limits.addressViewsPerHour };
  }
}

/** Records not yet finished between one pair, so nobody floods another parent. */
export const MAX_OPEN_PER_PAIR = 10;
/** A record that bounces forever stops here ("report it" is the way on). */
export const MAX_EVENTS = 40;

// --------------------------------------------------------------------------
// Records
// --------------------------------------------------------------------------

export const SETTLE_STATUSES = ["open", "paid", "closed", "cancelled", "declined"] as const;
export type SettleStatus = (typeof SETTLE_STATUSES)[number];

export const SETTLE_REASONS = ["contribution", "fuel", "other"] as const;
export type SettleReason = (typeof SETTLE_REASONS)[number];

export type SettleRole = "payee" | "payer";

export const SETTLE_ACTIONS = ["paid", "received", "notReceived", "cancel", "decline"] as const;
export type SettleAction = (typeof SETTLE_ACTIONS)[number];

export type SettleEventType = "requested" | "recorded" | "paid" | "received" | "not-received" | "cancelled" | "declined" | "reported" | "account-closed";

/** One entry of the append-only history. Roles, not uids: nothing to anonymise. */
export interface SettleEvent {
  type: SettleEventType;
  by: SettleRole | "system";
  atMs: number;
}

/** The marker that replaces a deleted parent's uid (privacy/anonymise.ts). */
export const DELETED_ID = "deleted";

export interface SettleRecord {
  id: string;
  requestId: string;
  /** Who created it: the payee asked ("request") or the payer recorded a payment first. */
  createdBy: SettleRole;
  payeeUid: string;
  payerUid: string;
  payeeFirstName: string;
  payerFirstName: string;
  /** The uids that may read it (a deleted parent is taken out). */
  parties: string[];
  carpoolId: string;
  amount: number;
  currency: typeof CURRENCY;
  reason: SettleReason;
  note: string;
  status: SettleStatus;
  /** "Not received" marks so far. */
  notReceived: number;
  reportedBy: SettleRole[];
  events: SettleEvent[];
  createdAtMs: number;
  updatedAtMs: number;
  closedAtMs: number | null;
  /** Retention: a closed parent's year (closure + 1 year); see planRetention. */
  keptUntilMs: number | null;
}

export function isFinal(status: SettleStatus): boolean {
  return status === "closed" || status === "cancelled" || status === "declined";
}

/** One record per creator and request ID: a retried create finds the first one. */
export function settleId(creatorUid: string, requestId: string): string {
  return "s_" + createHash("sha256").update(`${creatorUid}:${requestId}`).digest("hex").slice(0, 40);
}

export function roleOf(record: SettleRecord, uid: string): SettleRole | null {
  if (uid === DELETED_ID) return null;
  if (record.payeeUid === uid) return "payee";
  if (record.payerUid === uid) return "payer";
  return null;
}

// --------------------------------------------------------------------------
// Input parsing
// --------------------------------------------------------------------------

export function record(data: unknown): Record<string, unknown> {
  if (typeof data !== "object" || data === null || Array.isArray(data)) throw new SettleError("invalid-request");
  return data as Record<string, unknown>;
}

const DOC_ID = /^[A-Za-z0-9_-]{1,128}$/;
export function docId(v: unknown): string {
  if (typeof v !== "string" || !DOC_ID.test(v)) throw new SettleError("invalid-request");
  return v;
}

const REQUEST_ID = /^[A-Za-z0-9-]{16,64}$/;
export function requestIdField(v: unknown): string {
  if (typeof v !== "string" || !REQUEST_ID.test(v)) throw new SettleError("invalid-request");
  return v;
}

export const NOTE_MAX = 80;

/** C0 controls, DEL, and the line and paragraph separators. */
function isControl(code: number): boolean {
  return code <= 0x1f || code === 0x7f || code === 0x2028 || code === 0x2029;
}

/** A short single-line note: control characters and line breaks become spaces. */
export function noteField(v: unknown): string {
  if (v === undefined || v === null) return "";
  if (typeof v !== "string") throw new SettleError("invalid-request");
  const clean = Array.from(v)
    .map((ch) => (isControl(ch.codePointAt(0) ?? 0) ? " " : ch))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  if (Array.from(clean).length > NOTE_MAX) throw new SettleError("invalid-request");
  return clean;
}

export function amountField(v: unknown, settings: SettleSettings): number {
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v < MIN_AMOUNT) throw new SettleError("invalid-amount");
  if (v > settings.maxAmount) throw new SettleError("amount-too-high", { maxAmount: settings.maxAmount });
  return v;
}

export interface CreateInput {
  requestId: string;
  /** "request": the caller is the payee. "paid": the caller is the payer and already paid. */
  kind: "request" | "paid";
  otherUid: string;
  carpoolId: string;
  amount: number;
  reason: SettleReason;
  note: string;
}

export function parseCreate(data: unknown, settings: SettleSettings): CreateInput {
  const raw = record(data);
  if (raw.kind !== "request" && raw.kind !== "paid") throw new SettleError("invalid-request");
  if (typeof raw.reason !== "string" || !(SETTLE_REASONS as readonly string[]).includes(raw.reason)) throw new SettleError("invalid-request");
  return {
    requestId: requestIdField(raw.requestId),
    kind: raw.kind,
    otherUid: docId(raw.otherUid),
    carpoolId: docId(raw.carpoolId),
    amount: amountField(raw.amount, settings),
    reason: raw.reason as SettleReason,
    note: noteField(raw.note),
  };
}

export function parseAction(data: unknown): { id: string; action: SettleAction } {
  const raw = record(data);
  if (typeof raw.action !== "string" || !(SETTLE_ACTIONS as readonly string[]).includes(raw.action)) throw new SettleError("invalid-request");
  return { id: docId(raw.id), action: raw.action as SettleAction };
}

// --------------------------------------------------------------------------
// State machine
// --------------------------------------------------------------------------

export function newRecord(input: CreateInput, creator: { uid: string; firstName: string }, other: { uid: string; firstName: string }, nowMs: number): SettleRecord {
  const createdBy: SettleRole = input.kind === "request" ? "payee" : "payer";
  const payee = createdBy === "payee" ? creator : other;
  const payer = createdBy === "payee" ? other : creator;
  return {
    id: settleId(creator.uid, input.requestId),
    requestId: input.requestId,
    createdBy,
    payeeUid: payee.uid,
    payerUid: payer.uid,
    payeeFirstName: payee.firstName,
    payerFirstName: payer.firstName,
    parties: [payee.uid, payer.uid],
    carpoolId: input.carpoolId,
    amount: input.amount,
    currency: CURRENCY,
    reason: input.reason,
    note: input.note,
    // A payment recorded by the payer waits for the payee's confirmation.
    status: createdBy === "payee" ? "open" : "paid",
    notReceived: 0,
    reportedBy: [],
    events: [{ type: createdBy === "payee" ? "requested" : "recorded", by: createdBy, atMs: nowMs }],
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
    closedAtMs: null,
    keptUntilMs: null,
  };
}

/** A retried create must carry the same request (same people, amount, reason). */
export function sameRequest(existing: SettleRecord, fresh: SettleRecord): boolean {
  return (
    existing.payeeUid === fresh.payeeUid &&
    existing.payerUid === fresh.payerUid &&
    existing.carpoolId === fresh.carpoolId &&
    existing.amount === fresh.amount &&
    existing.reason === fresh.reason &&
    existing.note === fresh.note &&
    existing.createdBy === fresh.createdBy
  );
}

interface Transition {
  by: SettleRole;
  from: SettleStatus;
  to: SettleStatus;
  event: SettleEventType;
}

/**
 * - open --payer "paid"--> paid
 * - paid --payee "received"--> closed
 * - paid --payee "notReceived"--> open (counted)
 * - open --payee "cancel"--> cancelled
 * - open --payer "decline"--> declined
 */
const TRANSITIONS: Record<SettleAction, Transition> = {
  paid: { by: "payer", from: "open", to: "paid", event: "paid" },
  received: { by: "payee", from: "paid", to: "closed", event: "received" },
  notReceived: { by: "payee", from: "paid", to: "open", event: "not-received" },
  cancel: { by: "payee", from: "open", to: "cancelled", event: "cancelled" },
  decline: { by: "payer", from: "open", to: "declined", event: "declined" },
};

/**
 * The record after [role] takes [action], or a SettleError: "not-allowed"
 * for the wrong side, "invalid-state" for the wrong moment. Appends one
 * event; never rewrites history.
 */
export function applyAction(r: SettleRecord, role: SettleRole, action: SettleAction, nowMs: number): SettleRecord {
  const t = TRANSITIONS[action];
  if (t.by !== role) throw new SettleError("not-allowed");
  if (r.status !== t.from) throw new SettleError("invalid-state", { status: r.status });
  if (r.events.length >= MAX_EVENTS) throw new SettleError("invalid-state", { status: r.status });
  return {
    ...r,
    status: t.to,
    notReceived: action === "notReceived" ? r.notReceived + 1 : r.notReceived,
    events: [...r.events, { type: t.event, by: role, atMs: nowMs }],
    updatedAtMs: nowMs,
    closedAtMs: isFinal(t.to) ? nowMs : null,
  };
}

/** Either side may report once the record bounced [reportAfter] times. */
export function canReport(r: SettleRecord, role: SettleRole, reportAfter: number): "ok" | "report-too-early" | "already-reported" {
  if (r.reportedBy.includes(role)) return "already-reported";
  return r.notReceived >= reportAfter ? "ok" : "report-too-early";
}

export function markReported(r: SettleRecord, role: SettleRole, nowMs: number): SettleRecord {
  return { ...r, reportedBy: [...r.reportedBy, role], events: [...r.events, { type: "reported", by: role, atMs: nowMs }], updatedAtMs: nowMs };
}

/** Which push the other side gets after [action] (never to the one who acted). */
export function noticeFor(action: SettleAction | "requested" | "recorded"): "settle-requested" | "settle-paid" | "settle-updated" {
  if (action === "requested") return "settle-requested";
  if (action === "paid" || action === "recorded") return "settle-paid";
  return "settle-updated";
}

// --------------------------------------------------------------------------
// Account deletion and retention (same rule as trips, privacy/trip_retention.ts)
// --------------------------------------------------------------------------

const DAY_MS = 86_400_000;
/** Records stay while either party's account is active, plus this long after the last closure. */
export const SETTLE_KEEP_AFTER_CLOSE_MS = 365 * DAY_MS;

function initialOf(name: string): string {
  const first = Array.from(name.trim())[0];
  return first ? `${first}.` : "";
}

/**
 * A parent deletes the account: their name becomes an initial and their
 * uid "deleted" (they leave `parties`), an unfinished record is ended with
 * an "account-closed" entry, and the record is kept until closure + 1 year
 * at least. Returns null when [uid] is not a party.
 */
export function anonymiseSettleUp(r: SettleRecord, uid: string, closedAtMs: number): SettleRecord | null {
  const role = roleOf(r, uid);
  if (!role) return null;
  const ended = !isFinal(r.status);
  return {
    ...r,
    payeeUid: role === "payee" ? DELETED_ID : r.payeeUid,
    payerUid: role === "payer" ? DELETED_ID : r.payerUid,
    payeeFirstName: role === "payee" ? initialOf(r.payeeFirstName) : r.payeeFirstName,
    payerFirstName: role === "payer" ? initialOf(r.payerFirstName) : r.payerFirstName,
    parties: r.parties.filter((p) => p !== uid),
    // The note is the two parents' own words: it goes with the first of them.
    note: "",
    status: ended ? "cancelled" : r.status,
    events: ended ? [...r.events, { type: "account-closed", by: "system", atMs: closedAtMs }] : r.events,
    closedAtMs: ended ? closedAtMs : r.closedAtMs,
    updatedAtMs: closedAtMs,
    keptUntilMs: Math.max(r.keptUntilMs ?? 0, closedAtMs + SETTLE_KEEP_AFTER_CLOSE_MS),
  };
}

export type RetentionPlan = "keep" | "clear" | "delete";

/**
 * For a record whose keptUntilMs has passed: "delete" when no party's
 * account is active any more, else "clear" (the remaining parent's account
 * keeps it; a later closure sets a new date). "keep" before the date.
 * [activeUids]: the parties (still in `parties`) whose account exists.
 */
export function planRetention(r: SettleRecord, activeUids: ReadonlySet<string>, nowMs: number): RetentionPlan {
  if (r.keptUntilMs === null || r.keptUntilMs > nowMs) return "keep";
  return r.parties.some((p) => activeUids.has(p)) ? "clear" : "delete";
}
