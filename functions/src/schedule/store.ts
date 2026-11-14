import { Timestamp, type DocumentData } from "firebase-admin/firestore";
import { NOTIFICATION_EVENTS } from "../notifications/outbox";
import {
  EVENT_TTL_DAYS,
  EXCEPTION_REASONS,
  RUN_STATUSES,
  type BalanceRecord,
  type Direction,
  type ExceptionReason,
  type ExceptionRecord,
  type FamilyBalance,
  type Rider,
  type RunRecord,
  type RunStatus,
  type ScheduleEvent,
  type SwapRecord,
  type SwapStatus,
} from "./model";

/** Firestore mapping of the schedule records (Prompt 7). Only Cloud Functions write them. */

export const SCHEDULE = "schedule";
export const SWAPS = "swaps";
export const EXCEPTIONS = "exceptions";
export const BALANCES = "balances";
/**
 * Prompt 8: schedule alerts go straight to the notification outbox
 * (notifications/outbox.ts), where the one sender
 * (sendNotification) picks them up. Same document shape as before.
 */
export const SCHEDULE_EVENTS = NOTIFICATION_EVENTS;

function text(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function textOrNull(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function num(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

function ms(v: unknown): number {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : 0;
}

function msOrNull(v: unknown): number | null {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : null;
}

const ts = (value: number): Timestamp => Timestamp.fromMillis(value);
const tsOrNull = (value: number | null): Timestamp | null => (value === null ? null : Timestamp.fromMillis(value));

function direction(v: unknown): Direction {
  return v === "toHome" ? "toHome" : "toSchool";
}

function riders(v: unknown): Rider[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((x) => (typeof x === "object" && x !== null ? (x as Record<string, unknown>) : {}))
    .filter((x) => typeof x.id === "string")
    .map((x) => ({ id: x.id as string, firstName: text(x.firstName), parentUid: text(x.parentUid) }));
}

export function runFromDoc(carpoolId: string, id: string, d: DocumentData): RunRecord {
  return {
    id,
    carpoolId,
    date: text(d.date),
    direction: direction(d.direction),
    time: text(d.time),
    startMs: ms(d.startAt),
    confirmByMs: ms(d.confirmBy),
    status: (RUN_STATUSES as readonly unknown[]).includes(d.status) ? (d.status as RunStatus) : "open",
    driverUid: textOrNull(d.driverUid),
    driverFirstName: text(d.driverFirstName),
    fallback: d.fallback === true,
    swapped: d.swapped === true,
    swapId: textOrNull(d.swapId),
    swapBy: textOrNull(d.swapBy),
    riders: riders(d.riders),
    absent: riders(d.absent),
    weekStart: text(d.weekStart),
    termId: text(d.termId),
    confirmedAtMs: msOrNull(d.confirmedAt),
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function runToDoc(r: RunRecord): DocumentData {
  return {
    carpoolId: r.carpoolId,
    date: r.date,
    direction: r.direction,
    time: r.time,
    startAt: ts(r.startMs),
    confirmBy: ts(r.confirmByMs),
    status: r.status,
    driverUid: r.driverUid,
    driverFirstName: r.driverFirstName,
    fallback: r.fallback,
    swapped: r.swapped,
    swapId: r.swapId,
    swapBy: r.swapBy,
    riders: r.riders,
    absent: r.absent,
    weekStart: r.weekStart,
    termId: r.termId,
    confirmedAt: tsOrNull(r.confirmedAtMs),
    createdAt: ts(r.createdAtMs),
    updatedAt: ts(r.updatedAtMs),
  };
}

const SWAP_STATUSES: readonly SwapStatus[] = ["open", "accepted", "cancelled", "expired"];

export function swapFromDoc(carpoolId: string, id: string, d: DocumentData): SwapRecord {
  return {
    id,
    carpoolId,
    runId: text(d.runId),
    date: text(d.date),
    direction: direction(d.direction),
    requesterUid: text(d.requesterUid),
    requesterFirstName: text(d.requesterFirstName),
    previousStatus: d.previousStatus === "confirmed" ? "confirmed" : "planned",
    status: (SWAP_STATUSES as readonly unknown[]).includes(d.status) ? (d.status as SwapStatus) : "expired",
    acceptedBy: textOrNull(d.acceptedBy),
    suggestedUids: Array.isArray(d.suggestedUids) ? d.suggestedUids.filter((u: unknown): u is string => typeof u === "string") : [],
    createdAtMs: ms(d.createdAt),
    updatedAtMs: ms(d.updatedAt),
  };
}

export function swapToDoc(s: SwapRecord): DocumentData {
  return {
    carpoolId: s.carpoolId,
    runId: s.runId,
    date: s.date,
    direction: s.direction,
    requesterUid: s.requesterUid,
    requesterFirstName: s.requesterFirstName,
    previousStatus: s.previousStatus,
    status: s.status,
    acceptedBy: s.acceptedBy,
    suggestedUids: s.suggestedUids,
    createdAt: ts(s.createdAtMs),
    updatedAt: ts(s.updatedAtMs),
  };
}

export function exceptionFromDoc(carpoolId: string, id: string, d: DocumentData): ExceptionRecord {
  return {
    id,
    carpoolId,
    kind: d.kind === "times" ? "times" : "noSchool",
    reason: (EXCEPTION_REASONS as readonly unknown[]).includes(d.reason) ? (d.reason as ExceptionReason) : "other",
    from: text(d.from),
    to: text(d.to),
    morning: textOrNull(d.morning),
    afternoon: textOrNull(d.afternoon),
    createdBy: text(d.createdBy),
    createdAtMs: ms(d.createdAt),
  };
}

export function exceptionToDoc(e: ExceptionRecord): DocumentData {
  return {
    kind: e.kind,
    reason: e.reason,
    from: e.from,
    to: e.to,
    morning: e.morning,
    afternoon: e.afternoon,
    createdBy: e.createdBy,
    createdAt: ts(e.createdAtMs),
  };
}

export function balanceFromDoc(carpoolId: string, termId: string, d: DocumentData): BalanceRecord {
  const families: Record<string, FamilyBalance> = {};
  const raw = typeof d.families === "object" && d.families !== null ? (d.families as Record<string, unknown>) : {};
  for (const [uid, v] of Object.entries(raw)) {
    const f = typeof v === "object" && v !== null ? (v as Record<string, unknown>) : {};
    families[uid] = { firstName: text(f.firstName), driven: num(f.driven), received: num(f.received), share: num(f.share) };
  }
  return { carpoolId, termId, families, updatedAtMs: ms(d.updatedAt) };
}

export function balanceToDoc(b: BalanceRecord): DocumentData {
  return { termId: b.termId, families: b.families, updatedAt: ts(b.updatedAtMs) };
}

export function eventToDoc(e: ScheduleEvent): DocumentData {
  return {
    type: e.type,
    carpoolId: e.carpoolId,
    runId: e.runId,
    date: e.date,
    direction: e.direction,
    recipients: e.recipients,
    actorUid: e.actorUid,
    childId: e.childId,
    critical: e.critical,
    // The sender (notifications/dispatch.ts) picks up "pending" events.
    status: "pending",
    createdAt: ts(e.createdAtMs),
    // Also the Firestore TTL field (SETUP.md section 18).
    expiresAt: ts(e.createdAtMs + EVENT_TTL_DAYS * 86_400_000),
  };
}
