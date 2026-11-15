import { maskPhone } from "../auth/phone";
import { distanceKm } from "../maps/geo";
import { TYPES } from "./catalog";
import {
  buildPush,
  buildRecord,
  canReceive,
  DEFAULT_ALARM_DELAY_MIN,
  inQuietHours,
  MAX_ATTEMPTS,
  MAX_EVENT_AGE_MS,
  MAX_RECIPIENTS,
  recordText,
  wantsWhatsApp,
  whatsappParams,
  type ChannelState,
  type LatLng,
  type NotificationRecord,
  type NotificationSettings,
  type OutboxEvent,
  type PushMessage,
  type Recipient,
} from "./model";
import type { Language } from "../whatsapp/sender";

/**
 * The ONE sender (Prompt 8: F12, F23). For every outbox event it:
 * 1. finds the recipients (the event's list, or nearby parents for a new
 *    parent), skipping the actor, suspended or banned accounts and, except
 *    for the verification result, parents who are not verified;
 * 2. writes the in-app record users/{uid}/notifications/{eventId} (created
 *    once: a retried event finds it);
 * 3. sends the push to every phone of the parent;
 * 4. sends the WhatsApp template when the parent has that group on.
 *
 * Idempotent: each channel of each record is claimed in a transaction
 * before it is sent ("sending"), and only a channel that failed is tried
 * again, at most MAX_ATTEMPTS times. A retry of the whole event (the
 * trigger retries when something failed) therefore never sends a push or
 * a WhatsApp message twice. A crash between claiming and sending leaves
 * "sending": that message is lost rather than sent twice.
 *
 * Quiet hours: outside critical alerts, a push in the parent's quiet hours
 * is silent (no sound, passive) and its WhatsApp message is not sent.
 * Critical alerts always sound and always go to WhatsApp when on.
 *
 * Logs: counts, types and masked numbers only.
 */

export type Channel = "push" | "whatsapp" | "alarm";

export interface PushToken {
  /** Document ID: sha256 of the token. */
  key: string;
  token: string;
}

export interface PushResult {
  sent: number;
  /** Keys of tokens FCM refused for good (uninstalled app, new token): removed. */
  invalid: string[];
}

export interface PushSender {
  readonly kind: "fake" | "fcm";
  send(tokens: PushToken[], message: PushMessage): Promise<PushResult>;
}

export interface WhatsAppNotifier {
  /** Sends one approved template. Throws when it was not accepted. */
  sendTemplate(toE164: string, template: string, language: Language, params: string[], preview: string): Promise<void>;
}

/** A parent who may get a new-parent alert (parentLocations/{uid}). */
export interface NearbyParent {
  uid: string;
  point: LatLng;
  radiusKm: number;
  verified: boolean;
  notifyNewParents: boolean;
}

export interface NotifyStore {
  recipient(uid: string): Promise<Recipient | null>;
  settings(uid: string): Promise<NotificationSettings>;
  tokens(uid: string): Promise<PushToken[]>;
  deleteTokens(keys: string[]): Promise<void>;
  /** Creates the record unless it exists; returns the stored one. */
  ensureRecord(record: NotificationRecord): Promise<NotificationRecord>;
  record(uid: string, id: string): Promise<NotificationRecord | null>;
  /**
   * In one transaction: true and the channel set to "sending" (attempts + 1)
   * when it was never tried or failed fewer than MAX_ATTEMPTS times.
   */
  claim(uid: string, id: string, channel: Channel, nowMs: number, maxAttempts: number): Promise<boolean>;
  finish(uid: string, id: string, channel: Channel, state: Exclude<ChannelState, "sending">, reason: string | null, nowMs: number): Promise<void>;
  /** The alarm of a critical record was sent (or is no longer needed). */
  setAlarmState(uid: string, id: string, state: "sent" | "cancelled"): Promise<void>;
  /** The new parent's public record now (still verified and shown?). */
  nearbySubject(uid: string): Promise<{ verified: boolean; showOnMap: boolean } | null>;
  /** Parents whose schools include [schoolId]. */
  parentsAtSchool(schoolId: string, limit: number): Promise<NearbyParent[]>;
  markEvent(id: string, status: "done" | "failed", summary: DispatchSummary): Promise<void>;
}

export interface DispatchDeps {
  store: NotifyStore;
  push: PushSender;
  whatsapp: WhatsAppNotifier;
  now: () => number;
  log: (message: string, data?: Record<string, unknown>) => void;
  alarmDelayMs?: number;
  /**
   * Pilot feature switches: false when the event's type belongs to a
   * feature that is off now (features/model.ts GATED_NOTIFICATIONS). The
   * event is then closed with reason "feature-off": no record, no push,
   * no WhatsApp. Absent (unit tests): everything is sent.
   */
  typeAllowed?: (type: OutboxEvent["type"]) => Promise<boolean>;
}

