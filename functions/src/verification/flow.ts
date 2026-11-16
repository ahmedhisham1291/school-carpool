import { accessReason, thumbPath } from "../privacy/photos";
import { sessionKey } from "../privacy/devices";
import { consentText } from "../auth/consent_texts";
import { checkMethod, nameMatches, SignatureError, signatureRecord, type SignatureRecord } from "../auth/signature";
import type { KycImages, KycOutcome, KycProvider } from "./kyc";
import { runKyc } from "./kyc";
import { nationalIdHash } from "./national_id";
import {
  cairoDate,
  isTeen,
  DRIVER_PHOTO_FILE,
  driverPhotoPath,
  faceRefPath,
  parseDecision,
  parseSubmission,
  requiredFiles,
  VerificationError,
  type ChildSubmission,
  type DriverSubmission,
  type NameCheck,
  type RejectionReason,
  type Submission,
  type VerificationConsent,
  VERIFICATION_CONSENT_VERSIONS,
} from "./submission";

/**
 * Identity verification (F2), children (F3) and the automated check (F18).
 * The logic runs over small store interfaces so it can be unit-tested; the
 * Firestore and Cloud Storage versions are in store.ts.
 *
 * Storage layout (storage.rules):
 *   verification/{uid}/pending/{name}          the app uploads here, nothing else
 *   verification/{uid}/cases/{caseId}/{name}   copied on submit; Functions only
 */

export type AccountStatus = "unverified" | "pending" | "verified" | "rejected" | "suspended";
export type CaseStatus = "awaiting_review" | "approved" | "rejected" | "withdrawn";
export type CaseScope = "identity" | "update";

export interface UserSnapshot {
  status: AccountStatus;
  /** The ID name of a verified parent (null before the ID check). */
  firstName?: string | null;
  lastName?: string | null;
  emailVerified: boolean;
  termsAccepted: boolean;
  /** True while a case of this parent waits for review. */
  caseOpen: boolean;
}

export interface ChildSnapshot {
  id: string;
  ownerUid: string;
  status: "pending" | "approved" | "rejected";
}

export interface CaseChild extends Omit<ChildSubmission, "childId" | "birthDate"> {
  childId: string;
  isNew: boolean;
  file: string;
  /**
   * R4: 15 or older (birth date, age or grade): the guardian declared the
   * child was told and agrees. The birth date itself is not kept (only
   * needed for this check).
   */
  teen?: boolean;
}

export interface CaseRecord {
  id: string;
  uid: string;
  scope: CaseScope;
  status: CaseStatus;
  nationalIdHash: string | null;
  identity: { firstName: string; lastName: string; idExpiry: string; livenessChallenge: string } | null;
  children: CaseChild[];
  driver: DriverSubmission | null;
  /** Full storage paths of the case images. */
  files: string[];
  kyc: KycOutcome | null;
  submittedAtMs: number;
  /** True once the retention job deleted the images. */
  imagesDeleted: boolean;
}

export interface SubmissionWrite {
  caseRecord: CaseRecord;
  /** Children to delete first (a parent who is not verified resubmits all). */
  replaceChildIds: string[];
  consents: VerificationConsent[];
  /**
   * R3: the signature of each consent (same method, name and device; the
   * text hash per type) and the typed name for users/{uid}.signedNames.
   */
  signatures: Partial<Record<VerificationConsent, SignatureRecord>>;
  signedName: string | null;
}

export interface DecisionWrite {
  caseId: string;
  uid: string;
  scope: CaseScope;
  status: "approved" | "rejected";
  reviewerUid: string;
  reasonCode: RejectionReason | null;
  note: string | null;
  /** Approve of a case with children: how the parent and child name check passed. */
  nameCheck: NameCheck | null;
  decidedAtMs: number;
  /**
   * When the scheduled job deletes the images. Prompt 12 (owner decision,
   * DECISIONS.md "Data retention"): null, decided cases keep their photos
   * while the account is active; account deletion purges them 1 year
   * after closure. Only withdrawn cases are still deleted by the job.
   */
  purgeAtMs: number | null;
  /** New account status, for an identity case. */
  userStatus: AccountStatus | null;
  childIds: string[];
  vehicle: boolean;
  /** National ID claim to release (identity rejected, not banned). */
  releaseNationalIdHash: string | null;
  /** National ID to add to the ban list. */
  banNationalIdHash: string | null;
  /** The "verified" claim was changed before this write (identity cases). */
  claimsChanged: boolean;
  ip: string | null;
}

