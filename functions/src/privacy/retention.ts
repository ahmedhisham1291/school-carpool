/**
 * Retention schedule (spec section 7, Prompt 12, owner decisions "Data
 * retention and collection" of 14 Nov 2026 and "Data after account
 * deletion" of 16 Nov 2026 in docs/DECISIONS.md). One
 * table for every data type: how long it is kept, from when, and what
 * deletes it. The privacy screen, the export, SECURITY.md and the App Store
 * answers list the same types (ids in DATA_TYPES). Pure; unit-tested.
 *
 * The lawyer confirmed the 14 Nov periods (docs/DECISIONS.md, owner update
 * 14 Nov 2026); the 16 Nov change (photos, face reference, case records,
 * routes and chat messages deleted WITH the account) is shorter and waits
 * for the lawyer's confirmation (docs/open-items.md B13). Every period
 * here is one constant, so a change is a one-line change.
 */

export const DAY_MS = 86_400_000;
export const YEAR_DAYS = 365;

/**
 * The minimised records that stay after an account closes (the parent's
 * part of shared run summaries, the proof of consent, Settle up records)
 * are kept this long. Photos, the face reference, case records, routes
 * and the parent's chat messages are NOT kept: they go with the account.
 */
export const AFTER_CLOSURE_DAYS = YEAR_DAYS;
/**
 * Safety hold (owner decision 16 Nov 2026): when an open report or rating
 * flag about the parent exists at deletion, the evidence (photos, face
 * reference, case records, routes of runs they drove) waits this long so
 * the admins can finish the case; then it is deleted whatever the state.
 */
export const SAFETY_HOLD_DAYS = 30;
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
/**
 * Sign-in history shown under "Recent sign-ins" (device, platform, time).
 * 180 days (was 90): Anti-Cybercrime Law No. 175 of 2018, Art. 2 asks a
 * "service provider" to keep information-system logs (user identity,
 * traffic data, device) for 180 continuous days. Whether the app is a
 * service provider in that sense is a question for the lawyer
 * (docs/legal/egypt-legal-review.md section 4); keeping 180 days is the
 * safe side. NOTE: these records still go at once when the parent deletes
 * the account (lawyer question 4.2).
 */
export const LOGIN_HISTORY_DAYS = 180;
/** A device signed out (or not seen) this long is dropped from the list. */
export const DEVICE_STALE_DAYS = 180;
/** Data export files (the signed link works for 1 hour). */
export const EXPORT_FILE_DAYS = 1;
/** Abuse counters (scraping alerts). */
export const ABUSE_COUNTER_DAYS = 2;
/**
 * Transfer records (transfers, transferResults): 5 years (lawyer
 * confirmed, owner answer 14 Nov 2026 13:29, DECISIONS.md).
 */
