/**
 * Retention schedule (spec section 7, Prompt 12, owner decision "Data
 * retention and collection" of 14 Nov 2026 in docs/DECISIONS.md). One
 * table for every data type: how long it is kept, from when, and what
 * deletes it. The privacy screen, the export, SECURITY.md and the App Store
 * answers list the same types (ids in DATA_TYPES). Pure; unit-tested.
 *
 * The owner will confirm the new periods with the lawyer (DECISIONS.md).
 * Every period here is one constant, so a change from the lawyer is a
 * one-line change.
 */

export const DAY_MS = 86_400_000;
export const YEAR_DAYS = 365;

/** Photos, trip summaries, consents and chat stay this long after the account closes. */
export const AFTER_CLOSURE_DAYS = YEAR_DAYS;
/** Archived routes (one per run) are kept this long after the run. */
export const ROUTE_ARCHIVE_DAYS = YEAR_DAYS;
/** Chat history is kept for the life of the chat plus this long. */
export const CHAT_AFTER_END_DAYS = YEAR_DAYS;
/** A handled report keeps its copy of the messages this long, then only the decision stays. */
export const REPORT_CONTEXT_DAYS = YEAR_DAYS;
/** Live trip points (the spec's "within 24 hours"; tripTick deletes them after 12 h). */
export const LIVE_POINTS_HOURS = 24;
/** The exact stop points of one run (homes, school) after the run ended. */
export const TRIP_STOPS_DAYS = 1;
/** Privacy requests are the proof that each request was answered. */
export const PRIVACY_REQUEST_DAYS = 3 * YEAR_DAYS;
/** Admin audit log. */
export const AUDIT_LOG_DAYS = 2 * YEAR_DAYS;
/** Sign-in history shown under "Recent sign-ins". */
export const LOGIN_HISTORY_DAYS = 90;
/** A device signed out (or not seen) this long is dropped from the list. */
export const DEVICE_STALE_DAYS = 180;
/** Data export files (the signed link works for 1 hour). */
export const EXPORT_FILE_DAYS = 1;
/** Abuse counters (scraping alerts). */
export const ABUSE_COUNTER_DAYS = 2;
/** Security alerts for admins once handled. */
export const SECURITY_ALERT_DAYS = YEAR_DAYS;
/** A closed carpool (card, members, runs, swaps, balances, its trips) is deleted 1 year after it closed (Prompt 12 review). */
export const CLOSED_CARPOOL_DAYS = YEAR_DAYS;
/** walletDaily/{uid}_{day}: the per-day limit counters live 35 days (TTL expiresAt; only today counts). */
export const WALLET_DAILY_DAYS = 35;

export type RetentionStart = "created" | "decision" | "runEnd" | "chatEnd" | "accountClosed" | "handled" | "never";

/** How a data type is deleted when its time comes. */
export type Enforcer =
  | "retentionDaily" // functions/src/privacy/jobs.ts (this prompt)
  | "tripTick" // functions/src/trips/flow.ts, every minute
  | "firestoreTtl" // Firestore TTL policy on expiresAt/expireAt (tool/firestore_ttl.sh)
  | "storageLifecycle" // tool/storage_lifecycle.json
  | "accountDeletion" // deleted at once when the parent deletes the account
  | "kept"; // never deleted automatically (ban list, transfer records)

export interface RetentionRule {
  /** Matches the ids in DATA_TYPES and the app's privacy screen. */
  id: DataTypeId;
  /** Where it lives (collections, storage paths, outside services). */
  where: string;
  /** Days after [from]; null = kept while the account is active, or as the law requires. */
  days: number | null;
  from: RetentionStart;
  enforcedBy: Enforcer[];
}

/**
 * Every data type the app collects (spec section 7, DECISIONS.md). The app
 * shows them on the privacy screen (lib/features/privacy/privacy_data.dart,
 * same ids and order) and the export holds one section per type.
 */
export const DATA_TYPES = [
  "account",
  "consents",
  "idPhotos",
  "children",
  "vehicle",
  "home",
  "carpools",
  "schedule",
  "trips",
  "liveLocation",
  "routeArchive",
  "chat",
  "ratings",
  "familyLinks",
  "handover",
  "emergencyContact",
  "notifications",
  "devices",
  "wallet",
  "reports",
  "analytics",
  "crashReports",
] as const;

export type DataTypeId = (typeof DATA_TYPES)[number];