export interface QueueEntry {
  caseId: string;
  scope: CaseScope;
  submittedAtMs: number;
  kycResult: string | null;
  children: number;
  driver: boolean;
}

export interface SchoolChoice {
  id: string;
  nameAr: string;
  nameEn: string;
  status: string;
  addedBy: string | null;
  mergedInto: string | null;
}

/**
 * The school a child of [uid] is linked to: an active school, or the
 * parent's own "Other" school still awaiting review. A school merged
 * meanwhile is followed to the school it was merged into. Undefined when
 * the parent may not use it.
 */
export async function resolveChildSchool(
  store: Pick<VerificationStore, "getSchool">,
  uid: string,
  schoolId: string,
): Promise<SchoolChoice | undefined> {
  let school = await store.getSchool(schoolId);
  if (school?.status === "merged" && school.mergedInto) school = await store.getSchool(school.mergedInto);
  if (!school) return undefined;
  if (school.status === "active") return school;
  if (school.status === "awaiting_review" && school.addedBy === uid) return school;
  return undefined;
}

/** Keeps the name the app showed when it is one of the school's names, else the Arabic name. */
export function childSchoolName(school: SchoolChoice, shown: string): string {
  return shown && (shown === school.nameAr || shown === school.nameEn) ? shown : school.nameAr || school.nameEn;
}

export interface VerificationStore {
  newId(): string;
  getUser(uid: string): Promise<UserSnapshot | undefined>;
  listChildren(uid: string): Promise<ChildSnapshot[]>;
  /** Read-only early check, so a refused ID costs no uploads copy or KYC call. */
  checkNationalId(hash: string, uid: string): Promise<"ok" | "duplicate" | "banned">;
  /**
   * Writes the case, children, car, user and consents, and claims the
   * national ID hash (if any) in ONE transaction: a claim never exists
   * without its case. Throws duplicate-id / banned-id / case-open when the
   * check fails at commit time; then nothing is written.
   */
  saveSubmission(write: SubmissionWrite): Promise<void>;
  /** Parent withdraws a case still waiting for review; releases its ID claim. */
  withdrawCase(uid: string, caseId: string, nowMs: number): Promise<void>;
  getCase(caseId: string): Promise<CaseRecord | undefined>;
  /**
   * Fails with already-decided when the case left the queue meanwhile.
   * Writes users/{uid}.claimsUpdatedAt when [write.claimsChanged]: the app
   * refreshes its ID token when that marker changes.
   */
  saveDecision(write: DecisionWrite): Promise<void>;
  queue(limit: number): Promise<QueueEntry[]>;
  /** A school a child may be linked to (F4), or undefined. */
  getSchool(id: string): Promise<SchoolChoice | undefined>;
  removeChild(uid: string, childId: string): Promise<void>;
  appendAudit(entry: { actorUid: string; action: string; target: string; ip: string | null; reasonCode?: string | null }): Promise<void>;
  casesDueForPurge(nowMs: number, limit: number): Promise<Array<{ id: string; uid: string; status: string }>>;
  /** Prompt 12: a decided case keeps its images (clears an old purge date). */
  keepImages(caseId: string): Promise<void>;
  markPurged(caseId: string, nowMs: number): Promise<void>;
  caseExists(caseId: string): Promise<boolean>;
}

export interface StoredFile {
  path: string;
  createdMs: number;
}

export interface VerificationFiles {
  exists(path: string): Promise<boolean>;
  copy(from: string, to: string): Promise<void>;
  delete(path: string): Promise<void>;
  read(path: string): Promise<Buffer>;
  list(prefix: string): Promise<StoredFile[]>;
  /** Returns the number of files deleted. */
  deletePrefix(prefix: string): Promise<number>;
  signedReadUrl(path: string, expiresAtMs: number): Promise<string>;
}

export interface ClaimsService {
  /** Sets or clears the "verified" custom claim, keeping other claims. */
  setVerified(uid: string, verified: boolean): Promise<void>;
  /** Signs the account out everywhere (ban). */
  revokeSessions(uid: string): Promise<void>;
}