export interface DispatchSummary {
  recipients: number;
  records: number;
  pushes: number;
  whatsapp: number;
  skipped: number;
  failed: number;
  reason: string | null;
}

const empty = (reason: string | null = null): DispatchSummary => ({
  recipients: 0,
  records: 0,
  pushes: 0,
  whatsapp: 0,
  skipped: 0,
  failed: 0,
  reason,
});

/** Thrown after the whole event was tried when a channel failed: the trigger retries. */
export class RetryableDispatchError extends Error {
  constructor(readonly summary: DispatchSummary) {
    super(`notification dispatch: ${summary.failed} channel(s) failed`);
  }
}

/** Recipients of [event]: never the actor, never twice, at most MAX_RECIPIENTS. */
export async function resolveRecipients(store: NotifyStore, event: OutboxEvent): Promise<string[]> {
  let uids: string[];
  if (event.type === "new-parent") {
    uids = await newParentRecipients(store, event);
  } else {
    uids = event.recipients;
  }
  const out = [...new Set(uids)].filter((u) => u !== event.actorUid && u !== event.subjectUid);
  return out.sort().slice(0, MAX_RECIPIENTS);
}

/**
 * F23: verified parents of the same school whose own radius reaches the
 * new parent's ROUNDED point, who did not switch new-parent alerts off.
 * Only when the new parent is still verified and shown on the map.
 */
async function newParentRecipients(store: NotifyStore, event: OutboxEvent): Promise<string[]> {
  const subject = event.subjectUid;
  const point = event.point;
  if (!subject || !point) return [];
  const now = await store.nearbySubject(subject);
  if (!now || !now.verified || !now.showOnMap) return [];
  const found = new Set<string>();
  for (const schoolId of event.schoolIds.slice(0, 10)) {
    for (const p of await store.parentsAtSchool(schoolId, MAX_RECIPIENTS * 2)) {
      if (p.uid === subject || !p.verified || !p.notifyNewParents) continue;
      if (distanceKm(p.point, point) <= p.radiusKm) found.add(p.uid);
    }
  }
  return [...found];
}

export async function dispatchEvent(deps: DispatchDeps, event: OutboxEvent): Promise<DispatchSummary> {
  if (event.status !== "pending") return empty("already-" + event.status);
  if (deps.typeAllowed && !(await deps.typeAllowed(event.type))) {
    const summary = empty("feature-off");
    await deps.store.markEvent(event.id, "done", summary);
    return summary;
  }
  const nowMs = deps.now();
  if (nowMs - event.createdAtMs > MAX_EVENT_AGE_MS) {
    const summary = empty("stale");
    await deps.store.markEvent(event.id, "failed", summary);
    deps.log("notification event too old, not sent", { type: event.type });
    return summary;
  }
  if (event.type === "critical-alarm") return dispatchAlarm(deps, event);

  const uids = await resolveRecipients(deps.store, event);
  const summary = empty();
  summary.recipients = uids.length;
  // Small batches: a carpool has a handful of members, a new parent maybe a few hundred neighbours.
  for (let i = 0; i < uids.length; i += 10) {
    const results = await Promise.all(uids.slice(i, i + 10).map((uid) => deliver(deps, event, uid)));
    for (const r of results) {
      summary.records += r.record ? 1 : 0;
      summary.pushes += r.push ? 1 : 0;
      summary.whatsapp += r.whatsapp ? 1 : 0;
      summary.skipped += r.skipped ? 1 : 0;
      summary.failed += r.failed;
    }
  }
  if (summary.failed > 0) throw new RetryableDispatchError(summary);
  await deps.store.markEvent(event.id, "done", summary);
  deps.log("notification sent", { type: event.type, ...summary });
  return summary;
}

interface Delivery {
  record: boolean;
  push: boolean;
  whatsapp: boolean;
  skipped: boolean;
  failed: number;
}

