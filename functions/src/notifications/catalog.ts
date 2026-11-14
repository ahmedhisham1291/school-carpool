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
  // Handover not confirmed (F34). Critical; produced by the trip tick (Prompt 10).
  "child-not-confirmed",
  // Trips (Prompt 10: F15, F16, F20, F35, F41)
  "trip-started",
  "driver-arrived",
  "child-picked-up",
  "child-dropped",
  "child-received",
  // Review item 4: the driver marked the child not coming, or ended the run before the pickup.
  "child-not-coming",
  "location-stopped",
  "driver-late",
  "driver-at-gate",
  "all-children-in",
  "emergency",
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
  // Prompt 10: Arrived and "location stopped" (on by default), other trip
  // news (off), and the emergency button (on, critical).
  "tripAlerts",
  "trips",
  "emergency",
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
  tripAlerts: true,
  trips: false,
  emergency: true,
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
  /**
   * Prompt 10: always sounds (time-sensitive push) and ignores quiet hours,
   * but is not critical (no alarm): Arrived, location stopped.
   */
  urgent: boolean;
}

const spec = (group: NotificationGroup, template: string | null, hasWhen: boolean, critical = false, urgent = false): TypeSpec => ({
  group,
  critical,
  template,
  hasWhen,
  urgent,
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
  "trip-started": spec("trips", "cp_trip_started", true),
  "driver-arrived": spec("tripAlerts", "cp_driver_arrived", true, false, true),
  "child-picked-up": spec("trips", "cp_child_picked_up", true),
  "child-dropped": spec("trips", "cp_child_dropped", true),
  "child-received": spec("trips", null, true),
  "child-not-coming": spec("tripAlerts", "cp_child_not_coming", true),
  "location-stopped": spec("tripAlerts", "cp_location_stopped", true, false, true),
  "driver-late": spec("trips", "cp_driver_late", true),
  "driver-at-gate": spec("trips", "cp_driver_at_gate", true),
  "all-children-in": spec("trips", "cp_all_children_in", true),
  "emergency": spec("emergency", "cp_emergency", true, true),
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
  /** Prompt 10: trip types open the run's trip screen. */
  runId?: string | null;
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

/** Trip types (Prompt 10): they open /carpools/{id}/trip/{runId}. */
export const TRIP_TYPES: readonly NotificationType[] = [
  "trip-started",
  "driver-arrived",
  "child-picked-up",
  "child-dropped",
  "child-received",
  "child-not-coming",
  "child-not-confirmed",
  "location-stopped",
  "driver-late",
  "driver-at-gate",
  "all-children-in",
];

const RUN = /^\d{4}-\d{2}-\d{2}_(am|pm)$/;

const ID = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * The screen the app opens for a notification (go_router paths). Only IDs
 * go into it; the app checks the shape again before it navigates.
 */
export function routeFor(input: RouteInput): string {
  const carpool = input.carpoolId && ID.test(input.carpoolId) ? input.carpoolId : null;
  const run = input.runId && RUN.test(input.runId) ? input.runId : null;
  if (TRIP_TYPES.includes(input.type)) return carpool && run ? `/carpools/${carpool}/trip/${run}` : carpool ? `/carpools/${carpool}/schedule` : "/notifications";
  switch (input.type) {
    case "emergency":
      // Every member is told, also those without a child on the run.
      return carpool ? `/carpools/${carpool}/emergency` : "/notifications";
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
