/**
 * Notifications (Prompt 8: F12, F23). Every notification type, the
 * WhatsApp group it belongs to (what a parent switches on or off in
 * Settings), whether it is critical, its WhatsApp template and the screen
 * the app opens when the parent taps it.
 *
 * PRIVACY (spec section 7, "On the phone"): push and WhatsApp text comes
 * only from texts.ts. It never contains child names, parent names,
 * addresses or message text: at most a date and the run direction. The app
 * loads the details after it opens.
 */

export const NOTIFICATION_TYPES = [
  // Schedule (Prompt 7 events)
  "plan-ready",
  "no-driver",
  "swap-requested",
  "swap-accepted",
  "swap-cancelled",
  "run-taken",
  "child-absent",
  "child-back",
  "driver-unavailable",
  "schedule-changed",
  // A run's time moved (Prompt 7 fixes): to its driver; critical when there
  // is no time left to confirm again.
  "time-changed",
  // Driver reminders (Prompt 8 producer)
  "drive-evening",
  "drive-hour",
  "confirm-reminder",
  // Join requests (Prompt 6 flows)
  "join-requested",
  "join-approved",
  "join-declined",
  // Verification result (Prompt 3 flow)
  "verification-approved",
  "verification-rejected",
  // New parent nearby (Prompt 5 event, F23)
  "new-parent",
  // Handover not confirmed (F34). Critical; its producer comes with trips.
  "child-not-confirmed",
  // Chat (Prompt 9): push only, never WhatsApp.
  "chat-message",
  // The second, louder push of a critical alert nobody opened in time.
  "critical-alarm",
] as const;

export type NotificationType = (typeof NOTIFICATION_TYPES)[number];

export function isNotificationType(value: unknown): value is NotificationType {
  return typeof value === "string" && (NOTIFICATION_TYPES as readonly string[]).includes(value);
}

/**
 * What a parent switches WhatsApp on or off for (Settings > Alerts). Chat
 * has no switch: it is push only (F12).
 */
export const WHATSAPP_GROUPS = [
  "noDriver",
  "childNotConfirmed",
  "reminders",
  "swaps",
  "absences",
  "schedule",
  "joins",
  "verification",
  "newParents",
] as const;

export type WhatsAppGroup = (typeof WHATSAPP_GROUPS)[number];
export type NotificationGroup = WhatsAppGroup | "chat" | "alarm";

/**
 * COST MODE: every WhatsApp template message is paid, so only the critical
 * alerts go to WhatsApp unless the parent switches a group on. Sign-in
 * codes are sent by the sign-in functions, not here.
 */
export const WHATSAPP_DEFAULTS: Readonly<Record<WhatsAppGroup, boolean>> = {
  noDriver: true,
  childNotConfirmed: true,
  reminders: false,
  swaps: false,
  absences: false,
  schedule: false,
  joins: false,
  verification: false,
  newParents: false,
};

export function isWhatsAppGroup(value: unknown): value is WhatsAppGroup {
  return typeof value === "string" && (WHATSAPP_GROUPS as readonly string[]).includes(value);
}

export interface TypeSpec {
  group: NotificationGroup;
  /** Critical alerts ignore quiet hours and sound the alarm when not opened in time (spec section 11). */
  critical: boolean;
  /**
   * Approved WhatsApp template (utility category), one body parameter: the
   * date and run ({{1}}), or none. null: never sent by WhatsApp.
   */
  template: string | null;
  /** The text has a {when} part (date and direction of a run). */
  hasWhen: boolean;
}

const spec = (group: NotificationGroup, template: string | null, hasWhen: boolean, critical = false): TypeSpec => ({
  group,
  critical,
  template,
  hasWhen,
});

export const TYPES: Readonly<Record<NotificationType, TypeSpec>> = {
  "plan-ready": spec("schedule", "cp_plan_ready", false),
  "no-driver": spec("noDriver", "cp_no_driver", true, true),
  "swap-requested": spec("swaps", "cp_swap_requested", true),
  "swap-accepted": spec("swaps", "cp_new_driver", true),
  "swap-cancelled": spec("swaps", "cp_swap_cancelled", true),
  "run-taken": spec("swaps", "cp_new_driver", true),
  "child-absent": spec("absences", "cp_child_absent", true),
  "child-back": spec("absences", "cp_child_back", true),
  "driver-unavailable": spec("swaps", "cp_needs_driver", true),
  "schedule-changed": spec("schedule", "cp_schedule_changed", false),
  "time-changed": spec("schedule", "cp_time_changed", true),
  "drive-evening": spec("reminders", "cp_drive_tomorrow", true),
  "drive-hour": spec("reminders", "cp_drive_soon", true),
  "confirm-reminder": spec("reminders", "cp_confirm_drive", true),
  "join-requested": spec("joins", "cp_join_requested", false),
  "join-approved": spec("joins", "cp_join_approved", false),
  "join-declined": spec("joins", "cp_join_declined", false),
  "verification-approved": spec("verification", "cp_review_approved", false),
  "verification-rejected": spec("verification", "cp_review_rejected", false),
  "new-parent": spec("newParents", "cp_new_parent", false),
  "child-not-confirmed": spec("childNotConfirmed", "cp_child_not_confirmed", false, true),
  "chat-message": spec("chat", null, false),
  "critical-alarm": spec("alarm", null, false, true),
};

/** Types an unverified (or rejected) parent may still receive. */
export const OPEN_TO_UNVERIFIED: readonly NotificationType[] = ["verification-approved", "verification-rejected"];

export interface RouteInput {
  type: NotificationType;
  carpoolId: string | null;
  /** chat-message: "type:id" of the chat (Prompt 9). */
  chatCid?: string | null;
}

/**
 * Chat pushes (Prompt 9) are push only: their delivery record lives in
 * users/{uid}/chatPushes (never shown in the Notifications tab; TTL two
 * days), so chat never floods the tab or its unread dot. Their event IDs
 * start with this prefix ("chat_" + the Stream message ID).
 */
export const PUSH_ONLY_PREFIX = "chat_";

export function isPushOnlyId(id: string): boolean {
  return id.startsWith(PUSH_ONLY_PREFIX);
}

const CHAT_PART = /^[A-Za-z0-9_-]{1,64}$/;

const ID = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * The screen the app opens for a notification (go_router paths). Only IDs
 * go into it; the app checks the shape again before it navigates.
 */
export function routeFor(input: RouteInput): string {
  const carpool = input.carpoolId && ID.test(input.carpoolId) ? input.carpoolId : null;
  switch (input.type) {
    case "join-requested":
    case "join-approved":
    case "join-declined":
      return carpool ? `/carpools/${carpool}` : "/notifications";
    case "verification-approved":
    case "verification-rejected":
      return "/profile";
    case "new-parent":
      return "/home/nearby";
    case "chat-message": {
      const at = input.chatCid ? input.chatCid.indexOf(":") : -1;
      const type = at > 0 ? (input.chatCid as string).slice(0, at) : "";
      const id = at > 0 ? (input.chatCid as string).slice(at + 1) : "";
      return CHAT_PART.test(type) && CHAT_PART.test(id) ? `/chats/${type}/${id}` : "/chats";
    }
    case "critical-alarm":
      return "/notifications";
    default:
      return carpool ? `/carpools/${carpool}/schedule` : "/notifications";
  }
}
