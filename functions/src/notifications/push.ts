import type { App } from "firebase-admin/app";
import { getMessaging } from "firebase-admin/messaging";
import type { PushMessage } from "./model";
import type { PushResult, PushSender, PushToken } from "./dispatch";

/**
 * Push through Firebase Cloud Messaging (APNs on the iPhone: the APNs key
 * is uploaded to each Firebase project, SETUP.md section 18).
 *
 * - FakePushSender (dev on the emulators, CI): logs the type, the level and
 *   the number of phones. Nothing is sent and no token is logged.
 * - FcmPushSender: FCM HTTP v1 through the Admin SDK, one message per phone.
 *
 * COST MODE: FCM is free.
 */

/** FCM error codes that mean the token will never work again. */
const DEAD_TOKEN = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

export class FakePushSender implements PushSender {
  readonly kind = "fake";
  readonly sent: Array<{ tokens: number; message: PushMessage }> = [];

  constructor(private readonly log: (message: string) => void) {}

  async send(tokens: PushToken[], message: PushMessage): Promise<PushResult> {
    this.sent.push({ tokens: tokens.length, message });
    this.log(
      `[fake push] ${message.data.type} (${message.level}${message.sound ? ", sound" : ", silent"}${message.data.alarm === "1" ? ", alarm" : ""}) ` +
        `to ${tokens.length} phone(s): "${message.title}". Nothing was sent.`,
    );
    return { sent: tokens.length, invalid: [] };
  }
}

/** The FCM message for one phone (exported for tests). */
export function fcmMessage(token: string, m: PushMessage): Record<string, unknown> {
  return {
    token,
    notification: { title: m.title, body: m.body },
    data: { ...m.data },
    apns: {
      headers: {
        "apns-push-type": "alert",
        "apns-priority": m.level === "passive" ? "5" : "10",
      },
      payload: {
        aps: {
          ...(m.sound ? { sound: "default" } : {}),
          threadId: m.threadId,
          ...(m.contentAvailable ? { contentAvailable: true } : {}),
          // iOS 15+: time-sensitive alerts break through Focus (needs the
          // Time Sensitive Notifications capability, SETUP.md section 18).
          "interruption-level": m.level,
        },
      },
    },
    android: {
      priority: m.level === "passive" ? "normal" : "high",
      notification: {
        channelId: m.level === "time-sensitive" ? "critical" : m.sound ? "general" : "quiet",
        ...(m.sound ? { sound: "default" } : {}),
        tag: m.data.notificationId,
      },
    },
  };
}

export class FcmPushSender implements PushSender {
  readonly kind = "fcm";

  constructor(private readonly app: App) {}

  async send(tokens: PushToken[], message: PushMessage): Promise<PushResult> {
    const messages = tokens.map((t) => fcmMessage(t.token, message));
    // Typed loosely: the APNs interruption level is a custom aps key.
    const response = await getMessaging(this.app).sendEach(messages as never);
    const invalid: string[] = [];
    response.responses.forEach((r, i) => {
      if (!r.success && r.error && DEAD_TOKEN.has(r.error.code)) invalid.push(tokens[i].key);
    });
    return { sent: response.successCount, invalid };
  }
}

/** PUSH_PROVIDER: "fake" (refused in prod) or "fcm". */
export function createPushSender(provider: string, appEnv: string, app: () => App, log: (message: string) => void): PushSender {
  if (provider === "fake") {
    if (appEnv === "prod") throw new Error("The fake push sender is not allowed in prod (set PUSH_PROVIDER=fcm)");
    return new FakePushSender(log);
  }
  if (provider === "fcm") return new FcmPushSender(app());
  throw new Error(`Unknown PUSH_PROVIDER "${provider}"`);
}
