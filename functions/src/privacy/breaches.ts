import { BREACH_REGISTER_YEARS, DAY_MS, YEAR_DAYS } from "./retention";
import { isCairoWorkingDay } from "./requests";

/**
 * Personal data breach register (Law No. 151 of 2020, Art. 7; Executive
 * Regulations, Decree 816/2025, Art. 5; docs/legal/breach-runbook.md).
 *
 * - The PDPC is notified within 72 hours of becoming aware of a breach
 *   (portal or hotline), IMMEDIATELY when national security is involved.
 *   Safe side: a breach of sensitive data (children, biometrics) is also
 *   treated as "immediately" (some briefings read the Regulations so).
 * - The notice holds: date and hour of awareness and of notification; the
 *   nature of the breach and when it happened with an estimate of the
 *   records affected; likely effects and expected harm; urgent measures
 *   and corrective actions; the DPO's details; anything else the PDPC asks.
 * - Data subjects are told within 3 working days of notifying the PDPC,
 *   with the safeguards taken, by the channel agreed at collection.
 * - Every notice is recorded in a secure electronic register: this
 *   collection. Admin-only (written by the audited admin callables in
 *   breach_callables.ts; firestore.rules deny every client, admins too).
 *   Records are append-only in spirit: facts are added as events; a
 *   notification time, once set, is never changed; nothing is deleted.
 *
 * Pure; unit-tested (test/breaches.test.ts). Free text is written by
 * admins and must not contain personal data (the form says so).
 */

export const BREACH_REGISTER = "breachRegister";
export const PDPC_NOTICE_HOURS = 72;
/**
 * R15 (answers.md 1.10): our own target for a breach of children's or
 * biometric data: the PDPC notice within 24 hours of awareness ("act as
 * if immediately"), never later than 72 hours. National security: at once.
 */
export const SENSITIVE_TARGET_HOURS = 24;
export const SUBJECT_NOTICE_WORKING_DAYS = 3;
/** "Due soon" when less than this is left. */
export const BREACH_WARN_MS = 12 * 3_600_000;
export const BREACH_TEXT_MAX = 1000;
export const BREACH_REFERENCE_MAX = 60;

export const BREACH_KINDS = ["unauthorisedAccess", "disclosure", "loss", "alteration", "unavailable", "other"] as const;
export type BreachKind = (typeof BREACH_KINDS)[number];

/** Data categories (same words as the record of processing). */
export const BREACH_CATEGORIES = ["account", "contact", "idImages", "biometric", "children", "location", "home", "chat", "devices", "other"] as const;
export type BreachCategory = (typeof BREACH_CATEGORIES)[number];
/** Sensitive under Law 151 of 2020, Art. 1: children's data (incl. where they are) and biometrics. */
export const SENSITIVE_CATEGORIES: readonly BreachCategory[] = ["biometric", "children"];

/** Where it happened: us, or a processor (its own report is kept). */
export const BREACH_SOURCES = ["us", "google", "meta", "algolia", "sentry", "valify", "email", "stream", "other"] as const;
export type BreachSource = (typeof BREACH_SOURCES)[number];

export const BREACH_ACTIONS = ["contained", "pdpcNotified", "subjectsNotified", "note", "closed"] as const;
export type BreachAction = (typeof BREACH_ACTIONS)[number];

export type BreachStatus = "open" | "pdpcNotified" | "subjectsNotified" | "closed";

export interface BreachEvent {
  action: BreachAction | "reported";
  atMs: number;
  byUid: string;
  text: string | null;
}

export interface BreachRecord {
  id: string;
  /** When we became aware: the 72-hour clock starts here. */
  awareAtMs: number;
  occurredAtMs: number | null;
  reportedAtMs: number;
  reportedBy: string;
  kind: BreachKind;
  categories: BreachCategory[];
  source: BreachSource;
  approxRecords: number;
  approxPeople: number;
  nationalSecurity: boolean;
  sensitive: boolean;
  summary: string;
  effects: string;
  measures: string;
  status: BreachStatus;
  pdpcDueAtMs: number;
  immediate: boolean;
  /** R15: our internal target for the PDPC notice (24 h for children/biometrics, at once for national security, else 72 h). */
  targetAtMs?: number;
  pdpcNotifiedAtMs: number | null;
  pdpcReference: string | null;
  subjectsNotifiedAtMs: number | null;
  closedAtMs: number | null;
  /** R7: kept until this date (closed + BREACH_REGISTER_YEARS); null while open. */
  retainUntilMs?: number | null;
  events: BreachEvent[];
}

