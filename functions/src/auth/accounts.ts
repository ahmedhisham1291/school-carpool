import type { Auth, UserRecord } from "firebase-admin/auth";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Language } from "../whatsapp/sender";
import type { AccountService } from "./otp_flow";
import { pickFreeParentId, type RandomBytes } from "./parent_id";

export const USERS = "users";
/** Reserved parent IDs. Never deleted, so an ID is never reused. */
export const PARENT_IDS = "parentIds";

export type AccountStatus = "unverified" | "pending" | "verified" | "rejected" | "suspended";

/**
 * Fields of a new user record (spec section 9, "User"). The app can only
 * change `language` (firestore.rules); everything else is written here or
 * by later Cloud Functions.
 */
export function newUserRecord(parentId: string, phoneE164: string, language: Language): Record<string, unknown> {
  return {
    parentId,
    status: "unverified" satisfies AccountStatus,
    role: "parent",
    phone: phoneE164,
    email: null,
    emailVerified: false,
    language,
    whatsappOptIn: false,
    termsAcceptedAt: null,
    termsVersion: null,
  };
}

/**
 * The confirmed email to copy from Firebase Auth to the user record, or
 * null. Auth sets emailVerified only after the parent opened the link.
 */
export function verifiedEmail(user: Pick<UserRecord, "email" | "emailVerified">): string | null {
  return user.emailVerified && user.email ? user.email : null;
}

/**
 * Creates the user record and its parent ID in one transaction, unless it
 * exists. The parent ID document is created with `create`, so two
 * transactions can never claim the same ID. Returns the account status.
 *
 * For an existing record, a confirmed email from Auth ([email]) is copied
 * when the record does not have it yet. This finishes the email step for a
 * parent whose session ended when the link changed their email (Firebase
 * revokes sessions on an email change) and who signed in again.
 */
export async function ensureUserRecord(
  db: Firestore,
  uid: string,
  phoneE164: string,
  language: Language,
  random?: RandomBytes,
  email?: string | null,
): Promise<string> {
  return db.runTransaction(async (tx) => {
    const userRef = db.collection(USERS).doc(uid);
    const existing = await tx.get(userRef);
    if (existing.exists) {
      if (email && (existing.get("emailVerified") !== true || existing.get("email") !== email)) {
        tx.update(userRef, { email, emailVerified: true, updatedAt: FieldValue.serverTimestamp() });
      }
      const status: unknown = existing.get("status");
      return typeof status === "string" ? status : "unverified";
    }
    const parentId = await pickFreeParentId(
      async (id) => (await tx.get(db.collection(PARENT_IDS).doc(id))).exists,
      random,
    );
    tx.create(db.collection(PARENT_IDS).doc(parentId), { uid, createdAt: FieldValue.serverTimestamp() });
    tx.create(userRef, {
      ...newUserRecord(parentId, phoneE164, language),
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return "unverified";
  });
}

export function errorCode(error: unknown): string | undefined {
  if (typeof error === "object" && error !== null && "code" in error) {
    return String((error as { code: unknown }).code);
  }
  return undefined;
}

export class FirebaseAccountService implements AccountService {
  constructor(
    private readonly auth: Auth,
    private readonly db: Firestore,
  ) {}

  async signInWithPhone(phoneE164: string, language: Language): Promise<{ uid: string; suspended: boolean }> {
    const user = await this.findOrCreateAuthUser(phoneE164);
    const status = await ensureUserRecord(this.db, user.uid, phoneE164, language, undefined, verifiedEmail(user));
    return { uid: user.uid, suspended: status === "suspended" };
  }

  createToken(uid: string): Promise<string> {
    // No custom claims here: "verified" and "admin" are set by later
    // functions after review.
    return this.auth.createCustomToken(uid);
  }

  private async findOrCreateAuthUser(phoneE164: string): Promise<UserRecord> {
    try {
      return await this.auth.getUserByPhoneNumber(phoneE164);
    } catch (error) {
      if (errorCode(error) !== "auth/user-not-found") throw error;
    }
    try {
      return await this.auth.createUser({ phoneNumber: phoneE164 });
    } catch (error) {
      // Another request created it a moment ago.
      if (errorCode(error) !== "auth/phone-number-already-exists") throw error;
      return await this.auth.getUserByPhoneNumber(phoneE164);
    }
  }
}
