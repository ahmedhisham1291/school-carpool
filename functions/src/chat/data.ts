import type { ChatKind } from "./model";

/**
 * The chat documents the phone reads (firestore.rules "Own chat"):
 *
 * - chats/{cid}: the chat's head (names, member count, frozen, the last
 *   message and a message counter). Members read it; Functions write it.
 * - chats/{cid}/chatMembers/{uid}: the member's first name, for message
 *   authors. Members read one by its ID (never a list). Kept after a parent
 *   leaves so old messages still show a first name; Functions only write.
 * - chats/{cid}/chatAccess/{uid}: what the member may do (active, cut,
 *   frozen, mutedUntil). NOBODY reads it from the app, not even its owner:
 *   only the rules read it, on every read and write, so removing,
 *   suspending, freezing or muting a parent works at once and no member
 *   can see another member's sanctions.
 * - chats/{cid}/fanned/{messageId}: the message trigger's own marker (so a
 *   trigger delivered twice counts once); TTL 2 days; Functions only.
 * - chats/{cid}/messages/{id}: written by the sender's phone under strict
 *   rules (own uid, server time, fixed fields and sizes), never changed.
 *   Functions delete (admin removal, limits, blocked terms, retention).
 * - chats/{cid}/reads/{uid}: small chats only; the parent's own read and
 *   typing times (read marks and the typing line).
 * - userChats/{uid}/summaries/{cid}: one row of the parent's chat list.
 *   Functions write it; the parent may only reset their own unread count.
 *
 * FirestoreChatData (firestore_data.ts) is the real one; the tests use an
 * in-memory one. Nothing here is logged.
 */

export const CHATS = "chats";
export const CHAT_MEMBERS = "chatMembers";
export const CHAT_ACCESS = "chatAccess";
export const CHAT_FANNED = "fanned";
/** Fan-out markers are deleted this long after the message (Firestore TTL). */
export const FANNED_TTL_DAYS = 2;
export const CHAT_MESSAGES = "messages";
export const CHAT_READS = "reads";
export const USER_CHATS = "userChats";
export const CHAT_SUMMARIES = "summaries";
/** Storage: chatPhotos/{type}/{id}/{uid}/{messageId}.webp (or .jpg); "type:id" is the chat ID. */
export const CHAT_PHOTOS = "chatPhotos";

/** The Storage folder of a chat's photos: the chat ID with "/" in place of ":" (no ":" in a Storage path). */
export function photoFolder(cid: string): string {
  return `${CHAT_PHOTOS}/${cid.replace(":", "/")}`;
}

export const MESSAGE_KINDS = ["text", "photo", "location"] as const;
export type MessageKind = (typeof MESSAGE_KINDS)[number];

/** The last message as the chat list shows it (members only). */
export interface LastMessage {
  kind: MessageKind | "deleted";
  senderUid: string;
  /** Cut to PREVIEW_TEXT_MAX; "" for photos and pins. */
  text: string;
}

export interface ChatHead {
  cid: string;
  kind: ChatKind;
  nameAr: string;
  nameEn: string;
  refId: string | null;
  memberCount: number;
  frozen: boolean;
  /** Messages so far: school and area groups count unread from it. */
  seq: number;
  lastAtMs: number | null;
  last: LastMessage | null;
  /** The message the head was last updated for (a trigger delivered twice counts once). */
  lastMessageId: string | null;
  createdAtMs: number;
  updatedAtMs: number;
}

export interface ChatMember {
  uid: string;
  /** First name only; an initial once the account is deleted. */
  firstName: string;
  /** In the chat now. */
  active: boolean;
  /** The account lost chat access (suspended, banned, unverified, deleted). */
  cut: boolean;
  /** Nobody writes in a frozen chat (block, closed carpool, deleted parent). */
  frozen: boolean;
  /** Sending too fast: no new message until then. */
  mutedUntilMs: number | null;
  joinedAtMs: number;
  updatedAtMs: number;
}

export type MemberPatch = Partial<Pick<ChatMember, "firstName" | "active" | "cut" | "frozen" | "mutedUntilMs">>;

export interface ChatSummary {
  cid: string;
  kind: ChatKind;
  nameAr: string;
  nameEn: string;
  /** Private chats: the other parent. */
  otherUid: string | null;
  otherName: string;
  /** The parent's own push choice; null = none yet (large groups then count as muted, model.ts isMuted). */
  muted: boolean | null;
  frozen: boolean;
  /** False while the account is cut off: the rules then hide the row. */
  open: boolean;
  memberCount: number;
  /** Small chats: messages from others since the parent last read. */
  unread: number;
  /** Groups: the head's seq when the parent last read. */
  readSeq: number;
  lastAtMs: number | null;
  last: LastMessage | null;
  joinedAtMs: number;
  updatedAtMs: number;
}

export type SummaryPatch = Partial<Pick<ChatSummary, "nameAr" | "nameEn" | "otherUid" | "otherName" | "muted" | "frozen" | "open" | "memberCount" | "last">>;

export interface StoredMessage {
  id: string;
  senderUid: string;
  kind: MessageKind;
  text: string;
  photoPath: string | null;
  lat: number | null;
  lng: number | null;
  createdAtMs: number;
}