/** R7: when a closed register entry may be deleted (5 years after closing). */
export function breachRetainUntil(closedAtMs: number): number {
  return closedAtMs + BREACH_REGISTER_YEARS * YEAR_DAYS * DAY_MS;
}

export type BreachErrorReason = "invalid-request" | "not-found" | "invalid-state";

export class BreachError extends Error {
  constructor(readonly reason: BreachErrorReason) {
    super(reason);
    this.name = "BreachError";
  }
}

function text(value: unknown, max: number, required = false): string {
  if (value === undefined || value === null) {
    if (required) throw new BreachError("invalid-request");
    return "";
  }
  if (typeof value !== "string") throw new BreachError("invalid-request");
  const t = value.trim();
  if (t.length > max || (required && t.length === 0)) throw new BreachError("invalid-request");
  return t;
}

function time(value: unknown, nowMs: number, optional: boolean): number | null {
  if (value === undefined || value === null) {
    if (optional) return null;
    throw new BreachError("invalid-request");
  }
  // Not in the future (one minute of clock skew), not older than 5 years.
  if (typeof value !== "number" || !Number.isInteger(value) || value > nowMs + 60_000 || value < nowMs - 5 * 365 * DAY_MS) {
    throw new BreachError("invalid-request");
  }
  return value;
}

function count(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 100_000_000) throw new BreachError("invalid-request");
  return value;
}

function oneOf<T extends string>(list: readonly T[], value: unknown): T {
  if (typeof value !== "string" || !(list as readonly string[]).includes(value)) throw new BreachError("invalid-request");
  return value as T;
}

/** Adds [days] Cairo working days (Sun-Thu; holidays counted = earlier, safe side). */
export function addWorkingDays(fromMs: number, days: number): number {
  let at = fromMs;
  let left = days;
  while (left > 0) {
    at += DAY_MS;
    if (isCairoWorkingDay(at)) left -= 1;
  }
  return at;
}

/** When the PDPC must have the notice, and whether "immediately" applies. */
export function pdpcDeadline(awareAtMs: number, nationalSecurity: boolean, sensitive: boolean): { dueAtMs: number; immediate: boolean } {
  if (nationalSecurity || sensitive) return { dueAtMs: awareAtMs, immediate: true };
  return { dueAtMs: awareAtMs + PDPC_NOTICE_HOURS * 3_600_000, immediate: false };
}

/** R15: the internal target for the PDPC notice. */
export function pdpcTarget(awareAtMs: number, nationalSecurity: boolean, sensitive: boolean): number {
  if (nationalSecurity) return awareAtMs;
  if (sensitive) return awareAtMs + SENSITIVE_TARGET_HOURS * 3_600_000;
  return awareAtMs + PDPC_NOTICE_HOURS * 3_600_000;
}

/** Parents must be told within 3 working days of the PDPC notice (provisional until it is sent). */
export function subjectsDeadline(r: Pick<BreachRecord, "pdpcNotifiedAtMs" | "pdpcDueAtMs">): number {
  return addWorkingDays(r.pdpcNotifiedAtMs ?? r.pdpcDueAtMs, SUBJECT_NOTICE_WORKING_DAYS);
}

/** { awareAtMs, occurredAtMs?, kind, categories, source, approxRecords, approxPeople, nationalSecurity, summary, effects?, measures? } */
export function newBreach(id: string, data: unknown, byUid: string, nowMs: number): BreachRecord {
  if (typeof data !== "object" || data === null) throw new BreachError("invalid-request");
  const raw = data as Record<string, unknown>;
  const awareAtMs = time(raw.awareAtMs, nowMs, false) as number;
  const occurredAtMs = time(raw.occurredAtMs, nowMs, true);
  if (occurredAtMs !== null && occurredAtMs > awareAtMs) throw new BreachError("invalid-request");
  if (!Array.isArray(raw.categories) || raw.categories.length === 0 || raw.categories.length > BREACH_CATEGORIES.length) {
    throw new BreachError("invalid-request");
  }
  const categories = [...new Set(raw.categories.map((c) => oneOf(BREACH_CATEGORIES, c)))];
  if (typeof raw.nationalSecurity !== "boolean") throw new BreachError("invalid-request");
  const sensitive = categories.some((c) => SENSITIVE_CATEGORIES.includes(c));
  const deadline = pdpcDeadline(awareAtMs, raw.nationalSecurity, sensitive);
  return {
    id,
    awareAtMs,
    occurredAtMs,
    reportedAtMs: nowMs,
    reportedBy: byUid,
    kind: oneOf(BREACH_KINDS, raw.kind),
    categories,
    source: oneOf(BREACH_SOURCES, raw.source),
    approxRecords: count(raw.approxRecords),
    approxPeople: count(raw.approxPeople),
    nationalSecurity: raw.nationalSecurity,
    sensitive,
    summary: text(raw.summary, BREACH_TEXT_MAX, true),
    effects: text(raw.effects, BREACH_TEXT_MAX),
    measures: text(raw.measures, BREACH_TEXT_MAX),
    status: "open",
    pdpcDueAtMs: deadline.dueAtMs,
    immediate: deadline.immediate,
    targetAtMs: pdpcTarget(awareAtMs, raw.nationalSecurity, sensitive),
    pdpcNotifiedAtMs: null,
    pdpcReference: null,
    subjectsNotifiedAtMs: null,
    closedAtMs: null,
    events: [{ action: "reported", atMs: nowMs, byUid, text: null }],
  };
}

