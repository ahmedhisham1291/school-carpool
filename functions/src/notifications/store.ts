import { createHash } from "node:crypto";
import { FieldValue, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import { USERS } from "../auth/accounts";
import { takeFromWindow, type WindowCounter } from "../maps/limits";
import { publicFromDoc } from "../maps/store";
import { asLanguage } from "../whatsapp/sender";
import { isNotificationType, isPushOnlyId } from "./catalog";
import { NOTIFICATION_EVENTS, outboxDoc } from "./outbox";
import {
  MAX_DEVICES,
  RECORD_TTL_DAYS,
  settingsFrom,
  settingsToDoc,
  type AlarmState,
  type ChannelRecord,
  type ChannelState,
  type NotificationRecord,
  type NotificationSettings,
  type OutboxEvent,
  type Recipient,
} from "./model";
import type { Channel, DispatchSummary, NearbyParent, NotifyStore, PushToken } from "./dispatch";
import type { DeviceStore, NotificationLimitKind } from "./devices";
import type { RunLite, TickStore } from "./tick";

export const NOTIFICATIONS = "notifications";
/** Prompt 9: delivery records of chat pushes (push only, not in the Notifications tab). */
export const CHAT_PUSHES = "chatPushes";
const CHAT_PUSH_TTL_DAYS = 2;
export const NOTIFICATION_SETTINGS = "notificationSettings";
export const PUSH_TOKENS = "pushTokens";
export const NOTIFICATION_LIMITS = "notificationLimits";
const PARENT_LOCATIONS = "parentLocations";
const SCHEDULE = "schedule";
const DAY = 86_400_000;

const ts = (ms: number): Timestamp => Timestamp.fromMillis(ms);

function ms(v: unknown): number | null {
  const t = v as { toMillis?: () => number } | null | undefined;
  return typeof t?.toMillis === "function" ? t.toMillis() : null;
}

function text(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

/** Document ID of a push token: never the token itself. */
export function tokenKey(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function channelToDoc(c: ChannelRecord | null): DocumentData | null {
  return c ? { state: c.state, attempts: c.attempts, reason: c.reason, at: ts(c.atMs) } : null;
}

function channelFromDoc(v: unknown): ChannelRecord | null {
  const d = v as Record<string, unknown> | null | undefined;
  if (!d || typeof d !== "object" || typeof d.state !== "string") return null;
  return {
    state: d.state as ChannelState,
    attempts: typeof d.attempts === "number" ? d.attempts : 0,
    reason: text(d.reason),
    atMs: ms(d.at) ?? 0,
  };
}

export function recordToDoc(r: NotificationRecord): DocumentData {
  return {
    type: r.type,
    critical: r.critical,
    carpoolId: r.carpoolId,
    runId: r.runId,
    date: r.date,
    direction: r.direction,
    route: r.route,
    createdAt: ts(r.createdAtMs),
    readAt: r.readAtMs === null ? null : ts(r.readAtMs),
    alarmAt: r.alarmAtMs === null ? null : ts(r.alarmAtMs),
    alarmState: r.alarmState,
    push: channelToDoc(r.push),
    whatsapp: channelToDoc(r.whatsapp),
    alarm: channelToDoc(r.alarm),
    expiresAt: ts(r.createdAtMs + RECORD_TTL_DAYS * DAY),
  };
}

export function recordFromDoc(uid: string, id: string, d: DocumentData): NotificationRecord | null {
  if (!isNotificationType(d.type)) return null;
  return {
    id,
    uid,
    type: d.type,
    critical: d.critical === true,
    carpoolId: text(d.carpoolId),
    runId: text(d.runId),
    date: text(d.date),
    direction: text(d.direction),
    route: text(d.route) ?? "/notifications",
    createdAtMs: ms(d.createdAt) ?? 0,
    readAtMs: ms(d.readAt),
    alarmAtMs: ms(d.alarmAt),
    alarmState: (text(d.alarmState) as AlarmState | null) ?? null,
    push: channelFromDoc(d.push),
    whatsapp: channelFromDoc(d.whatsapp),
    alarm: channelFromDoc(d.alarm),
  };
}

function runLite(carpoolId: string, runId: string, d: DocumentData): RunLite {
  return {
    carpoolId,
    runId,
    date: text(d.date) ?? "",
    direction: text(d.direction) ?? "toSchool",
    driverUid: text(d.driverUid),
    startMs: ms(d.startAt) ?? 0,
    confirmByMs: ms(d.confirmBy) ?? 0,
    status: text(d.status) ?? "",
  };
}

function isAlreadyExists(error: unknown): boolean {
  const code = (error as { code?: unknown }).code;
  return code === 6 || code === "already-exists";
}

export class FirestoreNotifyStore implements NotifyStore, TickStore, DeviceStore {
  constructor(private readonly db: Firestore) {}

  takeLimit(uid: string, kind: NotificationLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const ref = this.db.collection(NOTIFICATION_LIMITS).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const raw = (snap.exists ? snap.get(kind) : undefined) as { windowStartMs?: unknown; count?: unknown } | undefined;
      const current: WindowCounter | undefined =
        raw && typeof raw.windowStartMs === "number" && typeof raw.count === "number" ? { windowStartMs: raw.windowStartMs, count: raw.count } : undefined;
      const result = takeFromWindow(current, nowMs, rule);
      if (result.allowed) tx.set(ref, { ...(snap.exists ? snap.data() : {}), [kind]: result.next });
      return { allowed: result.allowed, retryAfterMs: result.retryAfterMs };
    });
  }

  private recordRef(uid: string, id: string) {
    return this.db.collection(USERS).doc(uid).collection(isPushOnlyId(id) ? CHAT_PUSHES : NOTIFICATIONS).doc(id);
  }

  async recipient(uid: string): Promise<Recipient | null> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return null;
    const d = snap.data() ?? {};
    return {
      uid,
      status: text(d.status) ?? "unverified",
      banned: d.banned === true,
      language: asLanguage(d.language),
      phone: text(d.phone),
      whatsappOptIn: d.whatsappOptIn === true,
    };
  }

  async settings(uid: string): Promise<NotificationSettings> {
    const snap = await this.db.collection(NOTIFICATION_SETTINGS).doc(uid).get();
    return settingsFrom(snap.exists ? snap.data() : null);
  }

  async saveSettings(uid: string, s: NotificationSettings): Promise<void> {
    await this.db.collection(NOTIFICATION_SETTINGS).doc(uid).set({ ...settingsToDoc(s), updatedAt: FieldValue.serverTimestamp() });
  }

  async tokens(uid: string): Promise<PushToken[]> {
    const snap = await this.db.collection(PUSH_TOKENS).where("uid", "==", uid).limit(MAX_DEVICES * 2).get();
    return snap.docs.map((d) => ({ key: d.id, token: text(d.get("token")) ?? "" })).filter((t) => t.token.length > 0);
  }

  async deleteTokens(keys: string[]): Promise<void> {
    const batch = this.db.batch();
    for (const key of keys) batch.delete(this.db.collection(PUSH_TOKENS).doc(key));
    await batch.commit();
  }

  /**
   * Saves [token] for [uid] (a phone that signed in as another parent moves
   * to this one), drops [previous] after a token refresh, and keeps at most
   * MAX_DEVICES phones per parent (oldest out).
   */
  async registerToken(uid: string, token: string, platform: string, previous: string | null, nowMs: number): Promise<void> {
    const key = tokenKey(token);
    await this.db.collection(PUSH_TOKENS).doc(key).set({ uid, token, platform, updatedAt: ts(nowMs) });
    if (previous && previous !== token) {
      const old = await this.db.collection(PUSH_TOKENS).doc(tokenKey(previous)).get();
      if (old.exists && old.get("uid") === uid) await old.ref.delete();
    }
    const mine = await this.db.collection(PUSH_TOKENS).where("uid", "==", uid).limit(MAX_DEVICES * 3).get();
    if (mine.size > MAX_DEVICES) {
      const oldest = [...mine.docs].sort((a, b) => (ms(a.get("updatedAt")) ?? 0) - (ms(b.get("updatedAt")) ?? 0));
      await this.deleteTokens(oldest.slice(0, mine.size - MAX_DEVICES).map((d) => d.id));
    }
  }

  /** Sign-out: removes the phone's token when it belongs to [uid]. */
  async unregisterToken(uid: string, token: string): Promise<boolean> {
    const ref = this.db.collection(PUSH_TOKENS).doc(tokenKey(token));
    const snap = await ref.get();
    if (!snap.exists || snap.get("uid") !== uid) return false;
    await ref.delete();
    return true;
  }

  async ensureRecord(record: NotificationRecord): Promise<NotificationRecord> {
    const ref = this.recordRef(record.uid, record.id);
    try {
      const doc = recordToDoc(record);
      // Chat pushes: kept only long enough to stop a retried webhook pushing twice.
      if (isPushOnlyId(record.id)) doc.expiresAt = ts(record.createdAtMs + CHAT_PUSH_TTL_DAYS * DAY);
      await ref.create(doc);
      return record;
    } catch (error) {
      if (!isAlreadyExists(error)) throw error;
      const snap = await ref.get();
      return recordFromDoc(record.uid, record.id, snap.data() ?? {}) ?? record;
    }
  }

  async record(uid: string, id: string): Promise<NotificationRecord | null> {
    const snap = await this.recordRef(uid, id).get();
    return snap.exists ? recordFromDoc(uid, id, snap.data() ?? {}) : null;
  }

  claim(uid: string, id: string, channel: Channel, nowMs: number, maxAttempts: number): Promise<boolean> {
    const ref = this.recordRef(uid, id);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return false;
      const current = channelFromDoc(snap.get(channel));
      if (current && !(current.state === "failed" && current.attempts < maxAttempts)) return false;
      const next: ChannelRecord = { state: "sending", attempts: (current?.attempts ?? 0) + 1, reason: null, atMs: nowMs };
      tx.update(ref, { [channel]: channelToDoc(next) });
      return true;
    });
  }

  async finish(uid: string, id: string, channel: Channel, state: Exclude<ChannelState, "sending">, reason: string | null, nowMs: number): Promise<void> {
    await this.recordRef(uid, id).update({ [`${channel}.state`]: state, [`${channel}.reason`]: reason, [`${channel}.at`]: ts(nowMs) });
  }

  async setAlarmState(uid: string, id: string, state: "sent" | "cancelled"): Promise<void> {
    await this.recordRef(uid, id).update({ alarmState: state });
  }

  async nearbySubject(uid: string): Promise<{ verified: boolean; showOnMap: boolean } | null> {
    const snap = await this.db.collection(PARENT_LOCATIONS).doc(uid).get();
    const p = snap.exists ? publicFromDoc(snap.data() ?? {}) : null;
    return p ? { verified: p.verified, showOnMap: p.showOnMap } : null;
  }

  async parentsAtSchool(schoolId: string, limit: number): Promise<NearbyParent[]> {
    const snap = await this.db.collection(PARENT_LOCATIONS).where("schoolIds", "array-contains", schoolId).limit(limit).get();
    const out: NearbyParent[] = [];
    for (const d of snap.docs) {
      const p = publicFromDoc(d.data());
      if (p) out.push({ uid: d.id, point: p.point, radiusKm: p.radiusKm, verified: p.verified, notifyNewParents: p.notifyNewParents });
    }
    return out;
  }

  async markEvent(id: string, status: "done" | "failed", summary: DispatchSummary): Promise<void> {
    await this.db.collection(NOTIFICATION_EVENTS).doc(id).update({ status, summary, sentAt: FieldValue.serverTimestamp() });
  }

  // ---- tick ----

  async confirmedRuns(fromMs: number, toMs: number, limit: number): Promise<RunLite[]> {
    const snap = await this.db
      .collectionGroup(SCHEDULE)
      .where("status", "==", "confirmed")
      .where("startAt", ">=", ts(fromMs))
      .where("startAt", "<", ts(toMs))
      .limit(limit)
      .get();
    return snap.docs.map((d) => runLite(text(d.get("carpoolId")) ?? "", d.id, d.data()));
  }

  async plannedRuns(fromMs: number, toMs: number, limit: number): Promise<RunLite[]> {
    const snap = await this.db
      .collectionGroup(SCHEDULE)
      .where("status", "==", "planned")
      .where("confirmBy", ">=", ts(fromMs))
      .where("confirmBy", "<", ts(toMs))
      .limit(limit)
      .get();
    return snap.docs.map((d) => runLite(text(d.get("carpoolId")) ?? "", d.id, d.data()));
  }

  async createEvent(event: OutboxEvent): Promise<boolean> {
    try {
      await this.db.collection(NOTIFICATION_EVENTS).doc(event.id).create(outboxDoc(event));
      return true;
    } catch (error) {
      if (isAlreadyExists(error)) return false;
      throw error;
    }
  }

  async dueAlarms(nowMs: number, limit: number): Promise<Array<{ uid: string; id: string }>> {
    const snap = await this.db
      .collectionGroup(NOTIFICATIONS)
      .where("alarmState", "==", "waiting")
      .where("alarmAt", "<=", ts(nowMs))
      .limit(limit)
      .get();
    const out: Array<{ uid: string; id: string }> = [];
    for (const d of snap.docs) {
      // users/{uid}/notifications/{id}
      const uid = (d.ref as unknown as { parent?: { parent?: { id?: string } } }).parent?.parent?.id;
      if (uid) out.push({ uid, id: d.id });
    }
    return out;
  }

  escalate(uid: string, id: string, alarm: OutboxEvent): Promise<"escalated" | "cancelled" | "gone"> {
    const ref = this.recordRef(uid, id);
    const eventRef = this.db.collection(NOTIFICATION_EVENTS).doc(alarm.id);
    return this.db.runTransaction(async (tx) => {
      const [snap, existing] = await Promise.all([tx.get(ref), tx.get(eventRef)]);
      if (!snap.exists || snap.get("alarmState") !== "waiting") return "gone" as const;
      if (snap.get("readAt")) {
        tx.update(ref, { alarmState: "cancelled" });
        return "cancelled" as const;
      }
      tx.update(ref, { alarmState: "escalated" });
      if (!existing.exists) tx.create(eventRef, outboxDoc(alarm));
      return "escalated" as const;
    });
  }
}
