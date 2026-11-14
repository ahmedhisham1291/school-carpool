import type { Channel, DispatchSummary, NearbyParent, NotifyStore, PushResult, PushSender, PushToken, WhatsAppNotifier } from "../../src/notifications/dispatch";
import type { DeviceStore, NotificationLimitKind } from "../../src/notifications/devices";
import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";
import {
  defaultSettings,
  type ChannelRecord,
  type ChannelState,
  type NotificationRecord,
  type NotificationSettings,
  type OutboxEvent,
  type PushMessage,
  type Recipient,
} from "../../src/notifications/model";
import type { RunLite, TickStore } from "../../src/notifications/tick";
import type { Language } from "../../src/whatsapp/sender";

const clone = <T>(v: T): T => structuredClone(v);

/** In-memory notification store for unit tests (fake data only). */
export class MemoryNotifyStore implements NotifyStore, TickStore, DeviceStore {
  recipients = new Map<string, Recipient>();
  settingsByUid = new Map<string, NotificationSettings>();
  /** token key -> { uid, token, platform, updatedAtMs } */
  tokensByKey = new Map<string, { uid: string; token: string; platform: string; updatedAtMs: number }>();
  records = new Map<string, NotificationRecord>();
  events = new Map<string, OutboxEvent>();
  marked = new Map<string, { status: string; summary: DispatchSummary }>();
  locations = new Map<string, NearbyParent & { showOnMap: boolean; schoolIds: string[] }>();
  runs: RunLite[] = [];
  limits = new Map<string, WindowCounter>();
  consents: Array<{ uid: string; type: string; source: string; acceptedAtMs: number; withdrawnAtMs: number | null }> = [];
  confirmedQueries = 0;

  private key(uid: string, id: string): string {
    return `${uid}/${id}`;
  }

  addParent(uid: string, extra: Partial<Recipient> = {}): void {
    this.recipients.set(uid, {
      uid,
      status: "verified",
      banned: false,
      language: "en",
      phone: `+2010000000${String(this.recipients.size).padStart(2, "0")}`,
      whatsappOptIn: true,
      ...extra,
    });
    this.tokensByKey.set(`key-${uid}`, { uid, token: `token-${uid}-aaaaaaaaaaaaaaaaaaaa`, platform: "ios", updatedAtMs: 0 });
  }

  async recipient(uid: string): Promise<Recipient | null> {
    const r = this.recipients.get(uid);
    return r ? clone(r) : null;
  }

  async settings(uid: string): Promise<NotificationSettings> {
    return clone(this.settingsByUid.get(uid) ?? defaultSettings());
  }

  async saveSettings(uid: string, s: NotificationSettings): Promise<void> {
    this.settingsByUid.set(uid, clone(s));
  }

  async tokens(uid: string): Promise<PushToken[]> {
    return [...this.tokensByKey.entries()].filter(([, t]) => t.uid === uid).map(([key, t]) => ({ key, token: t.token }));
  }

  async deleteTokens(keys: string[]): Promise<void> {
    for (const k of keys) this.tokensByKey.delete(k);
  }

  async registerToken(uid: string, token: string, platform: string, previous: string | null, nowMs: number): Promise<void> {
    this.tokensByKey.set(`k:${token}`, { uid, token, platform, updatedAtMs: nowMs });
    if (previous && previous !== token && this.tokensByKey.get(`k:${previous}`)?.uid === uid) this.tokensByKey.delete(`k:${previous}`);
  }

  async setWhatsAppConsent(uid: string, accept: boolean, nowMs: number): Promise<void> {
    const r = this.recipients.get(uid);
    if (!r) throw new Error("no account record");
    const open = this.consents.filter((c) => c.uid === uid && c.type === "whatsapp" && c.withdrawnAtMs === null);
    if (accept && open.length === 0) this.consents.push({ uid, type: "whatsapp", source: "settings", acceptedAtMs: nowMs, withdrawnAtMs: null });
    if (!accept) for (const c of open) c.withdrawnAtMs = nowMs;
    r.whatsappOptIn = accept;
  }

  async unregisterToken(uid: string, token: string): Promise<boolean> {
    const t = this.tokensByKey.get(`k:${token}`);
    if (!t || t.uid !== uid) return false;
    this.tokensByKey.delete(`k:${token}`);
    return true;
  }

  async takeLimit(uid: string, kind: NotificationLimitKind, nowMs: number, rule: { windowMs: number; max: number }) {
    const k = `${uid}:${kind}`;
    const r = takeFromWindow(this.limits.get(k), nowMs, rule);
    if (r.allowed) this.limits.set(k, r.next);
    return { allowed: r.allowed, retryAfterMs: r.retryAfterMs };
  }

  async ensureRecord(record: NotificationRecord): Promise<NotificationRecord> {
    const k = this.key(record.uid, record.id);
    const existing = this.records.get(k);
    if (existing) return clone(existing);
    this.records.set(k, clone(record));
    return clone(record);
  }

  async record(uid: string, id: string): Promise<NotificationRecord | null> {
    const r = this.records.get(this.key(uid, id));
    return r ? clone(r) : null;
  }

