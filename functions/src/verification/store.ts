import type { Auth } from "firebase-admin/auth";
import { FieldValue, Timestamp, type DocumentData, type Firestore } from "firebase-admin/firestore";
import type { Storage } from "firebase-admin/storage";
import { USERS } from "../auth/accounts";
import { verificationResultEvent } from "../notifications/producers";
import { NOTIFICATION_EVENTS, outboxDoc } from "../notifications/outbox";
import { nameSearchFields } from "../text/normalize";
import type { KycOutcome, KycResult } from "./kyc";
import { asKycResult } from "./kyc";
import { VERIFICATION_CONSENT_VERSIONS, VerificationError, type DriverSubmission } from "./submission";
import { keptApproval } from "./vehicle";
import type {
  AccountStatus,
  CaseChild,
  CaseRecord,
  ChildSnapshot,
  ClaimsService,
  DecisionWrite,
  SchoolChoice,
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
      firstName: typeof data.firstName === "string" ? data.firstName : null,
      lastName: typeof data.lastName === "string" ? data.lastName : null,
    };
  }

  async listChildren(uid: string): Promise<ChildSnapshot[]> {
    const snap = await this.db.collection(CHILDREN).where("ownerUid", "==", uid).get();
    return snap.docs.map((doc) => ({ id: doc.id, ownerUid: uid, status: doc.get("status") }));
  }

  async checkNationalId(hash: string, uid: string): Promise<"ok" | "duplicate" | "banned"> {
    if ((await this.db.collection(BANNED_IDS).doc(hash).get()).exists) return "banned";
    const claim = await this.db.collection(NATIONAL_IDS).doc(hash).get();
    return claim.exists && claim.get("uid") !== uid ? "duplicate" : "ok";
  }

  saveSubmission(write: SubmissionWrite): Promise<void> {
    const c = write.caseRecord;
    const now = FieldValue.serverTimestamp();
    const submittedAt = Timestamp.fromMillis(c.submittedAtMs);
    return this.db.runTransaction(async (tx) => {
    // Reads first (Firestore transactions), then every write.
    const userRef = this.db.collection(USERS).doc(c.uid);
    const user = await tx.get(userRef);
    const verification = user.get("verification") as { status?: unknown } | null | undefined;
    if (!user.exists || user.get("status") === "pending" || verification?.status === "pending") {
      throw new VerificationError("case-open");
    }
    if (c.nationalIdHash) {
      const hash = c.nationalIdHash;
      if ((await tx.get(this.db.collection(BANNED_IDS).doc(hash))).exists) throw new VerificationError("banned-id");
      const claimRef = this.db.collection(NATIONAL_IDS).doc(hash);
      const claim = await tx.get(claimRef);
      if (claim.exists && claim.get("uid") !== c.uid) throw new VerificationError("duplicate-id");
      // An earlier, different ID of the same parent (a typo fixed on resubmit) is released.
      const mine = await tx.get(this.db.collection(NATIONAL_IDS).where("uid", "==", c.uid));
      for (const doc of mine.docs) if (doc.id !== hash) tx.delete(doc.ref);
      tx.set(claimRef, { uid: c.uid, caseId: c.id, createdAt: FieldValue.serverTimestamp() });
    }
    // Prompt 11 (F17): read before any write. New details for the SAME car
    // (same plate) keep its approval until the reviewer decides; a new car
    // gets no driving days until it is checked (verification/vehicle.ts).
    const vehicleRef = this.db.collection(VEHICLES).doc(c.uid);
    const currentVehicle = c.driver ? await tx.get(vehicleRef) : null;
    const kept = c.driver && currentVehicle?.exists ? keptApproval(currentVehicle.data(), c.driver.plate) : null;
    for (const id of write.replaceChildIds) tx.delete(this.db.collection(CHILDREN).doc(id));

    tx.create(this.db.collection(VERIFICATIONS).doc(c.id), {
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
        schoolId: child.schoolId,
        schoolName: child.schoolName,
        // R4: the guardian declared the 15+ child was told and agrees (teenAgreement consent).
        teenAgreed: child.teen === true,
        status: "pending",
        schoolIdChecked: false,
        reasonCode: null,
        caseId: c.id,
        updatedAt: now,
      };
      const ref = this.db.collection(CHILDREN).doc(child.childId);
      if (child.isNew) tx.set(ref, { ownerUid: c.uid, createdAt: now, ...fields });
      else tx.update(ref, fields);
    }

    if (c.driver) {
      tx.set(vehicleRef, {
        driverUid: c.uid,
        ...c.driver,
        status: "pending",
        reasonCode: null,
        caseId: c.id,
        approved: kept,
        updatedAt: now,
      });
    }

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
    // R3: the typed names (deleted with the user record); the kept consent records hold only a keyed hash.
    if (write.signedName) {
      for (const type of write.consents) userUpdate[`signedNames.${type}`] = write.signedName;
    }
    tx.update(userRef, userUpdate);

    for (const type of write.consents) {
      const signature = write.signatures[type];
      tx.create(userRef.collection("consents").doc(), {
        type,
        version: VERIFICATION_CONSENT_VERSIONS[type],
        acceptedAt: now,
        withdrawnAt: null,
        source: "verification",
        ...(signature ? { signature } : {}),
      });
    }
    });
  }

  withdrawCase(uid: string, caseId: string, nowMs: number): Promise<void> {
    return this.db.runTransaction(async (tx) => {
      const caseRef = this.db.collection(VERIFICATIONS).doc(caseId);
      const snap = await tx.get(caseRef);
      if (!snap.exists || snap.get("uid") !== uid) throw new VerificationError("not-found");
      if (snap.get("status") !== "awaiting_review") throw new VerificationError("already-decided");
      const record = caseFromDoc(caseId, snap.data() ?? {});
      const claimRef = record.nationalIdHash ? this.db.collection(NATIONAL_IDS).doc(record.nationalIdHash) : null;
      const claim = claimRef ? await tx.get(claimRef) : null;
      const childRefs = record.children.map((child) => this.db.collection(CHILDREN).doc(child.childId));
      const children = await Promise.all(childRefs.map((ref) => tx.get(ref)));
      const vehicleRef = this.db.collection(VEHICLES).doc(uid);
      const vehicle = record.driver ? await tx.get(vehicleRef) : null;

      const decidedAt = Timestamp.fromMillis(nowMs);
      tx.update(caseRef, { status: "withdrawn", decidedAt, purgeAt: decidedAt });
      const userUpdate: DocumentData = {
        "verification.status": "withdrawn",
        "verification.decidedAt": decidedAt,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (record.scope === "identity") userUpdate.status = "unverified";
      tx.update(this.db.collection(USERS).doc(uid), userUpdate);
      children.forEach((child, i) => {
        if (!child.exists || child.get("caseId") !== caseId) return;
        // New children of a withdrawn case go; edited ones go back to how a reviewer left them.
        if (record.children[i].isNew) tx.delete(childRefs[i]);
        else tx.update(childRefs[i], { status: "rejected", reasonCode: null, updatedAt: FieldValue.serverTimestamp() });
      });
      if (vehicle?.exists && vehicle.get("caseId") === caseId) {
        // Prompt 11: a withdrawn renewal of the same car puts the approved car back.
        const kept = vehicle.get("approved") as Record<string, unknown> | null | undefined;
        if (kept && typeof kept === "object") {
          tx.set(vehicleRef, { driverUid: uid, ...kept, status: "approved", reasonCode: null, caseId: null, approved: null, updatedAt: FieldValue.serverTimestamp() });
        } else {
          tx.delete(vehicleRef);
        }
      }
      if (claimRef && claim?.exists && claim.get("uid") === uid) tx.delete(claimRef);
      tx.create(this.db.collection(AUDIT_LOG).doc(), {
        actorUid: uid,
        action: "verification.withdraw",
        target: `${VERIFICATIONS}/${caseId}`,
        ip: null,
        time: FieldValue.serverTimestamp(),
      });
    });
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
        purgeAt: w.purgeAtMs === null ? null : Timestamp.fromMillis(w.purgeAtMs),
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
      // Written after the claim was set (decideVerification): the app
      // refreshes its ID token when this changes.
      if (w.claimsChanged) userUpdate.claimsUpdatedAt = FieldValue.serverTimestamp();
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
        // Prompt 11: once approved, the kept copy of the earlier approval goes;
        // a rejected renewal keeps it (the car as approved before stays usable).
        tx.update(vehicleRef, {
          status: w.status,
          reasonCode: w.reasonCode,
          ...(approved ? { approved: null } : {}),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      if (claimRef && claim?.exists && claim.get("uid") === w.uid) tx.delete(claimRef);
      if (w.banNationalIdHash) {
        tx.set(this.db.collection(BANNED_IDS).doc(w.banNationalIdHash), {
          caseId: w.caseId,
          byUid: w.reviewerUid,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      // Prompt 8: the parent is told the result (push; WhatsApp when on).
      const notice = verificationResultEvent(w, w.decidedAtMs);
      tx.set(this.db.collection(NOTIFICATION_EVENTS).doc(notice.id), outboxDoc(notice));
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

  async getSchool(id: string): Promise<SchoolChoice | undefined> {
    const snap = await this.db.collection("schools").doc(id).get();
    if (!snap.exists) return undefined;
    const d = snap.data() ?? {};
    return {
      id,
      nameAr: typeof d.nameAr === "string" ? d.nameAr : "",
      nameEn: typeof d.nameEn === "string" ? d.nameEn : "",
      status: typeof d.status === "string" ? d.status : "",
      addedBy: typeof d.addedBy === "string" ? d.addedBy : null,
      mergedInto: typeof d.mergedInto === "string" ? d.mergedInto : null,
    };
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

  async appendAudit(entry: { actorUid: string; action: string; target: string; ip: string | null; reasonCode?: string | null }): Promise<void> {
    await this.db.collection(AUDIT_LOG).doc().create({ ...entry, time: FieldValue.serverTimestamp() });
  }

  async casesDueForPurge(nowMs: number, limit: number): Promise<Array<{ id: string; uid: string; status: string }>> {
    const snap = await this.db
      .collection(VERIFICATIONS)
      .where("purgeAt", "<=", Timestamp.fromMillis(nowMs))
      .limit(limit)
      .get();
    return snap.docs.map((doc) => ({ id: doc.id, uid: String(doc.get("uid")), status: String(doc.get("status") ?? "") }));
  }

  async keepImages(caseId: string): Promise<void> {
    await this.db.collection(VERIFICATIONS).doc(caseId).update({ purgeAt: null });
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
  /**
   * [db]: users/{uid}.sessionsValidAfter is written on revocation (security
   * review, 16 Nov 2026). Revoking refresh tokens alone left a suspended or
   * banned parent's ID token (with the "verified" claim) working in the
   * rules for up to an hour: live runs, members and exact pickup points.
   */
  constructor(
    private readonly auth: Auth,
    private readonly db: Pick<Firestore, "collection"> | null = null,
  ) {}

  async setVerified(uid: string, verified: boolean): Promise<void> {
    const user = await this.auth.getUser(uid);
    const claims: Record<string, unknown> = { ...(user.customClaims ?? {}) };
    if (verified) claims.verified = true;
    else delete claims.verified;
    await this.auth.setCustomUserClaims(uid, claims);
  }

  async revokeSessions(uid: string): Promise<void> {
    await this.auth.revokeRefreshTokens(uid);
    if (!this.db) return;
    // Same as privacy/callables.ts revokeSessions: rules (sessionValid) and
    // the gated callables refuse ID tokens from a sign-in before this.
    const user = await this.auth.getUser(uid);
    await this.db.collection(USERS).doc(uid).update({ sessionsValidAfter: sessionsValidAfterSeconds(user.tokensValidAfterTime, Date.now()) });
  }
}

/** Seconds of Auth's tokensValidAfterTime (the revocation), or now when it is missing. */
export function sessionsValidAfterSeconds(tokensValidAfterTime: string | undefined, nowMs: number): number {
  const ms = Date.parse(tokensValidAfterTime ?? "");
  return Math.floor((Number.isFinite(ms) ? ms : nowMs) / 1000);
}
