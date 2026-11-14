import { cairoOffsetMinutes } from "../schedule/cairo";
import type { Language } from "../whatsapp/sender";
import { isNotificationType, isWhatsAppGroup, routeFor, TYPES, WHATSAPP_DEFAULTS, WHATSAPP_GROUPS, type NotificationType, type WhatsAppGroup } from "./catalog";
import { pushText, whenText, type PushText } from "./texts";

/**
 * Records of the notification sender (Prompt 8). Only Cloud Functions write
 * them, except `readAt` on the parent's own in-app records.
 *
 * - notificationEvents/{eventId}: the outbox. Every producer writes one
 *   event here (schedule flows, reminders, join requests, verification
 *   decisions, the new-parent event, the alarm tick); the one dispatcher
 *   (sendNotification) sends it. IDs only: no names or message text.
 *   Cloud Functions only. TTL on `expiresAt` (30 days).
 * - users/{uid}/notifications/{eventId}: the in-app record (Notifications
 *   tab), one per event and recipient, so a retried event never makes a
 *   second one. The parent reads it and may set `readAt` only.
 *   TTL on `expiresAt` (60 days).
 * - notificationSettings/{uid}: WhatsApp on or off per group and quiet
 *   hours. The parent reads it; updateNotificationSettings writes it.
 * - pushTokens/{sha256(token)}: one FCM token per phone, with its owner.
 *   Cloud Functions only (registerPushDevice, unregisterPushDevice, and the
 *   dispatcher removes tokens FCM refuses).
 */

export const EVENT_TTL_DAYS = 30;
export const RECORD_TTL_DAYS = 60;
/** A critical alert nobody opened after this long sounds the alarm. */
export const DEFAULT_ALARM_DELAY_MIN = 15;
/** Events older than this are not sent any more (a stuck retry, a backlog). */
export const MAX_EVENT_AGE_MS = 6 * 3_600_000;
/** A channel that failed is tried again by the trigger's retries, at most this often. */
export const MAX_ATTEMPTS = 3;
/** Fan-out cap per event (the new-parent alert can reach many parents). */
export const MAX_RECIPIENTS = 300;
/** Phones per parent; the oldest token goes when a new one comes. */
export const MAX_DEVICES = 10;

export interface LatLng {
  lat: number;
  lng: number;
}

export type EventStatus = "pending" | "done" | "failed";

/** One outbox event (notificationEvents/{id}). */
export interface OutboxEvent {
  id: string;
  type: NotificationType;
  /** Who is told. Empty for "new-parent": the dispatcher finds them. */
  recipients: string[];
  carpoolId: string | null;
  runId: string | null;
  date: string | null;
  direction: string | null;
  /** Who caused it; never told about their own action. */
  actorUid: string | null;
  childId: string | null;
  /** New parent: the parent, their schools and their ROUNDED point. */
  subjectUid: string | null;
  schoolIds: string[];
  point: LatLng | null;
  /** critical-alarm: the event whose record is repeated. */
  refEventId: string | null;
  critical: boolean;
  status: EventStatus;
  createdAtMs: number;
}

export type ChannelState = "sending" | "sent" | "failed" | "skipped";

export interface ChannelRecord {
  state: ChannelState;
  attempts: number;
  /** Why it was skipped or failed: "no-device", "off", "quiet", "error". Never personal data. */
  reason: string | null;
  atMs: number;
}

export type AlarmState = "waiting" | "escalated" | "sent" | "cancelled";

/** users/{uid}/notifications/{eventId}: what the Notifications tab shows. */
export interface NotificationRecord {
  id: string;
  uid: string;
  type: NotificationType;
  critical: boolean;
  carpoolId: string | null;
  runId: string | null;
  date: string | null;
  direction: string | null;
  route: string;
  createdAtMs: number;
  readAtMs: number | null;
  /** Critical only: when the alarm sounds if still unread. */
  alarmAtMs: number | null;
  alarmState: AlarmState | null;
  push: ChannelRecord | null;
  whatsapp: ChannelRecord | null;
  alarm: ChannelRecord | null;
}

export interface QuietHours {
  on: boolean;
  /** Cairo wall-clock HH:MM. The window may cross midnight. */
  from: string;
  to: string;
}

export interface NotificationSettings {
  whatsapp: Record<WhatsAppGroup, boolean>;
  quiet: QuietHours;
}

export const DEFAULT_QUIET: QuietHours = { on: true, from: "22:00", to: "06:00" };

export function defaultSettings(): NotificationSettings {
  return { whatsapp: { ...WHATSAPP_DEFAULTS }, quiet: { ...DEFAULT_QUIET } };
}

const TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;

export function isTime(value: unknown): value is string {
  return typeof value === "string" && TIME.test(value);
}