/** The message trigger's marker for one message. */
export interface FanMark {
  /** The sending limit refused it ("over"); "ok" otherwise. */
  verdict: "ok" | "over";
  /** The head and the unread counters were updated for it. */
  counted: boolean;
}

/** A chat photo in Storage. */
export interface StoredPhoto {
  path: string;
  createdAtMs: number;
}

/** chatPhotos/{type}/{id}/{uid}/{messageId}.ext -> its parts, or null for anything else. */
export function parsePhotoPath(path: string): { cid: string; uid: string; messageId: string } | null {
  const m = /^chatPhotos\/(cp_[a-z]+)\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_-]+)\.(webp|jpg)$/.exec(path);
  return m ? { cid: `${m[1]}:${m[2]}`, uid: m[3], messageId: m[4] } : null;
}

export interface ChatProfile {
  firstName: string;
  parentId: string;
}

export interface ChatData {
  /** First name and parent ID from users/{uid}; null when the record is gone. */
  profile(uid: string): Promise<ChatProfile | null>;

  head(cid: string): Promise<ChatHead | null>;
  /** Reads the head, applies [change] and saves its answer in one transaction; null leaves it. */
  updateHead(cid: string, change: (current: ChatHead | null) => ChatHead | null): Promise<ChatHead | null>;

  /**
   * The message trigger's marker. true when this call created it (first
   * delivery); false when it was there already (a second delivery).
   */
  claimMessage(cid: string, messageId: string, nowMs: number): Promise<boolean>;
  fanMark(cid: string, messageId: string): Promise<FanMark | null>;
  setVerdict(cid: string, messageId: string, verdict: FanMark["verdict"]): Promise<void>;
  /**
   * One transaction: when the marker says "not counted yet", applies
   * [change] to the head and marks it counted. "counted" when it did,
   * "duplicate" when it was counted before, "no-head" without a head.
   */
  countMessage(cid: string, messageId: string, change: (current: ChatHead) => ChatHead): Promise<"counted" | "duplicate" | "no-head">;

  member(cid: string, uid: string): Promise<ChatMember | null>;
  putMember(cid: string, member: ChatMember): Promise<void>;
  /** Changes an existing member document; a missing one stays missing. */
  patchMember(cid: string, uid: string, patch: MemberPatch, nowMs: number): Promise<void>;
  /** Member documents of [cid], active or not, at most [limit]. */
  members(cid: string, limit: number): Promise<ChatMember[]>;
  /** Every chat [uid] has a member document in (active or not). */
  chatsOf(uid: string, limit: number): Promise<string[]>;

  summary(uid: string, cid: string): Promise<ChatSummary | null>;
  putSummary(uid: string, summary: ChatSummary): Promise<void>;
  /** Changes an existing summary; a missing one stays missing. */
  patchSummary(uid: string, cid: string, patch: SummaryPatch, nowMs: number): Promise<void>;
  deleteSummary(uid: string, cid: string): Promise<void>;
  /**
   * A new message in a small chat: every summary of [uids] gets the last
   * message and time, and unread + 1 except [senderUid]'s. One batch.
   */
  noteMessage(cid: string, uids: string[], senderUid: string, last: LastMessage, lastAtMs: number): Promise<void>;

  message(cid: string, id: string): Promise<StoredMessage | null>;
  /** [before] older, the message, [after] newer, oldest first; empty when the message is gone. */
  messagesAround(cid: string, id: string, before: number, after: number): Promise<StoredMessage[]>;
  latestMessage(cid: string): Promise<StoredMessage | null>;
  /** false when a message with that ID exists already. */
  createMessage(cid: string, message: StoredMessage): Promise<boolean>;
  /** Deletes the message and its photo; the deleted message, or null when it was gone. */
  deleteMessage(cid: string, id: string): Promise<StoredMessage | null>;
  /** The parent's own messages in every chat, newest first. */
  messagesBy(uid: string, limit: number): Promise<Array<StoredMessage & { cid: string }>>;
  /** Deletes up to [limit] of the parent's messages (and photos); the number deleted. */
  deleteMessagesBy(uid: string, limit: number): Promise<number>;

  /** The head, members, access, messages, reads, markers, the members' summaries and the photos. */
  deleteChat(cid: string): Promise<void>;

  /** Chat photos created in [fromMs, toMs), at most [limit] (Storage listing). */
  photosCreatedBetween(fromMs: number, toMs: number, limit: number): Promise<StoredPhoto[]>;
  deletePhoto(path: string): Promise<void>;
  /** Every photo [uid] uploaded into [cid], with or without a message. */
  deletePhotosOf(cid: string, uid: string): Promise<void>;
}

/** The only place a chat photo may live: chatPhotos/{type}/{id}/{senderUid}/{messageId}.webp or .jpg. */
export function photoPathOk(cid: string, senderUid: string, messageId: string, path: string | null): boolean {
  if (path === null) return false;
  const base = `${photoFolder(cid)}/${senderUid}/${messageId}`;
  return path === `${base}.webp` || path === `${base}.jpg`;
}