async function deliver(deps: DispatchDeps, event: OutboxEvent, uid: string): Promise<Delivery> {
  const { store } = deps;
  const out: Delivery = { record: false, push: false, whatsapp: false, skipped: false, failed: 0 };
  const recipient = await store.recipient(uid);
  if (!canReceive(recipient, event.type)) {
    out.skipped = true;
    return out;
  }
  const nowMs = deps.now();
  const record = await store.ensureRecord(
    buildRecord(event, uid, nowMs, deps.alarmDelayMs ?? DEFAULT_ALARM_DELAY_MIN * 60_000),
  );
  out.record = true;
  const settings = await store.settings(uid);
  // Critical and urgent alerts (Arrived, location stopped) ignore quiet hours.
  const quiet = !record.critical && !TYPES[record.type].urgent && inQuietHours(nowMs, settings.quiet);

  // Push to every phone of the parent.
  if (await store.claim(uid, record.id, "push", nowMs, MAX_ATTEMPTS)) {
    try {
      const sent = await sendPush(deps, uid, buildPush(record, recipient.language, { quiet, alarm: false }));
      await store.finish(uid, record.id, "push", sent ? "sent" : "skipped", sent ? null : "no-device", deps.now());
      out.push = sent;
    } catch (error) {
      out.failed += 1;
      await store.finish(uid, record.id, "push", "failed", "error", deps.now());
      deps.log("push failed", { type: event.type, message: error instanceof Error ? error.message : "unknown" });
    }
  }

  // WhatsApp when the parent has this group on (COST MODE: critical only by default).
  if (wantsWhatsApp(record.type, recipient, settings, record.critical)) {
    if (quiet) {
      if (await store.claim(uid, record.id, "whatsapp", nowMs, MAX_ATTEMPTS)) {
        await store.finish(uid, record.id, "whatsapp", "skipped", "quiet", deps.now());
      }
    } else if (await store.claim(uid, record.id, "whatsapp", nowMs, MAX_ATTEMPTS)) {
      try {
        const template = TYPES[record.type].template as string;
        const preview = recordText(record, recipient.language).body;
        await deps.whatsapp.sendTemplate(recipient.phone as string, template, recipient.language, whatsappParams(record, recipient.language), preview);
        await store.finish(uid, record.id, "whatsapp", "sent", null, deps.now());
        out.whatsapp = true;
      } catch (error) {
        out.failed += 1;
        await store.finish(uid, record.id, "whatsapp", "failed", "error", deps.now());
        deps.log("whatsapp failed", {
          type: event.type,
          to: maskPhone(recipient.phone as string),
          message: error instanceof Error ? error.message : "unknown",
        });
      }
    }
  }
  return out;
}

/** Sends to every phone; removes tokens FCM refused. False when the parent has no phone registered. */
async function sendPush(deps: DispatchDeps, uid: string, message: PushMessage): Promise<boolean> {
  const tokens = await deps.store.tokens(uid);
  if (tokens.length === 0) return false;
  const result = await deps.push.send(tokens, message);
  if (result.invalid.length > 0) await deps.store.deleteTokens(result.invalid);
  if (result.sent === 0 && result.invalid.length < tokens.length) throw new Error("FCM sent nothing");
  return result.sent > 0;
}

/**
 * The second, louder push of a critical alert the parent has not opened
 * (spec section 11). The app also schedules its own local alarm (phones
 * that stop background apps); this covers a phone where the app never ran.
 */
async function dispatchAlarm(deps: DispatchDeps, event: OutboxEvent): Promise<DispatchSummary> {
  const { store } = deps;
  const summary = empty();
  const uid = event.recipients[0];
  const refId = event.refEventId;
  const record = uid && refId ? await store.record(uid, refId) : null;
  const recipient = uid ? await store.recipient(uid) : null;
  if (!uid || !record || record.readAtMs !== null || !canReceive(recipient, record.type)) {
    if (uid && record) await store.setAlarmState(uid, record.id, "cancelled");
    summary.skipped = 1;
    await store.markEvent(event.id, "done", summary);
    return summary;
  }
  summary.recipients = 1;
  const nowMs = deps.now();
  if (await store.claim(uid, record.id, "alarm", nowMs, MAX_ATTEMPTS)) {
    try {
      const sent = await sendPush(deps, uid, buildPush(record, recipient.language, { quiet: false, alarm: true }));
      await store.finish(uid, record.id, "alarm", sent ? "sent" : "skipped", sent ? null : "no-device", deps.now());
      await store.setAlarmState(uid, record.id, "sent");
      summary.pushes = sent ? 1 : 0;
    } catch (error) {
      await store.finish(uid, record.id, "alarm", "failed", "error", deps.now());
      summary.failed = 1;
      deps.log("alarm push failed", { message: error instanceof Error ? error.message : "unknown" });
      throw new RetryableDispatchError(summary);
    }
  }
  await store.markEvent(event.id, "done", summary);
  return summary;
}
