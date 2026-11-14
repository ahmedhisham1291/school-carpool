import { newEvent } from "../notifications/model";
import { isMuted, parseCid, SYSTEM_USER_ID } from "./model";
import type { ChatStore } from "./store";

/**
 * Stream webhook (Prompt 9). Stream sends every new message here (its own
 * push is off), and chat push goes through OUR sender (Prompt 8): one
 * "chat-message" outbox event per message, so the push text is the fixed
 * "You have a new message" and never the message, a name or a photo.
 *
 * The signature is checked before this runs (callables.ts,
 * verifyWebhookSignature). Recipients: the channel's members in OUR
 * registry, minus the sender, minus parents who muted that chat (large
 * school and area groups start muted), minus parents who blocked the
 * sender. The event ID is the message ID, so a webhook Stream sends twice
 * makes one push.
 */

export interface WebhookDeps {
  store: ChatStore;
  now: () => number;
  log: (message: string, data?: Record<string, unknown>) => void;
}

export interface WebhookResult {
  handled: boolean;
  recipients: number;
  reason: string | null;
}

const MESSAGE_ID = /^[A-Za-z0-9_-]{1,100}$/;

export async function handleWebhook(deps: WebhookDeps, body: unknown): Promise<WebhookResult> {
  const skip = (reason: string): WebhookResult => ({ handled: false, recipients: 0, reason });
  if (typeof body !== "object" || body === null) return skip("bad-body");
  const b = body as Record<string, unknown>;
  if (b.type !== "message.new") return skip("ignored-type");
  const message = (b.message ?? {}) as Record<string, unknown>;
  const user = (message.user ?? b.user ?? {}) as Record<string, unknown>;
  const senderUid = typeof user.id === "string" ? user.id : "";
  const messageId = typeof message.id === "string" ? message.id : "";
  if (!MESSAGE_ID.test(messageId)) return skip("bad-message");
  // System messages, our own system user and silent messages notify nobody.
  if (message.type === "system" || message.silent === true || senderUid === SYSTEM_USER_ID || senderUid === "") return skip("not-a-parent-message");
  // Thread replies not shown in the channel are not used by the app.
  if (typeof message.parent_id === "string" && message.show_in_channel !== true) return skip("thread-reply");

  const cid = typeof b.cid === "string" ? b.cid : `${String(b.channel_type ?? "")}:${String(b.channel_id ?? "")}`;
  const ref = parseCid(cid);
  if (!ref) return skip("unknown-channel");
  const channel = await deps.store.channel(ref.cid);
  if (!channel || !channel.members.includes(senderUid)) return skip("not-member");

  const [choices, blockers] = await Promise.all([deps.store.muteChoices(ref.cid), deps.store.blockersOf(senderUid)]);
  const blocked = new Set(blockers);
  const recipients = channel.members.filter(
    (uid) => uid !== senderUid && !blocked.has(uid) && !isMuted(ref.kind, channel.members.length, choices.get(uid) ?? null),
  );
  if (recipients.length === 0) return { handled: true, recipients: 0, reason: "nobody" };

  const event = newEvent(`chat_${messageId}`, "chat-message", recipients, deps.now(), {
    actorUid: senderUid,
    carpoolId: ref.kind === "carpool" ? channel.refId : null,
    chatCid: ref.cid,
  });
  const created = await deps.store.createEvent(event);
  deps.log("chat message push queued", { kind: ref.kind, recipients: recipients.length, duplicate: !created });
  return { handled: created, recipients: recipients.length, reason: created ? null : "duplicate" };
}