/** Settings from a stored document; anything missing or odd is the default. */
export function settingsFrom(doc: Record<string, unknown> | null | undefined): NotificationSettings {
  const out = defaultSettings();
  const wa = doc?.whatsapp;
  if (wa && typeof wa === "object") {
    for (const [k, v] of Object.entries(wa as Record<string, unknown>)) {
      if (isWhatsAppGroup(k) && typeof v === "boolean") out.whatsapp[k] = v;
    }
  }
  const q = doc?.quiet as Record<string, unknown> | undefined;
  if (q && typeof q === "object") {
    if (typeof q.on === "boolean") out.quiet.on = q.on;
    if (isTime(q.from)) out.quiet.from = q.from;
    if (isTime(q.to)) out.quiet.to = q.to;
  }
  return out;
}

export class NotificationInputError extends Error {
  constructor(readonly reason: "invalid-request") {
    super(reason);
  }
}

/**
 * updateNotificationSettings input: { whatsapp?: { group: bool }, quiet?: { on?, from?, to? } }.
 * Unknown groups, non-booleans and bad times are refused, not ignored.
 */
export function applySettingsChange(current: NotificationSettings, data: unknown): NotificationSettings {
  if (typeof data !== "object" || data === null) throw new NotificationInputError("invalid-request");
  const raw = data as Record<string, unknown>;
  const next: NotificationSettings = { whatsapp: { ...current.whatsapp }, quiet: { ...current.quiet } };
  let changed = false;
  if (raw.whatsapp !== undefined) {
    if (typeof raw.whatsapp !== "object" || raw.whatsapp === null) throw new NotificationInputError("invalid-request");
    for (const [k, v] of Object.entries(raw.whatsapp as Record<string, unknown>)) {
      if (!isWhatsAppGroup(k) || typeof v !== "boolean") throw new NotificationInputError("invalid-request");
      next.whatsapp[k] = v;
      changed = true;
    }
  }
  if (raw.quiet !== undefined) {
    if (typeof raw.quiet !== "object" || raw.quiet === null) throw new NotificationInputError("invalid-request");
    const q = raw.quiet as Record<string, unknown>;
    if (q.on !== undefined) {
      if (typeof q.on !== "boolean") throw new NotificationInputError("invalid-request");
      next.quiet.on = q.on;
      changed = true;
    }
    for (const key of ["from", "to"] as const) {
      if (q[key] === undefined) continue;
      if (!isTime(q[key])) throw new NotificationInputError("invalid-request");
      next.quiet[key] = q[key] as string;
      changed = true;
    }
  }
  if (!changed) throw new NotificationInputError("invalid-request");
  return next;
}

export function settingsToDoc(s: NotificationSettings): Record<string, unknown> {
  return { whatsapp: { ...s.whatsapp }, quiet: { ...s.quiet } };
}

/** Minutes after midnight, Cairo time (DST-aware). */
export function cairoMinutes(nowMs: number): number {
  const local = Math.floor(nowMs / 60_000) + cairoOffsetMinutes(nowMs);
  return ((local % 1440) + 1440) % 1440;
}

function minutesOf(time: string): number {
  const [h, m] = time.split(":").map(Number);
  return h * 60 + m;
}

/** True inside the parent's quiet hours (Cairo time). from == to means never. */
export function inQuietHours(nowMs: number, quiet: QuietHours): boolean {
  if (!quiet.on) return false;
  const now = cairoMinutes(nowMs);
  const from = minutesOf(quiet.from);
  const to = minutesOf(quiet.to);
  if (from === to) return false;
  return from < to ? now >= from && now < to : now >= from || now < to;
}

/** The parent, as far as sending is concerned. Phone stays in Functions. */
export interface Recipient {
  uid: string;
  status: string;
  banned: boolean;
  language: Language;
  /** E.164, for WhatsApp only. Never logged in clear. */
  phone: string | null;
  /** The WhatsApp consent from the terms step (Prompt 2). */
  whatsappOptIn: boolean;
}

export function canReceive(r: Recipient | null, type: NotificationType): r is Recipient {
  if (!r || r.banned || r.status === "suspended") return false;
  if (r.status === "verified") return true;
  return type === "verification-approved" || type === "verification-rejected";
}

/** WhatsApp for this recipient and type: a template exists, they agreed, and the group is on. */
export function wantsWhatsApp(type: NotificationType, r: Recipient, settings: NotificationSettings): boolean {
  const spec = TYPES[type];
  if (!spec.template || !r.whatsappOptIn || !r.phone) return false;
  const group = spec.group;
  return isWhatsAppGroup(group) && settings.whatsapp[group];
}

/** The in-app record of [event] for [uid]. */
export function buildRecord(event: OutboxEvent, uid: string, nowMs: number, alarmDelayMs: number): NotificationRecord {
  const critical = TYPES[event.type].critical || event.critical;
  return {
    id: event.id,
    uid,
    type: event.type,
    critical,
    carpoolId: event.carpoolId,
    runId: event.runId,
    date: event.date,
    direction: event.direction,
    route: routeFor({ type: event.type, carpoolId: event.carpoolId }),
    createdAtMs: nowMs,
    readAtMs: null,
    alarmAtMs: critical ? nowMs + alarmDelayMs : null,
    alarmState: critical ? "waiting" : null,
    push: null,
    whatsapp: null,
    alarm: null,
  };
}

