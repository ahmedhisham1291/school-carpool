import type { Auth } from "firebase-admin/auth";
import {
  FieldValue,
  GeoPoint,
  Timestamp,
  type DocumentData,
  type DocumentSnapshot,
  type Firestore,
  type Query,
} from "firebase-admin/firestore";
import { errorCode, USERS } from "../auth/accounts";
import { normalizeText } from "../text/normalize";
import { AdminError } from "./errors";
import type { AdminRole } from "./guard";
import type {
  AccountStatus,
  ActionHistoryItem,
  AdminAccounts,
  AdminRecord,
  AdminsStore,
  AreaRecord,
  AuditEntry,
  AuditItem,
  CaseHistoryItem,
  GeoPointValue,
  ListsStore,
  ModerationWrite,
  ReportItem,
  SchoolRecord,
  SchoolsStore,
  SchoolStatus,
  StoredUser,
  UsersStore,
} from "./types";

/** Collections of the admin panel. All closed to the app (firestore.rules). */
export const AUDIT_LOG = "auditLog";
export const ADMINS = "admins";
/** Search rate limit counters per admin. */
export const ADMIN_LIMITS = "adminLimits";
/** Moderation records with the admin's note (server only; the parent never sees the note). */
export const MODERATIONS = "moderations";
export const SCHOOLS = "schools";
export const AREAS = "areas";
export const REPORTS = "reports";
const VERIFICATIONS = "verifications";
const NATIONAL_IDS = "nationalIds";
const BANNED_IDS = "bannedIds";
const CHILDREN = "children";

const STATUSES: readonly AccountStatus[] = ["unverified", "pending", "verified", "rejected", "suspended"];

function millis(value: unknown): number {
  return value instanceof Timestamp ? value.toMillis() : 0;
}

