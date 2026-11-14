import { createHash } from "node:crypto";

/**
 * Chat (Prompt 9: F8, F9, F10, F13) on Stream Chat.
 *
 * Cloud Functions decide everything about chat: who gets a token, which
 * channels exist and who is in them. The app can read and write messages
 * only in channels it was added to (Stream channel-type permissions, set by
 * scripts/stream_setup.ts): it cannot create a channel or add a member.
 *
 * Four Stream channel types, one per kind of chat (spec section 5). Each
 * type carries the switches of its kind, so the rules hold on Stream's side
 * too: photos only in private and carpool chats, read receipts only in
 * small chats.
 *
 * Stream gets first names and parent IDs only (spec section 7): never a
 * phone number, an address or a child.
 */

export const CHAT_KINDS = ["private", "school", "area", "carpool"] as const;
export type ChatKind = (typeof CHAT_KINDS)[number];

/** Stream channel type of each kind (created by scripts/stream_setup.ts). */
export const CHANNEL_TYPES: Readonly<Record<ChatKind, string>> = {
  private: "cp_private",
  school: "cp_school",
  area: "cp_area",
  carpool: "cp_carpool",
};

export interface ChannelTypeConfig {
  /** Photos (spec section 5: private and carpool chats only). */
  uploads: boolean;
  /** Read receipts (small chats only). */
  readEvents: boolean;
}

export const CHANNEL_TYPE_CONFIG: Readonly<Record<ChatKind, ChannelTypeConfig>> = {
  private: { uploads: true, readEvents: true },
  school: { uploads: false, readEvents: false },
  area: { uploads: false, readEvents: false },
  carpool: { uploads: true, readEvents: true },
};

/** The Stream user that creates every channel (role admin, no person). */
export const SYSTEM_USER_ID = "carpool-system";

/**
 * School and area groups with more members than this are muted for a parent
 * until they unmute them (spec section 5: "mute by default after a set size").
 */
export const LARGE_GROUP_SIZE = 50;

/** A parent joins the area group of their child's school whose center is within this distance. */
export const AREA_MAX_KM = 6;

/** Members kept in the channel registry; a school bigger than this is refused more (logged). */
export const MAX_GROUP_MEMBERS = 5_000;

/** Private chat requests and their answers are deleted this long after the last change (TTL). */
export const REQUEST_TTL_DAYS = 30;

/** Reported message: this many messages before and after it are kept as context (spec section 5). */
export const CONTEXT_BEFORE = 2;
export const CONTEXT_AFTER = 1;
/** Each context message is cut to this length. */
export const CONTEXT_TEXT_MAX = 500;

/** Report reasons (spec section 6: user, message or group with a reason). */
export const REPORT_REASONS = ["harassment", "spam", "inappropriate", "privacy", "childSafety", "dangerousDriving", "other"] as const;
export type ReportReason = (typeof REPORT_REASONS)[number];

/**
 * Urgent reasons (spec section 6): the reported driver's driving days pause
 * at once and the report is reviewed the same day.
 */
export const URGENT_REASONS: readonly ReportReason[] = ["childSafety", "dangerousDriving"];

export const REPORT_TARGETS = ["message", "user", "group"] as const;
export type ReportTarget = (typeof REPORT_TARGETS)[number];

export const NOTE_MAX = 300;

export type ChatErrorReason =
  | "invalid-request"
  | "not-verified"
  | "suspended"
  | "not-found"
  | "not-member"
  | "not-allowed"
  | "blocked"
  | "requests-off"
  | "no-shared-school"
  | "already-pending"
  | "already-connected"
  | "self"
  | "rate-limited"
  | "chat-unavailable";

export const CHAT_ERROR_CODES: Readonly<Record<ChatErrorReason, string>> = {
  "invalid-request": "invalid-argument",
  "not-verified": "permission-denied",
  suspended: "permission-denied",
  "not-found": "not-found",
  "not-member": "permission-denied",
  "not-allowed": "permission-denied",
  blocked: "failed-precondition",
  "requests-off": "failed-precondition",
  "no-shared-school": "failed-precondition",
  "already-pending": "already-exists",
  "already-connected": "already-exists",
  self: "invalid-argument",
  "rate-limited": "resource-exhausted",
  "chat-unavailable": "unavailable",
};