export interface VerificationDeps {
  store: VerificationStore;
  files: VerificationFiles;
  kyc: KycProvider;
  claims: ClaimsService;
  nationalIdKey: string;
  /** R3: keys the typed-name hash and the device key of a signature (OTP_HMAC_KEY). */
  signatureKey?: string;
  now: () => number;
  reportError: (error: unknown) => void;
}

export const ROOT = "verification";
export const DAY_MS = 24 * 60 * 60 * 1000;
/** Uploads never submitted are deleted after this long. */
export const PENDING_MAX_AGE_MS = 3 * DAY_MS;
/** Admin image links expire quickly (no download, spec section 7). */
export const SIGNED_URL_TTL_MS = 5 * 60 * 1000;

export function pendingPath(uid: string, name: string): string {
  return `${ROOT}/${uid}/pending/${name}`;
}
export function casePrefix(uid: string, caseId: string): string {
  return `${ROOT}/${uid}/cases/${caseId}/`;
}

/** Submits documents for review: checks, copies the images, runs the automated check, queues the case. */
/**
 * R3: the typed name must match the ID name (the identity part of this
 * submission, or the verified parent's stored name), and a "recentSignIn"
 * signature needs a sign-in less than 10 minutes old. Returns the signature
 * of each consent (the text hash is of the text the parent read).
 */
export function signSubmission(
  key: string,
  uid: string,
  submission: Submission,
  user: Pick<UserSnapshot, "firstName" | "lastName">,
  authTimeSeconds: number | null,
  nowMs: number,
): Partial<Record<VerificationConsent, SignatureRecord>> {
  const s = submission.signature;
  if (!s) return {};
  checkMethod(s.method, authTimeSeconds, nowMs);
  const first = submission.identity?.firstName ?? user.firstName ?? null;
  const last = submission.identity?.lastName ?? user.lastName ?? null;
  if (!first || !last || !nameMatches(s.fullName, first, last)) throw new SignatureError("signature-name-mismatch");
  const deviceKey = s.deviceId ? sessionKey(key, s.deviceId) : null;
  const out: Partial<Record<VerificationConsent, SignatureRecord>> = {};
  for (const type of submission.consents) {
    const text = consentText(type, VERIFICATION_CONSENT_VERSIONS[type], s.language);
    if (text === null) throw new Error(`no consent text for ${type}`);
    out[type] = signatureRecord(key, uid, s, text, true, deviceKey);
  }
  return out;
}

