import type { Auth } from "firebase-admin/auth";
import { FieldValue, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "firebase-admin/storage";
import { USERS } from "../auth/accounts";
import { nameSearchFields } from "../text/normalize";
import type { KycOutcome, KycResult } from "./kyc";
import { asKycResult } from "./kyc";
import { VERIFICATION_CONSENT_VERSIONS, VerificationError, type DriverSubmission } from "./submission";
import type {
  AccountStatus,
  CaseChild,
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
} from "./flow";

/** Collections written only by Cloud Functions (firestore.rules). */
export const VERIFICATIONS = "verifications";
export const CHILDREN = "children";
export const VEHICLES = "vehicles";
/** Keyed hashes of national IDs in use: {hash} -> { uid }. */
export const NATIONAL_IDS = "nationalIds";
/** Keyed hashes of banned national IDs. Kept after account deletion. */
export const BANNED_IDS = "bannedIds";
/** Append-only record of admin and security events (spec section 9). */
export const AUDIT_LOG = "auditLog";
/** Server settings, for example config/kyc { fakeResult }. */
export const CONFIG = "config";

function millis(value: unknown): number {
  return value instanceof Timestamp ? value.toMillis() : 0;
}

function caseFromDoc(id: string, data: DocumentData): CaseRecord {
  const kyc = data.kyc as KycOutcome | null | undefined;
  return {
    id,
    uid: String(data.uid),
    scope: data.scope === "update" ? "update" : "identity",
    status: data.status,
    nationalIdHash: typeof data.nationalIdHash === "string" ? data.nationalIdHash : null,
    identity: data.identity ?? null,
    children: Array.isArray(data.children) ? (data.children as CaseChild[]) : [],
    driver: (data.driver as DriverSubmission | null | undefined) ?? null,
    files: Array.isArray(data.files) ? (data.files as string[]) : [],
    kyc: kyc ?? null,
    submittedAtMs: millis(data.submittedAt),
    imagesDeleted: data.imagesDeletedAt != null,
  };
}

export class FirestoreVerificationStore implements VerificationStore {
  constructor(private readonly db: Firestore) {}

  newId(): string {
    return this.db.collection(VERIFICATIONS).doc().id;
  }

  async getUser(uid: string): Promise<UserSnapshot | undefined> {
    const snap = await this.db.collection(USERS).doc(uid).get();
    if (!snap.exists) return undefined;
    const data = snap.data() ?? {};
    const verification = data.verification as { status?: unknown } | null | undefined;
    return {
      status: (typeof data.status === "string" ? data.status : "unverified") as AccountStatus,
      emailVerified: data.emailVerified === true,
      termsAccepted: data.termsAcceptedAt != null,
      caseOpen: verification?.status === "pending",
    };
  }

  async listChildren(uid: string): Promise<ChildSnapshot[]> {
    const snap = await this.db.collection(CHILDREN).where("ownerUid", "==", uid).get();
    return snap.docs.map((doc) => ({ id: doc.id, ownerUid: uid, status: doc.get("status") }));
  }

  claimNationalId(hash: string, uid: string): Promise<"ok" | "duplicate" | "banned"> {
    return this.db.runTransaction(async (tx) => {
      const banned = await tx.get(this.db.collection(BANNED_IDS).doc(hash));
      if (banned.exists) return "banned";
      const ref = this.db.collection(NATIONAL_IDS).doc(hash);
      const claim = await tx.get(ref);
      if (claim.exists && claim.get("uid") !== uid) return "duplicate";
      // An earlier, different ID of the same parent (a typo fixed on resubmit) is released.
      const mine = await tx.get(this.db.collection(NATIONAL_IDS).where("uid", "==", uid));
      for (const doc of mine.docs) if (doc.id !== hash) tx.delete(doc.ref);
      if (!claim.exists) tx.set(ref, { uid, createdAt: FieldValue.serverTimestamp() });
      return "ok";
    });
  }

  async saveSubmission(write: SubmissionWrite): Promise<void> {
    const c = write.caseRecord;
    const now = FieldValue.serverTimestamp();
    const submittedAt = Timestamp.fromMillis(c.submittedAtMs);
    const batch = this.db.batch();
    for (const id of write.replaceChildIds) batch.delete(this.db.collection(CHILDREN).doc(id));

    batch.create(this.db.collection(VERIFICATIONS).doc(c.id), {
      uid: c.uid,
      scope: c.scope,
      status: c.status,
      nationalIdHash: c.nationalIdHash,
      identity: c.identity,
      children: c.children,
      driver: c.driver,
      files: c.files,
      kyc: c.kyc,
      submittedAt,
      decidedAt: null,
      reviewerUid: null,
      reasonCode: null,
      note: null,
      purgeAt: null,
      imagesDeletedAt: null,
    });

    for (const child of c.children) {
      const fields = {
        firstName: child.firstName,
        age: child.age,
        grade: child.grade,
        schoolName: child.schoolName,
        status: "pending",
        schoolIdChecked: false,
        reasonCode: null,
        caseId: c.id,
        updatedAt: now,
      };
      const ref = this.db.collection(CHILDREN).doc(child.childId);
      if (child.isNew) batch.set(ref, { ownerUid: c.uid, schoolId: null, createdAt: now, ...fields });
      else batch.update(ref, fields);
    }

    if (c.driver) {
      batch.set(this.db.collection(VEHICLES).doc(c.uid), {
        driverUid: c.uid,
        ...c.driver,
        status: "pending",
        reasonCode: null,
        caseId: c.id,
        updatedAt: now,
      });
    }

    const userRef = this.db.collection(USERS).doc(c.uid);
    const userUpdate: DocumentData = {
      verification: { caseId: c.id, scope: c.scope, status: "pending", reasonCode: null, note: null, submittedAt, decidedAt: null },
      updatedAt: now,
    };
    if (c.identity) {
      userUpdate.status = "pending";
      userUpdate.firstName = c.identity.firstName;
      userUpdate.lastName = c.identity.lastName;
      userUpdate.idExpiry = c.identity.idExpiry;
      // Admin search by name (F14): normalized full name and its words.
      Object.assign(userUpdate, nameSearchFields(c.identity.firstName, c.identity.lastName));
    }
    batch.update(userRef, userUpdate);

    for (const type of write.consents) {
      batch.create(userRef.collection("consents").doc(), {
        type,
        version: VERIFICATION_CONSENT_VERSIONS[type],
        acceptedAt: now,
        withdrawnAt: null,
        source: "verification",
      });
    }
    await batch.commit();
  }

  async getCase(caseId: string): Promise<CaseRecord | undefined> {
    const snap = await this.db.collection(VERIFICATIONS).doc(caseId).get();
    return snap.exists ? caseFromDoc(caseId, snap.data() ?? {}) : undefined;
  }

  saveDecision(w: DecisionWrite): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const caseRef = this.db.collection(VERIFICATIONS).doc(w.caseId);
      const current = await tx.get(caseRef);
      if (!current.exists || current.get("status") !== "awaiting_review") throw new VerificationError("already-decided");
      const claimRef = w.releaseNationalIdHash ? this.db.collection(NATIONAL_IDS).doc(w.releaseNationalIdHash) : null;
      const claim = claimRef ? await tx.get(claimRef) : null;
      const childRefs = w.childIds.map((id) => this.db.collection(CHILDREN).doc(id));
      const children = await Promise.all(childRefs.map((ref) => tx.get(ref)));
      const vehicleRef = this.db.collection(VEHICLES).doc(w.uid);
      const vehicle = w.vehicle ? await tx.get(vehicleRef) : null;

      const approved = w.status === "approved";
      const decidedAt = Timestamp.fromMillis(w.decidedAtMs);
      tx.update(caseRef, {
        status: w.status,
        reviewerUid: w.reviewerUid,
        reasonCode: w.reasonCode,
        note: w.note,
        nameCheck: w.nameCheck,
        decidedAt,
        purgeAt: Timestamp.fromMillis(w.purgeAtMs),
      });

      const userUpdate: DocumentData = {
        "verification.status": w.status,
        "verification.reasonCode": w.reasonCode,
        "verification.note": w.note,
        "verification.decidedAt": decidedAt,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (w.userStatus) userUpdate.status = w.userStatus;
      if (w.userStatus === "verified") userUpdate.verifiedAt = decidedAt;
      tx.update(this.db.collection(USERS).doc(w.uid), userUpdate);

      children.forEach((snap, i) => {
        // Only children still tied to this case (not edited again or removed).
        if (snap.exists && snap.get("caseId") === w.caseId) {
          tx.update(childRefs[i], {
            status: w.status,
            schoolIdChecked: approved,
            reasonCode: w.reasonCode,
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      });
      if (vehicle?.exists && vehicle.get("caseId") === w.caseId) {
        tx.update(vehicleRef, { status: w.status, reasonCode: w.reasonCode, updatedAt: FieldValue.serverTimestamp() });
      }
      if (claimRef && claim?.exists && claim.get("uid") === w.uid) tx.delete(claimRef);
      if (w.banNationalIdHash) {
        tx.set(this.db.collection(BANNED_IDS).doc(w.banNationalIdHash), {
          caseId: w.caseId,
          byUid: w.reviewerUid,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      tx.create(this.db.collection(AUDIT_LOG).doc(), {
        actorUid: w.reviewerUid,
        action: w.banNationalIdHash ? "verification.ban" : `verification.${approved ? "approve" : "reject"}`,
        target: `${VERIFICATIONS}/${w.caseId}`,
        reasonCode: w.reasonCode,
        details: { nameCheck: w.nameCheck },
        ip: w.ip,
        time: FieldValue.serverTimestamp(),
      });
    });
  }

  async queue(limit: number): Promise<QueueEntry[]> {
    const snap = await this.db
      .collection(VERIFICATIONS)
      .where("status", "==", "awaiting_review")
      .orderBy("submittedAt")
      .limit(limit)
      .get();
    return snap.docs.map((doc) => {
      const c = caseFromDoc(doc.id, doc.data());
      return {
        caseId: c.id,
        scope: c.scope,
        submittedAtMs: c.submittedAtMs,
        kycResult: c.kyc?.result ?? null,
        children: c.children.length,
        driver: c.driver !== null,
      };
    });
  }

  removeChild(uid: string, childId: string): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const ref = this.db.collection(CHILDREN).doc(childId);
      const snap = await tx.get(ref);
      if (!snap.exists || snap.get("ownerUid") !== uid) throw new VerificationError("not-found");
      if (snap.get("status") === "pending") throw new VerificationError("case-open");
      tx.delete(ref);
    });
  }

  async appendAudit(entry: { actorUid: string; action: string; target: string; ip: string | null }): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create({ ...entry, time: FieldValue.serverTimestamp() });
  }

  async casesDueForPurge(nowMs: number, limit: number): Promise<Array<{ id: string; uid: string }>> {
    const snap = await this.db
      .collection(VERIFICATIONS)
      .where("purgeAt", "<=", Timestamp.fromMillis(nowMs))
      .limit(limit)
      .get();
    return snap.docs.map((doc) => ({ id: doc.id, uid: String(doc.get("uid")) }));
  }

  async markPurged(caseId: string, nowMs: number): Promise<void> {
    await this.db.collection(VERIFICATIONS).doc(caseId).update({
      purgeAt: FieldValue.delete(),
      imagesDeletedAt: Timestamp.fromMillis(nowMs),
    });
  }

  async caseExists(caseId: string): Promise<boolean> {
    return (await this.db.collection(VERIFICATIONS).doc(caseId).get()).exists;
  }
}

/** Test setting for the fake provider: config/kyc { fakeResult: "match" | "no_match" | "error" }. */
export async function readFakeKycSetting(db: Firestore): Promise<KycResult> {
  const snap = await db.collection(CONFIG).doc("kyc").get();
  return asKycResult(snap.exists ? snap.get("fakeResult") : undefined);
}

/** A Cloud Storage bucket (type from firebase-admin, no direct @google-cloud/storage dependency). */
export type Bucket = ReturnType<Storage["bucket"]>;

export class CloudStorageFiles implements VerificationFiles {
  constructor(private readonly bucket: Bucket) {}

  async exists(path: string): Promise<boolean> {
    const [exists] = await this.bucket.file(path).exists();
    return exists;
  }

  async copy(from: string, to: string): Promise<void> {
    await this.bucket.file(from).copy(this.bucket.file(to));
  }

  async delete(path: string): Promise<void> {
    await this.bucket.file(path).delete({ ignoreNotFound: true });
  }

  async read(path: string): Promise<Buffer> {
    const [contents] = await this.bucket.file(path).download();
    return contents;
  }

  async list(prefix: string): Promise<StoredFile[]> {
    const [files] = await this.bucket.getFiles({ prefix });
    return files.map((file) => ({
      path: file.name,
      createdMs: Date.parse(String(file.metadata.timeCreated ?? "")) || 0,
    }));
  }

  async deletePrefix(prefix: string): Promise<number> {
    const [files] = await this.bucket.getFiles({ prefix });
    for (const file of files) await file.delete({ ignoreNotFound: true });
    return files.length;
  }

  async signedReadUrl(path: string, expiresAtMs: number): Promise<string> {
    const [url] = await this.bucket.file(path).getSignedUrl({ version: "v4", action: "read", expires: expiresAtMs });
    return url;
  }
}

export class FirebaseClaimsService implements ClaimsService {
  constructor(private readonly auth: Auth) {}

  async setVerified(uid: string, verified: boolean): Promise<void> {
    const user = await this.auth.getUser(uid);
    const claims: Record<string, unknown> = { ...(user.customClaims ?? {}) };
    if (verified) claims.verified = true;
    else delete claims.verified;
    await this.auth.setCustomUserClaims(uid, claims);
  }

  async revokeSessions(uid: string): Promise<void> {
    await this.auth.revokeRefreshTokens(uid);
  }
}
