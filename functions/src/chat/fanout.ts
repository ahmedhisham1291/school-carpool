import { createHash } from "node:crypto";
import { newEvent } from "../notifications/model";
import { MESSAGE_KINDS, photoPathOk, type ChatData, type MessageKind, type StoredMessage } from "./data";
import { hasBlockedTerm } from "./moderation";
import { isMuted, isSmallChat, MESSAGE_TEXT_MAX, muteChoice, parseCid, SMALL_CHAT_MAX, SYSTEM_USER_ID } from "./model";
import { previewOf, type ChatServer } from "./server";
import type { ChatStore } from "./store";

/**
 * What happens after a parent's phone wrote a message (the trigger on
 * chats/{cid}/messages/{id}, callables.ts). The phone writes the message
 * itself so sending feels instant and works offline; everything else is
 * here, in two parts:
 *
 * A. The gate (MUST happen; the trigger is retried until it did). A marker
 *    per message makes a second delivery harmless: the sending limit is
 *    counted once. Removed: a message that is not valid, from somebody not
 *    in OUR registry, over the sending limit or the daily photo limit (the
 *    sender then cannot write for a while; the rules read `mutedUntil`),
 *    or with a blocked term. Removing is safe to repeat.
 *
 *    The message is visible to members who have the chat open from the
 *    write until this runs: usually one to three seconds, ten or more
 *    when the function starts cold. It never reaches the chat list or a
 *    push.
 *
 * B. The counters (best effort; a failure is logged, never retried into a
 *    double count): the chat's head (last message, time, message counter)
 *    together with the marker in ONE transaction, so a message is counted
 *    once whatever is delivered twice or in which order; then, in small
 *    chats, each member's chat list row (unread + 1, last message). School
 *    and area groups get no write per member; the app counts unread from
 *    the head's counter. Then the push through OUR sender (Prompt 8): one
 *    "chat-message" event with a fixed ID, so the push text is the fixed
 *    "You have a new message" and never the message, a name or a photo.
 *    Recipients: the chat's members in our registry, minus the sender,
 *    minus parents who muted that chat (large school and area groups start
 *    muted), minus parents who blocked the sender.
 *
 * Logs: kinds and counts only, never text, names or coordinates.
 */

export interface FanoutLimits {
  /** Messages a parent may send per minute, all chats together. */
  messagesPerMinute: number;
  /** Chat photos a parent may send per day, all chats together. */
  photosPerDay: number;
  /** How long a parent who went over cannot write. */
  muteMinutes: number;
}

export const DEFAULT_FANOUT_LIMITS: FanoutLimits = { messagesPerMinute: 30, photosPerDay: 50, muteMinutes: 10 };

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

  // ---- A. The gate: errors here are thrown, so the trigger is retried.
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
    if (message.kind === "text" && hasBlockedTerm(message.text)) return remove("blocked-term");

    // The limits are counted ONCE per message: only the delivery that
    // creates the marker counts; a later one reads the verdict.
    const first = await deps.data.claimMessage(ref.cid, messageId, nowMs);
    let over: string | null = null;
    if (first) {
      const perMinute = await deps.store.takeLimit(message.senderUid, "messages", nowMs, { windowMs: 60_000, max: deps.limits.messagesPerMinute });
      if (!perMinute.allowed) over = "too-fast";
      if (!over && message.kind === "photo") {
        const perDay = await deps.store.takeLimit(message.senderUid, "photos", nowMs, { windowMs: 86_400_000, max: deps.limits.photosPerDay });
        if (!perDay.allowed) over = "too-many-photos";
      }
      if (over) await deps.data.setVerdict(ref.cid, messageId, "over");
    } else if ((await deps.data.fanMark(ref.cid, messageId))?.verdict === "over") {
      over = "too-fast";
    }
    if (over) {
      // Mute once: a parent already muted is not written again for every
      // further message (each would be a query and a write per chat).
      const mine = await deps.data.member(ref.cid, message.senderUid);
      if (!mine || (mine.mutedUntilMs ?? 0) <= nowMs) {
        const until = nowMs + deps.limits.muteMinutes * 60_000;
        for (const c of await deps.data.chatsOf(message.senderUid, 500)) await deps.data.patchMember(c, message.senderUid, { mutedUntilMs: until }, nowMs);
      }
      return remove(over);
    }
  }

  // ---- B. The counters and the push: best effort, never thrown.
  try {
    const last = previewOf(message);
    const at = message.createdAtMs > 0 ? message.createdAtMs : nowMs;
    const counted = await deps.data.countMessage(ref.cid, messageId, (current) => ({
      ...current,
      seq: current.seq + 1,
      lastAtMs: Math.max(current.lastAtMs ?? 0, at),
      // An older message delivered late does not replace a newer preview.
      ...(at >= (current.lastAtMs ?? 0) ? { last, lastMessageId: messageId } : {}),
      updatedAtMs: nowMs,
    }));
    if (counted === "no-head") return out(false, 0, "no-head");
    if (counted === "counted" && small) {
      await deps.data.noteMessage(ref.cid, channel.members.slice(0, SMALL_CHAT_MAX), message.senderUid, last, at);
    }
    if (system) return out(true, 0, "system");

    const blocked = new Set(await deps.store.blockersOf(message.senderUid));
    const recipients = channel.members.filter(
      (uid) => uid !== message.senderUid && !blocked.has(uid) && !isMuted(ref.kind, channel.members.length, muteChoice(channel, uid)),
    );
    if (recipients.length === 0) return out(true, 0, counted === "duplicate" ? "duplicate" : "nobody");
    const event = newEvent(chatEventId(ref.cid, messageId), "chat-message", recipients, nowMs, {
      actorUid: message.senderUid,
      carpoolId: ref.kind === "carpool" ? channel.refId : null,
      chatCid: ref.cid,
    });
    const created = await deps.store.createEvent(event);
    deps.log("chat message push queued", { kind: ref.kind, recipients: recipients.length, duplicate: !created });
    return out(created, recipients.length, created ? null : "duplicate");
  } catch (error) {
    // Our own error text only (never the message).
    deps.log("chat message counters failed", { kind: ref.kind, message: error instanceof Error ? error.message : "unknown" });
    return out(false, 0, "counters-failed");
  }
}
