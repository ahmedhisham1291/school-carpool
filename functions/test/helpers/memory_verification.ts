import type {
  CaseRecord,
  ChildSnapshot,
  ClaimsService,
  DecisionWrite,
  QueueEntry,
  SchoolChoice,
  StoredFile,
  SubmissionWrite,
  UserSnapshot,
  VerificationFiles,
  VerificationStore,
} from "../../src/verification/flow";
import { verificationResultEvent } from "../../src/notifications/producers";
import type { OutboxEvent } from "../../src/notifications/model";
import { VerificationError } from "../../src/verification/submission";

/** In-memory stand-ins for Firestore, Cloud Storage and Auth claims (unit tests). */

export interface MemoryUser extends UserSnapshot {
  firstName?: string | null;
  lastName?: string | null;
}

export class MemoryVerificationStore implements VerificationStore {
  private counter = 0;
  readonly users = new Map<string, MemoryUser>();
  readonly children = new Map<string, ChildSnapshot & { caseId: string }>();
  readonly cases = new Map<string, CaseRecord & { purgeAtMs: number | null; reviewerUid?: string; reasonCode?: string | null }>();
  readonly nationalIds = new Map<string, string>();
  readonly banned = new Set<string>();
  readonly audit: Array<{ actorUid: string; action: string; target: string }> = [];
  readonly consents: Array<{ uid: string; type: string; signature?: unknown }> = [];
  /** R3: users/{uid}.signedNames (one typed name per submission here). */
  readonly signedNames = new Map<string, string>();
  readonly vehicles = new Map<string, { status: string; caseId: string }>();
  /** Schools children may be linked to; "nile" is active by default. */
  readonly schools = new Map<string, SchoolChoice>([
    ["nile", { id: "nile", nameAr: "مدرسة النيل", nameEn: "Nile School", status: "active", addedBy: null, mergedInto: null }],
  ]);

  async getSchool(id: string): Promise<SchoolChoice | undefined> {
    const school = this.schools.get(id);
    return school ? { ...school } : undefined;
  }

  newId(): string {
    this.counter += 1;
    return `id${this.counter}`;
  }

  async getUser(uid: string): Promise<UserSnapshot | undefined> {
    const user = this.users.get(uid);
    return user ? { ...user } : undefined;
  }

  async listChildren(uid: string): Promise<ChildSnapshot[]> {
    return [...this.children.values()].filter((c) => c.ownerUid === uid).map((c) => ({ ...c }));
  }

  /** Shared, ordered record of claim changes and status writes (order tests). */
  readonly events: string[] = [];
  readonly notifications: OutboxEvent[] = [];
  /** Lets a test claim an ID between the early check and the commit. */
  beforeCommit: (() => void) | null = null;

  async checkNationalId(hash: string, uid: string): Promise<"ok" | "duplicate" | "banned"> {
    if (this.banned.has(hash)) return "banned";
    const holder = this.nationalIds.get(hash);
    return holder && holder !== uid ? "duplicate" : "ok";
  }

  async saveSubmission(write: SubmissionWrite): Promise<void> {
    const c = write.caseRecord;
    this.beforeCommit?.();
    const user = this.users.get(c.uid);
    if (!user || user.status === "pending" || user.caseOpen) throw new VerificationError("case-open");
    const hash = c.nationalIdHash;
    if (hash) {
      if (this.banned.has(hash)) throw new VerificationError("banned-id");
      const holder = this.nationalIds.get(hash);
      if (holder && holder !== c.uid) throw new VerificationError("duplicate-id");
      for (const [h, u] of this.nationalIds) if (u === c.uid && h !== hash) this.nationalIds.delete(h);
      this.nationalIds.set(hash, c.uid);
    }
    for (const id of write.replaceChildIds) this.children.delete(id);
    this.cases.set(c.id, { ...c, purgeAtMs: null });
    for (const child of c.children) {
      this.children.set(child.childId, { id: child.childId, ownerUid: c.uid, status: "pending", caseId: c.id });
    }
    if (c.driver) this.vehicles.set(c.uid, { status: "pending", caseId: c.id });
    if (user) {
      user.caseOpen = true;
      if (c.identity) {
        user.status = "pending";
        user.firstName = c.identity.firstName;
        user.lastName = c.identity.lastName;
      }
    }
    for (const type of write.consents) this.consents.push({ uid: c.uid, type, signature: write.signatures[type] ?? null });
    if (write.signedName) this.signedNames.set(c.uid, write.signedName);
  }

  async getCase(caseId: string): Promise<CaseRecord | undefined> {
    const c = this.cases.get(caseId);
    return c ? { ...c } : undefined;
  }

  async saveDecision(w: DecisionWrite): Promise<void> {
    const c = this.cases.get(w.caseId);
    if (!c || c.status !== "awaiting_review") throw new VerificationError("already-decided");
    c.status = w.status;
    c.reviewerUid = w.reviewerUid;
    c.reasonCode = w.reasonCode;
    c.purgeAtMs = w.purgeAtMs;
    this.decidedAt.set(c.id, w.decidedAtMs);
    const user = this.users.get(w.uid);
    if (user) {
      user.caseOpen = false;
      if (w.userStatus) user.status = w.userStatus;
    }
    this.events.push(`status:${w.userStatus ?? "unchanged"}`);
    // Prompt 8: the outbox event written in the same transaction.
    this.notifications.push(verificationResultEvent(w, w.decidedAtMs));
    if (w.claimsChanged) this.events.push("marker:claimsUpdatedAt");
    for (const id of w.childIds) {
      const child = this.children.get(id);
      if (child && child.caseId === w.caseId) child.status = w.status;
    }
    const vehicle = this.vehicles.get(w.uid);
    if (w.vehicle && vehicle?.caseId === w.caseId) vehicle.status = w.status;
    if (w.releaseNationalIdHash && this.nationalIds.get(w.releaseNationalIdHash) === w.uid) {
      this.nationalIds.delete(w.releaseNationalIdHash);
    }
    if (w.banNationalIdHash) this.banned.add(w.banNationalIdHash);
    this.audit.push({ actorUid: w.reviewerUid, action: `verification.${w.status}`, target: `verifications/${w.caseId}` });
  }