export const TRANSFER_RECORD_YEARS = 5;
/** Security alerts for admins once handled. */
export const SECURITY_ALERT_DAYS = YEAR_DAYS;
/** A closed carpool (card, members, runs, swaps, balances) is deleted 1 year after it closed (Prompt 12 review); its trips stay per parent (owner, 14 Nov 2026 13:29). */
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
  "settleUp",
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
    // With the account; at most SAFETY_HOLD_DAYS later when an open report about the parent exists.
    where: "Storage verification/{uid}/cases, faceRefs/{uid}, driverPhotos/{uid}, selfieArchive/{uid} (KMS key), verifications/{caseId}",
    days: 0,
    from: "accountClosed",
    enforcedBy: ["accountDeletion", "retentionDaily"],
  },
  { id: "children", where: "children/{id}, handover lists", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "vehicle", where: "vehicles/{uid}", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "home", where: "homes/{uid}, parentLocations/{uid} (rounded), mapLimits, newParentEvents", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  {
    id: "carpools",
    // A closed carpool (the card, its runs, swaps, balances) goes CLOSED_CARPOOL_DAYS after it
    // closed (retentionDaily); its trips stay per parent: active + 1 year (trip_retention.ts).
    where: "memberships, carpools/{id}/members, requests, driverConsents, pickupPoints, carpoolWanted; names left in other parents' records become initials",
    days: 0,
    from: "accountClosed",
    enforcedBy: ["accountDeletion", "retentionDaily"],
  },
  { id: "schedule", where: "carpools/{id}/schedule (future runs released), swaps", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "trips", where: "trips/{id} run summaries (who drove, date, times, on time, children counted); a deleted parent is an initial at once", days: AFTER_CLOSURE_DAYS, from: "accountClosed", enforcedBy: ["accountDeletion", "retentionDaily"] },
  { id: "liveLocation", where: "trips/{id}/points, carpools/{id}/emergencies, tripStops/{id}", days: 1, from: "runEnd", enforcedBy: ["tripTick", "firestoreTtl", "retentionDaily"] },
  { id: "routeArchive", where: "Storage routeArchive/{yyyy}/{tripId}.json.gz (Coldline), routeArchives/{tripId}; a deleted driver's routes go with the account", days: ROUTE_ARCHIVE_DAYS, from: "runEnd", enforcedBy: ["retentionDaily", "storageLifecycle", "accountDeletion"] },
  { id: "chat", where: "Stream Chat (messages, first names, parent IDs), chatChannels; a deleted parent's own messages go with the account", days: CHAT_AFTER_END_DAYS, from: "chatEnd", enforcedBy: ["retentionDaily", "accountDeletion"] },
  { id: "ratings", where: "ratings, trustSummaries, ratingFlags", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "familyLinks", where: "guardianLinks, guardianRequests", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "handover", where: "handoverAdults/{childId}", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "emergencyContact", where: "emergencyContacts/{uid}", days: 0, from: "accountClosed", enforcedBy: ["accountDeletion"] },
  { id: "notifications", where: "users/{uid}/notifications (60 days), notificationEvents (30 days), pushTokens, notificationSettings", days: 60, from: "created", enforcedBy: ["firestoreTtl", "accountDeletion"] },
  { id: "devices", where: "users/{uid}/devices, users/{uid}/logins (90 days)", days: LOGIN_HISTORY_DAYS, from: "created", enforcedBy: ["firestoreTtl", "accountDeletion"] },
  // Transfer records: 5 years (DECISIONS.md, owner answers 14 Nov 13:29).
  // Nothing deletes them yet (MONEY: append-only); a deletion job at the
  // end of the period needs the owner's go.
  { id: "wallet", where: "transfers, transferResults (append-only), wallets/{uid} (partner reference); the money is held by the partner", days: TRANSFER_RECORD_YEARS * YEAR_DAYS, from: "created", enforcedBy: ["kept"] },
  // Settle up (F45): records of payments between two parents (never the
  // money). Same rule as trips: while either party's account is active + 1
  // year (settle_up/model.ts planRetention). The InstaPay address goes at
  // once with the account. The owner and the lawyer confirm the period
  // (docs/open-items.md).
  {
    id: "settleUp",
    where: "settleUps/{id} (payment records between two parents; a deleted parent becomes an initial), settleUpAddresses/{uid} (InstaPay address, deleted at once), settleUpLimits",
    days: AFTER_CLOSURE_DAYS,
    from: "accountClosed",
    enforcedBy: ["accountDeletion", "retentionDaily"],
  },
  { id: "reports", where: "reports (open reports are kept after deletion), message copies in reports", days: REPORT_CONTEXT_DAYS, from: "handled", enforcedBy: ["retentionDaily"] },
  { id: "analytics", where: "Google Analytics for Firebase (screens and features, no names, numbers, IDs, text or places)", days: 60, from: "created", enforcedBy: ["kept"] },
  { id: "crashReports", where: "Sentry (scrubbed errors)", days: 90, from: "created", enforcedBy: ["kept"] },
];

/** Kept after an account is deleted, and why (spec section 7, Prompt 12). */
export const KEPT_AFTER_DELETION = [
  { what: "bannedIds/{hash}", why: "keyed national-ID hash on the ban list (only when the parent was banned)" },
  { what: "reports", why: "reports about or by the parent (safety); a handled report loses its copy of the messages after 1 year" },
  { what: "transfers, transferResults", why: "transfer records for as long as the law requires (5 years, confirmed by the lawyer and the owner)" },
  { what: "auditLog", why: "admin actions (2 years)" },
  { what: "parentIds/{id}", why: "the parent ID is reserved forever so it is never reused (holds only the uid)" },
  { what: "closedAccounts/{uid}", why: "the purge date and the deletion report (no name, phone or ID)" },
  { what: "settleUps", why: "payment records between two parents stay for the other parent while either account is active + 1 year; the deleted parent shows as an initial" },
  { what: "trips", why: "run summaries shared with other families: the deleted parent is an initial at once; their part is anonymised 1 year after closure" },
  { what: "users/{uid}/consents", why: "proof of consent (document version and time, no name), 1 year after closure" },
  { what: "evidence under a safety hold", why: "only when an open report about the parent exists at deletion: photos, face reference, case records and routes wait at most 30 days, then are deleted" },
] as const;

/**
 * Deleted WITH the account (owner decision 16 Nov 2026, App Review
 * guideline 5.1.1(v)); the public pages and the delete screen say the same.
 */
export const DELETED_WITH_ACCOUNT = [
  "profile, phone number, email, parent ID link",
  "ID photos, selfies, school ID, licence and driver photos, the face reference, verification case records",
  "home address and exact pin, children, car, emergency contact",
  "every chat message the parent wrote (private and group chats)",
  "devices, sign-in history, push tokens, notifications",
  "archived routes of the runs the parent drove",
] as const;

export function rule(id: DataTypeId): RetentionRule {
  const r = RETENTION.find((x) => x.id === id);
  if (!r) throw new Error(`no retention rule for ${id}`);
  return r;
}

/** When the evidence of a closed account is deleted: at once, or after the safety hold. */
export function evidencePurgeAt(closedAtMs: number, hold: boolean): number {
  return hold ? closedAtMs + SAFETY_HOLD_DAYS * DAY_MS : closedAtMs;
}

/** When a kept record that waits for the account's closure is deleted. */
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