  async claim(uid: string, id: string, channel: Channel, nowMs: number, maxAttempts: number): Promise<boolean> {
    const r = this.records.get(this.key(uid, id));
    if (!r) return false;
    const current = r[channel];
    if (current && !(current.state === "failed" && current.attempts < maxAttempts)) return false;
    r[channel] = { state: "sending", attempts: (current?.attempts ?? 0) + 1, reason: null, atMs: nowMs };
    return true;
  }

  async finish(uid: string, id: string, channel: Channel, state: Exclude<ChannelState, "sending">, reason: string | null, nowMs: number): Promise<void> {
    const r = this.records.get(this.key(uid, id));
    if (!r) throw new Error("no record");
    const c = r[channel] as ChannelRecord;
    r[channel] = { ...c, state, reason, atMs: nowMs };
  }

  async setAlarmState(uid: string, id: string, state: "sent" | "cancelled"): Promise<void> {
    const r = this.records.get(this.key(uid, id));
    if (r) r.alarmState = state;
  }

  async nearbySubject(uid: string) {
    const l = this.locations.get(uid);
    return l ? { verified: l.verified, showOnMap: l.showOnMap } : null;
  }

  async parentsAtSchool(schoolId: string, limit: number): Promise<NearbyParent[]> {
    return [...this.locations.values()]
      .filter((l) => l.schoolIds.includes(schoolId))
      .slice(0, limit)
      .map((l) => ({ uid: l.uid, point: l.point, radiusKm: l.radiusKm, verified: l.verified, notifyNewParents: l.notifyNewParents }));
  }

  async markEvent(id: string, status: "done" | "failed", summary: DispatchSummary): Promise<void> {
    this.marked.set(id, { status, summary: clone(summary) });
    const e = this.events.get(id);
    if (e) e.status = status;
  }

  // ---- tick ----
  async confirmedRuns(fromMs: number, toMs: number, limit: number): Promise<RunLite[]> {
    this.confirmedQueries += 1;
    return this.runs.filter((r) => r.status === "confirmed" && r.startMs >= fromMs && r.startMs < toMs).slice(0, limit);
  }

  async plannedRuns(fromMs: number, toMs: number, limit: number): Promise<RunLite[]> {
    return this.runs.filter((r) => r.status === "planned" && r.confirmByMs >= fromMs && r.confirmByMs < toMs).slice(0, limit);
  }

  async createEvent(event: OutboxEvent): Promise<boolean> {
    if (this.events.has(event.id)) return false;
    this.events.set(event.id, clone(event));
    return true;
  }

  async dueAlarms(nowMs: number, limit: number): Promise<Array<{ uid: string; id: string }>> {
    return [...this.records.values()]
      .filter((r) => r.alarmState === "waiting" && r.alarmAtMs !== null && r.alarmAtMs <= nowMs)
      .slice(0, limit)
      .map((r) => ({ uid: r.uid, id: r.id }));
  }

  async escalate(uid: string, id: string, alarm: OutboxEvent): Promise<"escalated" | "cancelled" | "gone"> {
    const r = this.records.get(this.key(uid, id));
    if (!r || r.alarmState !== "waiting") return "gone";
    if (r.readAtMs !== null) {
      r.alarmState = "cancelled";
      return "cancelled";
    }
    r.alarmState = "escalated";
    if (!this.events.has(alarm.id)) this.events.set(alarm.id, clone(alarm));
    return "escalated";
  }

  /** The app marks a record read (the only change firestore.rules allow). */
  read(uid: string, id: string, atMs: number): void {
    const r = this.records.get(this.key(uid, id));
    if (r) r.readAtMs = atMs;
  }

  recordsOf(uid: string): NotificationRecord[] {
    return [...this.records.values()].filter((r) => r.uid === uid);
  }
}

/** Records every push; [failures] makes the next sends throw. */
export class RecordingPush implements PushSender {
  readonly kind = "fake";
  readonly sent: Array<{ tokens: PushToken[]; message: PushMessage }> = [];
  failures = 0;
  dead = new Set<string>();

  async send(tokens: PushToken[], message: PushMessage): Promise<PushResult> {
    if (this.failures > 0) {
      this.failures -= 1;
      throw new Error("FCM unavailable");
    }
    const live = tokens.filter((t) => !this.dead.has(t.key));
    if (live.length > 0) this.sent.push({ tokens: structuredClone(live), message: structuredClone(message) });
    return { sent: live.length, invalid: tokens.filter((t) => this.dead.has(t.key)).map((t) => t.key) };
  }
}

export class RecordingWhatsApp implements WhatsAppNotifier {
  readonly sent: Array<{ to: string; template: string; language: Language; params: string[]; preview: string }> = [];
  failures = 0;

  async sendTemplate(to: string, template: string, language: Language, params: string[], preview: string): Promise<void> {
    if (this.failures > 0) {
      this.failures -= 1;
      throw new Error("WhatsApp unavailable");
    }
    this.sent.push({ to, template, language, params: [...params], preview });
  }
}