function str(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function status(value: unknown): AccountStatus {
  return STATUSES.includes(value as AccountStatus) ? (value as AccountStatus) : "unverified";
}

function point(value: unknown): GeoPointValue | null {
  return value instanceof GeoPoint ? { lat: value.latitude, lng: value.longitude } : null;
}

/** An audit entry as stored: same shape as Prompt 3's entries, plus optional details. */
export function auditDoc(entry: AuditEntry): DocumentData {
  const doc: DocumentData = {
    actorUid: entry.actorUid,
    action: entry.action,
    target: entry.target,
    reasonCode: entry.reasonCode ?? null,
    ip: entry.ip,
    time: FieldValue.serverTimestamp(),
  };
  if (entry.details) doc.details = entry.details;
  return doc;
}

function userFromDoc(uid: string, data: DocumentData): StoredUser {
  return {
    uid,
    parentId: String(data.parentId ?? ""),
    firstName: str(data.firstName),
    lastName: str(data.lastName),
    phone: str(data.phone),
    email: str(data.email),
    status: status(data.status),
    banned: data.banned === true,
    statusBeforeSuspension: data.statusBeforeSuspension ? status(data.statusBeforeSuspension) : null,
    createdAtMs: millis(data.createdAt),
  };
}

/** Starts a query after the document [afterId] (cursor paging), if it still exists. */
async function after(db: Firestore, collection: string, query: Query, afterId: string | null): Promise<Query> {
  if (!afterId) return query;
  const snap = await db.collection(collection).doc(afterId).get();
  return snap.exists ? query.startAfter(snap) : query;
}

export class FirestoreUsersStore implements UsersStore {
  constructor(private readonly db: Firestore) {}

  consumeSearchQuota(adminUid: string, nowMs: number, limit: number, windowMs: number): Promise<boolean> {
    const ref = this.db.collection(ADMIN_LIMITS).doc(adminUid);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const start = typeof snap.get("windowStartMs") === "number" ? (snap.get("windowStartMs") as number) : 0;
      const count = typeof snap.get("count") === "number" ? (snap.get("count") as number) : 0;
      if (nowMs - start >= windowMs) {
        tx.set(ref, { windowStartMs: nowMs, count: 1 });
        return true;
      }
      if (count >= limit) return false;
      tx.set(ref, { windowStartMs: start, count: count + 1 });
      return true;
    });
  }

  async findByParentId(parentId: string): Promise<StoredUser | undefined> {
    const snap = await this.db.collection(USERS).where("parentId", "==", parentId).limit(1).get();
    const doc = snap.docs[0];
    return doc ? userFromDoc(doc.id, doc.data()) : undefined;
  }

  async findByPhone(e164: string): Promise<StoredUser[]> {
    const snap = await this.db.collection(USERS).where("phone", "==", e164).limit(5).get();
    return snap.docs.map((doc) => userFromDoc(doc.id, doc.data()));
  }

  async findByName(normalized: string, limit: number): Promise<StoredUser[]> {
    const users = this.db.collection(USERS);
    const [prefix, word] = await Promise.all([
      users.where("nameKey", ">=", normalized).where("nameKey", "<=", `${normalized}`).limit(limit).get(),
      users.where("nameTokens", "array-contains", normalized.split(" ")[0]).limit(limit).get(),
    ]);
    const found = new Map<string, StoredUser>();
    for (const doc of [...prefix.docs, ...word.docs]) found.set(doc.id, userFromDoc(doc.id, doc.data()));
    return [...found.values()].slice(0, limit);
  }

  async getUser(uid: string): Promise<StoredUser | undefined> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    return snap.exists ? userFromDoc(uid, snap.data() ?? {}) : undefined;
  }

  async caseHistory(uid: string, limit: number): Promise<CaseHistoryItem[]> {
    const snap = await this.db
      .collection(VERIFICATIONS)
      .where("uid", "==", uid)
      .orderBy("submittedAt", "desc")
      .limit(limit)
      .get();
    return snap.docs.map((doc) => ({
      caseId: doc.id,
      scope: String(doc.get("scope") ?? "identity"),
      status: String(doc.get("status") ?? ""),
      reasonCode: str(doc.get("reasonCode")),
      reviewerUid: str(doc.get("reviewerUid")),
      submittedAtMs: millis(doc.get("submittedAt")),
      decidedAtMs: doc.get("decidedAt") ? millis(doc.get("decidedAt")) : null,
    }));
  }

  async actionHistory(uid: string, limit: number): Promise<ActionHistoryItem[]> {
    const snap = await this.db
      .collection(AUDIT_LOG)
      .where("target", "==", `${USERS}/${uid}`)
      .orderBy("time", "desc")
      .limit(limit)
      .get();
    return snap.docs
      .map((doc) => ({
        action: String(doc.get("action") ?? ""),
        actorUid: String(doc.get("actorUid") ?? ""),
        reasonCode: str(doc.get("reasonCode")),
        timeMs: millis(doc.get("time")),
      }))
      .filter((item) => item.action !== "user.view");
  }

  async isAdmin(uid: string): Promise<boolean> {
    return (await this.db.collection(ADMINS).doc(uid).get()).exists;
  }

  async nationalIdHashOf(uid: string): Promise<string | null> {
    const snap = await this.db.collection(NATIONAL_IDS).where("uid", "==", uid).limit(1).get();
    return snap.docs[0]?.id ?? null;
  }

  applyModeration(write: ModerationWrite, expectedStatus: AccountStatus): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const userRef = this.db.collection(USERS).doc(write.uid);
      const current = await tx.get(userRef);
      if (!current.exists || status(current.get("status")) !== expectedStatus) throw new AdminError("invalid-state");
      tx.update(userRef, {
        status: write.status,
        statusBeforeSuspension: write.statusBeforeSuspension,
        banned: write.banned,
        // The app refreshes its token when this changes (Prompt 3 review fix).
        claimsUpdatedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      tx.create(this.db.collection(MODERATIONS).doc(), {
        uid: write.uid,
        action: write.action,
        reasonCode: write.reasonCode,
        note: write.note,
        actorUid: write.audit.actorUid,
        time: FieldValue.serverTimestamp(),
      });
      if (write.banNationalIdHash) {
        tx.set(this.db.collection(BANNED_IDS).doc(write.banNationalIdHash), {
          byUid: write.audit.actorUid,
          source: "moderation",
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      tx.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(write.audit));
    });
  }

  async audit(entry: AuditEntry): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create(auditDoc(entry));
  }
}

function schoolFromDoc(id: string, data: DocumentData): SchoolRecord {
  const s = data.status;
  return {
    id,
    nameAr: String(data.nameAr ?? ""),
    nameEn: String(data.nameEn ?? ""),
    governorate: String(data.governorate ?? ""),
    city: String(data.city ?? ""),
    location: point(data.location),
    status: s === "awaiting_review" || s === "merged" ? (s as SchoolStatus) : "active",
    source: String(data.source ?? "admin"),
    addedBy: str(data.addedBy),
    mergedInto: str(data.mergedInto),
    createdAtMs: millis(data.createdAt),
  };
}

function areaFromDoc(id: string, data: DocumentData): AreaRecord {
  return {
    id,
    schoolId: String(data.schoolId ?? ""),
    nameAr: String(data.nameAr ?? ""),
    nameEn: String(data.nameEn ?? ""),
    center: point(data.center) ?? { lat: 0, lng: 0 },
  };
}

export class FirestoreSchoolsStore implements SchoolsStore {
  constructor(private readonly db: Firestore) {}

  newId(collection: "schools" | "areas"): string {
    return this.db.collection(collection === "schools" ? SCHOOLS : AREAS).doc().id;
  }

