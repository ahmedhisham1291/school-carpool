import type { AdminRole } from "./guard";

/**
 * Data shapes and small store interfaces for the admin panel (F14). The
 * logic in users.ts, schools.ts, admins.ts and lists.ts runs over these so
 * it can be unit-tested; the Firestore and Auth versions are in store.ts.
 */

export type AccountStatus = "unverified" | "pending" | "verified" | "rejected" | "suspended";

export interface AuditEntry {
  actorUid: string;
  action: string;
  target: string;
  reasonCode?: string | null;
  /** Small, non-personal facts only (counts, kinds, IDs). Never names, phones or notes. */
  details?: Record<string, string | number | boolean | null>;
  ip: string | null;
}

/** A user record as stored (users/{uid}). The phone never leaves the server unmasked. */
export interface StoredUser {
  uid: string;
  parentId: string;
  firstName: string | null;
  lastName: string | null;
  phone: string | null;
  email: string | null;
  status: AccountStatus;
  banned: boolean;
  statusBeforeSuspension: AccountStatus | null;
  createdAtMs: number;
}

export interface CaseHistoryItem {
  caseId: string;
  scope: string;
  status: string;
  reasonCode: string | null;
  reviewerUid: string | null;
  submittedAtMs: number;
  decidedAtMs: number | null;
}

export interface ActionHistoryItem {
  action: string;
  actorUid: string;
  reasonCode: string | null;
  timeMs: number;
}

export interface ModerationWrite {
  uid: string;
  action: "suspend" | "unsuspend" | "ban";
  status: AccountStatus;
  statusBeforeSuspension: AccountStatus | null;
  banned: boolean;
  /** National ID hash to add to the ban list (ban only). */
  banNationalIdHash: string | null;
  reasonCode: string;
  note: string | null;
  audit: AuditEntry;
}

export interface UsersStore {
  /** Fixed window rate limit per admin. False when the limit is reached. */
  consumeSearchQuota(adminUid: string, nowMs: number, limit: number, windowMs: number): Promise<boolean>;
  findByParentId(parentId: string): Promise<StoredUser | undefined>;
  findByPhone(e164: string): Promise<StoredUser[]>;
  /** Prefix match on the normalized full name, plus whole-word match on its first word. */
  findByName(normalized: string, limit: number): Promise<StoredUser[]>;
  getUser(uid: string): Promise<StoredUser | undefined>;
  caseHistory(uid: string, limit: number): Promise<CaseHistoryItem[]>;
  actionHistory(uid: string, limit: number): Promise<ActionHistoryItem[]>;
  isAdmin(uid: string): Promise<boolean>;
  /** National ID hash held by this account, if any. */
  nationalIdHashOf(uid: string): Promise<string | null>;
  /** Writes the moderation and its audit entry in one transaction; fails with invalid-state if the status changed meanwhile. */
  applyModeration(write: ModerationWrite, expectedStatus: AccountStatus): Promise<void>;
  audit(entry: AuditEntry): Promise<void>;
}

/** Sessions and the "verified" claim of a parent account. */
export interface UserClaims {
  setVerified(uid: string, verified: boolean): Promise<void>;
  revokeSessions(uid: string): Promise<void>;
}

export type SchoolStatus = "active" | "awaiting_review" | "merged";

export interface GeoPointValue {
  lat: number;
  lng: number;
}

export interface SchoolRecord {
  id: string;
  nameAr: string;
  nameEn: string;
  governorate: string;
  city: string;
  location: GeoPointValue | null;
  status: SchoolStatus;
  source: string;
  addedBy: string | null;
  mergedInto: string | null;
  createdAtMs: number;
}

export interface AreaRecord {
  id: string;
  schoolId: string;
  nameAr: string;
  nameEn: string;
  center: GeoPointValue;
}

export interface SchoolsStore {
  newId(collection: "schools" | "areas"): string;
  getSchool(id: string): Promise<SchoolRecord | undefined>;
  listSchools(query: { status: SchoolStatus; governorate: string | null; afterId: string | null; limit: number }): Promise<SchoolRecord[]>;
  saveSchool(school: SchoolRecord, isNew: boolean, audit: AuditEntry): Promise<void>;
  listAreas(schoolId: string): Promise<AreaRecord[]>;
  getArea(id: string): Promise<AreaRecord | undefined>;
  saveArea(area: AreaRecord, isNew: boolean, audit: AuditEntry): Promise<void>;
  /** Marks [fromId] merged into [intoId] and moves its children; returns how many children moved. */
  mergeSchool(fromId: string, intoId: string, audit: AuditEntry): Promise<number>;
}

export interface AdminRecord {
  uid: string;
  email: string;
  displayName: string;
  role: AdminRole;
  disabled: boolean;
  createdAtMs: number;
}

export interface AdminsStore {
  listAdmins(): Promise<AdminRecord[]>;
  getAdmin(uid: string): Promise<AdminRecord | undefined>;
  saveAdmin(record: AdminRecord, createdBy: string, audit: AuditEntry): Promise<void>;
  /** Disabling also sets revokedAt: tokens issued before it stop working at once. */
  setDisabled(uid: string, disabled: boolean, audit: AuditEntry): Promise<void>;
  /** Removes the record of an admin whose creation failed part way. */
  removeAdmin(uid: string): Promise<void>;
  audit(entry: AuditEntry): Promise<void>;
}

/** Firebase Auth operations for admin accounts. */
export interface AdminAccounts {
  /** Creates an email account (no phone, no password yet). Fails with already-exists. */
  create(email: string, displayName: string): Promise<string>;
  setRole(uid: string, role: AdminRole): Promise<void>;
  /** One-time link where the new admin sets their own password. */
  passwordSetupLink(email: string): Promise<string>;
  setDisabled(uid: string, disabled: boolean): Promise<void>;
  /** Removes an account whose creation failed part way (no orphans). */
  remove(uid: string): Promise<void>;
}

export interface ReportItem {
  id: string;
  reporterUid: string;
  targetType: string;
  targetId: string;
  reason: string;
  status: string;
  createdAtMs: number;
  /** Prompt 9: child safety or dangerous driving (reviewed the same day). */
  urgent: boolean;
  /** Prompt 9: the kind of chat ("private", "school", "area", "carpool") or "". */
  kind: string;
}

export interface AuditItem {
  id: string;
  actorUid: string;
  action: string;
  target: string;
  reasonCode: string | null;
  ip: string | null;
  timeMs: number;
}

export interface ListsStore {
  listReports(status: string, limit: number): Promise<ReportItem[]>;
  listAudit(afterId: string | null, limit: number): Promise<AuditItem[]>;
  /** Display names of admins by uid (for the audit log). */
  adminNames(uids: string[]): Promise<Map<string, string>>;
  audit(entry: AuditEntry): Promise<void>;
}
