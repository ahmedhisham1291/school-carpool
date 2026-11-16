import { featureOn } from "../features/gate";
import { notificationFeature } from "../features/model";
import * as logger from "firebase-functions/logger";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { adminApp, adminDb } from "../admin";
import {
  ENFORCE_APP_CHECK,
  MIN_INSTANCES,
  NOTIFY_ALARM_DELAY_MIN,
  NOTIFY_DEVICE_CHANGES_PER_DAY,
  NOTIFY_SETTINGS_CHANGES_PER_DAY,
  REGION,
  REMINDER_EVENING_AT,
  PUSH_PROVIDER,
  WHATSAPP_ACCESS_TOKEN,
  WHATSAPP_API_VERSION,
  WHATSAPP_CODE_TEMPLATE,
  WHATSAPP_PHONE_NUMBER_ID,
  WHATSAPP_PROVIDER,
  WHATSAPP_TEMPLATE_LANG_AR,
  WHATSAPP_TEMPLATE_LANG_EN,
} from "../config";
import { CAIRO_TZ } from "../schedule/cairo";
import { reportError } from "../sentry";
import { createWhatsAppSender } from "../whatsapp/sender";
import { DeviceError, registerDevice, setWhatsAppConsent, unregisterDevice, updateSettings, type DeviceDeps } from "./devices";
import { dispatchEvent, RetryableDispatchError, type DispatchDeps } from "./dispatch";
import { DEFAULT_ALARM_DELAY_MIN, eventFromDoc } from "./model";
import { createPushSender } from "./push";
import { FirestoreNotifyStore } from "./store";
import { runNotificationTick } from "./tick";
import { gatedCall, sessionCall } from "../privacy/device_gate";
import { requireUid, runCallable } from "../common/callable";

/**
 * Notifications (Prompt 8: F12, F23).
 *
 * sendNotification is the ONE function that sends notifications: every
 * producer writes an event to notificationEvents and this trigger writes
 * the in-app record, sends the push and, when the parent has that group
 * on, the WhatsApp template. retry: true, so a failed channel is tried
 * again; channels already sent are never sent twice (dispatch.ts).
 *
 * Logs: types, counts and error messages only (no names, phone numbers,
 * tokens or text).
 */

const alarmDelayMs = (): number => {
  const v = NOTIFY_ALARM_DELAY_MIN.value();
  return (Number.isInteger(v) && v >= 5 && v <= 120 ? v : DEFAULT_ALARM_DELAY_MIN) * 60_000;
};

function dispatchDeps(): DispatchDeps {
  const appEnv = process.env.APP_ENV ?? "dev";
  const log = (message: string) => logger.info(message);
  const phoneNumberId = WHATSAPP_PHONE_NUMBER_ID.value();
  return {
    store: new FirestoreNotifyStore(adminDb()),
    push: createPushSender(PUSH_PROVIDER.value(), appEnv, adminApp, log),
    whatsapp: createWhatsAppSender(
      {
        provider: WHATSAPP_PROVIDER.value(),
        appEnv,
        meta: {
          accessToken: WHATSAPP_ACCESS_TOKEN.value(),
          phoneNumberId: phoneNumberId === "none" ? "" : phoneNumberId,
          apiVersion: WHATSAPP_API_VERSION.value(),
          templateName: WHATSAPP_CODE_TEMPLATE.value(),
          templateLanguages: { ar: WHATSAPP_TEMPLATE_LANG_AR.value(), en: WHATSAPP_TEMPLATE_LANG_EN.value() },
        },
      },
      log,
    ),
    now: () => Date.now(),
    log: (message, data) => logger.info(message, data ?? {}),
    alarmDelayMs: alarmDelayMs(),
    typeAllowed: async (type) => {
      const feature = notificationFeature(type);
      return feature === null || featureOn(feature);
    },
  };
}

