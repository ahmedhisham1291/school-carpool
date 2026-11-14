import { createHash } from "node:crypto";
import { newEvent } from "../notifications/model";
import { MESSAGE_KINDS, photoPathOk, type ChatData, type MessageKind, type StoredMessage } from "./data";
import { hasBlockedTerm } from "./moderation";
import { isMuted, isSmallChat, MESSAGE_TEXT_MAX, parseCid, SMALL_CHAT_MAX, SYSTEM_USER_ID } from "./model";
import { previewOf, type ChatServer } from "./server";
import type { ChatStore } from "./store";

/**
 * What happens after a parent's phone wrote a message (the trigger on
 * chats/{cid}/messages/{id}, callables.ts). The phone writes the message
 * itself so sending feels instant and works offline; everything else is
 * here:
 *
 * 1. Checks the rules cannot do: the sender is in OUR registry, the
 *    sending limit (too fast: the message is removed and the sender cannot
 *    write for a while; the rules read `mutedUntil`), blocked terms.
 * 2. The chat's head: last message, time and message counter.
 * 3. Small chats: each member's chat list row (unread + 1, last message).
 *    School and area groups get no write per member (thousands of them);
 *    the app counts unread from the head's counter.
 * 4. Push through OUR sender (Prompt 8): one "chat-message" event, so the
 *    push text is the fixed "You have a new message" and never the
 *    message, a name or a photo. Recipients: the chat's members in our
 *    registry, minus the sender, minus parents who muted that chat (large
 *    school and area groups start muted), minus parents who blocked the
 *    sender.
 *
 * A trigger can be delivered twice: the head remembers the last message it
 * counted and the event ID is fixed per message. Logs: kinds and counts
 * only, never text, names or coordinates.
 */

export interface FanoutLimits {
  /** Messages a parent may send per minute, all chats together. */
  messagesPerMinute: number;
  /** How long a parent who went over cannot write. */
  muteMinutes: number;
}

export const DEFAULT_FANOUT_LIMITS: FanoutLimits = { messagesPerMinute: 30, muteMinutes: 10 };

export interface FanoutDeps {
  store: ChatStore;
  data: ChatData;
  server: ChatServer;
  limits: FanoutLimits;
  now: () => number;
  log: (message: string, data?: Record<string, unknown>) => void;
}

export interface FanoutResult {
  handled: boolean;
  recipients: number;
  /** Why nothing was sent, or why the message was removed. */
  reason: string | null;
  removed: boolean;
}

const MESSAGE_ID = /^[A-Za-z0-9_-]{1,100}$/;

/** The message document as stored, or null when it is not a valid message. */
export function messageFromDoc(id: string, d: Record<string, unknown> | undefined): StoredMessage | null {
  if (!d || !MESSAGE_ID.test(id)) return null;
  const kind = d.kind as MessageKind;
  if (!(MESSAGE_KINDS as readonly string[]).includes(kind)) return null;
  if (typeof d.senderUid !== "string" || d.senderUid.length === 0) return null;
  const at = d.createdAt as { toMillis?: () => number } | number | null | undefined;
  const createdAtMs = typeof at === "number" ? at : typeof at?.toMillis === "function" ? at.toMillis() : 0;
  return {
    id,
    senderUid: d.senderUid,
    kind,
    text: typeof d.text === "string" ? d.text : "",
    photoPath: typeof d.photoPath === "string" ? d.photoPath : null,
    lat: typeof d.lat === "number" ? d.lat : null,
    lng: typeof d.lng === "number" ? d.lng : null,
    createdAtMs,
  };
}

/** The same checks as firestore.rules, again (belt and braces). */
export function messageProblem(cid: string, small: boolean, m: StoredMessage): string | null {
  switch (m.kind) {
    case "text":
      // Counted in characters, as the rules count (an emoji is one).
      return m.text.length > 0 && Array.from(m.text).length <= MESSAGE_TEXT_MAX ? null : "bad-text";
    case "photo":
      return small && photoPathOk(cid, m.senderUid, m.id, m.photoPath) ? null : "bad-photo";
    case "location":
      return small && m.lat !== null && m.lng !== null && Math.abs(m.lat) <= 90 && Math.abs(m.lng) <= 180 ? null : "bad-location";
  }
}