export class ChatError extends Error {
  constructor(
    readonly reason: ChatErrorReason,
    readonly retryAfterMs = 0,
  ) {
    super(reason);
  }
}

// --------------------------------------------------------------------------
// Channel IDs
// --------------------------------------------------------------------------

const REF_ID = /^[A-Za-z0-9_-]{1,40}$/;
const UID = /^[A-Za-z0-9_-]{1,128}$/;
/** Stream channel IDs: letters, digits, "-" and "_", at most 64. */
const CHANNEL_ID = /^[A-Za-z0-9_-]{1,64}$/;

export function isUid(v: unknown): v is string {
  return typeof v === "string" && UID.test(v);
}

export function isRefId(v: unknown): v is string {
  return typeof v === "string" && REF_ID.test(v);
}

/** One private channel per pair of parents, whoever asked first. Not reversible to the uids. */
export function privateChannelId(a: string, b: string): string {
  const [x, y] = [a, b].sort();
  return "dm-" + createHash("sha256").update(`${x}|${y}`).digest("hex").slice(0, 40);
}

export function groupChannelId(kind: Exclude<ChatKind, "private">, refId: string): string {
  if (!isRefId(refId)) throw new ChatError("invalid-request");
  const prefix = kind === "school" ? "s-" : kind === "area" ? "a-" : "c-";
  return prefix + refId;
}

export interface ChannelRef {
  kind: ChatKind;
  type: string;
  id: string;
  /** "type:id", Stream's channel key; also our registry document ID. */
  cid: string;
}

export function channelRef(kind: ChatKind, id: string): ChannelRef {
  const type = CHANNEL_TYPES[kind];
  return { kind, type, id, cid: `${type}:${id}` };
}

/** A cid from the app or a webhook, or null when it is not one of ours. */
export function parseCid(cid: unknown): ChannelRef | null {
  if (typeof cid !== "string") return null;
  const at = cid.indexOf(":");
  if (at <= 0) return null;
  const type = cid.slice(0, at);
  const id = cid.slice(at + 1);
  if (!CHANNEL_ID.test(id)) return null;
  const kind = CHAT_KINDS.find((k) => CHANNEL_TYPES[k] === type);
  return kind ? { kind, type, id, cid } : null;
}

// --------------------------------------------------------------------------
// Records (Firestore). Only Cloud Functions write them.
// --------------------------------------------------------------------------

/** chatChannels/{cid}: who is in each channel we created. */
export interface ChannelRecord {
  cid: string;
  kind: ChatKind;
  /** School, area or carpool ID; null for a private chat. */
  refId: string | null;
  /** School ID of a school or area group (the area's school). */
  schoolId: string | null;
  nameAr: string;
  nameEn: string;
  members: string[];
  /** Removed by an admin: never added back by the automatic sync. */
  excluded: string[];
  /** A private chat between parents where one blocked the other. */
  frozen: boolean;
  createdAtMs: number;
  updatedAtMs: number;
  /**
   * Prompt 12: when the chat ended (carpool closed, a private chat whose
   * parent deleted the account). retentionDaily deletes it on Stream one
   * year later (owner decision: life of the chat + 1 year).
   */
  endedAtMs?: number | null;
}

export type RequestStatus = "pending" | "accepted" | "declined" | "cancelled";

/** chatRequests/{fromUid}_{toUid}: a private chat request (spec section 5). */
export interface RequestRecord {
  id: string;
  fromUid: string;
  toUid: string;
  /** First names only, shown on the request (spec section 6, minimal exposure). */
  fromFirstName: string;
  toFirstName: string;
  status: RequestStatus;
  /** The private channel, once accepted. */
  cid: string | null;
  createdAtMs: number;
  updatedAtMs: number;
}

export function requestId(fromUid: string, toUid: string): string {
  return `${fromUid}_${toUid}`;
}

/** chatBlocks/{blockerUid}_{blockedUid} (F13). */
export interface BlockRecord {
  blockerUid: string;
  blockedUid: string;
  /** First name of the blocked parent, for the blocker's list. */
  blockedFirstName: string;
  createdAtMs: number;
}

export function blockId(blocker: string, blocked: string): string {
  return `${blocker}_${blocked}`;
}