export async function submitVerification(deps: VerificationDeps, uid: string, data: unknown, authTimeSeconds: number | null = null): Promise<{ caseId: string }> {
  const user = await deps.store.getUser(uid);
  if (!user) throw new VerificationError("no-account");
  if (user.status === "suspended") throw new VerificationError("suspended");
  if (!user.emailVerified || !user.termsAccepted) throw new VerificationError("signup-incomplete");
  if (user.status === "pending" || user.caseOpen) throw new VerificationError("case-open");

  const verified = user.status === "verified";
  const submission: Submission = parseSubmission(data, { today: cairoDate(deps.now()), verified });

  // Duplicate and ban checks on the keyed hash; the number itself goes no further.
  let hash: string | null = null;
  if (submission.identity) {
    hash = nationalIdHash(deps.nationalIdKey, submission.identity.nationalId);
    // Early, read-only: nothing is claimed until the case itself is saved.
    const check = await deps.store.checkNationalId(hash, uid);
    if (check === "banned") throw new VerificationError("banned-id");
    if (check === "duplicate") throw new VerificationError("duplicate-id");
  }

  const existing = await deps.store.listChildren(uid);
  for (const child of submission.children) {
    if (!child.childId) continue;
    const own = existing.find((c) => c.id === child.childId);
    if (!own) throw new VerificationError("not-found", { ref: child.ref });
    if (own.status === "pending") throw new VerificationError("case-open");
  }
  // R3: the written signature (typed ID name, device check) of the consents.
  const signatures = signSubmission(deps.signatureKey ?? deps.nationalIdKey, uid, submission, user, authTimeSeconds, deps.now());

  const schools = new Map<string, SchoolChoice>();
  for (const child of submission.children) {
    const school = await resolveChildSchool(deps.store, uid, child.schoolId);
    if (!school) throw new VerificationError("unknown-school", { ref: child.ref });
    schools.set(child.ref, school);
  }

  const names = requiredFiles(submission);
  const missing: string[] = [];
  for (const name of names) {
    if (!(await deps.files.exists(pendingPath(uid, name)))) missing.push(name);
  }
  if (missing.length > 0) throw new VerificationError("missing-upload", { missing });
  // Prompt 10: the optional driver photo goes with the driver details.
  if (submission.driver && (await deps.files.exists(pendingPath(uid, DRIVER_PHOTO_FILE)))) names.push(DRIVER_PHOTO_FILE);

  const caseId = deps.store.newId();
  const prefix = casePrefix(uid, caseId);
  for (const name of names) await deps.files.copy(pendingPath(uid, name), prefix + name);

  let kyc: KycOutcome | null = null;
  if (submission.identity) {
    const images = async (): Promise<KycImages> => ({
      idFront: await deps.files.read(`${prefix}id_front.jpg`),
      idBack: await deps.files.read(`${prefix}id_back.jpg`),
      selfie: await deps.files.read(`${prefix}selfie.jpg`),
      selfieTurn: await deps.files.read(`${prefix}selfie_turn.jpg`),
    });
    kyc = await runKyc(deps.kyc, images, deps.reportError);
  }

  const children: CaseChild[] = submission.children.map((child) => ({
    ref: child.ref,
    childId: child.childId ?? deps.store.newId(),
    isNew: child.childId === null,
    firstName: child.firstName,
    age: child.age,
    grade: child.grade,
    teen: isTeen(child, cairoDate(deps.now())),
    schoolId: schools.get(child.ref)?.id ?? child.schoolId,
    schoolName: childSchoolName(schools.get(child.ref) as SchoolChoice, child.schoolName),
    file: `${prefix}school_id_${child.ref}.jpg`,
  }));

  const save = deps.store.saveSubmission({
    caseRecord: {
      id: caseId,
      uid,
      scope: submission.identity ? "identity" : "update",
      status: "awaiting_review",
      nationalIdHash: hash,
      identity: submission.identity
        ? {
            firstName: submission.identity.firstName,
            lastName: submission.identity.lastName,
            idExpiry: submission.identity.idExpiry,
            livenessChallenge: submission.identity.livenessChallenge,
          }
        : null,
      children,
      driver: submission.driver,
      files: names.map((name) => prefix + name),
      kyc,
      submittedAtMs: deps.now(),
      imagesDeleted: false,
    },
    replaceChildIds: verified ? [] : existing.map((c) => c.id),
    consents: submission.consents,
    signatures,
    signedName: submission.signature?.fullName ?? null,
  });
  try {
    await save;
  } catch (error) {
    // Refused at commit (for example another account claimed the ID a
    // moment ago): drop the copies now; the daily job would too.
    try {
      await deps.files.deletePrefix(prefix);
    } catch (cleanup) {
      deps.reportError(cleanup);
    }
    throw error;
  }

  // The pending copies are no longer needed. A failure here is cleaned up by the daily job.
  for (const name of names) {
    try {
      await deps.files.delete(pendingPath(uid, name));
    } catch (error) {
      deps.reportError(error);
    }
  }
  return { caseId };
}

/** What a decision changes. Pure, unit-tested. */
export function planDecision(
  record: CaseRecord,
  decision: { approve: boolean; reasonCode: RejectionReason | null; note: string | null; ban: boolean; nameCheck?: NameCheck | null },
  reviewerUid: string,
  nowMs: number,
  ip: string | null,
): DecisionWrite {
  const identity = record.scope === "identity";
  let userStatus: AccountStatus | null = null;
  if (decision.ban) userStatus = "suspended";
  else if (identity) userStatus = decision.approve ? "verified" : "rejected";
  return {
    caseId: record.id,
    uid: record.uid,
    scope: record.scope,
    status: decision.approve ? "approved" : "rejected",
    reviewerUid,
    reasonCode: decision.reasonCode,
    note: decision.note,
    nameCheck: decision.approve ? (decision.nameCheck ?? null) : null,
    decidedAtMs: nowMs,
    purgeAtMs: null,
    userStatus,
    childIds: record.children.map((c) => c.childId),
    vehicle: record.driver !== null,
    // A rejected ID is released so its real owner can still register.
    releaseNationalIdHash: identity && !decision.approve && !decision.ban ? record.nationalIdHash : null,
    banNationalIdHash: decision.ban ? record.nationalIdHash : null,
    claimsChanged: userStatus !== null,
    ip,
  };
}

