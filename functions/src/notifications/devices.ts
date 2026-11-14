import { applySettingsChange, settingsView, type NotificationSettings } from "./model";

/**
 * Phones and settings (Prompt 8). Called by registerPushDevice,
 * unregisterPushDevice and updateNotificationSettings (the app reads its
 * own notificationSettings/{uid} directly; firestore.rules). Limits are counted on the server in
 * notificationLimits/{uid} (functions only).
 *
 * Tokens: one document per FCM token (key: sha256 of the token), so a phone
 * that signs in as another parent moves to that parent and never gets the
 * first parent's notifications. Sign-out removes the token (the app calls
 * unregister, then deletes the token on the phone). FCM's "not registered"
 * answers remove dead tokens while sending.
 */

export type NotificationLimitKind = "devices" | "settings";

export interface DeviceStore {
  takeLimit(uid: string, kind: NotificationLimitKind, nowMs: number, rule: { windowMs: number; max: number }): Promise<{ allowed: boolean; retryAfterMs: number }>;
  registerToken(uid: string, token: string, platform: string, previous: string | null, nowMs: number): Promise<void>;
  unregisterToken(uid: string, token: string): Promise<boolean>;
  settings(uid: string): Promise<NotificationSettings>;
  saveSettings(uid: string, s: NotificationSettings): Promise<void>;
  /**
   * The WhatsApp consent after sign-up: [accept] adds a consent record
   * (users/{uid}/consents, type "whatsapp", source "settings") and sets
   * whatsappOptIn; withdrawing sets withdrawnAt on the open whatsapp
   * records and clears whatsappOptIn. One transaction.
   */
  setWhatsAppConsent(uid: string, accept: boolean, nowMs: number): Promise<void>;
}

export interface DeviceDeps {
  store: DeviceStore;
  now: () => number;
  limits: { deviceChangesPerDay: number; settingsChangesPerDay: number };
}

export type DeviceErrorReason = "invalid-request" | "rate-limited";

export class DeviceError extends Error {
  constructor(
    readonly reason: DeviceErrorReason,
    readonly retryAfterMs = 0,
  ) {
    super(reason);
  }
}

const DAY = 86_400_000;
/** FCM tokens are long base64url-like strings; anything else is refused. */
const TOKEN = /^[A-Za-z0-9_:\-.]{20,4096}$/;
const PLATFORMS = ["ios", "android", "web"] as const;

function input(data: unknown): Record<string, unknown> {
  if (typeof data !== "object" || data === null) throw new DeviceError("invalid-request");
  return data as Record<string, unknown>;
}

async function take(deps: DeviceDeps, uid: string, kind: NotificationLimitKind, max: number): Promise<void> {
  const r = await deps.store.takeLimit(uid, kind, deps.now(), { windowMs: DAY, max });
  if (!r.allowed) throw new DeviceError("rate-limited", r.retryAfterMs);
}

/** { token, platform, previousToken? } -> { registered: true } */
export async function registerDevice(deps: DeviceDeps, uid: string, data: unknown): Promise<{ registered: true }> {
  const raw = input(data);
  const token = raw.token;
  const platform = raw.platform;
  const previous = raw.previousToken ?? null;
  if (typeof token !== "string" || !TOKEN.test(token)) throw new DeviceError("invalid-request");
  if (typeof platform !== "string" || !(PLATFORMS as readonly string[]).includes(platform)) throw new DeviceError("invalid-request");
  if (previous !== null && (typeof previous !== "string" || !TOKEN.test(previous))) throw new DeviceError("invalid-request");
  await take(deps, uid, "devices", deps.limits.deviceChangesPerDay);
  await deps.store.registerToken(uid, token, platform, previous as string | null, deps.now());
  return { registered: true };
}

/** { token } -> { removed } (sign-out). Not limited: signing out must always work. */
export async function unregisterDevice(deps: DeviceDeps, uid: string, data: unknown): Promise<{ removed: boolean }> {
  const token = input(data).token;
  if (typeof token !== "string" || !TOKEN.test(token)) throw new DeviceError("invalid-request");
  return { removed: await deps.store.unregisterToken(uid, token) };
}

/**
 * { accept: bool } -> { whatsappOptIn }. Lets a parent who said no to
 * WhatsApp at sign-up agree later (spec section 7: consent, and withdraw it
 * at any time). Counted with the settings changes.
 */
export async function setWhatsAppConsent(deps: DeviceDeps, uid: string, data: unknown): Promise<{ whatsappOptIn: boolean }> {
  const accept = input(data).accept;
  if (typeof accept !== "boolean") throw new DeviceError("invalid-request");
  await take(deps, uid, "settings", deps.limits.settingsChangesPerDay);
  await deps.store.setWhatsAppConsent(uid, accept, deps.now());
  return { whatsappOptIn: accept };
}

/** { whatsapp?: { group: bool }, quiet?: { on?, from?, to? } } -> the settings */
export async function updateSettings(deps: DeviceDeps, uid: string, data: unknown): Promise<Record<string, unknown>> {
  let next: NotificationSettings;
  try {
    next = applySettingsChange(await deps.store.settings(uid), data);
  } catch {
    throw new DeviceError("invalid-request");
  }
  await take(deps, uid, "settings", deps.limits.settingsChangesPerDay);
  await deps.store.saveSettings(uid, next);
  return settingsView(next);
}