export const RETENTION: readonly RetentionRule[] = [
  { id: "account", where: "users/{uid}, parentIds (ID reserved forever, not personal), Firebase Auth", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "consents", where: "users/{uid}/consents", days: AFTER_CLOSURE_DAYS, from: "accountClosed", enforcedBy: ["retentionDaily"] },
  {
    id: "idPhotos",
    where: "Storage verification/{uid}/cases, faceRefs/{uid}, driverPhotos/{uid}, selfieArchive/{uid} (KMS key), verifications/{caseId}",
    days: AFTER_CLOSURE_DAYS,
    from: "accountClosed",
    enforcedBy: ["retentionDaily"],
  },
  { id: "children", where: "children/{id}, handover lists", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "vehicle", where: "vehicles/{uid}", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "home", where: "homes/{uid}, parentLocations/{uid} (rounded), mapLimits, newParentEvents", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  {
    id: "carpools",
    // A closed carpool (the card, its runs, swaps, balances and trips) goes CLOSED_CARPOOL_DAYS after it closed (retentionDaily).
    where: "memberships, carpools/{id}/members, requests, driverConsents, pickupPoints, carpoolWanted; names left in other parents' records become initials",
    days: 0,
    from: "accountClosed",
    enforcedBy: ["accountDeletion", "retentionDaily"],
  },
  { id: "schedule", where: "carpools/{id}/schedule (future runs released), swaps", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "trips", where: "trips/{id} run summaries (who drove, date, times, on time, children counted)", days: AFTER_CLOSURE_DAYS, from: "accountClosed", enforcedBy: ["retentionDaily"] },
  { id: "liveLocation", where: "trips/{id}/points, carpools/{id}/emergencies, tripStops/{id}", days: 1, from: "runEnd", enforcedBy: ["tripTick", "firestoreTtl", "retentionDaily"] },
  { id: "routeArchive", where: "Storage routeArchive/{yyyy}/{tripId}.json.gz (Coldline), routeArchives/{tripId}", days: ROUTE_ARCHIVE_DAYS, from: "runEnd", enforcedBy: ["retentionDaily", "storageLifecycle"] },
  { id: "chat", where: "Stream Chat (messages, first names, parent IDs), chatChannels", days: CHAT_AFTER_END_DAYS, from: "chatEnd", enforcedBy: ["retentionDaily"] },
  { id: "ratings", where: "ratings, trustSummaries, ratingFlags", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "familyLinks", where: "guardianLinks, guardianRequests", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "handover", where: "handoverAdults/{childId}", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "emergencyContact", where: "emergencyContacts/{uid}", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "notifications", where: "users/{uid}/notifications (60 days), notificationEvents (30 days), pushTokens, notificationSettings", days: 60, from: "created", enforcedBy: ["firestoreTtl", "accountDeletion"] },
  { id: "devices", where: "users/{uid}/devices, users/{uid}/logins (90 days)", days: LOGIN_HISTORY_DAYS, from: "created", enforcedBy: ["firestoreTtl", "accountDeletion"] },
  // The lawyer decides how long transfer records stay (Prompt 12: "as long as the law requires").
  { id: "wallet", where: "transfers, transferResults (append-only), wallets/{uid} (partner reference); the money is held by the partner", days: null, from: "never", enforcedBy: ["kept"] },
  { id: "reports", where: "reports (open reports are kept after deletion), message copies in reports", days: REPORT_CONTEXT_DAYS, from: "handled", enforcedBy: ["retentionDaily"] },
  { id: "analytics", where: "Google Analytics for Firebase (screens and features, no names, numbers, IDs, text or places)", days: 60, from: "created", enforcedBy: ["kept"] },
  { id: "crashReports", where: "Sentry (scrubbed errors)", days: 90, from: "created", enforcedBy: ["kept"] },
];

/** Kept after an account is deleted, and why (spec section 7, Prompt 12). */
export const KEPT_AFTER_DELETION = [
  { what: "bannedIds/{hash}", why: "keyed national-ID hash on the ban list (only when the parent was banned)" },
  { what: "reports (open)", why: "open reports against or by the parent until an admin handles them" },
  { what: "transfers, transferResults", why: "transfer records for as long as the law requires (lawyer to confirm)" },
  { what: "auditLog", why: "admin actions (2 years)" },
  { what: "parentIds/{id}", why: "the parent ID is reserved forever so it is never reused (holds only the uid)" },
  { what: "closedAccounts/{uid}", why: "the purge date and the deletion report (no name, phone or ID)" },
  { what: "photos, trip summaries, route archives, consents, chat", why: "1 year after closure (owner decision 14 Nov 2026), admin-only with a logged reason" },
] as const;

export function rule(id: DataTypeId): RetentionRule {
  const r = RETENTION.find((x) => x.id === id);
  if (!r) throw new Error(`no retention rule for ${id}`);
  return r;
}

/** When something that waits for the account's closure is deleted. */
export function purgeAfterClosure(closedAtMs: number, days = AFTER_CLOSURE_DAYS): number {
  return closedAtMs + days * DAY_MS;
}

/** When a run's archived route is deleted. */
export function routeArchivePurgeAt(runEndedAtMs: number): number {
  return runEndedAtMs + ROUTE_ARCHIVE_DAYS * DAY_MS;
}

/** When an ended chat (carpool closed, a private chat whose parent left or blocked) is deleted. */
export function chatPurgeAt(endedAtMs: number): number {
  return endedAtMs + CHAT_AFTER_END_DAYS * DAY_MS;
}

/** When a handled report loses its copy of the messages. */
export function reportContextPurgeAt(handledAtMs: number): number {
  return handledAtMs + REPORT_CONTEXT_DAYS * DAY_MS;
}

/** True when the time has come (a null date never comes). */
export function isDue(purgeAtMs: number | null, nowMs: number): boolean {
  return purgeAtMs !== null && purgeAtMs <= nowMs;
}

/** Cutoff for "older than [days]" deletions. */
export function cutoff(nowMs: number, days: number): number {
  return nowMs - days * DAY_MS;
}

/** The Firestore TTL timestamp for a record created at [createdAtMs] that lives [days]. */
export function expiresAt(createdAtMs: number, days: number): number {
  return createdAtMs + days * DAY_MS;
}