/** Admin decision. The only path that verifies an account and sets the claim. */
export async function decideVerification(
  deps: VerificationDeps,
  reviewerUid: string,
  data: unknown,
  ip: string | null = null,
): Promise<{ status: string }> {
  const decision = parseDecision(data);
  const record = await deps.store.getCase(decision.caseId);
  if (!record) throw new VerificationError("not-found");
  if (record.status !== "awaiting_review") throw new VerificationError("already-decided");
  if (record.uid === reviewerUid) throw new VerificationError("own-case");
  if (decision.ban && !record.nationalIdHash) throw new VerificationError("invalid-decision");
  // The reviewer must confirm the parent and child name check (spec section 3).
  if (decision.approve && record.children.length > 0 && decision.nameCheck === null) {
    throw new VerificationError("name-check-missing");
  }

  const write = planDecision(record, decision, reviewerUid, deps.now(), ip);
  // The claim is set BEFORE the status and the claimsUpdatedAt marker are
  // written: when the app sees the marker and refreshes its token, the new
  // token already carries the claim.
  if (write.claimsChanged) await deps.claims.setVerified(record.uid, write.userStatus === "verified");
  try {
    await deps.store.saveDecision(write);
  } catch (error) {
    // The case was decided by someone else meanwhile: put the claim back.
    if (write.claimsChanged && write.userStatus === "verified") {
      try {
        await deps.claims.setVerified(record.uid, false);
      } catch (revert) {
        deps.reportError(revert);
      }
    }
    throw error;
  }
  if (decision.ban) await deps.claims.revokeSessions(record.uid);
  // Prompt 10 (F33, F38): an approved driver photo is kept for the driver
  // card and the selfie checks; every other image is deleted after review.
  const photo = record.files.find((f) => f.endsWith(`/${DRIVER_PHOTO_FILE}`));
  // The identity selfie becomes the face reference of the selfie checks
  // (F38), so every verified driver has one (Prompt 10 review).
  const selfie = record.files.find((f) => f.endsWith("/selfie.jpg"));
  const keep: Array<[string, string]> = [];
  if (write.status === "approved" && photo) keep.push([photo, driverPhotoPath(record.uid)]);
  if (write.status === "approved" && selfie && record.scope === "identity") keep.push([selfie, faceRefPath(record.uid)]);
  for (const [from, to] of keep) {
    try {
      await deps.files.copy(from, to);
    } catch (error) {
      deps.reportError(error);
    }
  }
  return { status: write.status };
}

export interface CaseView {
  caseId: string;
  uid: string;
  scope: CaseScope;
  status: CaseStatus;
  identity: CaseRecord["identity"];
  children: Array<Omit<CaseChild, "file"> & { imageUrl: string | null }>;
  driver: DriverSubmission | null;
  kyc: KycOutcome | null;
  submittedAtMs: number;
  /** Short-lived signed links, keyed by file name. */
  images: Record<string, string>;
  /** Prompt 12: links to the server-made thumbnails (same keys), where one exists. */
  thumbs: Record<string, string>;
}