/**
 * { id, action, atMs?, reference?, text? } applied to [r]. Rules:
 * - pdpcNotified once (a reference up to 60 characters; time not before awareness);
 * - subjectsNotified once, only after the PDPC notice;
 * - closed only after both notices (the law has no "low risk" exception);
 * - contained and note add an event; nothing is ever removed or rewritten.
 */
export function applyBreachUpdate(r: BreachRecord, data: unknown, byUid: string, nowMs: number): BreachRecord {
  if (typeof data !== "object" || data === null) throw new BreachError("invalid-request");
  const raw = data as Record<string, unknown>;
  const action = oneOf(BREACH_ACTIONS, raw.action);
  if (r.status === "closed") throw new BreachError("invalid-state");
  const atMs = (time(raw.atMs, nowMs, true) ?? nowMs) as number;
  const note = text(raw.text, BREACH_TEXT_MAX, action === "note");
  const event: BreachEvent = { action, atMs, byUid, text: note || null };
  const next: BreachRecord = { ...r, events: [...r.events, event] };
  switch (action) {
    case "pdpcNotified":
      if (r.pdpcNotifiedAtMs !== null || atMs < r.awareAtMs) throw new BreachError("invalid-state");
      next.pdpcNotifiedAtMs = atMs;
      next.pdpcReference = text(raw.reference, BREACH_REFERENCE_MAX) || null;
      next.status = "pdpcNotified";
      break;
    case "subjectsNotified":
      if (r.pdpcNotifiedAtMs === null || r.subjectsNotifiedAtMs !== null || atMs < r.pdpcNotifiedAtMs) throw new BreachError("invalid-state");
      next.subjectsNotifiedAtMs = atMs;
      next.status = "subjectsNotified";
      break;
    case "closed":
      if (r.pdpcNotifiedAtMs === null || r.subjectsNotifiedAtMs === null) throw new BreachError("invalid-state");
      next.closedAtMs = atMs;
      next.retainUntilMs = breachRetainUntil(atMs);
      next.status = "closed";
      break;
    default:
      break;
  }
  return next;
}

/** "now": the notice is due immediately (national security or sensitive data) and not sent yet. */
export type DeadlineState = "done" | "now" | "onTime" | "dueSoon" | "overdue";

function stateOf(doneAtMs: number | null, dueAtMs: number, nowMs: number): DeadlineState {
  if (doneAtMs !== null) return doneAtMs <= dueAtMs ? "done" : "overdue";
  if (nowMs > dueAtMs) return "overdue";
  return dueAtMs - nowMs <= BREACH_WARN_MS ? "dueSoon" : "onTime";
}

/** What the admin panel shows: both clocks and where each stands. */
export function breachView(r: BreachRecord, nowMs: number) {
  const subjectsDueAtMs = subjectsDeadline(r);
  const targetAtMs = r.targetAtMs ?? pdpcTarget(r.awareAtMs, r.nationalSecurity, r.sensitive);
  return {
    ...r,
    targetAtMs,
    subjectsDueAtMs,
    // R15: a sensitive breach not notified yet is "now" until 24 h, then overdue.
    pdpcState:
      r.immediate && r.pdpcNotifiedAtMs === null && !r.nationalSecurity && nowMs > targetAtMs
        ? ("overdue" as DeadlineState)
        : r.immediate && r.pdpcNotifiedAtMs === null ? ("now" as DeadlineState) : stateOf(r.pdpcNotifiedAtMs, r.immediate ? r.awareAtMs + PDPC_NOTICE_HOURS * 3_600_000 : r.pdpcDueAtMs, nowMs),
    subjectsState: stateOf(r.subjectsNotifiedAtMs, subjectsDueAtMs, nowMs),
  };
}
