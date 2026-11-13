import { AdminError } from "../../src/admin_panel/errors";
import type { AdminRole } from "../../src/admin_panel/guard";
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
  ListsStore,
  ModerationWrite,
  ReportItem,
  SchoolRecord,
  SchoolsStore,
  SchoolStatus,
  StoredUser,
  UserClaims,
  UsersStore,
} from "../../src/admin_panel/types";
import { normalizeText, nameSearchFields } from "../../src/text/normalize";

/** In-memory stand-ins for the admin panel stores (unit tests). */

export class MemoryAudit {
  readonly entries: AuditEntry[] = [];
  add(entry: AuditEntry): void {
    this.entries.push(entry);
  }
}

export class MemoryUsersStore implements UsersStore {
  readonly users = new Map<string, StoredUser>();
  readonly admins = new Set<string>();
  readonly nationalIds = new Map<string, string>();
  readonly banned = new Set<string>();
  readonly moderations: ModerationWrite[] = [];
  readonly quota = new Map<string, { start: number; count: number }>();
  cases: CaseHistoryItem[] = [];

  constructor(readonly log = new MemoryAudit()) {}

  addUser(user: Partial<StoredUser> & { uid: string }): StoredUser {
    const full: StoredUser = {
      parentId: "ABCD2345",
      firstName: null,
      lastName: null,
      phone: null,
      email: null,
      status: "verified",
      banned: false,
      statusBeforeSuspension: null,
      createdAtMs: 0,
      ...user,
    };
    this.users.set(full.uid, full);
    return full;
  }

  async consumeSearchQuota(adminUid: string, nowMs: number, limit: number, windowMs: number): Promise<boolean> {
    const q = this.quota.get(adminUid);
    if (!q || nowMs - q.start >= windowMs) {
      this.quota.set(adminUid, { start: nowMs, count: 1 });
      return true;
    }
    if (q.count >= limit) return false;
    q.count += 1;
    return true;
  }

  async findByParentId(parentId: string) {
    return [...this.users.values()].find((u) => u.parentId === parentId);
  }

  async findByPhone(e164: string) {
    return [...this.users.values()].filter((u) => u.phone === e164);
  }

  async findByName(normalized: string, limit: number) {
    const first = normalized.split(" ")[0];
    return [...this.users.values()]
      .filter((u) => {
        const { nameKey, nameTokens } = nameSearchFields(u.firstName ?? "", u.lastName ?? "");
        return nameKey.startsWith(normalized) || nameTokens.includes(first);
      })
      .slice(0, limit);
  }

  async getUser(uid: string) {
    const user = this.users.get(uid);
    return user ? { ...user } : undefined;
  }

  async caseHistory(uid: string): Promise<CaseHistoryItem[]> {
    return uid ? this.cases : [];
  }

  async actionHistory(uid: string): Promise<ActionHistoryItem[]> {
    return this.log.entries
      .filter((e) => e.target === `users/${uid}` && e.action !== "user.view")
      .map((e) => ({ action: e.action, actorUid: e.actorUid, reasonCode: e.reasonCode ?? null, timeMs: 0 }));
  }

  async isAdmin(uid: string) {
    return this.admins.has(uid);
  }

  async nationalIdHashOf(uid: string) {
    for (const [hash, holder] of this.nationalIds) if (holder === uid) return hash;
    return null;
  }

  async applyModeration(write: ModerationWrite, expectedStatus: AccountStatus) {
    const user = this.users.get(write.uid);
    if (!user || user.status !== expectedStatus) throw new AdminError("invalid-state");
    user.status = write.status;
    user.statusBeforeSuspension = write.statusBeforeSuspension;
    user.banned = write.banned;
    if (write.banNationalIdHash) this.banned.add(write.banNationalIdHash);
    this.moderations.push(write);
    this.log.add(write.audit);
  }

  async audit(entry: AuditEntry) {
    this.log.add(entry);
  }
}

export class MemoryClaims implements UserClaims {
  readonly verified = new Map<string, boolean>();
  readonly revoked: string[] = [];
  async setVerified(uid: string, verified: boolean) {
    this.verified.set(uid, verified);
  }
  async revokeSessions(uid: string) {
    this.revoked.push(uid);
  }
}

export class MemorySchoolsStore implements SchoolsStore {
  private counter = 0;
  readonly schools = new Map<string, SchoolRecord>();
  readonly areas = new Map<string, AreaRecord>();
  /** childId -> schoolId */
  readonly children = new Map<string, string>();

  constructor(readonly log = new MemoryAudit()) {}