/** chatMutes/{uid}_{cid with ':' as '~'}: a parent's own mute choice for one chat. */
export interface MuteRecord {
  uid: string;
  cid: string;
  muted: boolean;
  updatedAtMs: number;
}

export function muteId(uid: string, cid: string): string {
  return `${uid}_${cid.replace(":", "~")}`;
}

/** Muted when the parent said so; a large school or area group starts muted. */
export function isMuted(kind: ChatKind, memberCount: number, choice: boolean | null): boolean {
  if (choice !== null) return choice;
  return (kind === "school" || kind === "area") && memberCount > LARGE_GROUP_SIZE;
}

/** chatSettings/{uid}: requests off (spec section 5: "let a parent turn requests off"). */
export interface ChatSettings {
  requestsOff: boolean;
}

export type ReportStatus = "open" | "handled";

/** One message as a report keeps it: first name and parent ID of the author, text cut short. */
export interface MessageSnapshot {
  id: string;
  authorUid: string;
  authorName: string;
  authorParentId: string;
  text: string;
  /** "image", "location" or none: the photo itself is never copied. */
  attachment: string | null;
  createdAtMs: number;
  /** The reported message itself (the others are context). */
  reported: boolean;
}

/** reports/{id}: the admin queue (Prompt 4's list, with chat details). */
export interface ReportRecord {
  id: string;
  reporterUid: string;
  targetType: ReportTarget;
  /** Message ID, the reported parent's uid, or the cid. */
  targetId: string;
  /** The reported parent (message author or the user), when there is one. */
  subjectUid: string | null;
  cid: string;
  kind: ChatKind;
  reason: ReportReason;
  note: string;
  urgent: boolean;
  status: ReportStatus;
  /** Reported message with a little context (message reports only). */
  context: MessageSnapshot[];
  /** Urgent: the driving pause applied at once. */
  pausedDriving: boolean;
  outcome: string | null;
  handledBy: string | null;
  createdAtMs: number;
  handledAtMs: number | null;
}

/** The parent as chat sees them. */
export interface ChatAccount {
  uid: string;
  status: string;
  banned: boolean;
  firstName: string;
  parentId: string;
  language: "ar" | "en";
}

export function chatEligible(a: ChatAccount | null): a is ChatAccount {
  return !!a && !a.banned && a.status === "verified";
}

// --------------------------------------------------------------------------
// Input parsing
// --------------------------------------------------------------------------

export function record(data: unknown): Record<string, unknown> {
  if (typeof data !== "object" || data === null || Array.isArray(data)) throw new ChatError("invalid-request");
  return data as Record<string, unknown>;
}

export function uidField(v: unknown): string {
  if (!isUid(v)) throw new ChatError("invalid-request");
  return v;
}

export function cidField(v: unknown): ChannelRef {
  const ref = parseCid(v);
  if (!ref) throw new ChatError("invalid-request");
  return ref;
}

export function boolField(v: unknown): boolean {
  if (typeof v !== "boolean") throw new ChatError("invalid-request");
  return v;
}

/** Stream message IDs: the SDK's UUIDs or our own, no slashes. */
export function messageIdField(v: unknown): string {
  if (typeof v !== "string" || !/^[A-Za-z0-9_-]{1,100}$/.test(v)) throw new ChatError("invalid-request");
  return v;
}

/** A short, single-line note: control characters and bidi marks removed. */
export function cleanNote(v: unknown): string {
  if (v === undefined || v === null) return "";
  if (typeof v !== "string") throw new ChatError("invalid-request");
  // eslint-disable-next-line no-control-regex
  const text = v.replace(/[\u0000-\u001f\u007f‎‏‪-‮⁦-⁩]/g, " ").replace(/\s+/g, " ").trim();
  if (text.length > NOTE_MAX) throw new ChatError("invalid-request");
  return text;
}

export function isReportReason(v: unknown): v is ReportReason {
  return typeof v === "string" && (REPORT_REASONS as readonly string[]).includes(v);
}

export function isReportTarget(v: unknown): v is ReportTarget {
  return typeof v === "string" && (REPORT_TARGETS as readonly string[]).includes(v);
}

export function cutText(text: string, max = CONTEXT_TEXT_MAX): string {
  return text.length <= max ? text : text.slice(0, max - 1) + "…";
}
