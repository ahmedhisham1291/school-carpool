import type {
  CaseRecord,
  ChildSnapshot,
  ClaimsService,
  DecisionWrite,
  QueueEntry,
  StoredFile,
  SubmissionWrite,
  UserSnapshot,
  VerificationFiles,
  VerificationStore,
} from "../../src/verification/flow";
import { VerificationError } from "../../src/verification/submission";

/** In-memory stand-ins for Firestore, Cloud Storage and Auth claims (unit tests). */

export interface MemoryUser extends UserSnapshot {
  firstName?: string;
}

export class MemoryVerificationStore implements VerificationStore {
  private counter = 0;
  readonly users = new Map<string, MemoryUser>();
  readonly children = new Map<string, ChildSnapshot & { caseId: string }>();
  readonly cases = new Map<string, CaseRecord & { purgeAtMs: number | null; reviewerUid?: string; reasonCode?: string | null }>();
  readonly nationalIds = new Map<string, string>();
  readonly banned = new Set<string>();
  readonly audit: Array<{ actorUid: string; action: string; target: string }> = [];
  readonly consents: Array<{ uid: string; type: string }> = [];
  readonly vehicles = new Map<string, { status: string; caseId: string }>();

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

  async claimNationalId(hash: string, uid: string): Promise<"ok" | "duplicate" | "banned"> {
    if (this.banned.has(hash)) return "banned";
    const holder = this.nationalIds.get(hash);
    if (holder && holder !== uid) return "duplicate";
    for (const [h, u] of this.nationalIds) if (u === uid && h !== hash) this.nationalIds.delete(h);
    this.nationalIds.set(hash, uid);
    return "ok";
  }

  async saveSubmission(write: SubmissionWrite): Promise<void> {
    const c = write.caseRecord;
    for (const id of write.replaceChildIds) this.children.delete(id);
    this.cases.set(c.id, { ...c, purgeAtMs: null });
    for (const child of c.children) {
      this.children.set(child.childId, { id: child.childId, ownerUid: c.uid, status: "pending", caseId: c.id });
    }
    if (c.driver) this.vehicles.set(c.uid, { status: "pending", caseId: c.id });
    const user = this.users.get(c.uid);
    if (user) {
      user.caseOpen = true;
      if (c.identity) {
        user.status = "pending";
        user.firstName = c.identity.firstName;
      }
    }
    for (const type of write.consents) this.consents.push({ uid: c.uid, type });
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
    const user = this.users.get(w.uid);
    if (user) {
      user.caseOpen = false;
      if (w.userStatus) user.status = w.userStatus;
    }
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

  async casesDueForPurge(nowMs: number, limit: number): Promise<Array<{ id: string; uid: string }>> {
    return [...this.cases.values()]
      .filter((c) => c.purgeAtMs !== null && c.purgeAtMs <= nowMs)
      .slice(0, limit)
      .map((c) => ({ id: c.id, uid: c.uid }));
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

  async setVerified(uid: string, verified: boolean): Promise<void> {
    this.verified.set(uid, verified);
  }

  async revokeSessions(uid: string): Promise<void> {
    this.revoked.push(uid);
  }
}