  newId(collection: "schools" | "areas") {
    this.counter += 1;
    return `${collection}${this.counter}`;
  }

  async getSchool(id: string) {
    const s = this.schools.get(id);
    return s ? { ...s } : undefined;
  }

  async listSchools(q: { status: SchoolStatus; governorate: string | null; afterId: string | null; limit: number }) {
    const all = [...this.schools.values()]
      .filter((s) => s.status === q.status && (q.governorate === null || s.governorate === q.governorate))
      .sort((a, b) => normalizeText(a.nameAr).localeCompare(normalizeText(b.nameAr)));
    const start = q.afterId ? all.findIndex((s) => s.id === q.afterId) + 1 : 0;
    return all.slice(start, start + q.limit);
  }

  async saveSchool(school: SchoolRecord, isNew: boolean, audit: AuditEntry) {
    if (isNew && this.schools.has(school.id)) throw new Error("exists");
    this.schools.set(school.id, { ...school });
    this.log.add(audit);
  }

  async listAreas(schoolId: string) {
    return [...this.areas.values()].filter((a) => a.schoolId === schoolId);
  }

  async getArea(id: string) {
    return this.areas.get(id);
  }

  async saveArea(area: AreaRecord, _isNew: boolean, audit: AuditEntry) {
    this.areas.set(area.id, { ...area });
    this.log.add(audit);
  }

  async mergeSchool(fromId: string, intoId: string, audit: AuditEntry) {
    const from = this.schools.get(fromId);
    if (from) {
      from.status = "merged";
      from.mergedInto = intoId;
    }
    let moved = 0;
    for (const [child, school] of this.children) {
      if (school === fromId) {
        this.children.set(child, intoId);
        moved += 1;
      }
    }
    this.log.add(audit);
    return moved;
  }
}

export class MemoryAdminsStore implements AdminsStore {
  readonly admins = new Map<string, AdminRecord>();
  constructor(readonly log = new MemoryAudit()) {}
  async listAdmins() {
    return [...this.admins.values()];
  }
  async getAdmin(uid: string) {
    return this.admins.get(uid);
  }
  async saveAdmin(record: AdminRecord, _createdBy: string, audit: AuditEntry) {
    this.admins.set(record.uid, record);
    this.log.add(audit);
  }
  readonly revoked = new Set<string>();
  async setDisabled(uid: string, disabled: boolean, audit: AuditEntry) {
    const admin = this.admins.get(uid);
    if (admin) admin.disabled = disabled;
    if (disabled) this.revoked.add(uid);
    this.log.add(audit);
  }
  async removeAdmin(uid: string) {
    this.admins.delete(uid);
  }
  async audit(entry: AuditEntry) {
    this.log.add(entry);
  }
}

export class MemoryAdminAccounts implements AdminAccounts {
  readonly emails = new Map<string, string>();
  readonly roles = new Map<string, AdminRole>();
  readonly disabled = new Set<string>();
  readonly removed: string[] = [];
  /** Makes passwordSetupLink fail once (creation failing part way). */
  failLink = false;
  async remove(uid: string) {
    this.removed.push(uid);
    for (const [email, id] of this.emails) if (id === uid) this.emails.delete(email);
  }
  async create(email: string) {
    if (this.emails.has(email)) throw new AdminError("already-exists");
    const uid = `adm${this.emails.size + 1}`;
    this.emails.set(email, uid);
    return uid;
  }
  async setRole(uid: string, role: AdminRole) {
    this.roles.set(uid, role);
  }
  async passwordSetupLink(email: string) {
    if (this.failLink) {
      this.failLink = false;
      throw new Error("link service down");
    }
    return `https://example.test/reset?for=${encodeURIComponent(email)}`;
  }
  async setDisabled(uid: string, disabled: boolean) {
    if (disabled) this.disabled.add(uid);
    else this.disabled.delete(uid);
  }
}

export class MemoryListsStore implements ListsStore {
  readonly logged: AuditEntry[] = [];
  async audit(entry: AuditEntry) {
    this.logged.push(entry);
  }
  reports: ReportItem[] = [];
  auditItems: AuditItem[] = [];
  names = new Map<string, string>();
  async listReports(status: string, limit: number) {
    return this.reports.filter((r) => r.status === status).slice(0, limit);
  }
  async listAudit(afterId: string | null, limit: number) {
    const start = afterId ? this.auditItems.findIndex((a) => a.id === afterId) + 1 : 0;
    return this.auditItems.slice(start, start + limit);
  }
  async adminNames(uids: string[]) {
    return new Map([...this.names].filter(([uid]) => uids.includes(uid)));
  }
}