/** A push as the dispatcher builds it; push.ts turns it into an FCM message. */
export interface PushMessage {
  title: string;
  body: string;
  /** Only these keys, all IDs or flags: the app loads the rest after it opens. */
  data: { type: string; notificationId: string; route: string; critical: string; alarm: string; alarmAt: string };
  /** Sound and a heads-up banner (false in quiet hours). */
  sound: boolean;
  /** iOS interruption level and Android channel. */
  level: "passive" | "active" | "time-sensitive";
  /** Category so the phone groups pushes of one kind. */
  threadId: string;
  /** Wake the app in the background (critical: schedule the in-app alarm). */
  contentAvailable: boolean;
}

/** Text of [record] in [language]. */
export function recordText(record: Pick<NotificationRecord, "type" | "date" | "direction">, language: Language): PushText {
  return pushText(record.type, language, whenText(record.date, record.direction, language));
}

export function buildPush(record: NotificationRecord, language: Language, opts: { quiet: boolean; alarm: boolean }): PushMessage {
  const text = recordText(record, language);
  const critical = record.critical;
  const level = critical ? "time-sensitive" : opts.quiet ? "passive" : "active";
  return {
    title: opts.alarm ? (language === "ar" ? `تذكير: ${text.title}` : `Reminder: ${text.title}`) : text.title,
    body: text.body,
    data: {
      type: record.type,
      notificationId: record.id,
      route: record.route,
      critical: critical ? "1" : "0",
      alarm: opts.alarm ? "1" : "0",
      // Critical: when the app's own alarm should sound if still unread (ms since epoch).
      alarmAt: record.alarmAtMs === null ? "" : String(record.alarmAtMs),
    },
    sound: critical || !opts.quiet,
    level,
    threadId: TYPES[record.type].group,
    contentAvailable: critical,
  };
}

/** Body parameters of the WhatsApp template: {when} or nothing. */
export function whatsappParams(record: NotificationRecord, language: Language): string[] {
  if (!TYPES[record.type].hasWhen) return [];
  return [whenText(record.date, record.direction, language) || (language === "ar" ? "اليوم" : "today")];
}

/** Every group a parent can switch, with its value: what the settings screen shows. */
export function settingsView(s: NotificationSettings): Record<string, unknown> {
  const whatsapp: Record<string, boolean> = {};
  for (const g of WHATSAPP_GROUPS) whatsapp[g] = s.whatsapp[g];
  return { whatsapp, quiet: { ...s.quiet } };
}

// --------------------------------------------------------------------------
// Outbox events
// --------------------------------------------------------------------------

const DOC_ID = /^[A-Za-z0-9_-]{1,700}$/;

/** A new outbox event with defaults for every field. */
export function newEvent(
  id: string,
  type: NotificationType,
  recipients: string[],
  nowMs: number,
  extra: Partial<Omit<OutboxEvent, "id" | "type" | "recipients" | "createdAtMs" | "status">> = {},
): OutboxEvent {
  if (!DOC_ID.test(id)) throw new Error("bad event id");
  return {
    id,
    type,
    recipients: [...new Set(recipients)].sort(),
    carpoolId: extra.carpoolId ?? null,
    runId: extra.runId ?? null,
    date: extra.date ?? null,
    direction: extra.direction ?? null,
    actorUid: extra.actorUid ?? null,
    childId: extra.childId ?? null,
    subjectUid: extra.subjectUid ?? null,
    schoolIds: extra.schoolIds ?? [],
    point: extra.point ?? null,
    refEventId: extra.refEventId ?? null,
    critical: extra.critical ?? TYPES[type].critical,
    status: "pending",
    createdAtMs: nowMs,
  };
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function strings(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string" && x.length > 0) : [];
}

/**
 * Reads an outbox document written by any producer. null for an unknown
 * type (logged and dropped by the dispatcher).
 */
export function eventFromDoc(id: string, d: Record<string, unknown>, createdAtMs: number): OutboxEvent | null {
  if (!isNotificationType(d.type)) return null;
  const p = d.point as { latitude?: unknown; longitude?: unknown } | null | undefined;
  const point = p && typeof p.latitude === "number" && typeof p.longitude === "number" ? { lat: p.latitude, lng: p.longitude } : null;
  const status: EventStatus = d.status === "done" || d.status === "failed" ? d.status : "pending";
  return {
    id,
    type: d.type,
    recipients: strings(d.recipients),
    carpoolId: str(d.carpoolId),
    runId: str(d.runId),
    date: str(d.date),
    direction: str(d.direction),
    actorUid: str(d.actorUid),
    childId: str(d.childId),
    subjectUid: str(d.subjectUid),
    schoolIds: strings(d.schoolIds),
    point,
    refEventId: str(d.refEventId),
    critical: d.critical === true,
    status,
    createdAtMs,
  };
}