export const sendNotification = onDocumentCreated(
  { document: "notificationEvents/{eventId}", region: REGION, retry: true, secrets: [WHATSAPP_ACCESS_TOKEN], minInstances: MIN_INSTANCES },
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const id = (event.params as Record<string, string>).eventId;
    const data = snap.data() ?? {};
    const created = (data.createdAt as { toMillis?: () => number } | undefined)?.toMillis?.() ?? Date.now();
    const outbox = eventFromDoc(id, data, created);
    if (!outbox) {
      logger.warn("notification event with an unknown type dropped");
      return;
    }
    try {
      await dispatchEvent(dispatchDeps(), outbox);
    } catch (error) {
      if (error instanceof RetryableDispatchError) {
        logger.warn("notification will be retried", { type: outbox.type, ...error.summary });
        throw error;
      }
      logger.error("sendNotification failed", { type: outbox.type, message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);

/**
 * Every 5 minutes, Cairo time: driver reminders (evening before, one hour
 * before, missing confirmation) and the alarm for critical alerts nobody
 * opened. Writes events only; sendNotification sends them.
 */
export const notificationTick = onSchedule(
  { schedule: "every 5 minutes", timeZone: CAIRO_TZ, retryCount: 1, timeoutSeconds: 120, minInstances: MIN_INSTANCES },
  async () => {
    try {
      const result = await runNotificationTick({
        store: new FirestoreNotifyStore(adminDb()),
        now: () => Date.now(),
        eveningAt: REMINDER_EVENING_AT.value(),
      });
      logger.info("notification tick", result);
    } catch (error) {
      logger.error("notification tick failed", { message: error instanceof Error ? error.message : "unknown" });
      await reportError(error);
      throw error;
    }
  },
);

function deviceDeps(): DeviceDeps {
  return {
    store: new FirestoreNotifyStore(adminDb()),
    now: () => Date.now(),
    limits: {
      deviceChangesPerDay: NOTIFY_DEVICE_CHANGES_PER_DAY.value(),
      settingsChangesPerDay: NOTIFY_SETTINGS_CHANGES_PER_DAY.value(),
    },
  };
}

function uidOf(request: CallableRequest): string {
  return requireUid(request);
}

/** A rate limit is "resource-exhausted" (with retryAfterSeconds); any other device error is "invalid-argument". */
function deviceErrorMapper(error: unknown): HttpsError | undefined {
  if (!(error instanceof DeviceError)) return undefined;
  return new HttpsError(error.reason === "rate-limited" ? "resource-exhausted" : "invalid-argument", error.reason, {
    reason: error.reason,
    retryAfterSeconds: Math.ceil(error.retryAfterMs / 1000),
  });
}

function run<T>(name: string, body: () => Promise<T>): Promise<T> {
  return runCallable(name, body, { map: [deviceErrorMapper] });
}

const opts = { enforceAppCheck: ENFORCE_APP_CHECK };

/** { token, platform, previousToken? } -> { registered } */
export const registerPushDevice = gatedCall(opts, (r) => run("registerPushDevice", () => registerDevice(deviceDeps(), uidOf(r), r.data)));

/** { token } -> { removed } (before signing out) */
export const unregisterPushDevice = onCall(opts, (r) => run("unregisterPushDevice", () => unregisterDevice(deviceDeps(), uidOf(r), r.data)));

/** { whatsapp?: { group: bool }, quiet?: { on?, from?, to? } } -> the settings */
export const updateNotificationSettings = sessionCall(opts, (r) =>
  run("updateNotificationSettings", () => updateSettings(deviceDeps(), uidOf(r), r.data)),
);

/** { accept } -> { whatsappOptIn } (WhatsApp consent after sign-up, or withdrawn) */
export const setWhatsAppNotifications = gatedCall(opts, (r) =>
  run("setWhatsAppNotifications", () => setWhatsAppConsent(deviceDeps(), uidOf(r), r.data)),
);