  async withdrawCase(uid: string, caseId: string, nowMs: number): Promise<void> {
    const c = this.cases.get(caseId);
    if (!c || c.uid !== uid) throw new VerificationError("not-found");
    if (c.status !== "awaiting_review") throw new VerificationError("already-decided");
    c.status = "withdrawn";
    c.purgeAtMs = nowMs;
    const user = this.users.get(uid);
    if (user) {
      user.caseOpen = false;
      if (c.scope === "identity") user.status = "unverified";
    }
    for (const child of c.children) if (child.isNew && this.children.get(child.childId)?.caseId === caseId) this.children.delete(child.childId);
    if (c.nationalIdHash && this.nationalIds.get(c.nationalIdHash) === uid) this.nationalIds.delete(c.nationalIdHash);
  }

  async queue(limit: number): Promise<QueueEntry[]> {
    return [...this.cases.values()]
      .filter((c) => c.status === "awaiting_review")
      .sort((a, b) => a.submittedAtMs - b.submittedAtMs)
      .slice(0, limit)
      .map((c) => ({
        caseId: c.id,
        scope: c.scope,
        submittedAtMs: c.submittedAtMs,
        kycResult: c.kyc?.result ?? null,
        children: c.children.length,
        driver: c.driver !== null,
      }));
  }

  async removeChild(uid: string, childId: string): Promise<void> {
    const child = this.children.get(childId);
    if (!child || child.ownerUid !== uid) throw new VerificationError("not-found");
    if (child.status === "pending") throw new VerificationError("case-open");
    this.children.delete(childId);
  }

  async appendAudit(entry: { actorUid: string; action: string; target: string }): Promise<void> {
    this.audit.push(entry);
  }

  async casesDueForPurge(nowMs: number, limit: number): Promise<Array<{ id: string; uid: string; status: string }>> {
    return [...this.cases.values()]
      .filter((c) => c.purgeAtMs !== null && c.purgeAtMs <= nowMs)
      .slice(0, limit)
      .map((c) => ({ id: c.id, uid: c.uid, status: c.status }));
  }

  /** When each case was decided (R12). */
  readonly decidedAt = new Map<string, number>();

  async decidedCasesWithImages(decidedBeforeMs: number, limit: number): Promise<Array<{ id: string; uid: string; status: string }>> {
    return [...this.cases.values()]
      .filter((c) => (c.status === "approved" || c.status === "rejected") && !c.imagesDeleted && (this.decidedAt.get(c.id) ?? Infinity) <= decidedBeforeMs)
      .slice(0, limit)
      .map((c) => ({ id: c.id, uid: c.uid, status: c.status }));
  }

  async keepImages(caseId: string): Promise<void> {
    const c = this.cases.get(caseId);
    if (c) c.purgeAtMs = null;
  }

  async markPurged(caseId: string): Promise<void> {
    const c = this.cases.get(caseId);
    if (c) {
      c.purgeAtMs = null;
      c.imagesDeleted = true;
    }
  }

  async caseExists(caseId: string): Promise<boolean> {
    return this.cases.has(caseId);
  }
}

export class MemoryFiles implements VerificationFiles {
  readonly files = new Map<string, { data: Buffer; createdMs: number }>();
  reads = 0;

  constructor(private readonly clock: () => number) {}

  put(path: string, data = "jpeg", createdMs = this.clock()): void {
    this.files.set(path, { data: Buffer.from(data), createdMs });
  }

  async exists(path: string): Promise<boolean> {
    return this.files.has(path);
  }

  async copy(from: string, to: string): Promise<void> {
    const file = this.files.get(from);
    if (!file) throw new Error(`no such file ${from}`);
    this.files.set(to, { data: file.data, createdMs: this.clock() });
  }

  async delete(path: string): Promise<void> {
    this.files.delete(path);
  }

  async read(path: string): Promise<Buffer> {
    this.reads += 1;
    const file = this.files.get(path);
    if (!file) throw new Error(`no such file ${path}`);
    return file.data;
  }

  async list(prefix: string): Promise<StoredFile[]> {
    return [...this.files.entries()]
      .filter(([path]) => path.startsWith(prefix))
      .map(([path, f]) => ({ path, createdMs: f.createdMs }));
  }

  async deletePrefix(prefix: string): Promise<number> {
    let count = 0;
    for (const path of [...this.files.keys()]) {
      if (path.startsWith(prefix)) {
        this.files.delete(path);
        count += 1;
      }
    }
    return count;
  }

  async signedReadUrl(path: string, expiresAtMs: number): Promise<string> {
    return `https://signed.example/${path}?expires=${expiresAtMs}`;
  }
}

export class MemoryClaims implements ClaimsService {
  readonly verified = new Map<string, boolean>();
  readonly revoked: string[] = [];

  /** [events]: the store's event list, to check the order of writes. */
  constructor(private readonly events: string[] = []) {}

  async setVerified(uid: string, verified: boolean): Promise<void> {
    this.verified.set(uid, verified);
    this.events.push(`claim:${verified}`);
  }

  async revokeSessions(uid: string): Promise<void> {
    this.revoked.push(uid);
  }
}
