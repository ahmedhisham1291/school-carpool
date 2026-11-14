import { CHANNEL_TYPE_CONFIG, CHANNEL_TYPES, CHAT_KINDS, SYSTEM_USER_ID, type ChatKind } from "./model";

/**
 * What scripts/stream_setup.ts configures in a Stream app (Prompt 9). Kept
 * here, in plain data, so tests can check the rules hold:
 * - parents (role "user") can create no channel, add no member and change
 *   no channel: only Cloud Functions (server-side, which ignores grants) do;
 * - channel members read and write; photos only where uploads are on
 *   (private and carpool), read receipts only in small chats;
 * - no slash commands, polls, calls, threads or reactions (not in v1);
 * - blocked terms in Arabic and English are blocked (not just flagged);
 * - Stream's own push stays off: chat push goes through our webhook.
 */

/** Words and phrases Stream refuses in any chat. Arabic and English; the owner extends it in the dashboard or here. */
export const BLOCKED_TERMS_AR: readonly string[] = [
  "كس امك",
  "يلعن ابوك",
  "ابن الكلب",
  "ابن الوسخة",
  "شرموط",
  "شرموطة",
  "عرص",
  "خول",
  "منيوك",
  "متناك",
  "زبي",
  "طيز",
  "قحبة",
  "ابن المتناكة",
  "يا وسخ",
];

export const BLOCKED_TERMS_EN: readonly string[] = [
  "fuck",
  "fucking",
  "motherfucker",
  "shit",
  "bitch",
  "bastard",
  "asshole",
  "cunt",
  "dick",
  "slut",
  "whore",
  "retard",
  "kill yourself",
];

export const BLOCKLISTS = [
  { name: "carpool_blocked_ar", words: BLOCKED_TERMS_AR },
  { name: "carpool_blocked_en", words: BLOCKED_TERMS_EN },
] as const;

/** Parents get no app-level channel rights in our types (Functions create and fill channels). */
export const USER_GRANTS: readonly string[] = ["update-message-owner", "delete-message-owner", "delete-attachment-owner"];

const MEMBER_BASE: readonly string[] = [
  "read-channel",
  "read-channel-members",
  "create-message",
  "create-mention",
  "add-links",
  // Typing indicator and read events.
  "send-custom-event",
];
const MEMBER_UPLOADS: readonly string[] = ["create-attachment", "upload-attachment"];

export function memberGrants(kind: ChatKind): string[] {
  return [...MEMBER_BASE, ...(CHANNEL_TYPE_CONFIG[kind].uploads ? MEMBER_UPLOADS : [])];
}

/** Rights a parent must NEVER have in our channel types. */
export const FORBIDDEN_FOR_PARENTS: readonly string[] = [
  "create-channel",
  "update-channel",
  "update-channel-owner",
  "update-channel-members",
  "update-channel-members-owner",
  "delete-channel",
  "delete-channel-owner",
  "truncate-channel",
  "truncate-channel-owner",
  "update-channel-frozen",
  "remove-own-channel-membership",
  "remove-own-channel-membership-owner",
  "ban-channel-member",
  "delete-message",
  "skip-message-moderation",
];

export interface ChannelTypeSettings {
  name: string;
  typing_events: boolean;
  read_events: boolean;
  connect_events: boolean;
  uploads: boolean;
  reactions: boolean;
  replies: boolean;
  quotes: boolean;
  search: boolean;
  mutes: boolean;
  url_enrichment: boolean;
  polls: boolean;
  location_sharing: boolean;
  push_notifications: boolean;
  max_message_length: number;
  automod: "simple";
  automod_behavior: "block";
  blocklist_behavior: "block";
  blocklists: Array<{ blocklist: string; behavior: "block" }>;
  commands: string[];
  grants: Record<string, string[]>;
}

export function channelTypeSettings(kind: ChatKind): ChannelTypeSettings {
  const config = CHANNEL_TYPE_CONFIG[kind];
  return {
    name: CHANNEL_TYPES[kind],
    typing_events: true,
    read_events: config.readEvents,
    connect_events: kind === "private" || kind === "carpool",
    uploads: config.uploads,
    reactions: false,
    replies: false,
    quotes: true,
    search: false,
    mutes: true,
    url_enrichment: false,
    polls: false,
    // Our location pin is an attachment of type "location" (no live sharing).
    location_sharing: false,
    // Stream's own push stays off: chat push goes through our webhook and sender.
    push_notifications: false,
    max_message_length: 2000,
    automod: "simple",
    automod_behavior: "block",
    blocklist_behavior: "block",
    blocklists: BLOCKLISTS.map((b) => ({ blocklist: b.name, behavior: "block" as const })),
    commands: [],
    grants: {
      user: [...USER_GRANTS],
      guest: [],
      anonymous: [],
      channel_member: memberGrants(kind),
      channel_moderator: [],
    },
  };
}

export function allChannelTypeSettings(): ChannelTypeSettings[] {
  return CHAT_KINDS.map(channelTypeSettings);
}

/**
 * Stream AI moderation policy for every chat (text and images): harmful
 * text and images are blocked, borderline ones flagged for review in
 * Stream's dashboard; our blocklists apply too. Needs Stream's moderation
 * product on the app (SETUP.md 19.4).
 */
export function moderationPolicy(): Record<string, unknown> {
  return {
    key: "chat",
    block_list_config: { enabled: true, rules: BLOCKLISTS.map((b) => ({ name: b.name, action: "remove" })) },
    ai_text_config: {
      enabled: true,
      rules: [
        { label: "SEXUAL_HARASSMENT", action: "remove" },
        { label: "THREAT", action: "remove" },
        { label: "HATE_SPEECH", action: "remove" },
        { label: "INSULT", action: "flag" },
        { label: "SCAM", action: "flag" },
        { label: "SPAM", action: "flag" },
      ],
    },
    ai_image_config: {
      enabled: true,
      rules: [
        { label: "Explicit", action: "remove", min_confidence: 50 },
        { label: "Non-Explicit Nudity", action: "remove", min_confidence: 50 },
        { label: "Violence", action: "remove", min_confidence: 60 },
        { label: "Visually Disturbing", action: "flag", min_confidence: 60 },
        { label: "Hate Symbols", action: "remove", min_confidence: 60 },
      ],
    },
  };
}

export const SYSTEM_USER = { id: SYSTEM_USER_ID, name: "School Carpool", role: "admin" };