/** One push event per message, whatever ID the phone chose. */
export function chatEventId(cid: string, messageId: string): string {
  return "chat_" + createHash("sha256").update(`${cid}/${messageId}`).digest("hex").slice(0, 40);
}

export async function onMessageCreated(deps: FanoutDeps, cid: string, messageId: string, doc: Record<string, unknown> | undefined): Promise<FanoutResult> {
  const out = (handled: boolean, recipients: number, reason: string | null, removed = false): FanoutResult => ({ handled, recipients, reason, removed });
  const ref = parseCid(cid);
  if (!ref) return out(false, 0, "unknown-chat");
  const remove = async (reason: string): Promise<FanoutResult> => {
    await deps.server.deleteMessage(ref.type, ref.id, messageId);
    deps.log("chat message removed", { kind: ref.kind, reason });
    return out(false, 0, reason, true);
  };
  const message = messageFromDoc(messageId, doc);
  if (!message) return remove("invalid");
  const system = message.senderUid === SYSTEM_USER_ID;
  const small = isSmallChat(ref.kind);
  const nowMs = deps.now();

  const channel = await deps.store.channel(ref.cid);
  if (!channel) return remove("unknown-chat");
  if (!system) {
    if (!channel.members.includes(message.senderUid)) return remove("not-member");
    const problem = messageProblem(ref.cid, small, message);
    if (problem) return remove(problem);
    // Too fast: this message goes, and the rules refuse the next ones for a while.
    const limit = await deps.store.takeLimit(message.senderUid, "messages", nowMs, { windowMs: 60_000, max: deps.limits.messagesPerMinute });
    if (!limit.allowed) {
      const until = nowMs + deps.limits.muteMinutes * 60_000;
      for (const c of await deps.data.chatsOf(message.senderUid, 500)) await deps.data.patchMember(c, message.senderUid, { mutedUntilMs: until }, nowMs);
      return remove("too-fast");
    }
    if (message.kind === "text" && hasBlockedTerm(message.text)) return remove("blocked-term");
  }

  const last = previewOf(message);
  const at = message.createdAtMs > 0 ? message.createdAtMs : nowMs;
  const state = { duplicate: false, missing: false };
  await deps.data.updateHead(ref.cid, (current) => {
    state.missing = current === null;
    state.duplicate = current?.lastMessageId === messageId;
    if (!current || state.duplicate) return null;
    return { ...current, seq: current.seq + 1, lastAtMs: Math.max(current.lastAtMs ?? 0, at), last, lastMessageId: messageId, updatedAtMs: nowMs };
  });
  if (state.missing) return out(false, 0, "no-head");
  if (!state.duplicate && small) {
    await deps.data.noteMessage(ref.cid, channel.members.slice(0, SMALL_CHAT_MAX), message.senderUid, last, at);
  }
  if (system) return out(true, 0, "system");

  const [choices, blockers] = await Promise.all([deps.store.muteChoices(ref.cid), deps.store.blockersOf(message.senderUid)]);
  const blocked = new Set(blockers);
  const recipients = channel.members.filter(
    (uid) => uid !== message.senderUid && !blocked.has(uid) && !isMuted(ref.kind, channel.members.length, choices.get(uid) ?? null),
  );
  if (recipients.length === 0) return out(true, 0, "nobody");
  const event = newEvent(chatEventId(ref.cid, messageId), "chat-message", recipients, nowMs, {
    actorUid: message.senderUid,
    carpoolId: ref.kind === "carpool" ? channel.refId : null,
    chatCid: ref.cid,
  });
  const created = await deps.store.createEvent(event);
  deps.log("chat message push queued", { kind: ref.kind, recipients: recipients.length, duplicate: !created });
  return out(created, recipients.length, created ? null : "duplicate");
}