/** Admin view of one case with short-lived image links. Every view is logged. */
export async function openVerificationCase(
  deps: VerificationDeps,
  adminUid: string,
  data: unknown,
  ip: string | null = null,
): Promise<CaseView> {
  const raw = typeof data === "object" && data !== null ? (data as { caseId?: unknown; reason?: unknown }) : {};
  const caseId = raw.caseId;
  if (typeof caseId !== "string" || !/^[A-Za-z0-9]{1,40}$/.test(caseId)) throw new VerificationError("invalid-request");
  const record = await deps.store.getCase(caseId);
  if (!record) throw new VerificationError("not-found");
  // Prompt 12: photos are kept after the decision, so opening a decided
  // case needs a stated reason (logged). Reviewing the queue is the reason
  // for a case that waits for review.
  const reason = accessReason(raw.reason) ?? (record.status === "awaiting_review" ? "review" : null);
  if (!reason) throw new VerificationError("reason-required");
  await deps.store.appendAudit({ actorUid: adminUid, action: "verification.view", target: `verifications/${caseId}`, ip, reasonCode: reason });

  const images: Record<string, string> = {};
  const thumbs: Record<string, string> = {};
  if (!record.imagesDeleted) {
    const expires = deps.now() + SIGNED_URL_TTL_MS;
    for (const path of record.files) {
      const name = path.slice(path.lastIndexOf("/") + 1);
      images[name] = await deps.files.signedReadUrl(path, expires);
      const thumb = thumbPath(path);
      if (thumb && (await deps.files.exists(thumb))) thumbs[name] = await deps.files.signedReadUrl(thumb, expires);
    }
  }
  return {
    caseId: record.id,
    uid: record.uid,
    scope: record.scope,
    status: record.status,
    identity: record.identity,
    children: record.children.map(({ file, ...child }) => ({
      ...child,
      imageUrl: images[file.slice(file.lastIndexOf("/") + 1)] ?? null,
    })),
    driver: record.driver,
    kyc: record.kyc,
    submittedAtMs: record.submittedAtMs,
    images,
    thumbs,
  };
}

/**
 * Daily retention job (spec section 7): deletes the images of decided cases
 * whose time has come, uploads that were never submitted, and case folders
 * with no case record (a submit that failed half way).
 */
export async function purgeVerificationImages(
  deps: Pick<VerificationDeps, "store" | "files" | "now">,
  batchLimit = 200,
): Promise<{ cases: number; files: number }> {
  const now = deps.now();
  let cases = 0;
  let files = 0;
  for (const due of await deps.store.casesDueForPurge(now, batchLimit)) {
    // Prompt 12: decided cases are kept while the account is active (their
    // purge date from before the owner's decision is cleared); only cases
    // the parent withdrew are deleted.
    if (due.status !== "withdrawn") {
      await deps.store.keepImages(due.id);
      continue;
    }
    files += await deps.files.deletePrefix(casePrefix(due.uid, due.id));
    await deps.store.markPurged(due.id, now);
    cases += 1;
  }

  const known = new Map<string, boolean>();
  for (const file of await deps.files.list(`${ROOT}/`)) {
    const parts = file.path.split("/");
    const age = now - file.createdMs;
    let remove = false;
    if (parts.length === 4 && parts[2] === "pending") {
      remove = age > PENDING_MAX_AGE_MS;
    } else if (parts.length === 5 && parts[2] === "cases" && age > DAY_MS) {
      const caseId = parts[3];
      if (!known.has(caseId)) known.set(caseId, await deps.store.caseExists(caseId));
      remove = known.get(caseId) === false;
    }
    if (remove) {
      await deps.files.delete(file.path);
      files += 1;
    }
  }
  return { cases, files };
}

/**
 * Parent withdraws the case waiting for review (for example to fix a
 * typo). The ID claim is released, the images are deleted by the next
 * daily run, and a parent who was not verified goes back to "unverified".
 */
export async function withdrawVerification(
  deps: Pick<VerificationDeps, "store" | "now">,
  uid: string,
  data: unknown,
): Promise<void> {
  const caseId = typeof data === "object" && data !== null ? (data as { caseId?: unknown }).caseId : undefined;
  if (typeof caseId !== "string" || !/^[A-Za-z0-9]{1,40}$/.test(caseId)) throw new VerificationError("invalid-request");
  await deps.store.withdrawCase(uid, caseId, deps.now());
}

/** Removes a child (F3). Not while the child waits for review. */
export async function removeChild(deps: Pick<VerificationDeps, "store">, uid: string, data: unknown): Promise<void> {
  const childId = typeof data === "object" && data !== null ? (data as { childId?: unknown }).childId : undefined;
  if (typeof childId !== "string" || !/^[A-Za-z0-9]{1,40}$/.test(childId)) throw new VerificationError("invalid-request");
  await deps.store.removeChild(uid, childId);
}