  async getSchool(id: string): Promise<SchoolRecord | undefined> {
    const snap = await this.db.collection(SCHOOLS).doc(id).get();
    return snap.exists ? schoolFromDoc(id, snap.data() ?? {}) : undefined;
  }

  async listSchools(q: { status: SchoolStatus; governorate: string | null; afterId: string | null; limit: number }) {
    let query: Query = this.db.collection(SCHOOLS).where("status", "==", q.status);
    if (q.governorate) query = query.where("governorate", "==", q.governorate);
    query = await after(this.db, SCHOOLS, query.orderBy("nameAr"), q.afterId);
    const snap = await query.limit(q.limit).get();
    return snap.docs.map((doc) => schoolFromDoc(doc.id, doc.data()));
  }

  async saveSchool(school: SchoolRecord, isNew: boolean, audit: AuditEntry): Promise<void> {
    const batch = this.db.batch();
    const fields: DocumentData = {
      nameAr: school.nameAr,
      nameEn: school.nameEn,
      // Spelling-tolerant matching (Prompt 4B search uses the same normalization).
      searchKeys: [normalizeText(school.nameAr), normalizeText(school.nameEn)],
      governorate: school.governorate,
      city: school.city,
      location: school.location ? new GeoPoint(school.location.lat, school.location.lng) : null,
      status: school.status,
      mergedInto: school.mergedInto,
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (!isNew) {
      // The schools import (Prompt 4B) never overwrites an admin's edit;
      // an approved "Other" school drops the parent's uid (addedBy null).
      fields.adminEdited = true;
      fields.addedBy = school.addedBy;
    }
    const ref = this.db.collection(SCHOOLS).doc(school.id);
    if (isNew) {
      batch.create(ref, {
        ...fields,
        source: school.source,
        addedBy: school.addedBy,
        createdAt: Timestamp.fromMillis(school.createdAtMs),
      });
    } else {
      batch.update(ref, fields);
    }
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await batch.commit();
  }

  async listAreas(schoolId: string): Promise<AreaRecord[]> {
    const snap = await this.db.collection(AREAS).where("schoolId", "==", schoolId).limit(200).get();
    return snap.docs.map((doc) => areaFromDoc(doc.id, doc.data())).sort((a, b) => a.nameAr.localeCompare(b.nameAr, "ar"));
  }

  async getArea(id: string): Promise<AreaRecord | undefined> {
    const snap = await this.db.collection(AREAS).doc(id).get();
    return snap.exists ? areaFromDoc(id, snap.data() ?? {}) : undefined;
  }

  async saveArea(area: AreaRecord, isNew: boolean, audit: AuditEntry): Promise<void> {
    const batch = this.db.batch();
    const ref = this.db.collection(AREAS).doc(area.id);
    const fields: DocumentData = {
      schoolId: area.schoolId,
      nameAr: area.nameAr,
      nameEn: area.nameEn,
      center: new GeoPoint(area.center.lat, area.center.lng),
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (isNew) batch.create(ref, { ...fields, createdAt: FieldValue.serverTimestamp() });
    else batch.update(ref, fields);
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await batch.commit();
  }

  async mergeSchool(fromId: string, intoId: string, audit: AuditEntry): Promise<number> {
    // A school typed under "Other" belongs to one parent's children: far
    // below the 500 writes of one batch.
    const children = await this.db.collection(CHILDREN).where("schoolId", "==", fromId).limit(400).get();
    const batch = this.db.batch();
    batch.update(this.db.collection(SCHOOLS).doc(fromId), {
      status: "merged",
      mergedInto: intoId,
      updatedAt: FieldValue.serverTimestamp(),
    });
    const into = await this.db.collection(SCHOOLS).doc(intoId).get();
    const intoName = String(into.get("nameAr") ?? "");
    for (const doc of children.docs) {
      batch.update(doc.ref, {
        schoolId: intoId,
        ...(intoName ? { schoolName: intoName } : {}),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc({ ...audit, details: { ...audit.details, children: children.size } }));
    await batch.commit();
    return children.size;
  }
}

function adminFromDoc(uid: string, data: DocumentData): AdminRecord {
  return {
    uid,
    email: String(data.email ?? ""),
    displayName: String(data.displayName ?? ""),
    role: data.role === "superAdmin" ? "superAdmin" : "admin",
    disabled: data.disabled === true,
    createdAtMs: millis(data.createdAt),
  };
}

export class FirestoreAdminsStore implements AdminsStore {
  constructor(private readonly db: Firestore) {}

  async listAdmins(): Promise<AdminRecord[]> {
    const snap = await this.db.collection(ADMINS).orderBy("createdAt").limit(200).get();
    return snap.docs.map((doc) => adminFromDoc(doc.id, doc.data()));
  }

  async getAdmin(uid: string): Promise<AdminRecord | undefined> {
    const snap = await this.db.collection(ADMINS).doc(uid).get();
    return snap.exists ? adminFromDoc(uid, snap.data() ?? {}) : undefined;
  }

  async saveAdmin(record: AdminRecord, createdBy: string, audit: AuditEntry): Promise<void> {
    const batch = this.db.batch();
    batch.set(this.db.collection(ADMINS).doc(record.uid), {
      email: record.email,
      displayName: record.displayName,
      role: record.role,
      disabled: record.disabled,
      createdBy,
      createdAt: Timestamp.fromMillis(record.createdAtMs),
    });
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await batch.commit();
  }

  async setDisabled(uid: string, disabled: boolean, audit: AuditEntry): Promise<void> {
    const batch = this.db.batch();
    const update: DocumentData = { disabled, updatedAt: FieldValue.serverTimestamp() };
    // Tokens issued before this moment are refused by the functions and rules.
    if (disabled) update.revokedAt = FieldValue.serverTimestamp();
    batch.update(this.db.collection(ADMINS).doc(uid), update);
    batch.create(this.db.collection(AUDIT_LOG).doc(), auditDoc(audit));
    await batch.commit();
  }

  async removeAdmin(uid: string): Promise<void> {
    await this.db.collection(ADMINS).doc(uid).delete();
  }

  async audit(entry: AuditEntry): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create(auditDoc(entry));
  }
}

export class FirebaseAdminAccounts implements AdminAccounts {
  constructor(private readonly auth: Auth) {}

  async create(email: string, displayName: string): Promise<string> {
    try {
      // Email marked verified: the super admin vouches for it, and Identity
      // Platform needs a verified email before a second factor can be added.
      const user = await this.auth.createUser({ email, emailVerified: true, displayName });
      return user.uid;
    } catch (error) {
      if (errorCode(error) === "auth/email-already-exists") throw new AdminError("already-exists");
      throw error;
    }
  }

  async setRole(uid: string, role: AdminRole): Promise<void> {
    await this.auth.setCustomUserClaims(uid, role === "superAdmin" ? { admin: true, superAdmin: true } : { admin: true });
  }

  passwordSetupLink(email: string): Promise<string> {
    // Generated, not sent: the blocking function refuses password-reset
    // emails, and the super admin passes the link on directly.
    return this.auth.generatePasswordResetLink(email);
  }

  async setDisabled(uid: string, disabled: boolean): Promise<void> {
    await this.auth.updateUser(uid, { disabled });
    if (disabled) await this.auth.revokeRefreshTokens(uid);
  }

  async remove(uid: string): Promise<void> {
    await this.auth.deleteUser(uid);
  }
}

export class FirestoreListsStore implements ListsStore {
  constructor(private readonly db: Firestore) {}

  async listReports(reportStatus: string, limit: number): Promise<ReportItem[]> {
    const snap = await this.db
      .collection(REPORTS)
      .where("status", "==", reportStatus)
      .orderBy("createdAt", "desc")
      .limit(limit)
      .get();
    return snap.docs.map((doc) => ({
      id: doc.id,
      reporterUid: String(doc.get("reporterId") ?? ""),
      targetType: String(doc.get("targetType") ?? ""),
      targetId: String(doc.get("targetId") ?? ""),
      reason: String(doc.get("reason") ?? ""),
      status: String(doc.get("status") ?? ""),
      createdAtMs: millis(doc.get("createdAt")),
    }));
  }

  async listAudit(afterId: string | null, limit: number): Promise<AuditItem[]> {
    const query = await after(this.db, AUDIT_LOG, this.db.collection(AUDIT_LOG).orderBy("time", "desc"), afterId);
    const snap = await query.limit(limit).get();
    return snap.docs.map((doc: DocumentSnapshot) => ({
      id: doc.id,
      actorUid: String(doc.get("actorUid") ?? ""),
      action: String(doc.get("action") ?? ""),
      target: String(doc.get("target") ?? ""),
      reasonCode: str(doc.get("reasonCode")),
      ip: str(doc.get("ip")),
      timeMs: millis(doc.get("time")),
    }));
  }

  async audit(entry: AuditEntry): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create(auditDoc(entry));
  }

  async adminNames(uids: string[]): Promise<Map<string, string>> {
    const names = new Map<string, string>();
    if (uids.length === 0) return names;
    const snaps = await this.db.getAll(...uids.map((uid) => this.db.collection(ADMINS).doc(uid)));
    for (const snap of snaps) if (snap.exists) names.set(snap.id, String(snap.get("displayName") ?? ""));
    return names;
  }
}
